require_relative "logging"
require 'net/http'
require 'json'
require 'uri'
require 'webrick'

module TickTick
  extend self
  API_URL = "https://ticktick.com/open/"

  def get_projects
    request_ticktick('GET', 'project')
  end

  def get_project(project_id)
    request_ticktick('GET', "project/#{project_id}")
  end

  def get_project_with_data(project_id)
    request_ticktick('GET', "project/#{project_id}/data")
  end

  def create_project(name, options = {})
    body = {
      "name" => name
    }.merge(options)
    request_ticktick('POST', 'project', body)
  end

  def create_task(project_id, title, options = {})
    body = {
      "title" => title,
      "projectId" => project_id
    }.merge(options)
    request_ticktick('POST', 'task', body)
  end

  def update_task(task_id, updates = {})
    body = updates.merge({"id" => task_id})
    request_ticktick('POST', "task/#{task_id}", body)
  end

  private

  @requests = 0

  def request_ticktick(method, path, body = nil)
    @requests += 1
    if @requests > 90
      warning "Approaching TickTick API rate limit, sleeping for 60 seconds..."
      sleep 60
      @requests = 0
    end
    uri = URI("#{API_URL}v1/#{path}")
    req_class = case method.upcase
                when 'GET'
                  Net::HTTP::Get
                when 'POST'
                  Net::HTTP::Post
                when 'PUT'
                  Net::HTTP::Put
                when 'DELETE'
                  Net::HTTP::Delete
                else
                  raise "Unsupported HTTP method: #{method}"
                end
    req = req_class.new(uri)
    req['Authorization'] = "Bearer #{token}"
    req['Content-Type'] = 'application/json'
    req.body = body.to_json unless body.nil?
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(req)
    end
    handle_ticktick_response(res)
  end

  def handle_ticktick_response(res)
    case res.code.to_i
    when 200
      begin
        JSON.parse(res.body)
      rescue JSON::ParserError
        error "Failed to parse JSON response: #{res.body}"
      end
    when 401
      error "Unauthorized: Invalid or expired token."
    when 403
      error "Forbidden: You do not have permission to access this resource."
    when 404
      error "Not Found: The requested resource does not exist."
    else
      error "Unexpected response code #{res.code}: #{res.body}"
    end
  end

  def token
    if ENV["TICKTICK_TOKEN"]
      return ENV["TICKTICK_TOKEN"]
    end
    token_file = File.join(Dir.home, ".ticktick_token")
    if File.exist?(token_file)
      File.read(token_file).strip
    else
      warning "TickTick token file not found at #{token_file}! Generating..."
      generate_token(token_file)
    end
  end

  def generate_token(token_file)
    cliet_id = ENV['TICKTICK_CLIENT_ID']
    client_secret = ENV['TICKTICK_CLIENT_SECRET']
    if cliet_id.nil? || client_secret.nil?
      error "TICKTICK_CLIENT_ID and TICKTICK_CLIENT_SECRET environment variables must be set to generate a token."
    end

    server = WEBrick::HTTPServer.new(Port: 8090, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    code = nil
    server.mount_proc '/' do |req, res|
      code = req.query['code']
      res.body = "You can close this window now."
      server.shutdown
    end
    Thread.new { server.start }
    auth_url = "https://ticktick.com/oauth/authorize?scope=tasks:write%20tasks:read&client_id=#{cliet_id}&state=state&redirect_uri=http://localhost:8090/&response_type=code"

    `open "#{auth_url}"`
    info "Please authorize the application in your browser..."


    timeout = 120
    start_time = Time.now
    while code.nil?
      if Time.now - start_time > timeout
        error "Timeout waiting for authorization code."
      end
      sleep 1
    end
    info "Authorization code received."

    uri = URI("https://ticktick.com/oauth/token")
    req = Net::HTTP::Post.new(uri)
    req.basic_auth cliet_id, client_secret
    req.set_form_data({
      "code" => code,
      "grant_type" => "authorization_code",
      "scope" => "tasks:write tasks:read",
      "redirect_uri" => "http://localhost:8090/"
    })
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(req)
    end
    if res.code.to_i != 200
      error "Failed to get access token: #{res.code} #{res.body}"
    end
    data = JSON.parse(res.body)
    access_token = data["access_token"]
    File.open(token_file, 'w') do |file|
      file.write(access_token)
    end
    info "Access token saved to #{token_file}"
    access_token
  end
end
