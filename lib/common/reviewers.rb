require "json"

# Per-org shorthand → real-handle maps for reviewer / team references.
#
# Lookup is org-scoped: `Reviewers.expand("infra", org: "teamziax")` returns
# `"teamziax/infrastructure"`; `Reviewers.expand("austin", org: "teamziax")`
# returns `"AustinLMayes"`. Unknown handles pass through unchanged.
#
# To refresh after the org's team list / membership changes:
#
#   ruby -rcommon -e 'puts Reviewers.regenerate("teamziax")'
#
# That prints the proposed TEAMS/USERS entries to STDOUT — copy the parts
# that changed back into this file. We deliberately do NOT auto-rewrite,
# so hand-tuned shorthands (e.g. `infra` for `infrastructure`) survive.
module Reviewers
  extend self

  class UnknownHandle < StandardError
    def initialize(handle, org)
      super(<<~MSG.strip)
        Unknown reviewer handle #{handle.inspect} for org #{org.inspect}.
        Not a known shorthand (Reviewers::TEAMS[#{org.inspect}] / Reviewers::USERS[#{org.inspect}]) and not a direct match for any known team slug or user login.
        If a new teammate joined or a team was renamed, refresh shorthands:
          ruby -rcommon -e 'puts Reviewers.regenerate(#{org.inspect})'
        Otherwise check for a typo.
      MSG
    end
  end

  TEAMS = {
    "teamziax" => {
      "anticheat"       => "anti-cheat",
      "cluster"    => "cluster-operations",
      "content"    => "content",
      "corp"       => "corp-infrastructure",
      "designer"   => "designer",
      "dev"        => "developers",
      "forums"     => "forums",
      "game"       => "game",
      "infra"      => "infrastructure",
      "protocol"   => "protocol",
      "web"        => "web",
    }.freeze,
  }.freeze

  USERS = {
    "teamziax" => {
      "agentk"        => "AgentK20",
      "bruce"        => "AgentK20",
      "aroze"         => "UwUAroze",
      "auri"          => "Novampr",
      "beff"          => "beff2134",
      "beth"          => "beff2134",
      "camezonda"     => "Camezonda",
      "cam"     => "Camezonda",
      "clarky"        => "Clarky2416",
      "eliza"         => "elizabuckley",
      "ethaniccc"     => "ethaniccc",
      "libraryaddict" => "libraryaddict",
      "lib" => "libraryaddict",
      "luke"          => "rubik-cube-man",
      "rubik"          => "rubik-cube-man",
      "max"       => "Zanelees",
      "nova"         => "Novua",
      "owen"          => "SupremeMortal",
      "petteri"      => "PetteriM1",
      "redned"        => "Redned235",
      "jaden"        => "Redned235",
      "shane"         => "electronicboy",
      "sulaxan"       => "Sulaxan",
      "zed"           => "GingerGeek",
    }.freeze,
  }.freeze

  # Raises UnknownHandle on no match so typos surface at the call site
  # instead of going to GitHub as a non-existent reviewer.
  def expand(handle, org:)
    return "#{org}/#{TEAMS[org][handle]}" if TEAMS.dig(org, handle)
    return USERS[org][handle] if USERS.dig(org, handle)
    return handle if USERS[org]&.values&.include?(handle)
    if handle.start_with?("#{org}/")
      slug = handle.split("/", 2)[1]
      return handle if TEAMS[org]&.values&.include?(slug)
    end
    raise UnknownHandle.new(handle, org)
  end

  def expand_all(handles, org:)
    handles.map { |h| expand(h, org: org) }
  end

  # Prints suggested hash literals after refreshing teams/members from gh.
  # Doesn't rewrite this file — hand-tuned shorthands like `infra` would be
  # clobbered. Copy only the rows you want.
  def regenerate(org)
    teams = build_team_shorthands(org)
    users = build_user_shorthands(org)

    out = +"# --- Suggested TEAMS[#{org.inspect}] ---\n"
    teams.sort.each { |k, v| out << "#{k.inspect.ljust(14)} => #{v.inspect},\n" }
    out << "\n# --- Suggested USERS[#{org.inspect}] ---\n"
    users.sort.each { |k, v| out << "#{k.inspect.ljust(14)} => #{v.inspect},\n" }
    out
  end

  def build_team_shorthands(org)
    slugs = JSON.parse(`gh api orgs/#{org}/teams --paginate`).map { |t| t["slug"] }.sort
    result = {}
    slugs.each do |slug|
      [team_short_candidate(slug), slug].uniq.each do |candidate|
        next if result.key?(candidate)
        result[candidate] = slug
        break
      end
    end
    result
  end

  def build_user_shorthands(org)
    logins = JSON.parse(`gh api orgs/#{org}/members --paginate`)
      .map { |m| m["login"] }
      .reject { |l| l.start_with?("ziax-") && l.end_with?("-robot") }
    result = {}
    logins.sort.each do |login|
      name = JSON.parse(`gh api users/#{login}`)["name"].to_s.strip
      candidate = name.empty? ? login.downcase.gsub(/\d+$/, "") : name.split(/\s+/).first.downcase
      [candidate, login.downcase].each do |c|
        next if result.key?(c)
        result[c] = login
        break
      end
    end
    result
  end

  def team_short_candidate(slug)
    return slug.split("-").first if slug.include?("-")
    return slug[0, 5] if slug.length > 8
    slug
  end
end
