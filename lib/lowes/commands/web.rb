module Lowes
  module Commands
    class Web
      def initialize(global)
        @global = global
      end

      def run(argv)
        port = nil
        while (a = argv.shift)
          case a
          when "--port" then port = Integer(argv.shift)
          when "-h", "--help"
            puts <<~HELP
              Usage: lowes web [--port 4567]

              Launches a local Sinatra app at http://127.0.0.1:4567 that
              browses cached orders, quotes, materials, and price history.
            HELP
            return 0
          end
        end

        web_path = File.expand_path("../../../web.rb", __dir__)
        env = port ? { "PORT" => port.to_s } : {}
        # Process.exec replaces this Ruby process with the web app. No shell
        # is invoked — args are passed directly to execve(2).
        Process.exec(env, RbConfig.ruby, web_path)
      end
    end
  end
end
