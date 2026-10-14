require_relative "logging"
require_relative "git"
require 'json'
require 'octokit'
require 'shellwords'

module GitHub
    extend self

    class Error < StandardError; end

    # 🔴 Fetched on first use, not at load. As a constant this made an authenticated GitHub call
    # every time anything required this library — ten per PRTrain suite run, before a single test
    # ran, invisible to that suite's sandbox because nothing is armed at require time. It also
    # meant the library could not load at all without an authenticated `gh`.
    def github_username
      @github_username ||= `gh api user | jq -r .login`.strip
    end

    def make_pr(title, body: " ", base: nil, suffix: "", head: nil, draft: false)
      base = "production" unless base
      head ||= Git.current_branch
      full_title = "#{title} #{suffix}".strip
      info "Making PR for #{head} based off of #{base} with title #{full_title.inspect}"
      repo = Git.repo_name_with_org
      out = `gh api repos/#{repo}/pulls -X POST \
        -f title=#{full_title.shellescape} \
        -f head=#{head.shellescape} \
        -f base=#{base.shellescape} \
        -F draft=#{draft} \
        -f body=#{body.to_s.shellescape} 2>&1`
      error "Failed to create PR: #{out.strip[0, 300]}" unless $?.success?
      num = JSON.parse(out)["number"].to_s
      forget_pr_number(head)
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

    def change_pr_base(branch, base)
      num = get_pr_number(branch, only_mine: false)
      error "No PR found for #{branch}" if num.nil? || num.empty?
      info "Setting PR base to #{base} on ##{num}"
      out = `gh api repos/#{Git.repo_name_with_org}/pulls/#{num} -X PATCH -f base=#{base.shellescape} 2>&1`
      error "Failed to change PR base: #{out.strip[0, 200]}" unless $?.success?
    end

    def get_pr_number(branch, only_mine: true)
      repo = Git.repo_name_with_org
      owner = repo.split("/").first
      url = "repos/#{repo}/pulls?head=#{owner}:#{branch}&state=open&per_page=100"
      out = `gh api '#{url}' 2>/dev/null`
      return nil if out.strip.empty?
      prs = JSON.parse(out)
      prs = prs.select { |p| p.dig("user", "login") == github_username } if only_mine
      prs.empty? ? nil : prs.first["number"].to_s
    end

    def open_pr_number(branch)
      @open_pr_numbers ||= {}
      return @open_pr_numbers[branch] if @open_pr_numbers.key?(branch)
      num = get_pr_number(branch, only_mine: false)
      @open_pr_numbers[branch] = num.nil? ? nil : num.to_i
    end

    def forget_pr_number(branch)
      @open_pr_numbers&.delete(branch)
    end

    def remote_sha(branch)
      out = `git ls-remote origin refs/heads/#{branch.shellescape} 2>/dev/null`.strip
      out.empty? ? nil : out.split(/\s+/).first
    end

    def push_sha(sha, branch, force: true)
      return true if $dont_push
      args = ["git", "push", "--atomic", "--no-verify"]
      args << "--force" if force
      system(*args, "origin", "#{sha}:refs/heads/#{branch}")
    end

    PR_STATE_FIELDS = <<~GQL.gsub(/\s+/, " ").strip
      number title body state isDraft baseRefName headRefName headRefOid baseRefOid
      mergeStateStatus reviewDecision mergedAt url
      mergeCommit { oid }
      stack { number }
      reviewRequests(first: 20) { nodes { requestedReviewer {
        __typename ... on User { login } ... on Team { slug } ... on Bot { login } } } }
      reviews(last: 50) { nodes { state submittedAt author { __typename login } } }
      reviewThreads(first: 100) { nodes { id isResolved } }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    GQL

    # Number => the raw GraphQL node, for every number GitHub answered for. One request per call,
    # so keep +numbers+ to a couple of dozen; a PR that does not exist is simply absent.
    def pull_request_states(repo, numbers)
      owner, name = repo.split("/")
      aliases = numbers.map { |n| "pr#{n}: pullRequest(number: #{n.to_i}) { #{PR_STATE_FIELDS} }" }
      query = "{ repository(owner: #{owner.to_json}, name: #{name.to_json}) { #{aliases.join(" ")} } }"
      out = IO.popen(["gh", "api", "graphql", "-f", "query=#{query}"], err: [:child, :out], &:read).to_s
      # A number that no longer resolves makes gh exit 1 with the other nodes still in `data`, so
      # the exit code alone would throw away nineteen good answers for one bad one.
      parsed = begin
        JSON.parse(out)
      rescue JSON::ParserError
        raise Error, "gh api graphql failed for #{repo}: #{out.strip[0, 300]}"
      end
      nodes = parsed.dig("data", "repository")
      raise Error, "gh api graphql failed for #{repo}: #{out.strip[0, 300]}" unless nodes.is_a?(Hash)
      nodes.values.compact.each_with_object({}) { |node, h| h[node["number"]] = node }
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
        pr.user.login == github_username && pr.closed_at >= start && pr.closed_at <= e
      end
      prs += client.pull_requests(repo, sort: 'created', direction: 'desc').select do |pr|
        pr.user.login == github_username && pr.created_at >= start && pr.created_at <= e
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
