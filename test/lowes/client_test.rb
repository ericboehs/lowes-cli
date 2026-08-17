require_relative "../test_helper"
require "lowes/client"

class LowesClientTest < Minitest::Test
  include XDGSandbox

  def setup
    super
    @cookies = [
      { "name" => "session", "value" => "abc", "domain" => "www.lowes.com" },
      { "name" => "noise", "value" => "x", "domain" => "example.com" }
    ]
    @client = Lowes::Client.new(cookies: @cookies)
  end

  def test_cookie_header_filters_to_lowes_domains
    header = @client.send(:build_cookie_header, @cookies)
    assert_equal "session=abc", header
  end

  def test_get_quote_uses_quote_specific_headers
    captured = capture_request { @client.get_quote("12345") }
    assert_equal Net::HTTP::Get, captured[:req].class
    assert_equal "/digitalpro/api/quote/12345", captured[:req].uri.path
    assert_equal "true", captured[:req]["x-support-store-quotes"]
    assert_equal "true", captured[:req]["x-enable-quote-services"]
    assert_equal "session=abc", captured[:req]["Cookie"]
  end

  def test_get_quote_includes_vre_header_when_provided
    captured = capture_request { @client.get_quote("12345", vre: "VRE-9") }
    assert_equal "VRE-9", captured[:req]["x-vre"]
  end

  def test_create_quote_posts_to_create_with_body
    captured = capture_request(response_body: '{"onlineQuote":{"quoteId":"99"}}') do
      @client.create_quote(description: "Test", po_number: "PO1", comment: "c", empty: true)
    end
    assert_equal Net::HTTP::Post, captured[:req].class
    assert_equal "/digitalpro/api/quote/create", captured[:req].uri.path
    body = JSON.parse(captured[:req].body)
    assert_equal "Test", body["quoteDescription"]
    assert_equal "PO1", body["poNumber"]
    assert_equal true, body["emptyQuote"]
    assert_equal "true", captured[:req]["x-support-store-quotes"]
  end

  def test_delete_quote_uses_delete_method
    captured = capture_request { @client.delete_quote("12345") }
    assert_equal Net::HTTP::Delete, captured[:req].class
    assert_equal "/digitalpro/api/quote/12345", captured[:req].uri.path
  end

  def test_remove_item_includes_retain_price_query_string
    captured = capture_request { @client.remove_item("12345", "item-9") }
    assert_equal Net::HTTP::Delete, captured[:req].class
    assert_equal "/digitalpro/api/quote/12345/items/item-9", captured[:req].uri.path
    assert_equal "retainQuotePrice=true", captured[:req].uri.query
  end

  def test_remove_item_can_skip_retain_price
    captured = capture_request { @client.remove_item("12345", "item-9", retain_price: false) }
    assert_nil captured[:req].uri.query
  end

  def test_update_item_quantity_patches_quantity_path
    captured = capture_request { @client.update_item_quantity("12345", "item-9", 4) }
    assert_equal Net::HTTP::Patch, captured[:req].class
    assert_equal "/digitalpro/api/quote/12345/items/item-9/quantity", captured[:req].uri.path
    assert_equal({ "itemQty" => 4 }, JSON.parse(captured[:req].body))
  end

  def test_add_items_posts_items_array
    items = [{ "productInfo" => { "omniItemId" => "111" }, "quantity" => 2 }]
    captured = capture_request { @client.add_items("12345", items) }
    assert_equal Net::HTTP::Post, captured[:req].class
    assert_equal "/digitalpro/api/quote/12345", captured[:req].uri.path
    assert_equal "retainQuotePrice=true", captured[:req].uri.query
    body = JSON.parse(captured[:req].body)
    assert_equal items, body["items"]
    refute body["bulkUpdate"]
  end

  def test_add_items_bulk_sets_bulk_update_flag
    captured = capture_request { @client.add_items("12345", [], bulk: true) }
    body = JSON.parse(captured[:req].body)
    assert_equal true, body["bulkUpdate"]
  end

  def test_search_posts_empty_body_by_default
    captured = capture_request(response_body: '{"quotes":[]}') { @client.search }
    assert_equal Net::HTTP::Post, captured[:req].class
    assert_equal "/digitalpro/api/quote/search", captured[:req].uri.path
    assert_equal({}, JSON.parse(captured[:req].body))
  end

  def test_non_2xx_raises_with_status_and_parsed_body
    err = assert_raises(Lowes::Client::Error) do
      capture_request(status: "500", response_body: '{"error":"boom"}') { @client.delete_quote("99") }
    end
    assert_equal 500, err.status
    assert_equal({ "error" => "boom" }, err.body)
  end

  def test_from_storage_state_raises_when_missing
    err = assert_raises(Lowes::Client::Error) do
      Lowes::Client.from_storage_state(Pathname(@tmp).join("missing.json"))
    end
    assert_match(/no cookies/i, err.message)
  end

  def test_from_storage_state_loads_cookies
    path = Lowes::Config.cache_dir.join("storage_state.json")
    File.write(path, JSON.generate({ "cookies" => [{ "name" => "k", "value" => "v", "domain" => "www.lowes.com" }] }))
    client = Lowes::Client.from_storage_state(path)
    assert_equal "k=v", client.send(:build_cookie_header, [{ "name" => "k", "value" => "v", "domain" => "www.lowes.com" }])
  end

  # ---- refresh_cookies! ------------------------------------------------

  def test_refresh_keeps_existing_cookies_when_cdp_comes_back_empty
    path = Lowes::Config.cache_dir.join("storage_state.json")
    good = { "cookies" => [{ "name" => "session", "value" => "abc", "domain" => "www.lowes.com" }] }
    File.write(path, JSON.generate(good))

    count = nil
    _, err = capture_io do
      count = with_cdp_cookies([]) { Lowes::Client.refresh_cookies!(path: path) }
    end

    assert_equal 0, count
    assert_equal good["cookies"], JSON.parse(File.read(path))["cookies"]
    assert_match(/keeping the ones already in/, err)
  end

  # Nothing to protect, so the empty read is written through rather than
  # leaving the caller with a file that never appears.
  def test_refresh_writes_through_when_there_is_nothing_to_lose
    path = Lowes::Config.cache_dir.join("storage_state.json")
    count = with_cdp_cookies([]) { Lowes::Client.refresh_cookies!(path: path) }

    assert_equal 0, count
    assert_equal [], JSON.parse(File.read(path))["cookies"]
  end

  def test_refresh_replaces_cookies_when_cdp_has_them
    path = Lowes::Config.cache_dir.join("storage_state.json")
    File.write(path, JSON.generate({ "cookies" => [{ "name" => "old", "value" => "1", "domain" => "www.lowes.com" }] }))
    fresh = [{ "name" => "new", "value" => "2", "domain" => ".lowes.com" }]

    count = with_cdp_cookies(fresh) { Lowes::Client.refresh_cookies!(path: path) }

    assert_equal 1, count
    assert_equal fresh, JSON.parse(File.read(path))["cookies"]
  end

  # An unreadable file is not a session worth keeping, so it must not be the
  # thing that blocks a good write.
  def test_unparseable_storage_state_counts_as_empty
    path = Lowes::Config.cache_dir.join("storage_state.json")
    File.write(path, "{ not json")
    assert_equal 0, Lowes::Client.existing_lowes_cookie_count(path)

    with_cdp_cookies([]) { Lowes::Client.refresh_cookies!(path: path) }
    assert_equal [], JSON.parse(File.read(path))["cookies"]
  end

  private

  # Stands in for the whole CDP conversation: Chrome being up, the tab nudge,
  # and the cookie read.
  def with_cdp_cookies(cookies)
    stubbed = { ensure_chrome_alive!: ->(**) { true },
                ensure_lowes_tab!: ->(**) { true },
                cdp_get_cookies: ->(**) { cookies } }
    originals = stubbed.keys.to_h { |name| [name, Lowes::Client.method(name)] }
    stubbed.each { |name, impl| Lowes::Client.define_singleton_method(name, &impl) }
    yield
  ensure
    # `module_function`-style singleton methods are replaced, not shadowed —
    # putting the originals back is the only way the rest of the suite keeps
    # the real ones.
    originals.each { |name, impl| Lowes::Client.define_singleton_method(name, impl) }
  end

  # Stub Net::HTTP.start so no real HTTP happens. Captures the last request.
  def capture_request(status: "200", response_body: "{}")
    captured = {}
    fake_resp = FakeResponse.new(status, response_body)
    original = Net::HTTP.method(:start)
    Net::HTTP.singleton_class.send(:remove_method, :start)
    Net::HTTP.define_singleton_method(:start) do |_host, _port = nil, **_opts, &blk|
      blk.call(StubHTTP.new(fake_resp, captured))
    end
    begin
      yield
    ensure
      Net::HTTP.singleton_class.send(:remove_method, :start)
      Net::HTTP.define_singleton_method(:start, original)
    end
    captured
  end

  class StubHTTP
    def initialize(resp, captured)
      @resp = resp
      @captured = captured
    end

    def request(req)
      @captured[:req] = req
      @resp
    end
  end

  class FakeResponse
    def initialize(code, body)
      @code = code
      @body = body
    end
    def code; @code; end
    def body; @body; end
    def is_a?(klass)
      return @code.start_with?("2") if klass == Net::HTTPSuccess
      super
    end
  end
end
