require_relative "../test_helper"
require "lowes/worker"

# The worker can only notice a date range that came back short if it is told
# what the store already holds. That fact travels from the index, through
# `Commands::Sync`, into the request — and every hop is somewhere it can be
# dropped without anything failing, because a missing expectation just means a
# warning that never fires.
class SyncRequestTest < Minitest::Test
  # Stops at the request rather than running anything: what is being checked is
  # what the worker gets told, and a real run would need Chrome and a login.
  class CapturingWorker < Lowes::Worker
    attr_reader :request

    def _run_action(request)
      @request = request
      { orders: [], quotes: [], prices: [] }
    end
  end

  def sync_request(**kwargs)
    worker = CapturingWorker.new
    worker.sync(email: "e@x.test", password: "pw", years: [2026], **kwargs)
    worker.request
  end

  def test_the_stored_dates_reach_the_worker
    request = sync_request(stored_order_dates: ["2026-01-17", "2026-02-28"])
    assert_equal ["2026-01-17", "2026-02-28"], request[:stored_order_dates]
  end

  # `.compact` drops nil values from the request, and an empty array is not
  # nil — but a caller that passes nothing should still produce a request the
  # worker can read rather than one missing the key in a way it has to guess at.
  def test_an_empty_store_still_sends_a_list
    assert_equal [], sync_request[:stored_order_dates]
  end

  # The two lists answer different questions and `--full` empties only one of
  # them. If they were the same list, the sync most in need of this check —
  # the full re-sync, where the bug was found — would be the one without it.
  def test_a_full_resync_still_reports_what_the_store_holds
    request = sync_request(known_order_ids: [], stored_order_dates: ["2026-01-17"])
    assert_empty request[:known_order_ids]
    assert_equal ["2026-01-17"], request[:stored_order_dates]
  end
end

# `Commands::Sync` is the hop that reads the index, and it reads a different
# field than the one it passes for skipping (`date`, not the order id).
class SyncCommandStoredDatesTest < Minitest::Test
  include XDGSandbox

  def test_the_dates_come_off_the_index_entries
    store = Lowes::Store.new
    store.write_order({ "order_id" => "A", "order_placed" => "2026-01-17", "grand_total" => 1.0 })
    store.write_order({ "order_id" => "B", "order_placed" => "2026-02-28", "grand_total" => 2.0 })

    dates = store.index["orders"].values.filter_map { |m| m["date"] }
    assert_equal ["2026-01-17", "2026-02-28"], dates.sort
  end

  # An order whose date could not be parsed still gets an index entry. It must
  # not arrive as a nil that the worker then has to defend against.
  def test_an_entry_without_a_date_is_left_out
    store = Lowes::Store.new
    store.write_order({ "order_id" => "A", "grand_total" => 1.0 })

    dates = store.index["orders"].values.filter_map { |m| m["date"] }
    assert_empty dates
  end
end
