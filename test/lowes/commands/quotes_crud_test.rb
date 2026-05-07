require_relative "../../test_helper"
require "stringio"

class QuotesCrudTest < Minitest::Test
  include XDGSandbox

  def setup
    super
    @stub = StubOnlineClient.new
    @cmd = Lowes::Commands::Quotes.new(
      { json: false, quiet: true, verbose: false },
      online_client: @stub
    )
  end

  class StubOnlineClient
    attr_reader :calls
    def initialize
      @quotes = []
      @details = {}
      @calls = []
    end

    def add_quote(q); @quotes << q; end
    def add_detail(id, d); @details[id] = d; end

    def search(filters = {})
      @calls << [:search, filters]
      { "quotes" => @quotes }
    end

    def get_quote(id)
      @calls << [:get, id]
      raise Lowes::Client::Error.new("not found", status: 404) unless @details[id]
      { "quoteDetail" => @details[id] }
    end

    def create_quote(**kwargs)
      @calls << [:create, kwargs]
      new_id = "999000#{@calls.count(&->(c){ c.first == :create })}"
      { "onlineQuote" => { "quoteId" => new_id, "quoteDescription" => kwargs[:description] } }
    end

    def delete_quote(id)
      @calls << [:delete, id]
      { "ok" => true }
    end

    def duplicate_quote(id, **kwargs)
      @calls << [:duplicate, id, kwargs]
      # live API returns the quote object flat — not wrapped in onlineQuote
      { "quoteId" => "#{id}-copy", "quoteDescription" => kwargs[:description] }
    end

    def add_items(id, items, **opts)
      @calls << [:add_items, id, items, opts]
      { "ok" => true }
    end

    def remove_item(id, line_id, **opts)
      @calls << [:remove_item, id, line_id, opts]
      { "ok" => true }
    end

    def update_quote(id, payload)
      @calls << [:update_quote, id, payload]
      { "ok" => true }
    end

    def update_item_quantity(id, line_id, qty, **opts)
      @calls << [:update_item_quantity, id, line_id, qty, opts]
      { "ok" => true }
    end

    def refresh_quote(id)
      @calls << [:refresh, id]
      { "ok" => true }
    end
  end

  def test_list_renders_quotes_from_search
    @stub.add_quote(
      "quoteId" => "111", "quoteDescription" => "Wire",
      "createdTs" => "2026-05-06T12:00:00Z",
      "displayQuoteStatus" => "READY TO BUY",
      "totals" => { "totalAmount" => 200.00 }
    )
    out, _ = capture_io { @cmd.run(["list"]) }
    assert_includes out, "111"
    assert_includes out, "Wire"
    assert_includes out, "$200.00"
  end

  def test_list_filters_by_status_case_insensitive
    @stub.add_quote("quoteId" => "1", "quoteDescription" => "A", "displayQuoteStatus" => "READY TO BUY", "createdTs" => "2026-05-06")
    @stub.add_quote("quoteId" => "2", "quoteDescription" => "B", "displayQuoteStatus" => "EXPIRED",      "createdTs" => "2026-05-05")
    out, _ = capture_io { @cmd.run(["list", "--status", "expired"]) }
    refute_includes out, "READY TO BUY"
    assert_includes out, "EXPIRED"
  end

  def test_show_routes_to_get_and_renders_detail
    @stub.add_detail("240120902", {
      "quoteId" => "240120902", "quoteDescription" => "Wire",
      "displayQuoteStatus" => "READY TO BUY",
      "createdTs" => "2026-05-06",
      "cartItems" => {},
      "cartSummary" => { "subtotal" => 0, "totalSalesTax" => 0, "grandTotal" => 0 }
    })
    out, _ = capture_io { @cmd.run(["show", "240120902"]) }
    assert_includes out, "Wire"
  end

  def test_show_renders_per_item_pricing_and_volume_discount
    @stub.add_detail("999", {
      "quoteId" => "999",
      "quoteDescription" => "Test",
      "displayQuoteStatus" => "READY TO BUY",
      "createdTs" => "2026-05-06",
      "totalSavingSummary" => ["Member Volume Discount"],
      "vspApplied" => true,
      "cartItems" => {
        "L1" => {
          "quantity" => 4,
          "productInfo" => { "modelNumber" => "ABC", "itemNumber" => "111", "productName" => "Widget" },
          "priceInfo" => {
            "prices" => [
              { "priceType" => "BASE",  "value" => 100 },
              { "priceType" => "FINAL", "value" => 100 },
              { "priceType" => "LAST_UNLOCK_PRICE", "value" => 90 }
            ]
          },
          "discounts" => ["Member Volume Discount"]
        }
      },
      "cartSummary" => {
        "subtotal" => "360",
        "subTotalWithOutDiscount" => "400",
        "grandTotal" => "360",
        "totalDiscount" => "40",
        "totalSaving" => "40",
        "savingsPercentage" => "10",
        "totalSalesTax" => "0"
      }
    })
    out, _ = capture_io { @cmd.run(["show", "999"]) }
    assert_includes out, "$90.00/ea"
    assert_includes out, "was $100.00, −10.0%"
    assert_includes out, "line $360.00"
    assert_includes out, "Savings: $40.00 (10.0%)"
    assert_includes out, "via:     Member Volume Discount"
  end

  def test_show_prints_upsell_when_below_vsp_threshold
    @stub.add_detail("888", {
      "quoteId" => "888", "quoteDescription" => "Almost There",
      "displayQuoteStatus" => "READY TO BUY",
      "createdTs" => "2026-05-06",
      "vspSummary" => {
        "vspQualify" => true, "vspApplied" => false,
        "vspThreshold" => "2000.00", "prevSubTotal" => "1797.00",
        "toQualifyVSP" => "203.00", "qualifiedVSPPercentage" => "89"
      },
      "cartItems" => {},
      "cartSummary" => { "subtotal" => "1797", "subTotalWithOutDiscount" => "1797", "grandTotal" => "1797", "totalSalesTax" => "0" }
    })
    out, _ = capture_io { @cmd.run(["show", "888"]) }
    assert_includes out, "Add $203.00 for a Member Volume Discount"
    assert_includes out, "threshold $2000.00"
  end

  def test_show_returns_1_when_api_404s
    rc = nil
    capture_io { rc = @cmd.run(["show", "missing"]) }
    assert_equal 1, rc
  end

  def test_new_calls_create_quote_and_prints_id
    out, _ = capture_io { @cmd.run(["new", "--name", "Framing", "--note", "test", "--po", "PO1"]) }
    create = @stub.calls.find { |c| c.first == :create }
    refute_nil create
    assert_equal({ description: "Framing", po_number: "PO1", comment: "test" }, create[1])
    assert_match(/\A\d+\z/, out.strip)
  end

  def test_new_requires_name
    rc = nil
    _out, err = capture_io { rc = @cmd.run(["new"]) }
    assert_equal 2, rc
    assert_match(/--name required/, err)
  end

  def test_delete_calls_client_when_forced
    rc = nil
    capture_io { rc = @cmd.run(["delete", "12345", "-y"]) }
    assert_equal 0, rc
    assert_equal [:delete, "12345"], @stub.calls.find { |c| c.first == :delete }
  end

  def test_clone_calls_duplicate_quote
    out, _ = capture_io { @cmd.run(["clone", "12345", "--name", "Custom"]) }
    dup = @stub.calls.find { |c| c.first == :duplicate }
    assert_equal "12345", dup[1]
    assert_equal({ description: "Custom" }, dup[2])
    assert_equal "12345-copy", out.strip
  end

  def test_add_with_numeric_item_id
    rc = nil
    capture_io { rc = @cmd.run(["add", "240", "28828201", "--qty", "3"]) }
    assert_equal 0, rc
    add = @stub.calls.find { |c| c.first == :add_items }
    assert_equal "240", add[1]
    assert_equal [{ "productInfo" => { "omniItemId" => "28828201" }, "quantity" => 3 }], add[2]
  end

  def test_add_extracts_item_id_from_url
    rc = nil
    capture_io { rc = @cmd.run(["add", "240", "https://www.lowes.com/pd/Some-Product/1000123456"]) }
    assert_equal 0, rc
    add = @stub.calls.find { |c| c.first == :add_items }
    assert_equal "1000123456", add[2].first["productInfo"]["omniItemId"]
  end

  def test_add_rejects_unparseable_target
    rc = nil
    _out, err = capture_io { rc = @cmd.run(["add", "240", "ABC-MODEL"]) }
    assert_equal 2, rc
    assert_match(/numeric item-id/, err)
  end

  def test_remove_calls_remove_item_when_forced
    rc = nil
    capture_io { rc = @cmd.run(["remove", "240", "line-99", "-y"]) }
    assert_equal 0, rc
    rm = @stub.calls.find { |c| c.first == :remove_item }
    assert_equal "240", rm[1]
    assert_equal "line-99", rm[2]
  end

  def test_set_updates_header_and_qty
    rc = nil
    capture_io { rc = @cmd.run(["set", "240", "--name", "Renamed", "--qty", "L1=4", "--qty", "L2=8"]) }
    assert_equal 0, rc
    upd = @stub.calls.find { |c| c.first == :update_quote }
    assert_equal "240", upd[1]
    assert_equal({ "quoteDescription" => "Renamed" }, upd[2])

    qtys = @stub.calls.select { |c| c.first == :update_item_quantity }
    assert_equal 2, qtys.size
    assert_equal ["240", "L1", 4], qtys[0][1..3]
    assert_equal ["240", "L2", 8], qtys[1][1..3]
  end

  def test_refresh_calls_refresh_quote
    rc = nil
    capture_io { rc = @cmd.run(["refresh", "240"]) }
    assert_equal 0, rc
    assert_equal [:refresh, "240"], @stub.calls.find { |c| c.first == :refresh }
  end

  def test_bare_id_falls_through_to_show
    @stub.add_detail("xyz", { "quoteId" => "xyz", "cartItems" => {}, "cartSummary" => {} })
    out, _ = capture_io { @cmd.run(["xyz"]) }
    assert_includes out, "xyz"
  end
end
