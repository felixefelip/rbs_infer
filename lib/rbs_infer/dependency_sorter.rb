require "prism"
require "set"

module RbsInfer
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
      @class_file = {}     # class_name → file
      @file_deps = {}      # file → Set of files it depends on
    end

    def sorted_levels
      scan_files
      build_dependency_graph
      topological_levels
    end

    private

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
        extractor = ClassNameExtractor.new
        result.value.accept(extractor)
        class_name = extractor.class_name
        next unless class_name

        @file_class[file] = class_name
        @class_file[class_name] = file

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
      @class_file.each_key do |cn|
        short_to_classes[cn.split("::").last] << cn
      end

      @file_deps = {}
      @files.each do |file|
        refs = @file_refs[file]
        next unless refs

        deps = Set.new
        refs.each do |short_name|
          short_to_classes[short_name].each do |cn|
            dep_file = @class_file[cn]
            deps << dep_file if dep_file && dep_file != file
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
