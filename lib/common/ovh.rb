require_relative "logging"
require_relative "temp_storage"
require 'net/http'
require 'json'
require 'active_support/time'

module OVH
  extend self

  URL = "https://eu.api.ovh.com/1.0/"

  OVH_APP_KEY = ENV['OVH_APP_KEY']
  OVH_APP_SECRET = ENV['OVH_APP_SECRET']
  OVH_CONSUMER_KEY = ENV['OVH_CONSUMER_KEY']

  # x.x.x.x/xx
  V4_PATTERN = /\A((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\/([0-9]|[1-2][0-9]|3[0-2]))\z/
  V6_PATTERN = /\A([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}(\/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))\z/

  def servers
    servers = get("dedicated/server")
    servers_rich = {}
    servers.each do |srv|
      srv_info = get("dedicated/server/#{srv}")
      ips = get("dedicated/server/#{srv}/ips")
      v4_ips = ips.select { |ip| ip =~ V4_PATTERN }.map { |ip| ip.split('/').first }
      v6_ips = ips.select { |ip| ip =~ V6_PATTERN }.map { |ip| ip.split('/').first }
      srv_info['ips'] = ips
      srv_info['v4_ips'] = v4_ips
      srv_info['v6_ips'] = v6_ips
      srv_info['id'] = srv
      srv_info['name'] = srv_info['iam']['displayName']
      srv_info['hardware'] = get("dedicated/server/#{srv}/specifications/hardware")
      servers_rich[srv_info['iam']['displayName']] = srv_info
    end
    servers_rich
  end

  def get_fresh(path, query: nil)
    TempStorage.clear("ovh.api.get.#{path}.#{query}")
    get(path, query: query)
  end

  def get(path, query: nil)
    if TempStorage.is_stored?("ovh.api.get.#{path}.#{query}")
      return JSON.parse(TempStorage.get("ovh.api.get.#{path}.#{query}"))
    end
    url = URI.join(URL, path)
    url.query = URI.encode_www_form(query) if query && !query.empty?

    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true

    req = Net::HTTP::Get.new(url)
    set_request_headers(req, "GET", url, "")

    res = http.request(req)
    jr = JSON.parse(res.body)
    TempStorage.store("ovh.api.get.#{path}.#{query}", res.body, expiry: 12.hours)
    jr
  end

  def put(path, body: {})
    url = URI.join(URL, path)

    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true

    body_str = body.to_json
    req = Net::HTTP::Put.new(url)
    set_request_headers(req, "PUT", url, body_str)
    req.body = body_str

    res = http.request(req)
    JSON.parse(res.body)
  end

  def post(path, body: {})
    url = URI.join(URL, path)

    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true

    body_str = body.to_json
    req = Net::HTTP::Post.new(url)
    set_request_headers(req, "POST", url, body_str)
    req.body = body_str

    res = http.request(req)
    JSON.parse(res.body)
  end

  def delete(path)
    url = URI.join(URL, path)

    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true

    req = Net::HTTP::Delete.new(url)
    set_request_headers(req, "DELETE", url, "")

    res = http.request(req)
    if res.is_a?(Net::HTTPSuccess)
      true
    else
      warning "Failed to delete resource at #{url}: #{res.code} #{res.message}"
      false
    end
  end

  private

  def ovh_signature(method, full_url, tstamp, body_str)
    raise "missing OVH_APP_SECRET or OVH_CONSUMER_KEY" unless OVH_APP_SECRET && OVH_CONSUMER_KEY
    to_sign = [OVH_APP_SECRET, OVH_CONSUMER_KEY, method.upcase, full_url, body_str, tstamp.to_s].join("+")
    "$1$#{Digest::SHA1.hexdigest(to_sign)}"
  end

  def set_request_headers(req, method, url, body_str)
    tstamp = ovh_time
    sig = ovh_signature(method, url.to_s, tstamp, body_str)
    req["X-Ovh-Application"] = OVH_APP_KEY
    req["X-Ovh-Consumer"]    = OVH_CONSUMER_KEY
    req["X-Ovh-Timestamp"]   = tstamp.to_s
    req["X-Ovh-Signature"]   = sig
    req["Content-Type"]      = "application/json"
  end

  def ovh_time
    uri = URI.join(URL, "auth/time")
    res = Net::HTTP.get_response(uri)
    Integer(res.body)
  end
end
