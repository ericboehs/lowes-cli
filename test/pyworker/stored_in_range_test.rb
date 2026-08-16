require_relative "../test_helper"
require "open3"

# A full sync over 2022-2026 came back with 313 of 323 orders. The ten missing
# were 2026-01-17 through 2026-03-28 — exactly one quarter, which had failed to
# load. The reason was already being emitted, at `info`, which the Ruby side
# hides unless `--verbose`. A whole quarter vanished and the output was clean.
#
# `_stored_in_range` is what makes that quarter distinguishable from a quarter
# with genuinely nothing in it: orders do not leave a date range once they are
# in it, so what the store already holds is the floor the page has to clear.
class StoredInRangeTest < Minitest::Test
  PYWORKER = ROOT.join("pyworker").freeze

  def setup
    super
    skip "python3 not installed" unless system("python3", "--version", out: File::NULL, err: File::NULL)
  end

  def count(dates, start, finish)
    script = <<~PY
      import json, sys
      from datetime import date
      sys.path.insert(0, #{PYWORKER.to_s.dump})
      import fetch
      s = date.fromisoformat(#{start.dump})
      e = date.fromisoformat(#{finish.dump})
      print(fetch._stored_in_range(json.loads(#{dates.to_json.dump}), s, e))
    PY
    out, err, status = Open3.capture3("python3", "-c", script)
    flunk("python failed: #{err}") unless status.success?
    Integer(out.strip)
  end

  def test_it_counts_what_falls_inside_the_range
    dates = ["2026-01-17", "2026-02-28", "2026-03-28", "2026-04-02"]
    assert_equal 3, count(dates, "2026-01-01", "2026-03-31")
  end

  # Quarters are built as inclusive bounds and butt directly against each
  # other, so an order dated exactly on a boundary belongs to one quarter and
  # must not be missing from it.
  def test_both_bounds_are_inside
    assert_equal 2, count(["2026-01-01", "2026-03-31"], "2026-01-01", "2026-03-31")
  end

  def test_a_day_either_side_is_outside
    assert_equal 0, count(["2025-12-31", "2026-04-01"], "2026-01-01", "2026-03-31")
  end

  def test_a_genuinely_empty_range_expects_nothing
    assert_equal 0, count(["2024-05-05"], "2026-01-01", "2026-03-31")
  end

  def test_an_empty_store_expects_nothing
    assert_equal 0, count([], "2026-01-01", "2026-03-31")
  end

  # An index entry can carry a null or malformed date. Counting it in would
  # invent an expectation the page can never meet and warn on every sync; the
  # honest answer for a date we cannot read is to expect nothing from it.
  def test_dates_it_cannot_read_are_counted_nowhere
    assert_equal 1, count(["not-a-date", "", "2026-02-02"], "2026-01-01", "2026-03-31")
  end

  # Lowe's dates are plain `YYYY-MM-DD`, but an entry written with a time on it
  # still names a day inside the range and should not fall out of it. The last
  # day of the quarter is where that bites: compared whole, `2026-03-31T10:00Z`
  # sorts past a range ending `2026-03-31`.
  def test_a_timestamped_date_still_lands_in_its_range
    assert_equal 1, count(["2026-02-02T14:03:00Z"], "2026-01-01", "2026-03-31")
    assert_equal 1, count(["2026-03-31T10:00:00Z"], "2026-01-01", "2026-03-31")
  end
end
