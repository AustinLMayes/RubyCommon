require "ansi"

def info(*msg)
    puts "#{Ansi.green "[INFO]"} #{msg.join(" ")}"
end

def warning(msg)
    puts "#{Ansi.yellow "[WARNING]"} #{msg}"
end

def error(msg)
    puts "#{Ansi.red "[ERROR]"} #{msg}"
    exit false
end