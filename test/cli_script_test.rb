# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require_relative '../lib/common/cli'

class CliScriptTest < Minitest::Test
  LIB = File.expand_path('../lib', __dir__)

  def script(code, *argv)
    Open3.capture3(RbConfig.ruby, '-I', LIB, '-rcommon/cli', '-e', code, '--', *argv)
  end

  def test_help_is_either_flag_anywhere
    assert Cli.help?(%w[a --help])
    assert Cli.help?(%w[-h])
    refute Cli.help?(%w[--helpful -H])
    refute Cli.help?([])
  end

  def test_usage_prints_help_on_stdout_and_exits_zero
    out, err, status = script('Cli.usage!("Usage: x\n")')
    assert_equal ["Usage: x\n", '', 0], [out, err, status.exitstatus]
  end

  def test_usage_error_goes_to_stderr_unless_told_otherwise
    out, err, status = script('Cli.usage!("Usage: x\n", Cli::USAGE)')
    assert_equal ['', "Usage: x\n", 2], [out, err, status.exitstatus]

    out, err, status = script('Cli.usage!("Usage: x\n", 1, out: $stdout)')
    assert_equal ["Usage: x\n", '', 1], [out, err, status.exitstatus]
  end

  def test_abort_warns_and_exits_with_the_code
    out, err, status = script('Cli.abort!("no repo")')
    assert_equal ['', "no repo\n", Cli::FAILED], [out, err, status.exitstatus]

    _, _, status = script('Cli.abort!("x", 7)')
    assert_equal 7, status.exitstatus
  end

  def test_option_takes_the_first_occurrence_and_its_value
    argv = %w[a --repo /r b --repo /s]
    assert_equal '/r', Cli.option!(argv, '--repo')
    assert_equal %w[a b --repo /s], argv
  end

  def test_option_without_a_value_is_empty_and_absent_is_nil
    argv = %w[a --repo]
    assert_equal '', Cli.option!(argv, '--repo')
    assert_equal %w[a], argv
    assert_nil Cli.option!(argv, '--repo')
    assert_equal %w[a], argv
  end

  def test_run_returns_stdout_on_an_allowed_status
    assert_equal "hi\n", Cli.run!('echo', 'hi')
    assert_equal '', Cli.run!('sh', '-c', 'exit 1', ok: [0, 1])
  end

  def test_run_names_the_command_and_its_stderr_then_exits_two
    out, err, status = script('Cli.run!("sh", "-c", "echo bad >&2; exit 3")')
    assert_equal ['', "sh -c echo bad >&2; exit 3: bad\n", 2], [out, err, status.exitstatus]
  end

  def test_out_checks_a_result_already_run
    result = Command.run('sh', '-c', 'echo bad >&2; exit 1')
    _, err, status = script(<<~RUBY)
      Cli.out!(Command.run('sh', '-c', 'echo bad >&2; exit 1'), 'git -C /r grep x')
    RUBY
    assert_equal ["git -C /r grep x: bad\n", 2], [err, status.exitstatus]
    assert_equal '', Cli.out!(result, 'unused', ok: [1])
  end
end
