module Lowes
  # The Python worker's stderr is where an unhandled traceback goes, and it is
  # the only place it goes — the NDJSON `error` event only covers the failures
  # the worker anticipated. Discarding it unless `--verbose` means the runs
  # that most need explaining are the ones explained least, so it is always
  # captured and replayed when the exit status says something went wrong.
  module StderrTail
    # A traceback plus its context, not a whole session's chatter.
    KEEP = 50

    # Drains `io` on a thread so the pipe can't fill and stall the worker.
    # Returns [thread, lines]; `lines` is only safe to read once the thread has
    # been joined.
    def self.drain(io, echo: false)
      lines = []
      thread = Thread.new do
        io.each_line do |raw|
          line = raw.chomp
          lines << line
          lines.shift while lines.size > KEEP
          warn(line) if echo
        end
      rescue IOError => e
        # The pipe closing under us is ordinary at shutdown. Anything else
        # means the remaining diagnostics are gone — worth one line, because a
        # thread dying quietly is how that becomes invisible.
        lines << "(stopped reading worker stderr: #{e.message})"
      end
      [thread, lines]
    end

    # Replays what was captured. For the failure paths where nothing else will.
    def self.report(lines, prefix)
      return if lines.empty?
      warn "#{prefix} — worker stderr:"
      lines.each { |line| warn("  #{line}") }
    end
  end
end
