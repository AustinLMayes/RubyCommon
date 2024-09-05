module AppleScript
    extend self
  
    def run_script(script)
      system 'osascript', *script.split(/\n/).map { |line| ['-e', line] }.flatten
    end

    def notification(title, text, sound = "Funk")
      script = "display notification \"#{text}\" with title \"#{title}\" sound name \"#{sound}\""
      run_script(script)
    end

    def alert(title, text, buttons = ["OK"], default_button = "OK")
      script = "display dialog \"#{text}\" with title \"#{title}\" buttons {\"#{buttons.join('", "')}\"} default button \"#{default_button}\""
      run_script(script)
    end
  end
