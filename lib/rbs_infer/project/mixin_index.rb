module RbsInfer::Project
  # The project's mixin graph. One pass over every source file, recording what
  # each one DEFINES and what it `include`s/`prepend`s, to answer the two
  # questions a mixin raises.
  #
  # **Who can call into this module** — `files_reaching`. A concern's methods
  # are mixed into the host and called without a receiver, not only in the
  # host's own file but in the host's *other* concerns: sibling modules share
  # the host's `self`, so a bare `track_event :x` in `Card::Statuses` reaches
  # `Eventable#track_event` because `Card` includes both. Those sibling files
  # never name the concern, so the constant-reference index (`SourceIndex`)
  # doesn't find them. The answer is host files ∪ the files of every sibling
  # module those hosts also include.
  #
  # **What `self` is inside it** — `hosts_of`, the classes that include it
  # (felixefelip/rbs_infer#163), and `extenders_of`, the ones that `extend` it.
  # Two methods rather than one because the answers are types of different
  # KINDS: an `include` puts the module in the host's instance ancestry, so
  # `self` is an instance (`Card & Card::Entropic`); an `extend` puts it in the
  # host's SINGLETON ancestry, so `self` is the class/module object itself
  # (`singleton(Bar)`). Folding them into one list would hand a caller a name it
  # cannot tell apart, and the wrong one of the two is a wrong signature.
  #
  # The two match names differently, on purpose. Reachability keys on the short
  # name: a false positive only widens a search that is then filtered by what
  # the calls actually resolve to. A self-type cannot afford one — naming the
  # wrong host puts a wrong type in a signature — so `hosts_of` resolves the
  # written name to an FQN the way Ruby does.
  class MixinIndex
    def initialize(source_files, parse_cache: nil)
      @parse_cache = parse_cache || ParseCache.new
      @included_shorts = {}                            # file → Set[short name]
      @extended_shorts = {}                            # file → Set[short name]
      @written_mixin_names = Set.new                   # every name written in an include/extend
      @files_defining = Hash.new { |h, k| h[k] = [] }  # short name → [file]
      @includes_by_class = Hash.new { |h, k| h[k] = Set.new } # class FQN → Set[written name]
      @extends_by_class = Hash.new { |h, k| h[k] = Set.new }  # class FQN → Set[written name]
      @module_declarations = Set.new                          # FQNs declared as `module`
      @hosts_by_target = {}                                   # target FQN → [host FQN]
      @extenders_by_target = {}                               # target FQN → [extender FQN]
      @hosts_of_cache = {}                                    # target FQN → resolved hosts
      @extenders_of_cache = {}                                # target FQN → resolved extenders
      @ancestor_builder = nil                                 # RBS env the memo below belongs to
      @ancestor_shorts = {}                                   # written name → Set[ancestor short]
      build(source_files)
    end

    # Files whose bare calls can reach instance methods of `module_name`
    # (the host + the host's sibling concerns).
    #
    # A host is any file mixing in something that CARRIES the target, not only
    # one naming it: `include` chains, and the chain may run through a module
    # the corpus has no Ruby for. Every ERB template includes `ActionViewContext`,
    # which is emitted as `.rbs` and includes every app helper — so a partial
    # calling `idade_recomendada_para(recomendacao_vacina)` was not a host of
    # `SugestoesHelper`, was swept by no other route either (it names no
    # constant, and the call is bare), and the helper's parameter came out
    # `untyped` with the call site never read.
    def files_reaching(module_name)
      carriers = carrier_shorts(module_name)
      result = Set.new
      host_files(carriers).each do |host|
        result << host
        @included_shorts.fetch(host, EMPTY).each do |sibling_short|
          next if carriers.include?(sibling_short)
          @files_defining[sibling_short].each { |f| result << f }
        end
      end
      result.to_a
    end

    # Classes that `include`/`prepend` `module_name`, by FQN — the answer to
    # "what is `self` inside this module", read off the source instead of
    # guessed from a naming convention (felixefelip/rbs_infer#163).
    #
    # Every one of them, not the first: a module mixed into two classes has two
    # possible `self`s, and saying one would be a claim the code does not make.
    #
    # Matching has to resolve the written name, which is rarely the FQN: Ruby
    # looks a constant up outward through the enclosing namespaces, so `include
    # Eventable` inside `class Card` may mean `Card::Eventable` or `::Eventable`
    # — whichever the project declares first, innermost out. `@hosts_by_target`
    # has already settled that, so the answer is a lookup rather than a scan.
    def hosts_of(module_name)
      @hosts_of_cache[unqualified(module_name)] ||= resolve_hosts(module_name, Set.new)
    end

    # Classes and modules whose SINGLETON gets `module_name` — `extend Foo`, by
    # FQN. `self` inside `Foo`'s instance methods is then the extender's class
    # object, `singleton(Bar)`, which is why these are not merged into
    # `hosts_of`.
    #
    # A module is as good an answer as a class here, and is NOT resolved through
    # the way `hosts_of` resolves an including module: `module Baz; extend Foo`
    # makes the object `Baz` itself the receiver of `Foo`'s methods, so `Baz` is
    # the self, not a waypoint to one.
    #
    # Reached through an including module, though: when `module M` includes the
    # target and `class C` extends `M`, `C`'s singleton carries the target too,
    # so `singleton(C)` is one of the target's selves.
    def extenders_of(module_name)
      @extenders_of_cache[unqualified(module_name)] ||= resolve_extenders(module_name, Set.new)
    end

    # Whether the sources declare `name` with `module` rather than `class`.
    #
    # A caller relocating a body needs the keyword the reopening must use, and
    # getting it wrong is not a worse type but a broken environment: `module
    # Post` over a `class Post` is a `RBS::…MismatchError` that poisons the run.
    # False for a name the corpus never declares — a gem's, a framework's —
    # which is the same "nothing to add here" every other lookup here answers.
    def module?(name)
      @module_declarations.include?(unqualified(name))
    end

    private

    EMPTY = Set.new.freeze
    private_constant :EMPTY

    EMPTY_ARRAY = [].freeze
    private_constant :EMPTY_ARRAY

    # `seen` is recursion state, threaded rather than exposed: only the outermost
    # call is memoized, so a cached entry is always the complete answer.
    def resolve_hosts(module_name, seen)
      target = unqualified(module_name)
      return [] unless seen.add?(target)

      # A MODULE that includes the target is not a `self` — it is another mixin,
      # and the real self is whoever includes IT. Fizzy's `Authentication` is
      # included by `ActiveStorage::Authorize`, a concern; answering `Authorize`
      # put a module in a position only a class can hold. Resolved through,
      # `seen`-guarded because two concerns can include each other.
      @hosts_by_target.fetch(target, EMPTY_ARRAY)
                      .flat_map { |host| @module_declarations.include?(host) ? resolve_hosts(host, seen) : [host] }
                      .uniq.sort
    end

    # Same `seen`-threading as `resolve_hosts`, and the same reason: only the
    # outermost call is memoized, so a cached entry is the complete answer.
    def resolve_extenders(module_name, seen)
      target = unqualified(module_name)
      return [] unless seen.add?(target)

      direct = @extenders_by_target.fetch(target, EMPTY_ARRAY)
      # `class C; extend M; end` where `module M; include Foo; end` — C's
      # singleton gets M, and M carries Foo, so `singleton(C)` is a self of
      # Foo's instance methods. Only through a MODULE host: a class that
      # includes Foo passes it to its instances, never to its singleton.
      inherited = @hosts_by_target.fetch(target, EMPTY_ARRAY)
                                  .select { |host| @module_declarations.include?(host) }
                                  .flat_map { |host| resolve_extenders(host, seen) }

      (direct + inherited).uniq.sort
    end

    # The short names that carry `module_name` — itself, plus every mixin name
    # the sources write whose ANCESTRY reaches it.
    #
    # The source alone cannot answer the second half. A module declared only in
    # RBS has no `include` line in the corpus for `build` to read, so the chain
    # through it is invisible and `host_files` — which matches a written name
    # against the target's — stops one link short. The RBS environment already
    # holds the answer, transitively and for `.rbs`-only modules alike; this
    # asks it instead of re-deriving a closure over what the corpus happens to
    # show.
    #
    # Asked once per WRITTEN mixin name (dozens), not once per file (hundreds):
    # what a name carries is a property of the name.
    def carrier_shorts(module_name)
      short = module_name.split("::").last
      carriers = Set[short]
      @written_mixin_names.each do |name|
        carriers << name.split("::").last if ancestor_shorts(name).include?(short)
      end
      carriers
    end

    # Short names of every instance ancestor of `name`, per RBS. Empty when the
    # environment cannot answer — a module the generated RBS does not declare
    # yet (a cold run, before `sig/` exists) among them, which is why an empty
    # answer must read as "nothing to add here", never as "includes nothing":
    # the source-derived half of `files_reaching` stands on its own.
    #
    # Memoized against the environment's IDENTITY rather than held for the life
    # of the index. `Corpus` keeps one `MixinIndex` for the whole run because
    # its answers are a pure function of the source files, and this one is not:
    # the CLI regenerates `sig/` between dependency levels and passes and calls
    # `SteepEnvironment.reset!`, which makes the next builder a different
    # object and drops these answers with it — the same key `SteepBridge` hangs
    # its type-check cache on, so there is no new invalidation hook to wire.
    def ancestor_shorts(name)
      builder = RbsInfer::Signatures::SteepEnvironment.definition_builder
      return EMPTY unless builder

      unless @ancestor_builder.equal?(builder)
        @ancestor_builder = builder
        @ancestor_shorts = {}
      end

      @ancestor_shorts[name] ||= compute_ancestor_shorts(builder, name)
    end

    def compute_ancestor_shorts(builder, name)
      type_name = RBS::TypeName.parse("::#{name.sub(/\A::/, "")}")
      builder.ancestor_builder.instance_ancestors(type_name)
             .ancestors.map { |a| a.name.to_s.split("::").last }.to_set
    rescue StandardError
      # An unknown name raises rather than answering empty, and so does a
      # declaration RBS cannot build. Neither is a reason to fail the sweep.
      EMPTY
    end

    # Files whose class/module mixes any of `carriers` in, by either route. A
    # file that only EXTENDS the module still makes bare calls into it —
    # `bazinga(Baz)` in a class body is a call on the class object — so
    # reachability does not care which of the two ancestries carries it.
    def host_files(carriers)
      @included_shorts.filter_map { |file, shorts| file if shorts.intersect?(carriers) } |
        @extended_shorts.filter_map { |file, shorts| file if shorts.intersect?(carriers) }
    end

    def build(source_files)
      owned = {} #: Hash[String, String]

      source_files.each do |file|
        entry = @parse_cache.get(file)
        next unless entry

        extractor = RbsInfer::AST::ClassNameExtractor.new(file_path: file)
        entry.result.value.accept(extractor)
        class_name = extractor.class_name

        unless class_name
          # A source that does not NAME its class still belongs to one — an ERB template is
          # the body of `ERBPostsIndex`. Resolved in a second pass, because the file that
          # DEFINES that class (and carries its `include`s) may come later.
          if (owner = SourceOwners.owner_class(file))
            owned[file] = owner.split("::").last
          end
          next
        end

        mixins = MixinWriter.collect(entry.result.value)
        written = mixins.includes.values.reduce(Set.new, :|)
        extended = mixins.extends.values.reduce(Set.new, :|)

        @module_declarations << class_name if extractor.is_module
        @module_declarations.merge(mixins.module_declarations)
        @files_defining[class_name.split("::").last] << file
        # Reachability keys on the FILE, so the union over its declarations is
        # the right granularity: a bare call anywhere in the file can reach
        # anything anything in it mixes in.
        @included_shorts[file] = written.map { |name| name.split("::").last }.to_set
        @extended_shorts[file] = extended.map { |name| name.split("::").last }.to_set
        # Kept unshortened as well: resolving one against RBS needs the name the
        # source wrote (`ActionView::Helpers`), which the short form has lost.
        @written_mixin_names.merge(written).merge(extended)
        # Self-types cannot use that union — they key on the DECLARATION that
        # wrote the mixin. Attributing a file's every `include` to its headline
        # class made `class Example23; module Baz; extend Foo; end; end` answer
        # `Example23` for "who extends Foo", a class that extends nothing.
        # Merged rather than assigned: a class reopened across files carries the
        # includes of all of them.
        mixins.includes.each { |owner, names| @includes_by_class[owner].merge(names) }
        mixins.extends.each { |owner, names| @extends_by_class[owner].merge(names) }
      end

      # A template's bare calls reach whatever its OWNER includes: `post_status_badge(post)`
      # in `posts/index.html.erb` reaches `PostsHelper` because `ERBPostsIndex` includes it.
      # The include lives in the class's own file, never in the template.
      owned.each do |file, owner_short|
        inherited = Set.new
        @files_defining[owner_short].each do |definer|
          inherited.merge(@included_shorts.fetch(definer, EMPTY))
        end
        @included_shorts[file] = inherited unless inherited.empty?
      end

      @hosts_by_target = index_by_target(@includes_by_class)
      @extenders_by_target = index_by_target(@extends_by_class)
    end

    # The reverse of `@includes_by_class`, built once.
    #
    # `include Eventable` written inside `class Card` names exactly one of a
    # fixed, enumerable set: the name as written, or that name under any of the
    # host's nestings. Nothing about that set depends on what is later asked, so
    # deriving it per query — scanning every class and re-splitting every name to
    # ask "does this one resolve to the target?" — recomputes at every call what
    # one pass over the graph settles for good. Enumerating it here turns
    # `hosts_of` into a hash lookup, and (measured on Fizzy) takes the mixin
    # resolution from ~36% of a run's wall time, plus the GC churn of the strings
    # it allocated, down to noise.
    def index_by_target(mixins_by_class)
      by_target = {}
      mixins_by_class.each do |host, written|
        prefixes = nestings(host)
        written.each do |name|
          targets_for(name, prefixes).each do |target|
            hosts = (by_target[target] ||= [])
            hosts << host unless hosts.include?(host)
          end
        end
      end
      by_target
    end

    # The candidates a written name can mean, innermost nesting first — and,
    # when the project declares one of them, ONLY that one. Ruby stops at the
    # first constant it finds walking outward, so `include Notifiable` inside
    # `class User` means `User::Notifiable` when that module exists and never
    # reaches `::Notifiable`. Registering every candidate instead put `User`
    # among the hosts of a module it does not include, and the concern's self
    # type gained a member nothing inhabits: `(Event & Notifiable) | (Mention &
    # Notifiable) | (User & Notifiable)` (felixefelip/rbs_infer#189).
    #
    # A candidate is only decided against what the sources DECLARE as a module,
    # which is what an `include` can name. When none of them is declared the
    # module is one we cannot see — a gem's, a framework's — and every candidate
    # stays: narrowing on absent evidence would drop hosts that resolve today.
    def targets_for(name, prefixes)
      short = unqualified(name)
      # `include ::Notifiable` says outright which one it means, and no nesting
      # of the host is a candidate for it.
      return [short] if name.to_s.start_with?("::")

      candidates = prefixes.reverse.map { |prefix| "#{prefix}::#{short}" }
      candidates << short
      declared = candidates.find { |candidate| @module_declarations.include?(candidate) }
      declared ? [declared] : candidates
    end

    # `"A::B::C"` → `["A", "A::B", "A::B::C"]`, the namespaces a constant
    # written inside `A::B::C` is looked up against, innermost aside.
    def nestings(name)
      parts = name.split("::")
      parts.each_index.map { |i| parts[0..i].join("::") }
    end

    def unqualified(name)
      name.to_s.sub(/\A::/, "")
    end

    # Every mixin a file writes, attributed to the class or module that
    # lexically encloses it, and split by which ancestry it lands in.
    #
    # The split is not the method name alone: `include` inside `class << self`
    # puts the module on the singleton, which is what `extend` means, so it is
    # recorded as one. That equivalence is Ruby's, not a convention — the two
    # spellings produce the same ancestors.
    class MixinWriter < Prism::Visitor
      INCLUDE_CALLS = %i[include prepend].freeze
      # `extend self` records nothing: its argument is not a constant, so
      # `extract_constant_path` returns nil — and that is the right answer, since
      # a module extending ITSELF names no other host.
      EXTEND_CALLS = %i[extend].freeze

      attr_reader :includes, :extends, :module_declarations

      def self.collect(root)
        new.tap { |writer| root.accept(writer) }
      end

      def initialize
        @stack = []
        @singleton_depth = 0
        @includes = Hash.new { |h, k| h[k] = Set.new }
        @extends = Hash.new { |h, k| h[k] = Set.new }
        @module_declarations = Set.new
        super()
      end

      def visit_class_node(node)
        with_scope(node) { super }
      end

      def visit_module_node(node)
        with_scope(node) { |fqn| @module_declarations << fqn if fqn; super }
      end

      def visit_singleton_class_node(node)
        @singleton_depth += 1
        super
      ensure
        @singleton_depth -= 1
      end

      def visit_call_node(node)
        record(node) if node.receiver.nil? && node.arguments
        super
      end

      private

      # A mixin written at the top level of a file belongs to no declaration and
      # is dropped — `Array.include Foo` has an explicit receiver and never
      # reaches here, and a bare `include Foo` at top level mixes into Object,
      # which is not a self any signature of ours would name.
      def record(node)
        owner = @stack.last or return

        bucket =
          if EXTEND_CALLS.include?(node.name) then @extends
          elsif INCLUDE_CALLS.include?(node.name) then @singleton_depth.positive? ? @extends : @includes
          end
        return unless bucket

        node.arguments.arguments.each do |arg|
          name = RbsInfer::Analyzer.extract_constant_path(arg)
          bucket[owner] << name if name
        end
      end

      # `class A::B` inside `module A` is `A::A::B` nowhere — a compact path is
      # already absolute enough to stand on its own, so a name that carries its
      # own namespace is not re-prefixed.
      def with_scope(node)
        name = RbsInfer::Analyzer.extract_constant_path(node.constant_path)
        fqn =
          if name.nil? then nil
          elsif @stack.empty? || name.include?("::") then name
          else "#{@stack.last}::#{name}"
          end

        @stack.push(fqn) if fqn
        yield fqn
      ensure
        @stack.pop if fqn
      end
    end
    private_constant :MixinWriter
  end
end

require_relative "../signatures/steep_environment"
