# frozen_string_literal: true

require_relative 'usage'

module Cli
  module Defaults
    class Refused < StandardError; end

    FILLABLE = %i[value enum number positional].freeze

    def self.check!(name, usage, words, defaults)
      return if defaults.empty?

      parsed = Usage.parse(usage, words: words)
      defaults.each { |param, value| one!(name, parsed, param, value) }
    end

    def self.one!(name, parsed, param_name, value)
      param = parsed.params.find { |p| p.name == param_name }
      raise Refused, "#{name}: no #{param_name.inspect} in its usage to default" unless param
      unless FILLABLE.include?(param.kind)
        raise Refused, "#{name}: #{param_name} is a #{param.kind}, which cannot carry a default"
      end
      if param.values.any? && !param.values.include?(value)
        raise Refused, "#{name}: #{param_name} default #{value.inspect} is not one of " \
                       "#{param.values.join(', ')}"
      end
      return unless param.kind == :positional

      positional!(name, parsed, param)
    end

    def self.positional!(name, parsed, param)
      unless parsed.params.last == param && parsed.literals.empty?
        raise Refused, "#{name}: #{param.name} is not the last thing its usage names, so a " \
                       "default would land in another argument's place"
      end
      return unless parsed.params.any? { |p| p.kind == :prose || p.repeated }

      raise Refused, "#{name}: #{param.name} sits beside trailing prose, which cannot be counted"
    end

    # Positionals before flags: handlers `argv.shift` their positional before `take_options`,
    # so an appended flag ahead of a defaulted positional would be read as that positional.
    def self.fill(command, words, argv)
      declared = command.defaults
      return argv if declared.nil? || declared.empty?

      parsed = Usage.parse(command.usage, words: words)
      missing = declared.filter_map do |param_name, value|
        param = parsed.params.find { |p| p.name == param_name }
        [param, value] if param && !filled_in?(parsed, param, argv)
      end
      sunk, flags = missing.partition { |param, _| param.kind == :positional }
      argv + sunk.map { |_, value| value } +
        flags.flat_map { |param, value| ["--#{param.name}", value] }
    end

    def self.filled_in?(parsed, param, argv)
      unless param.kind == :positional
        return argv.any? { |t| t == "--#{param.name}" || t.start_with?("--#{param.name}=") }
      end

      slot = parsed.params.select { |p| p.kind == :positional }.index(param)
      positionals(parsed, argv) > slot
    end

    def self.positionals(parsed, argv)
      valued = parsed.params.flat_map do |p|
        case p.kind
        when :one_of then p.values
        when :value, :enum, :number, :body, :text then [p.name]
        else []
        end
      end
      count = 0
      index = 0
      while index < argv.length
        token = argv[index]
        if token.to_s.start_with?('--')
          index += valued.include?(token.sub(/\A--/, '')) ? 2 : 1
        else
          count += 1
          index += 1
        end
      end
      count
    end

    def self.spell(command, words)
      declared = command.defaults
      return nil if declared.nil? || declared.empty?

      parsed = Usage.parse(command.usage, words: words)
      declared.map do |param_name, value|
        param = parsed.params.find { |p| p.name == param_name }
        param&.kind == :positional ? "<#{param_name}> #{value}" : "--#{param_name} #{value}"
      end.join('  ')
    end
  end
end
