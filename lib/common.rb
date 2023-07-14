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
  branches = []
  branches << "production"
  branches << "main"
  branches << "master"
  branches << "dev"
  branches
end

def base_branches
  branches = ["main", "dev", "production", "master", "staging"]
  branches
end
