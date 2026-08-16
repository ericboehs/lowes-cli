require_relative "../test_helper"
require "lowes/worker"

# A sync run is long enough that "what the caller gets at the end" and "what the
# caller could have had by now" are different questions. The worker already had
# every order in hand the moment it read it; the block is how that reaches a
# caller that wants to do something durable with it.
class WorkerStreamTest < Minitest::Test
  # Replaces the python worker with a fixed script of events. `run` is where the
  # subprocess lives, so overriding it leaves the whole event loop under test.
  class ScriptedWorker < Lowes::Worker
    # `trace` is shared with the test's callback on purpose: the interleaving of
    # the two is the claim being made. A worker that collected everything and
    # replayed it at the end would produce the same set of entries in a
    # different order.
    def initialize(events, trace)
      super(quiet: true)
      @events = events
      @trace = trace
    end

    def run(request)
      @events.each do |event|
        @trace << "emit:#{event["data"]["order_id"]}" if event["event"] == "order"
        yield event
        return if event["event"] == "done"
      end
    end
  end

  def order_event(id)
    { "event" => "order", "data" => { "order_id" => id } }
  end

  def sync(events, trace = [], &block)
    worker = ScriptedWorker.new(events, trace)
    orders = worker.sync(email: "e@x.test", password: "pw", years: [2026], &block)
    [orders, trace]
  end

  def test_each_order_arrives_before_the_next_one_is_read
    trace = []
    events = [order_event("A"), order_event("B"), { "event" => "done", "count" => 2 }]
    sync(events, trace) { |o| trace << "got:#{o["order_id"]}" }

    assert_equal ["emit:A", "got:A", "emit:B", "got:B"], trace
  end

  # Every other caller of `sync` — and `run_action` — still wants the whole run
  # as a list. Streaming is an addition, not a replacement.
  def test_the_full_list_still_comes_back
    events = [order_event("A"), order_event("B"), { "event" => "done", "count" => 2 }]
    orders, = sync(events) { |_o| }

    assert_equal ["A", "B"], orders.map { |o| o["order_id"] }
  end

  def test_a_caller_without_a_block_is_unaffected
    events = [order_event("A"), { "event" => "done", "count" => 1 }]
    orders, = sync(events)

    assert_equal ["A"], orders.map { |o| o["order_id"] }
  end

  # The reason any of this exists. A run that dies partway used to hand back
  # nothing, so the orders it had already fetched were thrown away; the caller
  # must have seen them before the failure, not after it.
  def test_orders_emitted_before_a_crash_have_already_arrived
    seen = []
    events = [order_event("A"), order_event("B")]
    worker = ScriptedWorker.new(events, [])
    def worker.run(request)
      super { |e| yield e }
      raise Lowes::Worker::Error, "worker exited 1"
    end

    assert_raises(Lowes::Worker::Error) do
      worker.sync(email: "e@x.test", password: "pw", years: [2026]) { |o| seen << o["order_id"] }
    end
    assert_equal ["A", "B"], seen
  end
end
