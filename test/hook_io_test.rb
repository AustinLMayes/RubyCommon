# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
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
