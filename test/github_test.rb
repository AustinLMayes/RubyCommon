# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/common/github'

class GitHubTest < Minitest::Test
  def setup
    @calls = []
    @answers = []
    GitHub.instance_variable_set(:@open_pr_numbers, nil)
    GitHub.instance_variable_set(:@github_username, 'me')
  end

  def teardown
    Command.runner = nil
    GitHub.instance_variable_set(:@github_username, nil)
    GitHub.instance_variable_set(:@open_pr_numbers, nil)
  end

  def status(ok)
    Struct.new(:ok) { def success? = ok; def exitstatus = ok ? 0 : 1 }.new(ok)
  end

  def answer(*outs, ok: true)
    @answers.concat(outs.map { |out| Command::Result.new(out, '', status(ok), false) })
    Command.runner = lambda do |argv, **opts|
      @calls << [argv, opts]
      @answers.shift || Command::Result.new('', '', status(true), false)
    end
  end

  def quietly(&block)
    out = nil
    capture_io { out = block.call }
    out
  end

  def test_gh_runs_gh_with_argv_and_inherits_stderr_by_default
    answer('hi')
    result = GitHub.gh('api', 'user')
    assert_equal 'hi', result.out
    assert_equal [%w[gh api user], :inherit], [@calls[0][0], @calls[0][1][:stderr]]
  end

  def test_gh_parses_json_when_asked
    answer('[{"slug":"dev"}]')
    assert_equal [{ 'slug' => 'dev' }], GitHub.gh('api', 'orgs/x/teams', json: true)
  end

  def test_gh_missing_is_a_failed_result_like_the_shell_gave
    Command.runner = ->(_argv, **) { raise Command::Unavailable, 'No such file or directory - gh' }
    result = GitHub.gh('api', 'user')
    refute result.ok?
    assert_equal '', result.out
  end

  def test_gh_missing_raises_when_not_failing_open
    Command.runner = ->(_argv, **) { raise Command::Unavailable, 'No such file or directory - gh' }
    error = assert_raises(Command::Unavailable) { GitHub.gh('api', 'user', fail_open: false) }
    assert_equal 'No such file or directory - gh', error.message
  end

def test_stream_runs_gh_on_the_terminal_and_returns_its_exit
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'gh'), "#!/bin/sh\necho \"$@\"\nexit 3\n")
    File.chmod(0o755, File.join(dir, 'gh'))
    path = ENV['PATH']
    ENV['PATH'] = dir
    out, = capture_subprocess_io { refute GitHub.stream('run', 'cancel', '7') }
    assert_equal "run cancel 7\n", out
    ENV['PATH'] = File::NULL
    assert_nil GitHub.stream('api', 'user')
  ensure
    ENV['PATH'] = path
  end
