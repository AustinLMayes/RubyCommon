# frozen_string_literal: true

require_relative '../command'

module Cli
  HELP = %w[-h --help].freeze

  def self.help?(argv) = argv.any? { |a| HELP.include?(a) }

  def self.usage!(usage, code = OK, out: code == OK ? $stdout : $stderr)
    out.puts usage
    exit code
  end

  def self.abort!(message, code = FAILED)
    warn message
    exit code
  end

  def self.option!(argv, flag)
    return unless (i = argv.index(flag))

    value = argv.delete_at(i + 1).to_s
    argv.delete_at(i)
    value
  end

  def self.out!(result, what, ok: [0])
    return result.out if ok.include?(result.status&.exitstatus)

    abort!("#{what}: #{result.err.strip}")
  end

  def self.run!(*argv, ok: [0], **opts)
    out!(::Command.run(*argv, **opts), argv.join(' '), ok: ok)
  end
end
