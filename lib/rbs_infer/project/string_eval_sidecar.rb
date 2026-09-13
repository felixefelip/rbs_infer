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
    SCHEMA_VERSION = 1

    class << self
      def load(base_dir)
        base = Pathname(base_dir).expand_path
        path = base + PATH
        return new({}, base_dir: base) unless path.file?

        raw = YAML.safe_load(path.read)
        version = raw && raw["version"]
        if version && version != SCHEMA_VERSION
          warn "[rbs_infer] unsupported #{PATH} version #{version} (expected #{SCHEMA_VERSION}); ignoring"
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
      sources = @call_sites[key_for(path, line, column)] or return nil
      return nil unless sources.is_a?(Array) && sources.all? { |source| source.is_a?(String) }
      return nil if sources.empty?

      sources
    end

    private

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
