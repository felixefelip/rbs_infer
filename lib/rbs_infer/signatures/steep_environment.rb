require "steep"

module RbsInfer::Signatures
  # The project's RBS environment, loaded once per process and shared.
  #
  # This is not a SteepBridge internal: `RbsDefinitionResolver` reads
  # `definition_builder` for pure RBS lookups, and `RbsTypeLookup` mirrors the
  # `Dir.pwd` guard and pairs its `reset!` with this one. It lives beside them
  # rather than inside the bridge so neither has to reach through a type
  # checker to get an RBS environment.
  #
  # Loading it costs ~1s, so both the builder and the Steep context derived
  # from it are memoized at the module level, keyed by working directory —
  # a `chdir` (the CLI never does mid-run, but tests do) starts fresh.
  module SteepEnvironment
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
  end
end
