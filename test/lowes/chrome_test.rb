require_relative "../test_helper"
require "json"
require "lowes/chrome"
require "lowes/commands/chrome_start"

# The headless launch is the whole point of these two classes, and it is one
# flag away from being silently refused by Akamai — `--headless` without a
# matching `--user-agent` gets 403 Access Denied. So the argv is asserted on
# directly rather than through anything that would have to start a browser.
class ChromeStartArgvTest < Minitest::Test
  include XDGSandbox

  PROFILE = "/tmp/lowes-test-profile".freeze

  def command(headless)
    cmd = Lowes::Commands::ChromeStart.new(quiet: true)
    cmd.send(:command, chrome_binary, 9222, PROFILE, "https://www.lowes.com/", headless)
  end

  # Real if it is there, a stub that answers `--version` if it isn't, so this
  # asserts on the same code path on a laptop and in CI.
  def chrome_binary
    real = Lowes::Commands::ChromeStart::CHROME_APP
    return real if File.exist?(real)

    @stub ||= begin
      path = File.join(@tmp, "chrome")
      File.write(path, "#!/bin/sh\necho 'Google Chrome 151.0.7922.109'\n")
      File.chmod(0o755, path)
      path
    end
  end

  def test_headed_launch_passes_no_headless_and_no_user_agent
    cmd = command(false)
    refute_includes cmd, "--headless"
    assert_nil cmd.find { |a| a.start_with?("--user-agent=") }
  end

  def test_headless_launch_always_carries_a_user_agent
    cmd = command(true)
    assert_includes cmd, "--headless"
    ua = cmd.find { |a| a.start_with?("--user-agent=") }
    refute_nil ua, "--headless without --user-agent is refused by Akamai"
    refute_includes ua, "HeadlessChrome"
  end

  def test_user_agent_names_the_version_the_binary_reports
    ua = command(true).find { |a| a.start_with?("--user-agent=") }
    version = IO.popen([chrome_binary, "--version"], &:read)[/\d+/]
    assert_includes ua, "Chrome/#{version}.0.0.0"
  end

  def test_configured_user_agent_wins
    write_config("browser" => { "user_agent" => "Mozilla/5.0 (custom)" })
    assert_includes command(true), "--user-agent=Mozilla/5.0 (custom)"
  end

  def test_both_modes_keep_the_debugging_port_and_profile
    [true, false].each do |headless|
      cmd = command(headless)
      assert_includes cmd, "--remote-debugging-port=9222"
      assert_includes cmd, "--user-data-dir=#{PROFILE}"
      assert_equal "https://www.lowes.com/", cmd.last
    end
  end

  private

  def write_config(extra)
    path = Lowes::Config.config_path
    data = JSON.parse(File.read(path)).merge(extra)
    File.write(path, JSON.pretty_generate(data))
  end
end

class ChromeHeadlessDefaultTest < Minitest::Test
  include XDGSandbox

  def setup
    super
    @prev_headless = ENV["LOWES_HEADLESS"]
    ENV.delete("LOWES_HEADLESS")
  end

  def teardown
    ENV["LOWES_HEADLESS"] = @prev_headless
    super
  end

  def test_defaults_to_headless_with_no_config_and_no_env
    assert Lowes::Chrome.headless_default?
  end

  def test_env_var_forces_a_window
    %w[0 false no off FALSE].each do |value|
      ENV["LOWES_HEADLESS"] = value
      refute Lowes::Chrome.headless_default?, "LOWES_HEADLESS=#{value} should mean headed"
    end
  end

  def test_env_var_beats_config
    write_browser("headless" => false)
    ENV["LOWES_HEADLESS"] = "1"
    assert Lowes::Chrome.headless_default?
  end

  def test_config_can_ask_for_a_window
    write_browser("headless" => false)
    refute Lowes::Chrome.headless_default?
  end

  private

  def write_browser(browser)
    path = Lowes::Config.config_path
    data = JSON.parse(File.read(path)).merge("browser" => browser)
    File.write(path, JSON.pretty_generate(data))
  end
end

# `running_headless?` is what stops `lowes login` from asking someone to type
# into a window that isn't there, so it is worth pinning to real `ps` output.
class ChromeProcessDetectionTest < Minitest::Test
  PROFILE = "/Users/x/.local/share/lowes/cache/chrome-profile".freeze

  BROWSER_HEADED = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome " \
                   "--remote-debugging-port=9222 --user-data-dir=#{PROFILE} https://www.lowes.com/".freeze
  BROWSER_HEADLESS = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome " \
                     "--remote-debugging-port=9222 --user-data-dir=#{PROFILE} --headless " \
                     "--user-agent=Mozilla/5.0 https://www.lowes.com/".freeze
  # A renderer inherits both the profile and the headless flag, and there are a
  # dozen of them. Matching one would report the wrong pid to signal.
  HELPER = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper " \
           "--type=renderer --headless --user-data-dir=#{PROFILE}".freeze

  def with_processes(lines)
    Lowes::Chrome.define_singleton_method(:processes) { lines.map { |l| l + "\n" } }
    yield
  ensure
    Lowes::Chrome.singleton_class.send(:remove_method, :processes)
  end

  def test_finds_the_browser_process_not_its_helpers
    with_processes([HELPER, BROWSER_HEADED]) do
      assert_equal BROWSER_HEADED, Lowes::Chrome.running_argv(profile: PROFILE).strip
    end
  end

  def test_reports_headless_when_the_browser_is_headless
    with_processes([BROWSER_HEADLESS]) do
      assert Lowes::Chrome.running_headless?(profile: PROFILE)
    end
  end

  def test_reports_headed_when_the_browser_has_a_window
    with_processes([BROWSER_HEADED, HELPER]) do
      refute Lowes::Chrome.running_headless?(profile: PROFILE)
    end
  end

  def test_a_headless_helper_alone_is_not_a_headless_browser
    with_processes([HELPER]) do
      assert_nil Lowes::Chrome.running_headless?(profile: PROFILE)
    end
  end

  def test_ignores_a_chrome_on_another_profile
    other = BROWSER_HEADLESS.sub(PROFILE, "/Users/x/other-profile")
    with_processes([other]) do
      assert_nil Lowes::Chrome.running_argv(profile: PROFILE)
    end
  end
end
