# Load all for convenience
Dir[File.dirname(__dir__) + '/lib/common/*.rb'].each do |file|
  require "common/" + File.basename(file, File.extname(file))
end

def fix_path(path)
  if path.start_with? "~"
    path = "#{Dir.home}/#{path[1..-1]}"
  end
  path
end
