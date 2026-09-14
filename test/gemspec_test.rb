# frozen_string_literal: true

require "minitest/autorun"

# 🔴 `lib/common/*.rb` required `net-ssh` and `webrick` and the gemspec declared neither. It only
# worked because both happened to be installed under ruby 3.0.0 — the moment the system moved to
# 3.4.10 the gem installed fine and then failed to load, and `require "common"` reported
# "cannot load such file -- common", naming the wrong file entirely. A two-line patch fixes today;
# this is what stops it coming back.
class GemspecTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def spec
    @spec ||= Gem::Specification.load(File.join(ROOT, "common.gemspec"))
  end

  def required_features
    Dir[File.join(ROOT, "lib", "**", "*.rb")].flat_map do |file|
      File.read(file).scan(/^\s*require ["']([a-z0-9_\/-]+)["']/).flatten
    end.uniq.reject { |feature| feature.start_with?("common") }
  end

  def test_every_gem_the_library_requires_is_declared
    declared = spec.dependencies.map(&:name)

    undeclared = required_features.filter_map do |feature|
      provider = begin
        Gem::Specification.find_by_path(feature)
      rescue StandardError
        nil
      end
      next if provider.nil? || provider.default_gem?
      next if declared.include?(provider.name)

      "#{feature} (from #{provider.name})"
    end

    assert_empty undeclared, "required but not declared in common.gemspec: #{undeclared.inspect}"
  end

  # The complement: a dependency nobody requires is noise a reader has to disprove.
  def test_the_scanner_actually_finds_the_requires
    assert_includes required_features, "net/ssh"
    assert_operator required_features.length, :>, 5
  end
end
