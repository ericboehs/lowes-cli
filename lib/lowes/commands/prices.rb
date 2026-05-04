require "time"

module Lowes
  module Commands
    class Prices
      def initialize(global)
        @global = global
      end

      def run(argv)
        only = nil
        while (a = argv.shift)
          case a
          when "--only" then only = argv.shift
          when "-h", "--help"
            puts <<~HELP
              Usage: lowes prices [--only nickname-or-model] [--json]

              Refreshes prices for every item in the materials list and appends
              each result to that item's local price history.
            HELP
            return 0
          else
            warn "unknown prices option: #{a}"
            return 2
          end
        end

        config = Lowes::Config.load
        store = Lowes::Store.new
        items = store.materials
        items = items.select { |m| [m["nickname"], m["model"], m["item_id"]].include?(only) } if only

        if items.empty?
          warn "no materials to price (add some with `lowes materials add ...`)"
          return 1
        end

        unless Lowes::Chrome.ensure_started(quiet: @global[:quiet])
          warn "prices: Chrome (CDP) didn't come up — try `lowes chrome-start` manually"
          return 1
        end
        worker = Lowes::Worker.new(verbose: @global[:verbose], quiet: @global[:quiet])
        results = worker.fetch_prices(items: items, store_zip: config.store_zip)

        results.each do |r|
          r["fetched_at"] ||= Time.now.utc.iso8601
          store.append_price(r)
        end
        Lowes::Formatter.new(json: @global[:json]).prices(results)
        0
      end
    end
  end
end
