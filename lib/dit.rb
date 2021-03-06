require 'thor'
require 'git'
require 'os'
require 'fileutils'
require 'set'

# This is the class where all the dit work is done.
# The thor class is basically a very thin layer on top of this that just
# calls its methods directly.
# This is because the hooks are not running through the Thor object, but also
# referencing these methods.
class Dit
  def self.init
    exit_if_windows

    if Dir.exist?('.git')
      symlink_all if prompt_for_symlink_all
    else
      Git.init(Dir.getwd)
      puts "Initialized empty Git repository in #{File.join(Dir.getwd, '.git')}"
    end

    hook

    puts 'Dit was successfully hooked into .git/hooks.'
  end

  def self.exit_if_windows
    if OS.windows?
      puts 'This is a windows system, and dit does not support windows.'
      puts 'See vulpino/dit issue #1 if you have a potential solution.'
      exit 1
    end
  end

  def self.prompt_for_symlink_all
    puts 'Dit has detected an existing git repo, and will initialize it to ' \
      'populate your ~ directory with symlinks.'
    puts 'Please confirm this by typing y, or anything else to cancel.'
    response = STDIN.gets.chomp.upcase
    response == 'Y'
  end

  def self.hook
    Dir.chdir(File.join('.git', 'hooks')) do
      # The following check for the existence of post-commit or post-merge hooks
      # and will not interfere with them if they exist and do not use bash.
      append_to_post_commit, cannot_post_commit = detect_hook 'post-commit'
      append_to_post_merge, cannot_post_merge = detect_hook 'post-merge'

      write_hook('post-commit', append_to_post_commit) unless cannot_post_commit
      write_hook('post-merge', append_to_post_merge) unless cannot_post_merge

      make_dit
      make_ruby_enforcer

      # Make sure they're executable
      FileUtils.chmod '+x', %w(post-commit post-merge dit force-ruby)
    end
  end

  def self.symlink_list(list)
    list = get_roots list
    list.each do |f|
      wd_f = File.expand_path f
      home_f = File.expand_path(f).gsub(Dir.getwd, Dir.home)
      symlink wd_f, home_f
    end
  end

  def self.get_roots(list)
    root_list = Set[]
    list.each do |f|
      f.strip!
      root = f.split('/')[0]
      root ||= f
      root_list |= Set[root]
    end
    root_list.delete?('')
    %w(.gitignore README.md README).each { |i| root_list.delete(i) }
    root_list 
  end

  def self.symlink_unlinked
    symlink_list `git show --pretty="format:" --name-only HEAD`.split("\n")
  end

  def self.symlink_all
    current_branch = `git rev-parse --abbrev-ref HEAD`.chomp
    symlink_list `git ls-tree -r #{current_branch} --name-only`.split("\n")
  end

  def self.symlink(a, b)
    if File.exist?(b)
      return if File.symlink?(b) && File.readlink(b).include?(Dir.getwd)
      return unless prompt_for_overwrite a, b
    end
    File.symlink(a, b)
  rescue
    puts "Failed to symlink #{a} to #{b}"
  end

  def self.prompt_for_overwrite(a, b)
    return false if @never
    (FileUtils.rm(b); return true) if @always # just this once;
    puts "#{b} conflicts with #{a}. Remove #{b}? [y/n/a/s]"
    puts "To always overwrite, type \"A\". To never overwrite, type \"S\""
    response = STDIN.gets.upcase
    case response
    when 'Y'
      FileUtils.rm(b)
      return true
    when 'A'
      @always = true
      FileUtils.rm(b)
      return true
    when 'S'
      @never = true
    end
    false
  end

  def self.detect_hook(hook)
    return [false, false] unless File.exist?(hook)

    cannot_hook, append_to_hook = false

    if `cat #{hook}`.include?('./.git/hooks/dit')
      puts 'Dit hook already installed.'
      cannot_hook = true
    elsif `cat #{hook}`.include?('#!/usr/bin/env bash')
      puts "You have #{hook} hooks already that use bash, so we'll " \
        'append ourselves to the file.'
      append_to_hook = true
    else
      puts "You have #{hook} hooks that use some foreign language, " \
        "so we won't interfere, but we can't hook in there."
      cannot_hook = true
    end

    [append_to_hook, cannot_hook]
  end

  def self.write_hook(hook_file, do_append)
    File.open(hook_file, 'a') do |f|
      f.puts '#!/usr/bin/env bash' unless do_append
      f.puts '( exec ./.git/hooks/dit )'
    end
  end

  def self.make_dit
    File.open('dit', 'a') do |f|
      f.puts '#!/usr/bin/env ./.git/hooks/force-ruby'
      f.puts "require 'dit'"
      f.puts 'Dit.symlink_unlinked'
    end
  end

  def self.make_ruby_enforcer
    # The following lines are because git hooks do this weird thing
    # where they prepend /usr/bin to the path and a bunch of other stuff
    # meaning git hooks will use /usr/bin/ruby instead of any ruby
    # from rbenv or rvm or chruby, so we make a script forcing the hook
    # to use our ruby
    ruby_path = `which ruby`
    if ruby_path != '/usr/bin/ruby'
      ruby_folder = File.dirname(ruby_path)
      File.open('force-ruby', 'a') do |f|
        f.puts '#!/usr/bin/env bash'
        f.puts 'set -e'
        f.puts 'PATH=#{ruby_folder}:$PATH'
        f.puts "exec ruby \"$@\""
      end
    else
      File.open('force-ruby', 'a') do |f|
        f.puts '#!/usr/bin/env bash'
        f.puts "exec ruby \"$@\""
      end
    end
  end

  def self.clean_home
    Dir.chdir(Dir.home) do
      existing_dotfiles = Dir.glob('.*')
      existing_dotfiles.each do |f|
        next if f == '.' || f == '..'
        if File.symlink?(f)
          f_abs = File.readlink(f)
          File.delete(f) unless File.exist?(f_abs)
        end
      end
    end
  end

  def self.version
    '0.4'
  end
end

# This is the thor class the CLI calls.
# It's a thin layer on top of the Dit class. See above.
class DitCMD < Thor
  desc 'init', 'Initialize the current directory as a dit directory.'
  def init
    Dit.init
  end

  desc 'rehash', "Manually symlink everything in case a git hook didn't run."
  def rehash
    Dit.symlink_all
  end

  desc 'version', 'Print the dit version.'
  def version
    puts "Dit #{Dit.version} on ruby #{RUBY_VERSION}"
  end

  desc 'clean', 'Clean dead symlinks from your home dir.'
  def clean
    Dit.clean_home
  end
end
