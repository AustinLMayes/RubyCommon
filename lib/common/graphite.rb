require "json"
require "net/http"
require "securerandom"
require "shellwords"
require "uri"
require_relative "logging"
require_relative "git"

# Three surfaces against Graphite:
#   - API:  CLI-token-authed HTTP to api.graphite.com/v1/graphite/*
#   - Web:  cookie-authed HTTP to app.graphite.com/api/v1/graphite/* (richer,
#           but the CLI token can't auth here — needs the browser session
#           captured by PRTrain's bin/graphite_session.py)
#   - CLI:  `gt --cwd <dir>` shellouts for local-working-tree operations
module Graphite
  extend self

  class Error < StandardError; end

  API_BASE = "https://api.graphite.com/v1"
  AUTH_PATH = File.expand_path("~/.config/graphite/auth")

  WEB_BASE = "https://app.graphite.com/api/v1"
  WEB_SESSION_PATH = File.expand_path("~/.config/graphite/web-session.json")
  WEB_SESSION_REFRESH_SCRIPT = File.expand_path("~/Projects/Ruby/PRTrain/bin/graphite_session.py")

  ## ----- API surface (HTTP to api.graphite.com) -----

  def token
    @token ||= JSON.parse(File.read(AUTH_PATH)).fetch("authToken")
  end

  def token_available?
    File.exist?(AUTH_PATH) && !token.to_s.empty?
  rescue
    false
  end

  def post(path, body)
    uri = URI("#{API_BASE}#{path}")
    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "token #{token}"
    req["Content-Type"] = "application/json"
    req.body = body.to_json
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 30) do |http|
      http.request(req)
    end
    unless res.is_a?(Net::HTTPSuccess)
      raise Error, "Graphite API #{path} failed: HTTP #{res.code} #{res.body.to_s[0, 200]}"
    end
    res.body.to_s.empty? ? {} : JSON.parse(res.body)
  end

  def pull_request_info(repo, pr_numbers)
    owner, name = repo.split("/")
    post("/graphite/cli/pull-request-info", {
      repoOwner: owner,
      repoName: name,
      prNumbers: pr_numbers,
      consistent: true
    })
  end

  def mergeability_status(repo, pr_numbers)
    owner, name = repo.split("/")
    post("/graphite/mergeability-status", {
      repoOwner: owner,
      repoName: name,
      prNumbers: pr_numbers
    })
  end

  # Accepts the whole stack in one call.
  def api_merge(repo, pr_numbers, trunk_branch_name:)
    owner, name = repo.split("/")
    post("/graphite/merge", {
      repoOwner: owner,
      repoName: name,
      trunkBranchName: trunk_branch_name,
      prNumbers: pr_numbers
    })
  end

  # Metadata-only when each prs[] entry carries the PR's current remote SHAs;
  # otherwise pushes. Use the current-SHA pattern from a daemon that wants to
  # set reviewers / mergeWhenReady / rerequestReview without local checkouts.
  def api_submit_update(repo, trunk_branch_name:, prs:, merge_when_ready: nil, rerequest_review: nil)
    owner, name = repo.split("/")
    body = {
      repoOwner: owner,
      repoName: name,
      trunkBranchName: trunk_branch_name,
      prs: prs,
      webSubmitAnalytics: {
        eligible: false, usedWebSubmit: false, prompted: false,
        suppressedPrompt: false, submitViaCliSetting: false
      }
    }
    body[:mergeWhenReady] = merge_when_ready unless merge_when_ready.nil?
    body[:rerequestReview] = rerequest_review unless rerequest_review.nil?
    post("/graphite/submit/pull-requests", body)
  end

  ## ----- Web surface (cookie-authed app.graphite.com/api/v1) -----

  def web_session
    return nil unless File.exist?(WEB_SESSION_PATH)
    @web_session_mtime, @web_session_cache = nil, nil if @web_session_mtime != File.mtime(WEB_SESSION_PATH)
    @web_session_mtime ||= File.mtime(WEB_SESSION_PATH)
    @web_session_cache ||= JSON.parse(File.read(WEB_SESSION_PATH))
  rescue JSON::ParserError
    nil
  end

  # Local check only — doesn't probe the server.
  def web_session_valid?
    sess = web_session
    return false unless sess
    cookies = sess["cookies"] || []
    auth = cookies.find { |c| c["name"] == "auth" }
    return false unless auth
    exp = auth["expires"]
    return true unless exp.is_a?(Numeric) && exp.positive?
    exp > Time.now.to_i
  end

  # Raises if refresh fails — caller should treat that as "user must rerun
  # `graphite_session.py login`" rather than retrying.
  def web_session_refresh!
    raise Error, "Refresh script missing: #{WEB_SESSION_REFRESH_SCRIPT}" unless File.exist?(WEB_SESSION_REFRESH_SCRIPT)
    out = `#{[WEB_SESSION_REFRESH_SCRIPT, "refresh"].shelljoin} 2>&1`
    raise Error, "graphite_session.py refresh failed (exit #{$?.exitstatus}): #{out[0, 500]}" unless $?.success?
    @web_session_mtime, @web_session_cache = nil, nil
    true
  end

  # On 401, refreshes the session once and retries before bubbling up.
  def web_get(path, params: {})
    web_request(:get, path, params: params)
  end

  def web_post(path, body)
    web_request(:post, path, body: body)
  end

  def web_request(method, path, params: {}, body: nil)
    sess = web_session
    raise Error, "No web session — run `#{WEB_SESSION_REFRESH_SCRIPT} login`" unless sess

    res = web_request_once(method, path, params: params, body: body, sess: sess)
    return parse_web_response(res) unless res.code.to_s == "401"

    info "Graphite web session 401 — refreshing"
    web_session_refresh!
    sess = web_session
    raise Error, "Session refresh ran but cookie still missing" unless sess
    res = web_request_once(method, path, params: params, body: body, sess: sess)
    raise Error, "#{method.upcase} #{path}: HTTP #{res.code} (after refresh)" unless res.is_a?(Net::HTTPSuccess)
    parse_web_response(res)
  end

  def web_sections
    web_get("/graphite/sections")
  end

  # Batched PR data for one dashboard section — previousReviewers (incl. bot
  # reviewers), requestedReviewers, unresolvedThreadCount, mergeStateStatus,
  # ciRollup, hasUnreadUpdatesForViewer.
  def web_section_prs(section_id:, sort_method: "updatedAt", sort_order: "DESC", limit: 200)
    web_get("/graphite/section/prs", params: {
      sectionId: section_id,
      sortMethod: sort_method,
      sortOrder: sort_order,
      "__first" => limit
    })
  end

  # Per-PR only — don't loop this over a train.
  def web_pull_request_timeline(repo, pr_number)
    owner, name = repo.split("/")
    web_get("/graphite/github-pr/#{owner}/#{name}/#{pr_number}/pull-request-timeline")
  end

  def web_update_pr_thread(owner, thread_id, resolved: true)
    web_post("/graphite/mutation/update-pr-thread", {
      forgeSource: "github",
      owner: owner,
      id: thread_id,
      isResolved: resolved
    })
  end

  # User logins only — endpoint rejects team slugs.
  def web_rerequest_specific_reviews(repo, pr_number, logins)
    owner, name = repo.split("/")
    web_post("/graphite/mutation/rerequest-specific-reviews", {
      forgeSource: "github",
      name: name,
      owner: owner,
      number: pr_number.to_s,
      logins: logins
    })
  end

  # rerequest-specific-reviews takes user logins only. This one accepts a team
  # slug as well, and re-fires the notification for a reviewer who has never
  # responded, which neither that mutation nor GitHub's REST POST can do.
  # Takes a single reviewer per call.
  def web_poke_reviewer(repo, pr_number, login_or_team_slug)
    owner, name = repo.split("/")
    web_post("/graphite/mutation/poke-reviewer", {
      repo: name,
      owner: owner,
      number: pr_number,
      loginOrTeamSlug: login_or_team_slug
    })
  end

  ## ----- CLI surface (gt shellouts) -----

  # gt writes its state files into the SHARED git dir, so a plain
  # File.join(dir, ".git", ...) is wrong inside a git worktree, where `.git` is
  # a file holding a `gitdir:` pointer rather than a directory. Resolving via
  # `--git-common-dir` gives the shared dir for both a normal clone and a
  # worktree. Returns nil when +dir+ isn't a git repo at all.
  def git_state_path(dir, filename)
    common = `git -C #{dir.to_s.shellescape} rev-parse --git-common-dir 2>/dev/null`.strip
    return nil if common.empty?
    File.join(File.expand_path(common, dir), filename)
  end

  # Reads the trunk branch name from the repo's local Graphite config
  # (`.graphite_repo_config` in the shared git dir). Returns nil if gt has never
  # been initialized in this clone.
  def trunk(dir = Dir.pwd)
    config_path = git_state_path(dir, ".graphite_repo_config")
    return nil if config_path.nil? || !File.exist?(config_path)
    JSON.parse(File.read(config_path))["trunk"]
  rescue JSON::ParserError
    nil
  end

  # True iff +dir+ has been initialized with `gt init` (i.e. has a Graphite
  # repo config file).
  def initialized?(dir = Dir.pwd)
    path = git_state_path(dir, ".graphite_repo_config")
    !path.nil? && File.exist?(path)
  end

  # gt rewrites this file after each submit/sync; treat it as authoritative
  # only for branches gt has actually seen since the last submit.
  def local_pr_info(dir = Dir.pwd)
    path = git_state_path(dir, ".graphite_pr_info")
    return {} if path.nil? || !File.exist?(path)
    JSON.parse(File.read(path))
  rescue JSON::ParserError
    {}
  end

  def local_pr_numbers(dir = Dir.pwd)
    (local_pr_info(dir)["prInfos"] || []).each_with_object({}) do |info, hash|
      hash[info["headRefName"]] = info["prNumber"]
    end
  end

  # "already merging" / "already merged" are returned as success since they
  # mean the merge has already started (typically via merge-when-ready).
  def merge(dir = Dir.pwd, branch:)
    Dir.chdir(dir) { Git.checkout_branch(branch) }
    out = `#{["gt", "--cwd", dir, "--no-interactive", "merge"].shelljoin} 2>&1`
    return true if $?.success?
    return true if out =~ /already merg(?:ed|ing)/i
    raise Error, "gt merge failed: #{out[0, 500]}"
  end

  # team_reviewers entries are GitHub team slugs (server resolves them to
  # "org/slug"). The named branch must already be gt-tracked.
  def submit(dir = Dir.pwd, branch: nil, reviewers: nil, team_reviewers: nil,
             merge_when_ready: false, rerequest_review: false, force: false,
             always: false, draft: nil, stack: false)
    Dir.chdir(dir) { Git.safe_checkout(branch) } if branch
    args = []
    args += ["--reviewers", Array(reviewers).join(",")] if reviewers && !Array(reviewers).empty?
    args += ["--team-reviewers", Array(team_reviewers).join(",")] if team_reviewers && !Array(team_reviewers).empty?
    args << "--merge-when-ready" if merge_when_ready
    args << "--rerequest-review" if rerequest_review
    args << "--force" if force
    args << "--always" if always
    args << "--draft" if draft == true
    args << "--publish" if draft == false
    args << "--stack" if stack
    run!(dir, "submit", *args)
    true
  end

  def sync(dir = Dir.pwd)
    run!(dir, "sync")
    true
  end

  # For programmatic stack order prefer reading the branch-metadata refs.
  def log_short(dir = Dir.pwd)
    capture(dir, "log", "short")
  end

  def mergeability(dir = Dir.pwd, branch:)
    Dir.chdir(dir) { Git.checkout_branch(branch) }
    if system("gt", "--cwd", dir, "--no-interactive", "--quiet", "merge", "--dry-run",
              out: File::NULL, err: File::NULL)
      :ready
    else
      :not_ready
    end
  end

  ## ----- private -----

  # Returns the raw Net::HTTPResponse so the caller can branch on 401.
  def web_request_once(method, path, params: {}, body: nil, sess:)
    uri = URI.parse("#{WEB_BASE}#{path}")
    uri.query = URI.encode_www_form(params) unless params.empty?
    req = case method
          when :get  then Net::HTTP::Get.new(uri.request_uri)
          when :post then Net::HTTP::Post.new(uri.request_uri)
          else raise ArgumentError, "Unsupported HTTP method: #{method}"
          end
    req["Cookie"] = cookie_header_for(sess, uri)
    req["Accept"] = "*/*"
    req["Accept-Language"] = "en-US,en;q=0.9"
    req["Referer"] = "https://app.graphite.com/"
    req["User-Agent"] = sess["userAgent"] || "Mozilla/5.0"
    req["Sec-Fetch-Site"] = "same-origin"
    req["Sec-Fetch-Mode"] = "cors"
    req["Sec-Fetch-Dest"] = "empty"
    req["x-graphite-fetch-context"] = "initial"
    req["X-Graphite-Page-Status"] = "ACTIVE"
    req["X-Graphite-Tab"] = (@web_tab_id ||= SecureRandom.uuid)
    req["X-Graphite-Client-Request-Id"] = SecureRandom.uuid
    if body
      req["Content-Type"] = "text/plain"
      req["Origin"] = "https://app.graphite.com"
      # Required — POSTs 401 with "invalid-csrf-token" otherwise.
      csrf = sess["csrfToken"]
      req["X-CSRF-TOKEN"] = csrf if csrf
      req.body = body.to_json
    end
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 30) do |http|
      http.request(req)
    end
  end

  def parse_web_response(res)
    raise Error, "GET failed: HTTP #{res.code} #{res.body.to_s[0, 200]}" unless res.is_a?(Net::HTTPSuccess)
    res.body.to_s.empty? ? {} : JSON.parse(res.body)
  end

  def cookie_header_for(sess, uri)
    host = uri.host.to_s
    path = uri.path.to_s
    (sess["cookies"] || []).filter_map do |c|
      cdomain = c["domain"].to_s.sub(/\A\./, "")
      next nil unless host == cdomain || host.end_with?(".#{cdomain}")
      cpath = c["path"].to_s
      next nil unless cpath.empty? || cpath == "/" || path.start_with?(cpath)
      "#{c['name']}=#{c['value']}"
    end.join("; ")
  end

  def run!(dir, *args)
    cmd = ["gt", "--cwd", dir, "--no-interactive"] + args
    return if system(*cmd)
    raise Error, "Command failed: #{cmd.shelljoin}"
  end

  def capture(dir, *args)
    cmd = ["gt", "--cwd", dir] + args
    out = `#{cmd.shelljoin}`
    raise Error, "Command failed: #{cmd.shelljoin}" unless $?.success?
    out
  end
end
