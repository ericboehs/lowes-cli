require_relative "../test_helper"
require "json"
require "socket"
require "lowes/chrome"
require "lowes/commands/chrome_start"

# The headless launch is the whole point of these two classes, and it is one
# flag away from being silently refused by Akamai — `--headless` without a
# matching `--user-agent` gets 403 Access Denied. So the argv is asserted on
# directly rather than through anything that would have to start a browser.
class ChromeStartArgvTest < Minitest::Test
  include XDGSandbox

  PROFILE = "/tmp/lowes-test-profile".freeze

  def command(headless, binary = chrome_binary)
    cmd = Lowes::Commands::ChromeStart.new(quiet: true)
    cmd.send(:command, binary, 9222, PROFILE, "https://www.lowes.com/", headless)
  end

  # Real if it is there, a stub that answers `--version` if it isn't, so this
  # asserts on the same code path on a laptop and in CI.
  def chrome_binary
    real = Lowes::Commands::ChromeStart::CHROME_APP
    File.exist?(real) ? real : stub_binary
  end

  # A binary whose version is known here, so the version assertion can name a
  # literal instead of re-deriving it with the same `--version` call the
  # implementation makes — which would pass no matter what that call returned.
  def stub_binary
    @stub_binary ||= begin
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
    ua = command(true, stub_binary).find { |a| a.start_with?("--user-agent=") }
    assert_includes ua, "Chrome/151.0.0.0"
  end

  # Everything above reaches past `run` into the private builder, which would
  # keep passing if `run` stopped calling it or dropped the flag it parsed.
  # This one goes through the front door and watches what gets spawned.
  def test_run_spawns_the_argv_it_built
    spawned = nil
    with_spawn_stub(->(*argv, **_opts) { spawned = argv; 4242 }) do
      status = Lowes::Commands::ChromeStart.new(quiet: true)
                                           .run(["--headed", "--binary", stub_binary, "--profile", PROFILE])
      assert_equal 0, status
    end
    assert_equal stub_binary, spawned.first
    assert_includes spawned, "--user-data-dir=#{PROFILE}"
    refute_includes spawned, "--headless"
  end

  def with_spawn_stub(stub)
    original_spawn = Process.method(:spawn)
    original_detach = Process.method(:detach)
    Process.define_singleton_method(:spawn) { |*a, **k| stub.call(*a, **k) }
    Process.define_singleton_method(:detach) { |_pid| nil }
    yield
  ensure
    Process.define_singleton_method(:spawn, original_spawn)
    Process.define_singleton_method(:detach, original_detach)
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

  # `write_default!` seeds `"headless": true`, so the shipped config is not the
  # unconfigured case — remove the key to actually reach the nil branch.
  def test_defaults_to_headless_with_no_config_and_no_env
    write_browser({})
    assert Lowes::Chrome.headless_default?
  end

  def test_defaults_to_headless_when_the_config_file_is_missing
    File.delete(Lowes::Config.config_path)
    assert Lowes::Chrome.headless_default?
  end

  # `!!"false"` is true, and `"headless": "false"` is an easy thing to write.
  # Honouring it as headless would hand back a window to nobody.
  def test_a_quoted_false_still_means_headed
    %w[false 0 no off].each do |value|
      write_browser("headless" => value)
      refute Lowes::Chrome.headless_default?, %(headless: "#{value}" should mean headed)
    end
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

  # `module_function` puts `processes` on the singleton class, which is the same
  # place `define_singleton_method` writes to — so this overwrites rather than
  # shadows, and `remove_method` would delete the real one for the rest of the
  # suite. Hold the original and put it back.
  def with_processes(lines)
    original = Lowes::Chrome.method(:processes)
    Lowes::Chrome.define_singleton_method(:processes) { lines.map { |l| l + "\n" } }
    yield
  ensure
    Lowes::Chrome.define_singleton_method(:processes, original)
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

  # A `ps` that fails has to read as "we don't know", not "nothing is running":
  # the latter sends `ensure_headed` off to kill a browser it never found.
  def test_a_failed_ps_is_not_an_empty_process_list
    original = Lowes::Chrome.method(:processes)
    Lowes::Chrome.define_singleton_method(:processes) { nil }
    assert_nil Lowes::Chrome.running_argv(profile: PROFILE)
    assert_nil Lowes::Chrome.running_headless?(profile: PROFILE)
  ensure
    Lowes::Chrome.define_singleton_method(:processes, original)
  end

  def test_quit_ours_does_nothing_when_no_chrome_of_ours_is_running
    with_processes([HELPER]) do
      refute Lowes::Chrome.quit_ours(profile: PROFILE)
    end
  end

  # Against the real `ps`, because the pid/command split is the only thing this
  # method does and a stubbed `ps` would be asserting on my own formatting.
  def test_pid_for_matches_a_command_line_to_its_pid
    mine = IO.popen(["ps", "-axww", "-o", "pid=,command="], &:read)
             .lines.find { |l| l.strip.split(" ", 2).first.to_i == Process.pid }
    skip "no ps line for this process" unless mine
    assert_equal Process.pid, Lowes::Chrome.pid_for(mine.strip.split(" ", 2).last)
  end
