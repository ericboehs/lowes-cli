require_relative "../test_helper"
require "stringio"
require "lowes/stderr_tail"

# The worker's stderr used to be read only to be thrown away unless --verbose,
# which meant a Python traceback was invisible on exactly the runs that ended
# in "python worker exited 1". These cover the buffer that keeps it.
class LowesStderrTailTest < Minitest::Test
  def test_captures_lines_without_echoing_by_default
    _, err = capture_io do
      thread, lines = Lowes::StderrTail.drain(StringIO.new("boom\ntraceback\n"))
      thread.join
      @lines = lines
    end
    assert_equal ["boom", "traceback"], @lines
    assert_empty err
  end

  def test_echoes_live_when_asked
    _, err = capture_io do
      thread, = Lowes::StderrTail.drain(StringIO.new("boom\n"), echo: true)
      thread.join
    end
    assert_equal "boom\n", err
  end

  # A chatty worker must not turn the buffer into a memory leak; the tail is
  # the part a traceback lives in anyway.
  def test_keeps_only_the_tail
    thread, lines = Lowes::StderrTail.drain(StringIO.new((1..200).map { |i| "line #{i}\n" }.join))
    thread.join
    assert_equal Lowes::StderrTail::KEEP, lines.size
    assert_equal "line 200", lines.last
  end

  # The old code rescued IOError into nothing, so a reader that died partway
  # through was indistinguishable from a worker that had nothing to say. Raised
  # from a stub rather than by closing a real pipe mid-read, which would make
  # the assertion a race.
  class DyingIO
    def each_line
      yield "first\n"
      raise IOError, "stream closed in another thread"
    end
  end

  def test_a_dead_reader_leaves_a_note_rather_than_silence
    thread, lines = Lowes::StderrTail.drain(DyingIO.new)
    thread.join
    assert_includes lines, "first"
    assert_match(/stopped reading worker stderr.*stream closed/, lines.last)
  end

  def test_report_prefixes_and_indents_what_it_replays
    _, err = capture_io { Lowes::StderrTail.report(%w[boom bang], "lowes: worker exited 1") }
    assert_equal "lowes: worker exited 1 — worker stderr:\n  boom\n  bang\n", err
  end

  def test_report_says_nothing_when_there_was_nothing
    _, err = capture_io { Lowes::StderrTail.report([], "lowes: worker exited 1") }
    assert_empty err
  end
end
