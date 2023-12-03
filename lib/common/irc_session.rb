require 'openssl'

class IRCSession
    
    @waiting_for_motd = false

    def initialize(server, port, nick, password)
        @server = server
        @port = port
        @nick = nick
        @password = password
        @ssl = port == 6697
        @callbacks = {}
        @channels = []
    end

    def connect
        raise "Already connected" if connected?
        info "Connecting to IRC server #{@server}:#{@port}"
        @waiting_for_motd = true
        @socket = nil
        if @ssl
            info "Using SSL"
            sock = TCPSocket.new(@server, @port)
            ctx = OpenSSL::SSL::SSLContext.new
            ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
            @socket = OpenSSL::SSL::SSLSocket.new(sock, ctx)
            @socket.sync_close = true
            @socket.connect
            info "SSL connection established"
        else
            @socket = TCPSocket.open(@server, @port)
        end
        # wait for connection
        sleep 1 until connected?
        send "PASS #{@password}"
        send "NICK #{@nick}"
        send "USER #{@nick} 0 * #{@nick}"
        send "USERHOST #{@nick}"
        @thread = Thread.new do
            while connected?
                handle_message_raw @socket.gets
            end
        end
        sleep 1 until !@waiting_for_motd
        info "Connected to IRC server #{@server}:#{@port}"
    end

    def connected?
        !@socket.nil? && !@socket.closed?
    end

    def disconnect
        return unless connected?
        @thread.kill if @thread != nil && @thread.alive?
        send "QUIT"
        @socket.close
        @socket = nil
        @thread = nil
        info "Disconnected from IRC server #{@server}:#{@port}"
    end

    def join(channel)
        return if @channels.include?(channel)
        send "JOIN #{channel}"
        @channels << channel
    end

    def part(channel)
        return unless @channels.include?(channel)
        send "PART #{channel}"
        @channels.delete channel
    end

    def send_message(channel, msg)
        temp_join = !@channels.include?(channel)
        join channel if temp_join
        send "PRIVMSG #{channel} :#{msg}"
        part channel if temp_join
    end

    def on_message(channel, &block)
        @callbacks[channel] ||= []
        @callbacks[channel] << block
        if connected? && !@callbacks[channel].nil? && channel != "*"
            join channel
        end
    end

    private

    def handle_message_raw(line)
        debug "<- " + line
        line = line[1..-1] if line.start_with? ":"
        # handle MOTD
        if @waiting_for_motd && (line.include?("End of /MOTD command.") || line.include?("MOTD File is missing"))
            @waiting_for_motd = false
            return
        end
        if line.start_with? "PING"
            send "PONG #{line.split[1]}"
            return
        end
        parts = line.split
        if parts[1] == "PRIVMSG"
            channel = parts[2]
            msg = parts[3..-1].join(" ")[1..-1]
            handle_message(channel, msg)
        elsif parts[0] == "ERROR"
            error "IRC Error: #{line}"
        end
    end

    def handle_message(channel, msg)
        @callbacks[channel].each do |callback|
            callback.call(msg)
        end unless @callbacks[channel].nil?
        @callbacks["*"].each do |callback|
            callback.call(channel, msg)
        end unless @callbacks["*"].nil?
    end

    def send(msg)
        @socket.puts msg
        debug "-> " + msg
        sleep 0.1
    end
end

