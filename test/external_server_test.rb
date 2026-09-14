# frozen_string_literal: true

require 'minitest/autorun'
require 'socket'
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

  private

  def quietly
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end
end
