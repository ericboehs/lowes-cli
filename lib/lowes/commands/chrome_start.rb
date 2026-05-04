require "fileutils"
require "open3"
require "shellwords"

module Lowes
  module Commands
    class ChromeStart
      CHROME_APP = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome".freeze
      DEFAULT_PORT = 9222
      DEFAULT_PROFILE_DIR = "#{Dir.home}/.local/share/lowes/cache/chrome-profile".freeze

      def initialize(global = {})
        @global = global || {}
        @quiet = @global[:quiet] || @global[:silent]
      end

      def run(argv)
        port = DEFAULT_PORT
        profile = DEFAULT_PROFILE_DIR
        url = "https://www.lowes.com/"
        while (a = argv.shift)
          case a
          when "--port"    then port = Integer(argv.shift)
          when "--profile" then profile = argv.shift
          when "--url"     then url = argv.shift
          when "-h", "--help"
            puts help_text
            return 0
          end
        end

        unless File.exist?(CHROME_APP)
          warn "lowes chrome-start: Google Chrome not found at #{CHROME_APP}"
          warn "  install Chrome, or pass --binary /path/to/chrome"
          return 1
        end

        FileUtils.mkdir_p(profile)
        cmd = [
          CHROME_APP,
          "--remote-debugging-port=#{port}",
          "--user-data-dir=#{profile}",
          "--no-default-browser-check",
          "--no-first-run",
          url
        ]

        warn "starting Chrome with debugging on port #{port}"
        warn "  profile: #{profile}"
        warn "  sign in to Lowe's in this window, then run `lowes login` (or any command) in another terminal"
        warn ""
        warn "  command: #{cmd.shelljoin}"

        # Detach so the parent shell can exit. Chrome stays running.
        pid = Process.spawn(*cmd, [:out, :err] => "/dev/null")
        Process.detach(pid)
        warn "started chrome (pid=#{pid})"
        0
      end

      private

      def help_text
        <<~HELP
          Usage: lowes chrome-start [--port 9222] [--profile DIR] [--url URL]

          Launches Google Chrome with remote-debugging enabled and a
          dedicated user-data-dir. Subsequent `lowes` commands attach to
          this Chrome over CDP, so they use a real Chrome process and your
          real signed-in session — bypassing Lowe's "we can't sign you in
          right now" automation block.

          Sign in to Lowe's in the browser window once. Cookies persist in
          the profile dir, so you only need to do this once.

          Options:
            --port N       Remote-debugging port (default 9222)
            --profile DIR  Chrome user-data-dir (default ~/.local/share/lowes/cache/chrome-profile)
            --url URL      Initial page (default https://www.lowes.com/)
        HELP
      end
    end
  end
end
