# frozen_string_literal: true

module RbsInfer::Inference
  # What `self` is inside a module's instance method, narrowed from *whatever
  # mixes the module in* to *whoever calls this method*.
  #
  # `ModuleSelfTypeAnnotator` answers the first question, and it answers it
  # right: a module extended by `Bar` and by `Baz` has, as a declaration, the
  # self type `(singleton(Bar) | singleton(Baz))`. But an ARGUMENT is not a
  # declaration. `Example23::Foo#bazinga` is invoked once, in `Bar`'s class
  # body, so the `self` it hands to `module_included.bazingado(self)` is
  # `singleton(Bar)` and nothing else — which a human reads off the source.
  # Typing that parameter with the union made `Baz.bazingado`'s body stop
  # checking, because `Baz` has no `log_something` (felixefelip/rbs_infer#222).
  #
  # The narrowing only ever REMOVES branches the declaration already listed, and
  # it declines — returning the declaration untouched — the moment the evidence
  # is incomplete. Three ways it can be:
  #
  # - the method is called on a RECEIVER somewhere (`x.bazinga`). What `self`
  #   is inside the callee is then the receiver's type, which this walk does not
  #   resolve, so the picture is no longer whole.
  # - a bare call sits in a MODULE's instance method and the module is not one
  #   of the declared branches. `self` there is whoever mixes THAT module in —
  #   a name this record does not carry — so the call cannot be placed. It
  #   covers the module's own body, where `self` is the whole union, and a
  #   sibling concern sharing a host.
  # - nothing calls it at all. An uncalled method says nothing about its `self`;
  #   narrowing to the empty set would be inventing a fact, not reading one.
  #
  # The observations are gathered by method NAME across the corpus, so most of
  # them belong to other methods that happen to share it. Those are dropped, not
  # counted and not a reason to decline: a bare call resolves in its caller's
  # own ancestry, and the declaration already lists every class whose ancestry
  # carries this module (`hosts_of`/`extenders_of` resolve through module hosts
  # to the classes). A caller outside that list is calling something else. Two
  # namespaces with the same method names used to blank each other's narrowing
  # (felixefelip/rbs_infer#227).
  #
  # Whole-program by construction, which is the assumption the analyzer already
  # makes everywhere else: the call sites it can see are the call sites there
  # are.
  class InvokerSelfTypes
    def initialize(source_index:, parse_cache:)
      @source_index = source_index
      @parse_cache = parse_cache
      @observed = {}
    end

    # `declared` is the module's self type as the annotators state it. Returns
    # it unchanged unless the call sites prove a narrower one.
    def narrow(method_name:, declared:)
      return declared if declared.nil? || method_name.nil?

      branches = union_branches(declared)
      return declared if branches.size < 2

      observed = observed_selves(method_name)
      return declared if observed.nil? || observed.empty?

      declared_branches = branches.to_set
      invokers = observed.filter_map do |self_type, module_instance|
        next self_type if declared_branches.include?(self_type)
        # Outside the declaration and unplaceable: `self` is a host this record
        # cannot name, and it might be one of ours.
        return declared if module_instance

        nil
      end.to_set
      return declared if invokers.empty?

      kept = branches.select { |branch| invokers.include?(branch) }
      return declared if kept.size == branches.size

      parenthesize(kept)
    end

    private

    # Same rule the annotator applies when it builds the declaration: a single
    # part is written bare, because the parentheses exist only to keep a `|` or
    # a `&` from binding wrong where the type lands.
    def parenthesize(parts)
      return parts.first if parts.size == 1 && !parts.first.include?(" & ")

      "(#{parts.join(" | ")})"
    end

    # The declaration arrives parenthesized and may hold intersections
    # (`Card & Card::Entropic`), so it is parsed rather than split on `|`.
    def union_branches(declared)
      type = RBS::Parser.parse_type(declared)
      case type
      when RBS::Types::Union then type.types.map(&:to_s)
      else [type.to_s]
      end
    rescue RBS::ParsingError, RBS::BaseError
      []
    end

    # Every `self` a call to `method_name` runs under, or nil when the evidence
    # is incomplete. Memoized per method name: the answer is a property of the
    # corpus, not of the module asking.
    def observed_selves(method_name)
      return @observed[method_name] if @observed.key?(method_name)

      @observed[method_name] = compute_observed_selves(method_name)
    end

    def compute_observed_selves(method_name)
      # `files_mentioning`, not `files_calling`/`files_with_bare_call`: those two
      # are candidate filters that over-approximate one way and under-approximate
      # the other, and a narrowing needs the whole picture or none of it. Whether
      # an occurrence is a call, and whether it has a receiver, is then decided on
      # the AST rather than on the text.
      files = @source_index.files_mentioning(method_name)
      return nil if files.empty?

      files.each_with_object(Set.new) do |file, acc|
        entry = @parse_cache.get(file) or return nil

        found = SelfContextCollector.collect(entry.result.value, method_name)
        return nil if found.nil?

        acc.merge(found)
      end
    end

    # Walks a file for bare calls to one method and records the `self` each runs
    # under, as `[self type, from a module's instance method?]`. Returns nil if
    # any of them cannot be placed at all.
    #
    # The flag is what tells a caller that resolves in its own ancestry — a
    # class, or a module's own singleton — from one whose `self` is somebody
    # else at runtime. Only the first kind can be dismissed for not appearing in
    # a declaration.
    class SelfContextCollector < Prism::Visitor
      def self.collect(root, method_name)
        collector = new(method_name)
        root.accept(collector)
        collector.unplaceable ? nil : collector.selves
      end

      attr_reader :selves, :unplaceable

      def initialize(method_name)
        @method_name = method_name.to_sym
        @selves = Set.new
        @unplaceable = false
        @path = []
        # nil in a class/module body, :instance in a `def x`, :singleton in a
        # `def self.x` or under `class << self`.
        @scope = nil
        # Whether the innermost enclosing declaration is a `module`.
        @module_scope = false
        super()
      end

      def visit_class_node(node) = with_path(node, module_scope: false) { super }
      def visit_module_node(node) = with_path(node, module_scope: true) { super }

      def visit_singleton_class_node(node)
        outer = @scope
        @scope = :singleton
        super
        @scope = outer
      end

      def visit_def_node(node)
        outer = @scope
        # `def self.x` inside a body, and any `def` already under `class << self`.
        @scope = (node.receiver || @scope == :singleton) ? :singleton : :instance
        super
        @scope = outer
      end

      def visit_call_node(node)
        record(node) if node.name == @method_name
        super
      end

      private

      def record(node)
        # A receiver puts `self` inside the callee at the receiver's type, which
        # is not read here.
        return @unplaceable = true if node.receiver
        return @unplaceable = true if @path.empty?

        owner = @path.join("::")
        # A body and a `def self.` both run on the class object; an instance
        # method runs on an instance. A module's INSTANCE method is the one case
        # where that instance is not the thing named here but whoever mixes it
        # in, which is what the flag records.
        instance = @scope == :instance
        @selves << [instance ? owner : "singleton(#{owner})", instance && @module_scope]
      end

      def with_path(node, module_scope:)
        name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
        return yield if name.nil?

        @path.push(name)
        outer_scope = @scope
        outer_module = @module_scope
        @scope = nil
        @module_scope = module_scope
        yield
        @scope = outer_scope
        @module_scope = outer_module
        @path.pop
      end
    end
  end
end
