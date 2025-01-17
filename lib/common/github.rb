require_relative "logging"
require_relative "git"
require 'octokit'

module GitHub
    extend self

    GITHUB_USERNAME = `gh api user | jq -r .login`.strip
  
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
      client.auto_paginate = true
      prs = []
      prs += client.pull_requests(repo, state: 'closed', sort: 'created', direction: 'desc').select do |pr|
        pr.user.login == GITHUB_USERNAME && pr.closed_at >= start && pr.closed_at <= e
      end
      prs += client.pull_requests(repo, sort: 'created', direction: 'desc').select do |pr|
        pr.user.login == GITHUB_USERNAME && pr.created_at >= start && pr.created_at <= e
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

    def lines_changed_in_commit(repo, sha)
      client = get_client
      files = client.commit(repo, sha).files
      files.sum(&:changes)
    end
  end
