# frozen_string_literal: true

require "prism"
require "set"

module RbsInfer::Project
  # Moves a block's *definition site* to the class/module that later evaluates
  # it. Ruby's `class_eval(&stored_block)` runs `def`s in that block against the
  # receiver, not the object whose class body happened to contain the block.
  #
  # The direct spelling (`Widget.class_eval do … end`) is handled by
  # ClassEvalExpander. This is the equally-static indirect spelling:
  #
  #   module Builder
  #     attr_reader :body
  #     def keep(&block) = @body = block
  #     def apply(source) = class_eval(&source.body)
  #   end
  #
  #   module Source
  #     extend Builder
  #     keep { def installed; end }
  #   end
  #
  #   class Target
  #     extend Builder
  #     apply(Source)
  #   end
  #
  # It expands that to a virtual reopening of Target containing `installed`.
  # ClassMemberCollector deliberately ignores arbitrary blocks, so the original
  # lexical call site remains available as type evidence without emitting the
  # method on Source. This is plain Ruby rather than a framework convention, so
  # it lives in Project alongside ClassEvalExpander.
  #
  # Deliberately conservative: a chain must name one storage method, one reader,
  # one stored block, and one constant target. Any ambiguity declines the replay.
  module StoredBlockReplayExpander
    REPLAY_METHODS = %i[class_eval module_eval].freeze

    module_function

    def expand(source)
      return nil unless source.include?("class_eval") || source.include?("module_eval")

      parsed = Prism.parse(source)
      return nil unless parsed.success?

      replays = Collector.new(source).collect(parsed.value)
      return nil if replays.empty?

      apply_replays(source, replays)
    end

    def apply_replays(source, replays)
      # A source block can only be replayed against one statically known target.
      # Multiple targets are ambiguous at runtime, so Collector rejects them.
      return nil unless replays.map { |replay| replay.block.body.location }.uniq.size == replays.size

      virtual_reopens = replays.map do |replay|
        body = replay.block.body
        body_source = source.byteslice(body.location.start_offset, body.location.end_offset - body.location.start_offset)
        "#{replay.kind} #{replay.target}\n#{body_source}\nend\n"
      end

      [source, virtual_reopens.join("\n")].join("\n")
    end

    Replay = Data.define(:target, :block, :kind)

    # Collects declarations and class-body calls in one lexical pass. It keeps
    # syntax, not guessed types: resolving `Foo` in `extend Foo` and `Baz` in
    # `apply(Baz)` uses the declarations that are actually present in the file.
    class Collector < Prism::Visitor
      Storage = Data.define(:owner, :method, :ivar)
      ReplayMethod = Data.define(:owner, :method, :parameter, :reader)
      StoredCall = Data.define(:owner, :subject, :method, :block)
      ApplyCall = Data.define(:owner, :subject, :method, :argument)

      def initialize(source)
        @source = source
        @scope = []
        @method_depth = 0
        @declarations = Set.new
        @declaration_kinds = {}
        @extends = []
        @storages = []
        @readers = []
        @replay_methods = []
        @stored_calls = []
        @apply_calls = []
        super()
      end

      def collect(root)
        root.accept(self)
        resolve_replays
      end

      def visit_class_node(node)
        with_scope(node) { super }
      end

      def visit_module_node(node)
        with_scope(node) { super }
      end

      def visit_def_node(node)
        collect_method_shape(node) if current_scope
        @method_depth += 1
        super
      ensure
        @method_depth -= 1
      end

      def visit_call_node(node)
        collect_class_body_call(node) if current_scope && @method_depth.zero?
        super
      end

      private

      def with_scope(node)
        name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
        return yield unless name

        qualified = qualify(name)
        @declarations << qualified
        @declaration_kinds[qualified] = node.is_a?(Prism::ModuleNode) ? "module" : "class"
        @scope << qualified
        yield
      ensure
        @scope.pop if @scope.last == qualified
      end

      def current_scope
        @scope.last
      end

      def qualify(name)
        name = name.to_s.sub(/\A::/, "")
        return name if name.include?("::")

        parent = @scope.last
        parent ? "#{parent}::#{name}" : name
      end

      def resolve_constant(node, context)
        name = RbsInfer::Analyzer.extract_constant_path(node)
        return nil unless name

        name = name.sub(/\A::/, "")
        return name if name.include?("::") && @declarations.include?(name)
        return name if name.start_with?("::")

        prefixes = context.to_s.split("::")
        prefixes.length.downto(1) do |length|
          candidate = "#{prefixes.take(length).join("::")}::#{name}"
          return candidate if @declarations.include?(candidate)
        end
        @declarations.include?(name) ? name : nil
      end

      def collect_method_shape(node)
        params = node.parameters
        block_name = params&.block&.name&.to_s
        method_name = node.name.to_s

        if block_name && (ivar = stored_block_ivar(node.body, block_name))
          @storages << Storage.new(owner: current_scope, method: method_name, ivar: ivar)
        end

        replay = replay_shape(node.body)
        return unless replay

        parameter, reader = replay
        @replay_methods << ReplayMethod.new(owner: current_scope, method: method_name, parameter: parameter, reader: reader)
      end

      def stored_block_ivar(body, block_name)
        nodes(body).filter_map do |node|
          next unless node.is_a?(Prism::InstanceVariableWriteNode)
          next unless node.value.is_a?(Prism::LocalVariableReadNode)
          next unless node.value.name.to_s == block_name

          node.name.to_s
        end.uniq.then { |ivars| ivars.first if ivars.size == 1 }
      end

      # `class_eval(&parameter.reader)` / `module_eval(&parameter.reader)`.
      # The receiver is deliberately limited to the method parameter: a replay
      # against arbitrary state needs a type/data-flow answer this source-only
      # pass does not have and must decline rather than guess.
      def replay_shape(body)
        shapes = nodes(body).filter_map do |node|
          next unless node.is_a?(Prism::CallNode) && REPLAY_METHODS.include?(node.name)
          pass = node.block
          next unless pass.is_a?(Prism::BlockArgumentNode)
          reader_call = pass.expression
          next unless reader_call.is_a?(Prism::CallNode) && reader_call.arguments.nil?
          next unless reader_call.receiver.is_a?(Prism::LocalVariableReadNode)

          [reader_call.receiver.name.to_s, reader_call.name.to_s]
        end.uniq
        shapes.first if shapes.size == 1
      end

      def collect_class_body_call(node)
        case node.name
        when :extend
          return unless bare_or_self?(node) && node.arguments

          node.arguments.arguments.each do |argument|
            @extends << [current_scope, argument]
          end
        else
          return unless bare_or_self?(node)

          if node.block.is_a?(Prism::BlockNode)
            @stored_calls << StoredCall.new(owner: nil, subject: current_scope, method: node.name.to_s, block: node.block)
          elsif node.arguments && node.arguments.arguments.size == 1
            @apply_calls << ApplyCall.new(owner: nil, subject: current_scope, method: node.name.to_s, argument: node.arguments.arguments.first)
          end
        end
      end

      def bare_or_self?(node)
        node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
      end

      def resolve_replays
        extenders = Hash.new { |hash, key| hash[key] = Set.new }
        @extends.each do |subject, raw_module|
          mod = resolve_constant(raw_module, subject)
          extenders[mod] << subject if mod
        end

        # `attr_reader :body` is collected from its lexical owner after all
        # declarations are known, so a relative `extend Builder` can resolve.
        collect_readers_from_source

        storage_by_owner_and_method = @storages.group_by { |storage| [storage.owner, storage.method] }
        replay_by_owner_and_method = @replay_methods.group_by { |replay| [replay.owner, replay.method] }
        reader_ivars = @readers.group_by { |owner, name| [owner, name] }.transform_values { |entries| entries.map(&:last).uniq }

        candidates = []
        @apply_calls.each do |apply|
          extenders.each do |owner, subjects|
            next unless subjects.include?(apply.subject)
            replay_entries = replay_by_owner_and_method[[owner, apply.method]]
            next unless replay_entries&.size == 1

            replay = replay_entries.first
            source_subject = resolve_constant(apply.argument, apply.subject)
            next unless source_subject && subjects.include?(source_subject)

            ivars = reader_ivars[[owner, replay.reader]]
            next unless ivars&.size == 1

            storage_entries = storage_by_owner_and_method.select do |(storage_owner, _), entries|
              storage_owner == owner && entries.size == 1 && entries.first.ivar == ivars.first
            end
            next unless storage_entries.size == 1

            storage_method = storage_entries.keys.first.last
            blocks = @stored_calls.select { |stored| stored.subject == source_subject && stored.method == storage_method }
            next unless blocks.size == 1

            kind = @declaration_kinds[apply.subject]
            next unless kind

            candidates << Replay.new(target: apply.subject, block: blocks.first.block, kind: kind)
          end
        end

        by_block = candidates.group_by { |candidate| candidate.block.location.start_offset }
        by_block.values.filter_map do |entries|
          targets = entries.map(&:target).uniq
          entries.first if targets.size == 1
        end
      end

      # `attr_reader` is a normal call in a class/module body; collect it in a
      # second short lexical walk because declarations must be known before a
      # relative constant can be resolved. Keeping reader recognition explicit
      # is what prevents an arbitrary method named `body` from being treated as
      # an ivar accessor.
      def collect_readers_from_source
        parsed = Prism.parse(@source)
        reader_collector = ReaderCollector.new
        parsed.value.accept(reader_collector)
        @readers.concat(reader_collector.readers)
      end

      def nodes(root)
        return [] unless root

        RbsInfer::Analyzer.find_all_nodes(root) { true }
      end

      class ReaderCollector < Prism::Visitor
        attr_reader :readers

        def initialize
          @scope = []
          @method_depth = 0
          @readers = []
          super()
        end

        def visit_class_node(node) = with_scope(node) { super }
        def visit_module_node(node) = with_scope(node) { super }

        def visit_def_node(node)
          @method_depth += 1
          super
        ensure
          @method_depth -= 1
        end

        def visit_call_node(node)
          if @method_depth.zero? && node.name == :attr_reader && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) && node.arguments
            node.arguments.arguments.each do |argument|
              @readers << [@scope.last, argument.unescaped.to_s, "@#{argument.unescaped}"] if argument.is_a?(Prism::SymbolNode)
            end
          end
          super
        end

        private

        def with_scope(node)
          name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
          return yield unless name

          name = name.sub(/\A::/, "")
          qualified = name.include?("::") ? name : [@scope.last, name].compact.join("::")
          @scope << qualified
          yield
        ensure
          @scope.pop if @scope.last == qualified
        end
      end
    end
  end
end
