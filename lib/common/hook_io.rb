# frozen_string_literal: true

require 'json'

# Stdin/exit-code plumbing for a Claude Code PreToolUse hook.
#
# A hook that raises blocks every tool call it matches, so everything here fails
# open: a payload we cannot parse is a payload we let through.
module HookIO
  ALLOW = 0
  BLOCK = 2

  def self.payload(io = $stdin)
    parsed = JSON.parse(io.read)
    parsed.is_a?(Hash) ? parsed : nil
  rescue StandardError
    nil
  end

  def self.allow!
    exit ALLOW
  end

  # Stderr is what the model reads back as a system reminder, so the message is
  # the whole point of blocking — never block silently.
  def self.block!(message)
    warn message
    exit BLOCK
  end

  def self.tool_input(payload)
    value = payload['tool_input']
    value.is_a?(Hash) ? value : {}
  end
end
