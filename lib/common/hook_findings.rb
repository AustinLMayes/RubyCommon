# frozen_string_literal: true

require_relative 'hook_io'
require_relative 'once_gate'

module HookFindings
  CAP = 8

  Finding = Struct.new(:mode, :name, :say, :text, :never, :line, :side, :path, :identity, keyword_init: true) do
    def describe
      at = line ? "#{side == :removed ? 'removed line' : 'line'} #{line} " : ''
      "#{at}#{say}:\n      #{text[0, 140]}"
    end
  end

  def self.claim(gate, findings, session:, path:)
    keyed = findings.select { |f| f.mode == :once }
                    .to_h { |f| [OnceGate.key(session.to_s, f.path || path, f.name, f.identity || f.text), f] }
    gate.claim(keyed.keys).map { |k| keyed[k] }
  rescue StandardError
    []
  end

  def self.finish!(guard, findings, gate:, session:, path:, lead:, retry_note:, cap: CAP)
    unconfirmed = claim(gate, findings, session: session, path: path)
    stopping = findings.select { |f| f.mode == :block } + unconfirmed
    if stopping.empty?
      warns = findings.select { |f| f.mode == :warn }
      HookIO.pass! if warns.empty?
      HookIO.warn!(guard, "#{path} #{warns.map(&:describe).join('; ')}")
    end

    shown = cap ? stopping.first(cap) : stopping
    more = stopping.length > shown.length ? "\n  … and #{stopping.length - shown.length} more" : ''
    note = stopping.filter_map(&:never).uniq
    note << retry_note if unconfirmed.any?
    HookIO.block!(guard, "#{lead}\n\n#{shown.map { |f| "  • #{f.describe}" }.join("\n")}#{more}\n\n#{note.join(' ')}")
  end
end
