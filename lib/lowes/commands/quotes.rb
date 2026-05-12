require "lowes/client"
require "lowes/quote_adapter"

module Lowes
  module Commands
    class Quotes
      def initialize(global, online_client: nil)
        @global = global
        @online_client = online_client
      end

      def run(argv)
        action = argv.shift || default_action
        case action
        when "list"            then list(argv)
        when "pick"            then pick(argv)
        when "show"            then show(argv)
        when "new"             then create(argv)
        when "delete"          then delete(argv)
        when "clone"           then clone(argv)
        when "add"             then add_item(argv)
        when "remove"          then remove_item(argv)
        when "set"             then set_fields(argv)
        when "refresh"         then refresh(argv)
        when "refresh-cookies" then refresh_cookies(argv)
        when "-h", "--help", "help"
          puts help_text
          0
        else
          show([action, *argv])
        end
      end

      private

      # Bare `lowes quotes` is a picker when interactive + fzf is around.
      # Otherwise (pipes, scripts, --json, no fzf) fall through to plain list.
      def default_action
        return "list" if @global[:json]
        return "list" unless $stdin.tty? && $stdout.tty?
        return "list" unless fzf_path
        "pick"
      end

      def fzf_path
        @fzf_path ||= ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
                                 .map { |d| File.join(d, "fzf") }
                                 .find { |p| File.executable?(p) }
      end

      def pick(_argv)
        Lowes::Config.load
        rows = (online_client.search["quotes"] || []).map { |q| online_quote_to_row(q) }
                                                     .sort_by { |r| r["created"].to_s }.reverse
        return puts("(no quotes)") if rows.empty?

        chosen_id = fzf_pick_quote(rows)
        return 0 unless chosen_id
        show([chosen_id])
      end

      def fzf_pick_quote(rows)
        # Tab-separated lines: id is hidden in column 1, display columns follow.
        # fzf's --with-nth/--delimiter shows columns 2.. while preserving column 1
        # for selection; --print-query keeps it scriptable later.
        lines = rows.map { |r|
          [r["quote_id"], r["date"], r["status"].to_s.ljust(14), Lowes::Formatter.new.send(:format_money, r["total"]).rjust(10), r["name"].to_s].join("\t")
        }.join("\n")

        IO.popen([fzf_path, "--delimiter=\t", "--with-nth=2..", "--ansi",
                  "--prompt=quote> ", "--header=date        status         total       name",
                  "--height=40%", "--reverse"], "r+") do |io|
          io.write(lines)
          io.close_write
          choice = io.read.to_s.strip
          choice.empty? ? nil : choice.split("\t", 2).first
        end
      end

      def list(argv)
        limit = nil
        status = nil
        while (a = argv.shift)
          case a
          when "--limit"  then limit = Integer(argv.shift)
          when "--status" then status = argv.shift
          when "-h", "--help"
            puts "Usage: lowes quotes list [--status STATUS] [--limit N] [--json]"
            return 0
          end
        end
        Lowes::Config.load
        rows = (online_client.search["quotes"] || []).map { |q| online_quote_to_row(q) }
        rows.select! { |r| r["status"].to_s.casecmp(status).zero? } if status
        rows.sort_by! { |r| r["created"].to_s }.reverse!
        rows = rows.first(limit) if limit
        Lowes::Formatter.new(json: @global[:json]).quotes(rows)
        0
      end

      def show(argv)
        id = nil
        do_refresh = false
        while (a = argv.shift)
          case a
          when "--refresh" then do_refresh = true
          when "-h", "--help"
            puts "Usage: lowes quotes show <id> [--refresh]"
            return 0
          else
            id ||= a
          end
        end
        return missing("show") unless id
        Lowes::Config.load
        try_refresh(id) if do_refresh
        q = fetch_online_quote(id)

        if q && !do_refresh && q["status"].to_s.upcase == "EXPIRED" && $stdin.tty? && !@global[:json]
          $stderr.print "quote is expired — refresh? [Y/n] "
          ans = $stdin.gets&.strip&.downcase
          if ans.nil? || ans.empty? || %w[y yes].include?(ans)
            try_refresh(id) and q = fetch_online_quote(id)
          end
        end

        Lowes::Formatter.new(json: @global[:json]).quote(q)
        q ? 0 : 1
      end

      def create(argv)
        name = nil; note = ""; po = ""
        while (a = argv.shift)
          case a
          when "--name" then name = argv.shift
          when "--note" then note = argv.shift
          when "--po"   then po = argv.shift
          when "-h", "--help"
            puts "Usage: lowes quotes new --name NAME [--note ...] [--po PO]"
            return 0
          end
        end
        unless name
          warn "quotes new: --name required"
          return 2
        end
        Lowes::Config.load
        q = online_client.create_quote(description: name, po_number: po, comment: note)["onlineQuote"] || {}
        @global[:json] ? puts(JSON.pretty_generate(q)) : puts(q["quoteId"])
        0
      end

      def delete(argv)
        id = nil; force = false
        while (a = argv.shift)
          case a
          when "-y", "--yes" then force = true
          when "-h", "--help"
            puts "Usage: lowes quotes delete <id> [-y]"
            return 0
          else
            id ||= a
          end
        end
        Lowes::Config.load
        id ||= pick_quote_id_interactive
        return missing("delete") unless id
        unless force
          $stderr.print "delete quote #{id}? [y/N] "
          return 0 unless %w[y yes].include?($stdin.gets&.strip&.downcase)
        end
        online_client.delete_quote(id)
        warn "deleted #{id}" unless @global[:quiet]
        0
      end

      def clone(argv)
        src_id = nil; new_name = nil
        while (a = argv.shift)
          case a
          when "--name" then new_name = argv.shift
          when "-h", "--help"
            puts "Usage: lowes quotes clone <id> [--name NAME]"
            return 0
          else
            src_id ||= a
          end
        end
        Lowes::Config.load
        src_id ||= pick_quote_id_interactive
        return missing("clone") unless src_id
        resp = online_client.duplicate_quote(src_id, description: new_name.to_s)
        q = resp["onlineQuote"] || resp
        @global[:json] ? puts(JSON.pretty_generate(q)) : puts(q["quoteId"])
        0
      end

      def add_item(argv)
        id = nil; target = nil; qty = 1
        while (a = argv.shift)
          case a
          when "--qty" then qty = Integer(argv.shift)
          when "-h", "--help"
            puts "Usage: lowes quotes add [<quote-id>] <url|item-id> [--qty N]"
            return 0
          else
            if id.nil? then id = a else target ||= a end
          end
        end

        # Single positional that looks like a URL → treat as target, pick the quote.
        if id && target.nil? && url_like?(id)
          target = id
          id = nil
        end

        unless target
          warn "quotes add: <url|item-id> is required"
          return 2
        end

        item_id = resolve_item_id(target)
        unless item_id
          warn "quotes add: pass a numeric omniItemId or a Lowe's product URL (e.g. lowes.com/pd/<slug>/<digits>)"
          return 2
        end

        Lowes::Config.load

        unless id
          id = pick_quote_id_interactive
          unless id
            warn "quotes add: <quote-id> is required (or run interactively with fzf)"
            return 2
          end
        end

        online_client.add_items(id, [{ "productInfo" => { "omniItemId" => item_id }, "quantity" => qty }])
        warn "added #{item_id} (qty #{qty}) to #{id}" unless @global[:quiet]
        0
      end

      def url_like?(s)
        s.to_s.start_with?("http://", "https://") || s =~ %r{\A(?:www\.)?lowes\.com/}i
      end

      def pick_quote_id_interactive
        return nil unless $stdin.tty? && $stdout.tty? && fzf_path
        rows = (online_client.search["quotes"] || []).map { |q| online_quote_to_row(q) }
                                                     .sort_by { |r| r["created"].to_s }.reverse
        return nil if rows.empty?
        fzf_pick_quote(rows)
      end

      def remove_item(argv)
        id = nil; line_id = nil; force = false
        while (a = argv.shift)
          case a
          when "-y", "--yes" then force = true
          when "-h", "--help"
            puts "Usage: lowes quotes remove [<quote-id>] [<line-id>] [-y]"
            return 0
          else
            if id.nil? then id = a else line_id ||= a end
          end
        end

        Lowes::Config.load
        id ||= pick_quote_id_interactive
        unless id
          warn "quotes remove: <quote-id> is required"
          return 2
        end

        line_id ||= pick_line_id_interactive(id)
        unless line_id
          warn "quotes remove: <line-id> is required"
          return 2
        end

        unless force
          $stderr.print "remove line #{line_id} from #{id}? [y/N] "
          return 0 unless %w[y yes].include?($stdin.gets&.strip&.downcase)
        end
        online_client.remove_item(id, line_id)
        warn "removed line #{line_id}" unless @global[:quiet]
        0
      end

      def pick_line_id_interactive(quote_id)
        return nil unless $stdin.tty? && $stdout.tty? && fzf_path
        q = fetch_online_quote(quote_id)
        return nil unless q
        items = q["items"] || []
        return nil if items.empty?
        fzf_pick_line(items)
      end

      def fzf_pick_line(items)
        f = Lowes::Formatter.new
        lines = items.map { |it|
          qty   = "x#{it["quantity"]}".ljust(5)
          unit  = f.send(:format_money, it["unit_price"]).rjust(10)
          title = it["title"].to_s
          [it["line"], qty, unit, title].join("\t")
        }.join("\n")

        IO.popen([fzf_path, "--delimiter=\t", "--with-nth=2..", "--ansi",
                  "--prompt=line> ", "--header=qty    unit       item",
                  "--height=40%", "--reverse"], "r+") do |io|
          io.write(lines)
          io.close_write
          choice = io.read.to_s.strip
          choice.empty? ? nil : choice.split("\t", 2).first
        end
      end

      def set_fields(argv)
        id = nil
        header = {}
        qty_overrides = {}
        while (a = argv.shift)
          case a
          when "--name" then header["quoteDescription"] = argv.shift
          when "--note" then header["comment"] = argv.shift
          when "--po"   then header["poNumber"] = argv.shift
          when "--qty"
            line, n = argv.shift.split("=", 2)
            qty_overrides[line] = Integer(n)
          when "-h", "--help"
            puts "Usage: lowes quotes set <id> [--name ...] [--note ...] [--po ...] [--qty LINE_ID=N ...]"
            return 0
          else
            id ||= a
          end
        end
        Lowes::Config.load
        id ||= pick_quote_id_interactive
        return missing("set") unless id
        online_client.update_quote(id, header) unless header.empty?
        qty_overrides.each { |line_id, n| online_client.update_item_quantity(id, line_id, n) }
        0
      end

      def refresh(argv)
        id = argv.shift
        Lowes::Config.load
        id ||= pick_quote_id_interactive
        return missing("refresh") unless id
        online_client.refresh_quote(id)
        warn "refreshed #{id}" unless @global[:quiet]
        0
      end

      def refresh_cookies(_argv)
        Lowes::Config.load
        n = Lowes::Client.refresh_cookies!
        puts "refreshed #{n} cookies" unless @global[:quiet]
        0
      end

      def try_refresh(id)
        online_client.refresh_quote(id)
        true
      rescue Lowes::Client::Error => e
        warn "quotes refresh: #{e.status || "?"} #{e.message[0, 200]}"
        false
      end

      def fetch_online_quote(id)
        detail = online_client.get_quote(id)["quoteDetail"] || {}
        online_quote_detail_to_quote(detail)
      rescue Lowes::Client::Error => e
        warn "quotes show: #{e.status || "?"} #{e.message}"
        nil
      end

      def online_quote_to_row(q)        = Lowes::QuoteAdapter.to_row(q)
      def online_quote_detail_to_quote(d) = Lowes::QuoteAdapter.detail_to_quote(d)

      def online_client
        @online_client ||= Lowes::Client.from_storage_state(auto_refresh: true)
      end

      # Accept a numeric omniItemId OR a Lowe's product URL whose path ends in /<digits>.
      # Handles bare hosts ("lowes.com/pd/...") by assuming https, strips query/fragment,
      # and unwraps `lowes.com/redir?u=<encoded-url>` share links.
      def resolve_item_id(target)
        target = target.to_s.strip
        return nil if target.empty?
        return target if target.match?(/\A\d{4,}\z/)

        url = target
        url = "https://#{url}" if url =~ %r{\A(?:www\.)?lowes\.com/}i

        return nil unless url.start_with?("http://", "https://")

        uri = URI(url)
        if uri.path == "/redir" && uri.query
          inner = URI.decode_www_form(uri.query).assoc("u")&.last
          return resolve_item_id(inner) if inner
        end

        m = uri.path.match(%r{/(\d{4,})/?\z})
        m && m[1]
      rescue URI::InvalidURIError
        nil
      end

      def missing(action)
        warn "quotes #{action}: quote id required"
        2
      end

      def help_text
        <<~HELP
          Usage: lowes quotes <subcommand> [options]

          (no args)                         fzf picker if interactive, else list
          list                              list quotes from lowes.com (always)
          pick                              fzf picker (errors if fzf missing)
          show <id> [--refresh]             show one quote (auto-prompts on EXPIRED)
          new --name NAME [--note ...] [--po ...]
                                            create a new empty quote
          delete [<id>] [-y]                delete a quote (fzf-picks if no id)
          clone [<id>] [--name NAME]        duplicate a quote (fzf-picks if no id)
          add [<id>] <url|item-id> [--qty N]
                                            add a line item (fzf-picks if no id)
          remove [<id>] [<line-id>] [-y]    remove a line item (fzf-picks both)
          set [<id>] [--name ...] [--note ...] [--po ...] [--qty LINE_ID=N ...]
                                            update quote header / line quantity
          refresh [<id>]                    re-price a quote on lowes.com
          refresh-cookies                   pull fresh session cookies from Chrome
        HELP
      end
    end
  end
end
