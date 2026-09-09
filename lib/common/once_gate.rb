# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'

# A deliberation gate: the first time a caller presents some identity we record
# it and say "new"; present the same identity again and we say nothing is new.
# Lets a hook block once to force a re-read, then let the identical retry through.
class OnceGate
  DEFAULT_TTL = 24 * 60 * 60

  def initialize(dir:, ttl: DEFAULT_TTL, filename: 'pending.json')
    @dir = File.expand_path(dir.to_s)
    @path = File.join(@dir, filename)
    @ttl = ttl
  end

  # Identity is the content, deliberately not its position — an unrelated edit
  # that shifts a file must not revoke a confirmation the user already gave.
  def self.key(*parts)
    Digest::SHA256.hexdigest(parts.join("\x00"))[0, 32]
  end

  # Returns the subset of `keys` not seen before, having now recorded them.
  def claim(keys)
    state = load
    fresh = keys.reject { |k| state.key?(k) }
    return [] if fresh.empty?

    now = Time.now.to_f
    fresh.each { |k| state[k] = now }
    store(state)
    fresh
  end

  def load
    raw = JSON.parse(File.read(@path))
    return {} unless raw.is_a?(Hash)

    cutoff = Time.now.to_f - @ttl
    raw.select { |_, v| v.is_a?(Numeric) && v >= cutoff }
  rescue StandardError
    {}
  end

  def store(state)
    FileUtils.mkdir_p(@dir)
    tmp = "#{@path}.#{Process.pid}.tmp"
    File.write(tmp, JSON.generate(state))
    File.rename(tmp, @path)
  end
end
