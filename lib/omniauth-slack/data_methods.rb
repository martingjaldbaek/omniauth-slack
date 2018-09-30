require 'hashie'
require 'omniauth'
require 'omniauth-slack/refinements'
require 'omniauth-slack/semaphore'

module OmniAuth
  module Slack
    using ArrayRefinements
    using StringRefinements
  
    class Hashy < Hashie::Hash
      include Hashie::Extensions::MergeInitializer
      include Hashie::Extensions::MethodReader
      include Hashie::Extensions::MethodQuery
      # Note that this extensions will introduce procs into the hash, which won't serialize.
      include Hashie::Extensions::IndifferentAccess
    end
    
    class Mashy < Hashie::Mash
    end

    # DataMethods: declarative method dependency management.
    # 
    # - Get the most data from the fewest API calls.
    # - Assign data gateway priority for methods that can pull from multiple gateways.
    # - Skip a descendant path traversal now, when you know the end point is going to be blocked/down.
    #
    # Include DataMethods module in your OmniAuth::Strategy class
    # to gain flexible method dependency management.
    # Control which data_methods get called and in what priority
    # with the provider block option 'dependencies':
    #
    #   provider ...
    #     dependencies 'my_api_method', 'another_api_method'
    #   end
    #
    # Example data-method declaration in the Strategy class:
    #
    # data_method :my_api_method do
    #   scope classic:'identity.basic', identity:'identity:read:user'
    #   scope team:'conversations:read', app_home:'chat:write'
    #   scope_logic: 'or'  # override the default logic (or) within each scope query.
    #   storage true  # override the name of the cache variable. default is method-name. false disables cache for this method.
    #   condition proc{ true }
    #   condition proc{ ! false }
    #   default_value Hash.new
    #   source :access_token do
    #     get('/api/users.identity', headers: {'X-Slack-User' => user_id}).parsed
    #   end
    # end
    #
    # data_method :user_name do
    #   source :my_api_method do
    #     user.name
    #   end
    # end

    module DataMethods
          
      def self.included(other)
        OmniAuth.logger.debug "#{other} included #{self}"
        other.instance_eval do
          prepend Semaphore
          extend Extensions
          singleton_class.send :attr_reader, :data_methods, :logger
          @logger = OmniAuth.logger
          @data_methods ||= Hashy.new
          if self.is_a? OmniAuth::Strategy
            option :dependencies #, nil  # string or array of strings.
            option :dependency_filter  # regexp describing all data-methods that should be managed/gated.
          end
        end
      end
      
      # Strategy instance dependencies.
      def dependencies(filter=nil)
        # If you provide a filter, this will return the master dependency list (filtered).
        # Otherwise return the user-defined dependencies, or the class-level deps with the user (or default) filter applied.
        raw = if !filter.nil?
          self.class.dependencies(filter).keys
        else
          options.dependencies || @dependencies ||= self.class.dependencies(dependency_filter).keys
        end
        
        case raw
        when String; eval(raw)
        when Proc; instance_eval(&raw)
        else raw
        end
      end
      
      def dependency_filter
        options.dependency_filter
      end
      
      def data_methods; self.class.data_methods; end
      
      # TODO: Consider getting rid of this, or at least not using it for built-in omniauth-slack 'info' keys/values.
      #       But keep it around for user-defined data methods that should be attached to the info hash.
      def apply_data_methods(rslt = Hashy.new)
        data_methods.each do |name, opts|
          key = opts[:info_key]
          #log(:debug, "Applying key '#{key}' with method '#{name}'")
          next unless key
          rslt[key] ||= send(name)
          #log(:debug, "Applying key '#{key}' with method '#{name}': #{rslt[key]}")
          rslt
        end
      end
      
      # Preload api calls with a pool of threads.
      def preload_data_with_threads(num_threads=1, method_names=dependencies)
        return unless num_threads > 0 && !@preloaded_data
        @preloaded_data = 1
        #preload_methods = method_names || dependencies + options.additional_data.to_h.keys
        preload_methods = case method_names
          #when String; method_names.split(SIMPLE_WORD_SPLIT_REGEXP)
          when String; method_names.words
          when Array; method_names
          else []
        end
        log :info, "Preloading (#{preload_methods.size}) methods with (#{num_threads}) threads"  #: #{preload_methods}"
        work_q = Queue.new
        preload_methods.each{|x| work_q.push x }
        workers = num_threads.to_i.times.map do
          Thread.new do
            begin
              while x = work_q.pop(true)
                log :debug, "Preloading #{x} in thread #{Thread.current.object_id}."
                send x
              end
            rescue ThreadError
            end
          end
        end
        workers.map(&:join); "ok"
      end
      

      module Extensions
      
        # NOTE: Temp for debugging
        def sort_with(a1, a2, unmatched=:beginning)
          prc = Proc.new if block_given?
          a1.sort_with(a2, unmatched, &prc)
        end

        # List DataMethod instances and their dependencies.
        def dependency_tree
          return {} unless data_methods.to_h.any?
          data_methods.inject({}){|h,a| k,v = a[0], a[1]; h[k] = v.dependency_hash; h}
        end

        # Strategy class dependencies.
        # Flattens compiled dependency_tree into an array of uniq strings.
        # TODO: I think this can be cleaned up.
        def dependencies(filter = nil)
          filter ||= /.*/
          dtree = dependency_tree
          deps  = dtree.values.inject([]){|ary,hsh| ary.concat hsh.keys}
          # TODO: Do we still need this meths list?
          meths = dtree.keys.select(){|k| k.to_s[filter]}
          both = (deps.uniq | meths).sort_with(dtree.keys)
          both.inject({}){|h, v| h[v] = deps.count(v.to_s); h}.select{|k,v| k[filter]}
        end  
        
        # Which dependencies are missing callable methods.
        def missing_dependencies
          dependencies.keys.select{|m| !method_defined?(m) && !private_method_defined?(m)}
        end
        
        # Build a DataMethod object from a hash or a block.
        def data_method(name, opts = Hashy.new)
          #logger.debug "(slack) Building data_method object (#{name}, #{opts})"
          
          data_methods[name] = case
            when block_given?
              DataMethod.new(name, self, opts, &Proc.new)  #opts.merge!(name: name)
            else
              DataMethod.new(name, self, opts)  #opts.merge!(name: name)
          end
                    
          define_method(name) do
            semaphore(name).synchronize { data_methods[__method__].call(self) }
          end
          
          data_methods[name]
        end
        
      end # Extensions
    end # DataMethods



    #####  DataMethod Class  #####

    class DataMethod < Hashy
      #prepend Semaphore
      
      def self.new(*args)
        opts = Mashy.new(args.last.is_a?(Hash) ? args.pop : {})
        name = args[0].to_s
        klass = args[1]
        setup_block  = Proc.new if block_given?
        new_object = allocate
        %w(name scope scope_opts condition source storage default_value setup_block info_key).each do |property|
          new_object[property] = nil
        end
        new_object[:name] = name if name
        new_object[:klass] = klass
        new_object[:setup_block] = setup_block if setup_block
        new_object.merge!(opts)
        new_object.send(:initialize, opts, &setup_block)
        new_object
      end
      
      def initialize(opts = {})
        log :debug, "Initialize #{self.name}."
        instance_eval &Proc.new if block_given?
      end
      
      def log(type, text)
        klass.logger.send(type, "(#{klass.name.split('::').last.downcase} data_method) #{text}") if klass.respond_to?(:logger)
      end
      
      # Get/set scope queries.
      # Expects same args as AccessToken#has_scope?
      #   query == hash or array of hashes
      #   opts (options) == hash of options
      def scope(*args)
        return self[__method__] unless args.any?
        self[:scope] ||= []
        #log :debug, "Declaring #{name}.scope: #{args}"
        query = args.shift
        opts = args.last
        self[:scope_opts] = opts if opts
        self[:scope] << query
        self[:scope].flatten!
      end
      
      # Get/set scope_opts (:and | :or).
      def scope_opts(opts={})
        return self[__method__] unless opts && opts.any?
        #log :debug, "Declaring #{name}.scope_opts: #{opts}"
        self[:scope_opts] = opts
      end
      
      # Get/set sources.
      def source(*args)
        return self[__method__] unless args.any?
        opts = args.last.is_a?(Hash) ? args.pop : Mashy.new
        name = args.shift if [String, Symbol].any?{|t| args[0].is_a?(t)}
        code = case
          when block_given?; Proc.new
          when opts[:code]; opts.delete(:code)
          when args[0].is_a?(Proc); args.shift
          when args.any?; args
          else nil
        end          
        self[:source] ||= Hashie::Array.new
        #log :debug, "Declaring #{name}.source: #{name}, #{opts}, #{prc}"
        source_hash = Mashy.new({name: name, code: code}.merge(opts))
        self[:source] << source_hash
      end
      
      # Get/set cache storage name (or disable with false).
      def storage(arg = nil)
        return self[__method__] unless arg
        #log :debug, "Declaring #{name}.cache_storage: #{arg}"
        self[:storage] = arg
      end
      
      # Get/set conditions.
      def condition(code = nil)
        code = block_given? ? Proc.new : code
        return self[__method__] unless code
        self[:condition] ||= []
        #log :debug, "Declaring #{name}.condition: #{code}"
        self[:condition] << code
      end
      
      # Get/set defaut_value.
      def default_value(arg = nil)
        return self[__method__] unless arg
        #log :debug, "Declaring #{name}.default_value: #{arg}"
        self[:default_value] = arg
      end



      # Dependencies for this DataMethod instance.
      # For example try this: Strategy.data_methods.each{|k,v| puts "#{k}: #{v.api_dependencies_array(Strategy).inspect}" };nil
      def dependency_array
        return [] unless source
        source.inject([]) do |ary,src|
          src_name = src[:name].to_s
          ary << src_name
          sub_method = klass.data_methods[src_name]
          sub_method ? ary | sub_method.dependency_array : ary 
        end
      end
      
      # Dependency tree for this DataMethod instance.
      # For example try this: Strategy.data_methods.each{|k,v| puts "#{k}: #{v.api_dependencies_hash(Strategy).inspect}" };nil
      # or try this: y Strategy.data_methods.inject({}){|h,a| k,v = a[0], a[1]; h[k] = v.api_dependencies_hash(Strategy); h}
      def dependency_hash
        return {} unless source
        source.inject({}) do |hsh,src|
          ary = []
          src_name = src[:name].to_s
          sub_method = klass.data_methods[src_name]
          hsh[src_name] = sub_method ? ary | sub_method.dependency_array : ary
          hsh
        end   
      end
      
      # Resolve all conditions and return true/false.
      def resolve_conditions(strategy, conditions = condition)
        #log :debug, "Resolve_conditions for data-method '#{name}' with conditions '#{conditions}'"
        return true unless conditions
        rslt = case conditions
          when Proc; strategy.instance_eval &conditions
          when String; strategy.send :eval, conditions.to_s
          when Array;
            if conditions.size > 1
              conditions.all?{|c| resolve_conditions(strategy, c)}
            else
              #strategy.send :eval, conditions[0]
              resolve_conditions(strategy, conditions[0])
            end
          else conditions
        end ? true : false
        #log :debug, "Resolve_conditions for '#{name}' with '#{conditions}' result '#{rslt}'"
        rslt
      end
      
      # Resolve all scope queries and return true/false.
      def resolve_scopes(strategy)
        scopes = scope
        (scopes && scopes.any?) ? strategy.send(:has_scope?, scopes, scope_opts) : true
      end
      
      # Resolve a single source-hash.
      def resolve_source(src, strategy)
        source_target = src.name
        source_code = src.code
        #log :debug, "Data method '#{name}' calling source_target '#{source_target}' with code '#{source_code}'."
        target_result = source_target.is_a?(String) ? strategy.send(:eval, source_target) : strategy.send(source_target)
        #log :debug, "Data method '#{name}' with source_target '#{source_target}': #{target_result.class}"
        
        if target_result
          result = case
            when source_code.is_a?(Proc)
              target_result.instance_eval(&source_code)
            when source_code.is_a?(String)
              target_result.send(:eval, source_code)
            when source_code.is_a?(Array)
              target_result.send(:eval, source_code.join('.'))
            when source_code.nil?
              target_result
            else
              nil
          end
        end
      end
      
      # Select valid accessible source to attempt.
      def select_sources(strategy)
        source = self.source
        strategy.instance_eval do
          strategy_dependencies = dependencies
          master_dependencies_filtered = dependencies(dependency_filter)
          source.select do |src|
            strategy_dependencies.include?(src.name.to_s) || !master_dependencies_filtered.include?(src.name.to_s)
          end.sort_with(strategy_dependencies){|v| v.name.to_s}
        end
      end
      
      # Wrap this around a block to cache result as ivar @<name-of-method>.
      def with_cache(strategy, &block)
        storage_name = storage || name
        ivar_data = strategy.instance_variable_get("@#{storage_name}")
        return ivar_data if ivar_data
        result = yield
        strategy.instance_variable_set("@#{storage_name}", result) if result && storage_name && storage != false
        result
      end
      
      # Call the entire data-method.
      def call(strategy)
        with_cache(strategy) do
          result = nil
          resolve_scopes(strategy) &&
          resolve_conditions(strategy) &&
          select_sources(strategy).each do |src|
            result = resolve_source(src, strategy)
            break if result
          end
          
          result ||= default_value
          #log :debug, "Data method '#{name}' returning: #{result}"
          #result
        end
      end
              
    end # DataMethod
  end # Slack
end # OmniAuth

