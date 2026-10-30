# frozen_string_literal: true

module PushPolicy
  PERSONAL = %r{github\.com[:/]+AustinLMayes/}i.freeze

  def self.personal?(url) = url.to_s.match?(PERSONAL)

  def self.allowed?(url, branch, default_branch)
    return true if branch.start_with?('austin/')

    personal?(url) && !default_branch.to_s.empty? && branch == default_branch
  end
end
