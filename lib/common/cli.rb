# frozen_string_literal: true

require_relative 'cli/usage'
require_relative 'cli/defaults'
require_relative 'cli/args'
require_relative 'cli/help'

module Cli
  OK = 0
  FINDINGS = 1
  USAGE = 2
  FAILED = 2

  NameCollision = Class.new(StandardError)

  class Die < StandardError
    attr_reader :code

    def initialize(message, code)
      super(message)
      @code = code
    end
  end

  Command = Struct.new(:label, :summary, :usage, :danger, :after, :defaults, :handler,
                       keyword_init: true)

  def self.die!(message, code = FAILED)
    raise Die.new(message, code)
  end

  def self.main(program, argv = ARGV)
    exit(Integer(program.new.run(argv)))
  end

  module Program
    include Args
    include Help

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def program(name = nil)
        return @program = name if name

        @program || File.basename($PROGRAM_NAME)
      end

      def banner(text = nil)
        text ? @banner = text : @banner
      end

      def usage_status(code = nil)
        code ? @usage_status = code : (@usage_status || USAGE)
      end

      def on_error(*classes, &handler)
        error_handlers << [classes, handler]
      end

      def error_handlers
        @error_handlers ||= []
      end

      def domains
        @domains ||= {}
      end

      def root_verbs
        @root_verbs ||= {}
      end

      def registry
        domains.merge(root_verbs)
      end

      def domain(name, summary)
        raise NameCollision, "#{name} is already a root verb" if root_verbs.key?(name)
        raise NameCollision, "domain #{name} is already registered" if domains.key?(name)

        domains[name] = { summary: summary, verbs: {} }
      end

      def verb(domain_name, verb_name, label:, summary:, usage:, danger: false, after: nil,
               defaults: {}, &handler)
        domain = domains[domain_name]
        raise NameCollision, "no domain #{domain_name.inspect} to hang #{verb_name.inspect} on" unless domain
        raise NameCollision, "#{domain_name} #{verb_name} is already registered" if domain[:verbs].key?(verb_name)

        domain[:verbs][verb_name] = command("#{program} #{domain_name} #{verb_name}", domain_name,
                                            label, summary, usage, danger, after, defaults, handler)
      end

      def root(verb_name, label:, summary:, usage:, danger: false, after: nil, defaults: {},
               &handler)
        raise NameCollision, "#{verb_name} is already a domain" if domains.key?(verb_name)
        raise NameCollision, "root verb #{verb_name} is already registered" if root_verbs.key?(verb_name)

        root_verbs[verb_name] = command("#{program} #{verb_name}", nil,
                                        label, summary, usage, danger, after, defaults, handler)
      end

      def words_for(domain_name) = domain_name ? 2 : 1

      private

      def command(name, domain_name, label, summary, usage, danger, after, defaults, handler)
        defaults = defaults.transform_keys(&:to_s).transform_values(&:to_s).freeze
        Defaults.check!(name, usage, words_for(domain_name), defaults)
        Command.new(label: label, summary: summary, usage: usage, danger: danger, after: after,
                    defaults: defaults, handler: handler)
      end
    end

    attr_reader :out, :err, :env, :stdin

    def initialize(out: $stdout, err: $stderr, env: ENV, stdin: $stdin)
      @out = out
      @err = err
      @env = env
      @stdin = stdin
    end

    def program = self.class.program

    def run(argv)
      argv = argv.dup
      return print_help if argv.empty? || argv.any? { |a| ['--help', '-h'].include?(a) }

      head = argv.shift
      if (command = self.class.root_verbs[head])
        return Integer(command.handler.call(self, filled(command, nil, argv)))
      end

      domain = self.class.domains[head]
      unless domain
        delegated = fallthrough(head, argv)
        return delegated unless delegated.nil?

        return unknown_head(head)
      end

      verb_name = argv.shift
      return missing_verb(head) if verb_name.nil?

      command = domain[:verbs][verb_name]
      return unknown_verb(head, verb_name) unless command

      Integer(command.handler.call(self, filled(command, head, argv)))
    rescue Die => e
      err.puts e.message
      e.code
    rescue StandardError => e
      code = handled(e)
      raise if code.nil?

      code
    end

    def fallthrough(_head, _argv) = nil

    private

    def filled(command, domain_name, argv)
      Defaults.fill(command, self.class.words_for(domain_name), argv)
    end

    def handled(error)
      self.class.error_handlers.each do |classes, handler|
        return instance_exec(error, &handler) if classes.any? { |c| error.is_a?(c) }
      end
      return unless error.is_a?(MissingOptionValue) || error.is_a?(BodyUnreadable)

      err.puts error.message
      self.class.usage_status
    end
  end
end
