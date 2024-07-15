module Clipboard
    extend self

    def copy(text)
        IO.popen('pbcopy', 'w') { |io| io << text }
    end

    def paste
        IO.popen('pbpaste', 'r', &:read)
    end
end