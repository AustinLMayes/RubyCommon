# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'stringio'
require 'tmpdir'
require_relative '../lib/common/cli'

class CliTest < Minitest::Test
  Boom = Class.new(StandardError)
  Busy = Class.new(StandardError)

  def program(status: nil, banner: nil, &block)
    Class.new do
      include Cli::Program
      program 'tool'
      banner banner if banner
      usage_status status if status
      class_eval(&block) if block
    end
  end

  def call(klass, *argv, stdin: '')
    out = StringIO.new
    err = StringIO.new
    code = klass.new(out: out, err: err, env: {}, stdin: StringIO.new(stdin)).run(argv)
    [code, out.string, err.string]
  end

  def sample
    program(banner: "tool — does things\n\n  tool <domain> <verb>\n") do
      domain 'job', 'jobs'
      verb('job', 'add', label: 'Add', summary: 'add one', usage: 'tool job add <slug> [--at <when>]',
                         defaults: { at: 'now' }) do |cli, argv|
        cli.out.puts argv.join(',')
        0
      end
      root('init', label: 'Init', summary: 'make it', usage: 'tool init') { |cli, _| cli.out.puts 'made' }
    end
  end

  def test_root_and_domain_verbs_dispatch_with_defaults_filled
    klass = sample
    klass.root('zero', label: 'Z', summary: 'z', usage: 'tool zero') { 0 }
    assert_equal [0, "x,--at,now\n", ''], call(klass, 'job', 'add', 'x')
    assert_equal [0, "x,--at,later\n", ''], call(klass, 'job', 'add', 'x', '--at', 'later')
    assert_equal 0, call(klass, 'zero').first
  end

  def test_a_handler_that_returns_no_integer_raises
    assert_raises(TypeError) { call(sample, 'init') }
  end

  def test_help_walks_the_registry_on_stdout
    code, out, err = call(sample, 'job', '--help')
    assert_equal 0, code
    assert_equal '', err
    assert_equal <<~TXT, out
      tool — does things

        tool <domain> <verb>

        job          jobs
          add        add one
            tool job add <slug> [--at <when>]
            defaults to --at now

        init         make it
            tool init
    TXT
    assert_equal call(sample, '--help'), call(sample)
  end

  def test_help_without_a_banner_starts_at_the_registry
    klass = program { domain 'job', 'jobs' }
    assert_equal "  job          jobs\n\n", call(klass, '-h')[1]
  end

  def test_unknown_names_print_what_exists_at_the_usage_status
    assert_equal [2, '', <<~TXT], call(sample, 'nope')
      tool: unknown domain or verb "nope"
          domains: job
          verbs:   init
          run `tool --help`
    TXT
    assert_equal [2, '', <<~TXT], call(sample, 'job')
      tool: job needs a verb
          verbs: add
          run `tool --help`
    TXT
    assert_equal [2, '', <<~TXT], call(sample, 'job', 'frob')
      tool: job has no verb "frob"
          verbs: add
          run `tool --help`
    TXT
  end

  def test_usage_status_is_per_program
    klass = program(status: 1) { root('x', label: 'X', summary: 'x', usage: 'tool x') { |cli, _| cli.usage_error('tool x') } }
    assert_equal [1, '', "tool: tool x\n"], call(klass, 'x')
    assert_equal 1, call(klass, 'nope').first
  end

  def test_fallthrough_runs_before_the_unknown_name_error
    klass = program do
      define_method(:fallthrough) { |head, argv| head == 'ext' ? argv.length : nil }
    end
    assert_equal 2, call(klass, 'ext', 'a', 'b').first
    assert_equal 2, call(klass, 'other').first
    assert_includes call(klass, 'other')[2], 'unknown domain or verb'
  end

  def test_on_error_handlers_match_in_order_and_others_raise
    klass = program do
      on_error(Boom) { |e| err.puts "first #{e.message}"; 5 }
      on_error(StandardError) { |e| err.puts "second #{e.message}"; 6 }
      root('boom', label: 'B', summary: 'b', usage: 'tool boom') { raise Boom, 'b' }
      root('busy', label: 'B', summary: 'b', usage: 'tool busy') { raise Busy, 'c' }
    end
    assert_equal [5, '', "first b\n"], call(klass, 'boom')
    assert_equal [6, '', "second c\n"], call(klass, 'busy')

    bare = program { root('busy', label: 'B', summary: 'b', usage: 'tool busy') { raise Busy, 'c' } }
    assert_raises(Busy) { call(bare, 'busy') }
  end

  def test_die_prints_and_returns_its_code
    klass = program { root('d', label: 'D', summary: 'd', usage: 'tool d') { Cli.die!('gone', 7) } }
    assert_equal [7, '', "gone\n"], call(klass, 'd')
    klass.root('e', label: 'E', summary: 'e', usage: 'tool e') { Cli.die!('gone') }
    assert_equal Cli::FAILED, call(klass, 'e').first
  end

  def test_registration_refuses_collisions_and_missing_words
    klass = sample
    assert_raises(Cli::NameCollision) { klass.root('job', label: 'X', summary: 'x', usage: 'x') { 0 } }
    assert_raises(Cli::NameCollision) { klass.domain('init', 'x') }
    assert_raises(Cli::NameCollision) { klass.domain('job', 'x') }
    assert_raises(Cli::NameCollision) { klass.verb('nope', 'x', label: 'X', summary: 'x', usage: 'x') { 0 } }
    assert_raises(Cli::NameCollision) { klass.verb('job', 'add', label: 'X', summary: 'x', usage: 'x') { 0 } }
    assert_raises(Cli::NameCollision) { klass.root('init', label: 'X', summary: 'x', usage: 'x') { 0 } }
    assert_raises(ArgumentError) { klass.root('bare', summary: 'x', usage: 'x') { 0 } }
    assert_equal %w[job init], klass.registry.keys
  end

  def test_a_default_is_checked_against_the_usage_at_registration
    raised = assert_raises(Cli::Defaults::Refused) do
      sample.verb('job', 'bad', label: 'B', summary: 'b', usage: 'tool job bad [--json]', defaults: { json: 'x' })
    end
    assert_equal 'tool job bad: json is a flag, which cannot carry a default', raised.message
  end

  def test_take_options_and_expect_no_more
    cli = sample.new(out: StringIO.new, err: err = StringIO.new)
    argv = %w[a --at 1 b]
    assert_equal({ 'at' => '1' }, cli.take_options(argv, %w[--at]))
    assert_equal %w[a b], argv
    assert_equal 'needs a value', assert_raises(Cli::MissingOptionValue) { cli.take_options(%w[--at], %w[--at]) }.message[/needs a value/]
    assert_match(/given twice \("1" then "2"\)/, assert_raises(Cli::MissingOptionValue) { cli.take_options(%w[--at 1 --at 2], %w[--at]) }.message)
    assert cli.expect_no_more!([])
    refute cli.expect_no_more!(%w[x y], 'tool job add <slug>')
    assert_equal "tool: unexpected arguments: x y\n    tool job add <slug>\n    run `tool --help`\n", err.string
  end

  def test_an_option_error_from_a_handler_is_a_usage_error
    klass = program(status: 1) { root('t', label: 'T', summary: 't', usage: 'tool t') { |cli, argv| cli.take_options(argv, %w[--x]) } }
    assert_equal [1, '', "--x needs a value\n"], call(klass, 't', '--x')
  end

  def test_body_from
    cli = sample.new(stdin: StringIO.new('piped'))
    assert_equal '', cli.body_from(nil)
    assert_equal 'piped', cli.body_from('-')
    assert_match(/needs --body-file/, assert_raises(Cli::BodyUnreadable) { cli.body_from(nil, required: true) }.message)
    assert_equal 'no body file at /no/such', assert_raises(Cli::BodyUnreadable) { cli.body_from('/no/such') }.message
    Dir.mktmpdir do |dir|
      blank = File.join(dir, 'blank')
      File.write(blank, "  \n")
      assert_equal "  \n", cli.body_from(blank)
      assert_match(/body is empty/, assert_raises(Cli::BodyUnreadable) { cli.body_from(blank, required: true) }.message)
    end
    binary = sample.new(stdin: StringIO.new((+"\xff").force_encoding('UTF-8')))
    assert_match(/not valid UTF-8/, assert_raises(Cli::BodyUnreadable) { binary.body_from('-') }.message)
  end

  def test_invalid_body_message_is_the_programs_to_word
    klass = program { define_method(:invalid_body_message) { 'binary: use attach' } }
    cli = klass.new(stdin: StringIO.new((+"\xff").force_encoding('UTF-8')))
    assert_equal 'binary: use attach', assert_raises(Cli::BodyUnreadable) { cli.body_from('-') }.message
  end

  def test_usage_parse_reads_the_program_off_the_usage
    parsed = Cli::Usage.parse('tool pr unpause <repo> <number> | tool pr unpause all', words: 2)
    assert_equal %w[repo number], parsed.params.map(&:name)
    assert_equal %w[all], parsed.literals
    kinds = Cli::Usage.parse('ax job add <slug> [--limit <n>] [--json] (--a X | --b Y) [--w a|b] [reason...]', words: 2)
                      .params.map { |p| [p.name, p.kind, p.required] }
    assert_equal [['slug', :positional, true], ['limit', :number, false], ['json', :flag, false],
                  ['a-or-b', :one_of, true], ['w', :enum, false], ['reason', :prose, false]], kinds
    assert_raises(Cli::Usage::Unparsable) { Cli::Usage.parse('tool x {bad}', words: 1) }
  end

  def test_defaults_fill_positionals_before_flags_and_spell
    command = Cli::Command.new(usage: 'tool test thing [--limit <n>] [<spread>]', defaults: { 'spread' => '1m', 'limit' => '5' })
    assert_equal %w[1m --limit 5], Cli::Defaults.fill(command, 2, [])
    assert_equal %w[--limit 3 1m], Cli::Defaults.fill(command, 2, %w[--limit 3])
    assert_equal '<spread> 1m  --limit 5', Cli::Defaults.spell(command, 2)
  end

  def test_main_exits_with_the_code
    script = <<~RUBY
      require #{File.expand_path('../lib/common/cli', __dir__).inspect}
      class T
        include Cli::Program
        program 't'
        root('x', label: 'X', summary: 'x', usage: 't x') { 3 }
      end
      Cli.main(T)
    RUBY
    _out, status = Open3.capture2e(RbConfig.ruby, '--disable-gems', '-e', script, 'x')
    assert_equal 3, status.exitstatus
  end
end
