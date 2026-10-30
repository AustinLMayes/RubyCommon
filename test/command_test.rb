# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/common/command'

class CommandTest < Minitest::Test
  def teardown
    Command.runner = nil
  end

  def test_captures_stdout_stderr_and_status_apart
    result = Command.run('sh', '-c', 'echo out; echo err >&2; exit 3')

    assert_equal "out\n", result.out
    assert_equal "err\n", result.err
    assert_equal 3, result.status.exitstatus
    refute result.ok?
    refute result.timed_out?
  end

  def test_ok_on_a_zero_exit
    assert Command.run('true').ok?
  end

  def test_argv_never_reaches_a_shell
    assert_equal "$HOME `id` ;\n", Command.run('echo', '$HOME `id` ;').out
  end

  def test_a_single_string_with_spaces_is_one_executable_name
    assert_raises(Command::Unavailable) { Command.run('echo hi') }
  end

  def test_a_missing_executable_is_unavailable
    error = assert_raises(Command::Unavailable) { Command.run('no-such-binary-anywhere') }
    assert_includes error.message, 'no-such-binary-anywhere'
  end

  def test_stderr_merge_interleaves_into_out
    result = Command.run('sh', '-c', 'echo a; echo b >&2', stderr: :merge)

    assert_equal "a\nb\n", result.out
    assert_equal '', result.err
  end

  def test_stderr_discard_drops_it
    result = Command.run('sh', '-c', 'echo a; echo b >&2', stderr: :discard)

    assert_equal "a\n", result.out
    assert_equal '', result.err
  end

  def test_stderr_inherit_leaves_it_on_the_parents_stream
    _, err = capture_subprocess_io { Command.run('sh', '-c', 'echo leaked >&2', stderr: :inherit) }

    assert_equal "leaked\n", err
  end

  def test_stdin_is_fed_and_closed
    assert_equal 'piped', Command.run('cat', stdin: 'piped').out
  end

  def test_stdin_defaults_to_empty_rather_than_the_parents
    assert_equal '', Command.run('cat').out
  end

  def test_chdir_and_env
    Dir.mktmpdir do |dir|
      result = Command.run('sh', '-c', 'pwd; echo $PROBE', chdir: dir, env: { 'PROBE' => 'set' })

      assert_equal [File.realpath(dir), 'set'], result.out.split("\n")
    end
  end

  def test_output_is_binary_safe
    bytes = Command.run('printf', '\377\000\303').out.bytes

    assert_equal [255, 0, 195], bytes
  end

  def test_timeout_terminates_and_reports_it
    started = Time.now
    result = Command.run('sleep', '10', timeout: 0.2)

    assert result.timed_out?
    refute result.ok?
    assert_operator Time.now - started, :<, 3
  end

  def test_timeout_kills_a_child_that_ignores_term
    started = Time.now
    result = Command.run('ruby', '-e', 'trap("TERM") {}; puts "up"; $stdout.flush; sleep 10', timeout: 0.5)

    assert result.timed_out?
    assert_equal 'KILL', Signal.signame(result.status.termsig)
    assert_operator Time.now - started, :<, 4
  end

  def test_timeout_reaches_grandchildren_holding_the_pipe
    started = Time.now
    result = Command.run('sh', '-c', 'sleep 10; echo never', timeout: 0.2)

    assert result.timed_out?
    assert_equal '', result.out
    assert_operator Time.now - started, :<, 3
  end

  def test_runner_seam_replaces_the_spawn
    seen = nil
    Command.runner = lambda do |argv, **opts|
      seen = [argv, opts[:chdir]]
      Command::Result.new('stubbed', '', nil, false)
    end

    assert_equal 'stubbed', Command.run('git', 'status', chdir: '/x').out
    assert_equal [%w[git status], '/x'], seen
  end
end
