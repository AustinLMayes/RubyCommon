# frozen_string_literal: true

require 'set'

# Which lines of `new_text` are new relative to `old_text` — the "was this line
# touched by the edit" question, not a printable diff.
module LineDiff
  # Past this many LCS cells we stop diffing and call the whole changed region
  # new. Callers gate on the answer, so over-reporting is the safe direction,
  # and a full LCS on two 5000-line files is ~25M cells inside a PreToolUse hook.
  CELL_CAP = 2_000_000

  # => [new_lines, Set of indices into new_lines that were inserted or replaced]
  def self.added_indices(old_text, new_text)
    old_lines = split(old_text)
    new_lines = split(new_text)

    prefix = common_prefix(old_lines, new_lines)
    suffix = common_suffix(old_lines, new_lines, prefix)

    old_mid = old_lines[prefix...(old_lines.length - suffix)] || []
    new_mid = new_lines[prefix...(new_lines.length - suffix)] || []

    added = if new_mid.empty?
              []
            elsif old_mid.empty? || old_mid.length * new_mid.length > CELL_CAP
              (0...new_mid.length).to_a
            else
              unmatched(old_mid, new_mid)
            end

    [new_lines, added.map { |i| i + prefix }.to_set]
  end

  def self.split(text)
    text.to_s.lines.map { |l| l.chomp("\n") }
  end
  private_class_method :split

  def self.common_prefix(a, b)
    limit = [a.length, b.length].min
    i = 0
    i += 1 while i < limit && a[i] == b[i]
    i
  end
  private_class_method :common_prefix

  def self.common_suffix(a, b, prefix)
    limit = [a.length, b.length].min - prefix
    i = 0
    i += 1 while i < limit && a[a.length - 1 - i] == b[b.length - 1 - i]
    i
  end
  private_class_method :common_suffix

  def self.unmatched(old_mid, new_mid)
    table = lcs_table(old_mid, new_mid)
    matched = []
    i = old_mid.length
    j = new_mid.length
    while i.positive? && j.positive?
      if old_mid[i - 1] == new_mid[j - 1]
        matched << (j - 1)
        i -= 1
        j -= 1
      elsif table[i - 1][j] >= table[i][j - 1]
        i -= 1
      else
        j -= 1
      end
    end
    kept = matched.to_set
    (0...new_mid.length).reject { |k| kept.include?(k) }
  end
  private_class_method :unmatched

  def self.lcs_table(a, b)
    table = Array.new(a.length + 1) { Array.new(b.length + 1, 0) }
    a.each_index do |i|
      row = table[i]
      nxt = table[i + 1]
      b.each_index do |j|
        nxt[j + 1] = a[i] == b[j] ? row[j] + 1 : [nxt[j], row[j + 1]].max
      end
    end
    table
  end
  private_class_method :lcs_table
end
