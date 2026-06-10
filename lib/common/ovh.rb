require_relative "logging"
require_relative "temp_storage"
require 'net/http'
require 'json'
require 'digest'
require 'active_support/time'

module OVH
  extend self

  DEFAULT_URL = "https://eu.api.ovh.com/1.0/"

  # x.x.x.x/xx
  V4_PATTERN = /\A((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\/([0-9]|[1-2][0-9]|3[0-2]))\z/
  V6_PATTERN = /\A([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}(\/([0-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8]))\z/

  Account = Struct.new(:name, :app_key, :app_secret, :consumer_key, :url) do
    def to_s
      name
    end
  end

  # Configured via env vars. Two supported layouts:
  #   1) OVH_ACCOUNTS=eu,us (or any names) plus per-account
  #      OVH_<NAME>_APP_KEY / _APP_SECRET / _CONSUMER_KEY / _URL (URL optional, defaults to EU API)
  #   2) Legacy single account: OVH_APP_KEY / OVH_APP_SECRET / OVH_CONSUMER_KEY (+ optional OVH_URL)
  def accounts
    @accounts ||= load_accounts
  end

  def reset_accounts!
    @accounts = nil
  end

  def servers
    servers_rich = {}
    accounts.each do |account|
      ids = get("dedicated/server", account: account)
      ids.each do |srv|
        srv_info = get("dedicated/server/#{srv}", account: account)
        ips = get("dedicated/server/#{srv}/ips", account: account)
        v4_ips = ips.select { |ip| ip =~ V4_PATTERN }.map { |ip| ip.split('/').first }
        v6_ips = ips.select { |ip| ip =~ V6_PATTERN }.map { |ip| ip.split('/').first }
        srv_info['ips'] = ips
        srv_info['v4_ips'] = v4_ips
        srv_info['v6_ips'] = v6_ips
        srv_info['id'] = srv
        srv_info['name'] = srv_info['iam']['displayName']
        srv_info['account'] = account.name
        srv_info['hardware'] = get("dedicated/server/#{srv}/specifications/hardware", account: account)
        servers_rich[srv_info['iam']['displayName']] = srv_info
      end
    end
    servers_rich
  end

  def get_fresh(path, query: nil, account: nil)
    account = resolve_account(account)
    TempStorage.clear(cache_key(account, path, query))
    get(path, query: query, account: account)
  end

  def get(path, query: nil, account: nil)
    account = resolve_account(account)
    key = cache_key(account, path, query)
    if TempStorage.is_stored?(key)
      return JSON.parse(TempStorage.get(key))
    end
    url = URI.join(account.url, path)
    url.query = URI.encode_www_form(query) if query && !query.empty?

    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true

    req = Net::HTTP::Get.new(url)
    set_request_headers(req, "GET", url, "", account)

    res = http.request(req)
    jr = JSON.parse(res.body)
    TempStorage.store(key, res.body, expiry: 12.hours)
    jr
  end

  def put(path, body: {}, account: nil)
    account = resolve_account(account)
    url = URI.join(account.url, path)

    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true

    body_str = body.to_json
    req = Net::HTTP::Put.new(url)
    set_request_headers(req, "PUT", url, body_str, account)
    req.body = body_str

    res = http.request(req)
    JSON.parse(res.body)
  end

  def post(path, body: {}, account: nil)
    account = resolve_account(account)
    url = URI.join(account.url, path)

    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true

    body_str = body.to_json
    req = Net::HTTP::Post.new(url)
    set_request_headers(req, "POST", url, body_str, account)
    req.body = body_str

    res = http.request(req)
    JSON.parse(res.body)
  end

  def delete(path, account: nil)
    account = resolve_account(account)
    url = URI.join(account.url, path)

    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true

    req = Net::HTTP::Delete.new(url)
    set_request_headers(req, "DELETE", url, "", account)

    res = http.request(req)
    if res.is_a?(Net::HTTPSuccess)
      true
    else
      warning "Failed to delete resource at #{url}: #{res.code} #{res.message}"
      false
    end
  end

  private

  def load_accounts
    names_env = ENV['OVH_ACCOUNTS']
    if names_env && !names_env.strip.empty?
      names_env.split(',').map(&:strip).reject(&:empty?).map { |name| account_from_env(name) }
    else
      [Account.new(
        'default',
        require_env('OVH_APP_KEY'),
        require_env('OVH_APP_SECRET'),
        require_env('OVH_CONSUMER_KEY'),
        ENV['OVH_URL'] || DEFAULT_URL,
      )]
    end
  end

  def account_from_env(name)
    prefix = "OVH_#{name.upcase}"
    Account.new(
      name,
      require_env("#{prefix}_APP_KEY"),
      require_env("#{prefix}_APP_SECRET"),
      require_env("#{prefix}_CONSUMER_KEY"),
      ENV["#{prefix}_URL"] || DEFAULT_URL,
    )
  end

  def require_env(name)
    val = ENV[name]
    raise "Missing required environment variable: #{name}" if val.nil? || val.empty?
    val
  end

  # Callers may pass an Account, a name, or nil (defaults to first configured account).
  def resolve_account(account)
    return accounts.first if account.nil?
    return account if account.is_a?(Account)
    found = accounts.find { |a| a.name == account.to_s }
    raise "Unknown OVH account: #{account}. Known: #{accounts.map(&:name).join(', ')}" unless found
    found
  end

  def cache_key(account, path, query)
    "ovh.api.get.#{account.name}.#{path}.#{query}"
  end

  def ovh_signature(method, full_url, tstamp, body_str, account)
    to_sign = [account.app_secret, account.consumer_key, method.upcase, full_url, body_str, tstamp.to_s].join("+")
    "$1$#{Digest::SHA1.hexdigest(to_sign)}"
  end

  def set_request_headers(req, method, url, body_str, account)
    tstamp = ovh_time(account)
    sig = ovh_signature(method, url.to_s, tstamp, body_str, account)
    req["X-Ovh-Application"] = account.app_key
    req["X-Ovh-Consumer"]    = account.consumer_key
    req["X-Ovh-Timestamp"]   = tstamp.to_s
    req["X-Ovh-Signature"]   = sig
    req["Content-Type"]      = "application/json"
  end

  def ovh_time(account)
    uri = URI.join(account.url, "auth/time")
    res = Net::HTTP.get_response(uri)
    Integer(res.body)
  end
end
