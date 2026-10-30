# frozen_string_literal: true

require "shellwords"
require_relative "command"

module Ssh
  extend self

  HOST_KEY_FAILED = "Host key verification failed"

  def run(host, cmd, batch: true, connect_timeout: 10, via: nil, identity: nil, **opts)
    Command.run("ssh", *options(batch: batch, connect_timeout: connect_timeout, via: via, identity: identity), target(host), remote(cmd), **opts)
  end

  def options(batch: true, connect_timeout: 10, via: nil, identity: nil)
    opts = identity ? ["-i", identity] : []
    opts.push("-o", "BatchMode=yes") if batch
    opts.push("-o", "ConnectTimeout=#{connect_timeout}") if connect_timeout
    opts.push("-J", target(via)) if via
    opts
  end

  def target(host) = host.include?("@") ? host : "root@#{host}"

  def remote(cmd) = cmd.is_a?(Array) ? cmd.map(&:to_s).shelljoin : cmd

  def unknown_host?(result) = result.err.include?(HOST_KEY_FAILED)

  def unknown_host_message(host)
    "#{host} isn't in known_hosts. Ask for `! ssh #{target(host)} exit` once to bless it (ziax-ssh)"
  end

  def without_banner(text) = text.lines.grep_v(/\A\*\*/).join.strip
end
