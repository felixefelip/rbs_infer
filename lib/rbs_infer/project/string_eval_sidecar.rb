# frozen_string_literal: true

require "yaml"
require "pathname"

module RbsInfer::Project
  # What each call site of a `class_eval`-a-string macro defines there, as the
  # checker folded it.
  #
  #     ---
  #     version: 1
  #     call_sites:
  #       app/models/article.rb:7:2:
  #       - |
  #         def content
  #           rich_text_content || build_rich_text_content
  #         end
  #
  # Written by `steep check` (felixefelip/steep#169) from the specialization
  # pass, and read here the way `.steep_specializations.yml`,
  # `.steep_postconditions.yml` and `.steep_callbacks.yml` already are.
  #
  # The question the expander has — "what does `has_rich_text :content` define
  # on this line" — is a question about a VALUE, and this project answers value
  # questions with the type machinery rather than a second reader. `#{name}` is
  # `:content` at that call site because specialization says so, an
  # interpolation over literals folds to a literal, and the folded literal IS
  # the source. So no binder, no branch reader and no fold live here: what used
  # to be a small interpreter over the macro's body is one file lookup, and the
  # `if`/`case`/default it used to decide are decided by narrowing instead.
  #
  # A `nil` in a list is a chunk whose value the call site does not fix. It is
  # reported rather than left out, and it declines the whole call site: a class
  # given a reader whose writer was dropped is worse than one given neither.
  class StringEvalSidecar
    PATH = "sig/generated/.steep_string_evals.yml"

    # 1 wrote a chunk as a bare string, and the class it lands on was left for
    # the consumer to work out — which it can only do for an eval written on the
    # caller's own self. 2 lets a chunk NAME its class, which is what a receiver
    # like `Target.class_eval "…"` knows and the lexical rule cannot
    # (felixefelip/steep#175). Both are read: a bare string is a chunk with no
    # target, which is exactly what 1 meant.
    SCHEMA_VERSIONS = [1, 2].freeze
    SCHEMA_VERSION = SCHEMA_VERSIONS.last

    # One thing a call site defines. `target` is the class it lands on, or nil
    # for the class whose body holds the call.
    Chunk = Struct.new(:source, :target, keyword_init: true)

    class << self
      def load(base_dir)
        base = Pathname(base_dir).expand_path
        path = base + PATH
        return new({}, base_dir: base) unless path.file?

        raw = YAML.safe_load(path.read)
        version = raw && raw["version"]
        if version && !SCHEMA_VERSIONS.include?(version)
          warn "[rbs_infer] unsupported #{PATH} version #{version} (expected #{SCHEMA_VERSIONS.join(" or ")}); ignoring"
          return new({}, base_dir: base)
        end

        new(((raw && raw["call_sites"]) || {}), base_dir: base)
      rescue StandardError => e
        warn "[rbs_infer] failed to load #{path}: #{e.class}: #{e.message}"
        new({}, base_dir: base)
      end
    end

    def initialize(call_sites, base_dir:)
      @call_sites = call_sites
      @base = Pathname(base_dir).expand_path
    end

    def any?
      !@call_sites.empty?
    end

    # The chunks the call at `path:line:column` defines, or nil when it defines
    # none this run can read — including when one of them is a hole.
    def sources_for(path:, line:, column:)
      entries = @call_sites[key_for(path, line, column)] or return nil
      return nil unless entries.is_a?(Array) && !entries.empty?

      chunks = entries.map { |entry| chunk_for(entry) }
      return nil if chunks.any?(&:nil?)

      chunks
    end

    private

    # A bare string is a chunk with no target — the spelling version 1 wrote,
    # and still what version 2 writes for an eval on the caller's own self. A
    # map carries the class the eval names, and one this cannot read is a hole
    # like any other: a class given half of what a macro writes is worse than
    # one given none.
    def chunk_for(entry)
      case entry
      when String
        Chunk.new(source: entry)
      when Hash
        source = entry["source"]
        target = entry["target"]
        return nil unless source.is_a?(String)
        return nil unless target.nil? || (target.is_a?(String) && !target.strip.empty?)

        Chunk.new(source: source, target: target&.strip&.delete_prefix("::"))
      end
    end

    # The sidecar spells its paths relative to the Steep project, and a caller
    # here may hold the same file absolute. A relative one is resolved against
    # the project too, not against the process's directory: the two are the same
    # for a run of the CLI and differ for anything that changed directory since.
    def key_for(path, line, column)
      "#{relative(path)}:#{line}:#{column}"
    end

    def relative(path)
      pathname = Pathname(path)
      absolute = pathname.absolute? ? pathname : @base + pathname

      absolute.cleanpath.relative_path_from(@base).to_s
    rescue ArgumentError
      path.to_s
    end
  end
end
