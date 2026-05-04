require "fileutils"
require "open3"
require "net/http"

module Lowes
  # Helpers for ensuring a CDP-attached Chrome is reachable.
  # Used by sync/login/price/store/quotes — the commands that spawn the
  # Python worker, which expects http://127.0.0.1:9222 to answer.
  module Chrome
    CDP_URL = "http://127.0.0.1:9222"

    module_function

    def cdp_reachable?(timeout: 1.0)
      uri = URI("#{CDP_URL}/json/version")
      Net::HTTP.start(uri.host, uri.port, open_timeout: timeout, read_timeout: timeout) do |http|
        http.get(uri.request_uri).is_a?(Net::HTTPSuccess)
      end
    rescue StandardError
      false
    end

    # Returns true if Chrome is up (already-running or just-started),
    # false if we couldn't bring it up.
    def ensure_started(quiet: false)
      return true if cdp_reachable?

      warn("lowes: starting Chrome (no CDP on 9222)") unless quiet
      Lowes::Commands::ChromeStart.new(silent: quiet).run([])

      # Wait up to 20s for the port to come up
      deadline = Time.now + 20
      until Time.now > deadline
        return true if cdp_reachable?
        sleep 0.5
      end
      false
    end
  end
end
