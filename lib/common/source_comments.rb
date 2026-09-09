# frozen_string_literal: true

# Finds the comment lines in a source file.
#
# Detection is lexical rather than a regex per line, because a regex cannot tell
# `// real comment` from `"// inside a string"`. Each language family gets a
# small stateful scanner, so text inside string literals, template literals,
# Java text blocks, Python docstrings, shell/Ruby heredocs and YAML block
# scalars is never mistaken for a comment.
class SourceComments
  NOT_COMMENT = 0
  IS_COMMENT = 1
  # An empty line inside a block comment. Keeps a blank from splitting one
  # comment into two runs, so a marker anywhere in the block still covers it all.
  BLANK_IN_BLOCK = 2

  CODE = :code
  STRING = :string
  COMMENT = :comment

  C_FAMILY = %w[
    .java .kt .kts .scala .groovy
    .js .ts .tsx .jsx .mjs .cjs
    .go .rs
    .c .cc .cpp .cxx .h .hpp .hxx
    .cs .swift .m .mm
    .css .scss .sass .less
    .gradle
  ].freeze
  TEXT_BLOCK_LANGS = %w[.java .kt .kts .scala .groovy].freeze
  TEMPLATE_LITERAL_LANGS = %w[.js .ts .tsx .jsx .mjs .cjs].freeze
  BARE_HASH = %w[.fish .pl .pm .properties .dockerfile .containerfile].freeze
  BARE_HASH_NAMES = %w[dockerfile containerfile makefile].freeze

  LIFETIME_RE = /\G'[A-Za-z_][A-Za-z0-9_]*/.freeze
  HEREDOC_SH_RE = /(?<!<)<<-?\s*(?:(['"])([A-Za-z_][\w.-]*)\1|([A-Za-z_][\w.-]*))(?!<)/.freeze
  HEREDOC_RB_RE = /(?<!<)<<[~-]?\s*(?:(['"])([A-Za-z_][\w.-]*)\1|([A-Z_][\w.-]*))/.freeze
  BLOCK_SCALAR_RE = /(?:^|[\s:-])[|>][-+]?[0-9]*\s*$/.freeze

  attr_reader :lang, :suffix

  # => a SourceComments, or nil when the path is not a language we scan
  def self.for_path(file_path)
    suffix = File.extname(file_path.to_s).downcase
    name = File.basename(file_path.to_s).downcase
    lang = language_for(suffix, name)
    lang && new(lang, suffix)
  end

  def self.language_for(suffix, name)
    return 'c' if C_FAMILY.include?(suffix)
    return 'sql' if suffix == '.sql'
    return 'python' if suffix == '.py'
    return 'shell' if %w[.sh .bash .zsh].include?(suffix)
    return 'yaml' if %w[.yml .yaml].include?(suffix)
    return 'toml' if suffix == '.toml'
    return 'ruby' if suffix == '.rb'
    return 'lua' if suffix == '.lua'
    return 'html' if %w[.html .htm .xml .vue .svelte].include?(suffix)
    return 'hash' if BARE_HASH.include?(suffix) || BARE_HASH_NAMES.include?(name)

    nil
  end

  def initialize(lang, suffix)
    @lang = lang
    @suffix = suffix
    @spec = build_spec
  end

  # => one of NOT_COMMENT / IS_COMMENT / BLANK_IN_BLOCK per line
  def flags(lines)
    state = { block: false, triple: nil, quote: nil }
    heredoc_re = @spec[:heredoc] == 'ruby' ? HEREDOC_RB_RE : HEREDOC_SH_RE
    heredoc = nil
    pending = []
    scalar_indent = nil
    ruby_block = false
    out = []

    lines.each do |line|
      stripped = line.strip

      if heredoc
        heredoc = stripped == heredoc ? pending.shift : heredoc
        out << NOT_COMMENT
        next
      end

      if ruby_block
        out << IS_COMMENT
        ruby_block = false if stripped.start_with?('=end')
        next
      end
      if @lang == 'ruby' && stripped.start_with?('=begin')
        ruby_block = true
        out << IS_COMMENT
        next
      end

      if scalar_indent
        if stripped.empty? || indent_of(line) > scalar_indent
          out << NOT_COMMENT
          next
        end
        scalar_indent = nil
      end

      kinds = scan_line(line, state)
      first = first_non_space(line)
      out << if first.nil?
               state[:block] ? BLANK_IN_BLOCK : NOT_COMMENT
             else
               kinds[first] == COMMENT ? IS_COMMENT : NOT_COMMENT
             end

      if @spec[:heredoc]
        # The << operator has to be code, but the delimiter may be quoted
        # (<<'EOF'), so match a line that still has its string bodies.
        uncommented = mask(line, kinds, COMMENT)
        uncommented.to_enum(:scan, heredoc_re).each do
          m = Regexp.last_match
          pending << (m[2] || m[3]) if kinds[m.begin(0)] == CODE
        end
      end
      if @spec[:block_scalar] && BLOCK_SCALAR_RE.match?(keep_only(line, kinds, CODE))
        scalar_indent = indent_of(line)
      end
      heredoc = pending.shift if heredoc.nil? && !pending.empty?
    end

    out
  end

  private

  def indent_of(line)
    line.length - line.lstrip.length
  end

  def first_non_space(line)
    line.each_char.with_index { |ch, i| return i unless ch.match?(/\s/) }
    nil
  end

  def mask(line, kinds, kind)
    line.each_char.with_index.map { |ch, i| kinds[i] == kind ? ' ' : ch }.join
  end

  def keep_only(line, kinds, kind)
    line.each_char.with_index.map { |ch, i| kinds[i] == kind ? ch : ' ' }.join
  end

  def build_spec
    case @lang
    when 'c' then c_spec
    when 'sql'
      { line: ['--'], block: ['/*', '*/'], triple: [],
        quotes: { "'" => { escape: false }, '"' => { escape: false } } }
    when 'python'
      { line: ['#'], block: nil, triple: [['"""', '"""'], ["'''", "'''"]],
        quotes: { '"' => { escape: true }, "'" => { escape: true } } }
    when 'shell'
      { line: ['#'], block: nil, triple: [],
        quotes: { '"' => { escape: true, multiline: true },
                  "'" => { escape: false, multiline: true } },
        heredoc: 'shell' }
    when 'ruby'
      { line: ['#'], block: nil, triple: [],
        quotes: { '"' => { escape: true, multiline: true },
                  "'" => { escape: false, multiline: true } },
        heredoc: 'ruby' }
    when 'yaml'
      { line: ['#'], block: nil, triple: [],
        quotes: { '"' => { escape: true }, "'" => { escape: false } },
        block_scalar: true }
    when 'toml'
      { line: ['#'], block: nil, triple: [['"""', '"""'], ["'''", "'''"]],
        quotes: { '"' => { escape: true }, "'" => { escape: false } } }
    when 'lua'
      { line: ['--'], block: ['--[[', ']]'], triple: [['[[', ']]']],
        quotes: { '"' => { escape: true }, "'" => { escape: true } } }
    when 'html'
      { line: [], block: ['<!--', '-->'], triple: [],
        quotes: { '"' => { escape: false }, "'" => { escape: false } } }
    else
      { line: @suffix == '.properties' ? ['#', '!'] : ['#'],
        block: nil, triple: [], quotes: {} }
    end
  end

  def c_spec
    spec = { line: ['//'], block: ['/*', '*/'], triple: [],
             quotes: { '"' => { escape: true }, "'" => { escape: true } },
             lifetime_guard: @suffix == '.rs' }
    spec[:triple] = [['"""', '"""']] if TEXT_BLOCK_LANGS.include?(@suffix)
    spec[:quotes]['`'] = { escape: true, multiline: true } if TEMPLATE_LITERAL_LANGS.include?(@suffix)
    spec
  end

  def find_close(line, start, quote, escape)
    i = start
    while i < line.length
      ch = line[i]
      if escape && ch == '\\'
        i += 2
        next
      end
      return i if ch == quote

      i += 1
    end
    -1
  end

  # Rust `&'a str` opens no string; `'a'` does.
  def lifetime?(line, index)
    m = LIFETIME_RE.match(line, index)
    return false unless m

    finish = m.end(0)
    finish >= line.length || line[finish] != "'"
  end

  def scan_line(line, state)
    n = line.length
    kinds = Array.new(n, CODE)
    mark = ->(from, to, kind) { (from...to).each { |k| kinds[k] = kind } }
    i = 0

    while i < n
      if state[:block]
        close = @spec[:block][1]
        j = line.index(close, i)
        if j.nil?
          mark.call(i, n, COMMENT)
          i = n
        else
          mark.call(i, j + close.length, COMMENT)
          i = j + close.length
          state[:block] = false
        end
        next
      end

      if state[:triple]
        close = state[:triple]
        j = line.index(close, i)
        if j.nil?
          mark.call(i, n, STRING)
          i = n
        else
          mark.call(i, j + close.length, STRING)
          i = j + close.length
          state[:triple] = nil
        end
        next
      end

      if state[:quote]
        quote = state[:quote]
        j = find_close(line, i, quote, @spec[:quotes][quote][:escape])
        if j == -1
          mark.call(i, n, STRING)
          i = n
        else
          mark.call(i, j + 1, STRING)
          i = j + 1
          state[:quote] = nil
        end
        next
      end

      block = @spec[:block]
      if block && line[i, block[0].length] == block[0]
        state[:block] = true
        mark.call(i, i + block[0].length, COMMENT)
        i += block[0].length
        next
      end

      opened = @spec[:triple].find { |open_tok, _| line[i, open_tok.length] == open_tok }
      if opened
        state[:triple] = opened[1]
        mark.call(i, i + opened[0].length, STRING)
        i += opened[0].length
        next
      end

      token = @spec[:line].find { |tok| line[i, tok.length] == tok }
      if token
        mark.call(i, n, COMMENT)
        i = n
        next
      end

      ch = line[i]
      info = @spec[:quotes][ch]
      if info
        if ch == "'" && @spec[:lifetime_guard] && lifetime?(line, i)
          i += 1
          next
        end
        j = find_close(line, i + 1, ch, info[:escape])
        if j == -1
          state[:quote] = ch if info[:multiline]
          mark.call(i, n, STRING)
          i = n
        else
          mark.call(i, j + 1, STRING)
          i = j + 1
        end
        next
      end
      i += 1
    end

    kinds
  end
end
