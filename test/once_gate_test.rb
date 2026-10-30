# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../lib/common/once_gate'

class OnceGateTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('once-gate')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def gate(ttl: OnceGate::DEFAULT_TTL)
    OnceGate.new(dir: File.join(@dir, 'store'), ttl: ttl)
  end

  def test_first_claim_is_fresh_and_the_second_is_not
    assert_equal ['k1'], gate.claim(['k1'])
    assert_empty gate.claim(['k1'])
  end

  def test_only_the_unseen_keys_come_back
    gate.claim(['k1'])
    assert_equal ['k2'], gate.claim(%w[k1 k2])
  end

  def test_claiming_nothing_is_not_an_error
    assert_empty gate.claim([])
  end

  def test_a_separate_gate_over_the_same_dir_sees_the_record
    gate.claim(['k1'])
    assert_empty gate.claim(['k1'])
  end

  def test_an_expired_record_is_fresh_again
    gate(ttl: -1).claim(['k1'])
    assert_equal ['k1'], gate(ttl: -1).claim(['k1'])
  end

  # A store we cannot parse must behave like an empty one, never like a wall —
  # a corrupt file would otherwise block the same edit forever.
  def test_a_corrupt_store_reads_as_empty
    dir = File.join(@dir, 'store')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'pending.json'), 'not json at all')
    assert_equal ['k1'], gate.claim(['k1'])
  end

  def test_a_store_holding_a_non_hash_reads_as_empty
    dir = File.join(@dir, 'store')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'pending.json'), '[1,2,3]')
    assert_equal ['k1'], gate.claim(['k1'])
  end

  def test_junk_values_are_dropped_but_good_ones_survive
    g = gate
    g.claim(['good'])
    path = File.join(@dir, 'store', 'pending.json')
    state = JSON.parse(File.read(path))
    state['junk'] = 'not a timestamp'
    File.write(path, JSON.generate(state))
    assert_equal ['junk'], gate.claim(%w[good junk])
  end

  def test_the_store_is_created_on_demand
    refute_path_exists File.join(@dir, 'store')
    gate.claim(['k1'])
    assert_path_exists File.join(@dir, 'store', 'pending.json')
  end

  def test_key_is_stable_for_the_same_parts
    assert_equal OnceGate.key('a', 'b'), OnceGate.key('a', 'b')
  end

  def test_key_differs_when_a_part_differs
    refute_equal OnceGate.key('a', 'b'), OnceGate.key('a', 'c')
  end

  def test_key_separates_parts_so_concatenation_does_not_collide
    refute_equal OnceGate.key('ab', 'c'), OnceGate.key('a', 'bc')
  end
end

class OnceGateForTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir('once-gate-home')
    @env = ENV.to_h.slice('HOME', 'ONCE_GATE_TEST_DIR')
  end

  def teardown
    @env.each { |k, v| ENV[k] = v }
    ENV.delete('ONCE_GATE_TEST_DIR') unless @env.key?('ONCE_GATE_TEST_DIR')
    FileUtils.remove_entry(@home)
  end

  def test_the_env_var_wins
    ENV['ONCE_GATE_TEST_DIR'] = File.join(@home, 'from-env')
    OnceGate.for('some-guard', env: 'ONCE_GATE_TEST_DIR').claim(['k'])
    assert_path_exists File.join(@home, 'from-env', 'pending.json')
  end

  def test_without_it_the_store_is_under_the_home_cache
    ENV.delete('ONCE_GATE_TEST_DIR')
    ENV['HOME'] = @home
    OnceGate.for('some-guard', env: 'ONCE_GATE_TEST_DIR').claim(['k'])
    assert_path_exists File.join(@home, '.cache', 'some-guard', 'pending.json')
  end

  def test_options_pass_through
    ENV['ONCE_GATE_TEST_DIR'] = @home
    gate = OnceGate.for('g', env: 'ONCE_GATE_TEST_DIR', filename: 'held.json', ttl: -1)
    gate.claim(['k'])
    assert_path_exists File.join(@home, 'held.json')
    assert_equal ['k'], gate.claim(['k'])
  end
end
