require 'json'

module HumanJson
    extend self

    def edit(path, &block)
        json_data = File.read(path)
       
        i = 0
        # Replace the comments and other non-essential whitespace with placeholders
        json_data_with_placeholders = json_data.gsub(/(\s*(?:#|\/\/).*$)|(^\s*$)/) do |match|
            # Use a placeholder string that includes the original comment
            "\"__PLACEHOLDER#{i+=1}__\": \"#{escape(match)}\",\n"
        end

        # Parse the JSON data with placeholders
        parsed_data = JSON.parse(json_data_with_placeholders, :symbolize_names => true)

        # Call the block with the parsed data
        yield parsed_data

        formatted_json = JSON.pretty_generate(parsed_data)

        puts formatted_json

        formatted_json_with_comments = formatted_json.gsub(/"__PLACEHOLDER\d+__": "(.*?)",\n/) do |match|
            # Extract the placeholder type and data from the matched string
            placeholder_data = match.match(/"__(PLACEHOLDER)\d+__": "(.*?)",\n/)[2]
            unescape(placeholder_data) + "\n"
        end
      
        # Write the modified JSON data back to the file
        File.open(path, 'w') do |file|
            file.write(formatted_json_with_comments + "\n")
        end
    end

    def escape(str)
        puts "Escaping #{str}"
        # Escape all newline, space, and tab characters
        str = Regexp.escape(str)
        puts "Escaped #{str}"
        str
    end

    def unescape(str)
        puts "Unescaping #{str}"
        # Replace all newline, space, and tab characters with placeholders
        str = str.gsub(/\\r/, "\r").gsub(/\\n/, "\n").gsub(/\\t/, "\t").gsub(/\\s/, " ")
        puts "Unescaped #{str}"
        str
    end
end