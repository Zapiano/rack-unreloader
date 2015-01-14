module Rack
  # Reloading application that unloads constants before reloading the relevant
  # files, calling the new rack app if it gets reloaded.
  class Unreloader
    # Reference to ::File as File would return Rack::File by default.
    F = ::File

    # Given the path glob or array of path globs, find all matching files
    # or directories, and return an array of expanded paths.
    def self.expand_paths(paths)
      Array(paths).
        flatten.
        map{|path| Dir.glob(path).sort_by{|filename| filename.count('/')}}.
        flatten.
        map{|path| F.expand_path(path)}.
        uniq
    end

    # The Rack::Unreloader::Reloader instead related to this instance, if one.
    attr_reader :reloader

    # Setup the reloader. Options:
    # 
    # :cooldown :: The number of seconds to wait between checks for changed files.
    #              Defaults to 1.  Set to nil/false to not check for changed files.
    # :reload :: Set to false to not setup a reloader, and just have require work
    #            directly.  Should be set to false in production mode.
    # :logger :: A Logger instance which will log information related to reloading.
    # :subclasses :: A string or array of strings of class names that should be unloaded.
    #                Any classes that are not subclasses of these classes will not be
    #                unloaded.  This also handles modules, but module names given must
    #                match exactly, since modules don't have superclasses.
    def initialize(opts={}, &block)
      @app_block = block
      if @reload = opts.fetch(:reload, true)
        @cooldown = opts.fetch(:cooldown, 1)
        @last = Time.at(0)
        Kernel.require 'rack/unreloader/reloader'
        @reloader = Reloader.new(opts)
        @reloader.reload!
      else
        @cooldown = false
      end
    end

    # If the cooldown time has been passed, reload any application files that have changed.
    # Call the app with the environment.
    def call(env)
      if @cooldown && Time.now > @last + @cooldown
        Thread.respond_to?(:exclusive) ? Thread.exclusive{@reloader.reload!} : @reloader.reload!
        @last = Time.now
      end
      @app_block.call.call(env)
    end

    # Add a file glob or array of file globs to monitor for changes.
    def require(paths, &block)
      if @reload
        @reloader.require_dependencies(paths, &block)
      else
        Unreloader.expand_paths(paths).each{|f| super(f)}
      end
    end

    # Records that each path in +files+ depends on +dependency+.  If there
    # is a modification to +dependency+, all related files will be reloaded
    # after +dependency+ is reloaded.  Both +dependency+ and each entry in +files+
    # can be an array of path globs.
    def record_dependency(dependency, *files)
      if @reload
        files = Unreloader.expand_paths(files)
        Unreloader.expand_paths(dependency).each do |path|
          @reloader.record_dependency(path, files)
        end
      end
    end
  end
end
