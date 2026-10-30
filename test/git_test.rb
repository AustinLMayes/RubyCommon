# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'date'
require 'fileutils'
require_relative '../lib/common/git'

class GitTest < Minitest::Test
  class Refused < StandardError; end

  def setup
    @tmp = Dir.mktmpdir('git-test')
    @repo = File.join(@tmp, 'repo')
    sh(@tmp, 'git', 'init', '-q', '-b', 'main', @repo)
    sh(@repo, 'git', 'config', 'user.name', 'Test')
    sh(@repo, 'git', 'config', 'user.email', 'test@example.com')
    sh(@repo, 'git', 'config', 'alias.c', 'commit -s')
    commit_file('a.txt', "one\n", 'First')
  end

  def teardown
    Command.runner = nil
    FileUtils.rm_rf(@tmp)
  end

  def sh(dir, *cmd)
    system(*cmd, chdir: dir, out: File::NULL, err: File::NULL, exception: true)
  end

  def commit_file(name, body, subject)
    File.write(File.join(@repo, name), body)
    sh(@repo, 'git', 'add', name)
    sh(@repo, 'git', 'commit', '-q', '-m', subject)
  end

  def in_repo(&block)
    out = nil
    capture_subprocess_io { out = Dir.chdir(@repo, &block) }
    out
  end

  def test_run_returns_a_result_with_the_output
    result = Git.run(@repo, 'log', '-1', '--pretty=%s')

    assert result.ok?
    assert_equal "First\n", result.out
  end

  def test_run_with_no_dir_keeps_the_cwd
    assert_equal 'First', Dir.chdir(@repo) { Git.out(nil, 'log', '-1', '--pretty=%s') }
  end

  def test_config_overrides_go_in_front_of_the_subcommand
    assert_equal 'over', Git.out(@repo, 'config', '--get', 'probe.key', config: ['probe.key=over'])
  end

  def test_out_is_stripped_or_nil
    assert_equal 'First', Git.out(@repo, 'log', '-1', '--pretty=%s')
    assert_nil Git.out(@repo, 'rev-parse', '--verify', '-q', 'nope')
  end

  def test_out_keeps_the_bytes_when_asked
    commit_file('b.txt', "  indented\n\n", 'Second')
    assert_equal "  indented\n\n", Git.out(@repo, 'show', 'HEAD:b.txt', strip: false)
    assert_nil Git.out(@repo, 'show', 'HEAD:nope', strip: false)
  end

  def test_ok
    assert Git.ok?(@repo, 'rev-parse', 'HEAD')
    refute Git.ok?(@repo, 'rev-parse', '--verify', '-q', 'nope')
  end

  def test_run_bang_raises_the_full_stderr_by_default
    error = assert_raises(Git::Error) { Git.run!(@repo, 'checkout', 'nope') }

    assert_includes error.message, "pathspec 'nope'"
  end

  def test_run_bang_takes_the_callers_error_class_and_the_last_line
    error = assert_raises(Refused) do
      Git.run!(@repo, 'sh-not-a-command', error: Refused, message: :last_line)
    end

    refute_includes error.message, "\n"
    refute_empty error.message
  end

  def test_run_bang_names_the_command_when_git_says_nothing
    status = Struct.new(:exitstatus, :success?).new(5, false)
    Command.runner = ->(_argv, **) { Command::Result.new('', '', status, false) }

    error = assert_raises(Git::Error) { Git.run!(@repo, 'status') }
    assert_equal 'git status exited 5', error.message
  end

  def test_run_bang_returns_the_result_on_success
    assert_equal "First\n", Git.run!(@repo, 'log', '-1', '--pretty=%s').out
  end

  def test_a_missing_git_is_unavailable
    Command.runner = ->(_argv, **) { raise Command::Unavailable, 'git' }

    assert_raises(Command::Unavailable) { Git.run(@repo, 'status') }
  end

  def test_stream_inherits_stdio_and_returns_the_exit
    out, = capture_subprocess_io { assert Git.stream(@repo, 'log', '-1', '--pretty=%s') }

    assert_equal "First\n", out
    capture_subprocess_io { refute Git.stream(@repo, 'checkout', 'nope') }
  end

