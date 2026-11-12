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
  XARGS = %w[xargs gxargs parallel].freeze
  WRAPPERS = (%w[env sudo doas nohup timeout command stdbuf nice ionice time noglob exec caffeinate builtin coproc nocorrect] +
              XARGS).freeze
  WRAPPER_VALUE_FLAGS = {
    'env' => %w[-u --unset -C --chdir -P], 'timeout' => %w[-s --signal -k --kill-after],
    'sudo' => %w[-u -g -C -h -p -U -r -t -D], 'doas' => %w[-u -C], 'exec' => %w[-a], 'nice' => %w[-n],
    'ionice' => %w[-c -n -p], 'stdbuf' => %w[-i -o -e], 'xargs' => %w[-I -n -P -L -d -s -E -J -R -S],
    'gxargs' => %w[-I -n -P -L -d -s -E -a --arg-file], 'parallel' => %w[-I -j -P -n -N -d -E -S -a --jobs --sshlogin],
    'caffeinate' => %w[-t -w]
  }.freeze
  GLOB = /[*?\[]|\{[^{}]*(?:,|\.\.)[^{}]*\}/.freeze
  DURATION = /\A\d+(\.\d+)?[smhd]?\z/.freeze
  KEYWORDS = %w[if then elif else do while until !].freeze
  SHELLS = %w[bash sh zsh ksh dash csh tcsh fish].freeze
  ANSI = /\$'((?:\\.|[^'\\])*)'/m.freeze
  ANSI_ESCAPES = { 'n' => "\n", 't' => "\t", 'r' => "\r", 'e' => "\e", 'a' => "\a", 'b' => "\b", 'f' => "\f", 'v' => "\v" }.freeze
  INLINE_CODE_FLAG = /\A-{1,2}(c|e|E|eval|command)\z/.freeze
  SHELL_CODE_FLAG = /\A-[a-zA-Z]*c[a-zA-Z]*\z/.freeze

  GIT_OPTIONS = {
    '-C' => :dir, '-c' => :override, '--exec-path' => :value, '--config-env' => :value, '--super-prefix' => :value,
    '--attr-source' => :value,
    '--git-dir' => :mover, '--work-tree' => :mover, '--namespace' => :mover
  }.freeze
  REPO_ENV = /\AGIT_(DIR|WORK_TREE|COMMON_DIR|NAMESPACE|CONFIG\w*)=/.freeze

  Heredoc = Struct.new(:delim, :dash, :owner, :body, :executable, :quoted, keyword_init: true) do
    def executable?
      executable
    end
  end

  GitInvocation = Struct.new(:sub, :args, :raw_args, :dir, :overrides, :unresolved, :segment, :at, :cwd, :nested,
                             keyword_init: true)

  attr_reader :raw, :heredocs

  def self.basename(tok)
    tok.to_s.split('/').last.to_s
  end

  def self.command_name(tok)
    basename(tok.to_s.delete('\\').delete_prefix('=').sub(/\A[({]+/, ''))
  end

  def self.xargs_marker(flags, parallel: false)
    i = flags.index { |t| %w[-I -J].include?(t) }
    return flags[i + 1] if i
    return '{}' if flags.any? { |t| %w[-i --replace].include?(t) }

    found = flags.find { |t| t.match?(/\A-[IJi].|\A--replace=/) }&.sub(/\A-[IJi]|\A--replace=/, '')
    found || ('{' if parallel)
  end

  def self.strip_prefix(tokens, flags: true)
    wrapper = nil
    i = 0
    while i < tokens.length
      t = tokens[i]
      if WRAPPERS.include?(command_name(t)) then wrapper = command_name(t)
      elsif flags && t.start_with?('-') then i += 1 if WRAPPER_VALUE_FLAGS.fetch(wrapper, []).include?(t)
      elsif !t.match?(ENV_ASSIGN) && !t.match?(DURATION) then break
      end
      i += 1
    end
    tokens[i..] || []
  end

  def self.inline_code(tokens, flag = INLINE_CODE_FLAG)
    tokens.each_with_index do |tok, i|
      return tokens[i + 1] if tok.match?(flag) && tokens[i + 1]
    end
    nil
  end

  def self.substitutions(text, heredoc: false)
    found = []
    single = double = false
    i = 0
    while i < text.length
      c = text[i]
      if single then single = c != "'"
      elsif c == '\\' then i += 1
      elsif heredoc && c != '`' && text[i, 2] != '$(' then nil
      elsif c == '$' && text[i + 1] == "'" && !double then i = ansi_end(text, i + 2)
      elsif c == "'" && !double then single = true
      elsif c == '"' then double = !double
      elsif c == '#' && !double && (i.zero? || (text[i - 1].match?(/\s/) && text[i - 2] != '\\'))
        i = text.index("\n", i) || text.length
      elsif c == '`'
        stop = text.index(/(?<!\\)`/, i + 1) || text.length
        found << text[(i + 1)...stop]
        i = stop
      elsif text[i, 2].match?(/\A[$<>]\(/) || (text[i, 2] == '=(' && (i.zero? || !text[i - 1].match?(/[\w\]+]/)))
        stop = closing_paren(text, i + 2)
        found << text[(i + 2)...stop]
        i = stop
      end
      i += 1
    end
    found
  end

  def self.closing_paren(text, from)
    depth = 1
    quote = nil
    i = from
    while i < text.length
      c = text[i]
      if c == '\\' && quote != "'" then i += 1
      elsif quote then quote = nil if c == quote
      elsif ["'", '"'].include?(c) then quote = c
      elsif c == '(' then depth += 1
      elsif c == ')' && (depth -= 1).zero? then return i
      end
      i += 1
    end
    text.length
  end
  def self.ansi_decode(text)
    text.gsub(/\\(x\h{1,2}|u\h{1,4}|[0-7]{1,3}|.)/m) do
      e = Regexp.last_match(1)
      if e.match?(/\A[xu]\h/) then (n = e[1..].hex) < 128 ? n.chr : '?'
      elsif e.match?(/\A[0-7]/) then (n = e.oct) < 128 ? n.chr : '?'
      else ANSI_ESCAPES.fetch(e, e)
      end
    end
  end

  def self.trailing_closes(tok)
    count = depth = 0
    quote = nil
    i = 0
    while i < tok.length
      c = tok[i]
      if quote.nil? && depth.zero? && c == ')'
        count += 1
        i += 1
        next
      end

      count = 0
      if quote == "'" then quote = nil if c == "'"
      elsif c == '\\' then i += 1
      elsif tok[i, 2].match?(/\A[$<>]\(/)
        depth += 1
        i += 1
      elsif c == ')' then depth -= 1
      elsif quote == '"' then quote = nil if c == '"'
      elsif ["'", '"'].include?(c) then quote = c
      end
      i += 1
    end
    count
  end

  def self.heredoc_scan_text(line)
    out = +''
    stack = []
    i = 0
    while i < line.length
      c = line[i]
      top = stack.last
      if top == :single
        stack.pop if c == "'"
        c = ' '
      elsif c == '\\'
        c = '  '
        i += 1
      elsif top == :double && line[i, 2] != '$('
        stack.pop if c == '"'
        c = ' '
      elsif (heredoc = line[i..][/\A<<-?[ \t]*(?:'[^']*'|"[^"]*")/])
        c = heredoc
        i += heredoc.length - 1
      elsif line[i, 3] == '$((' || line[i, 2] == '$[' || (line[i, 2] == '((' && stack.empty?)
        close = line[i, 2] == '$[' ? ']' : '))'
        stop = (line.index(close, i + 2) || line.length) + close.length
        c = ' ' * (stop - i)
        i = stop - 1
      elsif c == '#' && (i.zero? || line[i - 1].match?(/[ \t;&|()]/)) then break
      elsif c == "'" then stack << :single
      elsif c == '"' then stack << :double
      elsif c == '$' && line[i + 1] == "'"
        stop = ansi_end(line, i + 2)
        c = ' ' * (stop - i + 1)
        i = stop
      elsif line[i, 2].match?(/\A[$<>]\(/)
        stack << :sub
        c = line[i, 2]
        i += 1
      elsif c == '(' && top == :sub then stack << :sub
      elsif c == ')' && top == :sub then stack.pop
      end
      out << c
      i += 1
    end
    out
  end

  def self.ansi_end(text, from)
    i = from
    i += text[i] == '\\' ? 2 : 1 while i < text.length && text[i] != "'"
    i
  end
  private_class_method :closing_paren

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

  def comments
    tokens.each_cons(2).filter_map { |a, b| b if a == '#' && !SEPARATORS.include?(b) }
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
    s = s.gsub(ANSI) { "'#{ShellCommand.ansi_decode(Regexp.last_match(1)).gsub("'", %q('\\\\''))}'" } if s.include?("$'")
    return s[1..-2].to_s if s.length >= 2 && s[0] == "'" && s[-1] == "'" && !s[1..-2].include?("'")
    return s[1..-2].to_s.gsub(/\\(.)/, '\1') if s.length >= 2 && s[0] == '"' && s[-1] == '"'
    return s unless s.match?(/['"\\]/)

    words = Shellwords.split(s)
    words.length == 1 ? words.first : s
  rescue ArgumentError
    s
  end

  def git_invocations(dir:, hops: 5, walk: false, substitutions: false, &other)
    walk_git(dir, hops: hops, walk: walk, depth: 0, subs: substitutions, &other)
  end

  def moves?
    commands.any? { |c| %w[cd pushd popd].include?(ShellCommand.command_name(unquote(ShellCommand.strip_prefix(c).first.to_s))) }
  end

  def wrapper_options(toks)
    wrapper = nil
    chdir = nil
    i = 0
    while i < toks.length
      t = unquote(toks[i])
      if WRAPPERS.include?(ShellCommand.command_name(t)) then wrapper = ShellCommand.command_name(t)
      elsif t.match?(ENV_ASSIGN) || t.match?(DURATION) then nil
      elsif !t.start_with?('-') || wrapper.nil? then break
      elsif wrapper == 'env' && (t == '--split-string' || t.match?(/\A-[a-zA-Z]*S\z/)) then return [toks[i + 1], chdir]
      elsif wrapper == 'env' && t.start_with?('--split-string=') then return [t.delete_prefix('--split-string='), chdir]
      elsif wrapper == 'env' && t.match?(/\A-[a-zA-Z]*S./) then return [t.sub(/\A-[a-zA-Z]*?S/, ''), chdir]
      elsif t.start_with?('--chdir=') then chdir = t.delete_prefix('--chdir=')
      elsif { 'env' => %w[-C --chdir], 'sudo' => %w[-D --chdir] }.fetch(wrapper, []).include?(t)
        chdir = unquote(toks[i + 1].to_s)
        i += 1
      elsif wrapper == 'env' && t.match?(/\A-C./) then chdir = t[2..]
      elsif WRAPPER_VALUE_FLAGS.fetch(wrapper, []).include?(t) then i += 1
      end
      i += 1
    end
    [nil, chdir]
  end

  protected

  def walk_git(dir, hops:, walk:, depth:, subs: false, &other)
    start = dir
    subshells = []
    pushed = []
    found = segments.flat_map do |all_tokens, before, after|
      raw_tokens = all_tokens.take_while { |t| t != '#' }
      next [] if raw_tokens.empty?

      raw_tokens.first[/\A[({]*/].count('(').times { subshells << dir }
      closes = ShellCommand.trailing_closes(raw_tokens.last)
      nested = subs ? substituted(raw_tokens.join(' '), raw_tokens, dir, hops: hops, walk: walk, depth: depth, &other) : []
      toks = raw_tokens.dup
      toks[0] = toks[0].sub(/\A(?:\(|\{(?![^{}\s]*(?:,|\.\.)[^{}\s]*\}))+/, '')
      toks[-1] = toks[-1][0, toks[-1].length - closes] if closes.positive?
      toks[-1] = '' if toks[-1].match?(/\A\}+\z/)
      toks = toks.reject(&:empty?).drop_while { |t| KEYWORDS.include?(t) }
      words = ShellCommand.strip_prefix(toks)
      split, chdir = wrapper_options(toks)
      if words.empty? && split.nil?
        closes.times { dir = subshells.pop if subshells.any? }
        next nested
      end

      name = ShellCommand.command_name(unquote(words.first.to_s))
      shell_at = words.index { |w| SHELLS.include?(ShellCommand.command_name(unquote(w))) }
      code = shell_at && ShellCommand.inline_code(words[shell_at..], SHELL_CODE_FLAG)
      code ||= split
      here = chdir ? moved_dir(chdir, dir, walk) : dir
      unsure = %w[| &].include?(after) || %w[| ||].include?(before) || (before == '&&' && after != '&&')
      result = nested + if %w[cd pushd popd].include?(name)
                 pushed << dir if name == 'pushd'
                 target = name == 'popd' ? pushed.pop : cd_target(words, dir, walk)
                 dir = unsure ? nil : target
                 []
               elsif (name == 'eval' || code) && depth >= hops
                 [too_deep(toks, here)]
               elsif GIT_WORDS.include?(name)
                 moved = toks[0, toks.length - words.length].any? { |t| t.match?(REPO_ENV) }
                 unresolved = 'a GIT_DIR / GIT_CONFIG style variable moves the repository this guard would read' if moved
                 unresolved ||= xargs_fed(toks[0, toks.length - words.length], words)
                 site = { segment: toks, cwd: here, at: toks.length - words.length + 1, nested: depth.positive? }
                 resolve_git(words[1..], here, [], unresolved, hops: hops, walk: walk, depth: depth, site: site, typed: true,
                                                               subs: subs, &other)
               elsif name == 'eval'
                 inner = ShellCommand.new(words[1..].map { |t| unquote(t) }.join(' '))
                 found_inner = inner.walk_git(here, hops: hops, walk: walk, depth: depth + 1, subs: subs, &other)
                 dir = nil if inner.moves?
                 found_inner
               elsif code
                 other&.call(words.map { |t| unquote(t) }, here, toks.map { |t| unquote(t) }) if shell_at&.positive?
                 ShellCommand.new(unquote(code)).walk_git(here, hops: hops, walk: walk, depth: depth + 1, subs: subs, &other)
               else
                 other&.call(words.map { |t| unquote(t) }, here, toks.map { |t| unquote(t) })
                 []
               end
      closes.times { dir = subshells.pop if subshells.any? }
      result
    end
    return found unless subs

    docs = heredocs.reject { |h| h.quoted || h.executable? }.map(&:body).join("\n")
    found + substituted(docs, [], dir == start ? start : nil, hops: hops, walk: walk, depth: depth, heredoc: true, &other)
  end

  def moved_dir(target, dir, walk)
    target.match?(Paths::UNKNOWABLE) || dir.nil? ? nil : Paths.canonical(target, base: dir, walk: walk)
  end

  def xargs_fed(prefix, words)
    at = prefix.index { |t| XARGS.include?(ShellCommand.command_name(unquote(t))) }
    return unless at

    parallel = ShellCommand.command_name(unquote(prefix[at])) == 'parallel'
    marker = ShellCommand.xargs_marker(prefix[(at + 1)..].map { |t| unquote(t) }, parallel: parallel)
    'xargs adds arguments to it from stdin' if parallel || marker.nil? || words.any? { |w| unquote(w).include?(marker) }
  end

  def segments
    out = []
    current = []
    before = nil
    tokens.each do |tok|
      if !SEPARATORS.include?(tok)
        current << tok
      elsif current.any?
        out << [current, before, tok]
        current = []
        before = tok
      elsif tok != "\n"
        before = tok
      end
    end
    out << [current, before, nil] if current.any?
    out
  end

  def substituted(text, segment, dir, hops:, walk:, depth:, heredoc: false, &other)
    ShellCommand.substitutions(text, heredoc: heredoc).flat_map do |code|
      next [too_deep(segment, dir)] if depth >= hops

      ShellCommand.new(code).walk_git(dir, hops: hops, walk: walk, depth: depth + 1, subs: true, &other)
    end
  end

  def resolve_git(args, dir, overrides, unresolved, hops:, walk:, depth:, site:, typed: false, subs: false, &other)
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
    site = site.merge(at: site[:at] + i) if typed
    sub = args[i] && unquote(args[i])
    rest = args[(i + 1)..] || []
    if sub&.match?(/[$`*?\[]/)
      return [invocation(sub, rest, dir, overrides, unresolved || 'its git subcommand is only known when it runs', site)]
    end

    body = sub && Git.aliases(dir: dir, overrides: overrides)[sub.downcase]
    return [invocation(sub, rest, dir, overrides, unresolved, site)] if body.nil? || ShellCommand.git_builtin?(sub)

    too_deep = "git alias `#{sub}` nests too deep to follow"
    return [invocation(sub, rest, dir, overrides, unresolved || too_deep, site)] if depth >= hops

    plain = rest.map { |a| unquote(a) }
    if body.start_with?('!')
      shell = [body[1..], *plain.map { |a| Shellwords.escape(a) }].join(' ')
      return ShellCommand.new(shell).walk_git(dir, hops: hops, walk: walk, depth: depth + 1, subs: subs, &other)
    end

    begin
      expanded = Shellwords.split(body)
    rescue ArgumentError => e
      return [invocation(sub, rest, dir, overrides, unresolved || "git alias `#{sub}` could not be split: #{e.message}", site)]
    end
    resolve_git(expanded + plain, dir, overrides, unresolved, hops: hops, walk: walk, depth: depth + 1, site: site, subs: subs, &other)
  end

  private

  def invocation(sub, rest, dir, overrides, unresolved, site)
    GitInvocation.new(sub: sub, args: rest.map { |a| unquote(a) }, raw_args: rest, dir: dir,
                      overrides: overrides, unresolved: unresolved, segment: site[:segment],
                      at: sub && site[:at], cwd: site[:cwd], nested: site[:nested])
  end

  def too_deep(segment, dir)
    GitInvocation.new(args: [], raw_args: [], dir: dir, overrides: [], unresolved: 'it nests shells or substitutions too deep to read',
                      segment: segment, cwd: dir, nested: true)
  end

  def cd_target(words, dir, walk)
    raw = words[1..].reject { |t| %w[-P -L -e -@].include?(unquote(t)) }.first
    target = raw && unquote(raw)
    return Dir.home if target.nil?
    return nil if dir.nil? || target == '-' || raw.gsub(/'[^']*'|"(?:\\.|[^"\\])*"/, '').match?(GLOB)

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
      ShellCommand.heredoc_scan_text(line).scan(OPENER) do |dash, sq, dq, bare|
        hd = Heredoc.new(
          delim: sq || dq || bare,
          dash: dash == '-',
          owner: owner,
          body: +'',
          executable: executable,
          quoted: bare.nil?
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
        if @s[@i] == '#'
          read_comment(out)
          next
        end
        tok = read_token
        out << tok unless tok.empty?
      end
      out
    end

    private

    def read_comment(out)
      out << '#'
      stop = @s.index("\n", @i) || @s.length
      text = @s[(@i + 1)...stop].strip
      out << text unless text.empty?
      @i = stop
    end

    def skip_blanks
      @i += @s[@i] == '\\' ? 2 : 1 while @i < @s.length && ([' ', "\t"].include?(@s[@i]) || @s[@i, 2] == "\\\n")
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
        break if ['<', '>'].include?(c) && @s[@i + 1] != '(' && !buf.match?(/\A\d*[<>]*\z/)

        case c
        when "'" then buf << read_single
        when '"', '`' then buf << read_double
        when '\\'
          if @s[@i + 1] == "\n"
            @i += 2
            next
          end

          buf << c
          @i += 1
          if @i < @s.length
            buf << @s[@i]
            @i += 1
          end
        when '$', '<', '>', '='
          if @s[@i + 1] == '(' && (c != '=' || buf.match?(/\A[({]*\z/))
            buf << read_subshell
          elsif c == '$' && @s[@i + 1] == "'"
            buf << read_ansi
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
      close = @s[@i]
      buf = close.dup
      @i += 1
      while @i < @s.length && @s[@i] != close
        if @s[@i] == '\\' && @s[@i + 1] == "\n"
          @i += 2
          next
        elsif @s[@i] == '\\'
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

    def read_ansi
      start = @i
      @i = ShellCommand.ansi_end(@s, @i + 2) + 1
      @s[start...@i]
    end

    def read_subshell
      buf = +@s[@i, 2]
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
