# frozen_string_literal: true

require_relative "paths"

module ZiaxUtils
  extend self

  class Error < StandardError; end

  def root = Paths.ziax_utils

  def require!(*files, quiet: false)
    $LOAD_PATH.unshift(root) unless $LOAD_PATH.include?(root)
    stderr = $stderr.dup if quiet
    $stderr.reopen(File.open(File::NULL, "w")) if quiet
    Dir.chdir(root) { files.each { |file| require File.join(root, file) } }
  ensure
    $stderr.reopen(stderr) if stderr
  end

  def rocket_client(env)
    line = File.read(File.join(root, "zutils.rb"))[/^\s*#{env}: (RocketClient\.new\(.*\)),?\s*$/, 1]
    raise Error, "no #{env}: RocketClient line in #{root}/zutils.rb" unless line

    require!("rocket_client", quiet: true)
    eval(line, TOPLEVEL_BINDING)
  end
end