end

# The three ways `lowes login` can find the port occupied. Getting this wrong
# means asking someone to sign in to a window that isn't there — a ten-minute
# silence ending in a timeout — or TERMing a browser that isn't ours.
class ChromeEnsureHeadedTest < Minitest::Test
  def with_chrome(stubs)
    originals = stubs.keys.to_h { |name| [name, Lowes::Chrome.method(name)] }
    stubs.each { |name, value| Lowes::Chrome.define_singleton_method(name) { |*, **| value } }
    yield
  ensure
    originals.each { |name, method| Lowes::Chrome.define_singleton_method(name, method) }
  end

  def test_nothing_on_the_port_starts_a_headed_chrome
    started = nil
    with_chrome(cdp_reachable?: false) do
      original = Lowes::Chrome.method(:ensure_started)
      Lowes::Chrome.define_singleton_method(:ensure_started) { |quiet: false, headless: nil| started = headless; true }
      assert Lowes::Chrome.ensure_headed(quiet: true)
    ensure
      Lowes::Chrome.define_singleton_method(:ensure_started, original)
    end
    assert_equal false, started, "login must ask for a window explicitly"
  end

  def test_a_headed_chrome_of_ours_is_left_alone
    with_chrome(cdp_reachable?: true, running_headless?: false) do
      assert Lowes::Chrome.ensure_headed(quiet: true)
    end
  end

  # Somebody else's Chrome. Restarting it would take down whatever they were
  # doing, so this reports success and lets the caller try the sign-in.
  def test_a_chrome_that_is_not_ours_is_not_restarted
    quit = false
    with_chrome(cdp_reachable?: true, running_headless?: nil) do
      original = Lowes::Chrome.method(:quit_ours)
      Lowes::Chrome.define_singleton_method(:quit_ours) { |*, **| quit = true }
      assert Lowes::Chrome.ensure_headed(quiet: true)
    ensure
      Lowes::Chrome.define_singleton_method(:quit_ours, original)
    end
    refute quit
  end

  def test_a_headless_chrome_of_ours_is_restarted_with_a_window
    quit = false
    started = nil
    with_chrome(cdp_reachable?: true, running_headless?: true) do
      originals = %i[quit_ours ensure_started].to_h { |n| [n, Lowes::Chrome.method(n)] }
      Lowes::Chrome.define_singleton_method(:quit_ours) { |*, **| quit = true }
      Lowes::Chrome.define_singleton_method(:ensure_started) { |quiet: false, headless: nil| started = headless; true }
      assert Lowes::Chrome.ensure_headed(quiet: true)
      originals.each { |n, m| Lowes::Chrome.define_singleton_method(n, m) }
    end
    assert quit, "the headless Chrome should have been asked to quit"
    assert_equal false, started
  end
end

