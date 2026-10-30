# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/common/paths'

class PathsTest < Minitest::Test
  def with_link
    Dir.mktmpdir('paths') do |dir|
      real = File.realpath(dir)
      Dir.mkdir(File.join(real, 'target'))
      File.symlink(File.join(real, 'target'), File.join(real, 'link'))
      yield real
    end
  end

  def test_unknowable_path_is_nil
    assert_nil Paths.canonical('$HOME/x')
    assert_nil Paths.canonical('`pwd`/x')
    assert_nil Paths.canonical(nil)
  end

  def test_tilde_expands_to_home
    assert_equal File.realpath(Dir.home), Paths.canonical('~')
    assert_equal File.join(File.realpath(Dir.home), 'no-such-paths-test'), Paths.canonical('~/no-such-paths-test')
  end

  def test_tilde_user_stays_relative_to_the_base
    with_link do |dir|
      assert_equal File.join(dir, '~nobody-here/x'), Paths.canonical('~nobody-here/x', base: dir, walk: false)
    end
  end

  def test_relative_path_resolves_against_the_base
    with_link do |dir|
      assert_equal File.join(dir, 'target'), Paths.canonical('target', base: dir)
      assert_equal File.join(dir, 'target'), Paths.canonical('../target', base: File.join(dir, 'target'))
    end
  end

  def test_walk_resolves_the_deepest_existing_ancestor
    with_link do |dir|
      assert_equal File.join(dir, 'target/a/b'), Paths.canonical('link/a/b', base: dir)
    end
  end

  def test_without_walk_only_an_existing_path_is_resolved
    with_link do |dir|
      assert_equal File.join(dir, 'target'), Paths.canonical('link', base: dir, walk: false)
      assert_equal File.join(dir, 'link/a'), Paths.canonical('link/a', base: dir, walk: false)
    end
  end

  def test_locators_take_their_env_override
    {
      'AGENT_SKILLS_ROOT' => :agent_skills, 'RUBYCOMMON_ROOT' => :ruby_common, 'ZIAX_UTILS' => :ziax_utils
    }.each do |var, locator|
      old = ENV[var]
      ENV[var] = '/somewhere'
      assert_equal '/somewhere', Paths.public_send(locator)
      ENV.delete(var)
      assert Paths.public_send(locator).start_with?(Dir.home)
    ensure
      old ? ENV[var] = old : ENV.delete(var)
    end
  end

  def test_ziax_joins_under_the_checkouts
    assert_equal File.join(Dir.home, 'Projects/Java/Ziax'), Paths.ziax
    assert_equal File.join(Dir.home, 'Projects/Java/Ziax/cubecraft'), Paths.ziax('cubecraft')
  end
end
