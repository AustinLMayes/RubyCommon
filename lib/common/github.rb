require "logging"

module GitHub
    extend self
  
    def make_pr(title, body: " ", base: nil, suffix: nil)
      is_mco = Git.current_branch.end_with?("mco")
      base = is_mco ? "production-mco" : "production" unless base
      suffix = is_mco ? "[MCO]" : "[Java]" unless suffix
      info "Making PR based off of #{base} with title \"#{title} #{suffix}\" and body \"#{body}\""
      `gh pr create --title "#{title} #{suffix}" --body "#{body}" --base #{base}`
    end
  end