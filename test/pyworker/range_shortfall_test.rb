require_relative "../test_helper"
require "open3"

# The decision that would have caught the 313-of-323 sync: a date range that
# came back with fewer orders than the store already holds in it. Every step of
# that fetch succeeded — the URL was built, the page was asked for, the run
# reported a clean finish — and only the store knew the answer was too small.
#
# `reason` is set when the order links never appeared at all. That path already
# logged, at `info`, which the Ruby side hides unless `--verbose`; so the whole
# of 2026 Q1 disappeared from a sync that printed nothing. The distinction it
# was missing is the one these pin: an empty quarter is ordinary, an empty
# quarter the store has orders in is a failure.
class RangeShortfallTest < Minitest::Test
  PYWORKER = ROOT.join("pyworker").freeze

  def setup
    super
    skip "python3 not installed" unless system("python3", "--version", out: File::NULL, err: File::NULL)
  end

  def shortfall(found:, expected:, reason: nil)
    script = <<~PY
      import json, sys
      from datetime import date
      sys.path.insert(0, #{PYWORKER.to_s.dump})
      import fetch
      out = fetch.range_shortfall(date(2026, 1, 1), date(2026, 3, 31),
                                  #{found}, #{expected}, #{reason ? reason.dump : "None"})
      print(json.dumps(out))
    PY
    out, err, status = Open3.capture3("python3", "-c", script)
    flunk("python failed: #{err}") unless status.success?
    JSON.parse(out)
  end

  # ---- the range that came back whole --------------------------------

  def test_a_range_that_matches_the_store_says_nothing
    assert_nil shortfall(found: 10, expected: 10)
  end

  # New orders are the normal case and are not a shortfall.
  def test_a_range_with_more_than_the_store_says_nothing
    assert_nil shortfall(found: 12, expected: 10)
  end

  def test_a_genuinely_empty_range_says_nothing
    assert_nil shortfall(found: 0, expected: 0)
  end

  # ---- the range that came back short --------------------------------

  # The 2026 Q1 case: ten orders on disk, nothing on the page.
  def test_a_range_the_store_has_orders_in_coming_back_empty_warns
    level, msg = shortfall(found: 0, expected: 10, reason: "Timeout 8000ms exceeded")
    assert_equal "warn", level
    assert_includes msg, "the store has 10 orders in that range"
    assert_includes msg, "the page did not load or the selector moved"
    assert_includes msg, "Timeout 8000ms exceeded"
  end

  # The page loaded, the selector matched, the extractor succeeded, and the
  # answer was still too small. Nothing else in the fetch can see this.
  def test_a_partial_range_warns_even_though_nothing_failed
    level, msg = shortfall(found: 7, expected: 10)
    assert_equal "warn", level
    assert_includes msg, "returned 7 orders but the store has 10"
    assert_includes msg, "3 will keep whatever is already on disk"
  end

  def test_the_count_of_what_will_not_be_refreshed_is_the_difference
    _, msg = shortfall(found: 1, expected: 34)
    assert_includes msg, "33 will keep whatever is already on disk"
  end

  # ---- the quarter with nothing in it --------------------------------

  # Most quarters in an early year are genuinely empty. Warning on those would
  # bury the one that matters, so it stays at `info` — the level it always was.
  def test_an_empty_quarter_the_store_agrees_is_empty_stays_quiet
    level, msg = shortfall(found: 0, expected: 0, reason: "Timeout 8000ms exceeded")
    assert_equal "info", level
    assert_includes msg, "empty quarter"
    refute_includes msg, "did not load"
  end

  # ---- wording ------------------------------------------------------

  def test_a_single_stored_order_is_not_pluralised
    _, msg = shortfall(found: 0, expected: 1, reason: "boom")
    assert_includes msg, "the store has 1 order in that range"
  end

  def test_the_range_is_named_so_the_quarter_is_identifiable
    _, msg = shortfall(found: 0, expected: 10, reason: "boom")
    assert_includes msg, "2026-01-01..2026-03-31"
  end
end
