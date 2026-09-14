# frozen_string_literal: true

require 'minitest/autorun'
require 'socket'
require 'net/http'
require 'uri'
require 'stringio'
require_relative '../lib/common/logging'
require_relative '../lib/common/external_server'

# 🔴 `if_connectable` is documented everywhere as "no-ops gracefully when the server is down", and
# every gutils task that talks to PR Train relies on that. It did the opposite: `is_connectable?`
# rescued ECONNREFUSED and called `error`, which is `puts` + `exit false`, so the whole rake task
# died at that point and its remaining work never ran. The `else` branch below was dead code.
class ExternalServerTest < Minitest::Test
  DEAD_PORT = 45_999

  def setup
    @server = ExternalServer.new('127.0.0.1', DEAD_PORT)
  end

  def test_a_refused_connection_reports_false_rather_than_exiting
    result = nil
    quietly { result = @server.is_connectable? }
    assert_equal false, result
  rescue SystemExit
    flunk 'is_connectable? exited the process instead of returning false'
  end

  def test_if_connectable_skips_the_block_when_nothing_is_listening
    yielded = false
    quietly { @server.if_connectable { yielded = true } }
    refute yielded, 'the block ran against a server that is not there'
  rescue SystemExit
    flunk 'if_connectable exited the process instead of skipping'
  end

  def test_the_caller_keeps_running_after_a_skipped_call
    reached = false
    quietly do
      @server.if_connectable { raise 'should not yield' }
      reached = true
    end
    assert reached, 'execution never resumed after if_connectable — the task would die here'
  end

  def test_it_still_yields_when_something_is_listening
    listener = TCPServer.new('127.0.0.1', 0)
    yielded = false
    quietly { ExternalServer.new('127.0.0.1', listener.addr[1]).if_connectable { yielded = true } }
    assert yielded, 'a live server was treated as unreachable'
  ensure
    listener&.close
  end

  # 🔴 Same `exit false` shape as is_connectable? had, one method over. A non-2xx from the server
  # killed the caller, so a rake task submitting ten PRs died at the first one the train refused
  # and the remaining nine never went. The daemon being ABSENT skipped cleanly while the daemon
  # ANSWERING BADLY was fatal, which is backwards.
  def test_a_rejected_request_warns_and_lets_the_caller_carry_on
    with_stub_server(400, "Error: no PR found") do |port|
      reached = false
      quietly do
        ExternalServer.new('127.0.0.1', port).send_request('command', 'input' => 'remove a/b 1')
        reached = true
      end
      assert reached, 'a 400 killed the caller — the rest of the batch would never run'
    end
  end

  def test_a_rejected_request_says_what_the_server_said
    with_stub_server(400, "Error: no PR found for a/b#1") do |port|
      said = output_of do
        ExternalServer.new('127.0.0.1', port).send_request('command', 'input' => 'remove a/b 1')
      end
      assert_includes said, '400'
      assert_includes said, 'no PR found', 'the reason the server gave was thrown away'
    end
  end

  def test_a_successful_request_is_not_reported_as_a_failure
    with_stub_server(200, 'OK') do |port|
      said = output_of do
        ExternalServer.new('127.0.0.1', port).send_request('command', 'input' => 'status prs')
      end
      refute_includes said, 'Failed'
    end
  end

  # 🔴 The guard is a TOCTOU and the window is wide open. GitUtils checks `if_connectable` ONCE and
  # then loops ten `send_request` calls inside it, so a daemon that stops — or was never up, which
  # is its current state — makes an unrescued Errno::ECONNREFUSED end the rake task exactly as
  # `exit false` did. Fixing is_connectable? alone left the batch just as fragile.
  def test_a_server_that_is_not_listening_warns_rather_than_raising
    reached = false
    said = output_of do
      @server.send_request('command', 'input' => 'status prs')
      reached = true
    end
    assert reached, 'ECONNREFUSED escaped and ended the caller'
    assert_includes said, '45999'
  end

  def test_a_batch_survives_the_server_going_away_midway
    with_stub_server(200, 'OK') do |port|
      client = ExternalServer.new('127.0.0.1', port)
      quietly { client.send_request('command', 'input' => 'first') }
    end

    dead = ExternalServer.new('127.0.0.1', DEAD_PORT)
    completed = 0
    quietly { 3.times { dead.send_request('command', 'input' => 'later'); completed += 1 } }
    assert_equal 3, completed, 'the batch stopped when the daemon went away mid-loop'
  end

  def test_a_dns_failure_is_also_survivable
    reached = false
    quietly do
      ExternalServer.new('no-such-host.invalid', 80).send_request('command', 'input' => 'x')
      reached = true
    end
    assert reached, 'a name that does not resolve ended the caller'
  end

  def test_an_unreachable_server_reports_false
    result = nil
    quietly { result = @server.send_request('command', 'input' => 'x') }
    assert_equal false, result
  end

  def test_a_successful_request_reports_true
    with_stub_server(200, 'OK') do |port|
      result = nil
      quietly { result = ExternalServer.new('127.0.0.1', port).send_request('command', 'input' => 'x') }
      assert_equal true, result
    end
  end

  def test_a_rejected_request_reports_false
    with_stub_server(400, 'nope') do |port|
      result = nil
      quietly { result = ExternalServer.new('127.0.0.1', port).send_request('command', 'input' => 'x') }
      assert_equal false, result
    end
  end

  private

  def with_stub_server(status, body)
    server = TCPServer.new('127.0.0.1', 0)
    thread = Thread.new do
      socket = server.accept
      length = 0
      while (line = socket.gets) && line.strip != ''
        length = line.split(':', 2).last.to_i if line =~ /\AContent-Length:/i
      end
      socket.read(length) if length.positive?
      socket.print("HTTP/1.1 #{status} X\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      socket.close
    rescue StandardError
      nil
    end
    yield server.addr[1]
  ensure
    thread&.kill
    server&.close
  end

  def quietly
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  def output_of
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    yield
    buffer.string
  ensure
    $stdout = original
  end
end
