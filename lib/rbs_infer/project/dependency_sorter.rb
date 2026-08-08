require "prism"
require "set"

module RbsInfer::Project
  # Builds a dependency graph from source files and returns them sorted in
  # topological order (grouped into levels).  Files in the same level have
  # no inter-dependencies and can be generated in any order; files in level
  # N+1 depend only on files from levels 0..N.
  #
  # This lets the CLI generate RBS level-by-level, resetting Steep once per
  # level transition instead of iterating "generate-all → diff → re-run".
  class DependencySorter
    # Returns an Array of Arrays (levels).  Each level is an Array of file
    # paths.  Level 0 contains files with no project-class dependencies.
    def self.sort(files)
      new(files).sorted_levels
    end

    def initialize(files)
      @files = files
      @file_class = {}     # file → class_name defined in file
      # class_name → EVERY file that declares it. A class reopened across files is
      # the norm here, not an oddity: `Tag` is `app/models/tag.rb` *and* the
      # AR-runtime pseudo-code that reopens it. Keying one file per class silently
      # dropped all but the last one scanned, so an edge meant for `app/models/tag.rb`
      # landed on `sig/generated/steep_ar_runtime/tag.rb` instead.
      @class_files = Hash.new { |h, k| h[k] = [] }
      @file_deps = {}      # file → Set of files it depends on
      @prepared = false
    end

    def sorted_levels
      prepare
      topological_levels
    end

    # `file → Set[file]` over BOTH directions of every dependency edge: the files
    # a file references and the files that reference it. Read as "whose generated
    # RBS can this file's inference have read, and whose can have read this one's".
    #
    # Both directions are needed because the two halves of inference read the graph
    # opposite ways. A RETURN type is resolved from the callee's RBS, so a file
    # reads the RBS of what it references — the direction `sorted_levels` orders
    # by. A PARAMETER type is inferred from call sites, so a file's RBS depends on
    # its CALLERS, which reference it. One edge, two readers, and a change at
    # either end can move the other.
    #
    # This is what the stabilization loop requeues on. Re-running only the files
    # whose own RBS changed is not enough: when the AR-runtime pseudo-code's
    # `from_params(params)` finally got a typed parameter, nothing re-ran
    # `app/models/filter.rb`, which reads that parameter through the pseudo-code's
    # `::Filter.from_params(params)` call site — it had already been generated in an
    # earlier level (it is a dependency of the pseudo-code, not a dependent) and had
    # not changed in the pass, so it was not in the queue. The type only landed on
    # the NEXT whole invocation of the CLI (felixefelip/rbs_infer#193 follow-up).
    def neighbors
      prepare
      @neighbors ||= @file_deps.each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |(file, deps), map|
        deps.each do |dep|
          map[file] << dep
          map[dep] << file
        end
      end
    end

    private

    def prepare
      return if @prepared
      @prepared = true

      scan_files
      build_dependency_graph
    end

    # Phase 1: For each file, extract the class it defines and the constant
    # names it references.
    def scan_files
      @file_class = {}
      @file_refs = {}  # file → Set of referenced constant short names

      @files.each do |file|
        begin
          source = File.read(file)
        rescue Errno::ENOENT, Errno::EACCES
          next
        end

        result = Prism.parse(source)

        # Extract class/module name defined in this file
        extractor = RbsInfer::AST::ClassNameExtractor.new(file_path: file)
        result.value.accept(extractor)
        class_name = extractor.class_name
        next unless class_name

        @file_class[file] = class_name
        @class_files[class_name] << file

        # Extract all constant references in the file
        refs = Set.new
        collect_constant_refs(result.value, refs)

        # Remove self-reference
        own_short = class_name.split("::").last
        refs.delete(own_short)

        @file_refs[file] = refs
      end
    end

    # Phase 2: Resolve constant references to actual files, building
    # file → Set[file] dependency edges.
    def build_dependency_graph
      # Build short_name → [class_name] index
      short_to_classes = Hash.new { |h, k| h[k] = [] }
      @class_files.each_key do |cn|
        short_to_classes[cn.split("::").last] << cn
      end

      @file_deps = {}
      @files.each do |file|
        refs = @file_refs[file]
        next unless refs

        deps = Set.new
        refs.each do |short_name|
          short_to_classes[short_name].each do |cn|
            @class_files[cn].each { |dep_file| deps << dep_file if dep_file != file }
          end
        end
        @file_deps[file] = deps
      end
    end

    # Phase 3: Kahn's algorithm for topological sort, returning
    # files grouped by level (depth from root).
    def topological_levels
      in_degree = Hash.new(0)
      @files.each { |f| in_degree[f] = 0 }
      @file_deps.each do |_file, deps|
        deps.each { |d| in_degree[d] += 0 } # ensure dep exists in hash
      end
      @file_deps.each do |file, deps|
        # file depends on deps → if dep's RBS changes, file may change.
        # We need reverse: to know when a file is "ready" (all its deps
        # have been generated).  So edges go: dep → file.
        # in_degree[file] = number of deps not yet generated.
        in_degree[file] = (deps & Set.new(@files)).size
      end

      # Collect adjacency (reverse: dep → files that depend on it)
      dependents = Hash.new { |h, k| h[k] = [] }
      @file_deps.each do |file, deps|
        deps.each do |dep|
          dependents[dep] << file if @files.include?(dep)
        end
      end

      levels = []
      remaining = @files.dup

      loop do
        # Current level: files with no unresolved deps
        level = remaining.select { |f| in_degree[f] <= 0 }
        break if level.empty?

        levels << level
        level.each do |f|
          remaining.delete(f)
          dependents[f].each { |dep| in_degree[dep] -= 1 }
        end
      end

      # Any remaining files are in cycles — add them as a final level
      levels << remaining unless remaining.empty?

      levels
    end

    # Recursively collect short constant names referenced in the AST
    def collect_constant_refs(node, refs)
      case node
      when Prism::ConstantReadNode
        refs << node.name.to_s
      when Prism::ConstantPathNode
        # Collect the rightmost name (the short class name)
        refs << node.name.to_s
        # Also traverse the parent path for nested refs
        collect_constant_refs(node.parent, refs) if node.parent
        return # don't re-traverse children
      end

      node.compact_child_nodes.each { |child| collect_constant_refs(child, refs) }
    end
  end
end
