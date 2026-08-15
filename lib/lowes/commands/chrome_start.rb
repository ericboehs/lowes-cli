require "fileutils"
require "open3"
require "shellwords"

require_relative "../chrome"

module Lowes
  module Commands
    # Launches the Chrome that every other command attaches to over CDP.
    #
    # The flags are the point of this class, and the point is how few there
    # are. Chrome started directly like this was never in automation mode, so
    # `navigator.webdriver` is already false and no stealth patching is needed
    # — that is why the CDP-attach design exists at all.
    #
    # `--headless` is available and it travels with a `--user-agent` override,
    # because a headless Chrome names itself `HeadlessChrome/<version>` in its
    # own User-Agent and Akamai refuses that token at the edge before a byte of
    # JavaScript runs. Measured against lowes.com, cold profile, same minute:
    #
    #   --headless alone            "Access Denied", 403, no _abck issued
    #   --headless + --user-agent   real homepage, _abck validated in ~3s
    #
    # So the two flags go together or neither goes.
    class ChromeStart
      CHROME_APP = Lowes::Chrome::CHROME_APP
      DEFAULT_PORT = 9222
      DEFAULT_PROFILE_DIR = Lowes::Chrome::DEFAULT_PROFILE_DIR

      def initialize(global = {})
        @global = global || {}
        @quiet = @global[:quiet] || @global[:silent]
      end

      def run(argv)
        port = DEFAULT_PORT
        profile = DEFAULT_PROFILE_DIR
        url = "https://www.lowes.com/"
        binary = nil
        headless = nil
        while (a = argv.shift)
          case a
          when "--port"     then port = Integer(argv.shift)
          when "--profile"  then profile = argv.shift
          when "--url"      then url = argv.shift
          when "--binary"   then binary = argv.shift
          when "--headless" then headless = true
          when "--headed"   then headless = false
          when "-h", "--help"
            puts help_text
            return 0
          end
        end
        headless = Lowes::Chrome.headless_default? if headless.nil?
        binary ||= browser_config["binary"] || CHROME_APP

        unless File.exist?(binary)
          warn "lowes chrome-start: Google Chrome not found at #{binary}"
          warn "  install Chrome, or pass --binary /path/to/chrome"
          return 1
        end

        begin
          cmd = command(binary, port, profile, url, headless)
        rescue RuntimeError => e
          warn "lowes chrome-start: #{e.message}"
          return 1
        end

        FileUtils.mkdir_p(profile)
        announce(cmd, port, profile, headless)

        # Detach so the parent shell can exit. Chrome stays running.
        pid = Process.spawn(*cmd, [:out, :err] => "/dev/null")
        Process.detach(pid)
        warn "started chrome (pid=#{pid})" unless @quiet
        0
      end

      private

      def command(binary, port, profile, url, headless)
        cmd = [
          binary,
          "--remote-debugging-port=#{port}",
          "--remote-allow-origins=*",
          "--user-data-dir=#{profile}",
          "--no-default-browser-check",
          "--no-first-run"
        ]
        cmd += ["--headless", "--user-agent=#{Lowes::Chrome.user_agent(binary)}"] if headless
        cmd << url
      end

      def browser_config
        @browser_config ||= Lowes::Chrome.browser_config
      end

      def announce(cmd, port, profile, headless)
        return if @quiet
        warn "starting Chrome#{" (headless)" if headless} with debugging on port #{port}"
        warn "  profile: #{profile}"
        if headless
          warn "  no window will open; run `lowes login` (or `lowes chrome-start --headed`) to sign in"
        else
          warn "  sign in to Lowe's in this window, then run `lowes login` (or any command) in another terminal"
        end
        warn ""
        warn "  command: #{cmd.shelljoin}"
      end

      def help_text
        <<~HELP
          Usage: lowes chrome-start [--headless|--headed] [--port 9222] [--profile DIR]
                                    [--url URL] [--binary PATH]

          Launches Google Chrome with remote-debugging enabled and a
          dedicated user-data-dir. Subsequent `lowes` commands attach to
          this Chrome over CDP, so they use a real Chrome process and your
          real signed-in session — bypassing Lowe's "we can't sign you in
          right now" automation block.

          Sign in to Lowe's in the browser window once. Cookies persist in
          the profile dir, so you only need to do this once. Signing in needs
          a window, so `lowes login` always runs headed.

          Options:
            --headless     No window (the default). Adds a User-Agent override,
                           without which Akamai answers 403 Access Denied.
            --headed       Open a visible window.
            --port N       Remote-debugging port (default 9222)
            --profile DIR  Chrome user-data-dir (default ~/.local/share/lowes/cache/chrome-profile)
            --url URL      Initial page (default https://www.lowes.com/)
            --binary PATH  Chrome executable (default #{CHROME_APP})

          Config (~/.config/lowes/config.json):
            "browser": { "headless": false, "binary": "...", "user_agent": "..." }

          Environment:
            LOWES_HEADLESS=0   Force a visible window for one invocation.
        HELP
      end
    end
  end
end
