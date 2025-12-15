require "mongo"

class MongoSession

    attr_reader :host, :user, :password, :auth_db

    def initialize(host, user, password, auth_db: "admin")
        @host = host
        @user = user
        @password = password
        @auth_db = auth_db
    end

    def create_session(port: 27017, ssl: true, &block)
        begin
            db = Mongo::Client.new(["#{@host}:#{port}"], user: @user, password: @password, ssl: ssl, auth_source: @auth_db)
            db = db.use(@auth_db)
            block.call db
        rescue Mongo::Error => e
            error "MongoDB Error: #{e.message}"
        ensure
            db.close if db
        end
    end
end
