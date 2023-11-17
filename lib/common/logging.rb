require_relative "ansi"

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

$debug = false

def enable_debug
    $debug = true
end

def debug(*msg)
    return unless $debug
    puts "#{Ansi.blue "[DEBUG]"} #{msg.join(" ")}"
end