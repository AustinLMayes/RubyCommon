require "mysql2"

class MysqlSession

    attr_reader :host, :user, :password

    def initialize(host, user, password)
        @host = host
        @user = user
        @password = password
    end

    def create_session(port: 3306, &block)
        begin
            db = Mysql2::Client.new(host: @host, username: @user, password: @password, port: port)
            block.call db
        rescue Mysql2::Error => e
            error "Error #{e.errno}: #{e.error}"
        ensure
            db.close
        end
    end
end