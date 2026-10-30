# frozen_string_literal: true

require_relative 'defaults'

module Cli
  module Help
    def print_help
      out.puts self.class.banner, '' if self.class.banner
      self.class.domains.sort.each do |name, domain|
        out.puts "  #{name.ljust(12)} #{domain[:summary]}"
        domain[:verbs].sort.each do |verb_name, command|
          out.puts "    #{verb_name.ljust(10)} #{command.summary}"
          out.puts "      #{command.usage}"
          print_defaults(command, name)
        end
      end
      out.puts
      self.class.root_verbs.sort.each do |name, command|
        out.puts "  #{name.ljust(12)} #{command.summary}"
        out.puts "      #{command.usage}"
        print_defaults(command, nil)
      end
      OK
    end

    def print_defaults(command, domain_name)
      spelled = Defaults.spell(command, self.class.words_for(domain_name))
      out.puts "      defaults to #{spelled}" if spelled
    end

    def unknown_head(name)
      err.puts "#{program}: unknown domain or verb #{name.inspect}"
      err.puts "    domains: #{self.class.domains.keys.sort.join(', ')}"
      err.puts "    verbs:   #{self.class.root_verbs.keys.sort.join(', ')}"
      err.puts "    run `#{program} --help`"
      self.class.usage_status
    end

    def missing_verb(domain_name)
      verbs = self.class.domains[domain_name][:verbs].keys.sort
      err.puts "#{program}: #{domain_name} needs a verb"
      err.puts "    verbs: #{verbs.join(', ')}"
      err.puts "    run `#{program} --help`"
      self.class.usage_status
    end

    def unknown_verb(domain_name, verb_name)
      verbs = self.class.domains[domain_name][:verbs].keys.sort
      err.puts "#{program}: #{domain_name} has no verb #{verb_name.inspect}"
      err.puts "    verbs: #{verbs.join(', ')}"
      err.puts "    run `#{program} --help`"
      self.class.usage_status
    end
  end
end
