require_relative "../../test_helper"
require "lowes/worker"
require "lowes/chrome"
require "lowes/commands/sync"

# A full sync is about half an hour of scraping, and it used to buffer every
# order and write once at the end. Two interrupted runs in one session cost 43
# and 67 orders that had already been fetched and paid for in requests to
# Lowe's — the store was byte-for-byte unchanged both times.
#
# So the question these tests ask is not "does a finished sync write the
# orders" but "what is on disk partway through, and what survives a run that
# never reaches its last line."
class SyncPartialWriteTest < Minitest::Test
  include XDGSandbox

  # Hands out orders the way the real worker does — one at a time, through the
  # block — and can stop partway. `after_each` is where the test gets to look at
  # the store mid-run, which is the only moment the interesting state exists.
  class FakeWorker
    def initialize(count, fail_after: nil, after_each: nil)
      @count = count
      @fail_after = fail_after
      @after_each = after_each
    end

    def sync(**_kwargs)
      emitted = []
      (1..@count).each do |i|
        order = { "order_id" => format("O%03d", i), "order_placed" => "2026-01-17",
                  "grand_total" => i.to_f }
        emitted << order
        yield order
        @after_each&.call(i)
        raise Lowes::Worker::Error, "worker exited 1" if i == @fail_after
      end
      emitted
    end
  end

  def setup
    super
    # Chrome and 1Password are the two things `Sync#run` reaches for before it
    # gets anywhere near the store. A cached session file is the same signal a
    # real logged-in run gives it.
    FileUtils.touch(Lowes::Config.cache_dir.join("storage_state.json"))
    @chrome = Lowes::Chrome.method(:ensure_started)
    Lowes::Chrome.define_singleton_method(:ensure_started) { |**_kw| true }
  end

  def teardown
    Lowes::Chrome.define_singleton_method(:ensure_started, @chrome)
    super
  end

  def run_sync(worker, argv: ["--year", "2026"])
    Lowes::Commands::Sync.new({ quiet: true, verbose: false }, worker: worker).run(argv)
  end

  # Read the index the way anything else on the system would: off disk. The
  # in-memory copy is exactly what a killed process does not get to keep. A
  # missing file is the honest answer for "nothing has been flushed yet".
  def index_on_disk
    return { "last_sync" => nil, "orders" => {} } unless Lowes::Config.index_path.exist?
    JSON.parse(File.read(Lowes::Config.index_path))
  end

  def test_a_finished_sync_writes_every_order_and_records_the_time
    assert_equal 0, run_sync(FakeWorker.new(3))

    index = index_on_disk
    assert_equal ["O001", "O002", "O003"], index["orders"].keys.sort
    refute_nil index["last_sync"]
  end

  # The whole point: the run dies, and what it had already fetched is still
  # there and still readable afterwards.
  def test_an_interrupted_run_keeps_what_it_already_fetched
    assert_raises(Lowes::Worker::Error) { run_sync(FakeWorker.new(10, fail_after: 4)) }

    assert_equal ["O001", "O002", "O003", "O004"], index_on_disk["orders"].keys.sort
    assert_equal 4, Lowes::Store.new.list_orders.length
  end

  # `last_sync` answers "when was this store last brought fully up to date",
  # and a run that crashed has not done that. Stamping it anyway would let the
  # next sync — or a human reading the index — believe the gap was checked.
  def test_an_interrupted_run_does_not_claim_it_synced
    assert_raises(Lowes::Worker::Error) { run_sync(FakeWorker.new(10, fail_after: 4)) }

    assert_nil index_on_disk["last_sync"]
  end

  # An order file with no index entry is an order nothing can find, so writing
  # the file is only half the work — and that half used to happen once, at the
  # end. The flush is periodic rather than per-order because rewriting the
  # whole index hundreds of times is real work for no gain, so what this pins
  # is both halves of the trade: the index does become readable partway
  # through, and it does not move on every single order.
  def test_the_index_catches_up_on_a_schedule_rather_than_at_the_end
    every = Lowes::Commands::Sync::INDEX_FLUSH_EVERY
    listed = []
    run_sync(FakeWorker.new(every + 2, after_each: ->(_i) { listed << index_on_disk["orders"].length }))

    assert_equal Array.new(every - 1, 0), listed.first(every - 1)
    assert_equal [every, every, every], listed.last(3)
    assert_equal every + 2, index_on_disk["orders"].length
  end

  # `--no-full-details` orders arrive with no line items by design, and the
  # store refuses to shrink an order that has some. Streaming does not change
  # which of those wins: writing early must be a smaller version of the same
  # result, not a different one.
  def test_writing_early_still_protects_stored_line_items
    seed = Lowes::Store.new
    seed.write_order({ "order_id" => "O001", "order_placed" => "2026-01-17",
                       "grand_total" => 1.0, "items" => [{ "title" => "2x4" }] })
    seed.commit_index!

    _out, err = capture_io do
      assert_equal 0, run_sync(FakeWorker.new(1), argv: ["--year", "2026", "--no-full-details"])
    end

    assert_equal [{ "title" => "2x4" }], Lowes::Store.new.read_order("O001")["items"]
    refute_match(/line item/, err)
  end
end
