# Load all for convenience
Dir[File.dirname(__dir__) + '*.rb'].each do |file| 
  next if file.end_with? "common.rb"
  require File.basename(file, File.extname(file))
end

def fix_path(path)
  if path.start_with? "~"
    path = "#{Dir.home}/#{path[1..-1]}"
  end
  path
end

def base_branches
  branches = ["gamedevnet", "gamedevnet-mco", "main", "dev"]
  %w(master production).each do |branch|
    branches << branch
    branches << branch + "-mco"
    branches << branch + "-gameframework"
    branches << branch + "-gameframework-mco"
    branches << branch + "-1.19"
  end
  branches
end
