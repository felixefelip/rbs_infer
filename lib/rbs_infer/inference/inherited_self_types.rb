# frozen_string_literal: true

module RbsInfer
  module Inference
    # What `self` is inside a class's instance method, narrowed from the class to
    # the subclasses it is invoked on:
    #
    #     class Animal; def introduce = speak("hello"); end
    #     class Dog < Animal; def speak(greeting) = greeting; end
    #     Dog.new.introduce
    #
    # `introduce` runs on a `Dog` and nothing else, so its `self` is `Dog`, and
    # its `speak` is `Dog#speak`. `InvokerSelfTypes` answers the same question for
    # a module's methods; this one reads a call made on a receiver, whose type is
    # the checker's.
    #
    # nil unless every invocation can be placed, and nil when one of them runs on
    # the class itself: the narrowing only ever removes what no call site uses. A
    # method nothing invokes keeps its class, so a bare call in it does too.
    class InheritedSelfTypes
      Invocation = Struct.new(:kind, :node, :owner, :method_name)

      UNKNOWN_TYPES = [RBS::Types::Bases::Any, RBS::Types::Bases::Top, RBS::Types::Bases::Self,
                       RBS::Types::Bases::Instance, RBS::Types::Interface, RBS::Types::Variable].freeze

      def initialize(source_index:, parse_cache:, steep_bridge:)
        @source_index = source_index
        @parse_cache = parse_cache
        @steep_bridge = steep_bridge
      end

      # `{ "Zoo::Animal" => { "introduce" => "Dog" } }` for the classes `root`
      # declares whose instance methods narrow.
      def narrowed(root)
        ClassBodies.collect(root).each_with_object({}) do |(name, nodes), acc|
          defs = nodes.flat_map { |node| InheritedReach.body_defs(node, :instance) }
                      .map { |defn| defn.name.to_s }.uniq
                      .filter_map { |method_name| (self_type = narrow(name, method_name)) && [method_name, self_type] }
                      .to_h
          acc[name] = defs unless defs.empty?
        end
      end

      # The same answer as sidecar entries, anchored on the class's leaf name. A
      # leaf two classes of the file share is left out: the anchor could not tell
      # them apart.
      def entries_for(root)
        leaves = ClassBodies.collect(root).keys.map { |name| leaf(name) }.tally
        narrowed(root).filter_map do |name, defs|
          { "anchor" => leaf(name), "defs" => defs } if leaves[leaf(name)] == 1
        end
      end

      # `{ "Zoo::Animal#introduce" => "Dog" }`.
      def by_def(root)
        narrowed(root).each_with_object({}) do |(name, defs), acc|
          defs.each { |method_name, self_type| acc["#{name}##{method_name}"] = self_type }
        end
      end

      # `source` with each narrowed method annotated where Steep reads it, as the
      # sidecar has it annotated for `steep check`.
      def inject(source)
        entries_for(Prism.parse(source).value).reduce(source) do |code, entry|
          Steep::Source::ModuleSelfTypes.inject_defs(code, defs: entry["defs"], anchor: entry["anchor"])
        end
      end

      # The files with a bare call to one of `method_names` in a method that runs
      # on `class_name`, which need not name it.
      def files_running_on(class_name, method_names)
        target = relative(class_name)
        method_names.flat_map { |name| @source_index.files_with_bare_call(name) }.to_set.select do |file|
          entry = @parse_cache.get(file)
          entry && by_def(entry.result.value).each_value.any? { |self_type| names(self_type).include?(target) }
        end
      end

      # The union of the classes `class_name#method_name` runs on, or nil.
      def narrow(class_name, method_name)
        state = memo
        key = [class_name, method_name.to_s]
        return state[:answers][key] if state[:answers].key?(key)
        return nil if state[:open].include?(key)

        state[:answers][key] = format(class_name, while_open(state, key) { selves_of(*key) })
      end

      private

      def while_open(state, key)
        state[:open] << key
        yield
      ensure
        state[:open].delete(key)
      end

      def format(class_name, selves)
        selves.sort.join(" | ") if selves && !selves.empty? && !selves.include?(class_name)
      end

      # Hung off the checker's context, as `SteepBridge.shared` does: every answer
      # is read off the RBS and off the checker's types, so a reset drops it.
      def memo
        context = RbsInfer::Signatures::SteepEnvironment.steep_context
        unless @context.equal?(context)
          @context = context
          @memo = { answers: {}, open: Set.new, inheritors: {} }
          @resolver = RbsInfer::Signatures::RbsDefinitionResolver.new
        end
        @memo
      end

      def inheritors(class_name, method_name)
        memo[:inheritors][[class_name, method_name]] ||=
          InheritedReach.new(target_class: class_name, source_index: @source_index,
                             parse_cache: @parse_cache, rbs_definition_resolver: @resolver)
                        .inheritors(method_name)
      end

      def selves_of(class_name, method_name)
        runners = inheritors(class_name, method_name)
        return nil if runners.empty?

        @source_index.files_mentioning(method_name).each_with_object(Set.new) do |file, selves|
          found = file_selves(file, class_name, method_name, runners) or return nil
          selves.merge(found)
        end
      end

      def file_selves(file, class_name, method_name, runners)
        entry = @parse_cache.get(file) or return nil
        invocations = InvocationCollector.collect(entry.result.value, method_name) or return nil
        received, written = invocations.partition { |invocation| invocation.kind == :receiver }

        on_receivers = receivers_selves(entry.source, file, received, class_name, method_name, runners) or return nil
        on_receivers + written_selves(written, class_name, method_name, runners)
      end

      def written_selves(written, class_name, method_name, runners)
        written.flat_map do |invocation|
          if invocation.kind == :bare
            bare_selves(invocation, class_name, method_name, runners)
          else
            super_selves(invocation, class_name, method_name)
          end
        end
      end

      def receivers_selves(source, file, received, class_name, method_name, runners)
        return [] if received.empty?

        types = @steep_bridge.all_expression_types(source, file:)
        received.flat_map do |invocation|
          key = RbsInfer::Signatures::SteepBridge.prism_expression_key(invocation.node.location)
          spelled = types[key] or return nil
          receiver_selves(spelled, class_name, method_name, runners) or return nil
        end
      end

      # A receiver typed as an ancestor that answers the method may hold an
      # instance of the class, so it cannot be placed.
      def receiver_selves(spelled, class_name, method_name, runners)
        candidates = parsed_instance_names(spelled) or return nil
        ours, others = candidates.partition { |name| name == class_name || runners.include?(name) }
        ours unless others.any? { |name| ancestor_answering?(name, class_name, method_name) }
      end

      def parsed_instance_names(spelled)
        instance_names(RBS::Parser.parse_type(spelled))
      rescue RBS::ParsingError
        nil
      end

      def ancestor_answering?(name, class_name, method_name)
        @resolver.method_owner(name, method_name) && @resolver.descendant_parents(name).key?("::#{class_name}")
      end

      # The class names an instance of `type` may be, or nil where the type does
      # not say. A branch of another kind is a homonym's receiver, not ours.
      def instance_names(type)
        case type
        when RBS::Types::Union then type.types.map { |branch| instance_names(branch) or return nil }.flatten
        when RBS::Types::Optional then instance_names(type.type)
        when RBS::Types::Intersection, RBS::Types::ClassInstance then class_parts(type)
        when *UNKNOWN_TYPES then nil
        else []
        end
      end

      # A bare call in a method of the class or of an inheritor runs on whatever
      # that method runs on.
      def bare_selves(invocation, class_name, method_name, runners)
        caller = invocation.owner
        return [] unless caller == class_name || runners.include?(caller)
        return [] if caller == class_name && invocation.method_name == method_name

        names(narrow(caller, invocation.method_name) || caller)
      end

      def super_selves(invocation, class_name, method_name)
        reached = @resolver.super_method_owner(invocation.owner, method_name, kind: :instance)
        return [] unless reached == "::#{class_name}"

        names(narrow(invocation.owner, method_name) || invocation.owner)
      end

      def class_parts(type)
        parts = type.is_a?(RBS::Types::Intersection) ? type.types.grep(RBS::Types::ClassInstance) : [type]
        parts.map { |part| relative(part.name) }
      end

      def names(self_type) = self_type.split(" | ")

      def leaf(name) = name.split("::").last

      def relative(type_name) = type_name.to_s.delete_prefix("::")

      # The class bodies a file writes, by qualified name.
      class ClassBodies < Prism::Visitor
        def self.collect(root)
          visitor = new
          root.accept(visitor)
          visitor.found
        end

        attr_reader :found

        def initialize
          @found = Hash.new { |hash, name| hash[name] = [] }
          @path = []
          super
        end

        def visit_class_node(node)
          within(node) { |name| @found[name] << node }
        end

        def visit_module_node(node)
          within(node)
        end

        private

        def within(node)
          segment = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
          @path.push(segment) if segment
          yield @path.join("::") if segment && block_given?
          node.compact_child_nodes.each { |child| child.accept(self) }
          @path.pop if segment
        end
      end

      # Every place a file may invoke `method_name`, or nil where one cannot be
      # placed: a bare call in a module's instance method, whose `self` is a
      # host, and the method named as a symbol, which `send`, `method` and
      # `alias_method` invoke without a call node.
      class InvocationCollector < Prism::Visitor
        def self.collect(root, method_name)
          collector = new(method_name.to_sym)
          root.accept(collector)
          collector.unplaceable ? nil : collector.invocations
        end

        attr_reader :invocations, :unplaceable

        def initialize(method_name)
          @method_name = method_name
          @invocations = []
          @unplaceable = false
          @path = []
          @kinds = []
          @def = nil
          super()
        end

        def visit_class_node(node) = within(node, :class) { super }
        def visit_module_node(node) = within(node, :module) { super }

        def visit_singleton_class_node(node)
          inside(:singleton) { super }
        end

        def visit_def_node(node)
          inside(node.receiver || @def == :singleton ? :singleton : node) { super }
        end

        def visit_call_node(node)
          record_call(node) if node.name == @method_name
          super
        end

        def visit_super_node(node)
          record_super
          super
        end

        def visit_forwarding_super_node(node)
          record_super
          super
        end

        def visit_assoc_node(node)
          node.key.accept(self) unless node.key.is_a?(Prism::SymbolNode)
          node.value&.accept(self)
        end

        def visit_symbol_node(node)
          @unplaceable = true if node.unescaped == @method_name.to_s
          super
        end

        private

        def record_call(node)
          return @invocations << Invocation.new(:receiver, node.receiver) if node.receiver
          return unless @def.is_a?(Prism::DefNode)
          return @unplaceable = true if @kinds.last == :module

          @invocations << Invocation.new(:bare, nil, @path.join("::"), @def.name.to_s)
        end

        def record_super
          return unless @def.is_a?(Prism::DefNode) && @def.name == @method_name && @kinds.last == :class

          @invocations << Invocation.new(:super, nil, @path.join("::"), @method_name.to_s)
        end

        def inside(scope)
          outer = @def
          @def = scope
          yield
        ensure
          @def = outer
        end

        def within(node, kind, &)
          segment = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
          return yield unless segment

          @path.push(segment)
          @kinds.push(kind)
          inside(nil, &)
        ensure
          if segment
            @kinds.pop
            @path.pop
          end
        end
      end
    end
  end
end
