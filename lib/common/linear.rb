# Linear API wrapper for Ruby (replaces the legacy Jira module).
#
# Linear is GraphQL-only: one endpoint, a single personal API key, no REST paths,
# no JQL, no workflow "transitions" (you set an issue's stateId directly), and
# bodies/comments are plain markdown (no ADF). Issue identifiers are per-team,
# e.g. CCENG-75 (CubeCraft Engineering) / ROC-146 (Rocket Engineering).

require "json"
require "net/http"
require "uri"
require_relative "logging"

module Linear
  extend self

  class Error < StandardError; end

  ENDPOINT = "https://api.linear.app/graphql"
  API_KEY = ENV["LINEAR_API_KEY"]

  AUSTIN_USER_ID = "c2d28e7c-0733-4892-9196-a4c169704d80"

  TEAMS = {
    "CCENG" => "CubeCraft Engineering",
    "ROC"   => "Rocket Engineering",
  }.freeze

  def ensure_api_key
    raise Error, "Missing required environment variable: LINEAR_API_KEY" if API_KEY.nil? || API_KEY.empty?
  end

  def api_available?
    !API_KEY.nil? && !API_KEY.empty?
  end

  def query(graphql, variables = {})
    ensure_api_key
    uri = URI(ENDPOINT)
    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = API_KEY
    req["Content-Type"] = "application/json"
    req.body = { query: graphql, variables: variables }.to_json
    debug "Linear GraphQL #{graphql.strip.split("\n").first}..."
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 30) do |http|
      http.request(req)
    end
    unless res.is_a?(Net::HTTPSuccess)
      raise Error, "Linear API failed: HTTP #{res.code} #{res.body.to_s[0, 300]}"
    end
    parsed = JSON.parse(res.body)
    if parsed["errors"]
      raise Error, "Linear GraphQL errors: #{parsed["errors"].map { |e| e["message"] }.join("; ")}"
    end
    parsed["data"]
  end

  def parse_identifier(identifier)
    m = identifier.to_s.match(/\A([A-Z]+)-(\d+)\z/)
    raise Error, "Not a Linear issue identifier: #{identifier.inspect}" unless m
    [m[1], m[2].to_i]
  end

  module Teams
    extend self

    def by_key(key)
      @cache ||= {}
      return @cache[key] if @cache.key?(key)
      data = Linear.query(<<~GQL, { key: key })
        query($key: String!) {
          teams(filter: { key: { eq: $key } }, first: 1) {
            nodes {
              id key name
              states { nodes { id name type position } }
              activeCycle { id number }
            }
          }
        }
      GQL
      node = data.dig("teams", "nodes", 0)
      raise Error, "No Linear team with key #{key}" if node.nil?
      @cache[key] = node
    end

    def id(key)
      by_key(key)["id"]
    end

    def state_id(key, state_name)
      states = by_key(key).dig("states", "nodes")
      exact = states.find { |s| s["name"].casecmp?(state_name) }
      return exact["id"] if exact
      partial = states.find { |s| s["name"].downcase.include?(state_name.downcase) }
      raise Error, "No state matching #{state_name.inspect} in team #{key} (have: #{states.map { |s| s["name"] }.join(", ")})" if partial.nil?
      partial["id"]
    end

    def active_cycle_id(key)
      by_key(key).dig("activeCycle", "id")
    end
  end

  module Labels
    extend self

    def id(name, team_key: nil)
      @cache ||= {}
      ck = [name, team_key]
      return @cache[ck] if @cache.key?(ck)
      data = Linear.query(<<~GQL, { name: name })
        query($name: String!) {
          issueLabels(filter: { name: { eq: $name } }, first: 20) {
            nodes { id name team { key } }
          }
        }
      GQL
      nodes = data.dig("issueLabels", "nodes") || []
      pick = nodes.find { |n| team_key && n.dig("team", "key") == team_key } ||
             nodes.find { |n| n["team"].nil? } ||
             nodes.first
      @cache[ck] = pick&.fetch("id", nil)
    end
  end

  module Users
    extend self

    def by_email(email)
      @cache ||= {}
      return @cache[email] if @cache.key?(email)
      data = Linear.query(<<~GQL, { email: email })
        query($email: String!) {
          users(filter: { email: { eq: $email } }, first: 1) { nodes { id name email displayName } }
        }
      GQL
      @cache[email] = data.dig("users", "nodes", 0)
    end

    def id_for_email(email)
      by_email(email)&.fetch("id", nil)
    end
  end

  ISSUE_FIELDS = <<~GQL.freeze
    id identifier number title description url
    state { id name type }
    assignee { id name email displayName }
    team { id key name }
    parent { id identifier }
    labels { nodes { id name } }
    children { nodes { id } }
  GQL

  module Issues
    extend self

    def get(identifier)
      key, number = Linear.parse_identifier(identifier)
      data = Linear.query(<<~GQL, { key: key, number: number })
        query($key: String!, $number: Float!) {
          issues(filter: { team: { key: { eq: $key } }, number: { eq: $number } }, first: 1) {
            nodes { #{ISSUE_FIELDS} }
          }
        }
      GQL
      data.dig("issues", "nodes", 0)
    end

    def state_name(identifier)
      get(identifier)&.dig("state", "name")
    end

    def set_state(identifier, state_name)
      issue = get(identifier)
      raise Error, "Issue not found: #{identifier}" if issue.nil?
      key = issue.dig("team", "key")
      state_id = Linear::Teams.state_id(key, state_name)
      return issue if issue.dig("state", "id") == state_id
      info "Setting #{identifier} -> #{state_name}"
      update(issue["id"], { stateId: state_id })
    end

    def update(issue_uuid, input)
      data = Linear.query(<<~GQL, { id: issue_uuid, input: input })
        mutation($id: String!, $input: IssueUpdateInput!) {
          issueUpdate(id: $id, input: $input) { success issue { #{ISSUE_FIELDS} } }
        }
      GQL
      res = data["issueUpdate"]
      raise Error, "issueUpdate failed for #{issue_uuid}" unless res && res["success"]
      res["issue"]
    end

    def add_comment(identifier, markdown)
      issue = get(identifier)
      raise Error, "Issue not found: #{identifier}" if issue.nil?
      data = Linear.query(<<~GQL, { input: { issueId: issue["id"], body: markdown } })
        mutation($input: CommentCreateInput!) {
          commentCreate(input: $input) { success comment { id } }
        }
      GQL
      raise Error, "commentCreate failed for #{identifier}" unless data.dig("commentCreate", "success")
      data.dig("commentCreate", "comment")
    end

    def assign(identifier, user_id = Linear::AUSTIN_USER_ID)
      issue = get(identifier)
      raise Error, "Issue not found: #{identifier}" if issue.nil?
      return issue if issue.dig("assignee", "id") == user_id
      update(issue["id"], { assigneeId: user_id })
    end

    def add_label(identifier, label_id)
      issue = get(identifier)
      ids = (issue.dig("labels", "nodes") || []).map { |l| l["id"] }
      update(issue["id"], { labelIds: (ids + [label_id]).uniq })
    end

    def remove_label(identifier, label_id)
      issue = get(identifier)
      ids = (issue.dig("labels", "nodes") || []).map { |l| l["id"] }
      update(issue["id"], { labelIds: ids - [label_id] })
    end

    def add_to_current_cycle(identifier)
      issue = get(identifier)
      key = issue.dig("team", "key")
      cycle_id = Linear::Teams.active_cycle_id(key)
      if cycle_id.nil?
        warning "No active cycle for team #{key}; skipping cycle assignment for #{identifier}"
        return issue
      end
      update(issue["id"], { cycleId: cycle_id })
    end

    def create(team_key:, title:, description: nil, parent_id: nil, project_id: nil, assignee_id: AUSTIN_USER_ID, state: nil, label_ids: nil)
      input = { teamId: Linear::Teams.id(team_key), title: title, assigneeId: assignee_id }
      input[:description] = description if description && !description.empty?
      input[:parentId] = parent_id if parent_id
      input[:projectId] = project_id if project_id
      input[:stateId] = Linear::Teams.state_id(team_key, state) if state
      input[:labelIds] = label_ids if label_ids
      data = Linear.query(<<~GQL, { input: input })
        mutation($input: IssueCreateInput!) {
          issueCreate(input: $input) { success issue { #{ISSUE_FIELDS} } }
        }
      GQL
      res = data["issueCreate"]
      raise Error, "issueCreate failed: #{title}" unless res && res["success"]
      res["issue"]
    end

    def search(filter, first: 100)
      issues = []
      cursor = nil
      loop do
        data = Linear.query(<<~GQL, { filter: filter, first: first, after: cursor })
          query($filter: IssueFilter, $first: Int!, $after: String) {
            issues(filter: $filter, first: $first, after: $after) {
              nodes { #{ISSUE_FIELDS} }
              pageInfo { hasNextPage endCursor }
            }
          }
        GQL
        issues += data.dig("issues", "nodes")
        page = data.dig("issues", "pageInfo")
        break unless page["hasNextPage"]
        cursor = page["endCursor"]
      end
      issues
    end
  end
end
