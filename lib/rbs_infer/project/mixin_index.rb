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

    private

    EMPTY = Set.new.freeze
    private_constant :EMPTY

    # Files whose class/module includes `short`.
    def host_files(short)
      @included_shorts.filter_map { |file, shorts| file if shorts.include?(short) }
    end

    def build(source_files)
      source_files.each do |file|
        entry = @parse_cache.get(file)
        next unless entry

        extractor = RbsInfer::AST::ClassNameExtractor.new(file_path: file)
        entry.result.value.accept(extractor)
        class_name = extractor.class_name
        next unless class_name

        @files_defining[class_name.split("::").last] << file
        @included_shorts[file] = include_short_names(entry.result.value)
      end
    end

    # Short names from the arguments of `include A, B::C` / `prepend A`.
    def include_short_names(root)
      shorts = Set.new
      RbsInfer::Analyzer.find_all_nodes(root) do |n|
        n.is_a?(Prism::CallNode) && n.receiver.nil? &&
          (n.name == :include || n.name == :prepend) && n.arguments
      end.each do |call|
        call.arguments.arguments.each do |arg|
          name = RbsInfer::Analyzer.extract_constant_path(arg)
          shorts << name.split("::").last if name
        end
      end
      shorts
    end
  end
end
