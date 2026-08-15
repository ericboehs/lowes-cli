require_relative "../test_helper"
require "open3"

# A `--full` re-sync of 2023 came back with no line items on 23 order pages.
# Re-reading those same pages moments later gave the full lists back for most
# of them — order 33434280 returned 11 items once and 34 on two separate
# re-reads — while a handful stayed empty no matter how often they were asked,
# because Lowe's serves a bare "Order Details" shell for some older orders.
#
# `order_detail` is the seam that tells those apart: it reloads once, and only
# what survives the reload gets warned about. These drive the real function out
# of the real file against a fake page, so a page that renders short and a page
# with nothing on it stay distinguishable.
class OrderDetailRetryTest < Minitest::Test
  PYWORKER = ROOT.join("pyworker").freeze

  def setup
    super
    skip "python3 not installed" unless system("python3", "--version", out: File::NULL, err: File::NULL)
  end

  # `reads` is what the extractor returns on successive visits, so a test says
  # "empty, then two items" and nothing else has to be arranged. The fake page
  # counts its own loads, which is how "did it reload?" gets asked directly
  # rather than inferred from the result.
  def order_detail(*reads, delay: 0.0)
    script = <<~PY
      import json, sys, time
      sys.path.insert(0, #{PYWORKER.to_s.dump})
      import fetch

      slept = []
      time.sleep = slept.append

      class FakePage:
          def __init__(self, reads):
              self.reads = list(reads)
              self.loads = []
          def goto(self, url, **kw): self.loads.append(url)
          def wait_for_timeout(self, ms): pass
          def evaluate(self, js):
              if js is fetch.EXPAND_ITEMS_JS: return None
              return self.reads.pop(0) if self.reads else None

      page = FakePage(json.loads(#{reads.to_json.dump}))
      detail = fetch.order_detail(page, "https://example.test/o/1", "33434280", #{delay}, 0.0)
      sys.stderr.write(json.dumps({"detail": detail, "loads": page.loads, "slept": slept}))
    PY
    out, err, status = Open3.capture3("python3", "-c", script)
    flunk("python failed: #{err}") unless status.success?
    result = JSON.parse(err)
    logs = out.lines.map { |l| JSON.parse(l) }
    [result["detail"], result["loads"].length, logs, result["slept"]]
  end

  # ---- the page that renders fine ------------------------------------

  def test_a_page_with_items_is_read_once
    detail, loads, logs = order_detail({ "items" => [{ "title" => "stud" }] })
    assert_equal 1, detail["items"].length
    assert_equal 1, loads
    assert_empty logs
  end

  # ---- the page that rendered short ----------------------------------

  # The 33434280 case. Nothing about the first read says it is wrong; the only
  # evidence available is that asking again gives a different answer.
  def test_an_empty_first_read_is_asked_again
    detail, loads, = order_detail({ "items" => [] }, { "items" => [{ "title" => "stud" }, { "title" => "screw" }] })
    assert_equal 2, detail["items"].length
    assert_equal 2, loads
  end

  def test_a_recovered_read_is_reported_rather_than_slipped_in
    _, _, logs = order_detail({ "items" => [] }, { "items" => [{ "title" => "stud" }, { "title" => "screw" }] })
    assert_equal ["info"], logs.map { |l| l["level"] }
    assert_includes logs[0]["msg"], "came back empty"
    assert_includes logs[0]["msg"], "a reload found 2 line items"
  end

  # An extractor that returns nothing at all is the same failure as one that
  # returns an empty list, and it arrives via `page.evaluate() or {}`.
  def test_an_extractor_returning_nothing_counts_as_empty
    detail, loads, = order_detail(nil, { "items" => [{ "title" => "stud" }] })
    assert_equal 1, detail["items"].length
    assert_equal 2, loads
  end

  # ---- the page that has nothing on it -------------------------------

  def test_a_page_that_is_empty_twice_is_only_asked_twice
    _, loads, = order_detail({ "items" => [] }, { "items" => [] })
    assert_equal 2, loads
  end

  def test_a_page_that_is_empty_twice_says_so
    _, _, logs = order_detail({ "items" => [] }, { "items" => [] })
    assert_equal ["warn"], logs.map { |l| l["level"] }
    assert_includes logs[0]["msg"], "33434280"
    assert_includes logs[0]["msg"], "none on a reload"
  end

  # The shell still carries a status and a total even with no line content,
  # and those are worth keeping — an order stored without its status is a
  # second, smaller version of the bug this whole seam exists to stop.
  def test_the_summary_fields_survive_a_doubly_empty_page
    detail, = order_detail({ "items" => [], "status" => "Delivered", "total_paid" => 41.2 },
                           { "items" => [], "status" => "Delivered", "total_paid" => 41.2 })
    assert_equal "Delivered", detail["status"]
    assert_equal 41.2, detail["total_paid"]
  end

  # The reload is a fresh render, so it can come back knowing less than the
  # first read did. Nothing here is evidence that the second look is better.
  def test_the_first_read_wins_when_the_reload_knows_less
    detail, = order_detail({ "items" => [], "status" => "Delivered" }, { "items" => [] })
    assert_equal "Delivered", detail["status"]
  end

  # Preferring the first read is the rule, but "first" has to mean a read that
  # actually returned something.
  def test_a_blank_first_read_falls_through_to_the_second
    detail, = order_detail(nil, { "items" => [], "status" => "Cancelled" })
    assert_equal "Cancelled", detail["status"]
  end

  # ---- the retry is still a request ----------------------------------

  # A reload is another page load against Lowe's, on the orders most likely to
  # be old and odd. Skipping the configured delay for it would turn the worst
  # pages into the fastest-hammered ones.
  def test_the_reload_waits_out_the_configured_delay
    _, _, _, slept = order_detail({ "items" => [] }, { "items" => [] }, delay: 0.5)
    assert_equal [0.5], slept
  end

  def test_a_page_that_reads_fine_waits_for_nothing
    _, _, _, slept = order_detail({ "items" => [{ "title" => "stud" }] }, delay: 0.5)
    assert_empty slept
  end
end
