require "json"
require "open3"
require "io/console"
require_relative "stderr_tail"

module Lowes
  class Worker
    class Error < StandardError; end

    PYWORKER = File.expand_path("../../pyworker", __dir__)

    def initialize(verbose: false, quiet: false)
      @verbose = verbose
      @quiet = quiet
    end

    # Generic action runner. Streams events, returns a hash:
    #   { orders: [...], quotes: [...], prices: [...] }
    # Accepts either a request hash positionally or keyword args (which we
    # symbolize/stringify into the request).
    def run_action(request_or_kwargs = nil, **kwargs)
      request = request_or_kwargs || kwargs
      request = request.transform_keys(&:to_s) if request.is_a?(Hash)
      _run_action(request)
    end

    def _run_action(request)
      results = { orders: [], quotes: [], prices: [] }
      error_msg = nil
      progress = Progress.new(quiet: @quiet)
      run(request) do |event|
        case event["event"]
        when "order"    then results[:orders] << event["data"]
        when "quote"    then results[:quotes] << event["data"]
        when "price"    then results[:prices] << event["data"]
        when "total"    then progress.start(event)
        when "progress" then progress.tick(event)
        when "log"
          level = event["level"] || "info"
          progress.clear
          warn("[worker:#{level}] #{event["msg"]}") if @verbose || level == "warn"
        when "done"
          progress.finish(event)
          return results
        when "error"    then error_msg = event["msg"]
        end
      end
      progress.clear
      raise Error, error_msg if error_msg && results.values.all?(&:empty?)
      warn("lowes: partial run — #{error_msg}") if error_msg
      results
    end

    # `stored_order_dates` is what the store already has, and it is deliberately
    # not the same list as `known_order_ids`: `--full` empties the skip list so
    # every order is re-fetched, but it does not make the store forget what is
    # in it. The worker uses the dates to notice a date range that came back
    # emptier than the store says it should be.
    def sync(email:, password:, years:, full_details: true, otp_secret: nil, rate_limit: {},
             known_order_ids: [], stored_order_dates: [])
      request = {
        action: "sync_orders",
        email: email,
        password: password,
        years: years,
        full_details: full_details,
        otp_secret: otp_secret,
        detail_delay: rate_limit["detail_delay"],
        detail_jitter: rate_limit["detail_jitter"],
        retry_backoff: rate_limit["retry_backoff"],
        known_order_ids: known_order_ids,
        stored_order_dates: stored_order_dates
      }.compact
      _run_action(request)[:orders]
    end

    def fetch_prices(items:, store_zip: nil)
      request = {
        action: "fetch_prices",
        items: items,
        store_zip: store_zip
      }.compact
      _run_action(request)[:prices]
    end

    class Progress
      BAR_WIDTH = 20

      def initialize(quiet: false)
        @quiet = quiet
        @tty = $stderr.tty?
        @line_drawn = false
        @start_time = nil
      end

      def start(event)
        return if @quiet
        label = event["year"] ? "year #{event["year"]}" : (event["label"] || "items")
        warn("#{label}: #{event["count"]}")
        @start_time = nil
      end

      def tick(event)
        return if @quiet
        @start_time ||= Time.now
        total = event["grand_total"] ? format("$%.2f", event["grand_total"]) : "         "
        eta = format_eta(event["i"], event["n"])
        line = format(
          "  [%3d/%-3d] %s %s %s %s  %s  %s",
          event["i"], event["n"],
          bar(event["i"], event["n"]),
          eta,
          event["date"] || "??????????",
          total,
          event["order_id"] || event["item_id"] || "",
          event["title"].to_s
        )
        if @tty
          width = (ENV["COLUMNS"] || `tput cols 2>/dev/null`.to_i.nonzero? || 100).to_i
          line = line[0, width - 1]
          $stderr.print "\r\e[2K#{line}"
          $stderr.flush
          @line_drawn = true
        else
          $stderr.puts line
        end
      end

      def clear
        return unless @tty && @line_drawn
        $stderr.print "\r\e[2K"
        $stderr.flush
        @line_drawn = false
      end

      def finish(event)
        clear
        return if @quiet
        skipped = event["skipped"].to_i
        suffix = skipped.positive? ? " (#{skipped} skipped)" : ""
        warn("done: #{event["count"]} items#{suffix}")
      end

      private

      def bar(i, n)
        return "[" + ("░" * BAR_WIDTH) + "]" if n.to_i.zero?
        filled = (i.to_f / n * BAR_WIDTH).round
        "[" + ("█" * filled) + ("░" * (BAR_WIDTH - filled)) + "]"
      end

      def format_eta(i, n)
        return "ETA --:--" if @start_time.nil? || i.to_i <= 0 || n.to_i <= 0
        elapsed = Time.now - @start_time
        remaining = (elapsed / i) * (n - i)
        return "ETA --:--" if remaining.nan? || remaining.infinite? || remaining < 0
        secs = remaining.to_i
        if secs >= 3600
          format("ETA %d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
        else
          format("ETA %2d:%02d", secs / 60, secs % 60)
        end
      end
    end

    private

    # The worker builds its own User-Agent for the no-CDP fallback path, from
    # its own copy of the platform table. Handing it the values Ruby resolved
    # is what keeps the two from drifting: `browser.user_agent` and
    # `browser.binary` in config.json reach the worker only through here.
    def worker_env
      require_relative "chrome"
      env = {}
      binary = Lowes::Chrome.browser_config["binary"]
      env["LOWES_CHROME_BINARY"] = binary if binary
      env["LOWES_USER_AGENT"] = Lowes::Chrome.user_agent
      env
    rescue StandardError => e
      # A UA we can't build is not worth failing a sync over — the worker has
      # its own fallback, and this path only matters when CDP is unreachable.
      warn "lowes: could not resolve a User-Agent for the worker (#{e.message})"
      {}
    end

    def run(request)
      cmd = python_cmd
      Open3.popen3(worker_env, *cmd, chdir: PYWORKER) do |stdin, stdout, stderr, wait|
        stdin.write(JSON.generate(request) + "\n")

        err_thread, err_lines = StderrTail.drain(stderr, echo: @verbose)

        stdout.each_line do |line|
          line = line.strip
          next if line.empty?
          event = parse_event(line)
          next unless event

          case event["event"]
          when "otp_required"
            answer = prompt_secret(event["prompt"] || "OTP")
            stdin.write(answer + "\n")
          when "prompt"
            answer = prompt_text(event)
            stdin.write(answer + "\n")
          else
            yield event
            return if event["event"] == "done" || event["event"] == "error"
          end
        end

        begin
          stdin.close
        rescue IOError, Errno::EPIPE
        end
        err_thread.join
        status = wait.value
        unless status.success?
          # "python worker exited 1" on its own says nothing. The reason was on
          # stderr a moment ago; print it before the exception replaces it.
          StderrTail.report(err_lines, "lowes: worker exited #{status.exitstatus}") unless @verbose
          raise Error, "python worker exited #{status.exitstatus}"
        end
      end
    end

    def parse_event(line)
      JSON.parse(line)
    rescue JSON::ParserError
      warn("[worker] non-JSON output: #{line}") if @verbose
      nil
    end

    def python_cmd
      venv = File.join(PYWORKER, ".venv", "bin", "python")
      return [venv, "fetch.py"] if File.executable?(venv)
      ["python3", "fetch.py"]
    end

    def prompt_text(event)
      msg = event["prompt"].to_s
      choices = event["choices"] || []
      choices.each { |c| $stderr.puts(c) }
      $stderr.print("--> #{msg}: ")
      $stderr.flush
      $stdin.gets.to_s.chomp
    end

    def prompt_secret(msg)
      $stderr.print("--> #{msg}: ")
      $stderr.flush
      if $stdin.respond_to?(:noecho) && $stdin.tty?
        code = $stdin.noecho(&:gets).to_s.chomp
        $stderr.puts
        code
      else
        $stdin.gets.to_s.chomp
      end
    end
  end
end
