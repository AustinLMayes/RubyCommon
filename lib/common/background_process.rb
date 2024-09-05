require_relative 'temp_storage'
require_relative 'logging'

class BackgroundProcess
  attr_reader :pid, :status

  def initialize(id, &block)
    data = TempStorage.get("bg-proc-#{id}")
    unless data.nil?
      if data["status"] == "running"
        error "Process is already running with PID #{data["pid"]}"
      end
    end
    @pid = fork do
      @status = "running"
      $stdout.reopen(TempStorage::PATH + "bg-#{id}.out", "w")
      $stderr.reopen(TempStorage::PATH + "bg-#{id}.err", "w")
      begin
        block.call
      rescue => e
        TempStorage.store("bg-proc-#{id}", { pid: @pid, status: "error" }, expiry: 1.day)
        @status = "error"
        return
      end
      TempStorage.store("bg-proc-#{id}", { pid: @pid, status: "done" }, expiry: 1.day)
      @status = "done"
    end
    Process.detach @pid
    TempStorage.store("bg-proc-#{id}", { pid: @pid, status: "running" })
  end

  def running?
    @status == "running"
  end

  def done?
    @status == "done"
  end

  def error?
    @status == "error"
  end

  def wait
    loop do
      break if done? || error?
      sleep 1
    end
  end

  def self.running?(id)
    data = TempStorage.get("bg-proc-#{id}")
    return false if data.nil?
    data["status"] == "running"
  end

  def self.done?(id)
    data = TempStorage.get("bg-proc-#{id}")
    return false if data.nil?
    data["status"] == "done"
  end

  def self.error?(id)
    data = TempStorage.get("bg-proc-#{id}")
    return false if data.nil?
    data["status"] == "error"
  end

  def self.wait(id)
    loop do
      break if done?(id) || error?(id)
      sleep 1
    end
  end

  def self.kill(id)
    data = TempStorage.get("bg-proc-#{id}")
    return false if data.nil?
    return false if data["status"] == "done"
    return false if data["status"] == "error"
    Process.kill("KILL", data["pid"])
    TempStorage.store("bg-proc-#{id}", { pid: data["pid"], status: "killed" }, expiry: 1.hour)
  end
end
