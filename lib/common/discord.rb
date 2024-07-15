module Discord
end

Dir[File.dirname(__dir__) + '/common/discord/*.rb'].each do |file|
    require_relative "discord/" + File.basename(file, File.extname(file))
end