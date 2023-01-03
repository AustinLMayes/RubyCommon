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

def root_branches
  gamedev = Dir.pwd.include? "Gamedev"
  one_ninteen = Dir.pwd.include? "1.19"
  branches = []
  branches << "production-gameframework" if gamedev
  branches << "master-1.19" if one_ninteen
  branches << "production"
  branches << "main"
  branches << "master"
  branches << "dev"
  branches
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
