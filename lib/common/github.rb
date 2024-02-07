require_relative "logging"
require_relative "git"
require 'octokit'

module GitHub
    extend self

    GITHUB_USERNAME = "AustinLMayes"
  
    def make_pr(title, body: " ", base: nil, suffix: "")
      base = "production" unless base
      info "Making PR based off of #{base} with title \"#{title} #{suffix}\" and body \"#{body}\""
      `gh pr create --title "#{title} #{suffix}" --body "#{body}" --base #{base}`
    end

    def get_auth_token
      warning "Using your GitHub auth token to perform actions on your behalf."
      `gh auth token`
    end

    @client = nil

    def get_client
      if @client == nil
        @client = Octokit::Client.new(:access_token => get_auth_token)
      end
      return @client
    end

    def prs_in_time_range(repo, start, e = Time.now)
      client = get_client
      prs = []
      seen_before = false
      page = 1
      while true
        puts "Getting page #{page}..."
        prs += client.pull_requests(repo, state: 'closed', sort: 'created', direction: 'desc', page: page).select do |pr|
          seen_before = true if pr.created_at < start
          pr.user.login == GITHUB_USERNAME
        end
        page += 1
        break if seen_before
      end
      page = 1
      seen_before = false
      while true
        puts "Getting page #{page}..."
        in_range = client.pull_requests(repo, sort: 'created', direction: 'desc', page: page)
        break if in_range.empty?
        prs += in_range.select do |pr|
          seen_before = true if pr.created_at < start
          pr.user.login == GITHUB_USERNAME
        end
        page += 1
        break if seen_before
      end
      return prs
    end

    def lines_changed_in_pr(pr)
      client = get_client
      files = client.pull_request_files(pr.base.repo.full_name, pr.number)
      files.sum(&:changes)
    end

    def commits(pr)
      client = get_client
      commits = client.pull_request_commits(pr.base.repo.full_name, pr.number)
      commits
    end

    def lines_changed_in_commit(repo, commit)
      client = get_client
      files = client.commit(repo, commit.sha).files
      files.sum(&:changes)
    end
  end