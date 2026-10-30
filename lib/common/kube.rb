# frozen_string_literal: true

require "json"
require_relative "command"

module Kube
  extend self

  class Error < StandardError
    attr_reader :result

    def initialize(message, result = nil)
      super(message)
      @result = result
    end
  end

  def run(*args, tool: :oc, context: nil, namespace: nil, request_timeout: nil, **opts)
    Command.run(*argv(*args, tool: tool, context: context, namespace: namespace, request_timeout: request_timeout), **opts)
  end

  def json(*args, **kw)
    result = run(*args, "-o", "json", **kw)
    raise Error.new("#{argv(*args, **kw.slice(*FLAGS)).join(" ")}: #{result.err.strip}", result) unless result.ok?

    JSON.parse(result.out)
  end

  def argv(*args, tool: :oc, context: nil, namespace: nil, request_timeout: nil)
    [tool.to_s,
     *(["--context", context] if context),
     *(["-n", namespace] if namespace),
     *("--request-timeout=#{request_timeout}" if request_timeout),
     *args]
  end

  FLAGS = %i[tool context namespace request_timeout].freeze
end
