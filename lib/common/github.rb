require_relative "logging"
require_relative "git"
require 'json'

module GitHub
    extend self

    class Error < StandardError; end

    # 🔴 Fetched on first use, not at load. As a constant this made an authenticated GitHub call
    # every time anything required this library — ten per PRTrain suite run, before a single test
    # ran, invisible to that suite's sandbox because nothing is armed at require time. It also
    # meant the library could not load at all without an authenticated `gh`.
    def github_username
      @github_username ||= gh("api", "user", "--jq", ".login").out.strip
    end

    def gh(*args, json: false, stderr: :inherit, fail_open: true, **opts)
      result = begin
        Command.run("gh", *args, stderr: stderr, **opts)
      rescue Command::Unavailable => e
        raise unless fail_open

        Command::Result.new(+"", e.message, nil, false)
      end
      json ? JSON.parse(result.out) : result
    end

    def stream(*args)
      system("gh", *args)
    end

    def make_pr(title, body: " ", base: nil, suffix: "", head: nil, draft: false, repo: nil)
      base = "production" unless base
      head ||= Git.current_branch
      full_title = "#{title} #{suffix}".strip
      info "Making PR for #{head} based off of #{base} with title #{full_title.inspect}"
      result = gh("api", "repos/#{repo || Git.repo_name_with_org}/pulls", "-X", "POST",
                  "-f", "title=#{full_title}",
                  "-f", "head=#{head}",
                  "-f", "base=#{base}",
                  "-F", "draft=#{draft}",
                  "-f", "body=#{body}", stderr: :merge)
      error "Failed to create PR: #{result.out.strip[0, 300]}" unless result.ok?
      num = JSON.parse(result.out)["number"].to_s
      forget_pr_number(head, repo: repo)
      num
    end

    def change_pr_title(branch, title, repo: nil)
      num, repo = pr_for(branch, repo)
      info "Setting PR title to #{title.inspect} on ##{num}"
      patch_pr(repo, num, "title", title)
    end

    def change_pr_body(branch, body, repo: nil)
      num, repo = pr_for(branch, repo)
      info "Setting PR body on ##{num}"
      patch_pr(repo, num, "body", body)
    end

    def change_pr_base(branch, base, repo: nil)
      num, repo = pr_for(branch, repo)
      info "Setting PR base to #{base} on ##{num}"
      patch_pr(repo, num, "base", base)
    end

    def get_pr_number(branch, only_mine: true, repo: nil)
      repo ||= Git.repo_name_with_org
      owner = repo.split("/").first
      url = "repos/#{repo}/pulls?head=#{owner}:#{branch}&state=open&per_page=100"
      out = gh("api", url, stderr: :discard).out
      return nil if out.strip.empty?
      prs = JSON.parse(out)
      prs = prs.select { |p| p.dig("user", "login") == github_username } if only_mine
      prs.empty? ? nil : prs.first["number"].to_s
    end

    def open_pr_number(branch, repo: nil)
      @open_pr_numbers ||= {}
      key = [repo, branch]
      return @open_pr_numbers[key] if @open_pr_numbers.key?(key)
      num = get_pr_number(branch, only_mine: false, repo: repo)
      @open_pr_numbers[key] = num.nil? ? nil : num.to_i
    end

    def forget_pr_number(branch, repo: nil)
      @open_pr_numbers&.delete([repo, branch])
    end

    def remote_sha(branch, dir: nil)
      out = Git.run(dir, "ls-remote", "origin", "refs/heads/#{branch}", stderr: :discard).out.strip
      out.empty? ? nil : out.split(/\s+/).first
    end

    def push_sha(sha, branch, force: true, dir: nil)
      return true if $dont_push
      Git.stream(dir, "push", "--atomic", "--no-verify", *("--force" if force), "origin", "#{sha}:refs/heads/#{branch}")
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
      out = gh("api", "graphql", "-f", "query=#{query}", stderr: :merge).out
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
      gh("auth", "token").out
    end

    @client = nil

    def get_client
      if @client == nil
        require 'octokit'
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

    private

    def pr_for(branch, repo)
      repo ||= Git.repo_name_with_org
      num = get_pr_number(branch, only_mine: false, repo: repo)
      error "No PR found for #{branch}" if num.nil? || num.empty?
      [num, repo]
    end

    def patch_pr(repo, num, field, value)
      result = gh("api", "repos/#{repo}/pulls/#{num}", "-X", "PATCH", "-f", "#{field}=#{value}", stderr: :merge)
      error "Failed to change PR #{field}: #{result.out.strip[0, 200]}" unless result.ok?
    end
  end
