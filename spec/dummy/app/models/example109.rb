# Active Record 8.0's `has_many` path, copied with the namespace renamed and cut
# to what `has_many :comments` runs (felixefelip/rbs_infer#392, item 8). Each
# step has a fixture of its own; this one checks that they compose.
#
# The macro is `has_records`, since the Active Record runtime generator takes a
# `has_many` under `app/models` as an association, and the memo is
# `generated_relation_methods`, since `generated_association_methods` is
# example90's. `pluralize_table_names` is a `class_attribute`, defined through
# example108's copy of Active Support's store. `association` is a stub: the
# path ends at the strings the builders evaluate.
#
# `has_records :comments` in `Post` runs `Builder::HasMany.build`, which creates
# a `HasManyReflection` holding `:comments`, builds and includes
# `Post::GeneratedRelationMethods` (`example109/core.rb`, as `core.rb` holds it
# in the gem), and defines `comments`, `comments=`, `comment_ids` and
# `comment_ids=` in it.
#
# `Post::GeneratedRelationMethods` is built and included, and `comments`,
# `comments=`, `comment_ids` and `comment_ids=` are defined in it.
# `association(:comments).reader` is a stub here, so `comments` answers `nil`;
# the records would come from the rest of Active Record's path.
#
# Nothing here states a type.
module Example109
  module Reflection
    class << self
      def add_reflection(ar, name, reflection)
        ar.clear_reflections_cache
        name = name.to_sym
        ar._reflections = ar._reflections.except(name).merge!(name => reflection)
      end

      def create(macro, name, scope, options, ar)
        reflection = reflection_class_for(macro).new(name, scope, options, ar)
        options[:through] ? ThroughReflection.new(reflection) : reflection
      end

      private
        def reflection_class_for(macro)
          case macro
          when :composed_of
            AggregateReflection
          when :has_many
            HasManyReflection
          when :has_one
            HasOneReflection
          when :belongs_to
            BelongsToReflection
          else
            raise "Unsupported Macro: #{macro}"
          end
        end
    end

    module ClassMethods
      def _reflect_on_association(association)
        _reflections[association.to_sym]
      end

      def clear_reflections_cache
        @__reflections = nil
      end
    end

    class AbstractReflection
      def initialize
        @class_name = nil
        @counter_cache_column = nil
        @inverse_of = nil
        @inverse_which_updates_counter_cache_defined = false
        @inverse_which_updates_counter_cache = nil
      end
    end

    class MacroReflection < AbstractReflection
      attr_reader :name

      attr_reader :scope

      attr_reader :options

      attr_reader :active_record

      attr_reader :plural_name

      def initialize(name, scope, options, active_record)
        super()
        @name          = name
        @scope         = scope
        @options       = normalize_options(options)
        @active_record = active_record
        @klass         = options[:anonymous_class]
        @plural_name   = active_record.pluralize_table_names ?
                            name.to_s.pluralize : name.to_s
      end

      def class_name
        @class_name ||= -(options[:class_name] || derive_class_name).to_s
      end

      def klass
        @klass ||= _klass(class_name)
      end

      def _klass(class_name)
        if active_record.name.demodulize == class_name
          return compute_class("::#{class_name}") rescue NameError
        end

        compute_class(class_name)
      end

      def compute_class(name)
        name.constantize
      end

      private
        def derive_class_name
          name.to_s.camelize
        end

        def normalize_options(options)
          counter_cache = options.delete(:counter_cache)

          if counter_cache
            active = true

            case counter_cache
            when String, Symbol
              column = -counter_cache.to_s
            when Hash
              active = counter_cache.fetch(:active, true)
              column = counter_cache[:column]&.to_s
            end

            options[:counter_cache] = { active: active, column: column }
          end

          options
        end
    end

    class AggregateReflection < MacroReflection
    end

    class AssociationReflection < MacroReflection
      def compute_class(name)
        if polymorphic?
          raise ArgumentError, "Polymorphic associations do not support computing the class."
        end

        begin
          klass = active_record.send(:compute_type, name)
        rescue NameError => error
          if error.name.match?(/(?:\A|::)#{name}\z/)
            message = "Missing model class #{name} for the #{active_record}##{self.name} association."
            message += " You can specify a different model class with the :class_name option." unless options[:class_name]
            raise NameError.new(message, name)
          else
            raise
          end
        end

        unless klass < Base
          raise ArgumentError, "The #{name} model class for the #{active_record}##{self.name} association is not an ActiveRecord::Base subclass."
        end

        klass
      end

      attr_reader :type, :foreign_type

      def initialize(name, scope, options, active_record)
        super
        @type = -(options[:foreign_type]&.to_s || "#{options[:as]}_type") if options[:as]
        @foreign_type = -(options[:foreign_type]&.to_s || "#{name}_type") if options[:polymorphic]
        @join_table = nil
        @foreign_key = nil
        @association_foreign_key = nil
        @association_primary_key = nil

        if options[:foreign_key].is_a?(Array)
          options[:query_constraints] = options.delete(:foreign_key)
        end

        ensure_option_not_given_as_class!(:class_name)
      end

      def collection?
        false
      end

      def polymorphic?
        options[:polymorphic]
      end

      private
        def ensure_option_not_given_as_class!(option_name)
          if options[option_name] && options[option_name].class == Class
            raise ArgumentError, "A class was passed to `:#{option_name}` but we are expecting a string."
          end
        end

        def derive_class_name
          class_name = name.to_s
          class_name = class_name.singularize if collection?
          class_name.camelize
        end
    end

    class HasManyReflection < AssociationReflection
      def macro; :has_many; end

      def collection?; true; end

      def association_class
        Associations::HasManyAssociation
      end
    end

    class HasOneReflection < AssociationReflection
      def macro; :has_one; end
    end

    class BelongsToReflection < AssociationReflection
      def macro; :belongs_to; end
    end

    class ThroughReflection < AbstractReflection
      def initialize(delegate_reflection)
        super()
        @delegate_reflection = delegate_reflection
      end

      private
        attr_reader :delegate_reflection

        delegate_methods = AssociationReflection.public_instance_methods -
          public_instance_methods

        delegate(*delegate_methods, to: :delegate_reflection)
    end
  end

  class AssociationNotFoundError < StandardError
    attr_reader :record, :association_name

    def initialize(record = nil, association_name = nil)
      @record           = record
      @association_name = association_name
      if record && association_name
        super("Association named '#{association_name}' was not found on #{record.class.name}; perhaps you misspelled it?")
      else
        super("Association was not found.")
      end
    end
  end

  module Associations
    module ClassMethods
      def has_records(name, scope = nil, **options, &extension)
        reflection = Builder::HasMany.build(self, name, scope, options, &extension)
        Reflection.add_reflection self, name, reflection
      end
    end

    class CollectionProxy
      def self.create(klass, association)
        new(klass, association)
      end

      def initialize(klass, association)
        @klass = klass
        @association = association
      end
    end

    class Association
      attr_reader :reflection

      def initialize(owner, reflection)
        @owner, @reflection = owner, reflection
      end

      def klass
        reflection.klass
      end

      private
        def ensure_klass_exists!
          klass
        end
    end

    class CollectionAssociation < Association
      def reader
        ensure_klass_exists!

        @proxy ||= CollectionProxy.create(klass, self)
      end
    end

    class HasManyAssociation < CollectionAssociation

      def writer(records); end

      def ids_reader; end

      def ids_writer(ids); end
    end

    module Builder
      class Association
        class << self
          attr_accessor :extensions
        end
        self.extensions = []

        def self.build(model, name, scope, options, &block)
          reflection = create_reflection(model, name, scope, options, &block)
          define_accessors(model, reflection)
          define_callbacks(model, reflection)
          define_validations(model, reflection)
          define_change_tracking_methods(model, reflection)
          reflection
        end

        def self.create_reflection(model, name, scope, options, &block)
          raise ArgumentError, "association names must be a Symbol" unless name.kind_of?(Symbol)

          extension = define_extensions(model, name, &block)
          options[:extend] = [*options[:extend], extension] if extension

          scope = build_scope(scope)

          Reflection.create(macro, name, scope, options, model)
        end

        def self.build_scope(scope)
          if scope && scope.arity == 0
            proc { instance_exec(&scope) }
          else
            scope
          end
        end

        def self.macro
          raise NotImplementedError
        end

        def self.define_extensions(model, name)
        end

        def self.define_callbacks(model, reflection)
          Association.extensions.each do |extension|
            extension.build(model, reflection)
          end
        end

        def self.define_accessors(model, reflection)
          mixin = model.generated_relation_methods
          name = reflection.name
          define_readers(mixin, name)
          define_writers(mixin, name)
        end

        def self.define_readers(mixin, name)
          mixin.class_eval <<-CODE, __FILE__, __LINE__ + 1
            def #{name}
              association(:#{name}).reader
            end
          CODE
        end

        def self.define_writers(mixin, name)
          mixin.class_eval <<-CODE, __FILE__, __LINE__ + 1
            def #{name}=(value)
              association(:#{name}).writer(value)
            end
          CODE
        end

        def self.define_validations(model, reflection)
        end

        def self.define_change_tracking_methods(model, reflection)
        end

        private_class_method :build_scope, :macro, :define_extensions,
          :define_callbacks, :define_accessors, :define_readers, :define_writers, :define_validations,
          :define_change_tracking_methods
      end

      class CollectionAssociation < Association
        CALLBACKS = [:before_add, :after_add, :before_remove, :after_remove]

        def self.define_callbacks(model, reflection)
          super
          name    = reflection.name
          options = reflection.options
          CALLBACKS.each { |callback_name|
            define_callback(model, callback_name, name, options)
          }
        end

        def self.define_extensions(model, name, &block)
          if block_given?
            extension_module_name = "#{name.to_s.camelize}AssociationExtension"
            extension = Module.new(&block)
            model.const_set(extension_module_name, extension)
          end
        end

        def self.define_callback(model, callback_name, name, options)
          full_callback_name = "#{callback_name}_for_#{name}"

          callback_values = Array(options[callback_name.to_sym])
          method_defined = model.respond_to?(full_callback_name)

          return if callback_values.empty? && !method_defined

          unless method_defined
            model.class_attribute(full_callback_name, instance_accessor: false, instance_predicate: false)
          end

          callbacks = callback_values.map do |callback|
            case callback
            when Symbol
              ->(method, owner, record) { owner.send(callback, record) }
            when Proc
              ->(method, owner, record) { callback.call(owner, record) }
            else
              ->(method, owner, record) { callback.send(method, owner, record) }
            end
          end
          model.send "#{full_callback_name}=", callbacks
        end

        def self.define_readers(mixin, name)
          super

          mixin.class_eval <<-CODE, __FILE__, __LINE__ + 1
            def #{name.to_s.singularize}_ids
              association(:#{name}).ids_reader
            end
          CODE
        end

        def self.define_writers(mixin, name)
          super

          mixin.class_eval <<-CODE, __FILE__, __LINE__ + 1
            def #{name.to_s.singularize}_ids=(ids)
              association(:#{name}).ids_writer(ids)
            end
          CODE
        end

        private_class_method :define_callback, :define_extensions, :define_readers, :define_writers
      end

      class HasMany < CollectionAssociation
        def self.macro
          :has_many
        end

        private_class_method :macro
      end
    end
  end

  class Base
    extend Core::ClassMethods
    extend Reflection::ClassMethods
    extend Associations::ClassMethods

    def self.pluralize_table_names = __class_attr_pluralize_table_names
    ::Example108::ClassAttribute.redefine(self, :pluralize_table_names, :__class_attr_pluralize_table_names, true)

    def self._reflections = __class_attr__reflections
    def self._reflections=(value)
      self.__class_attr__reflections = value
    end
    ::Example108::ClassAttribute.redefine(self, :_reflections, :__class_attr__reflections, {})

    class << self
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@_type_candidates_cache, Concurrent::Map.new)
      end

      protected
        def compute_type(type_name)
          if type_name.start_with?("::")
            type_name.constantize
          else
            type_candidate = @_type_candidates_cache[type_name]
            if type_candidate && type_constant = type_candidate.safe_constantize
              return type_constant
            end

            candidates = []
            name.scan(/::|$/) { candidates.unshift "#{$`}::#{type_name}" }
            candidates << type_name

            candidates.each do |candidate|
              constant = candidate.safe_constantize
              if candidate == constant.to_s
                @_type_candidates_cache[type_name] = candidate
                return constant
              end
            end

            raise NameError.new("uninitialized constant #{candidates.first}", candidates.first)
          end
        end
    end

    def initialize
      @association_cache = {}
    end

    def association(name)
      association = association_instance_get(name)

      if association.nil?
        unless reflection = self.class._reflect_on_association(name)
          raise AssociationNotFoundError.new(self, name)
        end
        association = reflection.association_class.new(self, reflection)
        association_instance_set(name, association)
      end

      association
    end

    private
      def association_instance_get(name)
        @association_cache[name]
      end

      def association_instance_set(name, association)
        @association_cache[name] = association
      end
  end

  class Comment < Base
  end

  class Post < Base
    has_records :comments
  end

  class Feed
    def self.comments = Post.new.comments
  end
end
