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
end

require_relative "rbs_infer/analyzer"
require_relative "rbs_infer/dependency_sorter"
require_relative "rbs_infer/railtie" if defined?(Rails::Railtie)
