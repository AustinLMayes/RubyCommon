# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/common/line_diff'

class LineDiffTest < Minitest::Test
  def added(old, new)
    lines, set = LineDiff.added_indices(old, new)
    [lines, set.to_a.sort]
  end

  def test_identical_text_adds_nothing
    lines, set = added("a\nb\nc\n", "a\nb\nc\n")
    assert_equal %w[a b c], lines
    assert_empty set
  end

  def test_pure_insertion
    _lines, set = added("a\nc\n", "a\nb\nc\n")
    assert_equal [1], set
  end

  def test_replacement
    _lines, set = added("a\nb\nc\n", "a\nB\nc\n")
    assert_equal [1], set
  end

  def test_deletion_adds_nothing
    _lines, set = added("a\nb\nc\n", "a\nc\n")
    assert_empty set
  end

  def test_empty_old_makes_everything_new
    _lines, set = added('', "a\nb\n")
    assert_equal [0, 1], set
  end

  def test_empty_new_adds_nothing
    lines, set = added("a\nb\n", '')
    assert_empty lines
    assert_empty set
  end

  def test_appending_at_the_end
    _lines, set = added("a\nb\n", "a\nb\nc\nd\n")
    assert_equal [2, 3], set
  end

  def test_prepending_at_the_start
    _lines, set = added("c\n", "a\nb\nc\n")
    assert_equal [0, 1], set
  end

  def test_duplicate_lines_do_not_confuse_the_match
    _lines, set = added("x\nx\n", "x\nx\nx\n")
    assert_equal 1, set.length
  end

  def test_a_line_moved_is_reported_once
    _lines, set = added("a\nb\n", "b\na\n")
    assert_equal 1, set.length
  end

  def test_no_trailing_newline_is_handled
    lines, set = added('a', 'b')
    assert_equal ['b'], lines
    assert_equal [0], set
  end

  # Over the cap we stop diffing and call the whole changed region new, so a
  # huge rewrite must still report rather than hang or return nothing.
  def test_over_the_cell_cap_everything_changed_is_new
    old = Array.new(3000) { |i| "old#{i}" }.join("\n")
    new = Array.new(3000) { |i| "new#{i}" }.join("\n")
    _lines, set = added(old, new)
    assert_equal 3000, set.length
  end

  def test_large_files_with_a_small_edit_stay_precise
    base = Array.new(4000) { |i| "line#{i}" }
    changed = base.dup
    changed[2000] = 'touched'
    _lines, set = added(base.join("\n"), changed.join("\n"))
    assert_equal [2000], set
  end
end
