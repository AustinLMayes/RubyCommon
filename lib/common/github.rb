require_relative "logging"
require_relative "git"
require 'octokit'

module GitHub
    extend self

    GITHUB_USERNAME = `gh api user | jq -r .login`.strip

    TRAIN = ExternalServer.new("localhost", 4567)
  
    def make_pr(title, body: " ", base: nil, suffix: "", head: nil, train: nil)
      base = "production" unless base
      info "Making PR for #{head == nil ? Git.current_branch : head} based off of #{base} with title \"#{title} #{suffix}\" and body \"#{body}\""
      res = system "gh", "pr", "create", "--title", "#{title} #{suffix}", "--body", body, "--base", base, "--head", head == nil ? Git.current_branch : head
      error "Failed to create PR" unless res
      sleep 5 # wait a bit for GitHub to register the new PR
      num = get_pr_number(head == nil ? Git.current_branch : head)
      if num.nil? || num.empty? || !(num =~ /^\d+$/)
        warning "Could not get PR number after creation! PR creation result: #{res} Head: #{head == nil ? Git.current_branch : head} Num: #{num}"
        sleep 5
        num = get_pr_number(head == nil ? Git.current_branch : head)
        if num.nil? || num.empty? || !(num =~ /^\d+$/)
          error "Still could not get PR number after waiting! Something went wrong with PR creation. Please check manually. Head: #{head == nil ? Git.current_branch : head} Num: #{num}"
          return nil
        end
      end
      pr_link = `gh pr view #{num} --json url --jq '.url'`.strip
      TickTick.create_task(nil, "PR ##{num}: #{title} #{suffix}", {content: "[PR ##{num}](#{pr_link})"})
      TRAIN.if_connectable do |conn|
        train ||= SecureRandom.hex(4)
        conn.send_request("command", {input: "add #{train} #{Git.repo_name_with_org} #{num}"})
      end
      num
    end

    def change_pr_base(branch, base)
      previous_base = get_pr_base(branch)
      if previous_base == base
        info "PR base already set to #{base} for #{branch}"
        return
      end
      info "Changing PR base to #{base} for #{branch}"
      # system "gh" "pr", "edit", branch, "--base", base
      `gh pr edit #{branch} --base #{base}`
    end

    def change_pr_title(branch, title)
      previous_title = get_pr_title(branch)
      if previous_title == title
        info "PR title already set to #{title} for #{branch}"
        return
      end
      info "Changing PR title to #{title}"
      res = system "gh", "pr", "edit", branch, "--title", title
      error "Failed to change PR title" unless res
    end

    def get_pr_title(branch)
      title = `gh pr view #{branch} --json title --jq '.title'`
      if title.empty?
        nil
      else
        title.strip
      end
    end

    def get_pr_base(branch)
      base = `gh pr view #{branch} --json baseRefName --jq '.baseRefName'`
      if base.empty?
        nil
      else
        base.strip
      end
    end

    def get_pr_number(branch, only_mine: true)
      author_filter = only_mine ? "-A #{GITHUB_USERNAME}" : ""
      pr = `gh pr list #{author_filter} --json number,headRefName --jq '.[] | select(.headRefName == "#{branch}") | .number' --limit=100`
      if pr.empty?
        nil
      else
        pr.strip
      end
    end

    def get_my_prs
      prs = `gh pr list -A #{GITHUB_USERNAME} --json number,headRefName,url --limit=100`
      prs = JSON.parse(prs)
      prs.map do |pr|
        {branch: pr["headRefName"], number: pr["number"], url: pr["url"]}
      end
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
