module Lowes
  module Commands
    class Show
      def initialize(global)
        @global = global
      end

      def run(argv)
        order_id = nil
        while (a = argv.shift)
          case a
          when "-h", "--help"
            puts "Usage: lowes show <order-id> [--json]"
            return 0
          else
            order_id ||= a
          end
        end

        unless order_id
          warn "show: order id is required"
          return 2
        end

        Lowes::Config.load
        store = Lowes::Store.new
        order = store.read_order(order_id)
        Lowes::Formatter.new(json: @global[:json]).show(order)
        order ? 0 : 1
      end
    end
  end
end
