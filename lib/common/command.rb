# frozen_string_literal: true

module Command
  Result = Struct.new(:out, :err, :status, :timed_out) do
    def ok? = !timed_out && status&.success? == true
    def timed_out? = timed_out
  end

  class Unavailable < StandardError; end

  GRACE = 1

  class << self
    attr_writer :runner

    def run(*argv, chdir: nil, env: {}, stdin: nil, timeout: nil, stderr: :capture)
      opts = { chdir: chdir, env: env, stdin: stdin, timeout: timeout, stderr: stderr }
      return @runner.call(argv, **opts) if @runner

      launch(argv, **opts)
    end

    private

    def launch(argv, chdir:, env:, stdin:, timeout:, stderr:)
      raise Errno::ENOENT, chdir if chdir && !File.directory?(chdir)

      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe if stderr == :capture
      in_r, in_w = IO.pipe if stdin
      opts = { out: out_w, in: in_r || File::NULL }
      opts[:err] = { capture: err_w, merge: [:child, :out], discard: File::NULL }.fetch(stderr) unless stderr == :inherit
      opts[:chdir] = chdir if chdir
      opts[:pgroup] = true if timeout
      begin
        pid = Process.spawn(env, [argv.first, argv.first], *argv.drop(1), **opts)
      rescue Errno::ENOENT => e
        [out_r, err_r, in_w].compact.each(&:close)
        raise Unavailable, e.message
      ensure
        [out_w, err_w, in_r].compact.each(&:close)
      end
      readers = [out_r, err_r].map { |io| io && Thread.new { io.binmode.read.force_encoding(Encoding.default_external).tap { io.close } } }
      Thread.new { feed(in_w, stdin) } if in_w
      status, timed_out = wait(pid, timeout)
      out, err = readers.map { |reader| reader ? reader.value : +'' }
      Result.new(out, err, status, timed_out)
    end

    def feed(io, data)
      io.write(data)
    rescue Errno::EPIPE
      nil
    ensure
      io.close
    end

    def wait(pid, timeout)
      waiter = Process.detach(pid)
      return [waiter.value, false] if timeout.nil? || waiter.join(timeout)

      signal('TERM', pid)
      signal('KILL', pid) unless waiter.join(GRACE)
      [waiter.value, true]
    end

    def signal(name, pid)
      Process.kill(name, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
