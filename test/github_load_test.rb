# frozen_string_literal: true

require "rbconfig"
require "tmpdir"
require "minitest/autorun"

# 🔴 `GITHUB_USERNAME` was a constant assigned from a backtick, so merely LOADING this library made
# an authenticated GitHub call — ten per PRTrain suite run, before a single test ran. PRTrain's test
# sandbox could not see it: the tripwire is not armed at require time, and the static scanner only
# globs PRTrain's own lib/. It also meant `require "common"` failed on a machine without an
# authenticated `gh`.
class GitHubLoadTest < Minitest::Test
  def with_recording_path
    Dir.mktmpdir("gh-shim-") do |dir|
      log = File.join(dir, "gh.log")
      File.write(File.join(dir, "gh"), "#!/bin/sh\necho \"$*\" >> #{log}\nexit 1\n")
      File.chmod(0o755, File.join(dir, "gh"))
      yield dir, log
    end
  end

  def run_with_shim(dir, body)
    lib = File.expand_path("../lib", __dir__)
    system({ "PATH" => "#{dir}:#{ENV['PATH']}" },
           RbConfig.ruby, "-I#{lib}", "-e", body, out: File::NULL, err: File::NULL)
  end

  def test_loading_the_library_makes_no_network_call
    with_recording_path do |dir, log|
      run_with_shim(dir, 'require "common"')

      invocations = File.exist?(log) ? File.read(log) : ""
      assert_empty invocations.strip,
                   "requiring common shelled out to gh: #{invocations.inspect}"
    end
  end

  # The complement — without it, deleting the call entirely would pass the check above.
  def test_the_username_is_still_available_when_something_asks_for_it
    with_recording_path do |dir, log|
      run_with_shim(dir, 'require "common"; GitHub.github_username')

      assert_includes File.read(log), "api user", "nothing asked gh for the username"
    end
  end

  def test_the_username_is_fetched_once_and_memoised
    with_recording_path do |dir, log|
      run_with_shim(dir, 'require "common"; 3.times { GitHub.github_username }')

      assert_equal 1, File.read(log).lines.length, "the username was fetched more than once"
    end
  end
end
