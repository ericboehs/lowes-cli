require "date"
require "open3"
require "time"

module Lowes
  module Commands
    class Sync
      def initialize(global)
        @global = global
      end

      def run(argv)
        years = nil
        full_details = true
        full_resync = false
        while (a = argv.shift)
          case a
          when "--year"  then years = [Integer(argv.shift)]
          when "--years" then years = argv.shift.split(",").map { |y| Integer(y) }
          when "--no-full-details" then full_details = false
          when "--full"  then full_resync = true
          when "-h", "--help"
            puts help_text
            return 0
          else
            warn "unknown sync option: #{a}"
            return 2
          end
        end

        config = Lowes::Config.load
        years ||= default_years(config)

        unless Lowes::Chrome.ensure_started(quiet: @global[:quiet])
          warn "sync: Chrome (CDP) didn't come up — try `lowes chrome-start` manually"
          return 1
        end

        password, otp_secret = resolve_credentials(config)
        return 2 if password == :missing

        store = Lowes::Store.new
        known_ids = full_resync ? [] : store.index["orders"].keys

        log "syncing years: #{years.join(", ")}#{full_resync ? " (full re-sync)" : " (skipping #{known_ids.size} known)"}"
        worker = Lowes::Worker.new(verbose: @global[:verbose], quiet: @global[:quiet])
        orders = worker.sync(
          email: config.email,
          password: password,
          years: years,
          full_details: full_details,
          otp_secret: otp_secret,
          rate_limit: config.rate_limit,
          known_order_ids: known_ids
        )

        orders.each { |o| store.write_order(o, detailed: full_details) }
        store.commit_index!

        append_sync_log(years, orders.size)
        log "wrote #{orders.size} orders to #{Lowes::Config.orders_dir}"
        0
      end

      private

      def resolve_credentials(config)
        if cookies_authenticated?
          log "using cached browser session (skipping 1Password prompt)"
          return ["unused-have-cookies", nil]
        end

        unless config.password_op_ref
          warn "config: password_op_ref must be set, or run `lowes login` first"
          return [:missing, nil]
        end
        password = fetch_password(config.password_op_ref)
        otp = config.otp_op_ref ? fetch_password(config.otp_op_ref) : nil
        [password, otp]
      end

      def default_years(config)
        n = config.default_year_window || 5
        cur = Date.today.year
        ((cur - n + 1)..cur).to_a
      end

      def cookies_authenticated?
        path = Lowes::Config.cache_dir.join("storage_state.json")
        path.exist?
      end

      def fetch_password(ref)
        out, err, status = Open3.capture3("bash", "-lc", "op signin --account my >/dev/null && op read #{shellword(ref)}")
        unless status.success?
          raise "op read failed for #{ref}: #{err.strip}"
        end
        out.chomp
      end

      def shellword(s)
        "'" + s.gsub("'", "'\\''") + "'"
      end

      def append_sync_log(years, count)
        path = Lowes::Config.sync_log_path
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, "a") do |f|
          f.puts "#{Time.now.utc.iso8601}  years=#{years.join(",")}  count=#{count}"
        end
      end

      def log(msg)
        warn(msg) unless @global[:quiet]
      end

      def help_text
        <<~HELP
          Usage: lowes sync [options]

          Options:
            --year YYYY          Sync a single year
            --years 2024,2025    Sync multiple years (comma-separated)
            --no-full-details    Skip per-order detail fetches (faster, fewer fields)
            --full               Re-fetch every order (default: skip orders already in store)
        HELP
      end
    end
  end
end
