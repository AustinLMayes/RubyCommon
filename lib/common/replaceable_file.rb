require 'fileutils'

class ReplaceableFile
    attr_reader :path, :data

    def initialize(path, data)
        @path = path
        @data = data
        raise "File does not exist" unless File.exists? path
    end

    def replace(&block)
        contents = File.read(@path)
        new_contents = contents
        @data.each do |find, rep|
            new_contents = new_contents.gsub("||#{find.upcase}||", rep)
        end

        tmp_path = "/tmp/replaceable"

        File.open(tmp_path, "w") {|file| file.puts new_contents }
        block.call tmp_path
        FileUtils.rm(tmp_path)
    end
end