# frozen_string_literal: true

module Cli
  class Usage
    Unparsable = Class.new(StandardError)

    Param = Struct.new(:name, :kind, :required, :values, :repeated, :one_of, :default,
                       keyword_init: true) do
      def initialize(*) = super.tap { self.values ||= [] }
    end

    REST = '[--<arg> <value>]...'
    NUMERIC = /\A(limit|ceiling|priority|index|number|pr|value)\z/.freeze

    attr_reader :params, :literals

    def self.parse(usage, words:)
      program = Regexp.escape(usage.to_s.strip[/\A\S+/].to_s)
      forms = usage.split(/\s+\|\s+(?=#{program}\s)/)
      parsed = new(tail(forms.first, words, program), usage)
      parsed.absorb_alternates(forms.drop(1).map { |f| tail(f, words, program) })
      parsed
    end

    def self.tail(form, words, program)
      form.to_s.strip.sub(/\A#{program}\s+/, '').split(/\s+/, words + 1)[words].to_s
    end

    def initialize(tail, usage = nil)
      @params = []
      @literals = []
      @usage = usage
      consume(queue(tail))
    end

    def absorb_alternates(others)
      @literals.concat(others.map(&:strip).select { |o| o.match?(/\A[a-z][a-z0-9-]*\z/) })
    end

    private

    def consume(tokens)
      until tokens.empty?
        token = tokens.shift
        case token
        when /\A\[(.+)\]\z/m then optional(Regexp.last_match(1))
        when /\A\((.+)\)\z/m then exclusive(Regexp.last_match(1))
        else absorb(token, tokens, required: true)
        end
      end
    end

    def optional(inner)
      nested = queue(inner)
      until nested.empty?
        token = nested.shift
        absorb(token, nested, required: false)
      end
    end

    def exclusive(inner)
      group = inner.split(/\s*\|\s*/).map(&:strip)
      names = group.filter_map { |g| g[/\A--([a-z][a-z-]*)/, 1] }
      raise Unparsable, "cannot read choice #{inner.inspect}" if names.empty?

      @params << Param.new(name: names.join('-or-'), kind: :one_of, required: true,
                           values: names, one_of: names)
    end

    def absorb(token, tokens, required:)
      if token == REST
        @params << Param.new(name: 'rest', kind: :rest, required: false, repeated: true)
        return
      end

      case token
      when /\A--([a-z][a-z-]*)\z/ then flag(Regexp.last_match(1), tokens, required)
      when /\A--([a-z][a-z-]*)=(.+)\z/m then @params << valued(Regexp.last_match(1), Regexp.last_match(2), required)
      when /\A<([a-z][a-z0-9-]*)(\.\.\.)?>\z/
        @params << Param.new(name: Regexp.last_match(1), kind: :positional, required: required,
                             repeated: !Regexp.last_match(2).nil?)
      when /\A([a-z][a-z0-9-]*)\.\.\.\z/
        @params << Param.new(name: Regexp.last_match(1), kind: :prose, required: required,
                             repeated: true)
      when /\A[a-z][a-z0-9-]*\z/ then @literals << token
      when /\A<[^>]+>\z/, /\A<[^>]+>[^\s]*<[^>]+>\z/
        @params << Param.new(name: token.delete('<>').gsub(/[^a-z0-9]+/i, '-').downcase,
                             kind: :positional, required: required)
      else
        raise Unparsable, "cannot read #{token.inspect} in #{@usage.inspect}"
      end
    end

    def flag(name, tokens, required)
      return inline_choice(name, tokens) if tokens.first == '|'

      value = tokens.first
      if value.nil? || value.start_with?('--', '[', '(')
        @params << Param.new(name: name, kind: :flag, required: false)
        return
      end

      tokens.shift
      return inline_choice(name, tokens) if tokens.first == '|'

      @params << valued(name, value, required)
    end

    def inline_choice(first, tokens)
      names = [first]
      while tokens.first == '|'
        tokens.shift
        flag = tokens.shift.to_s[/\A--([a-z][a-z-]*)/, 1]
        break unless flag

        names << flag
        tokens.shift if tokens.first && !tokens.first.start_with?('--', '[', '(', '|')
      end
      @params << Param.new(name: names.join('-or-'), kind: :one_of, required: true,
                           values: names, one_of: names)
    end

    def valued(name, value, required)
      clean = value.delete('"')
      values = clean.include?('|') && !clean.include?('<') ? clean.split('|') : []
      kind = if %w[body-file prompt-file].include?(name) then :body
             elsif name == 'comments' then :text
             elsif values.any? then :enum
             elsif name.match?(NUMERIC) then :number
             else :value
             end
      Param.new(name: name, kind: kind, required: required, values: values)
    end

    def queue(tail)
      out = []
      buffer = +''
      depth = 0
      quote = false
      tail.to_s.each_char do |c|
        case c
        when '[', '(' then depth += 1
        when ']', ')' then depth -= 1
        when '"' then quote = !quote
        end
        if c == ' ' && depth.zero? && !quote
          out << buffer unless buffer.empty?
          buffer = +''
        else
          buffer << c
        end
      end
      out << buffer unless buffer.empty?
      out
    end
  end
end
