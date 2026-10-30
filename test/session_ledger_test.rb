# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/common/session_ledger'

class SessionLedgerTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('session-ledger')
    @env = ENV.to_h.slice('CLAUDE_JOB_DIR', 'SESSION_LEDGER_DIR', 'HOME')
    %w[CLAUDE_JOB_DIR SESSION_LEDGER_DIR].each { |k| ENV.delete(k) }
  end

  def teardown
    %w[CLAUDE_JOB_DIR SESSION_LEDGER_DIR HOME].each { |k| @env.key?(k) ? ENV[k] = @env[k] : ENV.delete(k) }
    FileUtils.remove_entry(@dir)
  end

  def test_a_job_dir_wins
    ENV['CLAUDE_JOB_DIR'] = '/job'
    assert_equal '/job', SessionLedger.dir({ 'session_id' => 's' })
    assert_equal '/job', SessionLedger.dir({ 'session_id' => 's' }, job_only: true)
  end

  def test_an_empty_job_dir_counts_as_none
    ENV['CLAUDE_JOB_DIR'] = ''
    ENV['SESSION_LEDGER_DIR'] = '/ledgers'
    assert_equal '/ledgers/s', SessionLedger.dir({ 'session_id' => 's' })
  end

  def test_job_only_without_a_job_is_nil
    ENV['SESSION_LEDGER_DIR'] = '/ledgers'
    assert_nil SessionLedger.dir({ 'session_id' => 's' }, job_only: true)
  end

  def test_the_session_dir_defaults_under_the_home_cache
    ENV['HOME'] = @dir
    assert_equal File.join(@dir, '.cache', 'session-ledger', 's'), SessionLedger.dir({ 'session_id' => 's' })
  end

  def test_no_session_is_nil
    assert_nil SessionLedger.dir({})
    assert_nil SessionLedger.dir({ 'session_id' => '' })
  end

  def test_append_creates_the_dir_and_reads_back_in_order
    dir = File.join(@dir, 'a', 'b')
    SessionLedger.append(dir, { kind: 'dump', path: '/x' }, file: 'l.jsonl')
    SessionLedger.append(dir, { kind: 'forward', ports: ['1:2'] }, file: 'l.jsonl')
    assert_equal [{ 'kind' => 'dump', 'path' => '/x' }, { 'kind' => 'forward', 'ports' => ['1:2'] }],
                 SessionLedger.read(dir, file: 'l.jsonl')
  end

  def test_appending_nothing_writes_nothing
    dir = File.join(@dir, 'none')
    SessionLedger.append(dir, file: 'l.jsonl')
    refute_path_exists dir
  end

  def test_read_skips_unparsable_lines
    File.write(File.join(@dir, 'l.jsonl'), "{\"a\":1}\nnot json\n{\"b\":2}\n")
    assert_equal [{ 'a' => 1 }, { 'b' => 2 }], SessionLedger.read(@dir, file: 'l.jsonl')
  end

  def test_read_of_a_missing_file_is_empty
    assert_equal [], SessionLedger.read(@dir, file: 'nope.jsonl')
  end
end
