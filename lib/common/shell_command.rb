# frozen_string_literal: true

class ShellCommand
  # A heredoc body is data only if its consumer can't execute it — `bash <<'SH'` hides a real commit.
  INTERPRETERS = %w[
    bash sh zsh ksh dash csh tcsh fish
    python python2 python3 perl ruby node php lua
    ssh sshpass xargs eval exec sudo su env nohup timeout
    docker podman kubectl oc expect make rake gradle
  ].freeze

  OPENER = /(?<!<)<<(-?)[ \t]*(?:'([^']+)'|"([^"]+)"|([A-Za-z0-9_][A-Za-z0-9_.\-]*))/.freeze

  SEPARATORS = [';', '&&', '||', '|', '&', "\n"].freeze

  Heredoc = Struct.new(:delim, :dash, :owner, :body, :executable, keyword_init: true) do
    def executable?
      executable
    end
  end

  attr_reader :raw, :heredocs

  def initialize(raw)
    @raw = raw.to_s
    @heredocs = []
    @unterminated = false
    @code = build_code
  end

  def unterminated?
    @unterminated
  end

  # Falls back to the raw string when parsing gave up, so we never parse our way into an allow.
  def code
    @unterminated ? @raw : @code
  end

  def git_commit?
    commands.any? do |tokens|
      words = tokens.reject { |t| t.start_with?('-') }
      words[0] == 'git' && words[1] == 'commit'
    end
  end

  def commands
    result = [[]]
    tokens.each do |tok|
      if SEPARATORS.include?(tok)
        result << [] unless result.last.empty?
      else
        result.last << tok
      end
    end
    result.reject(&:empty?)
  end

  def tokens
    @tokens ||= Tokenizer.new(code).tokens
  end

  def flag_values(*names)
    out = []
    commands.each do |toks|
      toks.each_with_index do |tok, i|
        if names.include?(tok)
          out << unquote(toks[i + 1]) if toks[i + 1]
        elsif (name = names.find { |n| tok.start_with?("#{n}=") })
          out << unquote(tok[(name.length + 1)..])
        end
      end
    end
    out
  end

  def flag?(*names)
    tokens.any? { |t| names.include?(t) || names.any? { |n| t.start_with?("#{n}=") } }
  end

  def commit_heredoc
    heredocs.find { |h| h.owner == 'git' }
  end

  def data_heredocs
    heredocs.reject(&:executable?)
  end

  def unquote(str)
    s = str.to_s
    return s[1..-2].to_s if s.length >= 2 && s[0] == "'" && s[-1] == "'"
    return s[1..-2].to_s.gsub(/\\(.)/, '\1') if s.length >= 2 && s[0] == '"' && s[-1] == '"'

    s
  end

  private

  def build_code
    out = []
    pending = []
    consuming = nil

    @raw.split("\n", -1).each do |line|
      if consuming
        stripped = consuming.dash ? line.sub(/\A\t+/, '') : line
        if stripped == consuming.delim
          consuming = pending.shift
          next
        end
        out << line if consuming.executable?
        consuming.body << line << "\n"
        next
      end

      owner = command_word(line)
      executable = INTERPRETERS.include?(owner)
      line.scan(OPENER) do |dash, sq, dq, bare|
        hd = Heredoc.new(
          delim: sq || dq || bare,
          dash: dash == '-',
          owner: owner,
          body: +'',
          executable: executable
        )
        @heredocs << hd
        pending << hd
      end
      out << line
      consuming = pending.shift
    end

    @unterminated = !(consuming.nil? && pending.empty?)
    out.join("\n")
  end

  def command_word(line)
    line.sub(/\A[ \t]*/, '').split(/[ \t]/).first.to_s.split('/').last.to_s
  end

  class Tokenizer
    def initialize(str)
      @s = str.to_s
      @i = 0
    end

    def tokens
      out = []
      while @i < @s.length
        skip_blanks
        break if @i >= @s.length

        if (sep = read_separator)
          out << sep
          next
        end
        tok = read_token
        out << tok unless tok.empty?
      end
      out
    end

    private

    def skip_blanks
      @i += 1 while @i < @s.length && [' ', "\t"].include?(@s[@i])
    end

    def read_separator
      two = @s[@i, 2]
      if ['&&', '||'].include?(two)
        @i += 2
        return two
      end
      one = @s[@i]
      if [';', '|', '&', "\n"].include?(one)
        @i += 1
        return one
      end
      nil
    end

    def read_token
      buf = +''
      while @i < @s.length
        c = @s[@i]
        break if [' ', "\t", ';', '|', '&', "\n"].include?(c)

        case c
        when "'" then buf << read_single
        when '"' then buf << read_double
        when '\\'
          buf << c
          @i += 1
          if @i < @s.length
            buf << @s[@i]
            @i += 1
          end
        when '$'
          if @s[@i + 1] == '('
            buf << read_subshell
          else
            buf << c
            @i += 1
          end
        else
          buf << c
          @i += 1
        end
      end
      buf
    end

    def read_single
      buf = +@s[@i]
      @i += 1
      while @i < @s.length && @s[@i] != "'"
        buf << @s[@i]
        @i += 1
      end
      if @i < @s.length
        buf << @s[@i]
        @i += 1
      end
      buf
    end

    def read_double
      buf = +@s[@i]
      @i += 1
      while @i < @s.length && @s[@i] != '"'
        if @s[@i] == '\\'
          buf << @s[@i]
          @i += 1
          next if @i >= @s.length
        end
        buf << @s[@i]
        @i += 1
      end
      if @i < @s.length
        buf << @s[@i]
        @i += 1
      end
      buf
    end

    def read_subshell
      buf = +'$('
      @i += 2
      depth = 1
      while @i < @s.length && depth.positive?
        c = @s[@i]
        case c
        when '('
          depth += 1
          buf << c
          @i += 1
        when ')'
          depth -= 1
          buf << c
          @i += 1
        when "'" then buf << read_single
        when '"' then buf << read_double
        else
          buf << c
          @i += 1
        end
      end
      buf
    end
  end
end
