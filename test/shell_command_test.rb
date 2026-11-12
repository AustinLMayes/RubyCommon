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
                      overrides: ['core.x=1'], unresolved: nil,
                      segment: %w[git -C sub -c core.x=1 --no-pager status -s], at: 6, cwd: dir, nested: false }], found
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

  def test_an_apostrophe_in_a_comment_does_not_swallow_the_next_line
    cmd = ShellCommand.new("a=1 # don't\ngit push origin main")
    assert_equal [['a=1', '#', "don't"], %w[git push origin main]], cmd.commands
    assert_equal ["don't"], cmd.comments
    assert_equal [%w[echo a#b]], ShellCommand.new('echo a#b').commands
    assert_empty ShellCommand.new(%(gh pr comment --body '# GH-OK')).comments
  end

  def test_a_backtick_or_process_substitution_is_one_word
    assert_equal ['x=`git push origin main`'], ShellCommand.new('x=`git push origin main`').tokens
    assert_equal ['cat', '<(git push origin main)', '>(tee a b)'], ShellCommand.new('cat <(git push origin main) >(tee a b)').tokens
  end

  def test_a_heredoc_knows_whether_its_delimiter_was_quoted
    docs = ShellCommand.new("cat <<A <<'B' <<\"C\"\na\nA\nb\nB\nc\nC").heredocs
    assert_equal [false, true, true], docs.map(&:quoted)
  end

  def test_substitutions_outermost_first_outside_single_quotes_and_comments
    text = %(echo $(a) "$(b)" '$(c)' `d` <(e) >(f) $(x $(y)) # $(g))
    assert_equal ['a', 'b', 'd', 'e', 'f', 'x $(y)'], ShellCommand.substitutions(text)
    assert_equal ['a ")" b'], ShellCommand.substitutions('$(a ")" b)')
    assert_equal ['unclosed'], ShellCommand.substitutions('$(unclosed')
  end

  def test_zsh_equals_substitution_after_a_separator_but_not_an_array
    assert_equal %w[a b c d e], ShellCommand.substitutions('cat =(a); x;=(b)|=(c)&&=(d) (=(e))')
    assert_empty ShellCommand.substitutions('a=(1 2) b+=(3) c[1]=(4)')
  end

  def test_a_glued_redirect_ends_the_word
    assert_equal [%w[gh pr create >/dev/null]], ShellCommand.new('gh pr create>/dev/null').commands
    assert_equal [%w[git push <<<x]], ShellCommand.new('git push<<<x').commands
    assert_equal [%w[echo 2>/dev/null]], ShellCommand.new('echo 2>/dev/null').commands
    assert_equal [%w[diff <(a)]], ShellCommand.new('diff <(a)').commands
  end

  def test_git_invocation_reads_through_eval_and_exec
    with_repo do |dir|
      assert_equal %w[push], invocations("eval 'git push origin production'", dir).map { |f| f[:sub] }
      assert_equal %w[push], invocations(%(eval "git -C #{dir} push"), Dir.home).map { |f| f[:sub] }
      assert_equal %w[push], invocations('exec git push origin production', dir).map { |f| f[:sub] }
      assert_equal %w[push], invocations('{ eval git push; }', dir).map { |f| f[:sub] }
    end
  end

  def test_git_invocation_finds_a_shell_handed_code_mid_command
    with_repo do |dir|
      assert_equal %w[push], invocations(%(find . -exec bash -c 'git push origin x' \;), dir).map { |f| f[:sub] }
      assert_equal %w[push], invocations(%(xargs -n1 zsh -ec 'git push origin x'), dir).map { |f| f[:sub] }
    end
  end

  def test_git_invocation_follows_substitutions_only_when_asked_and_keeps_the_cd
    with_repo do |dir|
      Dir.mktmpdir('elsewhere') do |other|
        cmd = "cd #{dir} && x=$(git push origin main)"
        assert_empty invocations(cmd, other)
        found = invocations(cmd, other, substitutions: true)
        assert_equal [['push', File.realpath(dir)]], found.map { |f| [f[:sub], f[:dir]] }
        found = invocations("x=$(git push) && cd #{dir}", other, substitutions: true)
        assert_equal [['push', other]], found.map { |f| [f[:sub], f[:dir]] }
        assert_equal %w[push], invocations(%(bash -c 'x=$(git push origin production)'), dir, substitutions: true).map { |f| f[:sub] }
        assert_equal %w[push], invocations('echo "`git push`" <(git push)', dir, substitutions: true).map { |f| f[:sub] }.uniq
        assert_empty invocations("echo '$(git push)' # $(git push)", dir, substitutions: true)
      end
    end
  end

  def test_git_invocation_follows_substitutions_in_an_unquoted_heredoc
    with_repo do |dir|
      assert_equal %w[push], invocations("cat <<E\n$(git push origin main)\nE", dir, substitutions: true).map { |f| f[:sub] }
      assert_empty invocations("cat <<'E'\n$(git push origin main)\nE", dir, substitutions: true)
      found = invocations("cd /tmp && cat <<E\n$(git push origin main)\nE", dir, substitutions: true)
      assert_equal [['push', nil]], found.map { |f| [f[:sub], f[:dir]] }
    end
  end

  def test_git_invocation_gives_up_on_substitutions_past_the_hops
    found = invocations('echo $(echo $(echo $(git push)))', Dir.home, substitutions: true, hops: 2)
    assert_equal ['it nests shells or substitutions too deep to read'], found.map { |f| f[:unresolved] }
  end

  def test_strip_prefix_skips_the_value_a_wrapper_flag_takes
    assert_equal %w[git push], ShellCommand.strip_prefix(%w[env -u FOO git push])
    assert_equal %w[git push], ShellCommand.strip_prefix(%w[exec -a x git push])
    assert_equal %w[git push], ShellCommand.strip_prefix(%w[timeout -s KILL 60 git push])
    assert_equal %w[fgutils {}], ShellCommand.strip_prefix(%w[xargs -I {} fgutils {}])
    assert_equal %w[git push], ShellCommand.strip_prefix(%w[caffeinate -i builtin git push])
  end

  def test_a_line_continuation_joins_the_words
    assert_equal [%w[git push origin main]], ShellCommand.new("git \\\npush origin main").commands
    assert_equal ['"ab"'], ShellCommand.new("\"a\\\nb\"").tokens
  end

  def test_an_ansi_c_string_is_one_word
    assert_equal [["echo", "$'\\''"], %w[git push origin main]], ShellCommand.new("echo $'\\'' ; git push origin main").commands
    assert_empty ShellCommand.new(%(gh pr comment 1 --body $'\\' # GH-OK')).comments
    assert_equal ['git push'], ShellCommand.substitutions("echo $'\\'' $(git push)")
  end

  def test_a_heredoc_opener_in_a_comment_or_a_string_is_not_one
    ["# <<true", %(echo "<<true"), "echo '<<true'"].each do |line|
      cmd = ShellCommand.new(":\n#{line}\ngit push origin main\ntrue")
      assert_empty cmd.heredocs, line
      assert_includes cmd.commands, %w[git push origin main]
    end
    assert_equal ['E'], ShellCommand.new("cat <<'E'\nx\nE").heredocs.map(&:delim)
  end

  def test_substitutions_in_a_heredoc_body_ignore_quotes_and_hashes
    assert_equal ['git push'], ShellCommand.substitutions("don't\n$(git push)\n", heredoc: true)
    assert_equal ['git push'], ShellCommand.substitutions("# $(git push)\n", heredoc: true)
    assert_empty ShellCommand.substitutions('echo \$(git push)')
    assert_equal ['git push'], ShellCommand.substitutions('echo a\ #$(git push)')
  end

  def test_git_invocation_normalises_an_escaped_or_equals_command_word
    with_repo do |dir|
      ['\git push', 'gi\t push', '=git push', "'git' push"].each do |cmd|
        assert_equal %w[push], invocations(cmd, dir).map { |f| f[:sub] }, cmd
      end
    end
  end

  def test_git_invocation_reads_csh_and_env_dash_s
    with_repo do |dir|
      assert_equal %w[push], invocations(%(tcsh -c "git push origin main"), dir).map { |f| f[:sub] }
      assert_equal %w[push], invocations(%(env -S "git push origin main"), dir).map { |f| f[:sub] }
    end
  end

  def test_git_invocation_gives_up_on_eval_and_shells_past_the_hops
    found = invocations("eval eval eval eval eval eval git push", Dir.home)
    assert_equal ['it nests shells or substitutions too deep to read'], found.map { |f| f[:unresolved] }
    found = invocations(%(bash -c "bash -c 'git push'"), Dir.home, hops: 1)
    assert_equal ['it nests shells or substitutions too deep to read'], found.map { |f| f[:unresolved] }
  end

  def test_git_invocation_forgets_a_cd_it_cannot_be_sure_ran_here
    with_repo do |dir|
      Dir.mktmpdir('elsewhere') do |other|
        here = File.realpath(other)
        real = File.realpath(dir)
        { "(cd #{dir}) && git status" => other, "(cd #{dir} && git status)" => real,
          "cd #{dir} & git status" => nil, "cd #{dir} | true; git status" => nil, "true || cd #{dir}; git status" => nil,
          "test -d x && cd #{dir}; git status" => nil, "cd #{dir} && cd . && git status" => real,
          "pushd #{dir}; popd; git status" => other, "pushd #{dir} && git status" => real,
          "popd; git status" => nil }.each do |cmd, want|
          assert_equal [want], invocations(cmd, other).map { |f| f[:dir] }, cmd
        end
        assert_equal here, File.realpath(other)
      end
    end
  end

  def test_git_invocation_follows_substitutions_through_a_shell_alias
    with_repo do |dir|
      system('git', '-C', dir, 'config', 'alias.sub', '!x=$(git push origin main)', exception: true)
      assert_includes invocations('git sub', dir, substitutions: true).map { |f| f[:sub] }, 'push'
    end
  end

  def test_git_invocation_drops_a_trailing_comment_and_hands_a_wrapped_shell_to_the_block
    with_repo do |dir|
      assert_equal [%w[status]], invocations('git status # push it', dir).map { |f| f[:args].empty? ? [f[:sub]] : [f[:sub], *f[:args]] }
      seen = []
      ShellCommand.new(%(find . -exec bash -c 'echo hi' +)).git_invocations(dir: dir) { |words, _| seen << words }
      assert_equal [['find', '.', '-exec', 'bash', '-c', 'echo hi', '+'], %w[echo hi]], seen
    end
  end

  def test_unquote_decodes_backslashes_and_ansi_strings
    sc = ShellCommand.new('')
    assert_equal 'push', sc.unquote('pu\\sh')
    assert_equal 'git push origin main', sc.unquote('git\\ push\\ origin\\ main')
    assert_equal 'git push', sc.unquote("$'git push'")
    assert_equal "it's", sc.unquote("$'it\\'s'")
    assert_equal 'gh', sc.unquote("$'\\x67h'")
    assert_equal 'a b', sc.unquote("'a b'")
  end

  def test_git_invocation_decodes_an_escaped_subcommand_and_code
    with_repo do |dir|
      ['git pu\\sh origin main', 'git -C . pu\\sh', 'bash -c git\\ push\\ origin\\ main', "bash -c $'git push origin main'",
       'eval git\\ push'].each do |cmd|
        assert_equal %w[push], invocations(cmd, dir).map { |f| f[:sub] }, cmd
      end
    end
  end

  def test_git_invocation_refuses_a_subcommand_built_at_run_time
    with_repo do |dir|
      ['git $SUB origin main', 'git p?sh origin main', 'git "$(echo push)"'].each do |cmd|
        assert_equal ['its git subcommand is only known when it runs'], invocations(cmd, dir).map { |f| f[:unresolved] }, cmd
      end
    end
  end

  def test_git_invocation_reads_every_env_split_string_spelling
    with_repo do |dir|
      ['env -i -S "git push origin main"', 'env -S"git push origin main"', 'env --split-string="git push origin main"',
       'env FOO=1 -S "git push origin main"', 'env -iS "git push origin main"'].each do |cmd|
        assert_equal %w[push], invocations(cmd, dir).map { |f| f[:sub] }, cmd
      end
    end
  end

  def test_git_invocation_runs_where_env_or_sudo_moves_it
    with_repo do |dir|
      Dir.mktmpdir('elsewhere') do |other|
        real = File.realpath(dir)
        ["env -C #{dir} git status", "env --chdir=#{dir} git status", "sudo -D #{dir} git status"].each do |cmd|
          assert_equal [real], invocations(cmd, other).map { |f| f[:dir] }, cmd
        end
        assert_equal [nil], invocations('env -C "$X" git status', other).map { |f| f[:dir] }
      end
    end
  end

  def test_git_invocation_marks_xargs_arguments_unresolved
    with_repo do |dir|
      ['echo main | xargs git push origin', 'xargs -n1 git push origin < f'].each do |cmd|
        assert_equal ['xargs adds arguments to it from stdin'], invocations(cmd, dir).map { |f| f[:unresolved] }, cmd
      end
      assert_equal ['xargs adds arguments to it from stdin'], invocations('xargs -I{} git push origin {}', dir).map { |f| f[:unresolved] }
      assert_equal [nil], invocations('xargs -I{} git push origin main', dir).map { |f| f[:unresolved] }
      ['echo push | gxargs git', 'parallel git push origin ::: main', 'parallel git push origin main', 'xargs -i git {}'].each do |cmd|
        assert_equal ['xargs adds arguments to it from stdin'], invocations(cmd, dir).map { |f| f[:unresolved] }, cmd
      end
    end
  end

  def test_xargs_marker_reads_every_replace_spelling
    assert_equal 'X', ShellCommand.xargs_marker(%w[-n1 -I X])
    assert_equal '%', ShellCommand.xargs_marker(%w[-J%])
    assert_equal '{}', ShellCommand.xargs_marker(%w[-i])
    assert_equal 'R', ShellCommand.xargs_marker(%w[--replace=R])
    assert_equal '{', ShellCommand.xargs_marker(%w[-j4], parallel: true)
    assert_nil ShellCommand.xargs_marker(%w[-n1])
  end

  def test_a_precommand_before_a_subshell_still_names_the_command
    with_repo do |dir|
      ['time (git push origin HEAD)', 'coproc (git push origin HEAD)', 'nocorrect git push origin HEAD'].each do |cmd|
        assert_equal ['push'], invocations(cmd, dir).map { |f| f[:sub] }, cmd
      end
    end
    assert_equal 'gh', ShellCommand.command_name('({gh')
  end

  def test_a_globbed_cd_leaves_the_dir_unknown
    with_repo do |dir|
      ['cd /tm? && git status', 'cd {/tmp,/x} && git status'].each do |cmd|
        assert_equal [nil], invocations(cmd, dir).map { |f| f[:dir] }, cmd
      end
      assert_equal [File.realpath('/tmp')], invocations("cd '/tmp' && git status", dir).map { |f| f[:dir] }
    end
  end

  def test_git_invocation_forgets_the_dir_after_an_eval_that_moves
    with_repo do |dir|
      Dir.mktmpdir('elsewhere') do |other|
        assert_equal [nil], invocations(%(eval "cd #{dir}"; git status), other).map { |f| f[:dir] }
        assert_equal [nil], invocations("eval cd #{dir} && git status", other).map { |f| f[:dir] }
      end
    end
  end

  def test_git_invocation_pops_a_subshell_whose_last_word_is_quoted_or_substituted
    with_repo do |dir|
      Dir.mktmpdir('elsewhere') do |other|
        [%((cd #{dir} && echo "wip"); git status), %((cd #{dir} && echo $(pwd)); git status), %((cd #{dir}; echo 'a') && git status),
         "true | cd #{dir}; git status"].each_with_index do |cmd, i|
          assert_equal [i == 3 ? nil : other], invocations(cmd, other).map { |f| f[:dir] }, cmd
        end
      end
    end
  end

  def test_git_invocation_reads_the_attr_source_value_and_csh_fish
    with_repo do |dir|
      assert_equal %w[push], invocations('git --attr-source HEAD push origin main', dir).map { |f| f[:sub] }
      assert_equal %w[push push], invocations(%(csh -c "git push" ; fish -c "git push"), dir).map { |f| f[:sub] }
      assert_equal %w[push], invocations("gi\\\nt push", dir).map { |f| f[:sub] }
      assert_includes invocations(%(eval 'x=$(git push)'), dir, substitutions: true).map { |f| f[:sub] }, 'push'
      assert_equal %w[push], invocations('sudo -u x git push', dir).map { |f| f[:sub] }
    end
  end

  def test_a_heredoc_scan_reads_quotes_arithmetic_and_comments_the_way_the_shell_does
    ["true;# <<EOF", 'echo $((1<<2))', 'x=$((a <<b))', '(( a<<1 ))', 'echo $[1<<2]'].each do |line|
      cmd = ShellCommand.new("#{line}\ngit push origin main\nEOF")
      assert_empty cmd.heredocs, line
      assert_includes cmd.commands, %w[git push origin main], line
    end
    ['git commit -m "$(cat <<"EOF"', "git commit -m \"it's $(cat <<'EOF'"].each do |line|
      assert_equal ['EOF'], ShellCommand.new("#{line}\nFix it\nEOF\n)\"").heredocs.map(&:delim), line
    end
  end

  def test_git_invocation_without_a_subcommand_or_without_git
    with_repo do |dir|
      assert_equal [nil], invocations('git --version', dir).map { |f| f[:sub] }
      assert_empty invocations('ls -la && echo git push', dir)
    end
  end

def test_git_invocation_keeps_the_typed_segment_its_subcommand_and_the_shell_dir
  with_repo do |dir|
    Dir.mkdir(File.join(dir, 'sub'))
    found = invocations('cd sub && FOO=1 git -C .. checkout -b "a b"', dir).first
    assert_equal [["FOO=1", "git", "-C", "..", "checkout", "-b", %("a b")], 4, File.realpath(File.join(dir, 'sub')), File.realpath(dir)],
                 [found[:segment], found[:at], found[:cwd], found[:dir]]
    assert_nil invocations('git --version', dir).first[:at]
  end
end

def test_git_invocation_keeps_the_typed_alias_word_as_its_subcommand
  with_repo do |dir|
    found = invocations('git -c a.b=1 pu --dry-run', dir).first
    assert_equal ['push', %w[git -c a.b=1 pu --dry-run], 3], [found[:sub], found[:segment], found[:at]]
    found = invocations('git del austin/x', dir).last
    assert_equal [%w[git push -d origin austin/x], 1], [found[:segment], found[:at]]
  end
end

def test_git_invocation_hands_every_other_command_to_the_block
  with_repo do |dir|
    seen = []
    found = ShellCommand.new(%(nice rm -f x && cd #{dir} && git multi && bash -c "touch 'a b'")).git_invocations(dir: Dir.home) { |words, at| seen << [words, at] }
    assert_empty found
    real = File.realpath(dir)
    assert_equal [[%w[rm -f x], Dir.home], [%w[echo one], real], [%w[echo two], real], [['touch', 'a b'], real]], seen
  end
end

def test_git_invocation_hands_the_block_the_whole_segment_too
  seen = []
  ShellCommand.new(%(FOO="a b" nice -n 5 fgutils prs:submit)).git_invocations(dir: Dir.home) { |words, _, toks| seen << [words, toks] }
  assert_equal [[%w[fgutils prs:submit], ['FOO=a b', 'nice', '-n', '5', 'fgutils', 'prs:submit']]], seen
end

def test_git_invocation_says_whether_a_shell_got_in_between
  with_repo do |dir|
    assert_equal [false, false], [invocations('git push', dir).first[:nested], invocations('git pu', dir).first[:nested]]
    assert_equal [true], invocations('bash -c "git push"', dir).map { |i| i[:nested] }
    assert_equal [true, true], invocations('git del austin/x', dir).map { |i| i[:nested] }
  end
end
end
