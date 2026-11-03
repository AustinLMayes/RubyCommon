require_relative "kube"
require_relative "logging"
require_relative "mysql_session"

class KubeMysqlSession

    def initialize(context, namespace, cluster)
        @context = context
        @namespace = namespace
        @cluster = cluster
    end

    def create_session(&block)
        tunnel do |port, user, password|
            MysqlSession.new("127.0.0.1", user, password).create_session(port: port, &block)
        end
    end

    def tunnel
        user, password = credentials
        argv = Kube.argv("port-forward", "svc/#{@cluster}-haproxy", ":3306", tool: :kubectl, context: @context, namespace: @namespace)
        IO.popen(argv, err: [:child, :out]) do |forward|
            begin
                line = forward.gets.to_s
                port = line[/127\.0\.0\.1:(\d+)/, 1]
                error "Failed to port-forward #{@cluster}: #{line.strip}" unless port
                yield port.to_i, user, password
            ensure
                Process.kill("TERM", forward.pid)
            end
        end
    end

    private

    def credentials
        secret = Kube.json("get", "secret", "#{@cluster}-psuser-root", tool: :kubectl, context: @context, namespace: @namespace)
        %w(user password).map { |key| secret.fetch("data").fetch(key).unpack1("m0") }
    end
end
