require File.join(File.dirname(File.expand_path(__FILE__)), '../lib/rack/unreloader')

module ModifiedAt
  def set_modified_time(file, time)
    modified_times[File.expand_path(file)] = time
  end

  def modified_times
    @modified_times ||= {}
  end

  private

  def modified_at(file)
    modified_times[file] || super
  end
end

describe Rack::Unreloader do
  def code(i)
    "class App; def self.call(env) @a end; @a ||= []; @a << #{i}; end"
  end

  def update_app(code, file=@filename)
    ru.reloader.set_modified_time(file, @i += 1)
    File.open(file, 'wb'){|f| f.write(code)}
  end

  def logger
    return @logger if @logger
    @logger = []
    def @logger.method_missing(meth, log)
      self << log
    end
    @logger
  end

  def base_ru(opts={})
    block = opts[:block] || proc{App}
    @ru = Rack::Unreloader.new({:logger=>logger, :cooldown=>0}.merge(opts), &block)
    @ru.reloader.extend ModifiedAt
    Object.const_set(:RU, @ru)
  end

  def ru(opts={})
    return @ru if @ru
    base_ru(opts)
    update_app(opts[:code]||code(1))
    @ru.require 'spec/app.rb'
    @ru
  end

  def log_match(*logs)
    logs.length.should == @logger.length
    logs.zip(@logger).each{|l, log| l.is_a?(String) ? log.should == l : log.should =~ l}
  end

  before do
    @i = 0
    @filename = 'spec/app.rb'
  end

  after do
    ru.reloader.clear!
    Object.send(:remove_const, :RU)
    Object.send(:remove_const, :App) if defined?(::App)
    Object.send(:remove_const, :App2) if defined?(::App2)
    Dir['spec/app*.rb'].each{|f| File.delete(f)}
  end

  it "it should unload constants contained in file and reload file if file changes" do
    ru.call({}).should == [1]
    update_app(code(2))
    ru.call({}).should == [2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\AReloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ARemoved feature .*/spec/app.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z}
  end

  it "it should pickup files added as dependencies" do
    ru.call({}).should == [1]
    update_app("RU.require 'spec/app2.rb'; class App; def self.call(env) [@a, App2.call(env)] end; @a ||= []; @a << 2; end")
    update_app("class App2; def self.call(env) @a end; @a ||= []; @a << 3; end", 'spec/app2.rb')
    ru.call({}).should == [[2], [3]]
    update_app("class App2; def self.call(env) @a end; @a ||= []; @a << 4; end", 'spec/app2.rb')
    ru.call({}).should == [[2], [4]]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\AReloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ARemoved feature .*/spec/app.rb\z},
              %r{\ALoading.*spec/app2\.rb\z},
              %r{\ANew classes in .*spec/app2\.rb: App2\z},
              %r{\ANew classes in .*spec/app\.rb: (App App2|App2 App)\z},
              %r{\ANew features in .*spec/app\.rb: .*spec/app2\.rb\z},
              %r{\AReloading.*spec/app2\.rb\z},
              "Removed constant App2",
              %r{\ARemoved feature .*/spec/app2.rb\z},
              %r{\ANew classes in .*spec/app2\.rb: App2\z}
  end

  it "it should support :subclasses option and only unload subclasses of given class" do
    ru(:subclasses=>'App').call({}).should == [1]
    update_app("RU.require 'spec/app2.rb'; class App; def self.call(env) [@a, App2.call(env)] end; @a ||= []; @a << 2; end")
    update_app("class App2 < App; def self.call(env) @a end; @a ||= []; @a << 3; end", 'spec/app2.rb')
    ru.call({}).should == [[1, 2], [3]]
    update_app("class App2 < App; def self.call(env) @a end; @a ||= []; @a << 4; end", 'spec/app2.rb')
    ru.call({}).should == [[1, 2], [4]]
    update_app("RU.require 'spec/app2.rb'; class App; def self.call(env) [@a, App2.call(env)] end; @a ||= []; @a << 2; end")
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\AReloading.*spec/app\.rb\z},
              %r{\ARemoved feature .*/spec/app.rb\z},
              %r{\ALoading.*spec/app2\.rb\z},
              %r{\ANew classes in .*spec/app2\.rb: App2\z},
              %r{\ANew classes in .*spec/app\.rb: App2\z},
              %r{\ANew features in .*spec/app\.rb: .*spec/app2\.rb\z},
              %r{\AReloading.*spec/app2\.rb\z},
              "Removed constant App2",
              %r{\ARemoved feature .*/spec/app2.rb\z},
              %r{\ANew classes in .*spec/app2\.rb: App2\z}
  end

  it "it log invalid constant names in :subclasses options" do
    ru(:subclasses=>%w'1 Object').call({}).should == [1]
    logger.uniq!
    log_match %r{\ALoading.*spec/app\.rb\z},
              '"1" is not a valid constant name!',
              %r{\ANew classes in .*spec/app\.rb: App\z}
  end

  it "it should unload modules before reloading similar to classes" do
    ru(:code=>"module App; def self.call(env) @a end; @a ||= []; @a << 1; end").call({}).should == [1]
    update_app("module App; def self.call(env) @a end; @a ||= []; @a << 2; end")
    ru.call({}).should == [2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\AReloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ARemoved feature .*/spec/app.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z}
  end

  it "it should unload specific modules by name via :subclasses option" do
    ru(:subclasses=>'App', :code=>"module App; def self.call(env) @a end; @a ||= []; @a << 1; end").call({}).should == [1]
    update_app("module App; def self.call(env) @a end; @a ||= []; @a << 2; end")
    ru.call({}).should == [2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\AReloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ARemoved feature .*/spec/app.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z}
  end

  it "it should not unload modules by name if :subclasses option used and module not present" do
    ru(:subclasses=>'Foo', :code=>"module App; def self.call(env) @a end; @a ||= []; @a << 1; end").call({}).should == [1]
    update_app("module App; def self.call(env) @a end; @a ||= []; @a << 2; end")
    ru.call({}).should == [1, 2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\AReloading.*spec/app\.rb\z},
              %r{\ARemoved feature .*/spec/app.rb\z}
  end

  it "it unload partially loaded modules if loading fails, and allow future loading" do
    ru.call({}).should == [1]
    update_app("module App; def self.call(env) @a end; @a ||= []; raise 'foo'; end")
    proc{ru.call({})}.should raise_error
    defined?(::App).should == nil
    update_app(code(2))
    ru.call({}).should == [2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\AReloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ARemoved feature .*/spec/app.rb\z},
              %r{\AFailed to load .*spec/app\.rb; removing partially defined constants\z},
              "Removed constant App",
              %r{\AReloading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z}
  end

  it "it should unload classes in namespaces" do
    ru(:code=>"class Array::App; def self.call(env) @a end; @a ||= []; @a << 1; end", :block=>proc{Array::App}).call({}).should == [1]
    update_app("class Array::App; def self.call(env) @a end; @a ||= []; @a << 2; end")
    ru.call({}).should == [2]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: Array::App\z},
              %r{\AReloading.*spec/app\.rb\z},
              "Removed constant Array::App",
              %r{\ARemoved feature .*/spec/app.rb\z},
              %r{\ANew classes in .*spec/app\.rb: Array::App\z}
  end

  it "it should not unload class defined in dependency if already defined in parent" do
    base_ru
    update_app("class App; def self.call(env) @a end; @a ||= []; @a << 2; RU.require 'spec/app2.rb'; end")
    update_app("class App; @a << 3 end", 'spec/app2.rb')
    @ru.require 'spec/app.rb'
    ru.call({}).should == [2, 3]
    update_app("class App; @a << 4 end", 'spec/app2.rb')
    ru.call({}).should == [2, 3, 4]
    update_app("class App; def self.call(env) @a end; @a ||= []; @a << 2; RU.require 'spec/app2.rb'; end")
    ru.call({}).should == [2, 4]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\ALoading.*spec/app2\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\ANew features in .*spec/app\.rb: .*spec/app2\.rb\z},
              %r{\AReloading.*spec/app2\.rb\z},
              %r{\ARemoved feature .*/spec/app2.rb\z},
              %r{\AReloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ARemoved feature .*/spec/app2.rb\z},
              %r{\ARemoved feature .*/spec/app.rb\z},
              %r{\ALoading.*spec/app2\.rb\z},
              %r{\ANew classes in .*spec/app\.rb: App\z},
              %r{\ANew features in .*spec/app\.rb: .*spec/app2\.rb\z}
  end

  it "it allow specifying proc for which constants get removed" do
    base_ru
    update_app("class App; def self.call(env) [@a, App2.a] end; @a ||= []; @a << 1; end; class App2; def self.a; @a end; @a ||= []; @a << 2; end")
    @ru.require('spec/app.rb'){|f| File.basename(f).sub(/\.rb/, '').capitalize}
    ru.call({}).should == [[1], [2]]
    update_app("class App; def self.call(env) [@a, App2.a] end; @a ||= []; @a << 3; end; class App2; def self.a; @a end; @a ||= []; @a << 4; end")
    ru.call({}).should == [[3], [2, 4]]
    log_match %r{\ALoading.*spec/app\.rb\z},
              %r{\AReloading.*spec/app\.rb\z},
              "Removed constant App",
              %r{\ARemoved feature .*/spec/app.rb\z}
  end
end