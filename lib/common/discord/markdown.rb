module Discord::Markdown
    extend self

    def bold(text)
        "**#{text}**"
    end

    def italic(text)
        "*#{text}*"
    end

    def underline(text)
        "__#{text}__"
    end

    def strikethrough(text)
        "~~#{text}~~"
    end

    def code(text)
        "`#{text}`"
    end

    def code_block(text, lang: "")
        "```#{lang}\n#{text}\n```"
    end

    def quote(text)
        "> #{text}"
    end

    def spoiler(text)
        "||#{text}||"
    end

    def link(url, text: nil, preview: false)
        link = "<#{url}>" unless preview
        link = "[#{text}](#{link})" if text
        link
    end

    def h1(text)
        "# #{text}"
    end

    def h2(text)
        "## #{text}"
    end

    def h3(text)
        "### #{text}"
    end

    def subtext(text)
        "-# #{text}"
    end
    
    def list_item(text)
        "- #{text}"
    end

    def mention(user_id)
        "@#{user_id}"
    end

    def channel_mention(channel_id)
        "##{channel_id}"
    end

    def time(time, fomat: :date_time)
        epoch = time.to_i
        suffix = case fomat
        when :date_time_day
            'F'
        when :date_time
            'f'
        when :date_long
            'D'
        when :date_short
            'd'
        when :time_long
            'T'
        when :time_short
            't'
        when :relative
            'R'
        else
            raise ArgumentError, "Invalid format: #{format}"
        end
    end
end