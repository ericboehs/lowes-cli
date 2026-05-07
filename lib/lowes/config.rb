require "json"
require "fileutils"

module Lowes
  class Config
    DEFAULTS = {
      "default_year_window" => 2,
      "output" => { "color" => true },
      "rate_limit" => {
        "detail_delay" => 0.5,
        "detail_jitter" => 0.25,
        "retry_backoff" => [30, 60, 120]
      }
    }.freeze

    attr_reader :data

    def initialize(data)
      @data = DEFAULTS.merge(data || {})
    end

    def email = data["email"]
    def password_op_ref = data["password_op_ref"]
    def otp_op_ref = data["otp_op_ref"]
    def default_year_window = data["default_year_window"]
    def store_zip = data["store_zip"]
    def color? = data.dig("output", "color") != false
    def rate_limit = data["rate_limit"] || {}
    def default_tax_rate = data["default_tax_rate"]

    class << self
      def xdg_config_home
        ENV["XDG_CONFIG_HOME"] ? Pathname(ENV["XDG_CONFIG_HOME"]) : Pathname(Dir.home).join(".config")
      end

      def xdg_data_home
        ENV["XDG_DATA_HOME"] ? Pathname(ENV["XDG_DATA_HOME"]) : Pathname(Dir.home).join(".local/share")
      end

      def xdg_state_home
        ENV["XDG_STATE_HOME"] ? Pathname(ENV["XDG_STATE_HOME"]) : Pathname(Dir.home).join(".local/state")
      end

      def config_dir = xdg_config_home.join("lowes")
      def config_path = config_dir.join("config.json")
      def data_dir = xdg_data_home.join("lowes")
      def orders_dir = data_dir.join("orders")
      def prices_dir = data_dir.join("prices")
      def cache_dir = data_dir.join("cache")
      def index_path = data_dir.join("index.json")
      def materials_path = data_dir.join("materials.json")
      def state_dir = xdg_state_home.join("lowes")
      def sync_log_path = state_dir.join("sync.log")

      def ensure_dirs!
        [config_dir, data_dir, orders_dir, prices_dir, cache_dir, state_dir].each do |d|
          FileUtils.mkdir_p(d)
        end
        File.chmod(0o700, cache_dir) if File.directory?(cache_dir)
      end

      def load
        ensure_dirs!
        unless config_path.exist?
          raise "config not found at #{config_path}\n" \
                "Run: lowes config edit"
        end
        new(JSON.parse(File.read(config_path)))
      end

      def write_default!
        ensure_dirs!
        return if config_path.exist?
        File.write(config_path, JSON.pretty_generate({
          "email" => "you@example.com",
          "password_op_ref" => "op://Personal/Lowes/password",
          "otp_op_ref" => nil,
          "default_year_window" => 2,
          "store_zip" => nil,
          "output" => { "color" => true }
        }) + "\n")
      end
    end
  end
end
