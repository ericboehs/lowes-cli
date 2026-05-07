require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "pathname"

ROOT = Pathname(__dir__).join("..").realpath
$LOAD_PATH.unshift(ROOT.join("lib").to_s)

require "lowes/config"
require "lowes/store"
require "lowes/formatter"
require "lowes/commands/quotes"

module XDGSandbox
  def setup
    super
    @tmp = Dir.mktmpdir("lowes-test-")
    @prev_env = {}
    %w[XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME].each do |k|
      @prev_env[k] = ENV[k]
      ENV[k] = File.join(@tmp, k.downcase.sub("xdg_", "").sub("_home", ""))
    end
    Lowes::Config.ensure_dirs!
    Lowes::Config.write_default!
  end

  def teardown
    @prev_env.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(@tmp) if @tmp && File.directory?(@tmp)
    super
  end
end
