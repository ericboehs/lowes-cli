module Lowes
  module Commands
    class List
      def initialize(global)
        @global = global
      end

      def run(argv)
        year = nil
        limit = nil
        while (a = argv.shift)
          case a
          when "--year"  then year = Integer(argv.shift)
          when "--limit" then limit = Integer(argv.shift)
          when "-h", "--help"
            puts help_text
            return 0
          else
            warn "unknown list option: #{a}"
            return 2
          end
        end

        Lowes::Config.load
        store = Lowes::Store.new
        rows = store.list_orders(year: year, limit: limit)
        Lowes::Formatter.new(json: @global[:json]).list(rows)
        0
      end

      private

      def help_text
        <<~HELP
          Usage: lowes list [options]

          Options:
            --year YYYY    Limit to one year
            --limit N      Show only the most recent N orders
            --json         JSON output
        HELP
      end
    end
  end
end
