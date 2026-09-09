# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/common/source_comments'

class SourceCommentsTest < Minitest::Test
  C = SourceComments::IS_COMMENT
  N = SourceComments::NOT_COMMENT
  B = SourceComments::BLANK_IN_BLOCK

  def flags(path, text)
    scanner = SourceComments.for_path(path)
    refute_nil scanner, "no scanner for #{path}"
    scanner.flags(text.lines.map { |l| l.chomp("\n") })
  end

  def test_unknown_extension_has_no_scanner
    assert_nil SourceComments.for_path('notes.md')
    assert_nil SourceComments.for_path('data.json')
    assert_nil SourceComments.for_path('notes.txt')
  end

  def test_language_detection
    assert_equal 'c', SourceComments.for_path('A.java').lang
    assert_equal 'c', SourceComments.for_path('a.rs').lang
    assert_equal 'python', SourceComments.for_path('a.py').lang
    assert_equal 'shell', SourceComments.for_path('a.zsh').lang
    assert_equal 'ruby', SourceComments.for_path('a.rb').lang
    assert_equal 'yaml', SourceComments.for_path('a.yaml').lang
    assert_equal 'sql', SourceComments.for_path('q.sql').lang
    assert_equal 'lua', SourceComments.for_path('a.lua').lang
    assert_equal 'html', SourceComments.for_path('a.vue').lang
  end

  def test_extension_matching_is_case_insensitive
    assert_equal 'c', SourceComments.for_path('A.JAVA').lang
  end

  def test_dockerfile_is_detected_by_name
    assert_equal 'hash', SourceComments.for_path('/x/Dockerfile').lang
  end

  def test_line_comment_and_code
    assert_equal [N, C, N], flags('A.java', "int a = 1;\n// note\nint b = 2;\n")
  end

  def test_trailing_comment_is_not_a_comment_line
    assert_equal [N], flags('A.java', "int a = 1; // trailing\n")
  end

  def test_block_comment_spans_lines
    assert_equal [C, C, C, N], flags('A.java', "/*\n * body\n */\nint a = 1;\n")
  end

  def test_blank_inside_a_block_is_marked_separately
    assert_equal [C, C, B, C, C, N], flags('A.java', "/*\n * one\n\n * two\n */\nint a = 1;\n")
  end

  def test_blank_outside_a_block_is_not_in_a_block
    assert_equal [N, N, N], flags('A.java', "int a = 1;\n\nint b = 2;\n")
  end

  def test_a_string_holding_comment_syntax_is_not_a_comment
    assert_equal [N, N], flags('A.java', %(String s = "// no";\nString t = "/* no */";\n))
  end

  def test_python_docstring_is_a_string
    assert_equal [N, N, N, N], flags('a.py', %(def f():\n    """Doc.\n    """\n    return 1\n))
  end

  def test_hash_inside_a_python_string_is_not_a_comment
    assert_equal [N], flags('a.py', %(url = "http://x/#frag"\n))
  end

  def test_java_text_block_body_is_a_string
    assert_equal [N, N, N], flags('A.java', %(String s = """\n    // no\n    """;\n))
  end

  def test_js_template_literal_body_is_a_string
    assert_equal [N, N, N], flags('a.js', "const s = `\n// no\n`;\n")
  end

  def test_shell_quoted_heredoc_body_is_not_comments
    assert_equal [N, N, N, N], flags('a.sh', "cat <<'EOF'\n# no\nEOF\necho hi\n")
  end

  def test_shell_comment_after_a_heredoc_closes
    assert_equal [N, N, N, C], flags('a.sh', "cat <<'EOF'\n# no\nEOF\n# yes\n")
  end

  def test_two_heredocs_queued_on_one_line
    text = "cat <<-DOC > a && cat <<OTHER > b\n\t## one\nDOC\n## two\nOTHER\n# yes\n"
    assert_equal [N, N, N, N, N, C], flags('a.sh', text)
  end

  def test_left_shift_is_not_a_heredoc
    assert_equal [N, N, C], flags('a.sh', "n=$((1 << 3))\necho $n\n# yes\n")
  end

  def test_ruby_squiggly_heredoc_body_is_not_comments
    assert_equal [N, N, N, N], flags('a.rb', "s = <<~TEXT\n  # no\nTEXT\nputs s\n")
  end

  def test_ruby_begin_end_block_is_a_comment
    assert_equal [C, C, C, N], flags('a.rb', "=begin\nbody\n=end\nx = 1\n")
  end

  def test_yaml_block_scalar_body_is_not_comments
    assert_equal [N, N, N, N], flags('a.yml', "script: |\n  # no\n  echo hi\nother: 1\n")
  end

  def test_yaml_comment_after_a_block_scalar_ends
    assert_equal [N, N, N, C], flags('a.yml', "script: |\n  # no\nother: 1\n# yes\n")
  end

  def test_yaml_folded_scalar_with_chomp_indicator
    assert_equal [N, N, N], flags('a.yml', "run: >-\n    ## no\n    # no\n")
  end

  def test_rust_lifetime_does_not_open_a_string
    assert_equal [N, C], flags('a.rs', "fn f<'a>(x: &'a str) -> &'a str { x }\n// yes\n")
  end

  def test_rust_char_literal_still_works
    assert_equal [N, C], flags('a.rs', "let c = '/';\n// yes\n")
  end

  def test_sql_double_dash
    assert_equal [C, N], flags('q.sql', "-- note\nSELECT 1;\n")
  end

  def test_sql_double_dash_inside_a_string
    assert_equal [N], flags('q.sql', "SELECT '-- no' AS s;\n")
  end

  def test_html_comment
    assert_equal [N, C, N], flags('a.html', "<div>\n<!-- note -->\n</div>\n")
  end

  def test_css_universal_selector_is_not_a_comment
    assert_equal [N, N, N], flags('a.css', "* {\n  margin: 0;\n}\n")
  end

  def test_java_multiplication_continuation_is_not_a_comment
    assert_equal [N, N, N, N], flags('A.java', "int v = a\n    * b\n    * c;\n int d = 1;\n")
  end

  def test_properties_bang_is_a_comment
    assert_equal [N, C], flags('app.properties', "key=value\n! note\n")
  end

  def test_lua_block_comment
    assert_equal [C, C, C, N], flags('a.lua', "--[[\n  body\n]]\nlocal x = 1\n")
  end
end
