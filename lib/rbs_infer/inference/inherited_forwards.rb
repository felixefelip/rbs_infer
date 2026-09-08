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
  # A forward qualifies only when it is TRANSPARENT: the dispatcher's arguments
  # ARE the handler's, position for position, untouched. That is a claim about
  # the whole `def`, not about the call node — a leading parameter the dispatcher
  # keeps for itself, or a `shift` that peels one off, shifts every argument by
  # one and would type the handler's first parameter from the caller's control
  # argument. A wrong parameter type is worse than none, because it reads as an
  # answer (the argument `extract_cross_class_args` already makes about splats).
  class InheritedForwards
    # `source_index` and `parse_cache` find and read the ancestor's source.
    # Neither is defaulted: without them this silently answers "no forwards" —
    # the pre-#331 behaviour — instead of failing
    # (docs/engineering/required-threaded-deps.md).
    #
    # The RBS resolver is built here rather than injected, as
    # `NewCallCollector#rbs_definition_resolver` does: it holds no caller
    # context, only its own memoization of the loaded environment.
    #
    # NOTE the bootstrap: `inherited?` asks the RBS what the target's singleton
    # inherits, so on a cold run with no `sig/` yet this answers nothing and the
    # types arrive on a later pass of the stabilization loop, like every other
    # cross-file fact.
    def initialize(target_class:, source_index:, parse_cache:)
      @target_class = target_class
      @source_index = source_index
      @parse_cache = parse_cache
      @rbs_definition_resolver = RbsInfer::Signatures::RbsDefinitionResolver.new
    end

    # `{ "dispatch" => ["handle"] }` — the forward's name, and every target
    # method its arguments belong to. A list, because one dispatcher can drive
    # several (`h.setup(*args); h.handle(*args)`) and keeping one would leave the
    # rest `untyped` with no signal.
    def for_methods(method_names)
      return {} if method_names.empty?

      method_names.each_with_object({}) do |method_name, acc|
        forwards_into(method_name).each { |forward| (acc[forward] ||= []) << method_name }
      end
    end

    # The names of every singleton method under `root` that transparently hands
    # its whole argument list to `<a fresh instance of self>.<method_name>`.
    #
    # Purely syntactic and free of the RBS environment, which is what makes the
    # transparency rule testable on its own. Whether the target actually
    # INHERITS one of these is the separate question `inherited?` answers.
    def self.transparent_forwards(root, method_name)
      singleton_defs(root).select { |defn| transparent_forward?(defn, method_name) }
                          .map { |defn| defn.name.to_s }
                          .uniq
    end

    # `def self.x` and the `class << self` form, which is the dominant Rails
    # spelling for the same thing.
    #
    # NOT a module's instance method — the one spelling `extend` carries to a
    # host. `new` inside it is the host, so the shape is sound and the RBS half
    # would resolve it; recognizing it here needs a way to tell that module
    # method apart from an ordinary instance method calling a `new` of its own.
    # Nor `class_methods do`, which reaches the pipeline as a `module
    # ClassMethods` only AFTER `ClassMethodsExpander`, while this reads the raw
    # source `ParseCache` holds. Both are open (felixefelip/rbs_infer#331).
    def self.singleton_defs(root)
      explicit = RbsInfer::Analyzer.find_all_nodes(root) { |n| n.is_a?(Prism::DefNode) && n.receiver.is_a?(Prism::SelfNode) }
      reopened = RbsInfer::Analyzer.find_all_nodes(root) { |n| n.is_a?(Prism::SingletonClassNode) }
                                   .flat_map { |sc| RbsInfer::Analyzer.find_all_nodes(sc) { |n| n.is_a?(Prism::DefNode) && n.receiver.nil? } }
      explicit + reopened
    end

    def self.transparent_forward?(defn, method_name)
      params = defn.parameters
      return false unless defn.body
      # A dispatcher that keeps parameters of its own is not transparent: the
      # handler's first parameter would be typed from an argument the dispatcher
      # consumed. `&block` is the one exception — it occupies no argument
      # position.
      return false unless only_rest_and_keyrest?(params)

      rest = RestParamMarker.name_from(params)
      keyrest = keyrest_name(params)
      return false unless rest || keyrest

      locals = new_locals(defn.body)
      forwards = RbsInfer::Analyzer.find_all_nodes(defn.body) do |n|
        n.is_a?(Prism::CallNode) && n.name.to_s == method_name && n.receiver &&
          instance_of_self?(n.receiver, locals) && splats_exactly?(n, rest, keyrest)
      end
      return false if forwards.empty?

      # ...and nothing else in the body may touch what is being forwarded:
      # `args.shift`, `args = args.drop(1)`, `kwargs.delete(:tag)` all leave the
      # splat looking untouched at the call while the values have moved.
      untouched?(defn.body, [rest, keyrest].compact)
    end

    def self.only_rest_and_keyrest?(params)
      return false unless params.is_a?(Prism::ParametersNode)

      params.requireds.empty? && params.optionals.empty? && params.keywords.empty? &&
        params.posts.empty?
    end

    # No write to the forwarded names, and every read of them a SPLAT.
    #
    # Splatting hands over the elements, never the collection, so no callee can
    # reach back and change what the next forward will send. Any other read
    # exposes the object itself: `args.shift` reads it as a receiver, `handle(args)`
    # passes it whole. A write (`args = args.drop(1)`) is out for the same reason
    # — the handler stops receiving what the caller sent, while the call node
    # still reads as a faithful splat.
    #
    # Reads in a SECOND forward are fine and must be: one dispatcher driving
    # `h.setup(*args, **kwargs)` and then `h.handle(*args, **kwargs)` is the full
    # template method, and both handlers receive the caller's arguments.
    def self.untouched?(body, names)
      reads = RbsInfer::Analyzer.find_all_nodes(body) do |n|
        n.is_a?(Prism::LocalVariableReadNode) && names.include?(n.name.to_s)
      end
      return true if reads.empty?

      writes = RbsInfer::Analyzer.find_all_nodes(body) do |n|
        n.is_a?(Prism::LocalVariableWriteNode) && names.include?(n.name.to_s)
      end
      return false unless writes.empty?

      splatted = RbsInfer::Analyzer.find_all_nodes(body) { |n| n.is_a?(Prism::SplatNode) || n.is_a?(Prism::AssocSplatNode) }
                                   .map { |n| n.is_a?(Prism::SplatNode) ? n.expression : n.value }
                                   .to_set
      reads.all? { |read| splatted.include?(read) }
    end

    # The locals holding a fresh instance — `handler = new`. A receiverless
    # `new` inside a singleton method is `self.new`, so the local is an instance
    # of whatever class the call site named.
    #
    # EVERY assignment to the name has to be a `new`: this walk has no order, so
    # a local later reassigned to something else would otherwise stay marked for
    # the rest of the body.
    def self.new_locals(body)
      writes = RbsInfer::Analyzer.find_all_nodes(body) { |n| n.is_a?(Prism::LocalVariableWriteNode) }
      writes.group_by { |write| write.name.to_s }
            .select { |_, assignments| assignments.all? { |write| bare_new?(write.value) } }
            .keys.to_set
    end

    def self.instance_of_self?(receiver, locals)
      case receiver
      when Prism::LocalVariableReadNode then locals.include?(receiver.name.to_s)
      when Prism::CallNode then bare_new?(receiver)
      else false
      end
    end

    # `new` or `self.new` — NOT `Other.new`, which is a fixed class and carries
    # none of the call site's receiver.
    def self.bare_new?(node)
      return false unless node.is_a?(Prism::CallNode) && node.name == :new

      node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)
    end

    # The arguments are the rest and keyrest, splatted, and nothing else.
    def self.splats_exactly?(call, rest, keyrest)
      args = call.arguments&.arguments or return false
      expected = (rest ? 1 : 0) + (keyrest ? 1 : 0)
      return false unless args.size == expected

      index = 0
      if rest
        return false unless splat_of?(args[index], rest)

        index += 1
      end
      keyrest ? double_splat_of?(args[index], keyrest) : true
    end

    def self.splat_of?(arg, name)
      arg.is_a?(Prism::SplatNode) && arg.expression.is_a?(Prism::LocalVariableReadNode) &&
        arg.expression.name.to_s == name
    end

    def self.double_splat_of?(arg, name)
      return false unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

      elements = arg.elements
      elements.size == 1 && elements.first.is_a?(Prism::AssocSplatNode) &&
        elements.first.value.is_a?(Prism::LocalVariableReadNode) &&
        elements.first.value.name.to_s == name
    end

    def self.keyrest_name(params)
      return nil unless params.respond_to?(:keyword_rest)

      keyrest = params.keyword_rest
      keyrest.respond_to?(:name) && keyrest.name ? keyrest.name.to_s : nil
    end

    # `private` below governs instance methods only; these are the internals of
    # `transparent_forwards`, which is the one class method meant to be called.
    private_class_method :singleton_defs, :transparent_forward?, :only_rest_and_keyrest?, :untouched?,
                         :new_locals, :instance_of_self?, :bare_new?, :splats_exactly?, :splat_of?,
                         :double_splat_of?, :keyrest_name

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
  end
end
