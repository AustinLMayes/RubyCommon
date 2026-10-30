# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/common/ax'

class AxTest < Minitest::Test
  def setup
    @ax_bin = ENV.delete('AX_BIN')
  end

  def teardown
    Command.runner = nil
    ENV['AX_BIN'] = @ax_bin
  end

  def test_bin_is_ax_on_the_path_unless_ax_bin_names_one
    assert_equal 'ax', Ax.bin
    ENV['AX_BIN'] = ''
    assert_equal 'ax', Ax.bin
    ENV['AX_BIN'] = '/opt/ax'
    assert_equal '/opt/ax', Ax.bin
  end

  def test_call_runs_the_bin_with_the_args_and_options
    seen = nil
    Command.runner = lambda do |argv, **opts|
      seen = [argv, opts[:timeout], opts[:stderr]]
      Command::Result.new('ok', '', nil, false)
    end
    ENV['AX_BIN'] = '/opt/ax'
    Ax.call('queue', 'has', '--branch', 'b', timeout: 15, stderr: :merge)
    assert_equal [%w[/opt/ax queue has --branch b], 15, :merge], seen
    Ax.call('job', 'pause', 'x', bin: '/elsewhere/ax')
    assert_equal %w[/elsewhere/ax job pause x], seen[0]
  end

  def test_a_missing_ax_is_nil_when_failing_open
    Command.runner = ->(*, **) { raise Command::Unavailable, 'No such file or directory - ax' }
    assert_nil Ax.call('queue', 'has')
  end

  def test_a_missing_ax_raises_when_not_failing_open
    Command.runner = ->(*, **) { raise Command::Unavailable, 'No such file or directory - ax' }
    error = assert_raises(Command::Unavailable) { Ax.call('queue', 'has', fail_open: false) }
    assert_equal 'No such file or directory - ax', error.message
  end

  def test_a_real_call_returns_the_exit_status
    Dir.mktmpdir('ax-test') do |dir|
      bin = File.join(dir, 'ax')
      File.write(bin, "#!/bin/sh\necho \"$*\"\nexit #{Ax::TRAIN_NO_CHANGE}\n")
      File.chmod(0o755, bin)
      result = Ax.call('train', 'add', bin: bin)
      assert_equal "train add\n", result.out
      assert_equal Ax::TRAIN_NO_CHANGE, result.status.exitstatus
    end
  end

  def test_a_hung_ax_is_killed_at_the_timeout
    Dir.mktmpdir('ax-test') do |dir|
      bin = File.join(dir, 'ax')
      File.write(bin, "#!/bin/sh\nsleep 30\n")
      File.chmod(0o755, bin)
      started = Time.now
      result = Ax.call('x', bin: bin, timeout: 0.3)
      assert result.timed_out?
      assert_operator Time.now - started, :<, 5
    end
  end

  def test_exit_codes_match_ax
    assert_equal [3, 3, 4], [Ax::NOT_CLEAN, Ax::TRAIN_UNREACHABLE, Ax::TRAIN_NO_CHANGE]
  end
end
