# frozen_string_literal: true

require "json"
require "uri"
require_relative "command"
require_relative "secrets"

module Bugsnag
  extend self

  PROJECT = "5686a91877656272b700006e"
  API = "https://api.bugsnag.com"
  TRIES = 6

  class Error < StandardError; end

  Response = Struct.new(:code, :body, :sent) do
    def ok? = sent && code.start_with?("2")
    def json = JSON.parse(body)
  end

  def token = Secrets.extra("BUGSNAG_API_KEY")

  def url(path, params = [])
    params.empty? ? "#{API}#{path}" : "#{API}#{path}?#{URI.encode_www_form(params)}"
  end

  def get(path, params = [], tries: TRIES, pause: true)
    key = token or raise Error, "no BUGSNAG_API_KEY in the env or ~/.extra"
    tries.times do |attempt|
      result = Command.run("curl", "-s", "-w", "\n%{http_code}", "-H", "Authorization: token #{key}",
                           "-H", "X-Version: 2", url(path, params))
      body, _, code = result.out.rpartition("\n")
      return Response.new(code, body, result.ok?) unless code == "429" || body.include?("rate limit exceeded")

      sleep(2**attempt) if pause
    end
    raise Error, "bugsnag #{path}: still rate limited after #{tries} tries"
  end
end
