require "steep"
require_relative "../inference/ivar_type_set"

module RbsInfer::Signatures
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

      # Steep's type-checking context (factory → interface builder → subtyping
      # + constant resolver), derived from the shared `definition_builder` and
      # cached at the class level. The interface builder memoizes each type's
      # method "shape"; sharing it across every Analyzer means a type's shape is
      # built once per env instead of rebuilt per file — the dominant cost after
      # #48/#49 (felixefelip/rbs_infer#47). Keyed by builder identity, so it
      # rebuilds exactly when `definition_builder` does (reset! / chdir).
      def steep_context
        db = definition_builder
        return nil unless db
        return @steep_context if @steep_context_builder.equal?(db)

        @steep_context_builder = db
        factory = Steep::AST::Types::Factory.new(builder: db)
        interface_builder = Steep::Interface::Builder.new(factory, implicitly_returns_nil: false)
        @steep_context = {
          subtyping: Steep::Subtyping::Check.new(builder: interface_builder),
          constant_resolver: RBS::Resolver::ConstantResolver.new(builder: db),
        }
      end

      def reset!
        @definition_builder = nil
        @definition_builder_loaded = false
        @definition_builder_dir = nil
        @steep_context = nil
        @steep_context_builder = nil
      end

      private

      def build_definition_builder
        require "rbs"
        require "yaml"

        loader = RBS::EnvironmentLoader.new

        # Load the project's RBS collection (gems + stdlib) from its
        # lockfile, mirroring what `steep check` does (see Steep's
        # `Drivers::Utils::DriverHelper`). This is what pulls in the
        # *stdlib* RBS — `date`, `time`, etc. — which gem RBS depends on
        # but `EnvironmentLoader.new` does not load by itself.
        #
        # It matters because gems like activesupport reopen core stdlib
        # classes with overload-extending signatures, e.g. on `::Date`:
        #
        #     def +: (ActiveSupport::Duration other) -> self
        #          | ...   # extends the stdlib Date#+ overloads
        #
        # The trailing `| ...` requires the stdlib `date` base method to
        # already exist. Without `date` loaded, building `::Date`'s method
        # table raises `RBS::InvalidOverloadMethodError`; Steep wraps it as
        # an `UnexpectedError` and types every `Date`-receiver expression
        # as `untyped`. That silently poisons whole return-type chains
        # (e.g. `((Date.current - born) / 365).to_f.truncate(2)` inferred
        # as `untyped` instead of `Float`). Loading the lockfile keeps the
        # bridge's environment in parity with `steep check`.
        add_collection_from_lockfile(loader)

        Dir["sig/*/"].each { |d| loader.add(path: Pathname(d)) }

        env = RBS::Environment.from_loader(loader).resolve_type_names
        RBS::DefinitionBuilder.new(env: env)
      rescue LoadError, StandardError => _e
        nil
      end

      # Adds the project's RBS collection (gems + stdlib) to `loader` from
      # its `rbs_collection.lock.yaml`. Falls back to the legacy
      # `.gem_rbs_collection/*/*/` glob when there's no readable/usable
      # lockfile — note that fallback does NOT bring in stdlib RBS, so
      # `Date`/`Time` chains there still degrade to `untyped`.
      def add_collection_from_lockfile(loader)
        config_path = RBS::Collection::Config.find_config_path
        lock_path = config_path && RBS::Collection::Config.to_lockfile_path(config_path)

        unless lock_path&.exist?
          return add_gem_rbs_collection_glob(loader)
        end

        lockfile = RBS::Collection::Config::Lockfile.from_lockfile(
          lockfile_path: lock_path,
          data: YAML.load(lock_path.read)
        )
        # Raises CollectionNotAvailable if the lockfile references gems
        # that aren't installed under the collection dir. Check before
        # mutating `loader` so we can fall back cleanly to the glob.
        lockfile.check_rbs_availability!
        loader.add_collection(lockfile)
      rescue StandardError
        add_gem_rbs_collection_glob(loader)
      end

      def add_gem_rbs_collection_glob(loader)
        Dir[".gem_rbs_collection/*/*/"].each { |ver_dir| loader.add(path: Pathname(ver_dir)) }
      end
    end

    # Steep's subtyping/constant-resolver context, shared at the class level so
    # the interface builder's per-type shape cache is reused across instances
    # (felixefelip/rbs_infer#47). nil when the env couldn't be built.
    def steep_subtyping
      self.class.steep_context&.fetch(:subtyping)
    end

    def steep_constant_resolver
      self.class.steep_context&.fetch(:constant_resolver)
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
    def method_return_types_by_kind(source_code)
      typing = type_check(source_code)
      return { instance: {}, singleton: {} } unless typing

      # Index BlockBodyTypeMismatch errors by block node identity
      block_mismatches = {}
      typing.errors.each do |err|
        next unless err.is_a?(Steep::Diagnostic::Ruby::BlockBodyTypeMismatch)
        block_mismatches[err.node.__id__] = err
      end

      instance = {}
      singleton = {}

      typing.each_typing do |node, _type|
        next unless node.type == :def || node.type == :defs
        singleton_def = node.type == :defs
        method_name = singleton_def ? node.children[1].to_s : node.children[0].to_s
        body = singleton_def ? node.children[3] : node.children[2]
        next unless body

        body_type = typing.type_of(node: body)
        type_str = format_type(body_type)

        # When Steep can't resolve generic type params in block calls,
        # resolve from the block body type or from BlockBodyTypeMismatch errors.
        resolved = resolve_block_generic_type(typing, body, type_str, block_mismatches)
        type_str = resolved if resolved

        next if type_str == "untyped"

        (singleton_def ? singleton : instance)[method_name] = type_str
      end

      { instance: instance, singleton: singleton }
    end

    # Returns { "CONSTANT_NAME" => "Type" } for every `NAME = expr` /
    # `Foo::NAME = expr` in the source, typed from the RHS expression.
    # Keyed by the bare constant name (the `:casgn` node's name child), so
    # a path write (`Foo::BAR = ...`) keys as `"BAR"` — matching how
    # `ClassMemberCollector` records the member. Same oracle role as
    # `method_return_types`: Steep types the whole RHS (arrays, hashes,
    # comparison/arithmetic chains, and — once the class's RBS exists —
    # `new`-bearing collection builders), so rbs_infer#37 doesn't
    # re-implement chain typing.
    def constant_types(source_code)
      typing = type_check(source_code)
      return {} unless typing

      result = {}
      typing.each_typing do |node, type|
        next unless node.type == :casgn

        type_str = format_type(type)
        next if type_str == "untyped" || type_str == "bot" || type_str == "void"

        result[node.children[1].to_s] = type_str
      end
      result
    end

    # Cross-file complement to `constant_types`: resolves a constant reference
    # against the loaded environment (stdlib, gems, generated `sig/`). Class
    # references are absent (a class is a class_decl, not a `Foo = ...` casgn),
    # so they return nil. Type string is `::`-stripped to match `constant_types`.
    def constant_type_from_env(name, namespace:)
      builder = self.class.definition_builder
      return nil unless builder && name

      env = builder.env
      constant_name_candidates(name, namespace).each do |fqn|
        entry = env.constant_decls[RBS::TypeName.parse(fqn)]
        next unless entry

        return entry.decl.type.to_s.gsub(/(^|[\[\(, |])::/) { $1 }
      end
      nil
    rescue RBS::BaseError, StandardError
      nil
    end

    # True when `name` (resolved from `namespace`) is a class or module in the
    # env — i.e. its bare name is a valid type (`foo(User) -> User`).
    def class_or_module?(name, namespace:)
      builder = self.class.definition_builder
      return false unless builder && name

      env = builder.env
      constant_name_candidates(name, namespace).any? do |fqn|
        env.class_decls.key?(RBS::TypeName.parse(fqn))
      end
    rescue RBS::BaseError, StandardError
      false
    end

    # Fully-qualified candidates for a constant reference, walking the
    # enclosing namespace outward (Ruby's lexical constant lookup), then
    # top-level. An already-absolute `::X` reference only tries `::X`.
    def constant_name_candidates(name, namespace)
      bare = name.sub(/\A::/, "")
      candidates = []
      if namespace && !name.start_with?("::")
        parts = namespace.sub(/\A::/, "").split("::")
        until parts.empty?
          candidates << "::#{parts.join("::")}::#{bare}"
          parts.pop
        end
      end
      candidates << "::#{bare}"
      candidates.uniq
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

    # Returns { "var_name" => "Type" } for instance variable writes
    # observed in the source, scoped to `target_class`. The var name is
    # without the leading `@`.
    #
    # `target_class` matters when a single file defines several classes
    # (initializers, `lib/*_ext.rb`, fixtures): only writes lexically
    # inside `target_class` (or a module nested-and-included under it,
    # e.g. an expander's `GeneratedAttributeMethods`) count, so a sibling
    # class's `@x` never bleeds in (felixefelip/rbs_infer#38). Pass `nil`
    # to opt out of scoping (whole-file behavior).
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
    # scope) of `target_class`, the emitted type gets `| nil`
    # (definite-initialization rule). The narrowing is then reabsorbed by
    # steep#16 within methods that explicitly assign before reading.
    def ivar_write_types(source_code, target_class:)
      typing = type_check(source_code)
      return {} unless typing

      source_node = typing.source.node
      return {} unless source_node

      type_sets = Hash.new { |h, k| h[k] = RbsInfer::Inference::IvarTypeSet.new }
      initialized = collect_initialized_ivars(source_node, target_class: target_class)
      attr_writer_to_ivar = collect_attr_writers(source_node)
      # Only writes lexically inside `target_class` count. A single file can
      # define several classes (initializers, `lib/*_ext.rb`, the dummy-app
      # fixtures), and without scoping their ivars — and same-named methods
      # like `initialize` — pool into each other (felixefelip/rbs_infer#38).
      # `each_typing` enumerates the whole file, so we filter it by node
      # identity against the set of writes that belong to `target_class`.
      in_scope = collect_scoped_write_node_ids(source_node, attr_writer_to_ivar, target_class)

      typing.each_typing do |node, type|
        next unless in_scope.include?(node.object_id)
        case node.type
        when :ivasgn
          rhs = node.children[1]
          next unless rhs
          rhs_type = intrinsic_type_of(rhs, typing)
          next unless rhs_type
          var_name = node.children[0].to_s.sub(/\A@/, "")
          type_sets[var_name].add(format_type(rhs_type))
        when :send
          receiver, method_name, *args = node.children
          next unless attr_writer_to_ivar.key?(method_name)
          next unless receiver.nil? || (receiver.respond_to?(:type) && receiver.type == :self)
          next if args.empty?

          arg = args[0]
          arg_type = intrinsic_type_of(arg, typing)
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
    # method of `target_class` that writes (directly or via attr_writer)
    # an instance variable. The per-method shape is what enables consumers
    # (e.g., the ERB convention generator) to narrow an ivar's type to
    # the contribution of a specific writer — rather than always seeing
    # the wide union of all observed writes.
    #
    # Scoped to `target_class` so that same-named methods across classes
    # in one file (`Foo#initialize` and `Bar#initialize`) don't pool into
    # a single `"initialize"` bucket (felixefelip/rbs_infer#38). Pass
    # `nil` to opt out of scoping.
    #
    # Coverage mirrors `ivar_write_types`:
    # - Direct `:ivasgn` (`@x = expr`) inside any method.
    # - `:send` matching `attr_writer :x` / `attr_accessor :x` declared
    #   on the same class, with implicit-self or `self` receiver.
    #
    # Top-level `:ivasgn` outside any method (class-instance variable in
    # class body) is intentionally NOT recorded here — there's no method
    # to attribute it to. Use `collect_initialized_ivars` for that case.
    def ivar_write_types_per_method(source_code, target_class:)
      typing = type_check(source_code)
      return {} unless typing

      source_node = typing.source.node
      return {} unless source_node

      attr_writer_to_ivar = collect_attr_writers(source_node)
      per_method_sets = Hash.new do |h, k|
        h[k] = Hash.new { |h2, k2| h2[k2] = RbsInfer::Inference::IvarTypeSet.new }
      end

      collect_ivar_writes_per_method(
        source_node,
        typing: typing,
        attr_writer_to_ivar: attr_writer_to_ivar,
        current_method: nil,
        namespace: [],
        target_class: target_class,
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

    # Runs Steep's `Postconditions::Inferrer` against the source and
    # returns the resulting `InferredEntry` array. These describe what
    # ivars each method narrows (unconditional for setters, when_true
    # for predicates) and which marker class names the inferrer would
    # reference in the sidecar — exactly the info rbs_infer needs to
    # generate the matching marker class declarations in RBS.
    #
    # Using Steep's inferrer (instead of re-implementing detection on
    # the rbs_infer side) keeps the two emitters semantically aligned
    # for free: whenever Steep learns a new predicate shape, rbs_infer
    # picks it up without code change.
    def postcondition_inferred_entries(source_code)
      typing = type_check(source_code)
      return [] unless typing

      subtyping = steep_subtyping
      return [] unless subtyping

      Steep::Postconditions::Inferrer.infer(typing.source, typing, subtyping)
    rescue StandardError => e
      Steep.logger.warn { "[rbs_infer] postcondition inferrer failed: #{e.message}" } if defined?(Steep.logger)
      []
    end

    # Returns Set[String] of ivar names (without leading `@`) that are
    # assigned inside `def initialize` of `target_class`, or at its
    # class-body scope. Used by the definite-initialization rule to
    # decide whether `nil` is added to the union — so it must be scoped to
    # the same class the writes are, or an `@x` initialized in a *sibling*
    # class in the same file would wrongly suppress the `| nil` here.
    def collect_initialized_ivars(node, target_class:)
      result = Set.new
      walk_ivar_init_targets(node, in_init: false, in_class_body: false,
                             namespace: [], target_class: target_class, result: result)
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

    # Returns `{ "method_name" => "Self & Self::Validated" }` for `class_name`,
    # derived from the `applies_self` callback sidecar entries
    # (`.steep_callbacks.yml`, felixefelip/steep#27) loaded into the
    # callbacks store. rbs_rails' `ModelCallbacksGenerator` emits these for
    # after-validation lifecycle callbacks (`after_create`, `after_save`, …)
    # and their transitive self-call closure — so inside such a handler the
    # record is known validated and `self` refines to `Model & Model::Validated`.
    #
    # rbs_infer needs this because Steep keeps a `self` node as the abstract
    # `self` token in its typing output (the refinement only affects dispatch,
    # never the recorded node type), so the narrowed self type can't be read
    # back from `each_typing`. Reading the sidecar — the same source of truth
    # Steep consumes — lets call-site inference resolve `Klass.new(self)`
    # inside a callback to the validated type instead of the bare class.
    def callback_self_types(class_name)
      return {} unless class_name

      store = callbacks_store
      return {} if store.nil? || store.empty?

      key = class_name.to_s.sub(/\A::/, "")
      entries = store.entries_by_class[key]
      return {} unless entries

      result = {}
      entries.each do |entry|
        next unless entry.applies_self
        entry.runs_before.each do |method_sym|
          result[method_sym.to_s] ||= entry.applies_self
        end
      end
      result
    end

    private

    # Renders a whitequark `:const` node into a dotted class-path string:
    # `(const nil :Foo)` → "Foo", `(const (const nil :Foo) :Bar)` →
    # "Foo::Bar", `(const (cbase) :Foo)` → "Foo". Returns nil for shapes
    # we can't name (dynamic constant paths), so the caller keeps the
    # outer namespace rather than inventing a segment.
    def const_node_to_name(node)
      return nil unless node.is_a?(::Parser::AST::Node) && node.type == :const

      scope, name = node.children
      if scope.nil? || (scope.is_a?(::Parser::AST::Node) && scope.type == :cbase)
        name.to_s
      elsif scope.is_a?(::Parser::AST::Node) && scope.type == :const
        prefix = const_node_to_name(scope)
        prefix ? "#{prefix}::#{name}" : nil
      end
    end

    # True when the lexical class path `namespace` (array of segments) is
    # `target_class` *or* something nested under it. The nested case is
    # required: an expander (e.g. CurrentAttributes) can emit a nested
    # `module GeneratedAttributeMethods` that is `include`d into the class
    # and writes the same ivars, so its writes belong to the target. The
    # `::` boundary keeps a sibling like `BoardMember` from matching
    # target `Board`. A nil `target_class` means "don't scope" (whole
    # file), preserved for callers with no single target.
    def class_scope_match?(namespace, target_class)
      return true if target_class.nil?

      target = target_class.to_s.sub(/\A::/, "")
      current = namespace.join("::")
      current == target || current.start_with?("#{target}::")
    end

    # Object-ids of the `:ivasgn` / attr-writer `:send` nodes that live
    # lexically inside `target_class`. `ivar_write_types` filters the
    # whole-file `each_typing` stream against this set so a sibling class
    # in the same file can't contribute to the target's ivar types. Using
    # object-ids (not the nodes) sidesteps `Parser::AST::Node`'s
    # structural `==`, which would conflate two identical writes in
    # different classes.
    def collect_scoped_write_node_ids(node, attr_writer_to_ivar, target_class, namespace: [], result: Set.new)
      return result unless node.is_a?(::Parser::AST::Node)

      case node.type
      when :class, :module
        name = const_node_to_name(node.children[0])
        body = node.type == :class ? node.children[2] : node.children[1]
        collect_scoped_write_node_ids(body, attr_writer_to_ivar, target_class,
                                      namespace: name ? namespace + [name] : namespace,
                                      result: result) if body
      when :sclass
        collect_scoped_write_node_ids(node.children[1], attr_writer_to_ivar, target_class,
                                      namespace: namespace, result: result) if node.children[1]
      when :ivasgn
        result << node.object_id if class_scope_match?(namespace, target_class)
        node.children.each do |c|
          collect_scoped_write_node_ids(c, attr_writer_to_ivar, target_class, namespace: namespace, result: result)
        end
      when :send
        receiver, method_name = node.children[0], node.children[1]
        if attr_writer_to_ivar.key?(method_name) &&
           (receiver.nil? || (receiver.respond_to?(:type) && receiver.type == :self)) &&
           class_scope_match?(namespace, target_class)
          result << node.object_id
        end
        node.children.each do |c|
          collect_scoped_write_node_ids(c, attr_writer_to_ivar, target_class, namespace: namespace, result: result)
        end
      else
        node.children.each do |c|
          collect_scoped_write_node_ids(c, attr_writer_to_ivar, target_class, namespace: namespace, result: result)
        end
      end

      result
    end

    # Walks `node` accumulating ivar writes attributed to the enclosing
    # `def`. Propagates `current_method` through descent; only records
    # writes that happen inside a `:def` (writes in class body are
    # ignored here since they don't belong to any callable). Mirrors the
    # filter logic of `ivar_write_types` for both `:ivasgn` and
    # attr_writer-style `:send`.
    def collect_ivar_writes_per_method(node, typing:, attr_writer_to_ivar:, current_method:, namespace:, target_class:, result:)
      return unless node.is_a?(::Parser::AST::Node)

      case node.type
      when :class, :module
        name = const_node_to_name(node.children[0])
        body = node.type == :class ? node.children[2] : node.children[1]
        collect_ivar_writes_per_method(body, typing: typing,
                                       attr_writer_to_ivar: attr_writer_to_ivar,
                                       current_method: nil,
                                       namespace: name ? namespace + [name] : namespace,
                                       target_class: target_class,
                                       result: result) if body
      when :sclass
        # `class << self` — same lexical class, singleton scope; keep the
        # namespace so writes inside still attribute to the enclosing class.
        body = node.children[1]
        collect_ivar_writes_per_method(body, typing: typing,
                                       attr_writer_to_ivar: attr_writer_to_ivar,
                                       current_method: nil,
                                       namespace: namespace,
                                       target_class: target_class,
                                       result: result) if body
      when :def
        method_name = node.children[0].to_s
        body = node.children[2]
        collect_ivar_writes_per_method(body, typing: typing,
                                       attr_writer_to_ivar: attr_writer_to_ivar,
                                       current_method: method_name,
                                       namespace: namespace,
                                       target_class: target_class,
                                       result: result) if body
      when :defs
        # Singleton `def self.X` — class-instance variable scope, not
        # relevant for the per-action narrowing this method serves.
      when :ivasgn
        rhs = node.children[1]
        if current_method && rhs && class_scope_match?(namespace, target_class)
          var_name = node.children[0].to_s.sub(/\A@/, "")
          # Use the RHS's INTRINSIC type, not what `typing` recorded.
          # When the ivar is already declared in RBS (e.g.,
          # `@name: String?`), Steep's `:ivasgn` synthesize widens
          # the literal's typing via hint propagation — `@name = "TBA"`
          # shows up as `String?` instead of `String`, silently
          # swallowing the narrowing the writer actually introduces.
          # `intrinsic_type_of` re-computes the type from the literal
          # node shape, matching `synthesize(node, hint: nil)`.
          # Mirrors the same fix in Steep's
          # `Postconditions::Inferrer` (felixefelip/steep#35).
          rhs_type = intrinsic_type_of(rhs, typing)
          if rhs_type
            result[current_method][var_name].add(format_type(rhs_type))
          end
        end
        collect_ivar_writes_per_method(rhs, typing: typing,
                                       attr_writer_to_ivar: attr_writer_to_ivar,
                                       current_method: current_method,
                                       namespace: namespace,
                                       target_class: target_class,
                                       result: result) if rhs
      when :send
        receiver, method_name, *args = node.children
        if current_method && attr_writer_to_ivar.key?(method_name) &&
           (receiver.nil? || (receiver.respond_to?(:type) && receiver.type == :self)) &&
           !args.empty? && class_scope_match?(namespace, target_class)
          arg = args[0]
          arg_type = intrinsic_type_of(arg, typing)
          if arg_type
            ivar = attr_writer_to_ivar.fetch(method_name)
            result[current_method][ivar].add(format_type(arg_type))
          end
        end
        node.children.each do |c|
          collect_ivar_writes_per_method(c, typing: typing,
                                         attr_writer_to_ivar: attr_writer_to_ivar,
                                         current_method: current_method,
                                         namespace: namespace,
                                         target_class: target_class,
                                         result: result)
        end
      when :begin
        node.children.each do |c|
          collect_ivar_writes_per_method(c, typing: typing,
                                         attr_writer_to_ivar: attr_writer_to_ivar,
                                         current_method: current_method,
                                         namespace: namespace,
                                         target_class: target_class,
                                         result: result)
        end
      else
        node.children.each do |c|
          collect_ivar_writes_per_method(c, typing: typing,
                                         attr_writer_to_ivar: attr_writer_to_ivar,
                                         current_method: current_method,
                                         namespace: namespace,
                                         target_class: target_class,
                                         result: result)
        end
      end
    end

    # Walks `node` looking for `:ivasgn` targets that count as definite
    # initialization (inside `def initialize` or directly in a class body
    # outside any method). Does not descend into non-initialize defs.
    def walk_ivar_init_targets(node, in_init:, in_class_body:, namespace:, target_class:, result:)
      return unless node.is_a?(::Parser::AST::Node)

      case node.type
      when :class, :module
        name = const_node_to_name(node.children[0])
        body = node.type == :class ? node.children[2] : node.children[1]
        walk_ivar_init_targets(body, in_init: false, in_class_body: true,
                               namespace: name ? namespace + [name] : namespace,
                               target_class: target_class, result: result) if body
      when :sclass
        body = node.children[1]
        walk_ivar_init_targets(body, in_init: false, in_class_body: true,
                               namespace: namespace, target_class: target_class, result: result) if body
      when :def
        if node.children[0] == :initialize
          body = node.children[2]
          walk_ivar_init_targets(body, in_init: true, in_class_body: false,
                                 namespace: namespace, target_class: target_class, result: result) if body
        end
      when :defs
        # def self.X — singleton method, skip; ivar there is class-instance
        # variable, not relevant for instance ivar initialization.
      when :ivasgn
        if (in_init || in_class_body) && class_scope_match?(namespace, target_class)
          var_name = node.children[0].to_s.sub(/\A@/, "")
          result << var_name
        end
        # also walk RHS for nested classes (`@x = Class.new { @y = ... }` is
        # exotic but harmless to descend)
        rhs = node.children[1]
        walk_ivar_init_targets(rhs, in_init: in_init, in_class_body: in_class_body,
                               namespace: namespace, target_class: target_class, result: result) if rhs
      when :send
        receiver, method_name, *args = node.children
        if (in_init || in_class_body) && class_scope_match?(namespace, target_class) &&
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
          walk_ivar_init_targets(c, in_init: in_init, in_class_body: in_class_body,
                                 namespace: namespace, target_class: target_class, result: result)
        end
      when :begin
        node.children.each do |c|
          walk_ivar_init_targets(c, in_init: in_init, in_class_body: in_class_body,
                                 namespace: namespace, target_class: target_class, result: result)
        end
      else
        # Descend through everything else (if/case/blocks/etc.) while
        # keeping the current scope flags.
        node.children.each do |c|
          walk_ivar_init_targets(c, in_init: in_init, in_class_body: in_class_body,
                                 namespace: namespace, target_class: target_class, result: result)
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

    # Type-checks a source string and returns Steep's `typing` (or nil). This
    # is the single most expensive operation in the pipeline (a full Steep
    # synthesize), and the ~7 oracle methods above each call it — so one
    # analysis type-checks the same target source ~5x and each caller source
    # ~2x. Memoize per source for the instance's lifetime.
    #
    # Safe to cache: the bridge is per-Analyzer, the result depends only on
    # (source, env, sidecar stores), the env (`definition_builder`) only
    # changes via the class-level `reset!` — called *between* analyses, never
    # during one — and the stores are load-once read-only inputs. The returned
    # `typing` is only ever read by callers, never mutated. A new analysis
    # gets a fresh instance (and a freshly-reset env), so no cross-analysis
    # staleness. (felixefelip/rbs_infer#47)
    def type_check(source_code)
      (@type_check_cache ||= {}).fetch(source_code) do
        @type_check_cache[source_code] = type_check_uncached(source_code)
      end
    end

    private def type_check_uncached(source_code)
      subtyping = steep_subtyping
      return nil unless subtyping

      source = Steep::Source.parse(source_code, path: Pathname("(rbs_infer)"), factory: subtyping.factory)
      Steep::Services::TypeCheckService.type_check(
        source: source,
        subtyping: subtyping,
        constant_resolver: steep_constant_resolver,
        cursor: nil,
        contracts: contracts_store,
        postconditions: postconditions_store,
        callbacks: callbacks_store,
        delegation_registry: delegation_registry_store
      )
    rescue Parser::SyntaxError
      nil
    end

    # rbs_infer runs Steep's inferrers in isolation per-source, with
    # no surrounding project context — there's no delegation graph
    # to feed in. An empty registry satisfies the required kwarg
    # (felixefelip/steep#38) without enabling chain inlining that
    # we wouldn't be able to populate here anyway.
    def delegation_registry_store
      @delegation_registry_store ||= Steep::Project::DelegationRegistry.new
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

    # Returns the intrinsic (hint-free) type of a node. For literal AST
    # nodes Steep's `:ivasgn` synthesize widens the recorded type to
    # match the LHS declared type via hint propagation — so a
    # `@name = "TBA"` against `@name: String?` ends up with the str
    # node typed as `String?` in `typing`. The widening is intentional
    # for collections (`@x: Array[Numeric] = [1, 2, 3]` needs hint to
    # type-check), but for narrowing-detection it silently swallows
    # the writer's actual contribution.
    #
    # For literal nodes we compute the type directly from the node
    # shape, mirroring `synthesize(node, hint: nil)`. Non-literal RHS
    # nodes (sends, lvars, dstrs without interpolation, arrays, hashes)
    # fall back to `typing.type_of` — those rarely suffer the widening
    # since the hint mostly affects literal value-class lookups.
    #
    # Same pattern as `Steep::Postconditions::Inferrer#intrinsic_type_of`
    # (felixefelip/steep#35). Both call sites need to bypass the same
    # widening for the cross-receiver narrowing pipeline to fire.
    def intrinsic_type_of(node, typing)
      case node.type
      when :nil
        Steep::AST::Builtin.nil_type
      when :str, :dstr
        Steep::AST::Builtin::String.instance_type
      when :int
        Steep::AST::Builtin::Integer.instance_type
      when :float
        Steep::AST::Builtin::Float.instance_type
      when :sym, :dsym
        Steep::AST::Builtin::Symbol.instance_type
      when :true
        Steep::AST::Types::Literal.new(value: true)
      when :false
        Steep::AST::Types::Literal.new(value: false)
      when :regexp
        Steep::AST::Builtin::Regexp.instance_type
      else
        typing.type_of(node: node) rescue nil
      end
    end

    def format_type(steep_type)
      # `Steep::AST::Types::Logic::*` are internal types Steep uses for
      # predicate-narrowing flow analysis (e.g., the body of
      # `def x?; !@y.nil?; end` types as `Logic::Not`). They have no
      # valid RBS surface form — `to_s` emits `<% Steep::AST::Types::Logic::Not %>`,
      # which then leaks into generated RBS. Collapse all of them to
      # `bool` since that's the user-visible meaning of any predicate
      # return.
      return "bool" if steep_type.is_a?(Steep::AST::Types::Logic::Base)

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
