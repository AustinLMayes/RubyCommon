# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'rbconfig'
require_relative '../lib/common/hook_io'

class HookIOTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('hook-io')
    @path = File.join(@dir, 'A.java')
    File.write(@path, "a\nb\na\n")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_write_replaces_the_file
    assert_equal ["a\nb\na\n", "x\n"], HookIO.before_after('Write', { 'content' => "x\n" }, @path)
  end

  def test_write_to_a_missing_file_starts_empty
    assert_equal ['', "x\n"], HookIO.before_after('Write', { 'content' => "x\n" }, File.join(@dir, 'B.java'))
  end

  def test_edit_replaces_the_first_match_only
    _, after = HookIO.before_after('Edit', { 'old_string' => 'a', 'new_string' => 'z' }, @path)
    assert_equal "z\nb\na\n", after
  end

  def test_edit_replace_all
    _, after = HookIO.before_after('Edit', { 'old_string' => 'a', 'new_string' => 'z', 'replace_all' => true }, @path)
    assert_equal "z\nb\nz\n", after
  end

  def test_multi_edit_applies_in_order
    edits = [{ 'old_string' => 'b', 'new_string' => 'c' }, { 'old_string' => 'c', 'new_string' => 'd' }]
    _, after = HookIO.before_after('MultiEdit', { 'edits' => edits }, @path)
    assert_equal "a\nd\na\n", after
  end

  def test_multi_edit_without_an_edits_array_changes_nothing
    assert_equal ["a\nb\na\n", "a\nb\na\n"], HookIO.before_after('MultiEdit', { 'edits' => 'x' }, @path)
  end

  def test_other_tools_change_nothing
    assert_equal ["a\nb\na\n", "a\nb\na\n"], HookIO.before_after('NotebookEdit', {}, @path)
  end
end

class HookIOContractTest < Minitest::Test
  LIB = File.expand_path('../lib', __dir__)

  def hook(code, stdin: '', env: {})
    out, err, status = Open3.capture3(env, RbConfig.ruby, "-I#{LIB}", '-rcommon/hook_io', '-e', code, stdin_data: stdin)
    [status.exitstatus, out, err]
  end

  def test_pass_exits_zero_silently
    assert_equal [0, '', ''], hook('HookIO.pass!')
  end

  def test_bare_allow_still_exits_zero_silently
    assert_equal [0, '', ''], hook('HookIO.allow!')
  end

  def test_allow_with_a_reason_is_a_permission_decision
    rc, out, err = hook('HookIO.allow!("g", "cleared")')
    assert_equal [0, ''], [rc, err]
    assert_equal({ 'hookSpecificOutput' => { 'hookEventName' => 'PreToolUse', 'permissionDecision' => 'allow',
                                             'permissionDecisionReason' => 'g: cleared' } }, JSON.parse(out))
  end

  def test_ask
    rc, out, = hook('HookIO.ask!("g", "why")')
    assert_equal 0, rc
    assert_equal 'ask', JSON.parse(out).dig('hookSpecificOutput', 'permissionDecision')
    assert_equal 'g: why', JSON.parse(out).dig('hookSpecificOutput', 'permissionDecisionReason')
  end

  def test_one_argument_block_prints_the_message_as_is
    assert_equal [2, '', "raw text\n"], hook('HookIO.block!("raw text")')
  end

  def test_block_names_the_guard
    assert_equal [2, '', "BLOCKED by g hook: no.\n"], hook('HookIO.block!("g", "no.")')
  end

  def test_block_with_a_leading_newline_keeps_the_header_bare
    assert_equal [2, '', "BLOCKED by g hook:\n\n  • a\n"], hook('HookIO.block!("g", "\n\n  • a")')
  end

  def test_warn_is_a_system_message
    rc, out, err = hook('HookIO.warn!("g", "note")')
    assert_equal [0, ''], [rc, err]
    assert_equal({ 'systemMessage' => 'g: note' }, JSON.parse(out))
  end

  def test_warn_with_an_event_adds_context
    _, out, = hook('HookIO.warn!("g", "note", event: "PostToolUse")')
    assert_equal({ 'systemMessage' => 'g: note',
                   'hookSpecificOutput' => { 'hookEventName' => 'PostToolUse', 'additionalContext' => 'g: note' } },
                 JSON.parse(out))
  end

  def test_fail_open_says_what_went_unchecked
    rc, out, = hook('HookIO.fail_open!("g", "boom", "this push")')
    assert_equal 0, rc
    assert_equal 'g: boom, so this push went unchecked', JSON.parse(out)['systemMessage']
  end

  def test_fail_closed_blocks
    assert_equal [2, '', "BLOCKED by g hook: boom\n"], hook('HookIO.fail_closed!("g", "boom")')
  end

  def test_guard_yields_the_payload_and_passes_when_the_block_returns
    assert_equal [0, 'ls', ''], hook('HookIO.guard("g") { |p| print HookIO.command(p) }',
                                     stdin: '{"tool_input":{"command":"ls"}}')
  end

  def test_guard_lets_an_exit_inside_the_block_through
    assert_equal [2, '', "BLOCKED by g hook: x\n"], hook('HookIO.guard("g") { HookIO.block!("g", "x") }', stdin: '{}')
  end

  def test_guard_fails_open_on_a_bad_payload
    rc, out, = hook('HookIO.guard("g", what: "this edit") { raise "unreached" }', stdin: 'nope')
    assert_equal 0, rc
    assert_equal 'g: the tool payload did not parse as JSON, so this edit went unchecked', JSON.parse(out)['systemMessage']
  end

  def test_guard_fails_closed_on_a_bad_payload
    rc, _, err = hook('HookIO.guard("g", on_error: :closed) { raise "unreached" }', stdin: 'nope')
    assert_equal 2, rc
    assert_equal "BLOCKED by g hook: the tool payload did not parse as JSON\n", err
  end

  def test_guard_fails_open_on_a_crash
    rc, out, = hook('HookIO.guard("g") { raise "boom" }', stdin: '{}')
    assert_equal 0, rc
    assert_equal 'g: crashed (RuntimeError: boom), so this call went unchecked', JSON.parse(out)['systemMessage']
  end

  def test_guard_routes_a_load_error_too
    rc, _, err = hook('HookIO.guard("g", on_error: :closed) { require "no/such/lib" }', stdin: '{}')
    assert_equal 2, rc
    assert_match(/\ABLOCKED by g hook: crashed \(LoadError: cannot load such file -- no\/such\/lib\)/, err)
  end

  def test_command_tolerates_a_missing_tool_input
    assert_equal '', HookIO.command({})
    assert_equal '', HookIO.command({ 'tool_input' => 'x' })
  end

  def test_cwd_falls_back_to_the_process_dir
    assert_equal '/x', HookIO.cwd({ 'cwd' => '/x' })
    assert_equal Dir.pwd, HookIO.cwd({ 'cwd' => '' })
    assert_equal Dir.pwd, HookIO.cwd({})
  end

  def test_unattended_reads_a_non_empty_job_dir
    assert_equal [0, 'true', ''], hook('print HookIO.unattended?', env: { 'CLAUDE_JOB_DIR' => '/j' })
    assert_equal [0, 'false', ''], hook('print HookIO.unattended?', env: { 'CLAUDE_JOB_DIR' => '' })
    assert_equal [0, 'false', ''], hook('print HookIO.unattended?', env: { 'CLAUDE_JOB_DIR' => nil })
  end
end
