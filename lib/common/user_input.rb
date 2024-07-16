require_relative 'ansi'
require_relative 'time'

module UserInput
    extend self

    def ask(question, options = [])
        puts Ansi.green("#{question} ")
        options.each_with_index do |option, index|
            puts "#{index + 1}. #{option}"
        end
        print '> '
        input = STDIN.gets.chomp
        if options.any?
            loop do
                if input.to_i.between?(1, options.length)
                    return options[input.to_i - 1]
                else
                    puts Ansi.red("Invalid option. Please enter a number between 1 and #{options.length}.")
                    print '> '
                    input = gets.chomp
                end
            end
        else
            input
        end
    end

    def confirm(question)
        ask("#{question} (y/n)") == 'y'
    end

    def get_password(prompt)
        `osascript -e 'Tell application "System Events" to display dialog "#{prompt}" default answer "" with hidden answer' -e 'text returned of result'`.strip
    end

    def get_number(prompt)
        puts Ansi.green(prompt)
        loop do
            print '> '
            input = STDIN.gets.chomp
            if input.match?(/\A\d+\z/)
                return input.to_i
            else
                puts Ansi.red('Invalid input. Please enter a number.')
            end
        end
    end

    def get_integer(prompt)
        puts Ansi.green(prompt)
        loop do
            print '> '
            input = STDIN.gets.chomp
            if input.match?(/\A-?\d+\z/)
                return input.to_i
            else
                puts Ansi.red('Invalid input. Please enter an integer.')
            end
        end
    end

    def get_float(prompt)
        puts Ansi.green(prompt)
        loop do
            print '> '
            input = STDIN.gets.chomp
            if input.match?(/\A-?\d+(\.\d+)?\z/)
                return input.to_f
            else
                puts Ansi.red('Invalid input. Please enter a number.')
            end
        end
    end

    def get_time(prompt)
        relative_time = TimeUtils.parse_time(ask(prompt))
    end

end

