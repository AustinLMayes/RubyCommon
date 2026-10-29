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

  def self.before_after(tool_name, input, path)
    old_full = File.exist?(path) ? File.read(path, encoding: 'UTF-8', invalid: :replace, undef: :replace) : ''

    case tool_name
    when 'Write'
      [old_full, input['content'].to_s]
    when 'Edit'
      [old_full, apply_edit(old_full, input)]
    when 'MultiEdit'
      edits = input['edits']
      [old_full, (edits.is_a?(Array) ? edits : []).reduce(old_full) { |text, edit| apply_edit(text, edit) }]
    else
      [old_full, old_full]
    end
  end

  def self.apply_edit(text, edit)
    from = edit['old_string'].to_s
    to = edit['new_string'].to_s
    edit['replace_all'] ? text.gsub(from, to) : text.sub(from, to)
  end
  private_class_method :apply_edit
end
