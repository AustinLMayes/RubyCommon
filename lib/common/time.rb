module TimeUtils
    extend self

    def parse_time(time_string)
        # Default to hours if no suffix is given
        time_string += "h" unless time_string =~ /[smhdwMy]/
        time = 0
        time_string.scan(/(\d+)([smhdwMy])/).each do |num, suffix|
            num = num.to_i
            case suffix
            when "s"
                time += num.seconds
            when "m"
                time += num.minutes
            when "h"
                time += num.hours
            when "d"
                time += num.days
            when "w"
                time += num.weeks
            when "M"
                time += num.months
            when "y"
                time += num.years
            end
        end
        time
    end
end