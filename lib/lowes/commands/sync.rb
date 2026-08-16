require "date"
require "open3"
require "time"

module Lowes
  module Commands
    class Sync
      # How often the index is written out mid-run. The order files are the
      # slow part and are already on disk; this only bounds how many of them
      # a hard kill can leave unreadable, and the next sync re-fetches those
      # anyway. Small enough that the loss is a rounding error, large enough
      # not to rewrite the whole index once per order.
      INDEX_FLUSH_EVERY = 25

      # `worker:` is injectable for the same reason `Commands::Quotes` takes an
      # `online_client:` — what happens to the store between the first order and
      # the last is the behavior worth testing, and reaching it for real means
      # Chrome, a login, and half an hour of scraping.
      def initialize(global, worker: nil)
        @global = global
        @worker = worker
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
        worker = @worker || Lowes::Worker.new(verbose: @global[:verbose], quiet: @global[:quiet])

        # Written as they arrive rather than collected and written at the end.
        # A full sync is half an hour of scraping, and buffering it meant an
        # interrupted run kept nothing at all — two stops in one session cost
        # 43 and 67 orders of work that had already been fetched. Nothing here
        # is unsafe to write early: `write_order` is idempotent per order and
        # refuses to shrink one, so the partial store is a smaller version of
        # the same result, not a different one.
        written = 0
        begin
          worker.sync(
            email: config.email,
            password: password,
            years: years,
            full_details: full_details,
            otp_secret: otp_secret,
            rate_limit: config.rate_limit,
            known_order_ids: known_ids,
            stored_order_dates: store.index["orders"].values.filter_map { |m| m["date"] }
          ) do |order|
            store.write_order(order, detailed: full_details)
            written += 1
            store.flush_index! if (written % INDEX_FLUSH_EVERY).zero?
          end
        ensure
          # An order whose file exists but whose index entry does not is an
          # order nothing can read, so the index gets flushed on the way out
          # however the run ends. `last_sync` is left alone unless the run
          # actually finished — see below.
          store.flush_index!
        end
        store.commit_index!

        append_sync_log(years, written)
        log "wrote #{written} orders to #{Lowes::Config.orders_dir}"
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
