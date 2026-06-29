# frozen_string_literal: true

require_relative "rbs_infer/version"

module RbsInfer
  ITERATOR_METHODS = %i[each map flat_map select reject filter find detect collect each_with_object].to_set

  ParsedFile = Data.define(:result, :source, :comments, :lines) do
    def tree = result.value
  end

  def self.class_name_to_path(class_name)
    class_name.sub(/\A::/, "")
              .gsub("::", "/")
              .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
              .gsub(/([a-z])([A-Z])/, '\1_\2')
              .downcase
  end

  # Path (sem extensão) → nome da constante, pela mesma convenção de
  # camelização que o rbs_infer usa para nomear a classe/módulo de um arquivo
  # (e que o Zeitwerk garante para apps Rails). Inverso conveniente de
  # `class_name_to_path` no caso convencional.
  #   "sugestoes_helper"   → "SugestoesHelper"
  #   "admin/posts_helper" → "Admin::PostsHelper"
  def self.path_to_class_name(path)
    path.split("/").map { |segment| segment.split(/[_-]/).map(&:capitalize).join }.join("::")
  end

  # Verifica se um caminho de arquivo corresponde exatamente ao path da classe,
  # evitando falsos positivos como "via_magic_link.rb" ao buscar "magic_link.rb".
  def self.file_matches_class_path?(file, class_path, ext: ".rb")
    file == "#{class_path}#{ext}" || file.end_with?("/#{class_path}#{ext}")
  end
end

require_relative "rbs_infer/analyzer"
require_relative "rbs_infer/markers/setter_marker_synthesizer"
require_relative "rbs_infer/markers/predicate_marker_synthesizer"
require_relative "rbs_infer/project/dependency_sorter"

# Default source expanders (RbsInfer::Project::SourceExpanders plugins). Each one
# registers itself on require; external gems can register their own
# without touching the core. The CurrentAttributes expander is pure Prism
# (no Rails at runtime) and self-gates on the superclass, so it is always
# safe to load.
require_relative "rbs_infer/extensions/rails/current_attributes_expander"
# The on_load expander rewrites `ActiveSupport.on_load :hook do ... end`
# into a plain class reopening (felixefelip/rbs_infer#38) — pure Prism,
# self-gates on the `on_load` substring, so it is always safe to load.
require_relative "rbs_infer/extensions/rails/on_load_expander"
# The class_methods expander rewrites an ActiveSupport::Concern's
# `class_methods do ... end` into a nested `module ClassMethods ... end`
# (felixefelip/rbs_infer#60) — pure Prism, self-gates on the
# `class_methods` substring, so it is always safe to load.
require_relative "rbs_infer/extensions/rails/class_methods_expander"
# Computes module/concern self-type annotations from the AST (correct
# acronym casing) + Rails path conventions, for Steep's generic injector
# (felixefelip/rbs_infer#52). Pure Prism/string logic, safe to always load.
require_relative "rbs_infer/extensions/rails/module_self_type_annotator"

require_relative "rbs_infer/railtie" if defined?(Rails::Railtie)