def test_capture_keeps_stdout_when_git_fails_like_a_backtick
  out, err = capture_subprocess_io { assert_equal "nope^\n", Dir.chdir(@repo) { Git.capture('rev-parse', 'nope^') } }

  assert_empty out
  assert_match 'nope^', err
end

def test_branch_lists
  assert_equal %w[production main master dev], Git.root_branches
  assert_equal %w[main dev production master staging], Git.base_branches
end

  def test_toplevel_git_dir_and_common_dir_in_a_linked_worktree
    tree = File.join(@tmp, 'tree')
    sh(@repo, 'git', 'worktree', 'add', '-q', '-b', 'side', tree)
    real_repo = File.realpath(@repo)

    assert_equal File.realpath(tree), Git.toplevel(dir: tree)
    assert_equal File.join(real_repo, '.git'), Git.common_dir(dir: tree)
    assert_equal File.join(real_repo, '.git', 'worktrees', 'tree'), Git.git_dir(dir: tree)
  end

  def test_repo_asks_git_so_a_linked_worktree_counts
    tree = File.join(@tmp, 'tree')
    sh(@repo, 'git', 'worktree', 'add', '-q', '-b', 'side', tree)

    assert Git.repo?(tree)
    assert Git.repo?(@repo)
    refute Git.repo?(@tmp)
    refute Git.repo?(File.join(@tmp, 'missing'))
  end

  def test_current_branch_with_a_dir
    assert_equal 'main', Git.current_branch(dir: @repo)
  end

  def test_current_branch_is_empty_when_detached
    sh(@repo, 'git', 'checkout', '-q', '--detach')

    assert_equal '', Git.current_branch(dir: @repo)
  end

  def test_current_branch_is_the_full_name_when_a_tag_shares_it
    sh(@repo, 'git', 'tag', 'main')

    assert_equal 'main', Git.current_branch(dir: @repo)
    assert_equal 'main', in_repo { Git.current_branch }
  end

  def test_current_branch_on_an_unborn_branch
    fresh = File.join(@tmp, 'fresh')
    sh(@tmp, 'git', 'init', '-q', '-b', 'trunk', fresh)

    assert_equal 'trunk', Git.current_branch(dir: fresh)
  end

  def test_remote_url_fetch_and_push
    sh(@repo, 'git', 'remote', 'add', 'origin', 'git@github.com:Owner/Repo.git')
    sh(@repo, 'git', 'remote', 'set-url', '--push', 'origin', 'https://github.com/Owner/Push.git')

    assert_equal 'git@github.com:Owner/Repo.git', Git.remote_url(dir: @repo)
    assert_equal 'https://github.com/Owner/Push.git', Git.remote_url(dir: @repo, push: true)
    assert_nil Git.remote_url('upstream', dir: @repo)
  end

  def test_default_branch_prefers_production_then_the_remote_head
    assert_nil Git.default_branch(dir: @repo)

    sh(@repo, 'git', 'update-ref', 'refs/remotes/origin/main', 'HEAD')
    sh(@repo, 'git', 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
    assert_equal 'main', Git.default_branch(dir: @repo)

    sh(@repo, 'git', 'update-ref', 'refs/remotes/origin/production', 'HEAD')
    assert_equal 'production', Git.default_branch(dir: @repo)
    assert_nil Git.default_branch('upstream', dir: @repo)
  end

  def test_slug_reads_ssh_and_https_remotes
    {
      'git@github.com:AustinLMayes/RubyCommon.git' => 'AustinLMayes/RubyCommon',
      'ssh://git@github.com/teamziax/cubecraft.git' => 'teamziax/cubecraft',
      'https://github.com/teamziax/rocket-data-platform' => 'teamziax/rocket-data-platform',
      'https://token@github.com/Owner/Repo.git/' => 'Owner/Repo',
      'git@github.com:Owner/dotted.name.git' => 'Owner/dotted.name'
    }.each { |url, slug| assert_equal slug, Git.slug(url), url }
    assert_nil Git.slug('')
    assert_nil Git.slug(nil)
  end

  def test_config_and_config_all
    sh(@repo, 'git', 'config', '--add', 'remote.origin.push', 'a')
    sh(@repo, 'git', 'config', '--add', 'remote.origin.push', 'b')

    assert_equal 'Test', Git.config('user.name', dir: @repo)
    assert_nil Git.config('no.such', dir: @repo)
    assert_equal %w[a b], Git.config_all('remote.origin.push', dir: @repo)
    assert_equal [], Git.config_all('no.such', dir: @repo)
  end

  def test_aliases_read_the_repo_and_the_overrides
    aliases = Git.aliases(dir: @repo, overrides: ['alias.zz=status'])

    assert_equal 'commit -s', aliases['c']
    assert_equal 'status', aliases['zz']
  end

  def test_my_commits_between_returns_every_commit
    sh(@repo, 'git', 'checkout', '-q', '-b', 'austin/x')
    commit_file('b.txt', "b\n", 'Second')
    commit_file('c.txt', "c\n", 'Third')
    shas = Git.out(@repo, 'log', '--reverse', '--pretty=%H', 'main..austin/x').split("\n")

    assert_equal shas, in_repo { Git.my_commits_between('main', 'austin/x', 'austin') }
    assert_equal shas, in_repo { Git.commits_between('main', 'austin/x') }
  end

  def test_lines_changed_needs_no_activesupport
    commit_file('a.txt', "one\ntwo\nthree\n", 'Grow')
    sha = Git.out(@repo, 'rev-parse', 'HEAD')

    refute ''.respond_to?(:blank?)
    assert_equal 2, in_repo { Git.lines_changed(sha) }
    assert_equal 0, in_repo { Git.lines_changed('0' * 40) }
  end

  def test_commit_message_and_last_commit_message
    sh(@repo, 'git', 'commit', '-q', '--allow-empty', '-m', 'Title', '-m', 'Body line')
    sha = Git.out(@repo, 'rev-parse', 'HEAD')

    assert_equal({ title: 'Title', body: "\nBody line" }, in_repo { Git.commit_message(sha) })
    assert_equal 'Title', in_repo { Git.last_commit_message }[:title]
  end

  def test_last_n_commits
    commit_file('b.txt', "b\n", 'Second')
    first, second = Git.out(@repo, 'log', '--reverse', '--pretty=%H').split("\n")

    assert_equal [second, first], in_repo { Git.last_n_commits(2) }
  end

  def test_uncommitted_lines
    assert_equal 0, in_repo { Git.uncommitted_lines }
    File.write(File.join(@repo, 'a.txt'), "one\ntwo\n")
    assert_equal 1, in_repo { Git.uncommitted_lines }
    assert in_repo { Git.has_uncommitted_changes? }
  end

  def test_branch_exists
    assert in_repo { Git.branch_exists('main') }
    refute in_repo { Git.branch_exists('nope') }
  end

  def test_find_branches_drops_markers_and_remotes
    sh(@repo, 'git', 'branch', 'austin/a')
    sh(@repo, 'git', 'worktree', 'add', '-q', '-b', 'austin/b', File.join(@tmp, 'b'))
    sh(@repo, 'git', 'update-ref', 'refs/remotes/origin/austin/c', 'HEAD')

    assert_equal %w[austin/a austin/b], in_repo { Git.find_branches('austin') }
  end

  def test_act_on_branches_checks_each_out_and_yields_it
    sh(@repo, 'git', 'branch', 'one')
    sh(@repo, 'git', 'branch', 'two')
    seen = []
    in_repo { Git.act_on_branches('one', 'two') { |b| seen << [b, Git.current_branch] } }

    assert_equal [%w[one one], %w[two two]], seen
  end

  def test_branch_is_on_remote
    sh(@repo, 'git', 'update-ref', 'refs/remotes/origin/main', 'HEAD')

    assert in_repo { Git.branch_is_on_remote?('main') }
    refute in_repo { Git.branch_is_on_remote?('other') }
  end

  def test_repo_name_helpers_keep_their_ssh_output
    sh(@repo, 'git', 'remote', 'add', 'origin', 'git@github.com:Owner/Repo.git')

    assert_equal %w[Owner Owner/Repo], in_repo { [Git.repo_org, Git.repo_name_with_org] }
  end
end
