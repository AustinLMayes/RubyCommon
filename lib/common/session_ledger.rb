# frozen_string_literal: true

require 'json'
require 'fileutils'

module SessionLedger
  def self.dir(payload, job_only: false)
    job = ENV['CLAUDE_JOB_DIR'].to_s
    return job unless job.empty?
    return nil if job_only

    session = payload['session_id'].to_s
    File.join(ENV['SESSION_LEDGER_DIR'] || File.join(Dir.home, '.cache', 'session-ledger'), session) unless session.empty?
  end

  def self.append(dir, *rows, file:)
    return if rows.empty?

    FileUtils.mkdir_p(dir)
    File.open(File.join(dir, file), 'a') { |f| rows.each { |r| f.puts(JSON.generate(r)) } }
  end

  def self.read(dir, file:)
    path = File.join(dir, file)
    return [] unless File.exist?(path)

    File.readlines(path).filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  end
end
