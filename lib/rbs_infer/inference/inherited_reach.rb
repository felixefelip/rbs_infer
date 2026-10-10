# frozen_string_literal: true

module RbsInfer::Inference
  # The classes below the target whose calls reach one of the target's own
  # methods (felixefelip/rbs_infer#412, #414):
  #
  #     class Base;           def call(name) = name; end
  #     class Kid < Base;     end                              # Kid.new runs Base#initialize
  #     class Other < Base;   def call(name) = super; end      # its super runs Base#call
  #
  # - `reach("initialize")` gives the classes whose `new` runs the target's
  #   `initialize` (`constructs`), so `Kid.new(...)` is its call site, and
  #   those whose own `initialize` reaches it through `super` (`supers`).
  # - `supers_by_method` gives, for any methods and on either side (`def call`
  #   and `def self.call`), the classes whose own method of that name reaches
  #   the target's through `super`.
  #
  # Which method runs is the RBS definition's answer, as everywhere else. The
  # source checks it: the RBS is the previous pass's output, so a class whose
  # source defines the method may not declare it yet, and then the RBS answers
  # with an ancestor's. Read as is, `Kid.new(3, :x)` would put `Integer` on
  # `Base`'s first parameter, and the next pass would keep it. A class on the
  # way whose source may define the method therefore takes the chain out,
  # whatever the RBS says.
  class InheritedReach
    Reach = Struct.new(:constructs, :supers)

    # For a collector whose usages are not `initialize`'s: nothing reaches it.
    NONE = Reach.new(Set.new.freeze, Set.new.freeze).freeze

    SIDES = %i[instance singleton].freeze

    # The macros that define a method by the name they are given.
    ATTR_SUFFIXES = { attr_reader: [""], attr_writer: ["="], attr_accessor: ["", "="] }.freeze
    NAMING_MACROS = %i[alias_method define_method].freeze

    class << self
      # The `def`s written in a class body itself, on `side`: each statement
      # that is one, under any wrapper (`private def call`, `memoize def call`,
      # `private_class_method def self.call`), and for `:singleton` the
      # `def self.`s and the `def`s of a `class << self` in the body. Not one
      # in a block or inside another method.
      def body_defs(class_node, side)
        body_statements(class_node, side).filter_map do |stmt, singleton_body|
          defn = unwrap(stmt)
          next unless defn.is_a?(Prism::DefNode) && (defn.receiver.nil? || defn.receiver.is_a?(Prism::SelfNode))

          defn if (side == :singleton) == (singleton_body || defn.receiver.is_a?(Prism::SelfNode))
        end
      end

      # Every name a class body may define a method by, on `side`: its
      # `def`s, and what `attr_*`, `alias`, `alias_method` and
      # `define_method` name. A reading meant to over-approximate: a name
      # here takes a chain out, which only costs a call site.
      def defined_names(class_node, side)
        names = body_defs(class_node, side).map { |defn| defn.name.to_s }
        body_statements(class_node, side).each do |stmt, singleton_body|
          next unless (side == :singleton) == singleton_body

          names.concat(macro_names(unwrap(stmt)))
        end
        names.to_set
      end

      private

      # `[statement, inside class << self?]` for each statement of the body,
      # and of each `class << self` in it when `side` is `:singleton`.
      def body_statements(class_node, side)
        statements = statements_of(class_node.body)
        own = statements.map { |stmt| [stmt, false] }
        return own unless side == :singleton

        own + statements.grep(Prism::SingletonClassNode)
                        .select { |sclass| sclass.expression.is_a?(Prism::SelfNode) }
                        .flat_map { |sclass| statements_of(sclass.body).map { |stmt| [stmt, true] } }
      end

      def statements_of(body)
        body.is_a?(Prism::StatementsNode) ? body.body : []
      end

      # The definition a receiverless one-argument call wraps, however deep:
      # `private memoize def call` is `def call`, `private attr_reader :x` is
      # `attr_reader :x`.
      def unwrap(stmt)
        node = stmt
        while node.is_a?(Prism::CallNode) && node.receiver.nil?
          arguments = node.arguments&.arguments || []
          inner = arguments.first
          break unless arguments.size == 1 && (inner.is_a?(Prism::DefNode) || (inner.is_a?(Prism::CallNode) && inner.receiver.nil?))

          node = inner
        end
        node
      end

      def macro_names(node)
        case node
        when Prism::AliasMethodNode
          node.new_name.is_a?(Prism::SymbolNode) ? [node.new_name.unescaped] : []
        when Prism::CallNode
          return [] unless node.receiver.nil?

          names = (node.arguments&.arguments || []).filter_map do |arg|
            arg.unescaped if arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
          end
          if (suffixes = ATTR_SUFFIXES[node.name])
            names.flat_map { |name| suffixes.map { |suffix| "#{name}#{suffix}" } }
          elsif NAMING_MACROS.include?(node.name)
            names.take(1)
          else
            []
          end
        else
          []
        end
      end
    end

    # `source_index` and `parse_cache` read the subclasses' source, and the
    # resolver their RBS. None is defaulted: without them this silently answers
    # NONE (docs/engineering/required-threaded-deps.md).
    def initialize(target_class:, source_index:, parse_cache:, rbs_definition_resolver:)
      @target_class = target_class
      @source_index = source_index
      @parse_cache = parse_cache
      @resolver = rbs_definition_resolver
      @sources = {}
    end

    def reach(method_name)
      return NONE if parents.empty?

      method_name = method_name.to_s
      constructs = Set.new
      supers = Set.new
      parents.each_key do |name|
        next if between(name).any? { |ancestor| defines?(ancestor, :instance, method_name) }

        if defines?(name, :instance, method_name)
          supers << relative(name) if @resolver.super_method_owner(name, method_name, kind: :instance) == target
        elsif method_name == "initialize" && @resolver.method_owner(name, method_name) == target
          constructs << relative(name)
        end
      end
      Reach.new(constructs.freeze, supers.freeze)
    end

    # `{ instance: { "call" => Set["Kid"] }, singleton: { "build" => Set["Kid"] } }`:
    # for each of `method_names`, on each side, the classes whose own method
    # of that name reaches the target's through `super`. Methods none reaches
    # are left out. One walk over the descendants, whatever the number of
    # methods.
    def supers_by_method(method_names)
      wanted = method_names.to_set(&:to_s)
      result = SIDES.to_h { |side| [side, {}] }
      parents.each_key do |name|
        chain = between(name)
        SIDES.each do |side|
          (source(name).names[side] & wanted).each do |method_name|
            next if chain.any? { |ancestor| defines?(ancestor, side, method_name) }
            next unless @resolver.super_method_owner(name, method_name, kind: side) == target

            (result[side][method_name] ||= Set.new) << relative(name)
          end
        end
      end
      result.reject { |_, by_method| by_method.empty? }
    end

    # The files that write the body of any of `names`: the only ones a
    # `super` in it can be in.
    def defining_files(names)
      names.each_with_object(Set.new) { |name, files| files.merge(source(absolute(name)).files) }
    end

    private

    Source = Struct.new(:names, :files)

    def target
      @target ||= absolute(@target_class)
    end

    def parents
      @parents ||= @resolver.descendant_parents(@target_class)
    end

    # The classes strictly between `name` and the target.
    def between(name)
      chain = []
      current = parents[name]
      while current && current != target
        chain << current
        current = parents[current]
      end
      chain
    end

    def defines?(name, side, method_name)
      source(name).names[side].include?(method_name)
    end

    # What the source writes for class `name`, in every file that writes its
    # body: the names it may define on each side, and those files.
    def source(name)
      @sources[name] ||= begin
        fqn = relative(name)
        names = SIDES.to_h { |side| [side, Set.new] }
        files = Set.new
        @source_index.files_referencing(fqn).each do |file|
          entry = @parse_cache.get(file) or next
          class_bodies(entry.result.value, fqn).each do |node|
            files << file
            SIDES.each { |side| names[side].merge(self.class.defined_names(node, side)) }
          end
        end
        Source.new(names, files)
      end
    end

    def class_bodies(root, fqn, outer = nil, found = [])
      return found unless root.is_a?(Prism::Node)

      if root.is_a?(Prism::ClassNode) || root.is_a?(Prism::ModuleNode)
        segment = RbsInfer::Analyzer.extract_constant_path(root.constant_path)
        if segment
          found << root if root.is_a?(Prism::ClassNode) && declared_names(segment, outer).include?(fqn)
          outer = outer ? "#{outer}::#{segment}" : segment
        end
      end
      root.compact_child_nodes.each { |child| class_bodies(child, fqn, outer, found) }
      found
    end

    # The classes `class <segment>` may declare inside `outer`: the one in the
    # current nesting, and for `class Ex::Foo` the `Foo` in whichever `Ex`
    # resolves from there.
    def declared_names(segment, outer)
      return [segment] unless outer
      return ["#{outer}::#{segment}"] unless segment.include?("::")

      parts = outer.split("::")
      parts.size.downto(0).map { |depth| [*parts.take(depth), segment].join("::") }
    end

    def absolute(name)
      name.start_with?("::") ? name : "::#{name}"
    end

    def relative(name)
      name.delete_prefix("::")
    end
  end
end
