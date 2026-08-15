require "fileutils"
require "open3"
require "json"
require "net/http"

require_relative "config"

module Lowes
  # Helpers for ensuring a CDP-attached Chrome is reachable.
  # Used by sync/login/price/store/quotes — the commands that spawn the
  # Python worker, which expects http://127.0.0.1:9222 to answer.
  module Chrome
    CDP_URL = "http://127.0.0.1:9222"

    CHROME_APP = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome".freeze

    # One profile, shared by every command and by `lowes login`. Whatever trust
    # Akamai extends is scoped to it, so it is the thing worth keeping.
    DEFAULT_PROFILE_DIR = "#{Dir.home}/.local/share/lowes/cache/chrome-profile".freeze

    FALSEY = %w[0 false no off].freeze

    # The version is read from the binary rather than frozen here: a UA naming
    # a Chrome that doesn't match the engine behind it is a worse tell than
    # `HeadlessChrome` was, and a constant becomes exactly that on the next
    # Chrome release.
    #
    # Everything that has to name a browser asks here: the headless launch
    # flag, the client borrowing that browser's cookies, and — via
    # LOWES_USER_AGENT, exported in Lowes::Worker#worker_env — the Python
    # worker's no-CDP fallback, which otherwise builds its own from its own
    # platform table in pyworker/stealth.py. That export is the only thing
    # keeping the two tables from drifting, so it travels with this comment.
    USER_AGENT = "Mozilla/5.0 (%<platform>s) AppleWebKit/537.36 (KHTML, like Gecko) " \
                 "Chrome/%<version>s.0.0.0 Safari/537.36".freeze

    # Only what has been measured. Guessing this string is how a coherent
    # browser starts contradicting itself, so anything else has to say so via
    # `browser.user_agent` in config.
    PLATFORMS = {
      /darwin/ => "Macintosh; Intel Mac OS X 10_15_7",
      /linux/ => "X11; Linux x86_64"
    }.freeze

    module_function

    def user_agent(binary = nil)
      configured = browser_config["user_agent"].to_s.strip
      unless configured.empty?
        # Worth saying out loud rather than silently honouring: this is the
        # one string whose whole job is to not contain that token.
        warn "lowes: browser.user_agent contains HeadlessChrome — Akamai refuses it" if configured.include?("HeadlessChrome")
        return configured
      end

      binary ||= browser_config["binary"] || CHROME_APP
      format(USER_AGENT, platform: platform, version: installed_version(binary))
    end

    def platform(host = RUBY_PLATFORM)
      PLATFORMS.each { |pattern, name| return name if pattern.match?(host) }
      raise "no user agent is known for #{host}; #{set_one}"
    end

    # Asked of the binary rather than of a running browser, because this runs
    # before there is one to ask. Memoized because the answer cannot change
    # within a process, and every Client built would otherwise fork a browser
    # just to read one number.
    def installed_version(binary)
      @versions ||= {}
      @versions[binary] ||= begin
        line = IO.popen([binary, "--version"], &:read).to_s
        line[/\d+/] || raise("#{binary} did not report a version; #{set_one}")
      rescue SystemCallError => e
        raise "could not ask #{binary} its version (#{e.message}); #{set_one}"
      end
    end

    def set_one = "set browser.user_agent in #{Lowes::Config.config_path}"

    # The browser's own description of itself, or nil if nothing usable is on
    # the port. Chrome answers here with the version, the WebSocket URL, and —
    # the reason this returns the body rather than a boolean — the User-Agent
    # it is actually going to send.
    #
    # A 200 that is not JSON counts as nothing usable: `webSocketDebuggerUrl`
    # is read out of this same body before any command can attach, so a body
    # we cannot parse is a port we cannot use, and calling it "reachable"
    # only moves the failure later.
    #
    # `url:` exists for the same reason `running_headless?` takes `profile:` —
    # so a test can point it at something it started itself rather than at
    # whatever Chrome the machine happens to have on 9222.
    def cdp_version(timeout: 1.0, url: CDP_URL)
      uri = URI("#{url}/json/version")
      body = Net::HTTP.start(uri.host, uri.port, open_timeout: timeout, read_timeout: timeout) do |http|
        response = http.get(uri.request_uri)
        response.is_a?(Net::HTTPSuccess) ? response.body : nil
      end
      body && JSON.parse(body)
    rescue StandardError
      nil
    end

    def cdp_reachable?(timeout: 1.0)
      !cdp_version(timeout: timeout).nil?
    end

    def cdp_user_agent(timeout: 1.0)
      cdp_version(timeout: timeout).to_h["User-Agent"]
    end

    # Proof, in the one direction it goes. A `HeadlessChrome` token is only
    # ever produced by a headless build that was left to name itself; its
    # absence proves nothing, because a headless Chrome started the way this
    # tool starts one is overriding that string on purpose. So: true means
    # headless, false means "no idea".
    def headless_ua? = cdp_user_agent.to_s.include?("HeadlessChrome")

    # Akamai reads the User-Agent at the edge and answers 403 before the page
    # loads, before its sensor runs, and before anything here gets a say. The
    # browser will tell us it is about to send that token if we ask, so ask —
    # otherwise this surfaces a few seconds later as an expired-session error
    # naming the wrong cause.
    #
    # Also the only check that covers a Chrome someone started by hand: one
    # launched without `--user-agent` is indistinguishable from a correct one
    # until lowes.com refuses it.
    def warn_headless_ua
      ua = cdp_user_agent
      return unless ua.to_s.include?("HeadlessChrome")

      warn "lowes: the Chrome on 9222 advertises #{ua[%r{HeadlessChrome/\S*}]} — lowes.com answers 403 to that. " \
           "It was started without --user-agent; quit it and rerun, or use `lowes chrome-start --headless`."
    end

    # Headless by default: every command that needs the browser used to raise
    # a Chrome window over whatever the user was doing, and there is nothing
    # to see in it. `LOWES_HEADLESS=0` or `"browser": {"headless": false}`
    # puts the window back.
    def headless_default?
      env = ENV["LOWES_HEADLESS"].to_s
      return truthy?(env) unless env.empty?

      configured = browser_config["headless"]
      configured.nil? ? true : truthy?(configured)
    end

    # One coercion for both sources. `"headless": "false"` — a quoted JSON
    # boolean, one of the easier config mistakes to make — is truthy to `!!`,
    # so reading it that way would hand back headless to someone who had just
    # written the word false to escape it.
    def truthy?(value)
      return value unless value.is_a?(String) || value.is_a?(Numeric)
      !FALSEY.include?(value.to_s.strip.downcase)
    end

    # Returns true if Chrome is up (already-running or just-started),
    # false if we couldn't bring it up.
    def ensure_started(quiet: false, headless: nil)
      if cdp_reachable?
        warn_headless_ua unless quiet
        return true
      end

      require_relative "commands/chrome_start"
      headless = headless_default? if headless.nil?
      warn("lowes: starting Chrome#{" (headless)" if headless} (no CDP on 9222)") unless quiet
      # A non-zero return means nothing was spawned (no binary, or no User-
      # Agent could be built). Polling a port nothing is coming up on for 20s
      # buries the message ChromeStart already printed.
      status = Lowes::Commands::ChromeStart.new(silent: quiet).run([headless ? "--headless" : "--headed"])
      return false unless status.to_i.zero?
      return false unless wait_for_cdp

      # Checked again on the browser we just launched, because passing
      # `--user-agent` and the browser having taken it are different claims,
      # and only the second one is the one that matters.
      warn_headless_ua unless quiet
      true
    end

    # A window the user can type into. `lowes login` is the one command that
    # needs one, and it is worth being blunt about: attaching to a headless
    # Chrome and then asking someone to sign in to it is a ten-minute silence
    # ending in a timeout.
    #
    # Only ever restarts a Chrome this tool launched, identified by its
    # user-data-dir. One that is merely on the port belongs to somebody else.
    def ensure_headed(quiet: false)
      return ensure_started(quiet: quiet, headless: false) unless cdp_reachable?

      case running_headless?
      when false then return true
      when nil
        # Something is serving CDP but it is not ours to restart. Say so: if
        # it happens to be headless, the sign-in prompt below never appears
        # and the wait that follows is the timeout this method exists to
        # prevent. The browser can settle that much itself — see
        # `headless_ua?` for why only the positive answer is worth acting on.
        warn(foreign_chrome_warning) unless quiet
        return true
      end

      warn("lowes: Chrome on 9222 is headless — restarting it with a window") unless quiet
      return false unless quit_ours

      ensure_started(quiet: quiet, headless: false)
    end

    def foreign_chrome_warning
      base = "lowes: Chrome on 9222 isn't one we started (different --profile?) — leaving it alone"
      return "#{base}; it reports itself headless, so there is no window to sign in to — quit it and rerun" if headless_ua?

      "#{base}; sign in there if it has a window"
    end

    # How the Chrome that is already running was launched. `ps` is the only
    # thing that knows; a marker file would go on claiming a browser that had
    # since exited. nil means we could not find one of ours at all.
    def running_headless?(profile: DEFAULT_PROFILE_DIR)
      argv = running_argv(profile: profile)
      argv&.include?("--headless")
    end

    def running_argv(profile: DEFAULT_PROFILE_DIR)
      (processes || []).find do |line|
        line.include?("--user-data-dir=#{profile}") &&
          line.include?("--remote-debugging-port=") &&
          !line.include?("--type=") # renderer/GPU helpers inherit the profile flag
      end
    end

    # A seam, and an honest one: nothing else on the machine can answer "how
    # was that process started". `-ww` because macOS `ps` truncates argv to the
    # terminal width otherwise, and the flag we are looking for is at the end.
    # nil, not [], when ps itself fails: "no Chrome of ours is running" and
    # "we could not find out" lead to opposite decisions here — one says go
    # ahead and launch, the other says do not signal anything.
    def processes
      IO.popen(["ps", "-axww", "-o", "command="], &:read).lines
    rescue SystemCallError => e
      warn "lowes: could not list processes (#{e.message})"
      nil
    end

    # "No config yet" is a normal state for a browser that is only being asked
    # whether to open a window, so that one is silent. A malformed config is
    # not: swallowing it would force headless and drop browser.binary and
    # browser.user_agent, all three without a word.
    def browser_config
      Lowes::Config.load.browser
    rescue StandardError => e
      # `Config.load` raises a plain RuntimeError for "no file yet", so the
      # file itself is what separates the two cases rather than the exception
      # class.
      warn "lowes: ignoring #{Lowes::Config.config_path} (#{e.message})" if Lowes::Config.config_path.exist?
      {}
    end

    # TERM rather than KILL: Chrome writes the profile out on the way down, and
    # that profile holds the signed-in session this whole design exists to keep.
    def quit_ours(profile: DEFAULT_PROFILE_DIR)
      line = running_argv(profile: profile)
      return false unless line

      pid = pid_for(line)
      return false unless pid

      Process.kill("TERM", pid)
      deadline = Time.now + 10
      sleep 0.25 while cdp_reachable?(timeout: 0.5) && Time.now < deadline
      !cdp_reachable?(timeout: 0.5)
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def pid_for(command_line)
      IO.popen(["ps", "-axww", "-o", "pid=,command="], &:read).lines.each do |line|
        pid, command = line.strip.split(" ", 2)
        return pid.to_i if command == command_line.strip
      end
      nil
    rescue SystemCallError
      nil
    end

    def wait_for_cdp(seconds: 20)
      deadline = Time.now + seconds
      until Time.now > deadline
        return true if cdp_reachable?
        sleep 0.5
      end
      false
    end
  end
end
