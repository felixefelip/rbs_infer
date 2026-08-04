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
  # (felixefelip/rbs_infer#163).
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
      @files_defining = Hash.new { |h, k| h[k] = [] }  # short name → [file]
      @includes_by_class = Hash.new { |h, k| h[k] = Set.new } # class FQN → Set[written name]
      @module_declarations = Set.new                          # FQNs declared as `module`
      @hosts_by_target = {}                                   # target FQN → [host FQN]
      @hosts_of_cache = {}                                    # target FQN → resolved hosts
      build(source_files)
    end

    # Files whose bare calls can reach instance methods of `module_name`
    # (the host + the host's sibling concerns).
    def files_reaching(module_name)
      short = module_name.split("::").last
      result = Set.new
      host_files(short).each do |host|
        result << host
        @included_shorts.fetch(host, EMPTY).each do |sibling_short|
          next if sibling_short == short
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
    # Eventable` inside `class Card` may mean `Card::Eventable` or `::Eventable`.
    # Every nesting of the host is a candidate — which is what `@hosts_by_target`
    # has already enumerated, so the answer is a lookup rather than a scan.
    def hosts_of(module_name)
      @hosts_of_cache[unqualified(module_name)] ||= resolve_hosts(module_name, Set.new)
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

    # Files whose class/module includes `short`.
    def host_files(short)
      @included_shorts.filter_map { |file, shorts| file if shorts.include?(short) }
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

        written = include_written_names(entry.result.value)
        @module_declarations << class_name if extractor.is_module
        @files_defining[class_name.split("::").last] << file
        @included_shorts[file] = written.map { |name| name.split("::").last }.to_set
        # Merged rather than assigned: a class reopened across files carries the
        # includes of all of them.
        @includes_by_class[class_name].merge(written)
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

      index_hosts_by_target
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
    def index_hosts_by_target
      @includes_by_class.each do |host, written|
        prefixes = nestings(host)
        written.each do |name|
          short = unqualified(name)
          candidates = prefixes.map { |prefix| "#{prefix}::#{short}" }
          candidates.unshift(short)
          candidates.each do |target|
            hosts = (@hosts_by_target[target] ||= [])
            hosts << host unless hosts.include?(host)
          end
        end
      end
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

    # Names as WRITTEN in the arguments of `include A, B::C` / `prepend A`.
    def include_written_names(root)
      names = Set.new
      RbsInfer::Analyzer.find_all_nodes(root) do |n|
        n.is_a?(Prism::CallNode) && n.receiver.nil? &&
          (n.name == :include || n.name == :prepend) && n.arguments
      end.each do |call|
        call.arguments.arguments.each do |arg|
          name = RbsInfer::Analyzer.extract_constant_path(arg)
          names << name if name
        end
      end
      names
    end
  end
end
