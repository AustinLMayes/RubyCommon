require 'net/ssh'
require_relative 'logging'

class SshTunnel

    def initialize(host, user, internal_host, internal_port, key_path, &block)
        local_port = 20000 + rand(10000)
        tunnel = fork do
            exec "ssh -nN -L #{local_port}:#{internal_host}:#{internal_port} #{user}@#{host} -i #{key_path}"
        end
        Process.detach(tunnel)
        sleep 2
        block.call local_port
    ensure
        Process.kill('HUP', tunnel) if tunnel
    end
end