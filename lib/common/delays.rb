require_relative "logging"

def wait_range(min, max)
    min = min.to_i if min.is_a? String
    max = max.to_i if max.is_a? String
  
    return if max < 1
    min *= 2 if $extra_slow
    max *= 2 if $extra_slow
  
    random = rand(min..max)
    info "Sleeping for #{random} seconds"
    sleep random
  end