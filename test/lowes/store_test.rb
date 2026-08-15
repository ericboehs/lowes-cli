require_relative "../test_helper"

# `write_order` replaces the file wholesale, so whatever a re-sync hands it is
# the whole record from then on. Re-scraping 2023 against the live site dropped
# 27 line items across 7 orders — five of them to zero — while the same pages
# re-read moments later gave the full lists back. Nothing was said, and the
# orders were simply shorter afterwards. These pin the rule that came out of
# that: a placed order does not get fewer line items later.
class StoreLineItemsTest < Minitest::Test
  include XDGSandbox

  def store = @store ||= Lowes::Store.new

  def order(id, count, **extra)
    items = Array.new(count) { |i| { "title" => "item #{i}", "line_total" => 1.0 * i } }
    { "order_id" => id, "order_placed" => "2023-06-01", "grand_total" => 99.0,
      "items" => items }.merge(extra.transform_keys(&:to_s))
  end

  def items_on_disk(id)
    JSON.parse(File.read(store.index["orders"][id]["file"].then { |f| Lowes::Config.data_dir.join(f) }))["items"]
  end

  def test_a_first_write_stores_what_it_was_given
    store.write_order(order("A", 3))
    assert_equal 3, items_on_disk("A").length
  end

  # The case that cost 22 lines: the page rendered short, the extractor
  # believed it, and the shorter list would have replaced the full one.
  def test_a_shorter_re_sync_does_not_shrink_a_stored_order
    store.write_order(order("A", 33))
    capture_io { store.write_order(order("A", 11)) }
    assert_equal 33, items_on_disk("A").length
  end

  # Five of the seven came back with nothing at all, which is the same bug
  # wearing its most obvious face.
  def test_an_empty_re_sync_does_not_empty_a_stored_order
    store.write_order(order("A", 7))
    capture_io { store.write_order(order("A", 0)) }
    assert_equal 7, items_on_disk("A").length
  end

  def test_a_longer_re_sync_replaces_the_stored_items
    store.write_order(order("A", 11))
    store.write_order(order("A", 34))
    assert_equal 34, items_on_disk("A").length
  end

  # The dedupe fix in #1 recovered lines without changing anything else, and
  # an equal-length rewrite has to be able to correct prices in place.
  def test_an_equal_length_re_sync_replaces_the_stored_items
    store.write_order(order("A", 2))
    store.write_order(order("A", 2).tap { |o| o["items"][0]["line_total"] = 999.0 })
    assert_equal 999.0, items_on_disk("A")[0]["line_total"]
  end

  # Only `items` is protected. A re-sync exists to correct the rest, and
  # freezing a status at "Shipped" forever would be its own bug.
  def test_the_rest_of_the_order_is_still_replaced
    store.write_order(order("A", 7, status: "Shipped"))
    capture_io { store.write_order(order("A", 0, status: "Delivered")) }
    file = Lowes::Config.data_dir.join(store.index["orders"]["A"]["file"])
    assert_equal "Delivered", JSON.parse(File.read(file))["status"]
    assert_equal 7, items_on_disk("A").length
  end

  def test_it_says_so_rather_than_quietly_keeping_them
    store.write_order(order("A", 7))
    _, err = capture_io { store.write_order(order("A", 0)) }
    assert_includes err, "0 line items"
    assert_includes err, "7 are already stored"
    assert_includes err, "re-sync if the order really changed"
  end

  def test_nothing_is_said_when_nothing_was_dropped
    store.write_order(order("A", 3))
    _, err = capture_io { store.write_order(order("A", 4)) }
    assert_empty err
  end

  # A half-written or hand-edited file has nothing to protect, and refusing to
  # overwrite it would make the store unrepairable by re-syncing.
  def test_an_unreadable_stored_file_does_not_block_the_write
    store.write_order(order("A", 3))
    File.write(Lowes::Config.data_dir.join(store.index["orders"]["A"]["file"]), "{ not json")
    store.write_order(order("A", 1))
    assert_equal 1, items_on_disk("A").length
  end
end

# `lowes sync --no-full-details` never opens an order page, so every order comes
# back with no line items by design. Protecting them is still right; warning
# about it once per order for doing exactly what was asked is not.
class StoreNoDetailSyncTest < Minitest::Test
  include XDGSandbox

  def store = @store ||= Lowes::Store.new

  def order(id, count)
    { "order_id" => id, "order_placed" => "2023-06-01", "grand_total" => 99.0,
      "items" => Array.new(count) { |i| { "title" => "item #{i}" } } }
  end

  def test_a_detail_free_sync_still_keeps_the_stored_items
    store.write_order(order("A", 7))
    store.write_order(order("A", 0), detailed: false)
    file = Lowes::Config.data_dir.join(store.index["orders"]["A"]["file"])
    assert_equal 7, JSON.parse(File.read(file))["items"].length
  end

  def test_a_detail_free_sync_does_not_warn_about_every_order
    store.write_order(order("A", 7))
    _, err = capture_io { store.write_order(order("A", 0), detailed: false) }
    assert_empty err
  end
end
