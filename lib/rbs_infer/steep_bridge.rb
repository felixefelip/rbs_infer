require "steep"
require_relative "ivar_type_set"

module RbsInfer
  # Bridge to Steep's TypeConstruction for resolving expression types.
  #
  # Steep is a full Ruby type checker. We use it as an oracle to resolve
  # expression types (local variables, return types, method chains, ternaries,
  # conditionals, etc.) that would otherwise require manual implementation
  # for each Ruby expression pattern.
  #
  # The rbs_infer pipeline continues to handle:
  # - Caller-side parameter type inference
  # - Cross-file call analysis
  # - Attr inference via initialize
  # - RBS generation
  class SteepBridge
    # Shared RBS DefinitionBuilder, cached at the class level.
    # Both SteepBridge and RbsDefinitionResolver use the same RBS environment,
    # so we load it once and share it to avoid duplicating ~1s of loading.
    class << self
      def definition_builder
        current_dir = Dir.pwd
        if @definition_builder_loaded && @definition_builder_dir == current_dir
          return @definition_builder
        end
        @definition_builder_loaded = true
        @definition_builder_dir = current_dir
        @definition_builder = build_definition_builder
      end

      def reset!
        @definition_builder = nil
        @definition_builder_loaded = false
        @definition_builder_dir = nil
      end

      private

      def build_definition_builder
        require "rbs"

        loader = RBS::EnvironmentLoader.new

        Dir["sig/*/"].each { |d| loader.add(path: Pathname(d)) }
        Dir[".gem_rbs_collection/*/*/"].each { |ver_dir| loader.add(path: Pathname(ver_dir)) }

        env = RBS::Environment.from_loader(loader).resolve_type_names
        RBS::DefinitionBuilder.new(env: env)
      rescue LoadError, StandardError => _e
        nil
      end
    end

    def initialize
      @subtyping = nil
      @constant_resolver = nil
      @initialized = false
    end

    # Returns { "var_name" => "Type" } for all local variable assignments
    # in all methods of the given source code.
    # Result is keyed by method name: { "method_name" => { "var" => "Type" } }
    def local_var_types_per_method(source_code)
      typing = type_check(source_code)
      return {} unless typing

      result = Hash.new { |h, k| h[k] = {} }

      typing.each_typing do |node, type|
        # :lvasgn = local variable assignment (x = expr)
        # :procarg0 = single block parameter (|x|)
        # :arg = block parameter in multi-param blocks (|x, y|);
        #        also matches def params, but those are typically untyped and get filtered below
        next unless node.type == :lvasgn || node.type == :procarg0 || node.type == :arg
        type_str = format_type(type)
        next if type_str == "untyped" || type_str == "nil" || type_str == "bot"

        var_name = node.children[0].to_s
        method_name = find_enclosing_method(node, typing)
        next unless method_name

        result[method_name][var_name] = type_str
      end

      result
    end

    # Returns { "method_name" => "ReturnType" } for all def nodes.
    # The return type is inferred from the body of the method.
    def method_return_types(source_code)
      typing = type_check(source_code)
      return {} unless typing

      # Index BlockBodyTypeMismatch errors by block node identity
      block_mismatches = {}
      typing.errors.each do |err|
        next unless err.is_a?(Steep::Diagnostic::Ruby::BlockBodyTypeMismatch)
        block_mismatches[err.node.__id__] = err
      end

      result = {}

      typing.each_typing do |node, _type|
        next unless node.type == :def || node.type == :defs
        method_name = node.type == :def ? node.children[0].to_s : node.children[1].to_s
        body = node.type == :def ? node.children[2] : node.children[3]
        next unless body

        body_type = typing.type_of(node: body)
        type_str = format_type(body_type)

        # When Steep can't resolve generic type params in block calls,
        # resolve from the block body type or from BlockBodyTypeMismatch errors.
        resolved = resolve_block_generic_type(typing, body, type_str, block_mismatches)
        type_str = resolved if resolved

        next if type_str == "untyped"

        result[method_name] = type_str
      end

      result
    end

    BLOCK_GENERIC_METHODS = %w[map collect].freeze

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
        actual_type = format_type(mismatch.actual)
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

      block_body_type = format_type(typing.type_of(node: block_body))
      return nil if !block_body_type || block_body_type == "untyped" || block_body_type == "bot"

      resolved = "Array[#{block_body_type}]"
      resolved == type_str ? nil : resolved
    end

    # Returns { "var_name" => "Type" } for all instance variable writes
    # observed in the source. The var name is without the leading `@`.
    #
    # Writes counted:
    #
    # - Direct `:ivasgn` (`@x = expr`) anywhere in any method.
    # - `:send` of `x=` with receiver `nil` (implicit self) or `:self`,
    #   when `x=` is declared as `attr_writer :x` / `attr_accessor :x`
    #   on the same class. The argument's type contributes to the union
    #   of `@x` (felixefelip/rbs_infer#4 + steep#18 mapping).
    #
    # When no write is observed inside `def initialize` (nor at class-body
    # scope), the emitted type gets `| nil` (definite-initialization rule).
    # The narrowing is then reabsorbed by steep#16 within methods that
    # explicitly assign before reading.
    def ivar_write_types(source_code)
      typing = type_check(source_code)
      return {} unless typing

      source_node = typing.source.node
      return {} unless source_node

      type_sets = Hash.new { |h, k| h[k] = IvarTypeSet.new }
      initialized = collect_initialized_ivars(source_node)
      attr_writer_to_ivar = collect_attr_writers(source_node)

      typing.each_typing do |node, type|
        case node.type
        when :ivasgn
          var_name = node.children[0].to_s.sub(/\A@/, "")
          type_sets[var_name].add(format_type(type))
        when :send
          receiver, method_name, *args = node.children
          next unless attr_writer_to_ivar.key?(method_name)
          next unless receiver.nil? || (receiver.respond_to?(:type) && receiver.type == :self)
          next if args.empty?

          arg = args[0]
          arg_type = typing.type_of(node: arg) rescue nil
          next unless arg_type

          ivar = attr_writer_to_ivar.fetch(method_name)
          type_sets[ivar].add(format_type(arg_type))
        end
      end

      result = {}
      type_sets.each do |name, type_set|
        force_nilable = !initialized.include?(name)
        emitted = type_set.emit(force_nilable: force_nilable)
        result[name] = emitted if emitted
      end
      result
    end

    # Returns `{ "method_name" => { "ivar_name" => "type" } }` for every
    # method in the source that writes (directly or via attr_writer) an
    # instance variable. The per-method shape is what enables consumers
    # (e.g., the ERB convention generator) to narrow an ivar's type to
    # the contribution of a specific writer — rather than always seeing
    # the wide union of all observed writes.
    #
    # Coverage mirrors `ivar_write_types`:
    # - Direct `:ivasgn` (`@x = expr`) inside any method.
    # - `:send` matching `attr_writer :x` / `attr_accessor :x` declared
    #   on the same class, with implicit-self or `self` receiver.
    #
    # Top-level `:ivasgn` outside any method (class-instance variable in
    # class body) is intentionally NOT recorded here — there's no method
    # to attribute it to. Use `collect_initialized_ivars` for that case.
    def ivar_write_types_per_method(source_code)
      typing = type_check(source_code)
      return {} unless typing

      source_node = typing.source.node
      return {} unless source_node

      attr_writer_to_ivar = collect_attr_writers(source_node)
      per_method_sets = Hash.new do |h, k|
        h[k] = Hash.new { |h2, k2| h2[k2] = IvarTypeSet.new }
      end

      collect_ivar_writes_per_method(
        source_node,
        typing: typing,
        attr_writer_to_ivar: attr_writer_to_ivar,
        current_method: nil,
        result: per_method_sets
      )

      result = {}
      per_method_sets.each do |method_name, ivar_sets|
        ivar_types = {}
        ivar_sets.each do |ivar_name, type_set|
          # `force_nilable: false` — this method already filters per
          # writer; nilability decisions live at the consumer
          # (controller declaration uses `ivar_write_types`, the
          # view consumer wants the writer's raw contribution).
          emitted = type_set.emit(force_nilable: false)
          ivar_types[ivar_name] = emitted if emitted
        end
        result[method_name] = ivar_types unless ivar_types.empty?
      end
      result
    end

    # Returns Set[String] of ivar names (without leading `@`) that are
    # assigned inside `def initialize` of any class in the source, or at
    # class-body scope. Used by the definite-initialization rule to
    # decide whether `nil` is added to the union.
    def collect_initialized_ivars(node)
      result = Set.new
      walk_ivar_init_targets(node, in_init: false, in_class_body: false, result: result)
      result
    end

    # Returns { :method_name= => "ivar_name_without_@" } for every
    # `attr_writer :x` / `attr_accessor :x` declared in the source.
    # Used to map `self.x = expr` call sites to the underlying `@x`.
    def collect_attr_writers(node)
      result = {}
      walk_attr_writer_decls(node, result: result)
      result
    end

    # Returns the type of a specific node within the typing result.
    # Useful for resolving argument types in call sites.
    # Returns { node_id => "Type" } for all typed expressions.
    def all_expression_types(source_code)
      typing = type_check(source_code)
      return {} unless typing

      result = {}

      typing.each_typing do |node, type|
        loc = node.loc&.expression
        next unless loc

        type_str = format_type(type)
        next if type_str == "untyped" || type_str == "bot"

        key = "#{loc.first_line}:#{loc.column}"
        result[key] = type_str
      end

      result
    end

    private

    # Walks `node` accumulating ivar writes attributed to the enclosing
    # `def`. Propagates `current_method` through descent; only records
    # writes that happen inside a `:def` (writes in class body are
    # ignored here since they don't belong to any callable). Mirrors the
    # filter logic of `ivar_write_types` for both `:ivasgn` and
    # attr_writer-style `:send`.
    def collect_ivar_writes_per_method(node, typing:, attr_writer_to_ivar:, current_method:, result:)
      return unless node.is_a?(::Parser::AST::Node)

      case node.type
      when :class, :module, :sclass
        body = node.type == :class ? node.children[2] : node.children[1]
        collect_ivar_writes_per_method(body, typing: typing,
                                       attr_writer_to_ivar: attr_writer_to_ivar,
                                       current_method: nil,
                                       result: result) if body
      when :def
        method_name = node.children[0].to_s
        body = node.children[2]
        collect_ivar_writes_per_method(body, typing: typing,
                                       attr_writer_to_ivar: attr_writer_to_ivar,
                                       current_method: method_name,
                                       result: result) if body
      when :defs
        # Singleton `def self.X` — class-instance variable scope, not
        # relevant for the per-action narrowing this method serves.
      when :ivasgn
        if current_method
          var_name = node.children[0].to_s.sub(/\A@/, "")
          ivasgn_type = typing.type_of(node: node) rescue nil
          if ivasgn_type
            result[current_method][var_name].add(format_type(ivasgn_type))
          end
        end
        rhs = node.children[1]
        collect_ivar_writes_per_method(rhs, typing: typing,
                                       attr_writer_to_ivar: attr_writer_to_ivar,
                                       current_method: current_method,
                                       result: result) if rhs
      when :send
        receiver, method_name, *args = node.children
        if current_method && attr_writer_to_ivar.key?(method_name) &&
           (receiver.nil? || (receiver.respond_to?(:type) && receiver.type == :self)) &&
           !args.empty?
          arg = args[0]
          arg_type = typing.type_of(node: arg) rescue nil
          if arg_type
            ivar = attr_writer_to_ivar.fetch(method_name)
            result[current_method][ivar].add(format_type(arg_type))
          end
        end
        node.children.each do |c|
          collect_ivar_writes_per_method(c, typing: typing,
                                         attr_writer_to_ivar: attr_writer_to_ivar,
                                         current_method: current_method,
                                         result: result)
        end
      when :begin
        node.children.each do |c|
          collect_ivar_writes_per_method(c, typing: typing,
                                         attr_writer_to_ivar: attr_writer_to_ivar,
                                         current_method: current_method,
                                         result: result)
        end
      else
        node.children.each do |c|
          collect_ivar_writes_per_method(c, typing: typing,
                                         attr_writer_to_ivar: attr_writer_to_ivar,
                                         current_method: current_method,
                                         result: result)
        end
      end
    end

    # Walks `node` looking for `:ivasgn` targets that count as definite
    # initialization (inside `def initialize` or directly in a class body
    # outside any method). Does not descend into non-initialize defs.
    def walk_ivar_init_targets(node, in_init:, in_class_body:, result:)
      return unless node.is_a?(::Parser::AST::Node)

      case node.type
      when :class, :module, :sclass
        body = node.type == :class ? node.children[2] : node.children[1]
        walk_ivar_init_targets(body, in_init: false, in_class_body: true, result: result) if body
      when :def
        if node.children[0] == :initialize
          body = node.children[2]
          walk_ivar_init_targets(body, in_init: true, in_class_body: false, result: result) if body
        end
      when :defs
        # def self.X — singleton method, skip; ivar there is class-instance
        # variable, not relevant for instance ivar initialization.
      when :ivasgn
        if in_init || in_class_body
          var_name = node.children[0].to_s.sub(/\A@/, "")
          result << var_name
        end
        # also walk RHS for nested classes (`@x = Class.new { @y = ... }` is
        # exotic but harmless to descend)
        rhs = node.children[1]
        walk_ivar_init_targets(rhs, in_init: in_init, in_class_body: in_class_body, result: result) if rhs
      when :send
        receiver, method_name, *args = node.children
        if (in_init || in_class_body) &&
           (receiver.nil? || (receiver.respond_to?(:type) && receiver.type == :self)) &&
           method_name.to_s.end_with?("=") &&
           method_name != :==
          # `self.x = expr` inside initialize or class body — counts as
          # init if `x=` is an attr_writer/accessor on this class. Resolve
          # lazily via the same attr-writer walk so we don't need to
          # double-pass.
          # Note: we ALWAYS mark `x` as initialized here when the shape
          # matches; the attr_writer registry filter happens at the
          # ivar-collection step. Acceptable false-positive: a custom
          # `x=` method in initialize won't actually init `@x`, but we'd
          # still mark it — the type set will be empty for that name and
          # nothing is emitted. So no observable bug.
          ivar = method_name.to_s.chomp("=").sub(/\A@/, "")
          result << ivar unless ivar.empty?
        end
        node.children.each do |c|
          walk_ivar_init_targets(c, in_init: in_init, in_class_body: in_class_body, result: result)
        end
      when :begin
        node.children.each do |c|
          walk_ivar_init_targets(c, in_init: in_init, in_class_body: in_class_body, result: result)
        end
      else
        # Descend through everything else (if/case/blocks/etc.) while
        # keeping the current scope flags.
        node.children.each do |c|
          walk_ivar_init_targets(c, in_init: in_init, in_class_body: in_class_body, result: result)
        end
      end
    end

    # Walks `node` collecting `attr_writer :x` / `attr_accessor :x` /
    # `attr_reader :x` declarations in class bodies; only writer/accessor
    # contribute to the `{ :x= => "x" }` map. Reader entries are skipped
    # because they don't define `x=`.
    def walk_attr_writer_decls(node, result:)
      return unless node.is_a?(::Parser::AST::Node)

      case node.type
      when :class, :module
        body = node.type == :class ? node.children[2] : node.children[1]
        if body
          # Only direct children of the class body count — `attr_writer`
          # inside a method body doesn't define accessors on the class.
          decls = body.type == :begin ? body.children : [body]
          decls.each do |child|
            next unless child.is_a?(::Parser::AST::Node)
            next unless child.type == :send
            next unless child.children[0].nil? # implicit-self receiver
            next unless %i[attr_writer attr_accessor].include?(child.children[1])
            child.children[2..].each do |arg|
              next unless arg.is_a?(::Parser::AST::Node)
              next unless arg.type == :sym
              name = arg.children[0].to_s
              result[:"#{name}="] = name
            end
          end
          # Descend into nested classes.
          decls.each { |c| walk_attr_writer_decls(c, result: result) }
        end
      when :sclass
        body = node.children[1]
        walk_attr_writer_decls(body, result: result) if body
      else
        node.children.each { |c| walk_attr_writer_decls(c, result: result) }
      end
    end

    def type_check(source_code)
      ensure_initialized
      return nil unless @subtyping

      source = Steep::Source.parse(source_code, path: Pathname("(rbs_infer)"), factory: @subtyping.factory)
      Steep::Services::TypeCheckService.type_check(
        source: source,
        subtyping: @subtyping,
        constant_resolver: @constant_resolver,
        cursor: nil,
        contracts: contracts_store,
        postconditions: postconditions_store,
        callbacks: callbacks_store
      )
    rescue Parser::SyntaxError
      nil
    end

    # Loads Steep's auto-inferred precondition contracts from the project's
    # sidecar (`sig/generated/.steep_contracts.yml`). With these in hand,
    # `Steep::TypeConstruction#contract_narrowed_type` fires inside method
    # bodies — so `Comment#author_name` reads `user` (a pure attr-style
    # method) as non-nil when the contract for that method requires it, and
    # `user.name` typechecks cleanly. Without this hook the store stayed
    # empty and no narrowing applied, which made rbs_infer fall back to
    # `untyped`.
    def contracts_store
      @contracts_store ||=
        begin
          base = Pathname(contracts_base_dir).expand_path
          Steep::Contracts.load(base)
        rescue StandardError => e
          warn "[rbs_infer] failed to load Steep contracts from #{base}: #{e.class}: #{e.message}"
          Steep::Contracts::Store.empty
        end
    end

    # Loads conditional postconditions written by external generators
    # (rbs_rails, rbs_inline, hand-authored) into a glob under `sig/`.
    # Required by Steep's TypeCheckService since felixefelip/steep#10.
    def postconditions_store
      @postconditions_store ||=
        begin
          base = Pathname(contracts_base_dir).expand_path
          Steep::Postconditions.load(base)
        rescue StandardError => e
          warn "[rbs_infer] failed to load Steep postconditions from #{base}: #{e.class}: #{e.message}"
          Steep::Postconditions::Store.empty
        end
    end

    # Loads the generic callback sidecar (felixefelip/steep#27) from
    # `sig/**/.steep_callbacks.yml`. rbs_rails emits this from
    # `before_action` declarations; combined with postconditions it
    # narrows ivars at the entry of every covered action without an
    # explicit setter call in the body. Required by `TypeCheckService`
    # since Steep made `callbacks:` a mandatory keyword.
    def callbacks_store
      @callbacks_store ||=
        begin
          base = Pathname(contracts_base_dir).expand_path
          Steep::Callbacks.load(base)
        rescue StandardError => e
          warn "[rbs_infer] failed to load Steep callbacks from #{base}: #{e.class}: #{e.message}"
          Steep::Callbacks::Store.empty
        end
    end

    def contracts_base_dir
      if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        ::Rails.root.to_s
      else
        Dir.pwd
      end
    end

    def ensure_initialized
      return if @initialized
      @initialized = true

      definition_builder = self.class.definition_builder
      return unless definition_builder

      factory = Steep::AST::Types::Factory.new(builder: definition_builder)
      interface_builder = Steep::Interface::Builder.new(factory, implicitly_returns_nil: false)
      @subtyping = Steep::Subtyping::Check.new(builder: interface_builder)
      @constant_resolver = RBS::Resolver::ConstantResolver.new(builder: definition_builder)
    end

    def format_type(steep_type)
      # `Steep::AST::Types::Logic::*` are internal types Steep uses for
      # predicate-narrowing flow analysis (e.g., the body of
      # `def x?; !@y.nil?; end` types as `Logic::Not`). They have no
      # valid RBS surface form — `to_s` emits `<% Steep::AST::Types::Logic::Not %>`,
      # which then leaks into generated RBS. Collapse all of them to
      # `bool` since that's the user-visible meaning of any predicate
      # return.
      if defined?(Steep::AST::Types::Logic::Base) && steep_type.is_a?(Steep::AST::Types::Logic::Base)
        return "bool"
      end

      str = steep_type.to_s

      # Remove leading :: from all type names
      str = str.gsub(/(^|[\[\(, |])::/) { $1 }

      # Normalize record key format: { :sym => Type } → { sym: Type }
      str = str.gsub(/:(\w+) =>/, '\1:')

      # Normalize nilable types in nested contexts: (Type | nil) → Type?
      str = str.gsub(/\(([^|()]+) \| nil\)/) { "#{$1.strip}?" }
      str = str.gsub(/\(nil \| ([^|()]+)\)/) { "#{$1.strip}?" }

      # Normalize void out of union types: (void | T) → T?
      # void in a union means "return value not used in that branch", treat as nil
      if str =~ /\A\(/ && str.include?("void")
        parts = str.gsub(/\A\(|\)\z/, "").split(/\s*\|\s*/)
        parts.reject! { |p| p == "void" }
        parts.reject! { |p| p == "nil" }
        if parts.empty?
          return "void"
        elsif parts.size == 1
          return "#{parts.first}?"
        else
          return "(#{parts.join(" | ")})?"
        end
      end

      # Normalize (T | nil) to T?
      if str =~ /\A\((.+) \| nil\)\z/
        inner = $1.strip
        return "#{inner}?" unless inner.include?("|")
      end
      if str =~ /\A\(nil \| (.+)\)\z/
        inner = $1.strip
        return "#{inner}?" unless inner.include?("|")
      end

      str
    end

    def find_enclosing_method(node, typing)
      # Walk up from the node to find the enclosing def
      # Since Parser AST nodes don't have parent pointers, we search
      # through the typing's source node tree
      source_node = typing.source.node
      find_method_for_node(source_node, node)
    end

    def find_method_for_node(root, target)
      current_method = nil
      search_for_method(root, target, current_method)
    end

    def search_for_method(node, target, current_method)
      return nil unless node.is_a?(Parser::AST::Node)

      if node.type == :def
        current_method = node.children[0].to_s
      elsif node.type == :defs
        current_method = node.children[1].to_s
      end

      return current_method if node.equal?(target)

      node.children.each do |child|
        result = search_for_method(child, target, current_method)
        return result if result
      end

      nil
    end
  end
end
