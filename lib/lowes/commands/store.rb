require "json"

module Lowes
  module Commands
    class Store
      def initialize(global)
        @global = global
      end

      def run(argv)
        action = argv.shift || "show"
        case action
        when "show", "-h", "--help"
          show
        when "set"
          set_store(argv)
        else
          # Allow `lowes store 73703` shorthand for `lowes store set 73703`
          if action.match?(/\A\d{5}\z/)
            set_store([action, *argv])
          else
            warn "unknown store action: #{action}"
            warn help_text
            2
          end
        end
      end

      private

      def show
        Lowes::Config.load
        unless Lowes::Chrome.ensure_started(quiet: @global[:quiet])
          warn "store: Chrome (CDP) didn't come up — try `lowes chrome-start` manually"
          return 1
        end
        worker = Lowes::Worker.new(verbose: @global[:verbose], quiet: @global[:quiet])
        worker.run_action(action: "show_store")
        0
      end

      def set_store(argv)
        zip = nil
        while (a = argv.shift)
          case a
          when "--zip" then zip = argv.shift
          when "-h", "--help"
            puts help_text
            return 0
          else
            zip ||= a
          end
        end

        config = Lowes::Config.load
        zip ||= config.store_zip
        unless zip&.match?(/\A\d{5}\z/)
          warn "store set: 5-digit ZIP required (got #{zip.inspect})"
          warn "  pass as `lowes store 73703` or set `store_zip` in config"
          return 2
        end

        unless Lowes::Chrome.ensure_started(quiet: @global[:quiet])
          warn "store set: Chrome (CDP) didn't come up — try `lowes chrome-start` manually"
          return 1
        end
        worker = Lowes::Worker.new(verbose: @global[:verbose], quiet: @global[:quiet])
        worker.run_action(action: "set_store", zip: zip)

        # Persist as the new default in config so `lowes store` later works without args.
        update_config_zip(zip)
        warn "saved store_zip=#{zip} to config"
        0
      end

      def update_config_zip(zip)
        path = Lowes::Config.config_path
        return unless File.exist?(path)
        data = JSON.parse(File.read(path))
        return if data["store_zip"] == zip
        data["store_zip"] = zip
        File.write(path, JSON.pretty_generate(data) + "\n")
      end

      def help_text
        <<~HELP
          Usage: lowes store [show|set <ZIP>]

          show:
            lowes store           # print current Lowe's store cookies (sn, region, etc.)

          set:
            lowes store 73703     # change My Store to first Lowe's near ZIP 73703
            lowes store set 73703 # explicit form
            lowes store set       # use config.store_zip

          The `set` form drives Lowe's store-finder UI in your CDP-attached
          Chrome (started by `lowes chrome-start`) and clicks "Set as My
          Store" on the first matching result.
        HELP
      end
    end
  end
end
