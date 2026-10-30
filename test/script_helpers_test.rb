# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/common/secrets"
require_relative "../lib/common/bugsnag"
require_relative "../lib/common/ziax_utils"

class ScriptHelpersTest < Minitest::Test
  OK = Struct.new(:ok) { def success? = ok }

  def setup
    @home = Dir.mktmpdir
    @env = ENV.to_h.slice("HOME", "ZIAX_UTILS", "BUGSNAG_API_KEY", "PROBE_KEY")
    ENV["HOME"] = @home
    ENV.delete("BUGSNAG_API_KEY")
    ENV.delete("PROBE_KEY")
  end

  def teardown
    Command.runner = nil
    %w[HOME ZIAX_UTILS BUGSNAG_API_KEY PROBE_KEY].each { |k| ENV[k] = @env[k] }
    FileUtils.rm_rf(@home)
  end

  def extra(text) = File.write(File.join(@home, ".extra"), text)

  def curl(*responses)
    calls = []
    Command.runner = lambda do |argv, **_|
      calls << argv
      out, ok = responses.shift
      Command::Result.new(out, "", OK.new(ok != false), false)
    end
    calls
  end

  def test_extra_prefers_the_environment
    extra("export PROBE_KEY=from-file\n")
    ENV["PROBE_KEY"] = "from-env"
    assert_equal "from-env", Secrets.extra("PROBE_KEY")
  end

  def test_extra_sources_the_file_so_quoted_and_computed_exports_resolve
    extra(%(export PROBE_KEY="a b=c$(printf %s -d)"\necho noise\n))
    assert_equal "a b=c-d", Secrets.extra("PROBE_KEY")
  end

  def test_extra_is_nil_when_unset_empty_or_missing
    assert_nil Secrets.extra("PROBE_KEY")
    extra("export PROBE_KEY=\n")
    assert_nil Secrets.extra("PROBE_KEY")
  end

  def test_extra_env_has_every_export
    extra("export OVH_A=1\nexport OVH_B=2\n")
    assert_equal %w[1 2], Secrets.extra_env.values_at("OVH_A", "OVH_B")
  end

  def test_bugsnag_url_encodes_bracketed_filter_keys
    assert_equal "#{Bugsnag::API}/projects/p/errors", Bugsnag.url("/projects/p/errors")
    assert_equal "#{Bugsnag::API}/x?filters%5Bevent.since%5D%5B%5D%5Btype%5D=eq&q=a+b",
                 Bugsnag.url("/x", [["filters[event.since][][type]", "eq"], ["q", "a b"]])
  end

  def test_bugsnag_get_sends_the_token_and_splits_the_status
    ENV["BUGSNAG_API_KEY"] = "tok"
    calls = curl(["[{\"id\":1}]\n200"])
    response = Bugsnag.get("/projects/#{Bugsnag::PROJECT}/errors", [%w[per_page 1]])
    assert response.ok?
    assert_equal [{ "id" => 1 }], response.json
    assert_includes calls[0], "Authorization: token tok"
    assert_equal %w[--max-time 30], calls[0][2, 2]
    assert_equal "#{Bugsnag::API}/projects/#{Bugsnag::PROJECT}/errors?per_page=1", calls[0].last
  end

  def test_bugsnag_get_retries_a_rate_limit_then_returns
    ENV["BUGSNAG_API_KEY"] = "tok"
    calls = curl(["{}\n429"], ["rate limit exceeded\n200"], ["{\"errors\":[\"no\"]}\n404"])
    response = Bugsnag.get("/x", pause: false)
    assert_equal 3, calls.size
    refute response.ok?
    assert_equal "404", response.code
  end

  def test_bugsnag_get_gives_up_after_the_tries
    ENV["BUGSNAG_API_KEY"] = "tok"
    calls = curl(*Array.new(6) { ["{}\n429"] })
    error = assert_raises(Bugsnag::Error) { Bugsnag.get("/x", pause: false) }
    assert_equal "bugsnag /x: still rate limited after 6 tries", error.message
    assert_equal 6, calls.size
  end

  def test_bugsnag_get_is_not_ok_when_curl_fails
    ENV["BUGSNAG_API_KEY"] = "tok"
    curl(["\n000", false])
    refute Bugsnag.get("/x").ok?
  end

  def test_bugsnag_get_takes_a_max_time
    ENV["BUGSNAG_API_KEY"] = "tok"
    calls = curl(["{}\n200"])
    Bugsnag.get("/x", max_time: 5)
    assert_equal %w[--max-time 5], calls[0][2, 2]
  end

  def test_bugsnag_get_without_a_token_raises
    assert_raises(Bugsnag::Error) { Bugsnag.get("/x") }
  end

  def test_rocket_client_evaluates_the_env_line_from_zutils
    root = File.join(@home, "zu")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "rocket_client.rb"), <<~RUBY)
      warn "loading noise"
      class RocketClient
        attr_reader :args, :cwd
        def initialize(*args) = (@args = args)
      end
      RC_CWD = Dir.pwd
    RUBY
    File.write(File.join(root, "zutils.rb"), <<~RUBY)
      {
        dev: RocketClient.new("https://d", "https://k", "games", "s", "rocket", "cubecraft"),
      }
    RUBY
    ENV["ZIAX_UTILS"] = root
    _, err = capture_subprocess_io { assert_equal %w[https://d https://k games s rocket cubecraft], ZiaxUtils.rocket_client("dev").args }
    assert_empty err
    assert_equal File.realpath(root), File.realpath(RC_CWD)
    assert_includes $LOAD_PATH, root
    error = assert_raises(ZiaxUtils::Error) { ZiaxUtils.rocket_client("prod") }
    assert_equal "no prod: RocketClient line in #{root}/zutils.rb", error.message
  end
end
