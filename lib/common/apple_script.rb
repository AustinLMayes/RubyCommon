module AppleScript
    extend self
  
    def run_script(script)
      system 'osascript', *script.split(/\n/).map { |line| ['-e', line] }.flatten
    end
  end