Gem::Specification.new do |s|
    s.name        = "common"
    s.version     = "1.0"
    s.platform    = Gem::Platform::RUBY
    s.authors     = ["Austin Mayes"]
    s.summary     = "Come common utils"
  
    s.required_rubygems_version = ">= 1.3.6"
  
    s.files        = Dir["{lib}/**/*.rb", "bin/*", "LICENSE", "*.md"]
    s.require_path = 'lib'

    s.add_dependency "octokit", "~> 7.0"
    s.add_dependency "mongo", "~> 2.0"
    s.add_dependency "mysql2", "~> 0.5"
    s.add_dependency "activesupport", "~> 7.0"
    s.add_dependency "net-ssh", "~> 7.0"
    # 🔴 Not a default gem since ruby 3.0, so it has to be declared like any other.
    s.add_dependency "webrick", "~> 1.8"
  end
