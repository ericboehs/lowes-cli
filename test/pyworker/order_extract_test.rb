require_relative "../test_helper"
require "open3"

# `pickLinePrices` decides what an order cost. It lives in fetch.py as a JS
# string evaluated inside a page, which normally means the only way to exercise
# it is to have Lowe's serve you an order — so it is sliced out of the real file
# and run under node here, against the row text those orders actually contain.
#
# Two shipped bugs came out of this function, and both made orders read as
# cheaper than they were:
#
#   - `line_was` took the "Saved $19.84" figure instead of the $37.96
#     strikethrough, because it picks the smallest amount above the line total
#     and the savings had grown larger than what was paid.
#   - `$5.00 /ea` matched as `5` — the optional cents group let the pattern
#     backtrack to a shorter number to get past its own `/ea` guard, dropping a
#     per-unit price into the line-total pool.
class OrderExtractPricesTest < Minitest::Test
  FETCH_PY = ROOT.join("pyworker", "fetch.py").freeze

  # The extractor is one long template; this pulls the standalone money block
  # out of it so a change to either end fails loudly rather than silently
  # testing a stale copy.
  def self.line_prices_js
    source = File.read(FETCH_PY)
    source[/^LINE_PRICES_JS = r"""\n(.*?)^"""$/m, 1] ||
      raise("LINE_PRICES_JS not found in #{FETCH_PY} — did it get renamed?")
  end

  def setup
    super
    skip "node not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)
  end

  def pick(text)
    script = "#{self.class.line_prices_js}\nconsole.log(JSON.stringify(pickLinePrices(#{text.to_json})));"
    out, err, status = Open3.capture3("node", "-e", script)
    flunk("node failed: #{err}") unless status.success?
    JSON.parse(out)
  end

  # ---- amounts that are prices ----------------------------------------

  def test_plain_amounts_are_prices
    assert_equal [37.96, 18.12], pick("$37.96 ... $18.12")
  end

  def test_a_price_ending_a_sentence_is_still_a_price
    assert_equal [37.96], pick("Order total $37.96.")
  end

  def test_thousands_separators_survive
    assert_equal [1234.56], pick("Total: $1,234.56.")
  end

  def test_whole_dollar_amounts_are_prices
    assert_equal [8.0, 10.0], pick("You pay $8.00. Was $10.00.")
  end

  # ---- amounts that are not prices ------------------------------------

  def test_per_unit_prices_are_skipped
    assert_equal [37.96], pick("$9.06 /ea. QTY 2 $37.96")
  end

  # The regression that started this: without the digit-boundary lookaheads the
  # amount backtracks to "5" so the `/ea` guard no longer applies, and a
  # per-unit price lands in the pool as $5.
  def test_a_per_unit_price_cannot_backtrack_past_the_guard
    assert_equal [], pick("$5.00 /ea")
  end

  def test_savings_are_not_prices
    assert_equal [37.96], pick("$37.96 Saved $19.84 with Volume Savings Discount")
  end

  # The same row carries the discount twice, phrased two different ways.
  def test_both_savings_phrasings_on_one_row
    assert_equal [5.56], pick("$5.56 Saved $1.98 with Member Discount: Save $3.88")
  end

  def test_savings_written_as_a_negative_or_in_parentheses
    assert_equal [], pick("Savings -$12.34")
    assert_equal [], pick("Savings ($5.00)")
    assert_equal [], pick("Savings\n-$12.34")
  end

  # "Subtotal" and "Was" both end in letters a loose savings pattern would
  # swallow. They are real prices.
  def test_labels_that_merely_look_like_savings_are_left_alone
    assert_equal [50.0], pick("Subtotal $50.00")
    assert_equal [10.0], pick("Was $10.00")
  end

  # ---- what the caller does with the result ---------------------------

  # `line_was` is the smallest amount above `line_total`. This is the whole
  # reason a stray savings figure mattered: it does not have to be the largest
  # number on the row to win, only larger than what was paid.
  def test_the_real_strikethrough_outranks_the_savings_it_used_to_lose_to
    prices = pick("$9.06 /ea. QTY 2 $37.96 $18.12 Saved $19.84 with Volume Savings Discount")
    line_total = prices.min
    assert_equal 18.12, line_total
    assert_equal 37.96, prices.select { |p| p > line_total }.min
  end
end
