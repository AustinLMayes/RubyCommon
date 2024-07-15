module Discord::Emoji
    extend self

    def letter(letter)
        letters = letter.downcase.split("")
        res = ""
        letters.each do |letter|
            raise ArgumentError, "Invalid letter: #{letter}" unless letter.match?(/[a-z]/)
            res += ":regional_indicator_#{letter}:"
        end
        res
    end

    def number(number)
        res = ""
        digits = number.to_s.split("")
        digits.each do |digit|
            raise ArgumentError, "Invalid digit: #{digit}" unless digit.match?(/[0-9]/)
            res += case digit.to_i
            when 0
                ":zero:"
            when 1
                ":one:"
            when 2
                ":two:"
            when 3
                ":three:"
            when 4
                ":four:"
            when 5
                ":five:"
            when 6
                ":six:"
            when 7
                ":seven:"
            when 8
                ":eight:"
            when 9
                ":nine:"
            end
        end
    end

    def checkmark
        ":white_check_mark:"
    end

    def x
        ":x:"
    end

    def warning
        ":warning:"
    end

    def error
        ":no_entry_sign:"
    end

    def info
        ":information_source:"
    end

    def tip
        ":bulb:"
    end

    def question
        ":question:"
    end

    def exclamation
        ":exclamation:"
    end

    def arrow(direction)
        case direction
        when :up
            ":arrow_up:"
        when :down
            ":arrow_down:"
        when :left
            ":arrow_left:"
        when :right
            ":arrow_right:"
        end
    end

    def clock(time)
        hour = time.hour.to_s
        minute = time.min >= 30 ? "30" : ""
        hour = "" if hour == "0"
        ":clock#{hour}#{minute}:"
    end

    def heart(color: :red)
        case color
        when :pink
            ":pink_heart:"
        when :red
            ":heart:"
        when :orange
            ":orange_heart:"
        when :yellow
            ":yellow_heart:"
        when :green
            ":green_heart:"
        when :light_blue
            ":light_blue_heart:"
        when :blue
            ":blue_heart:"
        when :purple
            ":purple_heart:"
        when :black
            ":black_heart:"
        when :gray
            ":grey_heart:"
        when :white
            ":white_heart:"
        when :brown
            ":brown_heart:"
        else
            raise ArgumentError, "Invalid color: #{color}"
        end
    end

    def circle(color: :red)
        case color
        when :red
            ":red_circle:"
        when :orange
            ":orange_circle:"
        when :yellow
            ":yellow_circle:"
        when :green
            ":green_circle:"
        when :light_blue
            ":light_blue_circle:"
        when :blue
            ":blue_circle:"
        when :purple
            ":purple_circle:"
        when :black
            ":black_circle:"
        when :white
            ":white_circle:"
        when :brown
            ":brown_circle:"
        else
            raise ArgumentError, "Invalid color: #{color}"
        end
    end

    def square(color: :red)
        case color
        when :red
            ":red_square:"
        when :orange
            ":orange_square:"
        when :yellow
            ":yellow_square:"
        when :green
            ":green_square:"
        when :light_blue
            ":light_blue_square:"
        when :blue
            ":blue_square:"
        when :purple
            ":purple_square:"
        when :black
            ":black_square:"
        when :white
            ":white_square:"
        when :brown
            ":brown_square:"
        else
            raise ArgumentError, "Invalid color: #{color}"
        end
    end

    def signal_strength
        ":signal_strength:"
    end

    # :new:
    def new
        ":new:"
    end

    def free
        ":free:"
    end

    def playback(action)
        case action
        when :eject
            ":eject:"
        when :play
            ":arrow_forward:"
        when :pause
            ":pause_button:"
        when :play_pause
            ":play_pause:"
        when :stop
            ":stop_button:"
        when :record
            ":record_button:"
        when :next
            ":track_next:"
        when :previous
            ":track_previous:"
        when :fast_forward
            ":fast_forward:"
        when :rewind
            ":rewind:"
        when :repeat
            ":repeat:"
        when :shuffle
            ":twisted_rightwards_arrows:"
        else
            raise ArgumentError, "Invalid action: #{action}"
        end
    end

    def math(operation)
        case operation
        when :add
            ":heavy_plus_sign:"
        when :subtract
            ":heavy_minus_sign:"
        when :multiply
            ":heavy_multiplication_x:"
        when :divide
            ":heavy_division_sign:"
        else
            raise ArgumentError, "Invalid operation: #{operation}"
        end
    end

    def chat(dot: false)
        if dot
            ":speech_balloon:"
        else
            ":left_speech_bubble:"
        end
    end

    def hammer_wrench
        ":hammer_and_wrench:"
    end

    def gear
        ":gear:"
    end

    def lock
        ":lock:"
    end

    def shield
        ":shield:"
    end

    def graph(direction)
        case direction
        when :up
            ":chart_with_upwards_trend:"
        when :down
            ":chart_with_downwards_trend:"
        when :bar
            ":bar_chart:"
        else
            raise ArgumentError, "Invalid direction: #{direction}"
        end
    end

    module CubeCraft
        extend self

        def cube(dark: false)
            if dark
                ":cube_dark:"
            else
                ":cube:"
            end
        end

        def swish(dark: false)
            if dark
                ":cube_swish_dark:"
            else
                ":cube_swish:"
            end
        end

        def ziax(dark: false)
            if dark
                ":ziax_dark:"
            else
                ":ziax_light:"
            end
        end

        def emotion(emotion: :blush)
            case emotion
            when :annoyed
                ":cube_annoyed:"
            when :annoyed1
                ":cube_annoyed~1:"
            when :blush
                ":cube_blush:"
            when :blush1
                ":cube_blush~1:"
            when :bruh
                ":cube_bruh:"
            when :chuckle
                ":cube_chuckle:"
            when :confused
                ":cube_confused:"
            when :confused1
                ":cube_confused~1:"
            when :cry
                ":cube_cry:"
            when :crylaugh
                ":cube_crylaugh:"
            when :cry1
                ":cube_cry~1:"
            when :gg
                ":cube_gg:"
            when :hearts
                ":cube_hearts:"
            when :hearts1
                ":cube_hearts~1:"
            when :huh
                ":cube_huh:"
            when :joy
                ":cube_joy:"
            when :lol
                ":cube_lol:"
            when :party
                ":cube_party:"
            when :partying
                ":cube_partying:"
            when :rage
                ":cube_rage:"
            when :rage1
                ":cube_rage~1:"
            when :scared
                ":cube_scared:"
            when :scared1
                ":cube_scared~1:"
            when :smile
                ":cube_smile:"
            when :smile1
                ":cube_smile~1:"
            when :starstruck
                ":cube_starstruck:"
            when :starstruck1
                ":cube_starstruck~1:"
            when :thanks
                ":cube_thanks:"
            when :unamused
                ":cube_unamused:"
            when :unamused1
                ":cube_unamused~1:"
            when :weary
                ":cube_weary:"
            when :wha
                ":cube_wha:"
            else
                raise ArgumentError, "Invalid emotion: #{emotion}"
            end
        end
    end
end