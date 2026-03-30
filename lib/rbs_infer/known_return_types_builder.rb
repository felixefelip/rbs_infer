module RbsInfer
  # Módulo que constrói o hash `known_return_types` a partir de
  # members, attr_types e method_type_resolver.
  # Padrão repetido em ReturnTypeResolver e TypeMerger.
  module KnownReturnTypesBuilder
    def build_known_return_types(members, attr_types, method_type_resolver: nil, target_class: nil, instance_types: [])
      types = {}
      attr_types.each { |name, type| types[name] = type }

      members.each do |m|
        case m.kind
        when :method
          if m.signature =~ /.*->\s*(.+)$/ && $1.strip != "untyped" && $1.strip != "void"
            types[m.name] = $1.strip
          end
        when :attr_accessor, :attr_reader
          if m.signature =~ /\w+:\s*(.+)/
            type = $1.strip
            types[m.name] = type unless type == "untyped"
          end
        end
      end

      if method_type_resolver && target_class
        resolver_types = method_type_resolver.resolve_all(target_class)
        resolver_types.each { |name, type| types[name] ||= type }
      end

      # Resolver métodos das classes declaradas em @type instance
      if method_type_resolver && instance_types.any?
        instance_types.each do |inst_class|
          inst_types = method_type_resolver.resolve_all(inst_class)
          inst_types.each { |name, type| types[name] ||= type }
        end
      end

      types
    end
  end
end
