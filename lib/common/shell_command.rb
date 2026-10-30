# frozen_string_literal: true

require 'shellwords'
require_relative 'git'
require_relative 'paths'

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

  # `g` is the zsh alias for git that the Bash tool's shell carries
  GIT_WORDS = %w[git g].freeze

  ENV_ASSIGN = /\A\w+=/.freeze
  WRAPPERS = %w[env sudo doas nohup timeout command stdbuf nice ionice time noglob xargs].freeze
  DURATION = /\A\d+(\.\d+)?[smhd]?\z/.freeze
  KEYWORDS = %w[if then elif else do while until !].freeze
  SHELLS = %w[bash sh zsh ksh dash].freeze
  INLINE_CODE_FLAG = /\A-{1,2}(c|e|E|eval|command)\z/.freeze
  SHELL_CODE_FLAG = /\A-[a-zA-Z]*c[a-zA-Z]*\z/.freeze

  GIT_OPTIONS = {
    '-C' => :dir, '-c' => :override, '--exec-path' => :value, '--config-env' => :value, '--super-prefix' => :value,
    '--git-dir' => :mover, '--work-tree' => :mover, '--namespace' => :mover
  }.freeze
  REPO_ENV = /\AGIT_(DIR|WORK_TREE|COMMON_DIR|NAMESPACE|CONFIG\w*)=/.freeze

  Heredoc = Struct.new(:delim, :dash, :owner, :body, :executable, keyword_init: true) do
    def executable?
      executable
    end
  end

  GitInvocation = Struct.new(:sub, :args, :raw_args, :dir, :overrides, :unresolved, keyword_init: true)

  attr_reader :raw, :heredocs

  def self.basename(tok)
    tok.to_s.split('/').last.to_s
  end

  def self.strip_prefix(tokens, flags: true)
    tokens.drop_while do |t|
      t.match?(ENV_ASSIGN) || WRAPPERS.include?(basename(t)) || t.match?(DURATION) || (flags && t.start_with?('-'))
    end
  end

  def self.inline_code(tokens, flag = INLINE_CODE_FLAG)
    tokens.each_with_index do |tok, i|
      return tokens[i + 1] if tok.match?(flag) && tokens[i + 1]
    end
    nil
  end

  def self.git_builtin?(sub)
    @git_builtins ||= Git.out(nil, '--list-cmds=builtins').to_s.split("\n")
    @git_builtins.include?(sub)
  end

  def self.git_aliases(dir, overrides = [])
    Git.aliases(dir: dir, overrides: overrides)
  end

  # <rest> must already be unquoted - a `!` alias re-quotes it into the shell code git runs
  def self.expand_git_alias(sub, rest, dir: nil, overrides: [])
    body = git_aliases(dir, overrides)[sub.to_s.downcase]
    return nil if body.nil?
    return [:shell, [body[1..], *rest.map { |a| Shellwords.escape(a) }].join(' ')] if body.start_with?('!')

    [:git, Shellwords.split(body) + rest]
  end

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
      GIT_WORDS.include?(words[0]) && words[1] == 'commit'
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
    heredocs.find { |h| GIT_WORDS.include?(h.owner) }
  end

  def data_heredocs
    heredocs.reject(&:executable?)
  end

  def unquote(str)
    s = str.to_s
    return s[1..-2].to_s if s.length >= 2 && s[0] == "'" && s[-1] == "'"
    return s[1..-2].to_s.gsub(/\\(.)/, '\1') if s.length >= 2 && s[0] == '"' && s[-1] == '"'
    return s unless s.match?(/['"]/)

    words = Shellwords.split(s)
    words.length == 1 ? words.first : s
  rescue ArgumentError
    s
  end

  def git_invocations(dir:, hops: 5, walk: false)
    walk_git(dir, hops: hops, walk: walk, depth: 0)
  end

  protected

  def walk_git(dir, hops:, walk:, depth:)
    commands.flat_map do |raw_tokens|
      toks = raw_tokens.dup
      toks[0] = toks[0].sub(/\A[({]+/, '')
      toks[-1] = toks[-1].sub(/[)}]+\z/, '') unless toks[-1].start_with?('"', "'")
      toks = toks.reject(&:empty?).drop_while { |t| KEYWORDS.include?(t) }
      words = ShellCommand.strip_prefix(toks)
      next [] if words.empty?

      name = ShellCommand.basename(unquote(words.first))
      if %w[cd pushd].include?(name)
        dir = cd_target(words, dir, walk)
        []
      elsif GIT_WORDS.include?(name)
        moved = toks[0, toks.length - words.length].any? { |t| t.match?(REPO_ENV) }
        unresolved = 'a GIT_DIR / GIT_CONFIG style variable moves the repository this guard would read' if moved
        resolve_git(words[1..], dir, [], unresolved, hops: hops, walk: walk, depth: depth)
      elsif SHELLS.include?(name) && depth < hops && (code = ShellCommand.inline_code(words, SHELL_CODE_FLAG))
        ShellCommand.new(unquote(code)).walk_git(dir, hops: hops, walk: walk, depth: depth + 1)
      else
        []
      end
    end
  end

  def resolve_git(args, dir, overrides, unresolved, hops:, walk:, depth:)
    i = 0
    while i < args.length
      tok = unquote(args[i])
      opt, inline = tok.start_with?('--') ? tok.split('=', 2) : [tok, nil]
      kind = GIT_OPTIONS[opt]
      break if kind.nil? && !tok.start_with?('-')

      value = inline || unquote(args[i + 1])
      case kind
      when :dir then dir = dir && Paths.canonical(value, base: dir, walk: walk)
      when :override then overrides += [value]
      when :mover then unresolved ||= "`git #{tok}` moves the repository this guard would read"
      end
      i += kind.nil? || inline ? 1 : 2
    end
    sub = args[i] && unquote(args[i])
    rest = args[(i + 1)..] || []
    body = sub && Git.aliases(dir: dir, overrides: overrides)[sub.downcase]
    return [invocation(sub, rest, dir, overrides, unresolved)] if body.nil? || ShellCommand.git_builtin?(sub)

    too_deep = "git alias `#{sub}` nests too deep to follow"
    return [invocation(sub, rest, dir, overrides, unresolved || too_deep)] if depth >= hops

    plain = rest.map { |a| unquote(a) }
    if body.start_with?('!')
      shell = [body[1..], *plain.map { |a| Shellwords.escape(a) }].join(' ')
      return ShellCommand.new(shell).walk_git(dir, hops: hops, walk: walk, depth: depth + 1)
    end

    begin
      expanded = Shellwords.split(body)
    rescue ArgumentError => e
      return [invocation(sub, rest, dir, overrides, unresolved || "git alias `#{sub}` could not be split: #{e.message}")]
    end
    resolve_git(expanded + plain, dir, overrides, unresolved, hops: hops, walk: walk, depth: depth + 1)
  end

  private

  def invocation(sub, rest, dir, overrides, unresolved)
    GitInvocation.new(sub: sub, args: rest.map { |a| unquote(a) }, raw_args: rest, dir: dir,
                      overrides: overrides, unresolved: unresolved)
  end

  def cd_target(words, dir, walk)
    target = words[1..].map { |t| unquote(t) }.reject { |t| %w[-P -L -e -@].include?(t) }.first
    return Dir.home if target.nil?
    return nil if dir.nil? || target == '-'

    Paths.canonical(target, base: dir, walk: walk)
  end

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
