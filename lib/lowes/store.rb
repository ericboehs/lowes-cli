require "json"
require "fileutils"
require "time"
require "date"

module Lowes
  class Store
    def initialize
      @orders_dir = Config.orders_dir
      @prices_dir = Config.prices_dir
      @index_path = Config.index_path
      @materials_path = Config.materials_path
    end

    def index
      @index ||= if @index_path.exist?
        JSON.parse(File.read(@index_path))
      else
        { "last_sync" => nil, "orders" => {} }
      end
    end

    # ----- Orders -----

    # `detailed:` is whether the caller actually asked for per-order detail.
    # `lowes sync --no-full-details` never opens an order page, so every order
    # arrives with no line items by design — that record is not evidence about
    # items one way or the other, and treating it as a loss would warn once per
    # order for doing exactly what was asked.
    def write_order(order, detailed: true)
      id = order["order_id"]
      raise "order missing order_id" unless id

      year = year_for(order, "order_placed")
      year_dir = @orders_dir.join(year.to_s)
      FileUtils.mkdir_p(year_dir)
      file = year_dir.join("#{id}.json")
      order = keep_line_items(order, file, announce: detailed)
      File.write(file, JSON.pretty_generate(order) + "\n")

      relative = file.relative_path_from(Config.data_dir).to_s
      index["orders"][id] = {
        "year" => year,
        "date" => order["order_placed"],
        "total" => order["grand_total"] || order["total_before_tax"] || order["subtotal"],
        "status" => order["status"],
        "file" => relative
      }
      file
    end

    def read_order(order_id)
      meta = index["orders"][order_id]
      return nil unless meta
      JSON.parse(File.read(Config.data_dir.join(meta["file"])))
    end

    def list_orders(year: nil, limit: nil)
      rows = index["orders"].map { |id, meta| meta.merge("order_id" => id) }
      rows = rows.select { |r| r["year"] == year } if year
      rows.sort_by! { |r| r["date"].to_s }.reverse!
      rows = rows.first(limit) if limit
      rows
    end

    def each_order(year: nil)
      return enum_for(:each_order, year: year) unless block_given?
      index["orders"].each do |id, meta|
        next if year && meta["year"] != year
        yield id, meta, -> { read_order(id) }
      end
    end

    def search_orders(query, year: nil)
      q = query.downcase
      hits = []
      each_order(year: year) do |id, meta, load|
        order = load.call
        items = order["items"] || []
        match = items.any? do |it|
          (it["title"] || "").downcase.include?(q) ||
            (it["model"] || "").downcase.include?(q) ||
            (it["link"] || "").downcase.include?(q)
        end
        match ||= id.downcase.include?(q)
        hits << order if match
      end
      hits.sort_by { |o| o["order_placed"].to_s }.reverse
    end

    # ----- Materials & price history -----

    def materials
      return [] unless File.exist?(@materials_path)
      JSON.parse(File.read(@materials_path))
    end

    def write_materials(list)
      File.write(@materials_path, JSON.pretty_generate(list) + "\n")
    end

    def add_material(entry)
      list = materials
      key = entry["model"] || entry["url"] || entry["item_id"]
      raise "material needs model, url, or item_id" unless key
      list.reject! { |m| (m["model"] || m["url"] || m["item_id"]) == key }
      list << entry
      write_materials(list)
      entry
    end

    def remove_material(key)
      list = materials
      before = list.size
      list.reject! { |m| [m["model"], m["url"], m["item_id"], m["nickname"]].include?(key) }
      write_materials(list) if list.size != before
      before - list.size
    end

    def append_price(entry)
      key = entry["model"] || entry["item_id"] || entry["url"]
      raise "price entry needs model/item_id/url" unless key
      slug = key.to_s.gsub(/[^A-Za-z0-9._-]/, "_")[0, 80]
      file = @prices_dir.join("#{slug}.ndjson")
      FileUtils.mkdir_p(@prices_dir)
      File.open(file, "a") { |f| f.puts JSON.generate(entry) }
      file
    end

    def price_history(key)
      slug = key.to_s.gsub(/[^A-Za-z0-9._-]/, "_")[0, 80]
      file = @prices_dir.join("#{slug}.ndjson")
      return [] unless file.exist?
      File.readlines(file).map { |l| JSON.parse(l) }
    end

    # ----- Index commit -----

    def commit_index!(synced_at: Time.now.utc.iso8601)
      index["last_sync"] = synced_at
      File.write(@index_path, JSON.pretty_generate(index) + "\n")
    end

    private

    # An order that has been placed does not get fewer line items later, so a
    # re-sync that comes back with fewer is this tool losing them, not Lowe's
    # changing its mind. Measured, not assumed: re-scraping 2023 against the
    # live site dropped 27 line items across 7 orders — five to zero, one from
    # 33 to 11 — while the same pages re-read moments later gave the full
    # lists back. Nothing said a word, because this method replaces the file
    # wholesale and the worker only reports what it did find.
    #
    # So the longer list wins, and the difference gets announced. That does
    # mean a genuinely corrected order cannot shrink; deleting its file and
    # syncing again is the way out, and the warning says so.
    def keep_line_items(order, file, announce:)
      return order unless file.exist?

      incoming = order["items"] || []
      stored = stored_items(file)
      return order if stored.length <= incoming.length

      if announce
        warn "lowes: order #{order["order_id"]} came back with #{incoming.length} line " \
             "item#{"s" unless incoming.length == 1} but #{stored.length} are already stored " \
             "— keeping the stored ones. Delete #{file} and re-sync if the order really changed."
      end
      order.merge("items" => stored)
    end

    # A file we cannot read has nothing to protect. Silent on purpose: the
    # caller is about to overwrite it either way, and the only thing this
    # answers is whether there is something in there worth keeping.
    def stored_items(file)
      JSON.parse(File.read(file))["items"] || []
    rescue StandardError
      []
    end

    def year_for(record, date_key)
      placed = record[date_key]
      return Date.parse(placed).year if placed
      Time.now.year
    rescue ArgumentError
      Time.now.year
    end
  end
end
