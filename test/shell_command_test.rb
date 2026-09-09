# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/common/shell_command'

class ShellCommandTest < Minitest::Test
  def test_doc_write_quoting_a_commit_is_not_a_commit
    cmd = <<~CMD
      cat > a.md <<'EOF'
      Prefer `git commit -m "Subject"` with no body.
      EOF
    CMD
    refute ShellCommand.new(cmd).git_commit?
  end

  def test_real_commit_is_a_commit
    assert ShellCommand.new('git commit -m "Subject"').git_commit?
  end

  def test_commit_tree_is_not_a_commit
    refute ShellCommand.new('git commit-tree abc -p def').git_commit?
  end

  def test_commit_hidden_in_a_shell_heredoc_is_still_found
    cmd = <<~CMD
      bash <<'SH'
      git commit -m "Subject"
      SH
    CMD
    assert ShellCommand.new(cmd).git_commit?
  end

  def test_commit_hidden_in_an_ssh_heredoc_is_still_found
    cmd = <<~CMD
      ssh host <<'EOS'
      cd /r && git commit -m "Subject"
      EOS
    CMD
    assert ShellCommand.new(cmd).git_commit?
  end

  def test_here_string_is_not_a_heredoc
    cmd = <<~CMD
      grep -q x <<<yes
      cat > a.md <<'EOF'
      Prefer `git commit -m "Subject"`.
      EOF
    CMD
    parsed = ShellCommand.new(cmd)
    refute parsed.unterminated?
    refute parsed.git_commit?
  end

  def test_digit_leading_delimiter
    cmd = <<~CMD
      cat > a.md <<'2DOC'
      Prefer `git commit -m "Subject"`.
      2DOC
    CMD
    parsed = ShellCommand.new(cmd)
    refute parsed.unterminated?
    refute parsed.git_commit?
  end

  def test_dashed_delimiter
    cmd = <<~CMD
      cat > a.md <<'DOC-MSG'
      Prefer `git commit -m "Subject"`.
      DOC-MSG
    CMD
    parsed = ShellCommand.new(cmd)
    refute parsed.unterminated?
    refute parsed.git_commit?
  end

  def test_dash_heredoc_strips_leading_tabs_from_terminator
    cmd = "cat > a.md <<-EOF\n\tPrefer `git commit`.\n\tEOF\n"
    parsed = ShellCommand.new(cmd)
    refute parsed.unterminated?
    refute parsed.git_commit?
  end

  def test_plain_heredoc_does_not_terminate_on_an_indented_delimiter
    cmd = "cat > a.md <<EOF\nbody\n  EOF\n"
    assert ShellCommand.new(cmd).unterminated?
  end

  def test_two_heredocs_on_one_line
    cmd = "cat <<'A' <<'B' > f\nfirst `git commit`\nA\nsecond `git commit`\nB\n"
    parsed = ShellCommand.new(cmd)
    refute parsed.unterminated?
    refute parsed.git_commit?
    assert_equal 2, parsed.heredocs.length
  end

  def test_unterminated_heredoc_falls_back_to_raw
    cmd = "cat > a.md <<'EOF'\ngit commit -m \"Subject\"\n"
    parsed = ShellCommand.new(cmd)
    assert parsed.unterminated?
    assert_equal cmd, parsed.code
    assert parsed.git_commit?
  end

  def test_collects_every_message_value_not_just_the_first
    cmd = 'git commit -m "Subject" -m "Body paragraph."'
    assert_equal ['Subject', 'Body paragraph.'], ShellCommand.new(cmd).flag_values('-m', '--message')
  end

  def test_collects_message_with_equals_form
    cmd = 'git commit --message="Subject"'
    assert_equal ['Subject'], ShellCommand.new(cmd).flag_values('-m', '--message')
  end

  def test_single_quoted_message
    cmd = "git commit -m 'Subject here'"
    assert_equal ['Subject here'], ShellCommand.new(cmd).flag_values('-m', '--message')
  end

  def test_commit_heredoc_is_attributed_to_git
    cmd = <<~CMD
      git commit -F - <<'EOF'
      Subject
      EOF
    CMD
    parsed = ShellCommand.new(cmd)
    refute_nil parsed.commit_heredoc
    assert_equal "Subject\n", parsed.commit_heredoc.body
  end

  def test_doc_heredoc_is_not_attributed_to_git
    cmd = <<~CMD
      cat > a.md <<'EOF'
      Some prose.
      EOF
      git commit -m "Subject"
    CMD
    parsed = ShellCommand.new(cmd)
    assert parsed.git_commit?
    assert_nil parsed.commit_heredoc
    assert_equal ['Subject'], parsed.flag_values('-m')
  end

  def test_separators_split_commands
    parsed = ShellCommand.new('cd /r && git commit -m "S"')
    assert_equal 2, parsed.commands.length
    assert parsed.git_commit?
  end

  def test_flag_detection
    assert ShellCommand.new('git commit --amend --no-edit').flag?('--amend')
    refute ShellCommand.new('git commit -m "x"').flag?('--amend')
  end

  def test_semicolon_in_a_quoted_message_does_not_split
    parsed = ShellCommand.new('git commit -m "Subject; not a separator"')
    assert_equal ['Subject; not a separator'], parsed.flag_values('-m')
  end
end
