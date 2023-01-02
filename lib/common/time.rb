module TimeUtils
    extend self

    def parse_time(time_string)
        # Default to hours if no suffix is given
        time_string += "h" unless time_string =~ /[mhd]/
        # Parse the time string in short form (e.g. 1h30m)
        time = 0
        time_string.scan(/(\d+)([mhd])/).each do |num, suffix|
            num = num.to_i
            case suffix
            when "m"
                time += num.minutes
            when "h"
                time += num.hours
            when "d"
                time += num.days
            end
        end
        time
    end
end