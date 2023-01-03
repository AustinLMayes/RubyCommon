module FileUtils
    extend self

    def parse_args(args, start=0)
        dirs = []
        dirs << Dir.pwd if args.extras[start].nil?
        dirs += args.extras[start..-1] unless args.extras[start].nil?
        dirs = fix_relative_dirs dirs
        dirs
    end

    def act_on_dirs(dirs, &block)
        dirs = fix_relative_dirs dirs
        dirs.each do |dir|
            Dir.chdir dir do
                block.call dir
            end
        end
    end

    def fix_relative_dirs(dirs)
        if dirs == ["*"]
            # Treat glob as parent path starting at "Ziax"
            # Walk up Dir.pwd until we find "Ziax*" and set that as the base, then find all dirs with a .git folder
            dirs = []
            Dir.chdir(Dir.pwd) do
                base = Dir.pwd
                Dir.glob("**/**/.git").each do |dir|
                    next if dir.include?("/work/") # Spigot
                    dirs << base + "/" + File.dirname(dir)
                end
            end
        end
        dirs.delete_if { |dir| !File.exists?(dir + "/.git") }
        dirs.map do |dir|
            if dir.start_with?(".")
                dir = File.expand_path(dir)
            end
            if dir.start_with?("~")
                dir = File.expand_path(dir)
            end
            Git.ensure_git dir
            dir
        end
    end
end