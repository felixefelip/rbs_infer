# frozen_string_literal: true

module RbsInfer::Inference
  # The dispatchers a class inherits, and which of its OWN methods each one
  # hands its arguments to (felixefelip/rbs_infer#331).
  #
  # The shape is the template method: a handler the subclass implements, invoked
  # only through a dispatcher the base class defines.
  #
  #     class Dispatcher
  #       def self.dispatch(*args, **kwargs)
  #         handler = new
  #         handler.handle(*args, **kwargs)   # `new` here is the SUBCLASS
  #         handler
  #       end
  #     end
  #
  #     Greeter.dispatch("ada", greeting: "hi")   # => Greeter#handle's arguments
  #
  # `new` inside an inherited singleton method is the receiver of the call, so
  # `Greeter.dispatch(...)` runs `Greeter#handle`. That is the whole licence for
  # reading such a call site as a call site of `handle` — and the receiver is
  # what says WHICH handler, which is exactly what the ancestry match in
  # `NewCallCollector#ancestry_match_key` had to drop, since a method inherited
  # from a base class has one declaration for every subclass.
  #
  # A forward qualifies only when it is TRANSPARENT: its arguments are the rest
  # and keyrest parameters, splatted, and nothing else. Anything else — an
  # argument added, reordered, or read — breaks the position-for-position
  # correspondence the caller's arguments are mapped by, and this answers
  # nothing rather than guessing.
  class InheritedForwards
    EMPTY = {}.freeze

    # `source_index` and `parse_cache` find and read the ancestor's source.
    # Neither is defaulted: without them this silently answers "no forwards" —
    # the pre-#331 behaviour — instead of failing
    # (docs/engineering/required-threaded-deps.md).
    #
    # The RBS resolver is built here rather than injected, as
    # `NewCallCollector#rbs_definition_resolver` does: it holds no caller
    # context, only its own memoization of the loaded environment.
    def initialize(target_class:, source_index:, parse_cache:)
      @target_class = target_class
      @source_index = source_index
      @parse_cache = parse_cache
      @rbs_definition_resolver = RbsInfer::Signatures::RbsDefinitionResolver.new
    end

    # `{ "dispatch" => "handle" }` — the forward's name, and the target method
    # its arguments belong to. Empty unless the target both defines a method
    # some ancestor forwards into AND inherits that forward.
    def for_methods(method_names)
      return EMPTY if method_names.empty?

      method_names.each_with_object({}) do |method_name, acc|
        forwards_into(method_name).each { |forward| acc[forward] = method_name }
      end
    end

    # The names of every `def self.<forward>(*args, **kwargs)` under `root` whose
    # body calls `<an instance of self>.<method_name>(*args, **kwargs)`.
    #
    # Purely syntactic and free of the RBS environment, which is what makes the
    # transparency rule testable on its own. Whether the target actually
    # INHERITS one of these is the separate question `inherited?` answers.
    def self.transparent_forwards(root, method_name)
      RbsInfer::Analyzer.find_all_nodes(root) { |n| n.is_a?(Prism::DefNode) && n.receiver.is_a?(Prism::SelfNode) }
        .select { |defn| transparent_forward?(defn, method_name) }
        .map { |defn| defn.name.to_s }
    end

    private

    # The forwards into `method_name`, found by asking which files CALL it: the
    # dispatcher's body does, and that index already exists. Walking the target's
    # superclass chain instead would miss a forward reached through an `extend`,
    # while the inheritance proof below covers both.
    def forwards_into(method_name)
      @source_index.files_calling(method_name).flat_map do |file|
        entry = @parse_cache.get(file)
        next [] unless entry

        self.class.transparent_forwards(entry.result.value, method_name)
            .select { |forward| inherited?(forward, entry) }
      end.uniq
    end

    def self.transparent_forward?(defn, method_name)
      rest = RestParamMarker.name_from(defn.parameters)
      keyrest = keyrest_name(defn.parameters)
      return false unless rest || keyrest
      return false unless defn.body

      locals = new_locals(defn.body)
      calls = RbsInfer::Analyzer.find_all_nodes(defn.body) do |n|
        n.is_a?(Prism::CallNode) && n.name.to_s == method_name && n.receiver
      end

      calls.any? do |call|
        instance_of_self?(call.receiver, locals) && splats_exactly?(call, rest, keyrest)
      end
    end

    # The locals holding a fresh instance — `handler = new`. A receiverless
    # `new` inside a singleton method is `self.new`, so the local is an instance
    # of whatever class the call site named.
    def self.new_locals(body)
      RbsInfer::Analyzer.find_all_nodes(body) { |n| n.is_a?(Prism::LocalVariableWriteNode) }
        .select { |write| bare_new?(write.value) }
        .map { |write| write.name.to_s }
        .to_set
    end

    def self.instance_of_self?(receiver, locals)
      case receiver
      when Prism::LocalVariableReadNode then locals.include?(receiver.name.to_s)
      when Prism::CallNode then bare_new?(receiver)
      else false
      end
    end

    # `new` or `self.new` — NOT `Other.new`, which is a different class and
    # carries none of the call site's receiver.
    def self.bare_new?(node)
      return false unless node.is_a?(Prism::CallNode) && node.name == :new

      node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
    end

    # The arguments are the rest and keyrest, splatted, and nothing else.
    def self.splats_exactly?(call, rest, keyrest)
      args = call.arguments&.arguments or return false

      expected = []
      expected << [Prism::SplatNode, rest] if rest
      expected << [Prism::KeywordHashNode, keyrest] if keyrest
      return false unless args.size == expected.size

      args.zip(expected).all? do |arg, (kind, name)|
        case kind.name
        when "Prism::SplatNode"
          arg.is_a?(Prism::SplatNode) && arg.expression.is_a?(Prism::LocalVariableReadNode) &&
            arg.expression.name.to_s == name
        else
          double_splat_of?(arg, name)
        end
      end
    end

    def self.double_splat_of?(arg, name)
      return false unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

      elements = arg.elements
      elements.size == 1 && elements.first.is_a?(Prism::AssocSplatNode) &&
        elements.first.value.is_a?(Prism::LocalVariableReadNode) &&
        elements.first.value.name.to_s == name
    end

    # The proof that the target reaches this forward: the RBS says its singleton
    # gets `forward` from a class OTHER than itself, and that class is the one
    # whose source this forward was read from. A same-named `def self.` on an
    # unrelated class answers nothing here, which is what keeps the receiver
    # filter honest — the whole defect being fixed is a match that ignored who
    # the receiver was.
    def inherited?(forward, entry)
      owner = @rbs_definition_resolver.method_owner("singleton(#{@target_class})", forward) or return false
      normalized = owner.sub(/\A::/, "")
      return false if normalized == @target_class.sub(/\A::/, "")

      declared_classes(entry).include?(normalized)
    end

    # The FULLY QUALIFIED names the file declares — `Example65::Dispatcher`, not
    # `Dispatcher`. `FileIndex` cannot answer this: it maps a class to a file by
    # path convention, so a base nested inside another declaration (which
    # `Example65::Dispatcher` is) resolves to nil there.
    def declared_classes(entry)
      NewCallCollector.collect_defined_class_names(entry.result.value)
    end

    def self.keyrest_name(params)
      return nil unless params.respond_to?(:keyword_rest)

      keyrest = params.keyword_rest
      keyrest.respond_to?(:name) && keyrest.name ? keyrest.name.to_s : nil
    end

    # `private` above governs instance methods only; these are the internals of
    # `transparent_forwards`, which is the one class method meant to be called.
    private_class_method :transparent_forward?, :new_locals, :instance_of_self?, :bare_new?,
                         :splats_exactly?, :double_splat_of?, :keyrest_name
  end
end
