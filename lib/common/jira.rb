# Jira API wrapper for Ruby

require "base64"
require 'rest-client'
require 'json'
require 'active_support/core_ext/hash/keys'

module Jira
    extend self
  
    API_URL = ENV['JIRA_API_URL']
    API_USER = ENV['JIRA_API_USER']
    API_TOKEN = ENV['JIRA_API_TOKEN']
    ENCODED_AUTH = Base64.strict_encode64("#{API_USER}:#{API_TOKEN}")
    AUSTIN_ACC_ID = ENV['JIRA_ACC_ID']

    UTILS_PATH = ENV['JIRA_UTILS_PATH'] || "/Users/austinmayes/Projects/Ruby/RubyCommon/utils"

    def ensure_api_vars
      missing = []
      missing << "JIRA_API_URL" if API_URL.nil? || API_URL.empty?
      missing << "JIRA_API_USER" if API_USER.nil? || API_USER.empty?
      missing << "JIRA_API_TOKEN" if API_TOKEN.nil? || API_TOKEN.empty?
      missing << "JIRA_ACC_ID" if AUSTIN_ACC_ID.nil? || AUSTIN_ACC_ID.empty?
      if missing.any?
        raise "Missing required environment variables: #{missing.join(', ')}"
      end
    end

    def get(url, api: "api", version: "latest")
      ensure_api_vars
      where = API_URL.gsub("@API@", api).gsub("@VERSION@", version) + url
      debug "GET #{where}..."
      res = JSON.parse(RestClient.get(where, {"Authorization": "Basic #{ENCODED_AUTH}", content_type: :json, accept: :json}).body)
      res
    end
  
    def patch(url, data, api: "api", version: "latest")
      ensure_api_vars
      where = API_URL.gsub("@API@", api).gsub("@VERSION@", version) + url
      debug "PATCH #{where} (data:#{data})..."
      begin
        return JSON.parse(RestClient.patch(where, data, {"Authorization": "Basic #{ENCODED_AUTH}", content_type: :json, accept: :json}).body)
      rescue => e
        puts e.response
        exit(false)
      end
    end
  
    def put(url, data, api: "api", version: "latest")
      ensure_api_vars
      where = API_URL.gsub("@API@", api).gsub("@VERSION@", version) + url
      debug "PUT #{where} (data:#{data})..."
      res = RestClient.put(where, data, {"Authorization": "Basic #{ENCODED_AUTH}", content_type: :json, accept: :json}).body
      if res.strip.empty?
        return {}
      end
      JSON.parse(res)
    end
  
    def post(url, data, ignored_errors: [], api: "api", version: "latest")
      ensure_api_vars
      where = API_URL.gsub("@API@", api).gsub("@VERSION@", version) + url
      debug "POST #{where} (data:#{data})..."
      begin
          res = RestClient.post(where, data, {"Authorization": "Basic #{ENCODED_AUTH}", content_type: :json, accept: :json})
          return nil if res.body.strip.empty?
          return JSON.parse(res.body)
      rescue => e
        ignored_errors.each do |f|
          if e.response.include?("\"#{f}\":")
            puts e.response + " (IGNORED)"
            return
          end
        end
        puts e.response
        raise e
      end
      nil
    end

    # TODO: Move these outside of base API
    module CC
        extend self
        PROJECT_ID = 10014
        EPIC_ISSUE_TYPE = 10000
        STORY_ISSUE_TYPE = 10001
        TASK_ISSUE_TYPE = 10002
        SUB_TASK_ISSUE_TYPE = 10003
        BUG_ISSUE_TYPE = 10004
        BOARD_ID = 14
        SPRINT_FIELD = "customfield_10020"
        TEAM_ALLOCATION_FIELD = "customfield_10039"

        module TeamAllocations
            extend self
            GAME_DEV = 10021
            PROD_OPS = 10024
            LIBRARY_DEV = 10128
            ROCKET = 10027
        end
    end

    module Sprints
        extend self

        def current(project_id)
            Jira.get("board/#{project_id}/sprint?state=active&maxResults=1", api: "agile")['values'][0]
        end

        def next(project_id)
            Jira.get("board/#{project_id}/sprint?state=future&maxResults=1", api: "agile")['values'][0]
        end
    end

    module CustomFields
        extend self

        def get(id)
            Jira.get("customFieldOption/#{id}")
        end
    end

    module Issues
        extend self

        def get(id)
            Jira.get "issue/#{id}"
        end

        def transitions(id)
            Jira.get "issue/#{id}/transitions"
        end

        def transition(id, transition_id)
            info "Transitioning issue #{id} with transition #{transition_id}..."
            Jira.post "issue/#{id}/transitions", {transition: {id: transition_id}}.to_json
        end

        def add_to_sprint(id, sprint_id)
            Jira.post "sprint/#{sprint_id}/issue", {issues: [id]}.to_json, api: "agile"
        end

        def add_to_current_sprint(id, board_id)
            sprint = Jira::Sprints.current(board_id)
            raise "No current sprint" if sprint.nil?
            add_to_sprint(id, sprint['id'])
        end

        def add_comment(id, comment)
            Jira.post "issue/#{id}/comment", {body: comment}.to_json
        end

        def create_meta
            pp Jira.get "issue/createmeta"
        end

        def create_multi(issues, parent, board_id, assignee: Jira::AUSTIN_ACC_ID)
            updates = []
            issues.each do |issue|
                update = {
                    fields: {
                        reporter: {id: Jira::AUSTIN_ACC_ID},
                        assignee: {id: assignee},
                        summary: issue[:parent],
                        issuetype: {id: Jira::CC::SUB_TASK_ISSUE_TYPE},
                        project: {id: Jira::CC::PROJECT_ID},
                        parent: {key: parent},
                        # "#{Jira::CC::SPRINT_FIELD}": sprint['id'],
                        "#{Jira::CC::TEAM_ALLOCATION_FIELD}": [{id: Jira::CC::TeamAllocations::GAME_DEV.to_s}]
                    }
                }
                update[:fields][:description] = issue[:description] unless issue[:description].nil? || issue[:description].empty?
                updates << update
            end
            created = Jira.post("issue/bulk", {issueUpdates: updates}.to_json, version: "3")['issues']
            puts "Created: #{created}"
            updates = []
            i = -1
            issues.each do |issue|
                i+=1
                raise "Can't find created issues #{i}" if created[i].nil?
                next if issue[:children].empty?
                issue[:children].each do |child|
                    updates << {
                        fields: {
                            reporter: {id: Jira::AUSTIN_ACC_ID},
                            assignee: {id: Jira::AUSTIN_ACC_ID},
                            summary: child,
                            issuetype: {id: Jira::CC::SUB_TASK_ISSUE_TYPE},
                            project: {id: Jira::CC::PROJECT_ID},
                            parent: {key: created[i]['key']},
                            "#{Jira::CC::TEAM_ALLOCATION_FIELD}": [{id: Jira::CC::TeamAllocations::GAME_DEV.to_s}]
                        }
                    }
                end
            end
            created << Jira.post("issue/bulk", {issueUpdates: updates}.to_json)['issues']
            created.each do |issue|
                next if issue.nil?
                # Jira.post("issue/#{issue['key']}/transitions", {transition: {id: 11}}.to_json)
            end
        end

        def create(epic, summary, type: :task, assignee: AUSTIN_ACC_ID)
          type_id = case type
                    when :task
                      Jira::CC::TASK_ISSUE_TYPE
                    when :story
                      Jira::CC::STORY_ISSUE_TYPE
                    when :bug
                      Jira::CC::BUG_ISSUE_TYPE
                    else
                      error "Unknown issue type: #{type}. Must be one of :task, :story, :bug"
                    end
            data = {
                fields: {
                  reporter: {id: Jira::AUSTIN_ACC_ID},
                  assignee: {id: assignee},
                  summary: summary,
                  issuetype: {id: type_id},
                  project: {id: Jira::CC::PROJECT_ID},
                  parent: {key: epic}
                },
                transition: {
                  id: 2
                }
            }
            res = Jira.post("issue", data.to_json)
            raise "Failed to create issue: #{res}" if res.nil? || res['errors']
            res
        end

        def search(jql, fields: ["*all"])
            res = Jira.post("search/jql", {jql: jql, fields: fields}.to_json)
            issues = []
            issues += res['issues']
            while res['nextPageToken']
                res = Jira.post("search/jql", {jql: jql, fields: fields, nextPageToken: res['nextPageToken']}.to_json)
                issues += res['issues']
            end
            issues
        end

        def add_label(id, label)
            Jira.put("issue/#{id}", {update: {labels: [{add: label}]}}.to_json)
        end

        def remove_label(id, label)
            Jira.put("issue/#{id}", {update: {labels: [{remove: label}]}}.to_json)
        end

        def assign(id, to = AUSTIN_ACC_ID)
            current = Jira.get("issue/#{id}")
            return if !current['fields']['assignee'].nil? && current['fields']['assignee']['accountId'] == to
            Jira.put("issue/#{id}/assignee", {accountId: to}.to_json)
        end
    end

    def to_adf(text)
        return text if text.nil? || text.empty?
        JSON.parse(`node #{UTILS_PATH}/md_to_adf.mjs '#{text}'`.strip)
    end
  end
