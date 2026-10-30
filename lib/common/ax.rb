# frozen_string_literal: true

require_relative "command"

module Ax
  NOT_CLEAN = 3
  TRAIN_UNREACHABLE = 3
  TRAIN_NO_CHANGE = 4

  def self.bin = ENV["AX_BIN"].to_s.empty? ? "ax" : ENV["AX_BIN"]

  def self.call(*args, bin: self.bin, timeout: nil, fail_open: true, **opts)
    Command.run(bin, *args, timeout: timeout, **opts)
  rescue Command::Unavailable, SystemCallError
    raise unless fail_open
  end
end
