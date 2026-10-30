# frozen_string_literal: true

require "shellwords"
require_relative "command"

module Secrets
  extend self

  def extra(name)
    value = ENV[name].to_s
    value = extra_env[name].to_s if value.empty?
    value unless value.empty?
  end

  def extra_env
    path = File.join(Dir.home, ".extra")
    result = Command.run("zsh", "-f", "-c", "source #{path.shellescape} >/dev/null 2>&1; env -0", stderr: :discard)
    result.out.split("\0").to_h { |pair| pair.split("=", 2) }
  rescue Command::Unavailable
    {}
  end
end
