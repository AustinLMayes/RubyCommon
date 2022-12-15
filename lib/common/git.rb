require_relative "logging"

module Git
    extend self
  
    def ensure_git(where)
      error "Repo not found at path #{where}!" unless File.exists? where
      error "#{where} is not a Git directory!" unless File.exists? "#{where}/.git"
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
  
    def nth_commit_sha(offset)
      `git log --reverse -n#{offset} --pretty="%H" | head -n1`.strip
    end
  
    def commits_after(date)
      `git log --reverse --since="#{date}" --pretty="%H" origin/#{current_branch}..#{current_branch}`.split("\n")
    end
  
    def last_pushed_date
      DateTime.parse(`git log --pretty="%aD" origin/#{current_branch} | head -n1`.strip)
    end
  
    def lines_changed(sha)
      out = `git show #{sha} --oneline --numstat`.strip
      count = 0
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

    def commit(msg)
      `git add .`
      `g c -am \"#{msg}\"`
    end
  end