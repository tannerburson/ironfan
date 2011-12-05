require File.expand_path('node_info.rb', File.dirname(__FILE__))
require File.expand_path('attr_struct.rb', File.dirname(__FILE__))
require File.expand_path('dump_aspects.rb', File.dirname(__FILE__))

# FIXME -- remove:
require 'pry' ; require 'ap'

module ClusterChef
  [:Component, :DaemonAspect, :LogAspect, :DirectoryAspect, :DashboardAspect, :PortAspect, :ExportedAspect,
  ].each{|klass| self.send(:remove_const, klass) rescue nil }

  class Component < Struct.new(
      :name,
      :realm
      )
    include ClusterChef::AttrStruct
    attr_reader :sys  # the system name: eg +:redis+ or +:nfs+
    attr_reader :subsys # the subsystem name: eg +:server+ or +:datanode+

    def initialize(run_context, sys, subsys=nil, hsh={})
      super()
      @run_context = run_context
      @sys      = sys
      @subsys   = subsys
      self.name = subsys ? "#{sys}_#{subsys}".to_sym : sys.to_sym
      merge!(hsh)
    end

    # A segmented name for the component
    # @example
    #   ClusterChef::Component.new(rc, :redis, :server, :realm => 'krypton').fullname
    #   # => 'krypton-redis-server'
    #   ClusterChef::Component.new(rc, :nfs, nil, :realm => 'krypton').fullname
    #   # => 'krypton-nfs'
    #
    # @return [String] the component's dotted name
    def fullname
      self.class.fullname(realm, sys, subsys)
    end

    def self.fullname(realm, sys, subsys=nil)
      subsys ? "#{realm}-#{sys}-#{subsys}".to_s : "#{realm}:#{sys}"
    end

    def node
      @run_context.node
    end

    def public_ip
    end

    def private_ip
    end

    def private_hostname
    end

    # Combines the hash for a system with the hash for its given subsys.
    # This lets us ask about the +:user+ for the 'redis.server' component,
    # whether it's set in +node[:redis][:server][:user]+ or
    # +node[:redis][:user]+. If an attribute exists on both the parent and
    # subsys hash, the subsys hash's value wins (see +:user+ in the
    # example below).
    #
    # If subsys is nil, just returns the direct node hash.
    #
    # @example
    #   node.to_hash
    #   # { :hadoop => {
    #   #     :user => 'hdfs', :log_dir => '/var/log/hadoop',
    #   #     :jobtracker => { :user => 'mapred', :port => 50030 } }
    #   # }
    #   node_info(:hadoop, jobtracker)
    #   # { :user => 'mapred', :log_dir => '/var/log/hadoop', :port => 50030,
    #   #   :jobtracker => { :user => 'mapred', :port => 50030 } }
    #   node_info(:hadoop, nil)
    #   # { :user => 'hdfs', :log_dir => '/var/log/hadoop',
    #   #   :jobtracker => { :user => 'mapred', :port => 50030 } }
    #
    #
    def node_info
      unless node[sys] then Chef::Log.warn("no system data in component '#{name}', node '#{node}'") ; return Mash.new ;  end
      hsh = Mash.new(node[sys].to_hash)
      if subsys
        if node[sys][subsys]
          hsh.merge!(node[sys][subsys])
        else
          Chef::Log.warn("no subsystem data in component '#{name}', node '#{node}'")
        end
      end
      hsh
    end

    def self.has_aspect(aspect, klass)
      @aspect_types ||= {}
      @aspect_types[aspect] = klass
    end
  end

  #
  #
  module Discovery

    def announce(sys, subsys=nil, options={})
      options           = Mash.new(options)
      options[:realm] ||= default_realm
      component = Component.new(run_context, sys, subsys, options)
      Chef::Log.info("Announcing component #{component.fullname}")
      node[:discovery][component.fullname] = component.to_hash
      component
    end

    def discover_nodes(sys, subsys=nil, realm=nil)
      realm ||= default_realm
      component_name = ClusterChef::Component.fullname(realm, sys, subsys)
      all_nodes = search(:node, "discovery:#{component_name}" ) rescue []
      if all_nodes.empty?
        Chef::Log.warn("No node announced for '#{component_name}'")
        return []
      end
      all_nodes.reject!{|server| server.name == node.name}  # remove this node...
      all_nodes << node if node[:discovery][component_name] # & use a fresh version
      all_nodes.
        sort_by{|server| server[:discovery][component_name][:timestamp] }
    end

    def default_realm
      node[:cluster_name]
    end

  end

  #
  # An *aspect* is an external property, commonly encountered across multiple
  # systems, that decoupled agents may wish to act on.
  #
  # For example, many systems have a Dashboard aspect -- phpMySQL, the hadoop
  # jobtracker web console, a one-pager generated by cluster_chef's
  # mini_dashboard recipe, or a purpose-built backend for your website. The
  # following independent concerns can act on such dashboard aspects:
  # * a dashboard dashboard creates a page linking to all of them
  # * your firewall grants access from internal machines and denies access on
  #   public interfaces
  # * the monitoring system checks that the port is open and listening
  #
  # Aspects are able to do the following:
  #
  # * Convert to and from a plain hash,
  #
  # * ...and thusly to and from plain node metadata attributes
  #
  # * discover its manifestations across all systems (on all or some
  #   machines): for example, all dashboards, or all open ports.
  #
  # * identify instances from a system's by-convention metadata. For
  #   example, given a chef server system at 10.29.63.45 with attributes
  #     `:chef_server => { :server_port => 4000, :dash_port => 4040 }`
  #   the PortAspect class would produce instances for 4000 and 4040, since by
  #   convention an attribute ending in `_port` means "I have a port aspect`;
  #   the DashboardAspect would recognize the `dash_port` attribute and
  #   produce an instance for `http://10.29.63.45:4040`.
  #
  # Note:
  #
  # * separate *identifiable conventions* from *concrete representation* of
  #   aspects. A system announces that it has a log aspect, and by convention
  #   declares a `:log_dir` attribute. At that point it is regularized into a
  #   LogAspect instance and stored in the `node[:aspects]` tree. External
  #   concerns should only inspect these concrete Aspects, and never go
  #   hunting for thins with a `:log_dir` attribute.
  #
  # * conventions can be messy, but aspects are perfectly uniform
  #
  module Aspect
    include AttrStruct

    # Harvest all aspects findable in the given node metadata hash
    #
    # @example
    #   ClusterChef::Aspect.harvest({ :log_dirs => '...', :dash_port => 9387 })
    #   # [ <LogAspect name="log" dirs=["..."]>,
    #   #   <DashboardAspect url="http://10.x.x.x:9387/">,
    #   #   <PortAspect port=9387 addr="10.x.x.x"> ]
    #
    def self.harvest_all(run_context, sys, subsys, info)
      info = Mash.new(info.to_hash)
      aspects = Mash.new
      registered.each do |aspect_name, aspect_klass|
        res = aspect_klass.harvest(run_context, sys, subsys, info)
        aspects[aspect_name] = res
      end
      aspects
    end

    # list of known aspects
    def self.registered
      @registered ||= Mash.new
    end

    # simple handle for class
    # @example
    #   foo = ClusterChef::FooAspect
    #   foo.klass_handle # :foo
    def klass_handle() self.class.klass_handle ; end

    # checks that the aspect is well-formed. returns non-empty array if there is lint.
    #
    # @abstract
    #   override to provide guidance, filling an array with warning strings. Include
    #       errors + super
    #   as the last line.
    #
    def lint
      []
    end

    def lint!
      lint.each{|l| Chef::Log.warn(l) }
    end

    def lint_flavor
      self.class.allowed_flavors.include?(self.flavor) ? [] : ["Unexpected #{klass_handle} flavor #{flavor.inspect}"]
    end

    module ClassMethods
      include AttrStruct::ClassMethods
      include ClusterChef::NodeInfo

      # Identify aspects from the given hash
      #
      # @return [Array<Aspect>] aspect instances found in hash
      #
      # @example
      #   LogAspect.harvest({
      #     :access_log_file => ['/var/log/nginx/foo-access.log'],
      #     :error_log_file  => ['/var/log/nginx/foo-error.log' ], })
      #   # [ <LogAspect @name="access_log" @files=['/var/log/nginx/foo-access.log'] >,
      #   #   <LogAspect @name="error_log"  @files=['/var/log/nginx/foo-error.log']  > ]
      #
      def harvest(run_context, sys, subsys, info)
        []
      end

      #
      # Extract attributes matching the given pattern.
      #
      # @param [Hash]   info   -- hash of key-val pairs
      # @param [Regexp] regex  -- filter for keys matching this pattern
      #
      # @yield on each match
      # @yieldparam [String, Symbol] key   -- the matching key
      # @yieldparam [Object]         val   -- its value in the info hash
      # @yieldparam [MatchData]      match -- result of the regexp match
      # @yieldreturn [Aspect]        block should return an aspect
      #
      # @return [Array<Aspect>] collection of the block's results
      def attr_matches(info, regexp)
        results = []
        info.each do |key, val|
          next unless (match = regexp.match(key.to_s))
          result = yield(key, val, match)
          result.lint!
          results << result
        end
        results.sort_by{|asp| asp.name }
      end

      # add this class to the list of registered aspects
      def register!
        Aspect.registered[klass_handle] = self
      end

      # strip off module part and '...Aspect' from class name
      # @example ClusterChef::FooAspect.klass_handle # :foo
      def klass_handle
        @klass_handle ||= self.name.to_s.gsub(/.*::(\w+)Aspect\z/,'\1').gsub(/([a-z\d])([A-Z])/,'\1_\2').downcase.to_sym
      end

      def rsrc_matches(rsrc_clxn, resource_name, cookbook_name)
        results = []
        rsrc_clxn.each do |rsrc|
          next unless rsrc.resource_name.to_s == resource_name.to_s
          next unless rsrc.cookbook_name.to_s =~ /#{cookbook_name}/
          result = block_given? ? yield(rsrc) : rsrc
          results << result if result
        end
        results.uniq
      end
    end
    def self.included(base) ; base.extend(ClassMethods) ; end
  end

  #
  # * scope[:run_state]
  #
  # from the eponymous service resource,
  # * service.path
  # * service.pattern
  # * service.user
  # * service.group
  #
  class DaemonAspect < Struct.new(:name,
      :pattern,    # pattern to detect process
      :run_state ) # desired run state

    include Aspect; register!
    def self.harvest(run_context, sys, subsys, info)
      rsrc_matches(run_context.resource_collection, :service, sys) do |rsrc|
        next unless rsrc.name =~ /#{sys}_#{subsys}/
        svc = self.new(rsrc.name, rsrc.pattern)
        svc.run_state = info[:run_state].to_s if info[:run_state]
        svc
      end
    end
  end

  class PortAspect < Struct.new(:name,
      :flavor,
      :port_num,
      :addrs)
    include Aspect; register!
    ALLOWED_FLAVORS = [:http, :https, :pop3, :imap, :ftp, :jmx, :ssh, :nntp, :udp, :selfsame]
    def self.allowed_flavors() ALLOWED_FLAVORS ; end

    def self.harvest(run_context, sys, subsys, info)
      attr_aspects = attr_matches(info, /^((.+_)?port)$/) do |key, val, match|
        name   = match[1]
        flavor = match[2].to_s.empty? ? :port : match[2].gsub(/_$/, '').to_sym
        # p [match.captures, name, flavor].flatten
        self.new(name, flavor, val.to_s)
      end
    end
  end

  class DashboardAspect < Struct.new(:name, :flavor,
      :url)
    include Aspect; register!
    ALLOWED_FLAVORS = [ :http, :jmx ]
    def self.allowed_flavors() ALLOWED_FLAVORS ; end

    def self.harvest(run_context, sys, subsys, info)
      attr_aspects = attr_matches(info, /^(.*dash)_port(s)?$/) do |key, val, match|
        name   = match[1]
        flavor = (name == 'dash') ? :http_dash : name.to_sym
        url    = "http://#{private_ip_of(run_context.node)}:#{val}/"
        self.new(name, flavor, url)
      end
    end
  end

  #
  # * scope[:log_dirs]
  # * scope[:log_dir]
  # * flavor: http, etc
  #
  class LogAspect < Struct.new(:name,
      :flavor,
      :dirs )
    include Aspect; register!
    ALLOWED_FLAVORS = [ :http, :log4j, :rails ]

    def self.harvest(run_context, sys, subsys, info)
      attr_matches(info, /^log_dir(s?)$/) do |key, val, match|
        name = 'log'
        self.new(name, name.to_sym, val)
      end
    end
  end

  #
  # * attributes with a _dir or _dirs suffix
  #
  class DirectoryAspect < Struct.new(:name,
      :flavor,  # log, conf, home, ...
      :dirs    # directories pointed to
      )
    include Aspect; register!
    ALLOWED_FLAVORS = [ :home, :conf, :log, :tmp, :pid, :data, :lib, :journal, ]
    def self.allowed_flavors() ALLOWED_FLAVORS ; end

    def self.harvest(run_context, sys, subsys, info)
      attr_aspects = attr_matches(info, /(.*)_dir(s?)$/) do |key, val, match|
        name = match[1]
        self.new(name, name.to_sym, val)
      end
      rsrc_aspects = rsrc_matches(run_context.resource_collection, :directory, sys) do |rsrc|
        rsrc
      end
      # [attr_aspects, rsrc_aspects].flatten.each{|x| p x }
      attr_aspects
    end
  end

  #
  # Code assets (jars, compiled libs, etc) that another system may wish to
  # incorporate
  #
  class ExportedAspect < Struct.new(:name,
      :flavor,
      :files)
    include Aspect; register!

    ALLOWED_FLAVORS = [:jars, :confs, :libs]
    def self.allowed_flavors() ALLOWED_FLAVORS ; end

    def flavor=(val)
      val = val.to_sym unless val.nil?
      super(val)
    end

    def lint
      errors  = []
      errors += lint_flavor
      errors + super()
    end

    def self.harvest(run_context, sys, subsys, info)
      attr_matches(info, /^exported_(.*)$/) do |key, val, match|
        name = match[1]
        self.new(name, name.to_sym, val)
      end
    end
  end

  #
  # manana
  #

  # # usage constraints -- ulimits, java heap size, thread count, etc
  # class UsageLimitAspect
  # end
  # # deploy
  # # package
  # # account (user / group)
  # class CookbookAspect < Struct.new( :name,
  #     :deploys, :packages, :users, :groups, :depends, :recommends, :supports,
  #     :attributes, :recipes, :resources, :authors, :license, :version )
  # end
  #
  # class CronAspect
  # end
  #
  # class AuthkeyAspect
  # end
end
