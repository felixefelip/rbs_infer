# frozen_string_literal: true

module RbsInfer::Inference
  # What each `attr_reader`/`attr_writer`/`attr_accessor` of a class holds.
  #
  # One map, assembled from four sources that have to be consulted in order,
  # because each one only fills what the previous left empty:
  #
  #   1. `initialize` — `self.x = param`, typed by the param's own call sites;
  #   2. the rest of the class body — `self.x = Foo.new` anywhere, plus the
  #      element types an `Array[untyped]` picks up from `<<`;
  #   3. the writes from OUTSIDE — `receiver.x = value`, which only the
  #      cross-class pass can see, and which therefore cannot be asked for until
  #      the method parameter types exist;
  #   4. the definite-initialization rule, which needs the finished map.
  #
  # The split into `infer` and `finalize` is that dependency, not a preference:
  # steps 3-4 need `method_param_types`, whose own inference reads the attr types
  # from steps 1-2. Between the two the Analyzer runs the parameter pass.
  #
  # Reading `initialize` also answers a question about the CONSTRUCTOR rather
  # than the attrs — which of its parameters may be nil — so `enrich_initialize_types`
  # lives here too, sharing the one walk over the body.
  class AttrTypeInferrer
    # `parsed_target` may be nil (a consumer that never parsed a target file);
    # every source above then has nothing to read and the map comes out empty.
    #
    # `constant_resolver` has to be the TARGET-AWARE one (the Analyzer's
    # `constant_arg_resolver`, which carries the target file's own constants) —
    # `self.x = SOME_CONSTANT` in `initialize` resolves against it, and the
    # env-only variant answers nothing for a constant the target itself declares.
    def initialize(target_class:, parsed_target:, method_type_resolver:, constant_resolver:, return_type_resolver:)
      @target_class = target_class
      @parsed_target = parsed_target
      @method_type_resolver = method_type_resolver
      @constant_resolver = constant_resolver
      @return_type_resolver = return_type_resolver
    end

    # Steps 1-2: everything the class's own body says.
    def infer(init_arg_types, members)
      attr_types = from_initialize(init_arg_types)

      if (body = class_body(members))
        body.attr_types.each { |name, type| attr_types[name] ||= type }
        refine_collection_types(attr_types, body.collection_element_types)
      end

      attr_types
    end

    # Steps 3-4, once `method_param_types` exists.
    #
    # One call rather than two on purpose: the setter step deliberately does NOT
    # decide nilability, precisely because the rule below applies it uniformly to
    # every getter afterwards. Splitting them would let a caller run the first
    # without the second, which is the bug the rule was written to fix — an attr
    # typed from a local write (`self.name = value.name`, never set in
    # `initialize`) wrongly stayed non-nil (felixefelip/rbs_infer#71, follow-up).
    def finalize(attr_types, members, method_param_types:)
      apply_external_setter_types(attr_types, members, method_param_types)
      apply_definite_init_nilability(attr_types, members)
    end

    # `initialize`'s parameters gain what the attrs know, and then the ones
    # written `= nil` widen.
    #
    # The order is the whole point: widening first would double the `?` on a type
    # that arrived nilable from `attr_types` already. Both halves mutate
    # `init_arg_types` in place and it is returned for the caller's convenience.
    def enrich_initialize_types(init_arg_types, attr_types)
      attr_types.each do |attr_name, type|
        current = init_arg_types[attr_name]
        init_arg_types[attr_name] = type if current.nil? || current == "untyped"
      end

      # A param with a literal `nil` default accepts nil however non-nil every
      # observed call site is — the same rule `ParamTypeInferrer` applies to
      # ordinary methods, for the one method it does not own.
      nil_default_params.each do |param_name|
        current = init_arg_types[param_name]
        next if current.nil? || current == "untyped"

        init_arg_types[param_name] = RbsInfer::Signatures::RbsParserUtil.nilablize(current)
      end

      init_arg_types
    end

    private

    # `self.x = <expr>` inside `initialize`, typed by what the expression is.
    def from_initialize(init_arg_types)
      visitor = initialize_body or return {}

      default_types = visitor.keyword_defaults
      nil_defaults = visitor.nil_default_params

      visitor.self_assignments.each_with_object({}) do |(attr_name, expr_info), attr_types|
        type = assigned_type(expr_info, init_arg_types, default_types, nil_defaults)
        attr_types[attr_name] = type if type
      end
    end

    def assigned_type(expr_info, init_arg_types, default_types, nil_defaults)
      case expr_info[:kind]
      when :param
        # self.x = x → the type comes from the call sites, or from the default
        param_name = expr_info[:name]
        call_site_type = init_arg_types[param_name]
        call_site_type = nil if call_site_type == "untyped"
        type = call_site_type || default_types[param_name]
        # A param with a literal `nil` default (`def initialize(name: nil); @name
        # = name; end`) lets the ivar receive nil however non-nil every caller
        # is. Say so in the declaration.
        type = RbsInfer::Signatures::RbsParserUtil.nilablize(type) if type && nil_defaults.include?(param_name)
        type
      when :param_method
        # self.x = param.method → resolve the param's type, then the method's
        param_type = init_arg_types[expr_info[:param_name]]
        param_type = nil if param_type.nil? || param_type == "untyped"
        @method_type_resolver.resolve(param_type, expr_info[:method_name], arg_types: nil) if param_type
      when :call
        # self.x = something.method → resolve it through RBS
        if expr_info[:class_name] && expr_info[:method_name] && @method_type_resolver
          resolved = @method_type_resolver.resolve_class_method(expr_info[:class_name], expr_info[:method_name])
          resolved == "self" ? expr_info[:class_name] : resolved
        else
          expr_info[:type]
        end
      when :constant, :literal
        expr_info[:type]
      end
    end

    def refine_collection_types(attr_types, element_types)
      element_types.each do |attr_name, types|
        current = attr_types[attr_name]
        next unless current&.start_with?("Array[untyped]")

        attr_types[attr_name] = "Array[#{types.to_a.join(" | ")}]"
      end
    end

    # Fills `attr_types` for writable attrs whose type could only come from
    # external `receiver.attr = value` call-sites (their `attr=` parameter,
    # inferred by the cross-class pass). Nilability is NOT decided here — see
    # `finalize`.
    def apply_external_setter_types(attr_types, members, method_param_types)
      writable = members.select { |m| [:attr_accessor, :attr_writer].include?(m.kind) }
      return if writable.empty?

      writable.each do |m|
        # Don't override a type already inferred from a local write.
        next if attr_types[m.name] && attr_types[m.name] != "untyped"

        setter_params = method_param_types["#{m.name}="]
        inferred = setter_params&.values&.reject { |t| t.nil? || t == "untyped" }&.first
        next unless inferred

        attr_types[m.name] = inferred
      end
    end

    # Definite-initialization rule, applied uniformly to every attr that has a
    # GETTER (`attr_reader`/`attr_accessor`) once `attr_types` is fully
    # assembled — no matter where the type came from (the initializer, a local
    # `self.x =` write, or an external setter). If the backing ivar is never
    # assigned in `initialize`, the getter can observe the pre-assignment `nil`,
    # so the type is nilable. A pure `attr_writer` has no getter and keeps its
    # bare accepted-value type.
    def apply_definite_init_nilability(attr_types, members)
      return unless @parsed_target

      getters = members.select { |m| [:attr_reader, :attr_accessor].include?(m.kind) }
      return if getters.empty?

      initialized = @return_type_resolver.collect_prism_initialized_ivars(@parsed_target.tree)

      getters.each do |m|
        next if initialized.include?(m.name)
        type = attr_types[m.name]
        next if type.nil? || type == "untyped"

        attr_types[m.name] = RbsInfer::Signatures::RbsParserUtil.nilablize(type)
      end
    end

    # `initialize`'s body, walked once. Both what it assigns to the attrs and
    # which of its parameters default to `nil` come out of the same visitor —
    # they used to be two identical walks over the same tree.
    def initialize_body
      return nil unless @parsed_target
      return @initialize_body if defined?(@initialize_body)

      @initialize_body = InitializeBodyAnalyzer.new(constant_resolver: @constant_resolver)
      @parsed_target.tree.accept(@initialize_body)
      @initialize_body
    end

    def nil_default_params
      initialize_body&.nil_default_params || Set.new
    end

    # `self.attr = Foo.new(...)` in ANY method of the class, and local variables
    # sharing an attr's name. Nil when there is nothing to read — no parsed
    # target, or a class that declares no attr at all.
    #
    # Returned as the visitor rather than as its answers: `attr_types` and
    # `collection_element_types` both come from it, and asking twice would walk
    # the tree twice.
    def class_body(members)
      return nil unless @parsed_target

      attr_names = members.select { |m| [:attr_accessor, :attr_reader, :attr_writer].include?(m.kind) }
                          .map(&:name)
                          .to_set
      return nil if attr_names.empty?

      visitor = ClassBodyAttrAnalyzer.new(
        attr_names: attr_names,
        method_type_resolver: @method_type_resolver,
        constant_resolver: @constant_resolver,
        target_class: @target_class
      )
      @parsed_target.tree.accept(visitor)
      visitor
    end
  end
end
