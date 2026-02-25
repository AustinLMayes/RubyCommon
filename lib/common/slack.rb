require_relative "apple_script"

module Slack
    extend self

    TOKEN = ENV['SLACK_API_TOKEN']

    @groups = nil
    @users = nil
    @channels = nil

    attr_writer :groups, :users, :channels

    def send_message(channel, text)
      call_slack_api('chat.postMessage', {
        channel: channel,
        text: text
      })
    end

    def schedule_message(channel, text, post_at)
      info "Scheduling message to #{channel} at #{Time.at(post_at).strftime("%Y-%m-%d %H:%M:%S")}: #{text}"
      res = call_slack_api('chat.scheduleMessage', {
        channel: channel,
        text: text,
        post_at: post_at.to_i
      })
      info "Scheduled message with ID #{res['scheduled_message_id']}"
    end

    def delete_scheduled_message(channel, scheduled_message_id)
      call_slack_api('chat.deleteScheduledMessage', {
        channel: channel,
        scheduled_message_id: scheduled_message_id
      })
    end

    def list_scheduled_messages
      call_slack_api('chat.scheduledMessages.list', {})['scheduled_messages'].map do |msg|
        {
          id: msg['id'],
          channel: @channels.find { |_, v| v == msg['channel_id'] }&.first,
          text: msg['text'],
          post_at: Time.at(msg['post_at']).strftime("%Y-%m-%d %H:%M:%S")
        }
      end
    end

    def chan_id(name)
      object_id(name, "channels", "#")
    end

    def user_id(name)
      object_id(name, "users", "@")
    end

    def group_id(name)
      object_id(name, "groups", "")
    end

    module Markdown
      module Mentions
        extend self

        def user(name)
          "<@#{Slack.user_id(name)}>"
        end

        def channel(name)
          "<##{Slack.chan_id(name)}>"
        end

        def group(name)
          "<!subteam^#{Slack.group_id(name)}|#{name}>"
        end

        def everyone
          "<!everyone>"
        end

        def here
          "<!here>"
        end

        def parse(text)
          text = text.gsub(/u:([a-zA-Z0-9._-]+)/) { user($1) }
          text = text.gsub(/c:([a-zA-Z0-9._-]+)/) { channel($1) }
          text = text.gsub(/g:([a-zA-Z0-9._-]+)/) { group($1) }
          text = text.gsub(/@everyone/) { everyone }
          text = text.gsub(/@here/) { here }
          text
        end
      end

      module Formatting
        extend self

        def bold(text)
          "*#{text}*"
        end

        def italic(text)
          "_#{text}_"
        end

        def strikethrough(text)
          "~#{text}~"
        end

        def code(text)
          "`#{text}`"
        end

        def preformatted(text)
          "```#{text}```"
        end
      end

      module Links
        extend self

        def link(text, url)
          "<#{url}|#{text}>"
        end
      end

      module Lists
        extend self

        def unordered(items)
          items.map do |item|
            if item.is_a?(Array)
              "- #{item[0]}\n  #{unordered(item[1..-1])}"
            else
              "- #{item}"
            end
          end
        end

        def ordered(items)
          items.each_with_index.map do |item, index|
            if item.is_a?(Array)
              "#{index + 1}. #{item[0]}\n   #{ordered(item[1..-1])}"
            else
              "#{index + 1}. #{item}"
            end
          end
        end
      end
    end

    private

    def object_id(name, collection, prefix)
      raise "#{collection} not loaded" unless instance_variable_get("@#{collection}")
      res = instance_variable_get("@#{collection}")[name.delete_prefix(prefix)]
      raise "#{collection.singularize.capitalize} #{name} not found! Options: #{instance_variable_get("@#{collection}").keys.map { |k| prefix + k.to_s }.join(', ')}" unless res
      res
    end

    def call_slack_api(method, params)
      raise("SLACK_API_TOKEN not set") unless TOKEN
      uri = URI("https://slack.com/api/#{method}")
      req = Net::HTTP::Post.new(uri)
      req['Authorization'] = "Bearer #{TOKEN}"
      req['Content-Type'] = 'application/json; charset=utf-8'
      req.body = params.to_json

      res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(req)
      end

      unless res.is_a?(Net::HTTPSuccess)
        raise "Slack API request failed with code #{res.code}: #{res.body}"
      end

      JSON.parse(res.body)
    end
  
  end
