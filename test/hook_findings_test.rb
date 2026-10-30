# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'rbconfig'
require_relative '../lib/common/hook_findings'

class HookFindingsTest < Minitest::Test
  LIB = File.expand_path('../lib', __dir__)

  def setup
    @state = Dir.mktmpdir('hook-findings')
  end

  def teardown
    FileUtils.remove_entry(@state)
  end

  def finding(**fields) = HookFindings::Finding.new(**fields)

  def finish(findings, **opts)
    args = { gate: "OnceGate.new(dir: #{@state.inspect})", session: '"s1"', path: '"/r/A.java"',
             lead: '"this Edit to /r/A.java adds"', retry_note: '"Re-issue it."' }
    args.merge!(opts.transform_values(&:inspect))
    code = "f = #{findings}.map { |h| HookFindings::Finding.new(**h) }\n" \
           "HookFindings.finish!('g', f, #{args.map { |k, v| "#{k}: #{v}" }.join(', ')})"
    out, err, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", '-rcommon/hook_findings', '-e', code)
    [status.exitstatus, out, err]
  end

  def test_describe_with_a_line
    f = finding(mode: :block, name: 'n', say: 'does x', text: 'var a = 1;', line: 3)
    assert_equal "line 3 does x:\n      var a = 1;", f.describe
  end

  def test_describe_a_removed_line
    f = finding(mode: :once, name: 'n', say: 'drops it', text: 'import a;', line: 7, side: :removed)
    assert_equal "removed line 7 drops it:\n      import a;", f.describe
  end

  def test_describe_without_a_line_and_cut_at_140
    f = finding(mode: :warn, name: 'n', say: 'says', text: 'x' * 200)
    assert_equal "says:\n      #{'x' * 140}", f.describe
  end

  def test_claim_returns_the_once_findings_not_seen_before
    gate = OnceGate.new(dir: @state)
    once = finding(mode: :once, name: 'a', say: 's', text: 't')
    found = [finding(mode: :block, name: 'b', say: 's', text: 't'), once]
    assert_equal [once], HookFindings.claim(gate, found, session: 's1', path: '/p')
    assert_empty HookFindings.claim(gate, found, session: 's1', path: '/p')
    assert_equal [once], HookFindings.claim(gate, found, session: 's2', path: '/p')
  end

  def test_claim_keys_on_the_identity_when_given
    gate = OnceGate.new(dir: @state)
    HookFindings.claim(gate, [finding(mode: :once, name: 'a', text: 'shown', identity: 'raw')], session: 's', path: '/p')
    assert_empty HookFindings.claim(gate, [finding(mode: :once, name: 'a', text: 'other', identity: 'raw')],
                                    session: 's', path: '/p')
    refute_empty HookFindings.claim(gate, [finding(mode: :once, name: 'a', text: 'shown')], session: 's', path: '/p')
  end

  def test_claim_keys_on_a_finding_path_over_the_call_path
    gate = OnceGate.new(dir: @state)
    HookFindings.claim(gate, [finding(mode: :once, name: 'a', text: 't', path: '/x')], session: 's', path: '/p')
    assert_empty HookFindings.claim(gate, [finding(mode: :once, name: 'a', text: 't')], session: 's', path: '/x')
  end

  def test_claim_lets_everything_through_when_the_gate_fails
    gate = Object.new
    def gate.claim(_) = raise(Errno::EACCES)
    assert_empty HookFindings.claim(gate, [finding(mode: :once, name: 'a', text: 't')], session: 's', path: '/p')
  end

  def test_no_findings_pass_silently
    assert_equal [0, '', ''], finish('[]')
  end

  def test_warn_findings_are_one_system_message
    rc, out, err = finish('[{ mode: :warn, name: "a", say: "says a", text: "x", line: 1 },
                           { mode: :warn, name: "b", say: "says b", text: "y", line: 2 }]')
    assert_equal [0, ''], [rc, err]
    assert_equal({ 'systemMessage' => "g: /r/A.java line 1 says a:\n      x; line 2 says b:\n      y" }, JSON.parse(out))
  end

  def test_a_block_finding_blocks_with_its_never_note
    rc, out, err = finish('[{ mode: :block, name: "a", say: "says a", text: "x", line: 1, never: "A is never allowed." },
                           { mode: :warn, name: "b", say: "says b", text: "y", line: 2 }]')
    assert_equal [2, ''], [rc, out]
    assert_equal "BLOCKED by g hook: this Edit to /r/A.java adds\n\n  • line 1 says a:\n      x\n\nA is never allowed.\n", err
  end

  def test_a_once_finding_blocks_then_passes
    once = '[{ mode: :once, name: "a", say: "says a", text: "x", line: 4 }]'
    assert_equal [2, '', "BLOCKED by g hook: this Edit to /r/A.java adds\n\n  • line 4 says a:\n      x\n\nRe-issue it.\n"],
                 finish(once)
    assert_equal [0, '', ''], finish(once)
  end

  def test_nevers_come_first_and_once_without_a_fresh_claim_drops_the_retry_note
    both = '[{ mode: :block, name: "a", say: "a", text: "x", never: "N." }, { mode: :once, name: "b", say: "b", text: "y" }]'
    _, _, first = finish(both)
    assert first.end_with?("\n\nN. Re-issue it.\n"), first
    _, _, again = finish(both)
    assert again.end_with?("  • a:\n      x\n\nN.\n"), again
  end

  def test_the_same_never_is_said_once
    _, _, err = finish('[{ mode: :block, name: "a", say: "a", text: "x", never: "N." },
                         { mode: :block, name: "a", say: "a", text: "y", never: "N." }]')
    assert err.end_with?("\n\nN.\n"), err
  end

  def test_more_than_the_cap_says_how_many_more
    many = (1..10).map { |i| "{ mode: :block, name: 'a', say: 'a', text: 't#{i}', line: #{i} }" }.join(', ')
    _, _, err = finish("[#{many}]")
    assert_equal 8, err.scan('  • ').length
    assert_includes err, "      t8\n  … and 2 more\n\n"
  end

  def test_no_cap_shows_every_finding
    many = (1..10).map { |i| "{ mode: :block, name: 'a', say: 'a', text: 't#{i}' }" }.join(', ')
    _, _, err = finish("[#{many}]", cap: nil)
    assert_equal 10, err.scan('  • ').length
    refute_includes err, 'more'
  end
end
