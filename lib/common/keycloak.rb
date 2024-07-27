require 'net/http'
require 'json'

class Keycloak
  attr_reader :url, :client_id, :client_secret, :realm

  def initialize(url, client_id, client_secret, realm)
    @url = url
    @client_id = client_id
    @client_secret = client_secret
    @realm = realm
  end

  def get_bearer_from_user_pass(username, password)
    response = Net::HTTP.post_form(URI.parse("#{url}/auth/realms/#{realm}/protocol/openid-connect/token"), {
      "client_id" => client_id,
      "client_secret" => client_secret,
      "grant_type" => "password",
      "username" => username,
      "password" => password
    })

    if response.code == "200"
      JSON.parse(response.body)["access_token"]
    else
      raise "Failed to get access token: #{response.code} #{response.body}"
    end
  end

  def get_bearer_from_client_credentials
    response = Net::HTTP.post_form(URI.parse("#{url}/auth/realms/#{realm}/protocol/openid-connect/token"), {
      "client_id" => client_id,
      "client_secret" => client_secret,
      "grant_type" => "client_credentials"
    })

    if response.code == "200"
      res = JSON.parse(response.body)
      error "Token type is #{res["token_type"]}" if res["token_type"] != "Bearer"
      res["access_token"]
    else
      raise "Failed to get access token: #{response.code} #{response.body}"
    end
  end
end
