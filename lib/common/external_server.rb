require_relative "logging"

class ExternalServer
    attr_reader :address, :port

    def initialize(address, port)
      @address = address
      @port = port
    end

    def send_request(path, data)
      uri = URI("http://#{@address}:#{@port}/#{path}")
      res = Net::HTTP.post_form(uri, data)
      if res.is_a?(Net::HTTPSuccess)
        info "Successfully sent request to #{uri}: #{data}"
        true
      else
        # 🔴 `error` is puts + `exit false`, so one refused command used to kill the whole batch —
        # a submit over ten PRs died on the first the train rejected and the other nine never went.
        # The body carries the server's reason; dropping it left "something failed" and nothing else.
        warning "Failed to send request to #{uri}: #{res.code} #{res.message} — #{res.body.to_s.strip}"
        false
      end
    end

    def is_connectable?
      begin
        socket = TCPSocket.new(@address, @port)
        socket.close
        true
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
        # 🔴 `error` is puts + `exit false`, so this used to KILL the caller — every gutils task
        # that reached a stopped PR Train died here instead of skipping, and `if_connectable`'s
        # whole else-branch was unreachable. The `false` below never got a chance to return.
        warning "Connection to #{@address}:#{@port} failed: #{e.class}: #{e.message}"
        false
      end
    end

    def if_connectable
      if is_connectable?
        yield self
      else
        warning "External server at #{@address}:#{@port} is not connectable. Skipping action."
      end
    end
end