end

  def test_make_pr_passes_fields_as_argv_without_shell_quoting
    answer('{"number": 42}')
    num = quietly { GitHub.make_pr("it's done", body: 'a "b" $c', base: 'main', head: 'austin/x', draft: true, repo: 'o/r') }
    assert_equal '42', num
    argv, opts = @calls[0]
    assert_equal ['gh', 'api', 'repos/o/r/pulls', '-X', 'POST', '-f', "title=it's done", '-f', 'head=austin/x',
                  '-f', 'base=main', '-F', 'draft=true', '-f', 'body=a "b" $c'], argv
    assert_equal :merge, opts[:stderr]
  end

  def test_make_pr_failure_exits_with_the_output
    answer('HTTP 422: head invalid', ok: false)
    out, = capture_io do
      assert_raises(SystemExit) { GitHub.make_pr('t', head: 'h', repo: 'o/r') }
    end
    assert_includes out, 'Failed to create PR: HTTP 422: head invalid'
  end

  def test_get_pr_number_asks_the_given_repo_and_discards_stderr
    answer('[{"number": 7, "user": {"login": "me"}}]')
    assert_equal '7', GitHub.get_pr_number('austin/x', repo: 'o/r')
    argv, opts = @calls[0]
    assert_equal ['gh', 'api', 'repos/o/r/pulls?head=o:austin/x&state=open&per_page=100'], argv
    assert_equal :discard, opts[:stderr]
  end

  def test_get_pr_number_filters_to_mine_unless_told_not_to
    answer('[{"number": 7, "user": {"login": "someone"}}]', '[{"number": 7, "user": {"login": "someone"}}]')
    assert_nil GitHub.get_pr_number('b', repo: 'o/r')
    assert_equal '7', GitHub.get_pr_number('b', only_mine: false, repo: 'o/r')
  end

  def test_get_pr_number_is_nil_on_no_output
    answer('')
    assert_nil GitHub.get_pr_number('b', repo: 'o/r')
  end

  def test_open_pr_number_caches_per_repo_and_branch_until_forgotten
    answer('[{"number": 1}]', '[{"number": 2}]', '[{"number": 3}]')
    assert_equal 1, GitHub.open_pr_number('b', repo: 'o/r')
    assert_equal 1, GitHub.open_pr_number('b', repo: 'o/r')
    assert_equal 2, GitHub.open_pr_number('b', repo: 'o/other')
    GitHub.forget_pr_number('b', repo: 'o/r')
    assert_equal 3, GitHub.open_pr_number('b', repo: 'o/r')
    assert_equal 3, @calls.length
  end

  def test_change_pr_title_looks_up_and_patches_the_same_repo
    answer('[{"number": 9}]', '{}')
    quietly { GitHub.change_pr_title('b', 'New', repo: 'o/r') }
    assert_equal ['gh', 'api', 'repos/o/r/pulls/9', '-X', 'PATCH', '-f', 'title=New'], @calls[1][0]
  end

  def test_change_pr_body_without_a_pr_exits
    answer('[]')
    out, = capture_io { assert_raises(SystemExit) { GitHub.change_pr_body('b', 'x', repo: 'o/r') } }
    assert_includes out, 'No PR found for b'
  end

  def test_change_pr_base_failure_exits_with_the_output
    answer('[{"number": 9}]', 'HTTP 404')
    @answers[1] = Command::Result.new('HTTP 404', '', status(false), false)
    out, = capture_io { assert_raises(SystemExit) { GitHub.change_pr_base('b', 'main', repo: 'o/r') } }
    assert_includes out, 'Failed to change PR base: HTTP 404'
  end

  def test_pull_request_states_merges_stderr_and_keeps_partial_answers
    answer('{"data": {"repository": {"pr1": {"number": 1}, "pr2": null}}}', ok: false)
    assert_equal({ 1 => { 'number' => 1 } }, GitHub.pull_request_states('o/r', [1, 2]))
    assert_equal :merge, @calls[0][1][:stderr]
  end

  def test_pull_request_states_raises_on_unparsable_output
    answer('gh: not logged in', ok: false)
    assert_raises(GitHub::Error) { GitHub.pull_request_states('o/r', [1]) }
  end

  def test_remote_sha_and_push_sha_work_on_a_given_dir
    Dir.mktmpdir('github-test') do |tmp|
      remote = File.join(tmp, 'remote.git')
      repo = File.join(tmp, 'repo')
      system('git', 'init', '-q', '--bare', remote, exception: true)
      system('git', 'init', '-q', '-b', 'main', repo, exception: true)
      system('git', '-C', repo, 'remote', 'add', 'origin', remote, exception: true)
      system('git', '-C', repo, '-c', 'user.name=T', '-c', 'user.email=t@e', 'commit', '-q', '--allow-empty', '-m', 'x',
             exception: true)
      sha = `git -C #{repo} rev-parse HEAD`.strip

      assert_nil GitHub.remote_sha('topic', dir: repo)
      assert capture_subprocess_io { assert GitHub.push_sha(sha, 'topic', dir: repo) }
      assert_equal sha, GitHub.remote_sha('topic', dir: repo)
    end
  end

  def test_push_sha_does_nothing_under_dont_push
    $dont_push = true
    Command.runner = ->(*) { flunk 'pushed' }
    assert GitHub.push_sha('abc', 'b')
  ensure
    $dont_push = nil
  end
end
