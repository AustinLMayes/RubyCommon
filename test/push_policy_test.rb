# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/common/push_policy'

class PushPolicyTest < Minitest::Test
  PERSONAL = 'git@github.com:AustinLMayes/GitUtils.git'
  SHARED = 'git@github.com:teamziax/cubecraft.git'

  def test_austin_branch_is_allowed_anywhere
    assert PushPolicy.allowed?(SHARED, 'austin/x', 'master')
    assert PushPolicy.allowed?('/tmp/mirror', 'austin/s/y', nil)
  end

  def test_default_branch_is_allowed_only_in_a_personal_repo
    assert PushPolicy.allowed?(PERSONAL, 'master', 'master')
    assert PushPolicy.allowed?('https://github.com/AustinLMayes/ax', 'main', 'main')
    refute PushPolicy.allowed?(SHARED, 'master', 'master')
  end

  def test_other_branches_of_a_personal_repo_are_refused
    refute PushPolicy.allowed?(PERSONAL, 'feature', 'master')
    refute PushPolicy.allowed?(PERSONAL, 'master', nil)
    refute PushPolicy.allowed?(PERSONAL, '', '')
  end

  def test_austin_must_be_the_branch_prefix
    refute PushPolicy.allowed?(SHARED, 'stacks/austin/x', 'master')
    refute PushPolicy.allowed?(SHARED, 'refs/heads/austin/x', 'master')
  end

  def test_personal_matches_ssh_https_and_doubled_separators
    assert PushPolicy.personal?(PERSONAL)
    assert PushPolicy.personal?('https://GitHub.com/austinlmayes/ax.git')
    assert PushPolicy.personal?('ssh://git@github.com//AustinLMayes/ax')
    refute PushPolicy.personal?(SHARED)
    refute PushPolicy.personal?('git@github.com:AustinLMayesFork/ax.git')
    refute PushPolicy.personal?(nil)
  end
end
