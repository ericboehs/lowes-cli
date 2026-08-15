require "open3"
require "json"

module Lowes
  module Commands
    class Login
      PYWORKER = File.expand_path("../../../pyworker", __dir__)

      def initialize(global)
        @global = global
      end

      def run(argv)
        while (a = argv.shift)
          case a
          when "-h", "--help"
            puts <<~HELP
              Usage: lowes login

              Opens a real browser window so you can log in to Lowes.com manually
              (solving any captcha or 2FA). Cookies + storage state are saved so
              subsequent `lowes sync` calls reuse the session.

              Always headed — if the shared Chrome is currently running headless
              it is restarted with a window first.
            HELP
            return 0
          end
        end

        Lowes::Config.ensure_dirs!
        # Headed, always: this is the one command where a person types into the
        # window. Everything else runs headless.
        unless Lowes::Chrome.ensure_headed(quiet: @global[:quiet])
          warn "login: Chrome (CDP) didn't come up — try `lowes chrome-start --headed` manually"
          return 1
        end
        venv = File.join(PYWORKER, ".venv", "bin", "python")
        python = File.executable?(venv) ? venv : "python3"

        Open3.popen3(python, "login.py", chdir: PYWORKER) do |stdin, stdout, stderr, wait|
          stdin.close
          err_thread = Thread.new do
            stderr.each_line { |l| warn(l.chomp) if @global[:verbose] }
          rescue IOError
          end
          stdout.each_line do |line|
            line = line.strip
            next if line.empty?
            event = (JSON.parse(line) rescue nil)
            next unless event

            case event["event"]
            when "log"      then warn(event["msg"]) unless @global[:quiet]
            when "navigate" then warn("→ #{event["url"]}") unless @global[:quiet]
            when "done"
              warn("lowes: saved #{event["count"]} cookies to #{event["cookies_path"]}")
              warn("       run `lowes sync` to fetch orders.")
            when "error"
              warn("lowes login: #{event["msg"]}")
            end
          end
          err_thread.join
          return wait.value.exitstatus
        end
      end
    end
  end
end
