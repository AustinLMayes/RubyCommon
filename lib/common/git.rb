require_relative "command"
require_relative "delays"
require_relative "logging"

module Git
    extend self

    class Error < StandardError; end

    def run(dir, *args, config: [], **opts)
      Command.run("git", *location(dir), *config.flat_map { |c| ["-c", c] }, *args, **opts)
    end

    def run!(dir, *args, error: Error, message: :full, **opts)
      result = run(dir, *args, **opts)
      return result if result.ok?

      raise error, failure(args, result, message)
    end

    def out(dir, *args, strip: true, **opts)
      result = run(dir, *args, **opts)
      return unless result.ok?

      strip ? result.out.strip : result.out
    end

    def ok?(dir, *args, **opts)
      run(dir, *args, **opts).ok?
    end

    def stream(dir, *args, config: [], env: {})
      system(env, "git", *location(dir), *config.flat_map { |c| ["-c", c] }, *args)
    end

    def toplevel(dir: nil, **opts)
      out(dir, "rev-parse", "--show-toplevel", **opts)
    end

    def git_dir(dir: nil, **opts)
      out(dir, "rev-parse", "--path-format=absolute", "--git-dir", **opts)
    end

    def common_dir(dir: nil, **opts)
      out(dir, "rev-parse", "--path-format=absolute", "--git-common-dir", **opts)
    end

    def repo?(dir)
      ok?(dir, "rev-parse", "--git-dir")
    end

    def remote_url(remote = "origin", dir: nil, push: false, **opts)
      out(dir, "remote", "get-url", *("--push" if push), remote, **opts)
    end

    def default_branch(remote = "origin", dir: nil, **opts)
      return "production" if ok?(dir, "rev-parse", "--verify", "-q", "refs/remotes/#{remote}/production", **opts)

      out(dir, "symbolic-ref", "-q", "--short", "refs/remotes/#{remote}/HEAD", **opts)&.delete_prefix("#{remote}/")
    end

    def slug(url)
      url.to_s.strip[%r{[:/]([^/:]+/[^/]+?)(?:\.git)?/?\z}, 1]
    end

    def config(key, dir: nil, **opts)
      out(dir, "config", "--get", key, **opts)
    end

    def config_all(key, dir: nil, **opts)
      out(dir, "config", "--get-all", key, **opts).to_s.split("\n")
    end

    def aliases(dir: nil, overrides: [])
      @aliases ||= {}
      @aliases[[dir, overrides]] ||= begin
        result = run(dir, "config", "-z", "--get-regexp", '^alias\.', config: overrides, stderr: :discard)
        entries = result.ok? ? result.out.split("\0") : []
        entries.to_h { |e| e.delete_prefix("alias.").split("\n", 2).then { |k, v| [k, v.to_s] } }
      end
    end

    def branch_for_comparison
      branch = "origin/" + current_branch
      unless branch_is_on_remote? current_branch
        branch = "production"
      end
      puts "Using branch #{branch} for comparison"
      branch
    end

    def ensure_git(where)
      error "Repo not found at path #{where}!" unless File.exist? where
      error "#{where} is not a Git directory!" unless File.exist? "#{where}/.git"
    end

    def is_repo?(where)
      File.exist? where and File.exist? "#{where}/.git"
    end

    def branch_is_on_remote?(branch)
      capture("branch", "-r").split("\n").include? "  origin/#{branch}"
    end
  
    def checkout_branch(branch)
      stream nil, "checkout", branch
      Git.ensure_branch branch
      stream nil, "branch", "--set-upstream-to=origin/#{branch}", branch
      stream nil, "pull"
    end
  
    def current_branch(dir: nil)
      out(dir, "symbolic-ref", "-q", "HEAD").to_s.delete_prefix("refs/heads/")
    end

    def repo_name
      capture("config", "--get", "remote.origin.url").strip.split("/").last.gsub(".git", "")
    end

    def repo_org
      capture("config", "--get", "remote.origin.url").strip.split(":").last.split("/").first
    end

    def repo_name_with_org
      capture("config", "--get", "remote.origin.url").strip.split(":").last.split("/")[0..1].join("/").gsub(".git", "")
    end
  
    def ensure_branch(branch)
      error "Not on expected branch #{branch}! On #{current_branch}" if current_branch.downcase != branch.downcase
    end

    def ensure_clean
      error "Uncommitted changes detected!" if has_uncommitted_changes?
    end
  
    def delete_branches(*branches, remote: true)
      info "Deleting #{branches.join(" ")}..."
      branches.shuffle.each do |branch|
        stream nil, "branch", "-D", branch
        stream nil, "push", "origin", "--delete", branch if remote && !$dont_push
        wait_range 3, 6
      end
    end
  
    def pull_branches(*branches, ensure_exists: true, delay: [0, 0])
      act_on_branches *branches, ensure_exists: ensure_exists, delay: delay do |branch|
        info "Pulling #{branch}"
        stream nil, "pull"
      end
    end
  
    def push_branches(*branches, ensure_exists: true, delay: [0, 0], force: false)
      act_on_branches *branches, ensure_exists: ensure_exists, delay: delay do |branch|
        info "Pushing #{branch}"
        push(force: force)
      end
    end
  
    def act_on_branches(*branches, ensure_exists: true, delay: [0, 0], shuffle: true, &block)
      branches.each do |branch|
        info "Checking out #{branch}..."
        stream nil, "checkout", branch
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
      stream nil, "rev-parse", "--verify", branch
    end

    # Only switch if there are no uncommitted changes
    def safe_checkout(*branches)
      return if branches.include? current_branch
      return if has_uncommitted_changes?
      return if has_unpushed_commits?
      branches.each do |branch|
        if branch_exists branch
          info "Switching to #{branch}"
          stream nil, "checkout", branch
          return
        end
      end
      warning "No branches found for #{Dir.pwd}! Tried #{branches.join(", ")}"
    end
  
    def nth_commit_sha(offset)
      capture("log", "--reverse", "-n#{offset}", "--pretty=%H").lines.first.to_s.strip
    end
  
    def commits_after(date)
      warning "Branch must be pushed to get accurate dates" unless branch_is_on_remote? current_branch
      capture("log", "--reverse", "--since=#{date}", "--pretty=%H", "#{branch_for_comparison}..#{current_branch}").split("\n")
    end

    # [{sha: "123", date: Ruby Date, message: "message"}]
    def commits_after_with_date(date)
      warning "Branch must be pushed to get accurate dates" unless branch_is_on_remote? current_branch
      dated_commits_since(date)
    end

    def commits_after_last_push
      commits_after last_pushed_date
    end

    def commits_after_last_push_with_date
      commits_after_with_date last_pushed_date
    end

    def my_commits_after_with_date(date, author)
      dated_commits_since(date)
    end

    def last_n_commits(n)
      commits = capture("log", "--reverse", "-n#{n}", "--pretty=%H", current_branch).split("\n")
      commits.reverse
    end
  
    def last_pushed_date
      DateTime.parse(capture("log", "-1", "--pretty=%aD", branch_for_comparison).strip).localtime
    end

    def has_unpushed_commits?
      capture("status").include? "Your branch is ahead of"
    end
  
    def lines_changed(sha)
      out = capture("show", sha, "--oneline", "--numstat").strip
      return 0 if out.empty? || out.include?("fatal: bad object")
      out.split("\n")[1..-1].sum { |l| l.split(" ").sum { |part| part.strip.to_i } }
    end

    def uncommitted_lines
      capture("diff", "--numstat").split("\n").map do |line|
        line.split(' ').first.to_i
      end.sum
    end

    def has_uncommitted_changes?
      uncommitted_lines > 0
    end

    def last_commit_message
      extract_commit_message(capture("log", "-1", "--pretty=%B"))
    end

    def commit(msg)
      capture "add", "."
      capture "c", "-am", msg
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
    def push(force: false, make_branch_if_missing: true)
      return false if $dont_push
      branch = current_branch
      refspec = "#{branch}:#{branch}"
      force_flag = force ? ["--force"] : []
      if make_branch_if_missing && !branch_is_on_remote?(branch)
        info "Branch #{branch} not found on remote, creating it..."
        capture "push", "--porcelain", "--set-upstream", *force_flag, "origin", refspec
        return true
      end
      capture("push", "--porcelain", *force_flag, "origin", refspec).include? ".."
    end

    def find_branches(pattern)
      puts "Looking for branches matching #{pattern}..."
      # `+` marks a branch checked out in another worktree — drop it too, or the
      # name comes back as "+ austin/s/foo" and callers use that as a branch.
      capture("branch", "-a").split("\n").map { |line| line.sub(/\A\s*[*+]?\s*/, "").strip }.select do |line|
        debug "Checking if #{line} matches #{pattern} (#{line.match?(/#{pattern}/)})" unless line.include?("remotes")
        !line.include?("remotes") && line.match?(/#{pattern}/)
      end
    end
    def find_branches_multi(*names)
      branches = names.map do |name|
        if name.is_a? String
          find_branches name
        elsif name.is_a? Array
          find_branches_multi *name
        end
      end.flatten.uniq
      info "Found branches: #{branches.join(", ")}"
      branches
    end

    PATCHES_PATH = ENV["HOME"] + "/git-utils/patches"

    def create_patches(branch: Git.current_branch, base: "production", prefix: nil, path: nil)
      info "Creating patches for #{base}..#{branch}"
      FileUtils.mkdir_p PATCHES_PATH
      patches_path = PATCHES_PATH + "/" + File.basename(Dir.pwd) + "/" + (path.nil? ? branch : path)
      info "Saving patches to #{patches_path}"
      if prefix
        FileUtils.rm Dir.glob(patches_path + "/#{prefix}*.patch")
        patches_path += "/tmp"
      else
        FileUtils.rm_rf patches_path
      end
      FileUtils.mkdir_p patches_path
      stream nil, "format-patch", "--diff-algorithm=myers", "--zero-commit", "--full-index", "--no-signature", "--no-stat", "-N", "-o", patches_path, "#{base}..#{branch}"
      if prefix
        Dir.glob(patches_path + "/*.patch").each do |file|
          FileUtils.mv file, patches_path + "/../" + prefix + "-" + File.basename(file)
        end
        FileUtils.rm_rf patches_path
      end
    end

    def apply_patches(path: Git.current_branch, prefix: "", interactive: false)
      patches_path = PATCHES_PATH + "/" + File.basename(Dir.pwd) + "/" + path
      error "No patches found in #{patches_path}" unless Dir.exist?(patches_path)
      error "No patches found in #{patches_path}" if Dir.empty?(patches_path)
      error "No patches found with prefix #{prefix}" if Dir.glob(patches_path + "/#{prefix}*.patch").empty?
      applied = stream nil, "am", "--3way", "--ignore-whitespace", *Dir.glob(patches_path + "/#{prefix}*.patch"), *("-i" if interactive)
      error "Failed to apply patches" unless applied
    end

    def commits_between(branch1, branch2)
      capture("log", "--no-merges", "--reverse", "--pretty=%H", "#{branch1}..#{branch2}").split("\n")
    end

    def my_commits_between(branch1, branch2, author)
      commits_between branch1, branch2
    end

    def commit_message(sha)
      full = capture("log", "-1", "--pretty=%B", sha).strip
      extract_commit_message full
    end

    private

    def location(dir)
      dir ? ["-C", dir] : []
    end

    def capture(*args)
      run(nil, *args, stderr: :inherit).out
    end

    def failure(args, result, message)
      return "git #{args.join(" ")} timed out" if result.timed_out?

      text = (result.err.strip.empty? ? result.out : result.err).strip
      text = text.lines.last.to_s.strip if message == :last_line
      text.empty? ? "git #{args.join(" ")} exited #{result.status&.exitstatus}" : text
    end

    def dated_commits_since(date)
      capture("log", "--reverse", "--since=#{date}", "--pretty=%H||%aD", "#{branch_for_comparison}..#{current_branch}").split("\n").map do |line|
        sha, date = line.split("||")
        {sha: sha, date: DateTime.parse(date), message: commit_message(sha)}
      end
    end

    def extract_commit_message(full)
      full = full.split("\n") unless full.is_a? Array
      full = full.reject { |line| line.start_with?("Signed-off-by:") || line.start_with?("#") }
      title = full.first
      body = ""
      body = full[1..-1].join("\n") if full.length > 1
      {title: title, body: body}
    end
end
