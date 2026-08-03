class RbsInfer::Signatures::SteepBridge
  # What Steep says each method's body evaluates to, keyed by name and by
  # receiver kind.
  #
  # This is ONE source of return type, not the decision: combining it with
  # chain resolution, attr types and previously-generated RBS is the job of
  # `RbsInfer::Inference::ReturnTypeResolver`, which consumes this class.
  class ReturnTypeAnalyzer
    BLOCK_GENERIC_METHODS = %w[map collect].freeze

    def initialize(steep_bridge:)
      @steep_bridge = steep_bridge
    end

    # Returns { "method_name" => "ReturnType" } for all def nodes.
    # The return type is inferred from the body of the method.
    # Return types of instance methods (`def x`), keyed by name. Singleton
    # methods (`def self.x`) are excluded — fetch those via
    # `method_return_types_by_kind(...)[:singleton]` so a class method and an
    # instance method sharing a name don't clobber each other's entry.
    def method_return_types(source_code)
      method_return_types_by_kind(source_code)[:instance]
    end

    # Return types split by receiver kind: `{ instance: {name=>type},
    # singleton: {name=>type} }`. `def x` (Prism `:def`) and `def self.x`
    # (`:defs`) used to write the same name-keyed entry, so a homonymous
    # pair leaked one type onto the other (felixefelip/rbs_infer#33).
    #
    # A class method has a THIRD spelling, and the node type does not tell it
    # apart: inside `class << self` it is a plain `:def`. Filed as an instance
    # method it was then unreachable, because the reader asks by the member's
    # kind — which is `:class_method` — and every such method stayed `untyped`
    # while Steep had its type all along (felixefelip/rbs_infer#162).
    def method_return_types_by_kind(source_code)
      typing = @steep_bridge.type_check(source_code)
      return { instance: {}, singleton: {} } unless typing

      # Index BlockBodyTypeMismatch errors by block node identity
      block_mismatches = {}
      typing.errors.each do |err|
        next unless err.is_a?(Steep::Diagnostic::Ruby::BlockBodyTypeMismatch)

        block_mismatches[err.node.__id__] = err
      end

      instance = {}
      singleton = {}
      singleton_class_defs = singleton_class_def_ids(typing.source.node)

      typing.each_typing do |node, _type|
        next unless node.type == :def || node.type == :defs

        plain_def = node.type == :def
        singleton_def = !plain_def || singleton_class_defs.include?(node.__id__)
        method_name = plain_def ? node.children[0].to_s : node.children[1].to_s
        body = plain_def ? node.children[2] : node.children[3]
        next unless body

        body_type = typing.type_of(node: body)
        type_str = RbsInfer::Signatures::SteepBridge::TypeFormatter.format_type(body_type)

        # When Steep can't resolve generic type params in block calls,
        # resolve from the block body type or from BlockBodyTypeMismatch errors.
        resolved = resolve_block_generic_type(typing, body, type_str, block_mismatches)
        type_str = resolved if resolved

        next if type_str == "untyped"

        (singleton_def ? singleton : instance)[method_name] = type_str
      end

      { instance: instance, singleton: singleton }
    end

    private

    # Node ids of the `def`s written inside `class << self`.
    #
    # `class << obj` is a different thing and is deliberately excluded: those
    # are singleton methods of THAT object, not of the class. The ivar walker
    # already treats `:sclass` and `:defs` as one scope for the same reason —
    # in both, `self` is the class.
    def singleton_class_def_ids(node, inside: false, result: Set.new)
      return result unless node.is_a?(Parser::AST::Node)

      case node.type
      when :sclass then inside = node.children[0]&.type == :self
      when :class, :module then inside = false
      when :def then result << node.__id__ if inside
      end

      node.children.each { |child| singleton_class_def_ids(child, inside: inside, result: result) }
      result
    end

    # When Steep can't resolve generic type params bottom-up in block calls
    # (e.g., `.map { |x| expr }` → Array[untyped]), extract the block body type
    # that Steep already typed correctly and substitute it.
    # Also corrects cases where bidirectional checking from a wrong RBS declaration
    # produces BlockBodyTypeMismatch — uses the actual block body type.
    def resolve_block_generic_type(typing, body, type_str, block_mismatches)
      last_expr = body
      last_expr = body.children.last if body.type == :begin

      return nil unless last_expr&.type == :block

      send_node = last_expr.children[0]
      return nil unless send_node&.type == :send

      called_method = send_node.children[1].to_s
      return nil unless BLOCK_GENERIC_METHODS.include?(called_method)

      # Check for BlockBodyTypeMismatch — the actual type is the correct block body type
      mismatch = block_mismatches[last_expr.__id__]
      if mismatch
        actual_type = RbsInfer::Signatures::SteepBridge::TypeFormatter.format_type(mismatch.actual)
        if actual_type && actual_type != "untyped" && actual_type != "bot"
          return "Array[#{actual_type}]"
        end
      end

      # Extract block body type from Steep and construct Array[block_body_type].
      # For .map/.collect the return is always Array[block_body_type].
      # This handles both:
      # - Array[untyped]: Steep couldn't resolve the generic at all
      # - Array[{record with untyped}]: Steep's bidirectional typing used the
      #   declared type, but the actual block body has a more precise type
      #   (e.g., test_hash refined order: untyped → order: Nokogiri::XML::Node)
      block_body = last_expr.children[2]
      block_body = block_body.children.last if block_body&.type == :begin
      return nil unless block_body

      block_body_type = RbsInfer::Signatures::SteepBridge::TypeFormatter.format_type(typing.type_of(node: block_body))
      return nil if !block_body_type || block_body_type == "untyped" || block_body_type == "bot"

      resolved = "Array[#{block_body_type}]"
      resolved == type_str ? nil : resolved
    end
  end
end
