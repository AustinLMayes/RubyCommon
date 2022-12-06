require_relative "apple_script"

module Slack
    extend self
  
    def send_message(channel, message, workspace = "CubeCraft Games")
      AppleScript.run_script(
        "tell script \"Slack\"
              send message \"#{message.downcase}\" in channel \"#{channel}\" in workspace \"#{workspace}\"
         end tell"
      )
    end
  
  end