# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
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

  def with_repo
    Dir.mktmpdir('shell-command') do |dir|
      system('git', 'init', '-q', dir, exception: true)
      system('git', '-C', dir, 'config', 'alias.pu', 'push -u origin HEAD', exception: true)
      system('git', '-C', dir, 'config', 'alias.del', '!git branch -D $1 & git push -d origin', exception: true)
      system('git', '-C', dir, 'config', 'alias.multi', "!echo one\necho two", exception: true)
      yield dir
    end
  end

  def test_plain_git_alias_splices_in_ahead_of_the_args
    with_repo do |dir|
      assert_equal [:git, %w[push -u origin HEAD --dry-run]],
                   ShellCommand.expand_git_alias('pu', ['--dry-run'], dir: dir)
    end
  end

  def test_shell_git_alias_appends_the_args_requoted
    with_repo do |dir|
      assert_equal [:shell, "git branch -D $1 & git push -d origin austin/x\\ y"],
                   ShellCommand.expand_git_alias('del', ['austin/x y'], dir: dir)
    end
  end

  def test_multi_line_alias_value_survives
    with_repo do |dir|
      assert_equal [:shell, "echo one\necho two"], ShellCommand.expand_git_alias('multi', [], dir: dir)
    end
  end

  def test_non_alias_is_nil
    with_repo { |dir| assert_nil ShellCommand.expand_git_alias('status', [], dir: dir) }
  end

  def test_command_line_config_alias_is_seen
    with_repo do |dir|
      assert_equal [:git, %w[push origin main]],
                   ShellCommand.expand_git_alias('sneak', [], dir: dir, overrides: ['alias.sneak=push origin main'])
    end
  end

  def test_quotes_inside_a_word_are_removed
    parsed = ShellCommand.new(%(git -c alias.pu='push -u origin HEAD' pu))
    assert_equal 'alias.pu=push -u origin HEAD', parsed.unquote(parsed.commands.first[2])
  end

  def test_strip_prefix_drops_env_wrappers_their_flags_and_durations
    assert_equal %w[git status], ShellCommand.strip_prefix(%w[FOO=1 timeout 5s nice -n 10 git status])
    assert_equal %w[git push], ShellCommand.strip_prefix(%w[/usr/bin/env A=b noglob stdbuf -oL git push])
    assert_equal %w[git log], ShellCommand.strip_prefix(%w[doas xargs -n 1 git log])
    assert_equal %w[make], ShellCommand.strip_prefix(%w[timeout 1.5m make])
  end

  def test_strip_prefix_without_flags_keeps_a_leading_flag
    assert_equal %w[-x kubectl], ShellCommand.strip_prefix(%w[sudo -x kubectl], flags: false)
    assert_equal %w[kubectl], ShellCommand.strip_prefix(%w[FOO=1 timeout 30 kubectl], flags: false)
  end

  def test_strip_prefix_of_nothing_but_wrappers_is_empty
    assert_empty ShellCommand.strip_prefix(%w[env FOO=1])
  end

  def test_inline_code_takes_the_word_after_the_flag
    assert_equal '"puts 1"', ShellCommand.inline_code(['ruby', '-e', '"puts 1"'])
    assert_equal 'x', ShellCommand.inline_code(%w[python3 --command x])
    assert_nil ShellCommand.inline_code(%w[ruby -e])
    assert_nil ShellCommand.inline_code(%w[bash -lc x])
    assert_equal 'x', ShellCommand.inline_code(%w[bash -lc x], ShellCommand::SHELL_CODE_FLAG)
  end

  def test_basename
    assert_equal 'git', ShellCommand.basename('/usr/bin/git')
    assert_equal 'git', ShellCommand.basename('git')
    assert_equal '', ShellCommand.basename(nil)
  end

  def invocations(cmd, dir, **opts)
    ShellCommand.new(cmd).git_invocations(dir: dir, **opts).map(&:to_h)
  end

  def test_git_invocation_reads_dir_and_overrides
    with_repo do |dir|
      sub = File.join(dir, 'sub')
      Dir.mkdir(sub)
      found = invocations('git -C sub -c core.x=1 --no-pager status -s', dir)
      assert_equal [{ sub: 'status', args: ['-s'], raw_args: ['-s'], dir: File.realpath(sub),
                      overrides: ['core.x=1'], unresolved: nil }], found
    end
  end

  def test_git_invocation_follows_a_plain_alias
    with_repo do |dir|
      found = invocations('git pu --dry-run', dir).first
      assert_equal 'push', found[:sub]
      assert_equal %w[-u origin HEAD --dry-run], found[:args]
    end
  end

  def test_git_invocation_follows_the_g_word_and_an_alias_with_global_options
    with_repo do |dir|
      system('git', '-C', dir, 'config', 'alias.cpu', '-c push.default=current push', exception: true)
      found = invocations('g cpu', dir).first
      assert_equal 'push', found[:sub]
      assert_equal ['push.default=current'], found[:overrides]
    end
  end

  def test_git_invocation_recurses_into_a_shell_alias
    with_repo do |dir|
      found = invocations('git del austin/x', dir)
      assert_equal [%w[branch -D $1], %w[push -d origin austin/x]], found.map { |f| [f[:sub], *f[:args]] }
    end
  end

  def test_git_invocation_sees_a_command_line_alias
    with_repo do |dir|
      found = invocations("git -c alias.sneak='push origin main' sneak", dir).first
      assert_equal ['push', %w[origin main]], [found[:sub], found[:args]]
    end
  end

  def test_git_invocation_tracks_cd_for_the_alias_lookup
    with_repo do |dir|
      system('git', '-C', dir, 'config', 'alias.onlyhere', 'push', exception: true)
      Dir.mktmpdir('elsewhere') do |other|
        assert_equal 'onlyhere', invocations('git onlyhere', other).first[:sub]
        found = invocations("cd #{dir} && git onlyhere", other).first
        assert_equal ['push', File.realpath(dir)], [found[:sub], found[:dir]]
        assert_equal 'push', invocations("(cd #{dir} && git onlyhere)", other).first[:sub]
      end
    end
  end

  def test_git_invocation_cd_without_a_knowable_target
    with_repo do |dir|
      assert_nil invocations('cd - && git status', dir).first[:dir]
      assert_equal Dir.home, invocations('cd && git status', dir).first[:dir]
      assert_nil invocations('cd "$X" && git status', dir).first[:dir]
      assert_nil invocations('git -C $X status', dir).first[:dir]
    end
  end

  def test_git_invocation_walk_resolves_a_missing_path_under_a_real_parent
    Dir.mktmpdir('walk') do |dir|
      link = File.join(dir, 'link')
      File.symlink(dir, link)
      assert_equal File.join(link, 'gone'), invocations('git -C gone status', link).first[:dir]
      assert_equal File.join(File.realpath(dir), 'gone'), invocations('git -C gone status', link, walk: true).first[:dir]
    end
  end

  def test_git_invocation_recurses_into_bash_c
    with_repo do |dir|
      found = invocations(%(bash -lc "git -C #{dir} pu"), Dir.home)
      assert_equal ['push', File.realpath(dir)], [found.first[:sub], found.first[:dir]]
    end
  end

  def test_git_invocation_skips_keywords_and_wrappers
    with_repo do |dir|
      assert_equal %w[push], invocations('if timeout 5 git pu; then echo ok; fi', dir).map { |f| f[:sub] }
    end
  end

  def test_git_invocation_keeps_raw_args_alongside_unquoted_ones
    with_repo do |dir|
      found = invocations('git commit -m "$(cat f)"', dir).first
      assert_equal ['-m', '"$(cat f)"'], found[:raw_args]
      assert_equal ['-m', '$(cat f)'], found[:args]
    end
  end

  def test_git_invocation_flags_a_repo_mover_but_still_reads_the_subcommand
    with_repo do |dir|
      found = invocations('git --git-dir=/x status', dir).first
      assert_equal ['status', '`git --git-dir=/x` moves the repository this guard would read'],
                   [found[:sub], found[:unresolved]]
      found = invocations('git --work-tree /x status', dir).first
      assert_equal ['status', '`git --work-tree` moves the repository this guard would read'],
                   [found[:sub], found[:unresolved]]
      found = invocations('GIT_DIR=/x git status', dir).first
      assert_equal 'a GIT_DIR / GIT_CONFIG style variable moves the repository this guard would read', found[:unresolved]
    end
  end

  def test_git_invocation_gives_up_on_an_alias_chain_past_the_hops
    with_repo do |dir|
      system('git', '-C', dir, 'config', 'alias.a1', 'a2', exception: true)
      system('git', '-C', dir, 'config', 'alias.a2', 'pu', exception: true)
      system('git', '-C', dir, 'config', 'alias.loop', 'loop', exception: true)
      assert_equal 'push', invocations('git a1', dir).first[:sub]
      found = invocations('git a1', dir, hops: 1).first
      assert_equal ['a2', 'git alias `a2` nests too deep to follow'], [found[:sub], found[:unresolved]]
      assert_equal 'git alias `loop` nests too deep to follow', invocations('git loop', dir).first[:unresolved]
    end
  end

  def test_git_invocation_reports_an_alias_it_cannot_split
    with_repo do |dir|
      system('git', '-C', dir, 'config', 'alias.bad', "push 'oops", exception: true)
      found = invocations('git bad', dir).first
      assert_equal 'bad', found[:sub]
      assert_match(/\Agit alias `bad` could not be split: /, found[:unresolved])
    end
  end

  def test_git_invocation_ignores_an_alias_shadowing_a_builtin
    with_repo do |dir|
      system('git', '-C', dir, 'config', 'alias.status', 'push', exception: true)
      assert_equal 'status', invocations('git status', dir).first[:sub]
    end
  end

  def test_git_invocation_without_a_subcommand_or_without_git
    with_repo do |dir|
      assert_equal [nil], invocations('git --version', dir).map { |f| f[:sub] }
      assert_empty invocations('ls -la && echo git push', dir)
    end
  end
end
