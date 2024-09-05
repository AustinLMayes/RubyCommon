require_relative 'logging'
require_relative 'temp_storage'
require_relative 'background_process'

class RecurringJob
  attr_reader :id, :interval, :last_run, :next_run, :status

  def initialize(id, interval, &block)
    existing = TempStorage.get("recurring-job-#{id}")
    @id = id
    @interval = interval
    @last_run = existing.nil? ? nil : DateTime.parse(existing["last_run"])
    unless existing.nil?
      pid = existing["pid"]
      status = existing["status"]
      if status == "waiting"
        BackgroundProcess.kill(pid)
      else
        RecurringJob.stop(id)
        RecurringJob.wait(id)
      end
    end
    @next_run = last_run.nil? ? DateTime.now : last_run + interval
    @status = "waiting"
    BackgroundProcess.new("recurring-job-#{id}") do
      tick = 0
      TempStorage.store("recurring-job-#{id}", { last_run: @last_run.to_s, pid: Process.pid, status: "waiting" })
      loop do
        break if @status == "stopped"
        if tick % 30 == 0
          data = TempStorage.get("recurring-job-#{id}-request")
          unless data.nil?
            case data["action"]
            when "stop"
              break
            else
              error "Unknown action: #{data["action"]}"
            end
          end
        end
        if @next_run <= DateTime.now
          begin
            TempStorage.store("recurring-job-#{id}", { last_run: @last_run.to_s, pid: Process.pid, status: "running" }, expiry: 1.hour)
            block.call
            @last_run = DateTime.now
            @next_run = @last_run + interval
            TempStorage.store("recurring-job-#{id}", { last_run: @last_run.to_s, pid: Process.pid, status: "waiting" })
          rescue => e
            TempStorage.store("recurring-job-#{id}", { last_run: @last_run.to_s, pid: Process.pid, status: "error" }, expiry: 1.day)
            error "Error in recurring job #{id}: #{e.message}"
          end
        end
        tick += 1
        sleep 1
      end
    end
  end

  def self.stop(id)
    data = TempStorage.get("recurring-job-#{id}")
    return if data.nil?
    TempStorage.store("recurring-job-#{id}-request", { action: "stop" }, expiry: 5.minutes)
  end

  def self.wait(id)
    data = TempStorage.get("recurring-job-#{id}")
    return if data.nil?
    BackgroundProcess.wait(data["pid"])
  end

  def self.running?(id)
    data = TempStorage.get("recurring-job-#{id}")
    return false if data.nil?
    data["status"] == "running"
  end

  def self.done?(id)
    data = TempStorage.get("recurring-job-#{id}")
    return false if data.nil?
    data["status"] == "done"
  end
end
