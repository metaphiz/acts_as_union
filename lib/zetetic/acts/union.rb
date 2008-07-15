module Zetetic #:nodoc:
  module Acts #:nodoc:  
    # = UnionCollection
    # UnionCollection provides useful application-space functionality
    # for emulating set unions acrosss ActiveRecord collections. 
    #
    # A UnionCollection can be initialized with zero or more sets, 
    # although generally it must contain at least two to do anything 
    # useful. Once initialized, the UnionCollection itself will 
    # act as an array containing all of the records from each of its 
    # member sets. The following will create a union object containing
    # the unique results of each individual find
    #
    #   union = Zetetic::Acts::UnionCollection.new(
    #     Person.find(:all, :conditions => "id <= 1"),                # set 0
    #     Person.find(:all, :conditions => "id >= 10 AND id <= 15"),  # set 1
    #     Person.find(:all, :conditions => "id >= 20")                # set 2
    #   )
    #
    # UnionCollection's more interesting feature is how it will 
    # intelligently forward ActiveRecord method calls to its member 
    # sets. This allows you to execute find operations directly on a 
    # UnionCollection, that will be executed on one or more 
    # of the member sets. Given the prior definition calling
    #
    #   union.find(:all, :conditions => "id <= 1 OR id >= 20")
    #
    # would return an array containing all the records from set 0
    # and set 2 (set 1 would be implicity excluded by the <tt>:conditions</tt>),
    #
    #   union.find_by_name('george')
    #
    # would return a single entry fetched from set 2 if george's id was >= 20,
    # 
    #   union.find(30)
    # 
    # would retrieve the record from set 2 with id == 30, and
    # 
    #   union.find(9)
    # 
    # would throw an #ActiveRecord::RecordNotFound exception because that id 
    # is specifically excluded from the union's member sets.
    # 
    # UnionCollection operates according to the following rules:
    #
    # * <tt>find :first</tt> - will search the sets in order and return the 
    #   first record that matches the find criteria.
    # * <tt>find :all</tt> - will search the sets, returning a 
    #   UnionCollection containing the all matching results. This UnionCollection
    #   can, of course, be searched further
    # * <tt>find(ids)</tt> - will look through all member sets in search
    #   of records with the given ids. #ActiveRecord::RecordNotFound will 
    #   be raised unless all the IDs are located.
    # * <tt>find_by_*</tt> - works as expected, behaving like <tt>find :first</tt>
    # * <tt>find_all_by_*</tt> - works as expected like <tt>find :all</tt>
    #
    class UnionCollection
      
      # UnionCollection should be initialized with a list of ActiveRecord collections
      #
      #   union = Zetetic::Acts::UnionCollection.new(
      #     Person.find(:all, :conditions => "id <= 1"),      # dynamic find set
      #     Person.managers                                   # an model association 
      #   )
      #
      def initialize(*sets)
        @sets = sets || []
        @sets.compact!     # remove nil elements
      end
      
      # Emulates the ActiveRecord::base.find method. 
      # Accepts all the same arguments and options
      #
      #   union.find(:first, :conditions => ["name = ?", "George"])
      #
      def find(*args)
        case args.first
          when :first then find_initial(:find, *args)
          when :all   then find_all(:find, *args)
          else             find_from_ids(:find, *args)
        end
      end
  
      def to_a
        load_sets
        @arr
      end
      
      private
      
      def load_sets
        @arr = []
        @sets.each{|set| @arr.concat set unless set.nil?} unless @sets.nil?
        @arr.uniq!
      end
      
      # start by passing the find to set 0. If no results are returned
      # pass the find on to set 1, and so on.
      def find_initial(method_id, *args)
        # conditions get anded together on subequent runs in this scope
        # by ActiveRecord. We'lls separate the conditions out, save a copy of the initial
        # state, and pass it to subsequent runs
        conditions = args[1][:conditions] if args.size > 1 and args[1].kind_of?(Hash)
        
        # this iteration is a great opportunity for future optimization - with
        # find initial there is no need to continue processing once we find
        # a match
        results = @sets.collect { |set| 
          args[1][:conditions] = conditions unless conditions.nil?
          set.empty? ? nil : set.send(method_id, *args)
        }.compact
        results.size > 0 ? results[0] : nil
      end
      
      def find_all(method_id, *args)
        # create a new UnionCollection with new member sets containing the 
        # results of the find accross the current member sets
        UnionCollection.new(*@sets.collect{|set| set.empty? ? nil : set.send(method_id, *Marshal::load(Marshal.dump(args))) })
      end
      
      # Invokes method against set1, catching ActiveRecord::RecordNotFound. if exception
      # is raised try the method execution against set2
      def find_from_ids(method_id, *args)
        res = []
        
        # another good target for future optimization - if only
        # one id is presented for the search there is no need to proxy
        # the call out to ever set - we can stop when we hit a match
        args.each do |id|
          @sets.each do |set|
            begin
              res << set.send(method_id, id) unless set.empty?
            rescue ActiveRecord::RecordNotFound
              # rethrow later
            end
          end
        end 
        
        res.uniq!
        if args.uniq.size != res.size
          #FIXME
          raise ActiveRecord::RecordNotFound.new "Couldn't find all records with IDs (#{args.join ','})"
        end
        args.size == 1 ? res[0] : res
      end
      
      # Handle find_by convienince methods
      def method_missing(method_id, *args, &block)
        if method_id.to_s =~ /^find_all_by/
          find_all method_id, *args, &block
        elsif method_id.to_s =~ /^find_by/
          find_initial method_id, *args, &block
        else
          load_sets
          @arr.send method_id, *args, &block
        end
      end
    end

    module Union
      def self.included(base)
        base.extend ClassMethods
      end

      module ClassMethods
        # = acts_as_union
        # acts_as_union simply presents a union'ed view of one or more ActiveRecord 
        # relationships (has_many or has_and_belongs_to_many, acts_as_network, etc).
        # 
        #   class Person < ActiveRecord::Base
        #     acts_as_network :friends
        #     acts_as_network :colleagues, :through => :invites, :foreign_key => 'person_id', 
        #                     :conditions => ["is_accepted = 't'"]
        #     acts_as_union   :aquantainces, [:friends, :colleagues]
        #   end
        #
        # In this case a call to the +aquantainces+ method will return a UnionCollection on both 
        # a person's +friends+ and their +colleagues+. Likewise, finder operations will work accross 
        # the two distinct sets as if they were one. Thus, for the following code
        # 
        #   stephen = Person.find_by_name('Stephen')
        #   # search for user by login
        #   billy = stephen.aquantainces.find_by_name('Billy')
        #
        # both Stephen's +friends+ and +colleagues+ collections would be searched for someone named Billy.
        # 
        # +acts_as_union+ doesn't accept any options.
        #
        def acts_as_union(relationship, methods)
          # define the accessor method for the union.
          # i.e. if People acts_as_union :jobs, this method is defined as def jobs
          class_eval <<-EOV
            def #{relationship}
              UnionCollection.new(#{methods.collect{|m| "self.#{m.to_s}"}.join(',')})
            end
          EOV
        end
      end
    end # module Union
  end  # module Acts
end
