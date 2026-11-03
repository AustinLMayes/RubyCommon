# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/common/kube_mysql_session'

class KubeMysqlSessionTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = ENV['PATH']
    ENV['PATH'] = "#{@dir}:#{@path}"
  end

  def teardown
    ENV['PATH'] = @path
    FileUtils.remove_entry(@dir)
  end

  def fake_kubectl(forward)
    File.write(File.join(@dir, 'kubectl'), <<~SH)
      #!/bin/sh
      echo "$@" >> #{@dir}/calls
      case "$*" in
        *port-forward*) #{forward} ;;
        *) echo '{"data":{"user":"cm9vdA==","password":"aHVudGVyMg=="}}' ;;
      esac
    SH
    File.chmod(0o755, File.join(@dir, 'kubectl'))
  end

  def test_tunnel_yields_the_forwarded_port_and_decoded_credentials_then_stops_the_forward
    fake_kubectl("echo $$ > #{@dir}/pid; echo 'Forwarding from 127.0.0.1:43210 -> 3306'; exec sleep 30")

    yielded = nil
    KubeMysqlSession.new('man1', 'cubecraft-legacy', 'main-mysql').tunnel { |*args| yielded = args }

    assert_equal [43_210, 'root', 'hunter2'], yielded
    calls = File.read(File.join(@dir, 'calls'))
    assert_includes calls, '--context man1 -n cubecraft-legacy get secret main-mysql-psuser-root'
    assert_includes calls, '--context man1 -n cubecraft-legacy port-forward svc/main-mysql-haproxy :3306'
    assert_raises(Errno::ESRCH) { Process.kill(0, File.read(File.join(@dir, 'pid')).to_i) }
  end

  def test_a_failed_forward_exits_without_yielding
    fake_kubectl("echo 'error: services not found'; exit 1")

    out, = capture_io do
      assert_raises(SystemExit) { KubeMysqlSession.new('man1', 'cubecraft-legacy', 'main-mysql').tunnel { flunk 'yielded' } }
    end
    assert_includes out, 'services not found'
  end
end
