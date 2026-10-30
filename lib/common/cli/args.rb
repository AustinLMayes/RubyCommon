# frozen_string_literal: true

module Cli
  MissingOptionValue = Class.new(StandardError)
  BodyUnreadable = Class.new(StandardError)

  module Args
    def usage_error(usage)
      err.puts "#{program}: #{usage}"
      self.class.usage_status
    end

    def expect_no_more!(argv, usage = nil)
      return true if argv.empty?

      err.puts "#{program}: unexpected arguments: #{argv.join(' ')}"
      err.puts "    #{usage}" if usage
      err.puts "    run `#{program} --help`"
      false
    end

    def take_options(argv, names)
      taken = {}
      rest = []
      until argv.empty?
        token = argv.shift
        unless names.include?(token)
          rest << token
          next
        end

        key = token.sub(/\A--/, '')
        if taken.key?(key)
          raise MissingOptionValue,
                "#{token} was given twice (#{taken[key].inspect} then #{argv.first.inspect}) — " \
                'refusing rather than silently discarding one of them'
        end

        value = argv.shift
        raise MissingOptionValue, "#{token} needs a value" if value.nil?

        taken[key] = value
      end
      argv.replace(rest)
      taken
    end

    def body_from(source, required: false)
      if source.nil?
        if required
          raise BodyUnreadable, 'this write needs --body-file <path|-> — refusing rather ' \
                                'than storing an empty body over what is there'
        end

        return ''
      end

      body = if source == '-'
               stdin.read.to_s
             else
               raise BodyUnreadable, "no body file at #{source}" unless File.file?(source)

               File.read(source)
             end
      raise BodyUnreadable, invalid_body_message unless body.valid_encoding?
      if required && body.strip.empty?
        raise BodyUnreadable, 'the body is empty — refusing rather than blanking the document'
      end

      body
    end

    def invalid_body_message
      'the body is not valid UTF-8 — refusing rather than writing bytes it cannot read back.'
    end
  end
end
