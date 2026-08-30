# frozen_string_literal: true

require "steep"
require "pathname"

module RbsInfer::Project
  # The project's own list of Ruby sources, read off its Steepfile.
  #
  # `check` is where a project says its Ruby lives, and it is the same list
  # `steep check` reads — so what rbs_infer resolves against cannot drift from
  # what the checker sees. Guessing a layout (`app/`/`engines/`/`lib/`) was
  # wrong in both directions: it missed a project that keeps code elsewhere,
  # and it missed the pseudo-code sidecars under `sig/`, which is what erased a
  # concern's whole `ClassMethods` block from a one-file run
  # (felixefelip/rbs_infer#291).
  #
  # `signature_pattern` is deliberately NOT read: those are `.rbs`, and this
  # list is handed to a Ruby parser. `inline_source_pattern` IS — inline RBS is
  # checked-in Ruby, and a call site in it counts like any other.
  #
  # ## `ignores:` — two different questions
  #
  # A Steepfile `ignore` says "report no diagnostics here", not "this file is
  # not part of the program". A framework-patching file is exactly the shape
  # that gets ignored while still declaring the DSL a checked file calls
  # (`lib/rails_ext/**` in the dummy). So a caller asking WHAT TO CHECK passes
  # `ignores: true`, and a caller asking WHAT THE PROGRAM DECLARES — which is
  # what a resolution corpus is asking — passes `ignores: false`
  # (felixefelip/rbs_infer#222).
  class SteepfileSources
    STEEPFILE = "Steepfile"

    def self.call(dir: Dir.pwd, ignores: true)
      new(dir: dir, ignores: ignores).call
    end

    def initialize(dir:, ignores:)
      @dir = Pathname(dir)
      @ignores = ignores
    end

    # The paths, relative to `dir`, or `nil` when there is no Steepfile to
    # read — the CLI runs against plain directories too, and a project that
    # never adopted Steep still has a corpus. `nil` rather than `[]` so a
    # caller can tell "no Steepfile" from "a Steepfile that matched nothing",
    # which are not the same answer.
    def call
      path = @dir + STEEPFILE
      return nil unless path.file?

      paths = expand(parse(path))
      # A Steepfile that resolves to nothing is a broken read, not a project
      # with no code: falling through in silence would degrade every type in
      # the run to `untyped` with nothing said about why.
      if paths.empty?
        warn "#{path}: no source files matched; falling back."
        return nil
      end

      paths
    # `ScriptError` alongside `StandardError`: a Steepfile is `instance_eval`ed,
    # so a typo in it arrives as a `SyntaxError`, which is not a StandardError
    # and used to abort the whole run.
    rescue StandardError, ScriptError => e
      warn "#{path}: could not be read (#{e.class}: #{e.message}); falling back."
      nil
    end

    private

    def parse(path)
      Steep::Project.new(steepfile_path: path.expand_path).tap do |project|
        Steep::Project::DSL.parse(project, path.read, filename: path.to_s)
      end
    end

    # Every target, and every group inside it — a grouped target holds its
    # patterns on the groups, and reading only the target would return the
    # ungrouped remainder.
    def expand(project)
      loader = Steep::Services::FileLoader.new(base_dir: project.base_dir)

      project.targets.flat_map { |target| [target, *target.groups] }
             .flat_map { |scope| [scope.source_pattern, scope.inline_source_pattern] }
             .compact
             .flat_map { |pattern| loader.each_path_in_patterns(without_ignores(pattern)).map(&:to_s) }
             .uniq
             .sort
    end

    def without_ignores(pattern)
      return pattern if @ignores

      Steep::Project::Pattern.new(patterns: pattern.patterns, ext: pattern.ext, ignores: [])
    end
  end
end
