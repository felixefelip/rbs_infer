module RbsInfer::Project
  # For a target module (concern), resolves the files whose *bare* calls (no
  # receiver) can reach the module's instance methods.
  #
  # A concern's methods are mixed into the host and called without a receiver —
  # not only in the host's own file, but in the host's *other* concerns too:
  # sibling modules share the host's `self`, so a bare `track_event :x` in
  # `Card::Statuses` reaches `Eventable#track_event` because `Card` includes
  # both. Those sibling files never name the concern, so the constant-reference
  # index (`SourceIndex`) doesn't find them.
  #
  # This index parses each file once, recording per file: the class/module it
  # defines and the short names it `include`s/`prepend`s. From that it answers
  # `files_reaching(module_name)` = host files (that include the module) ∪ the
  # files of every sibling module those hosts also include.
  class MixinIndex
    def initialize(source_files, parse_cache: nil)
      @parse_cache = parse_cache || ParseCache.new
      @included_shorts = {}                            # file → Set[short name]
      @files_defining = Hash.new { |h, k| h[k] = [] }  # short name → [file]
      @includes_by_class = Hash.new { |h, k| h[k] = Set.new } # class FQN → Set[written name]
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
    # Every nesting of the host is a candidate.
    def hosts_of(module_name)
      target = unqualified(module_name)

      @includes_by_class.filter_map do |host, written|
        host if written.any? { |name| resolves_to?(name, host, target) }
      end.sort
    end

    private

    EMPTY = Set.new.freeze
    private_constant :EMPTY

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
    end

    # Whether `written`, as it appears inside `host`, names `target`.
    def resolves_to?(written, host, target)
      name = unqualified(written)
      return true if name == target

      nestings(host).any? { |prefix| "#{prefix}::#{name}" == target }
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
