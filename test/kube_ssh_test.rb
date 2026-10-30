# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/common/kube'
require_relative '../lib/common/ssh'

class KubeSshTest < Minitest::Test
  OK = Struct.new(:ok) { def success? = ok }

  def teardown
    Command.runner = nil
  end

  def record(out: '', err: '', ok: true)
    calls = []
    Command.runner = lambda do |argv, **opts|
      calls << [argv, opts]
      Command::Result.new(out, err, OK.new(ok), false)
    end
    calls
  end

  def test_kube_argv_puts_context_namespace_and_timeout_before_the_args
    assert_equal %w[oc get pods], Kube.argv('get', 'pods')
    assert_equal %w[kubectl --context dev -n ns --request-timeout=15s get secret x],
                 Kube.argv('get', 'secret', 'x', tool: :kubectl, context: 'dev', namespace: 'ns', request_timeout: '15s')
  end

  def test_kube_run_passes_command_options_through
    calls = record(out: 'x')
    assert_equal 'x', Kube.run('get', 'pods', context: 'man1', timeout: 5).out
    assert_equal [%w[oc --context man1 get pods], 5], [calls[0][0], calls[0][1][:timeout]]
  end

  def test_kube_json_parses_and_asks_for_json
    calls = record(out: '{"items": []}')
    assert_equal({ 'items' => [] }, Kube.json('get', 'pods', context: 'man1', namespace: 'ns'))
    assert_equal %w[oc --context man1 -n ns get pods -o json], calls[0][0]
  end

  def test_kube_json_raises_with_the_command_and_stderr
    record(err: "error: forbidden\n", ok: false)
    error = assert_raises(Kube::Error) { Kube.json('get', 'secrets', context: 'man1') }
    assert_equal 'oc --context man1 get secrets: error: forbidden', error.message
    refute error.result.ok?
  end

  def test_ssh_run_is_batch_with_a_connect_timeout_by_default
    calls = record(out: 'up')
    assert_equal 'up', Ssh.run('g00', 'uptime').out
    assert_equal ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', 'root@g00', 'uptime'], calls[0][0]
  end

  def test_ssh_run_keeps_a_given_user_and_hops_via_a_jump_host
    calls = record
    Ssh.run('vyos@10.0.0.1', 'show', batch: false, connect_timeout: nil, via: 'bastion', stdin: 'x')
    assert_equal ['ssh', '-J', 'root@bastion', 'vyos@10.0.0.1', 'show'], calls[0][0]
    assert_equal 'x', calls[0][1][:stdin]
  end

  def test_ssh_quotes_an_array_command_and_passes_a_string_as_a_script
    calls = record
    Ssh.run('h', ['docker', 'stop', 'a; rm -rf /'])
    Ssh.run('h', 'docker ps | grep x')
    assert_equal "docker stop a\\;\\ rm\\ -rf\\ /", calls[0][0].last
    assert_equal 'docker ps | grep x', calls[1][0].last
  end

  def test_ssh_spots_an_unknown_host_and_says_how_to_bless_it
    result = Command::Result.new('', "Host key verification failed.\r\n", OK.new(false), false)
    assert Ssh.unknown_host?(result)
    refute Ssh.unknown_host?(Command::Result.new('', 'Connection refused', OK.new(false), false))
    assert_equal "g00 isn't in known_hosts. Ask for `! ssh root@g00 exit` once to bless it (ziax-ssh)",
                 Ssh.unknown_host_message('g00')
  end

  def test_ssh_drops_the_login_banner_from_stderr
    assert_equal "Permission denied\nagain", Ssh.without_banner("** WARNING **\nPermission denied\n** x\nagain\n")
  end
end
