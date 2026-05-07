require "json"
require "net/http"
require "uri"

module Lowes
  class Client
    class Error < StandardError
      attr_reader :status, :body
      def initialize(msg, status: nil, body: nil)
        super(msg)
        @status = status
        @body = body
      end
    end

    BASE = "https://www.lowes.com/digitalpro/api/quote".freeze
    DEFAULT_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36".freeze

    def self.from_storage_state(path = Lowes::Config.cache_dir.join("storage_state.json"), auto_refresh: true)
      raise Error, "no cookies at #{path} — run `lowes login` first" unless File.exist?(path)
      data = JSON.parse(File.read(path))
      new(cookies: data["cookies"] || [], storage_state_path: path, auto_refresh: auto_refresh)
    end

    # Pulls fresh cookies from the live Chrome session via CDP and rewrites
    # storage_state.json. Akamai bot cookies (_abck, bm_*) rotate frequently,
    # so the on-disk cookies often go stale within minutes. Run this before
    # each request burst to avoid 403s.
    def self.refresh_cookies!(cdp_url: "http://127.0.0.1:9222", path: Lowes::Config.cache_dir.join("storage_state.json"))
      version = JSON.parse(Net::HTTP.get(URI("#{cdp_url}/json/version")))
      ws_url = version["webSocketDebuggerUrl"]
      cookies = fetch_cookies_via_cdp(ws_url)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate({ "cookies" => cookies, "origins" => [] }))
      cookies.size
    end

    # Minimal CDP JSON-over-WebSocket client to call Storage.getCookies.
    def self.fetch_cookies_via_cdp(ws_url)
      require "socket"
      require "openssl"
      require "securerandom"
      require "digest"
      require "base64"
      uri = URI(ws_url)
      tcp = TCPSocket.new(uri.host, uri.port)
      key = Base64.strict_encode64(SecureRandom.bytes(16))
      tcp.write([
        "GET #{uri.request_uri} HTTP/1.1",
        "Host: #{uri.host}:#{uri.port}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: #{key}",
        "Sec-WebSocket-Version: 13",
        "", ""
      ].join("\r\n"))
      # Drain handshake
      while (line = tcp.gets) && line.strip != ""; end
      send_ws_text(tcp, JSON.generate({ "id" => 1, "method" => "Storage.getCookies", "params" => {} }))
      msg = recv_ws_text(tcp)
      tcp.close
      JSON.parse(msg).dig("result", "cookies") || []
    end

    def self.send_ws_text(sock, payload)
      bytes = payload.b
      header = [0x81].pack("C")
      mask_key = SecureRandom.bytes(4)
      length = bytes.bytesize
      header += if length < 126
        [length | 0x80].pack("C")
      elsif length < 65_536
        [126 | 0x80, length].pack("Cn")
      else
        [127 | 0x80, length].pack("CQ>")
      end
      header += mask_key
      masked = bytes.each_byte.with_index.map { |b, i| b ^ mask_key.bytes[i % 4] }.pack("C*")
      sock.write(header + masked)
    end

    def self.recv_ws_text(sock)
      first = sock.read(2).bytes
      length = first[1] & 0x7F
      length = sock.read(2).unpack1("n") if length == 126
      length = sock.read(8).unpack1("Q>") if length == 127
      sock.read(length)
    end

    def initialize(cookies:, user_agent: DEFAULT_USER_AGENT, storage_state_path: nil, auto_refresh: false)
      @cookie_header = build_cookie_header(cookies)
      @user_agent = user_agent
      @storage_state_path = storage_state_path
      @auto_refresh = auto_refresh
    end

    # ---- Quote-level CRUD ------------------------------------------------

    def search(filters = {})
      post_json("/search", filters, headers: { "x-support-store-quotes" => "true" })
    end

    def get_quote(quote_id, vre: nil)
      h = { "x-support-store-quotes" => "true", "x-enable-quote-services" => "true" }
      h["x-vre"] = vre if vre
      get_json("/#{quote_id}", headers: h)
    end

    def create_quote(description:, po_number: "", comment: "", empty: true, address: {})
      body = {
        "quoteDescription" => description,
        "poNumber" => po_number,
        "comment" => comment,
        "emptyQuote" => empty,
        "address" => address
      }
      post_json("/create", body, headers: { "x-support-store-quotes" => "true" })
    end

    def update_quote(quote_id, payload)
      patch_json("/#{quote_id}", payload)
    end

    def delete_quote(quote_id)
      delete_json("/#{quote_id}")
    end

    def refresh_quote(quote_id)
      post_json("/#{quote_id}/refresh", {})
    end

    def duplicate_quote(quote_id, description: "", po_number: "", comment: "")
      post_json("/#{quote_id}/duplicate", {
        "quoteDescription" => description,
        "poNumber" => po_number,
        "comment" => comment
      })
    end

    # ---- Line item operations -------------------------------------------

    # items: [{ "productInfo" => { "omniItemId" => "12345" }, "quantity" => 1 }, ...]
    # NB: the add endpoint is POST /<quoteId> (not /<quoteId>/items) per the saga
    # bundle. Item-level operations (remove, qty) live under /<quoteId>/items/<itemId>.
    def add_items(quote_id, items, retain_price: true, bulk: false)
      path = "/#{quote_id}"
      path += "?retainQuotePrice=true" if retain_price
      body = bulk ? { "items" => items, "bulkUpdate" => true } : { "items" => items }
      post_json(path, body)
    end

    def remove_item(quote_id, item_id, retain_price: true)
      path = "/#{quote_id}/items/#{item_id}"
      path += "?retainQuotePrice=true" if retain_price
      delete_json(path)
    end

    def update_item_quantity(quote_id, item_id, quantity, retain_price: true)
      path = "/#{quote_id}/items/#{item_id}/quantity"
      path += "?retainQuotePrice=true" if retain_price
      patch_json(path, { "itemQty" => quantity })
    end

    # ---- HTTP plumbing ---------------------------------------------------

    private

    def get_json(path, headers: {})
      request(Net::HTTP::Get.new(uri_for(path)), headers: headers)
    end

    def post_json(path, body, headers: {})
      req = Net::HTTP::Post.new(uri_for(path))
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)
      request(req, headers: headers)
    end

    def patch_json(path, body, headers: {})
      req = Net::HTTP::Patch.new(uri_for(path))
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)
      request(req, headers: headers)
    end

    def delete_json(path, headers: {})
      request(Net::HTTP::Delete.new(uri_for(path)), headers: headers)
    end

    def uri_for(path)
      URI("#{BASE}#{path}")
    end

    def request(req, headers: {})
      req["User-Agent"] = @user_agent
      req["Accept"] = "application/json, text/plain, */*"
      req["Cookie"] = @cookie_header if @cookie_header && !@cookie_header.empty?
      req["Origin"] = "https://www.lowes.com"
      req["Referer"] = "https://www.lowes.com/quotes"
      headers.each { |k, v| req[k] = v }

      uri = req.uri
      resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        http.request(req)
      end

      body = resp.body.to_s
      parsed = body.empty? ? nil : (try_json(body) || body)
      unless resp.is_a?(Net::HTTPSuccess)
        if resp.code.to_i == 403 && @auto_refresh && !@refreshed_once
          @refreshed_once = true
          reload_cookies!
          return request(rebuild_request(req), headers: headers)
        end
        raise Error.new("HTTP #{resp.code} #{req.method} #{uri.path}", status: resp.code.to_i, body: parsed)
      end
      parsed
    end

    def reload_cookies!
      self.class.refresh_cookies!(path: @storage_state_path) if @storage_state_path
      data = JSON.parse(File.read(@storage_state_path))
      @cookie_header = build_cookie_header(data["cookies"] || [])
    end

    def rebuild_request(req)
      klass = req.class
      fresh = klass.new(req.uri)
      fresh.body = req.body if req.body
      fresh
    end

    def try_json(body)
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def build_cookie_header(cookies)
      Array(cookies).each_with_object([]) do |c, acc|
        domain = c["domain"].to_s
        next unless domain.include?("lowes.com")
        acc << "#{c["name"]}=#{c["value"]}"
      end.join("; ")
    end
  end
end
