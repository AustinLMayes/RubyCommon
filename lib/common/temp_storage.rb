module TempStorage
    extend self

    PATH = "/tmp/ts-"

    def store(key, value, expiry: nil)
        File.write "#{PATH}#{key}", value
        File.write "#{PATH}#{key}.expiry", Time.now.to_i + expiry unless expiry.nil?
    end

    def is_stored?(key)
        stored = File.exists? "#{PATH}#{key}"
        if stored && File.exists?("#{PATH}#{key}.expiry")
            expired = is_expired? key
            if expired
                File.delete "#{PATH}#{key}"
                File.delete "#{PATH}#{key}.expiry"
            end
            stored && !expired
        else
            stored
        end
    end

    def get(key)
        return nil if is_expired? key
        File.read "#{PATH}#{key}"
    end

    def get_store_time(key)
        return nil unless File.exists? "#{PATH}#{key}"
        File.mtime "#{PATH}#{key}"
    end

    def clear(key)
        File.delete "#{PATH}#{key}"
        File.delete "#{PATH}#{key}.expiry"
    end

    def clear_expired
        Dir.glob("#{PATH}*").each do |path|
            next unless path.end_with? ".expiry"
            key = path.gsub(".expiry", "").gsub(PATH, "")
            clear key if is_expired? key
        end
    end

    private

    def is_expired?(key)
        return false unless File.exists? "#{PATH}#{key}.expiry"
        File.read("#{PATH}#{key}.expiry").to_i < Time.now.to_i
    end
end