# `/json/version` is the browser describing itself, and the one field worth the
# read is the User-Agent: `HeadlessChrome` there is a 403 from Akamai a few
# seconds later, blamed on the session. Served over a real socket rather than a
# stubbed `Net::HTTP`, because the two ways this comes back wrong — a body that
# isn't JSON, a port that isn't answering — both live below that seam.
class ChromeCdpVersionTest < Minitest::Test
  HEADLESS = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
             "(KHTML, like Gecko) HeadlessChrome/151.0.0.0 Safari/537.36".freeze
  REAL = HEADLESS.sub("HeadlessChrome", "Chrome").freeze

  def body(user_agent) = JSON.generate("Browser" => "Chrome/151.0.7922.109", "User-Agent" => user_agent)

  # One request, one response, then gone — which is all `cdp_version` makes.
  def with_cdp(body, status: "200 OK")
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      socket = server.accept
      while (line = socket.gets) && line.strip != ""; end
      socket.write("HTTP/1.1 #{status}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      socket.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    thread&.kill
    server&.close
  end

  def test_reads_the_user_agent_out_of_the_body
    with_cdp(body(HEADLESS)) do |url|
      assert_equal HEADLESS, Lowes::Chrome.cdp_version(url: url)["User-Agent"]
    end
  end

  # `webSocketDebuggerUrl` is read out of this same body before anything can
  # attach, so a body we can't parse is a port we can't use. Calling it
  # reachable only moves the failure somewhere it explains itself worse.
  def test_a_body_that_is_not_json_is_not_a_usable_port
    with_cdp("<html>not chrome</html>") do |url|
      assert_nil Lowes::Chrome.cdp_version(url: url)
    end
  end

  def test_a_non_success_status_is_not_a_usable_port
    with_cdp(body(REAL), status: "404 Not Found") do |url|
      assert_nil Lowes::Chrome.cdp_version(url: url)
    end
  end

  def test_nothing_listening_is_nil_rather_than_an_exception
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    assert_nil Lowes::Chrome.cdp_version(timeout: 0.5, url: "http://127.0.0.1:#{port}")
  end
end

# The token, and what gets said about it. Only the positive direction is an
# answer: a headless Chrome started the way this tool starts one is overriding
# that string on purpose, so its absence means "no idea", not "has a window".
class ChromeHeadlessUaTest < Minitest::Test
  def with_ua(user_agent)
    original = Lowes::Chrome.method(:cdp_user_agent)
    Lowes::Chrome.define_singleton_method(:cdp_user_agent) { |*, **| user_agent }
    yield
  ensure
    Lowes::Chrome.define_singleton_method(:cdp_user_agent, original)
  end

  def test_detects_a_chrome_that_names_itself_headless
    with_ua(ChromeCdpVersionTest::HEADLESS) { assert Lowes::Chrome.headless_ua? }
  end

  # The state every command is meant to be in. Flagging this would fire the
  # warning on every successful run, which is how a real warning stops being read.
  def test_a_headless_chrome_with_the_override_is_not_flagged
    with_ua(ChromeCdpVersionTest::REAL) { refute Lowes::Chrome.headless_ua? }
  end

  def test_no_browser_at_all_is_not_flagged
    with_ua(nil) { refute Lowes::Chrome.headless_ua? }
  end

  def test_the_warning_names_the_token_it_found
    out, err = with_ua(ChromeCdpVersionTest::HEADLESS) { capture_io { Lowes::Chrome.warn_headless_ua } }
    assert_empty out
    assert_includes err, "HeadlessChrome/151.0.0.0"
    assert_includes err, "403"
  end

  def test_nothing_is_said_about_a_browser_that_will_be_accepted
    _, err = with_ua(ChromeCdpVersionTest::REAL) { capture_io { Lowes::Chrome.warn_headless_ua } }
    assert_empty err
  end

  # Someone else's Chrome, which we won't restart either way — but "sign in
  # there" is advice you cannot take when there is no window, and following it
  # is the ten-minute timeout `ensure_headed` exists to prevent.
  def test_a_foreign_headless_chrome_is_not_offered_as_somewhere_to_sign_in
    with_ua(ChromeCdpVersionTest::HEADLESS) do
      assert_includes Lowes::Chrome.foreign_chrome_warning, "no window to sign in to"
    end
  end

  def test_a_foreign_chrome_that_may_have_a_window_is_offered_as_one
    with_ua(ChromeCdpVersionTest::REAL) do
      assert_includes Lowes::Chrome.foreign_chrome_warning, "sign in there if it has a window"
    end
  end
end

# The wiring. Both paths through `ensure_started` end with a browser on the
# port, and either one can end with the wrong browser on the port.
class ChromeEnsureStartedWarnsTest < Minitest::Test
  def with_chrome(stubs)
    originals = stubs.keys.to_h { |name| [name, Lowes::Chrome.method(name)] }
    stubs.each { |name, value| Lowes::Chrome.define_singleton_method(name) { |*, **| value } }
    yield
  ensure
    originals.each { |name, method| Lowes::Chrome.define_singleton_method(name, method) }
  end

  def test_warns_about_a_headless_chrome_that_was_already_running
    _, err = with_chrome(cdp_reachable?: true, cdp_user_agent: ChromeCdpVersionTest::HEADLESS) do
      capture_io { assert Lowes::Chrome.ensure_started }
    end
    assert_includes err, "HeadlessChrome"
  end

  # Passing `--user-agent` and the browser having taken it are separate claims.
  # This asserts the second one gets checked, on the browser we just launched.
  def test_warns_about_a_headless_chrome_it_launched_itself
    _, err = with_chrome(cdp_reachable?: false, wait_for_cdp: true,
                         cdp_user_agent: ChromeCdpVersionTest::HEADLESS) do
      original = Lowes::Commands::ChromeStart.instance_method(:run)
      Lowes::Commands::ChromeStart.define_method(:run) { |*| 0 }
      capture_io { assert Lowes::Chrome.ensure_started }
    ensure
      Lowes::Commands::ChromeStart.define_method(:run, original)
    end
    assert_includes err, "HeadlessChrome"
  end

  def test_quiet_stays_quiet
    _, err = with_chrome(cdp_reachable?: true, cdp_user_agent: ChromeCdpVersionTest::HEADLESS) do
      capture_io { Lowes::Chrome.ensure_started(quiet: true) }
    end
    assert_empty err
  end
end
