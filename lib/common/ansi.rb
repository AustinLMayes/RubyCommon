module Ansi
    extend self

    COLORS = [:black, :red, :green, :yellow, :blue, :purple, :aqua]

    def color(code, text = nil)
        if text
            "#{color(code)}#{text}#{reset}"
        else
            "\e[#{code}m"
        end
    end

    def reset
        color(0)
    end

    COLORS.each_with_index do |name, code|
        define_method name do |text = nil|
            color(30 + code, text)
        end
    end
end