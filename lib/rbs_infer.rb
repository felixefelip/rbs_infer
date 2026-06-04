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

  # Verifica se um caminho de arquivo corresponde exatamente ao path da classe,
  # evitando falsos positivos como "via_magic_link.rb" ao buscar "magic_link.rb".
  def self.file_matches_class_path?(file, class_path, ext: ".rb")
    file == "#{class_path}#{ext}" || file.end_with?("/#{class_path}#{ext}")
  end
end

require_relative "rbs_infer/analyzer"
require_relative "rbs_infer/setter_marker_synthesizer"
require_relative "rbs_infer/predicate_marker_synthesizer"
require_relative "rbs_infer/dependency_sorter"

# Source expanders padrão (plugins de RbsInfer::SourceExpanders). Cada um
# se auto-registra no require; gems externas podem registrar os seus sem
# tocar o core. O expander de CurrentAttributes é puro Prism (sem Rails
# em runtime) e se auto-gateia pela superclasse, então é seguro sempre.
require_relative "rbs_infer/extensions/rails/current_attributes_expander"

require_relative "rbs_infer/railtie" if defined?(Rails::Railtie)
