require "lowes/client"

module Lowes
  module Commands
    class Quotes
      def initialize(global, online_client: nil)
        @global = global
        @online_client = online_client
      end

      def run(argv)
        action = argv.shift || "list"
        case action
        when "list"            then list(argv)
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
        id = argv.shift
        return missing("show") unless id
        Lowes::Config.load
        q = fetch_online_quote(id)
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
        return missing("delete") unless id
        Lowes::Config.load
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
        return missing("clone") unless src_id
        Lowes::Config.load
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
            puts "Usage: lowes quotes add <quote-id> <url|item-id> [--qty N]"
            return 0
          else
            if id.nil? then id = a else target ||= a end
          end
        end
        unless id && target
          warn "quotes add: <quote-id> and <url|item-id> are required"
          return 2
        end
        item_id = resolve_item_id(target)
        unless item_id
          warn "quotes add: pass a numeric item-id or a Lowe's product URL ending in /<digits>"
          return 2
        end
        Lowes::Config.load
        online_client.add_items(id, [{ "productInfo" => { "omniItemId" => item_id }, "quantity" => qty }])
        warn "added #{item_id} (qty #{qty}) to #{id}" unless @global[:quiet]
        0
      end

      def remove_item(argv)
        id = nil; line_id = nil; force = false
        while (a = argv.shift)
          case a
          when "-y", "--yes" then force = true
          when "-h", "--help"
            puts "Usage: lowes quotes remove <quote-id> <line-id> [-y]"
            return 0
          else
            if id.nil? then id = a else line_id ||= a end
          end
        end
        unless id && line_id
          warn "quotes remove: <quote-id> and <line-id> are required"
          return 2
        end
        Lowes::Config.load
        unless force
          $stderr.print "remove line #{line_id} from #{id}? [y/N] "
          return 0 unless %w[y yes].include?($stdin.gets&.strip&.downcase)
        end
        online_client.remove_item(id, line_id)
        warn "removed line #{line_id}" unless @global[:quiet]
        0
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
        return missing("set") unless id
        Lowes::Config.load
        online_client.update_quote(id, header) unless header.empty?
        qty_overrides.each { |line_id, n| online_client.update_item_quantity(id, line_id, n) }
        0
      end

      def refresh(argv)
        id = argv.shift
        return missing("refresh") unless id
        Lowes::Config.load
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

      def fetch_online_quote(id)
        detail = online_client.get_quote(id)["quoteDetail"] || {}
        online_quote_detail_to_quote(detail)
      rescue Lowes::Client::Error => e
        warn "quotes show: #{e.status || "?"} #{e.message}"
        nil
      end

      def online_quote_to_row(q)
        created = q["createdTs"] || q["createdAt"]
        {
          "quote_id" => q["quoteId"],
          "type"     => "online",
          "name"     => q["quoteDescription"],
          "status"   => q["displayQuoteStatus"] || q["quoteStatus"],
          "created"  => created,
          "date"     => created.to_s[0, 10],
          "total"    => q.dig("totals", "totalAmount")
        }
      end

      def online_quote_detail_to_quote(d)
        cs = d["cartSummary"] || {}
        items = (d["cartItems"] || {}).map do |line_id, it|
          pi = it["productInfo"] || {}
          summary = it["itemSummary"] || {}
          prices = ((it["priceInfo"] || {})["prices"] || []).each_with_object({}) { |p, h| h[p["priceType"]] = p["value"] }
          qty = it["quantity"].to_i

          # itemSummary is authoritative when present (each line carries its own
          # discount %; the cart-level pct is just a weighted average).
          unit_paid       = summary["unitPrice"]&.to_f         || prices["LAST_UNLOCK_PRICE"] || prices["FINAL"] || prices["BASE"]
          unit_list       = (summary["wasPrice"]&.to_f && qty > 0 ? summary["wasPrice"].to_f / qty : nil) || prices["FINAL"] || prices["BASE"] || prices["RETAIL"]
          line_total      = summary["subTotalAfterDisc"]&.to_f || (unit_paid && unit_paid * qty)
          line_total_list = summary["wasPrice"]&.to_f          || (unit_list && unit_list * qty)
          discount_pct    = summary["totalSavingsPercentage"]&.to_f
          discount_pct  ||= (unit_list && unit_paid && unit_list > 0) ? ((unit_list - unit_paid) / unit_list.to_f * 100).round(1) : 0.0

          {
            "line"               => line_id,
            "model"              => pi["modelNumber"] || pi["model"],
            "item_id"            => pi["itemNumber"] || pi["omniItemId"],
            "url"                => pi["pdUrl"],
            "title"              => pi["productName"] || pi["productDescription"],
            "image_url"          => pi["imageUrl"],
            "quantity"           => qty,
            "unit_price"         => unit_paid,
            "unit_price_list"    => unit_list,
            "discount_pct"       => discount_pct,
            "discount_amount"    => summary["discount"]&.to_f,
            "discounts"          => it["discounts"] || [],
            "line_total"         => line_total,
            "line_total_list"    => line_total_list
          }
        end
        vsp = d["vspSummary"] || {}
        {
          "quote_id"             => d["quoteId"],
          "type"                 => "online",
          "name"                 => d["quoteDescription"],
          "status"               => d["displayQuoteStatus"] || d["quoteStatus"],
          "notes"                => (d["comments"] || []).first&.dig("comment"),
          "created"              => d["createdTs"] || d["createdAt"],
          "items"                => items,
          "subtotal"             => cs["subtotal"]&.to_f,
          "subtotal_list"        => cs["subTotalWithOutDiscount"]&.to_f,
          "tax"                  => cs["totalSalesTax"]&.to_f,
          "total"                => cs["grandTotal"]&.to_f,
          "total_savings"        => cs["totalDiscount"]&.to_f || cs["totalSaving"]&.to_f,
          "savings_pct"          => cs["savingsPercentage"]&.to_f,
          "savings_summary"      => d["totalSavingSummary"] || [],
          "vsp_applied"          => d["vspApplied"],
          "vsp_to_qualify"       => vsp["toQualifyVSP"]&.to_f,
          "vsp_threshold"        => vsp["vspThreshold"]&.to_f,
          "vsp_qualify_pct"      => vsp["qualifiedVSPPercentage"]&.to_f
        }
      end

      def online_client
        @online_client ||= Lowes::Client.from_storage_state(auto_refresh: true)
      end

      # Accept a numeric item-id OR a Lowe's product URL whose path ends in /<digits>.
      def resolve_item_id(target)
        return target if target.match?(/\A\d{4,}\z/)
        if target.start_with?("http://", "https://")
          path = URI(target).path
          m = path.match(%r{/(\d{4,})/?\z})
          return m[1] if m
        end
        nil
      end

      def missing(action)
        warn "quotes #{action}: quote id required"
        2
      end

      def help_text
        <<~HELP
          Usage: lowes quotes <subcommand> [options]

          list                              list quotes from lowes.com
          show <id>                         show one quote
          new --name NAME [--note ...] [--po ...]
                                            create a new empty quote
          delete <id> [-y]                  delete a quote
          clone <id> [--name NAME]          duplicate a quote
          add <id> <url|item-id> [--qty N]  add a line item
          remove <id> <line-id> [-y]        remove a line item
          set <id> [--name ...] [--note ...] [--po ...] [--qty LINE_ID=N ...]
                                            update quote header / line quantity
          refresh <id>                      re-price a quote on lowes.com
          refresh-cookies                   pull fresh session cookies from Chrome
        HELP
      end
    end
  end
end
