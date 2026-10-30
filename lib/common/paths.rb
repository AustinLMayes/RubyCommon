# frozen_string_literal: true

module Paths
  UNKNOWABLE = /[$`]/.freeze

  def self.canonical(path, base: nil, walk: true)
    return nil if path.nil? || path.match?(UNKNOWABLE)

    path = "./#{path}" if path.match?(%r{\A~[^/]})
    full = File.expand_path(path, base)
    return File.exist?(full) ? File.realpath(full) : full unless walk

    head = full
    tail = []
    until File.exist?(head) || head == '/'
      tail.unshift(File.basename(head))
      head = File.dirname(head)
    end
    File.join(File.realpath(head), *tail)
  end

  def self.agent_skills
    ENV['AGENT_SKILLS_ROOT'] || File.join(Dir.home, 'Projects/agent-skills')
  end

  def self.ruby_common
    ENV['RUBYCOMMON_ROOT'] || File.join(Dir.home, 'Projects/Ruby/RubyCommon')
  end

  def self.ziax_utils
    ENV['ZIAX_UTILS'] || File.join(Dir.home, 'Projects/Ruby/ZiaxUtils')
  end

  def self.ziax(*parts)
    File.join(Dir.home, 'Projects/Java/Ziax', *parts)
  end
end
