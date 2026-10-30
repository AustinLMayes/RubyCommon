# frozen_string_literal: true

require 'json'

# Stdin/exit-code plumbing for a Claude Code hook.
#
# A hook that raises blocks every tool call it matches, so payload parsing fails
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

  def self.guard(name, on_error: :open, what: 'this call', io: $stdin)
    payload = payload(io)
    if payload.nil?
      why = 'the tool payload did not parse as JSON'
      on_error == :closed ? fail_closed!(name, why) : fail_open!(name, why, what)
    end
    yield payload
    pass!
  rescue StandardError, LoadError => e
    why = "crashed (#{e.class}: #{e.message})"
    on_error == :closed ? fail_closed!(name, why) : fail_open!(name, why, what)
  end

  def self.pass!
    exit ALLOW
  end

  def self.allow!(guard = nil, reason = nil)
    decide!('allow', guard, reason) if guard
    exit ALLOW
  end

  def self.ask!(guard, reason)
    decide!('ask', guard, reason)
  end

  # Stderr is what the model reads back as a system reminder, so the message is
  # the whole point of blocking — never block silently.
  def self.block!(guard_or_message, message = nil)
    if message
      warn "BLOCKED by #{guard_or_message} hook:#{sep(message)}#{message}"
    else
      warn guard_or_message
    end
    exit BLOCK
  end

  def self.warn!(guard, note, event: nil)
    text = "#{guard}:#{sep(note)}#{note}"
    out = { systemMessage: text }
    out[:hookSpecificOutput] = { hookEventName: event, additionalContext: text } if event
    puts JSON.generate(out)
    exit ALLOW
  end

  def self.fail_open!(guard, why, what = 'this call')
    warn!(guard, "#{why}, so #{what} went unchecked")
  end

  def self.fail_closed!(guard, why)
    block!(guard, why)
  end

  def self.command(payload)
    tool_input(payload)['command'].to_s
  end

  def self.cwd(payload)
    dir = payload['cwd'].to_s
    dir.empty? ? Dir.pwd : dir
  end

  def self.unattended?
    !ENV['CLAUDE_JOB_DIR'].to_s.empty?
  end

  def self.sep(text)
    text.start_with?("\n") ? '' : ' '
  end
  private_class_method :sep

  def self.decide!(decision, guard, reason)
    puts JSON.generate(hookSpecificOutput: {
                         hookEventName: 'PreToolUse', permissionDecision: decision,
                         permissionDecisionReason: "#{guard}: #{reason}"
                       })
    exit ALLOW
  end
  private_class_method :decide!

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
