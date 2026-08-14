require "fileutils"
require "open3"
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
    # Chrome release. Everything that has to name a browser — the headless
    # launch flag, and the curl-side client borrowing that browser's cookies —
    # asks here, so the two cannot drift apart.
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
      configured = browser_config["user_agent"]
      return configured if configured

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

    def cdp_reachable?(timeout: 1.0)
      uri = URI("#{CDP_URL}/json/version")
      Net::HTTP.start(uri.host, uri.port, open_timeout: timeout, read_timeout: timeout) do |http|
        http.get(uri.request_uri).is_a?(Net::HTTPSuccess)
      end
    rescue StandardError
      false
    end

    # Headless by default: every command that needs the browser used to raise
    # a Chrome window over whatever the user was doing, and there is nothing
    # to see in it. `LOWES_HEADLESS=0` or `"browser": {"headless": false}`
    # puts the window back.
    def headless_default?
      env = ENV["LOWES_HEADLESS"].to_s
      return !FALSEY.include?(env.downcase) unless env.empty?

      configured = browser_config["headless"]
      configured.nil? ? true : !!configured
    end

    # Returns true if Chrome is up (already-running or just-started),
    # false if we couldn't bring it up.
    def ensure_started(quiet: false, headless: nil)
      return true if cdp_reachable?

      require_relative "commands/chrome_start"
      headless = headless_default? if headless.nil?
      warn("lowes: starting Chrome#{" (headless)" if headless} (no CDP on 9222)") unless quiet
      Lowes::Commands::ChromeStart.new(silent: quiet).run([headless ? "--headless" : "--headed"])
      wait_for_cdp
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
      return true unless running_headless?

      warn("lowes: Chrome on 9222 is headless — restarting it with a window") unless quiet
      return false unless quit_ours

      ensure_started(quiet: quiet, headless: false)
    end

    # How the Chrome that is already running was launched. `ps` is the only
    # thing that knows; a marker file would go on claiming a browser that had
    # since exited. nil means we could not find one of ours at all.
    def running_headless?(profile: DEFAULT_PROFILE_DIR)
      argv = running_argv(profile: profile)
      argv&.include?("--headless")
    end

    def running_argv(profile: DEFAULT_PROFILE_DIR)
      processes.find do |line|
        line.include?("--user-data-dir=#{profile}") &&
          line.include?("--remote-debugging-port=") &&
          !line.include?("--type=") # renderer/GPU helpers inherit the profile flag
      end
    end

    # A seam, and an honest one: nothing else on the machine can answer "how
    # was that process started". `-ww` because macOS `ps` truncates argv to the
    # terminal width otherwise, and the flag we are looking for is at the end.
    def processes
      IO.popen(["ps", "-axww", "-o", "command="], &:read).lines
    rescue SystemCallError
      []
    end

    # Non-fatal on purpose: "no config yet" is a normal state for a browser
    # that is only being asked whether to open a window.
    def browser_config
      Lowes::Config.load.browser
    rescue StandardError
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
