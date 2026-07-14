require_relative "logging"
require_relative "git"
require 'octokit'

module GitHub
    extend self

    GITHUB_USERNAME = `gh api user | jq -r .login`.strip

    TRAIN = ExternalServer.new("localhost", 4567)
  
    def make_pr(title, body: " ", base: nil, suffix: "", head: nil, train: nil)
      base = "production" unless base
      head ||= Git.current_branch
      full_title = "#{title} #{suffix}".strip
      info "Making PR for #{head} based off of #{base} with title #{full_title.inspect}"
      repo = Git.repo_name_with_org
      out = `gh api repos/#{repo}/pulls -X POST \
        -f title=#{full_title.shellescape} \
        -f head=#{head.shellescape} \
        -f base=#{base.shellescape} \
        -f body=#{body.to_s.shellescape} 2>&1`
      error "Failed to create PR: #{out.strip[0, 300]}" unless $?.success?
      created = JSON.parse(out)
      num = created["number"].to_s
      pr_link = created["html_url"]
      TickTick.create_task(nil, "PR ##{num}: #{full_title}", {content: "[PR ##{num}](#{pr_link})"})
      TRAIN.if_connectable do |conn|
        train ||= SecureRandom.hex(4)
        conn.send_request("command", {input: "add #{train} #{repo} #{num}"})
      end
      num
    end

    def change_pr_title(branch, title)
      num = get_pr_number(branch, only_mine: false)
      error "No PR found for #{branch}" if num.nil? || num.empty?
      info "Setting PR title to #{title.inspect} on ##{num}"
      out = `gh api repos/#{Git.repo_name_with_org}/pulls/#{num} -X PATCH -f title=#{title.shellescape} 2>&1`
      error "Failed to change PR title: #{out.strip[0, 200]}" unless $?.success?
    end

    def change_pr_body(branch, body)
      num = get_pr_number(branch, only_mine: false)
      error "No PR found for #{branch}" if num.nil? || num.empty?
      info "Setting PR body on ##{num}"
      out = `gh api repos/#{Git.repo_name_with_org}/pulls/#{num} -X PATCH -f body=#{body.to_s.shellescape} 2>&1`
      error "Failed to change PR body: #{out.strip[0, 200]}" unless $?.success?
    end

    def get_pr_number(branch, only_mine: true)
      repo = Git.repo_name_with_org
      owner = repo.split("/").first
      url = "repos/#{repo}/pulls?head=#{owner}:#{branch}&state=open&per_page=100"
      out = `gh api '#{url}' 2>/dev/null`
      return nil if out.strip.empty?
      prs = JSON.parse(out)
      prs = prs.select { |p| p.dig("user", "login") == GITHUB_USERNAME } if only_mine
      prs.empty? ? nil : prs.first["number"].to_s
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
