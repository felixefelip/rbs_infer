class RbsInfer::Signatures::SteepBridge
  class BlockAnalyzer
    def initialize(steep_bridge:)
      @steep_bridge = steep_bridge
    end

    # Methods that hand their own block to someone else, mapped to what that
    # callee declares the block to be:
    #
    #   { "authenticate_with_http_token" => { required: true, params: ["String", "…?"] } }
    #
    # Forwarding proves nothing by itself — `items.each(&block)` is perfectly
    # fine without a block — so the answer has to come from the CALLEE, and only
    # the checker can say which of its overloads applies. Against a possibly-nil
    # proc it picks `() -> ::Enumerator[Elem, self]` for `each` (no block
    # required) and the single required-block declaration for
    # `Token.authenticate`. That is the distinction rbs_infer cannot draw
    # structurally, and the reason this lives here (felixefelip/rbs_infer#149).
    #
    # Keys are `name` for instance methods and `self.name` for singletons, so a
    # class method never answers for its instance namesake.
    def forwarded_block_requirements(source_code)
      typing = @steep_bridge.type_check(source_code)
      return {} unless typing

      sites = Hash.new { |hash, key| hash[key] = [] }
      each_forwarded_block(typing) do |send_node, method_key|
        block = required_callee_block(typing, send_node)
        sites[method_key] << block if block
      end

      # Any site that requires a block makes the method require one — calling it
      # without one would reach that call. The parameters only survive while the
      # sites agree; past that, `nil` widens them back to `*untyped`.
      sites.transform_values do |found|
        agreed = found.uniq
        { required: true, params: agreed.size == 1 && agreed.first != :unknown ? agreed.first : nil }
      end
    end

    # Methods that STORE their block in an ivar, mapped to the `self` the block
    # will run against when that ivar is finally handed on:
    #
    #   { "included" => "Module" }
    #
    # `included(&block)` keeps the block and `base.class_eval(&@included_block)`
    # replays it, and `class_eval` declares `{ (self m) [self: self] -> U }` — so
    # the block's body was written against the includer, not against the module
    # that stored it. Nothing in the storing method says that; the callee does,
    # and only the checker can say which callee a call resolves to
    # (felixefelip/rbs_infer#208).
    #
    # Just the binding. The callee's block PARAMETERS are what it will pass, and
    # a block may always ignore what it is passed — the arity here is the storing
    # method's `*untyped`, honestly unknown. (It is also the shape that survives
    # union: `mod.send(:included, self)` has a receiver typed as every includer's
    # singleton at once, and merging their `included`s needs block parameter
    # lists that intersect. `*untyped` intersects with `ActiveSupport::Concern`'s
    # `()`, `(Module)` intersects with nothing, and the method drops out of the
    # union's shape entirely.)
    #
    # The two halves are joined by the IVAR, not by the method: the slot is what
    # the block lives in, and the method that stores it and the one that replays
    # it are routinely different (`included` stores, an `append_features` replays).
    # Keys as above: `name`, or `self.name` for singletons.
    def stored_block_self_types(source_code)
      typing = @steep_bridge.type_check(source_code)
      return {} unless typing

      stores = Hash.new { |hash, key| hash[key] = Set.new } # method key → ivar names it stores into
      sites = Hash.new { |hash, key| hash[key] = [] }       # ivar name → the calls it is handed to
      walk_stored_blocks(typing.source.node, nil, nil, false, stores, sites)

      bindings = sites.transform_values do |send_nodes|
        found = send_nodes.filter_map { |send_node| callee_block_self_type(typing, send_node) }.uniq
        # Sites that disagree say nothing: a block cannot have been written
        # against two different `self`s.
        found.first if found.size == 1
      end

      result = {}
      stores.each do |method_key, ivars|
        answers = ivars.filter_map { |ivar| bindings[ivar] }.uniq
        result[method_key] = answers.first if answers.size == 1
      end
      result
    end

    private

    # Yields `[send_node, method_key]` for every call that receives a
    # `&block_param` — the method's own block on its way out. `&:symbol` is a
    # proc literal built on the spot, not this method's block, so it is not a
    # forward and never reaches the callee lookup.
    #
    # The anonymous forward (`other(url, &)`) is the same thing said without a
    # name, and Parser spells it as a `block_pass` with a nil child rather than
    # an `lvar` one. Reading only the `lvar` shape left those methods with the
    # callee's requirement unasked — `?{ (*untyped) }` where the callee makes it
    # `{ (String) }` (felixefelip/rbs_infer#174).
    def each_forwarded_block(typing, &block)
      walk_forwarded_blocks(typing.source.node, nil, false, &block)
    end

    def walk_forwarded_blocks(node, method_key, singleton, &block)
      return unless node.is_a?(Parser::AST::Node)

      case node.type
      when :def then method_key = singleton ? "self.#{node.children[0]}" : node.children[0].to_s
      when :defs then method_key = "self.#{node.children[1]}"
      when :sclass then singleton = true
      when :send, :csend
        forwarded = node.children.any? do |child|
          next false unless child.is_a?(Parser::AST::Node) && child.type == :block_pass

          inner = child.children[0]
          inner.nil? || inner.type == :lvar
        end
        block.call(node, method_key) if forwarded && method_key
      end

      node.children.each { |child| walk_forwarded_blocks(child, method_key, singleton, &block) }
    end

    # Both halves of the store in one walk: `@x = block` (which method fills the
    # slot) and `foo(&@x)` (where the slot's contents go). Gathered separately
    # and matched afterwards, because the source may write them in either order
    # — the hand-rolled `included` stores in one branch of an `if` and replays in
    # the other.
    #
    # The method key and the block's parameter name are threaded the way
    # `walk_forwarded_blocks` threads its key: a nested `def` rebinds both, so
    # nothing inside it is attributed to the method it sits in.
    def walk_stored_blocks(node, method_key, block_param, singleton, stores, sites)
      return unless node.is_a?(Parser::AST::Node)

      case node.type
      when :def
        method_key = singleton ? "self.#{node.children[0]}" : node.children[0].to_s
        block_param = block_param_name(node.children[1])
      when :defs
        method_key = "self.#{node.children[1]}"
        block_param = block_param_name(node.children[2])
      when :sclass
        singleton = true
      when :ivasgn
        value = node.children[1]
        if method_key && block_param && value.is_a?(Parser::AST::Node) &&
           value.type == :lvar && value.children[0].to_s == block_param
          stores[method_key] << node.children[0].to_s
        end
      when :send, :csend
        ivar = node.children.filter_map { |child| passed_ivar(child) }.first
        sites[ivar] << node if ivar
      end

      node.children.each { |child| walk_stored_blocks(child, method_key, block_param, singleton, stores, sites) }
    end

    # The name of the `&block` parameter in an `args` node, or nil when the
    # method takes none — or takes an anonymous `&`, which cannot be stored.
    def block_param_name(args)
      return nil unless args.is_a?(Parser::AST::Node)

      blockarg = args.children.find { |child| child.is_a?(Parser::AST::Node) && child.type == :blockarg }
      blockarg&.children&.first&.to_s
    end

    # `&@x` — the ivar's name, when the argument is an ivar handed on as a block.
    def passed_ivar(node)
      return nil unless node.is_a?(Parser::AST::Node) && node.type == :block_pass

      inner = node.children[0]
      inner&.type == :ivar ? inner.children[0].to_s : nil
    end

    # What the callee binds `self` to inside the block it receives, as a type
    # string, or nil when it binds nothing (or the declarations disagree).
    def callee_block_self_type(typing, send_node)
      call = typing.call_of(node: send_node)
      decls = call.respond_to?(:method_decls) ? call.method_decls.to_a : []
      return nil if decls.empty?

      bindings = decls.map { |decl| block_self_binding(typing, send_node, decl.method_type.block) }.uniq
      bindings.size == 1 ? bindings.first : nil
    rescue StandardError
      nil
    end

    # `class_eval` declares `[self: self]`, and `self` there is the RECEIVER —
    # the one thing a declaration cannot spell, so it is read off the call.
    def block_self_binding(typing, send_node, block)
      self_type = block&.self_type or return nil

      if self_type.is_a?(RBS::Types::Bases::Self)
        receiver = send_node.children[0] or return nil
        self_type = typing.type_of(node: receiver) rescue nil
        return nil unless self_type
      end

      formatted = RbsInfer::Signatures::SteepBridge::TypeFormatter.format_type(self_type)
      formatted unless formatted == "untyped" || formatted == "bot" || formatted == "void"
    end

    # The block the callee declares, as `[param types]`, or `:unknown` when it
    # requires one whose shape we can't spell. `nil` when it requires none —
    # including when the receiver is untyped, where there is no callee to ask.
    #
    # Every declaration has to require it: a union receiver whose halves
    # disagree cannot force a block on this method.
    def required_callee_block(typing, send_node)
      call = typing.call_of(node: send_node)
      decls = call.respond_to?(:method_decls) ? call.method_decls.to_a : []
      return nil if decls.empty?
      return nil unless decls.all? { |decl| decl.method_type.block&.required }

      shapes = decls.map { |decl| callee_block_params(decl.method_type.block) }.uniq
      shapes.size == 1 ? shapes.first : :unknown
    rescue StandardError
      nil
    end

    # Only a plain list of required positionals is transcribable — an optional
    # or rest parameter in the callee's block has no place in the caller's
    # `(untyped, untyped)` shape, so it widens instead of guessing.
    def callee_block_params(block)
      function = block.type
      return :unknown unless function.respond_to?(:required_positionals)
      return :unknown unless function.optional_positionals.empty? && function.rest_positionals.nil? &&
                             function.trailing_positionals.empty? && function.required_keywords.empty?

      function.required_positionals.map { |param| RbsInfer::Signatures::SteepBridge::TypeFormatter.format_type(param.type) }
    end
  end
end
