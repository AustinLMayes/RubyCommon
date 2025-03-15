require_relative "logging"
require 'net/http'
require 'json'

module DataPacket
  extend self

  URL = "https://api.datapacket.com/v0/graphql"

  GET_SERVERS_GQL = <<~GQL
    query Servers($pageIndex: Int, $powerStatus_in: [PowerStatus!]) {
      servers(input: {pageIndex: $pageIndex, pageSize: 50, filter: {powerStatus_in: $powerStatus_in}}) {
        entries {
          alias
          location {
            name
          }
          network {
            ipAddresses {
              ip
              isPrimary
            }
          }
          powerStatus
        }
        isLastPage
        nextPageIndex
      }
    } 
  GQL

  def online_servers
    servers.select { |server| server["powerStatus"] == "ON" }
  end

  def servers
    servers = []
    pageIndex = 0
    loop do
      res = call_graphql(GET_SERVERS_GQL, {pageIndex: pageIndex, powerStatus_in: %w[ON UNKNOWN OFF] })
      res["servers"]["entries"].each do |server|
        servers << server
      end
      break if res["servers"]["isLastPage"]
      pageIndex = res["servers"]["nextPageIndex"]
    end
    servers
  end

  private

  def call_graphql(query, variables = {})
    uri = URI(URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    headers = {
      "Content-Type" => "application/json",
      "Authorization" => "Bearer #{token}",
    }
    res = http.post(uri.path, {query: query, variables: variables}.to_json, headers)
    if res.code == "200"
      json = JSON.parse(res.body)
      if json["errors"]
        raise "Failed to call graphql: #{json["errors"]}"
      else
        json["data"]
      end
    else
      raise "Failed to call graphql: #{res.code} #{res.body}"
    end
  end

  def token
    found = ENV["DATAPACKET_TOKEN"]
    error "DATAPACKET_TOKEN environment variable not set" unless found
    found
  end
end
