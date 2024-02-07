require_relative "logging"

module Git
    extend self
  
    def branch_for_comparison
      branch = "origin/" + current_branch
      unless branch_is_on_remote? current_branch
        branch = "production"
      end
      puts "Using branch #{branch} for comparison"
      branch
    end

    def ensure_git(where)
      error "Repo not found at path #{where}!" unless File.exists? where
      error "#{where} is not a Git directory!" unless File.exists? "#{where}/.git"
    end

    def is_repo?(where)
      File.exists? where and File.exists? "#{where}/.git"
    end

    def branch_is_on_remote?(branch)
      `git branch -r`.split("\n").include? "  origin/#{branch}"
    end
  
    def checkout_branch(branch)
      system "git", "checkout", branch
      Git.ensure_branch branch
      system "git branch --set-upstream-to=origin/#{branch} #{branch}"
      system "git pull"
    end
  
    def current_branch
      `git branch --show-current`.strip
    end

    def repo_name
      `git config --get remote.origin.url`.strip.split("/").last.gsub(".git", "")
    end

    def repo_org
      `git config --get remote.origin.url`.strip.split(":").last.split("/").first
    end
  
    def ensure_branch(branch)
      error "Not on expected branch #{branch}! On #{current_branch}" if current_branch.downcase != branch.downcase
    end
  
    def delete_branches(*branches, remote: true)
      info "Deleting #{branches.join(" ")}..."
      branches.shuffle.each do |branch|
        system "git branch -D #{branch}"
        system "git push origin --delete #{branch}" if remote
        wait_range 3, 6
      end
    end
  
    def pull_branches(*branches, ensure_exists: true, delay: [0, 0])
      act_on_branches *branches, ensure_exists: ensure_exists, delay: delay do |branch|
        info "Pulling #{branch}"
        system "git", "pull"
      end
    end
  
    def push_branches(*branches, ensure_exists: true, delay: [0, 0])
      act_on_branches *branches, ensure_exists: ensure_exists, delay: delay do |branch|
        info "Pushing #{branch}"
        system "git", "pu"
      end
    end
  
    def act_on_branches(*branches, ensure_exists: true, delay: [0, 0], shuffle: true, &block)
      existing = []
      branches.each do |branch|
        existing << branch
  
        # if system "git rev-parse --verify #{branch}"
        #   existing << branch
        # elsif ensure_exists
        #   error "Branch #{branch} does not exist in repository!"
        # else
        #   warning "Tried to check out #{branch} but it didn't exist!"
        # end
      end
  
      branches = branches.shuffle if shuffle
  
      existing.each do |branch|
        info "Checking out #{branch}..."
        system "git", "checkout", branch
        if current_branch.downcase == branch.downcase
          wait_range *delay
          block.call branch
        end
      end
    end
  
    def ensure_exists(branch)
      error "Branch #{branch} does not exist in repository!" unless branch_exists branch
    end
  
    def branch_exists(branch)
      system "git rev-parse --verify #{branch}"
    end

    # Only switch if there are no uncommitted changes
    def safe_checkout(*branches)
      return if branches.include? current_branch
      return if has_uncommitted_changes?
      return if has_unpushed_commits?
      branches.each do |branch|
        if branch_exists branch
          info "Switching to #{branch}"
          system "git checkout #{branch}"
          return
        end
      end
      warning "No branches found for #{Dir.pwd}! Tried #{branches.join(", ")}"
    end
  
    def nth_commit_sha(offset)
      `git log --reverse -n#{offset} --pretty="%H" | head -n1`.strip
    end
  
    def commits_after(date)
      warn "Branch must be pushed to get accurate dates" unless branch_is_on_remote? current_branch
      `git log --reverse --since="#{date}" --pretty="%H" #{branch_for_comparison}..#{current_branch}`.split("\n")
    end

    # [{sha: "123", date: Ruby Date, message: "message"}]
    def commits_after_with_date(date)
      warn "Branch must be pushed to get accurate dates" unless branch_is_on_remote? current_branch
      `git log --reverse --since="#{date}" --pretty="%H||%aD||%s" #{branch_for_comparison}..#{current_branch}`.split("\n").map do |line|
        sha, date, message = line.split("||")
        {sha: sha, date: DateTime.parse(date), message: message}
      end
    end

    def commits_after_last_push
      commits_after last_pushed_date
    end

    def commits_after_last_push_with_date
      commits_after_with_date last_pushed_date
    end

    def my_commits_after_with_date(date, author)
      commits = `git log --reverse --since="#{date}" --pretty="%H||%aD||%s" #{branch_for_comparison}..#{current_branch}`.split("\n").map do |line|
        sha, date, message = line.split("||")
        {sha: sha, date: DateTime.parse(date), message: message}
      end
      commits.select do |commit|
        commit[:message].include? author
      end
      commits
    end
  
    def last_pushed_date
      DateTime.parse(`git log --pretty="%aD" #{branch_for_comparison} | head -n1`.strip).localtime
    end

    def has_unpushed_commits?
      `git status`.include? "Your branch is ahead of"
    end
  
    def lines_changed(sha)
      out = `git show #{sha} --oneline --numstat`.strip
      count = 0
      return count if out.blank? || out.include?("fatal: bad object")
      out.split("\n")[1..-1].each do |l|
        l.split(' ').each do |part|
          begin
            count += part.strip.to_i
          rescue => exception
            break
          end
        end
      end
      count
    end

    def uncommitted_lines
      `git diff --numstat`.split("\n").map do |line|
        line.split(' ').first.to_i
      end.sum
    end

    def has_uncommitted_changes?
      uncommitted_lines > 0
    end

    def last_commit_message
      `git log -1 --pretty=%B`.strip.split("\n").first
    end

    def commit(msg)
      `git add .`
      `git c -am \"#{msg}\"`
    end

    def random_commit(*message_variants)
      message = message_variants.sample
      message = message.downcase if rand(5) == 0
      message = message.split(" ").map(&:capitalize).join(" ") if rand(8) == 0
      built = ""
      message.split(" ").each do |word|
        built += word
        built += " " unless rand(12) == 0
      end
      commit built
    end

    # True if push was successful and new commits were pushed
    def push
      `git push --porcelain`.include? ".."
    end

    def find_branches(pattern)
      puts "Looking for branches matching #{pattern}..."
      `git branch -a`.split("\n").select do |line|
        line.include?(pattern) && !line.include?("remotes")
      end.map do |line|
        line.gsub("*", "").gsub("\n", "").strip
      end
    end

    def find_branches_multi(*names)
      names.map do |name|
        if name.is_a? String
          find_branches name
        elsif name.is_a? Array
          find_branches_multi *name
        end
      end.flatten.uniq
    end
  end