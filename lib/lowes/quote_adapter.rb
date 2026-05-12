module Lowes
  # Maps the lowes.com /digitalpro/api/quote response shape to the internal
  # row/quote shape used by the CLI formatter and the web UI.
  module QuoteAdapter
    module_function

    def to_row(q)
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

    def detail_to_quote(d)
      cs    = d["cartSummary"] || {}
      vsp   = d["vspSummary"]  || {}
      items = (d["cartItems"] || {}).map { |line_id, it| line_to_item(line_id, it) }

      {
        "quote_id"        => d["quoteId"],
        "type"            => "online",
        "name"            => d["quoteDescription"],
        "status"          => d["displayQuoteStatus"] || d["quoteStatus"],
        "notes"           => (d["comments"] || []).first&.dig("comment"),
        "created"         => d["createdTs"] || d["createdAt"],
        "items"           => items,
        "link"            => d["quoteId"] ? "https://www.lowes.com/quotes/#{d["quoteId"]}" : nil,
        "subtotal"        => cs["subtotal"]&.to_f,
        "subtotal_list"   => cs["subTotalWithOutDiscount"]&.to_f,
        "tax"             => cs["totalSalesTax"]&.to_f,
        "total"           => cs["grandTotal"]&.to_f,
        "total_savings"   => cs["totalDiscount"]&.to_f || cs["totalSaving"]&.to_f,
        "savings_pct"     => cs["savingsPercentage"]&.to_f,
        "savings_summary" => d["totalSavingSummary"] || [],
        "vsp_applied"     => d["vspApplied"],
        "vsp_to_qualify"  => vsp["toQualifyVSP"]&.to_f,
        "vsp_threshold"   => vsp["vspThreshold"]&.to_f,
        "vsp_qualify_pct" => vsp["qualifiedVSPPercentage"]&.to_f
      }
    end

    # `productInfo.imageUrl` comes back as `/productimages/<uuid>/<n>.jpeg` —
    # which 403s on www.lowes.com but is served from mobileimages.lowes.com.
    def absolute_image_url(url)
      return nil if url.nil? || url.empty?
      return url if url.start_with?("http://", "https://")
      "https://mobileimages.lowes.com#{url}"
    end

    # `cartItems[*].itemSummary` is the authoritative per-line price source —
    # each line's discount % is its own (not the cart average), so prefer it
    # when present and fall back to `priceInfo.prices[]` only if it's empty.
    def line_to_item(line_id, it)
      pi      = it["productInfo"] || {}
      summary = it["itemSummary"] || {}
      prices  = ((it["priceInfo"] || {})["prices"] || []).each_with_object({}) { |p, h| h[p["priceType"]] = p["value"] }
      qty     = it["quantity"].to_i

      unit_paid = summary["unitPrice"]&.to_f || prices["LAST_UNLOCK_PRICE"] || prices["FINAL"] || prices["BASE"]
      unit_list = (summary["wasPrice"]&.to_f && qty > 0 ? summary["wasPrice"].to_f / qty : nil) ||
                  prices["FINAL"] || prices["BASE"] || prices["RETAIL"]
      line_total      = summary["subTotalAfterDisc"]&.to_f || (unit_paid && unit_paid * qty)
      line_total_list = summary["wasPrice"]&.to_f          || (unit_list && unit_list * qty)
      discount_pct    = summary["totalSavingsPercentage"]&.to_f
      discount_pct  ||= (unit_list && unit_paid && unit_list > 0) ? ((unit_list - unit_paid) / unit_list.to_f * 100).round(1) : 0.0

      {
        "line"            => line_id,
        "model"           => pi["modelNumber"] || pi["model"],
        "item_id"         => pi["itemNumber"] || pi["omniItemId"],
        "url"             => pi["pdUrl"],
        "title"           => pi["productName"] || pi["productDescription"],
        "image_url"       => absolute_image_url(pi["imageUrl"]),
        "quantity"        => qty,
        "unit_price"      => unit_paid,
        "unit_price_list" => unit_list,
        "discount_pct"    => discount_pct,
        "discount_amount" => summary["discount"]&.to_f,
        "discounts"       => it["discounts"] || [],
        "line_total"      => line_total,
        "line_total_list" => line_total_list
      }
    end
  end
end
