require_relative "logging"

module GitHub
    extend self
  
    def make_pr(title, body: " ", base: nil, suffix: "")
      base = "production" unless base
      info "Making PR based off of #{base} with title \"#{title} #{suffix}\" and body \"#{body}\""
      `gh pr create --title "#{title} #{suffix}" --body "#{body}" --base #{base}`
    end
  end