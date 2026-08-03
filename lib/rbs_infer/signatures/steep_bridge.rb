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
        type_str = RbsInfer::Signatures::SteepBridge::TypeFormatter.format_type(type)
        next if type_str == "untyped" || type_str == "nil" || type_str == "bot"

        var_name = node.children[0].to_s
        # A body checked with `@type self_method:` has no enclosing `def` — an ERB template
        # compiles to a method at runtime, so its code is top-level in the source. Dropping
        # those locals loses every block param a template binds (`@posts.each do |post|`),
        # which is what types a helper's argument at the call site.
        method_name = find_enclosing_method(node, typing) || self_method_name(typing)
        next unless method_name

        result[method_name][var_name] = type_str
      end

      result
    end

    # Types of local variable READS, keyed by `[line, column]` of the read.
    #
    # `local_var_types_per_method` above answers "what type does this variable
    # have in this method": one answer per variable, which therefore cannot
    # express narrowing, a positional property. Steep has already computed the
    # narrowed type — it is sitting on the `:lvar` node:
    #
    #   if session = find_session_by_cookie   # :lvasgn -> (Session & Validated)?
    #     set_current_session session          # :lvar   -> (Session & Validated)
    #   end
    #
    # Reading the assignment's type for that argument is what had a caller
    # passing "possibly nil" where the code cannot (felixefelip/rbs_infer#142).
    #
    # Keyed by line and CHARACTER column so a Prism node can look itself up:
    # Prism counts columns in bytes (`start_column`) and in characters
    # (`start_character_column`), while Parser counts characters — matching on
    # the character column is what keeps a source with multibyte text aligned.
    def local_var_read_types(source_code)
      typing = type_check(source_code)
      return {} unless typing

      result = {}
      typing.each_typing do |node, type|
        next unless node.type == :lvar

        type_str = RbsInfer::Signatures::SteepBridge::TypeFormatter.format_type(type)
        # An unusable answer defers to the per-method map rather than
        # overriding it with nothing.
        next if type_str == "untyped" || type_str == "bot"

        result[[node.loc.line, node.loc.column]] = type_str
      end
      result
    end

    def forwarded_block_requirements(source_code)
      RbsInfer::Signatures::SteepBridge::BlockAnalyzer.new.forwarded_block_requirements(source_code)
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

        type_str = RbsInfer::Signatures::SteepBridge::TypeFormatter.format_type(type)
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

    def ivar_write_types(source_code, target_class:)
      steep_bridge_ivar_write_analyzer.ivar_write_types(source_code, target_class: target_class)
    end

    def ivar_write_types_per_method(source_code, target_class:)
      steep_bridge_ivar_write_analyzer.ivar_write_types_per_method(source_code, target_class: target_class)
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

    # The key an expression is filed under in `all_expression_types`: its full
    # RANGE, both ends.
    #
    # A position was not enough, because a position does not name an expression.
    # A receiver starts exactly where its call does, so in
    #
    #     Registry.holder = ticket.holder
    #
    # `ticket` and `ticket.holder` began at the same column and shared one key.
    # It stayed hidden while the call had a type of its own — either answer was
    # at least ABOUT the right expression — and surfaced when the call was
    # `untyped`: dropped from the map, the receiver was left answering for the
    # whole expression, and `holder=` took a `Ticket?` (the object that HAS a
    # holder) instead of a `Holder` (felixefelip/rbs_infer#168).
    #
    # Preferring the widest or the narrowest expression at a position does not
    # decide it either: `Current.with` wants the inner answer and this wants the
    # outer one. Only the range tells the two apart — so both sides of the map
    # build their key through here, or they drift apart in silence.
    def self.expression_key(first_line, first_column, last_line, last_column)
      "#{first_line}:#{first_column}-#{last_line}:#{last_column}"
    end

    # The same key for a Prism node — the LOOKUP side of the map. Character
    # columns, because Parser counts characters where Prism also offers bytes,
    # and a source with multibyte text has to line up (felixefelip/rbs_infer#142).
    def self.prism_expression_key(location)
      expression_key(location.start_line, location.start_character_column,
                     location.end_line, location.end_character_column)
    end

    # Returns the type of a specific node within the typing result.
    # Useful for resolving argument types in call sites.
    # Returns { expression_key => "Type" } for all typed expressions.
    def all_expression_types(source_code)
      typing = type_check(source_code)
      return {} unless typing

      result = {}

      typing.each_typing do |node, type|
        loc = node.loc&.expression
        next unless loc

        type_str = RbsInfer::Signatures::SteepBridge::TypeFormatter.format_type(type)
        next if type_str == "untyped" || type_str == "bot"

        key = self.class.expression_key(loc.first_line, loc.column, loc.last_line, loc.last_column)
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

    # `{ "set_post" => { "@post" => "(::Post & ::Post::Validated)" } }` — for each
    # instance method of `class_name`, the ivars its postcondition proves populated
    # once it has run.
    #
    # rbs_infer needs this for the same reason it needs `callback_self_types`: the
    # narrowing is a FLOW fact, and the analyzer has no flow analysis. A controller's
    # declared `@post` is `(Post | (Post & Post::Validated))?` — nilable, because the
    # ivar is assigned in `set_post` rather than in `initialize` — but at a call site
    # that the pseudo-code shows running AFTER `set_post`, the narrowed type holds.
    # Reading the same sidecar Steep consumes lets call-site inference use it
    # (felixefelip/rbs_infer#109).
    def postcondition_established_ivars(class_name)
      return {} unless class_name

      store = postconditions_store
      return {} if store.nil? || store.empty?

      key = class_name.to_s.sub(/\A::/, "")
      result = {}
      store.entries.each do |(entry_class, method_name), entry|
        next unless entry_class == key

        types = entry.unconditional&.ivar_type_strings
        next if types.nil? || types.empty?

        result[method_name.to_s] = types.transform_keys(&:to_s)
      end
      result
    end

    # `{ "render" => [{ param: "target", pattern: ":edit", ivars: { "@post" => "..." } }] }`
    # — the argument-sensitive partitions of `class_name`'s methods
    # (felixefelip/steep#89, #91, #95).
    #
    # The fork records, per (method, parameter, literal), what the callers passing that
    # literal had established. Inside a `when :edit` branch the facts of the `:edit`
    # partition hold, which is how a shared dispatcher like a controller's `render`
    # override stays precise instead of collapsing to the meet over all its callers.
    # rbs_infer needs it for the same reason it needs `postcondition_established_ivars`:
    # the narrowing is a flow fact and the analyzer has no flow analysis.
    def argument_entry_partitions(class_name)
      return {} unless class_name

      store = postconditions_store
      return {} if store.nil? || store.empty?

      key = class_name.to_s.sub(/\A::/, "")
      result = Hash.new { |h, k| h[k] = [] }
      store.argument_entry_facts.each do |(entry_class, method_name), partitions|
        next unless entry_class == key

        partitions.each do |partition|
          ivars = partition[:ivars]
          next if ivars.nil? || ivars.empty?

          result[method_name.to_s] << {
            param: partition[:param_name].to_s,
            pattern: partition[:pattern].to_s,
            ivars: ivars.transform_keys(&:to_s).transform_values(&:to_s)
          }
        end
      end
      result
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

    private

    def steep_bridge_ivar_write_analyzer
      @steep_bridge_ivar_write_analyzer ||= IvarWriteAnalyzer.new(steep_bridge: self)
    end

    def type_check_uncached(source_code)
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
        delegation_registry: delegation_registry_store,
        constructor_bindings: constructor_bindings_store,
        return_forwarding: return_forwarding_store,
        return_alias: return_alias_store
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

    def constructor_bindings_store
      @constructor_bindings_store ||= Steep::Project::ConstructorBindingRegistry.new
    end

    def return_forwarding_store
      @return_forwarding_store ||= Steep::Project::ReturnForwardingRegistry.new
    end

    def return_alias_store
      @return_alias_store ||= Steep::Project::ReturnAliasRegistry.new
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

    # The method a top-level body stands for, from its `@type self_method:` annotation
    # (felixefelip/steep#85), or nil when the body carries none.
    def self_method_name(typing)
      root = typing.source.node or return nil
      (typing.source.mapping[root] || []).each do |annot|
        return annot.method_name.to_s if annot.is_a?(Steep::AST::Annotation::SelfMethod)
      end
      nil
    rescue StandardError
      nil
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
