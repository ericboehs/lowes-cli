require "time"

module Lowes
  module Commands
    class Price
      def initialize(global)
        @global = global
      end

      def run(argv)
        target = nil
        history = false
        while (a = argv.shift)
          case a
          when "--history" then history = true
          when "-h", "--help"
            puts <<~HELP
              Usage: lowes price <url|model|item-id> [--history] [--json]

              Fetches the current price for a single product. Records the result
              in the local price history (~/.local/share/lowes/prices/<key>.ndjson).

              Use --history to print all stored price points for the key without
              hitting the network.
            HELP
            return 0
          else
            target ||= a
          end
        end

        unless target
          warn "price: url, model, or item-id is required"
          return 2
        end

        config = Lowes::Config.load
        store = Lowes::Store.new

        if history
          rows = store.price_history(target)
          Lowes::Formatter.new(json: @global[:json]).prices(rows)
          return 0
        end

        item = parse_target(target)
        unless Lowes::Chrome.ensure_started(quiet: @global[:quiet])
          warn "price: Chrome (CDP) didn't come up — try `lowes chrome-start` manually"
          return 1
        end
        worker = Lowes::Worker.new(verbose: @global[:verbose], quiet: @global[:quiet])
        results = worker.fetch_prices(items: [item], store_zip: config.store_zip)

        results.each do |r|
          r["fetched_at"] ||= Time.now.utc.iso8601
          store.append_price(r)
        end
        Lowes::Formatter.new(json: @global[:json]).prices(results)
        results.empty? ? 1 : 0
      end

      private

      def parse_target(target)
        if target.start_with?("http://", "https://")
          { "url" => target }
        elsif target.match?(/\A\d{6,}\z/)
          { "item_id" => target }
        else
          { "model" => target }
        end
      end
    end
  end
end
