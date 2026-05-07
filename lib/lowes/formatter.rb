require "json"

module Lowes
  class Formatter
    BOLD = "\e[1m"
    DIM  = "\e[2m"
    RST  = "\e[0m"

    def initialize(json: false, color: $stdout.tty?)
      @json = json
      @color = color
    end

    def list(rows)
      return puts(JSON.pretty_generate(rows)) if @json
      return puts("(no orders — run `lowes sync`)") if rows.empty?

      headers = %w[date order_id total status]
      data = rows.map { |r| [r["date"], r["order_id"], format_money(r["total"]), r["status"] || ""] }
      print_table(headers, data)
    end

    def show(order)
      return puts(JSON.pretty_generate(order)) if @json
      return puts("(not found)") unless order

      puts "#{bold("Order")} #{order["order_id"]}"
      puts "  Placed:  #{order["order_placed"]}"
      puts "  Status:  #{order["status"]}" if order["status"]
      puts "  Total:   #{format_money(effective_total(order))}"
      puts "  Ship to: #{order["ship_to"]}" if order["ship_to"]
      puts "  Store:   #{order["store"]}"   if order["store"]
      puts "  Payment: #{order["payment_method"]} #{order["payment_method_last_4"] ? "•••• #{order["payment_method_last_4"]}" : ""}".rstrip if order["payment_method"]
      if (link = order["order_details_link"])
        puts "  Link:    #{link}"
      end

      items = order["items"] || []
      puts
      puts bold("Items (#{items.size})")
      items.each do |it|
        title = it["title"].to_s
        qty   = it["quantity"] ? "x#{it["quantity"]} " : ""
        price = it["price"] ? " — #{format_money(it["price"])}" : ""
        model = it["model"] ? " [#{it["model"]}]" : ""
        puts "  • #{qty}#{title}#{model}#{price}"
        puts dim("    #{it["link"]}") if it["link"]
      end
    end

    def search(orders, query)
      return puts(JSON.pretty_generate(orders)) if @json
      return puts("(no matches for #{query.inspect})") if orders.empty?

      orders.each do |o|
        items = o["items"] || []
        first = items.find { |i| i["title"].to_s.downcase.include?(query.downcase) } || items.first
        title = first ? first["title"] : "(no items)"
        puts "#{o["order_placed"]}  #{o["order_id"]}  #{format_money(effective_total(o))}  #{title}"
      end
    end

    def quotes(rows)
      return puts(JSON.pretty_generate(rows)) if @json
      return puts("(no quotes — run `lowes quotes sync`)") if rows.empty?

      headers = %w[date type quote_id name total status]
      data = rows.map { |r| [r["date"], r["type"] || "online", r["quote_id"], r["name"].to_s[0, 40], format_money(r["total"]), r["status"] || ""] }
      print_table(headers, data)
    end

    def quote(q)
      return puts(JSON.pretty_generate(q)) if @json
      return puts("(not found)") unless q

      puts "#{bold("Quote")} #{q["quote_id"]} #{dim("[#{q["type"] || "online"}]")}"
      puts "  Name:    #{q["name"]}"          if q["name"]
      puts "  Created: #{q["created"]}"
      puts "  Status:  #{q["status"]}"        if q["status"]
      if q["subtotal_list"] && q["subtotal"] && q["subtotal_list"] != q["subtotal"]
        savings_pct = q["savings_pct"] || ((q["total_savings"].to_f / q["subtotal_list"].to_f) * 100).round(1)
        puts "  List:    #{format_money(q["subtotal_list"])}"
        puts "  Savings: #{format_money(q["total_savings"])} (#{savings_pct}%)"
      end
      puts "  Total:   #{format_money(q["total"])}"
      if (sources = q["savings_summary"]) && !sources.empty?
        puts "  via:     #{sources.join(", ")}"
      end
      if (gap = q["vsp_to_qualify"]) && gap > 0
        threshold = q["vsp_threshold"] ? " (threshold #{format_money(q["vsp_threshold"])})" : ""
        puts "  #{bold("↑ Add #{format_money(gap)} for a Member Volume Discount")}#{dim(threshold)}"
      end
      puts "  Store:   #{q["store"]}"         if q["store"]
      puts "  Link:    #{q["link"]}"          if q["link"]

      items = q["items"] || []
      puts
      puts bold("Items (#{items.size})")
      items.each do |it|
        title = it["title"].to_s
        qty   = it["quantity"] ? "x#{it["quantity"]} " : ""
        model = it["model"] ? " [#{it["model"]}]" : ""
        puts "  • #{qty}#{title}#{model}"

        unit_paid = it["unit_price"]
        unit_list = it["unit_price_list"]
        if unit_paid && unit_list && unit_list != unit_paid
          pct = it["discount_pct"] || ((unit_list - unit_paid) / unit_list.to_f * 100).round(1)
          line = "    #{format_money(unit_paid)}/ea " \
                 "#{dim("(was #{format_money(unit_list)}, −#{pct}%)")}"
          line += " — line #{format_money(it["line_total"])}" if it["line_total"]
          puts line
        elsif unit_paid
          line = "    #{format_money(unit_paid)}/ea"
          line += " — line #{format_money(it["line_total"])}" if it["line_total"]
          puts line
        end
      end
    end

    def prices(rows)
      return puts(JSON.pretty_generate(rows)) if @json
      return puts("(no prices)") if rows.empty?

      headers = %w[fetched_at model title price status]
      data = rows.map do |r|
        [
          r["fetched_at"].to_s[0, 19],
          r["model"].to_s,
          r["title"].to_s[0, 40],
          format_money(r["price"]),
          r["availability"] || ""
        ]
      end
      print_table(headers, data)
    end

    def materials(list)
      return puts(JSON.pretty_generate(list)) if @json
      return puts("(no materials — `lowes materials add ...`)") if list.empty?

      headers = %w[nickname model item_id url]
      data = list.map do |m|
        [m["nickname"].to_s, m["model"].to_s, m["item_id"].to_s, (m["url"] || "").to_s[0, 60]]
      end
      print_table(headers, data)
    end

    private

    def effective_total(order)
      order["grand_total"] || order["total_before_tax"] || order["subtotal"]
    end

    def print_table(headers, rows)
      cols = headers.size
      widths = Array.new(cols) { |i| [headers[i].length, *rows.map { |r| r[i].to_s.length }].max }
      fmt = widths.map { |w| "%-#{w}s" }.join("  ")
      puts bold(fmt % headers)
      rows.each { |r| puts(fmt % r) }
    end

    def format_money(val)
      return "" if val.nil?
      return val if val.is_a?(String) && !val.match?(/\A-?\d/)
      sprintf("$%.2f", val.to_f)
    end

    def bold(s) = @color ? "#{BOLD}#{s}#{RST}" : s
    def dim(s)  = @color ? "#{DIM}#{s}#{RST}"  : s
  end
end
