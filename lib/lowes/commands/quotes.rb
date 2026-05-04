require "open3"

module Lowes
  module Commands
    class Quotes
      def initialize(global)
        @global = global
      end

      def run(argv)
        action = argv.shift || "list"
        case action
        when "list"  then list(argv)
        when "show"  then show(argv)
        when "sync"  then sync(argv)
        when "-h", "--help", "help"
          puts help_text
          0
        else
          # Treat as "show <quote_id>" if it looks like one
          show([action, *argv])
        end
      end

      private

      def list(argv)
        limit = nil
        while (a = argv.shift)
          case a
          when "--limit" then limit = Integer(argv.shift)
          when "-h", "--help"
            puts "Usage: lowes quotes list [--limit N] [--json]"
            return 0
          end
        end
        Lowes::Config.load
        rows = Lowes::Store.new.list_quotes(limit: limit)
        Lowes::Formatter.new(json: @global[:json]).quotes(rows)
        0
      end

      def show(argv)
        id = argv.shift
        unless id
          warn "quotes show: quote id required"
          return 2
        end
        Lowes::Config.load
        q = Lowes::Store.new.read_quote(id)
        Lowes::Formatter.new(json: @global[:json]).quote(q)
        q ? 0 : 1
      end

      def sync(_argv)
        config = Lowes::Config.load
        store = Lowes::Store.new

        unless Lowes::Chrome.ensure_started(quiet: @global[:quiet])
          warn "quotes sync: Chrome (CDP) didn't come up — try `lowes chrome-start` manually"
          return 1
        end

        password, otp_secret = resolve_credentials(config)
        return 2 if password == :missing

        worker = Lowes::Worker.new(verbose: @global[:verbose], quiet: @global[:quiet])
        quotes = worker.sync_quotes(email: config.email, password: password, otp_secret: otp_secret)
        quotes.each { |q| store.write_quote(q) }
        store.commit_index!
        warn "wrote #{quotes.size} quotes to #{Lowes::Config.quotes_dir}" unless @global[:quiet]
        0
      end

      def resolve_credentials(config)
        path = Lowes::Config.cache_dir.join("storage_state.json")
        return ["unused-have-cookies", nil] if path.exist?

        unless config.password_op_ref
          warn "config: password_op_ref must be set, or run `lowes login` first"
          return [:missing, nil]
        end
        out, err, status = Open3.capture3(
          "bash", "-lc",
          "op signin --account my >/dev/null && op read '#{config.password_op_ref.gsub("'", "'\\''")}'"
        )
        raise "op read failed: #{err.strip}" unless status.success?
        otp = nil
        if config.otp_op_ref
          otp_out, _otp_err, otp_st = Open3.capture3("bash", "-lc", "op read '#{config.otp_op_ref.gsub("'", "'\\''")}'")
          otp = otp_out.chomp if otp_st.success?
        end
        [out.chomp, otp]
      end

      def help_text
        <<~HELP
          Usage: lowes quotes <list|show|sync> [options]

          list:
            lowes quotes list [--limit N] [--json]
          show:
            lowes quotes show <quote-id> [--json]
          sync:
            lowes quotes sync
        HELP
      end
    end
  end
end
