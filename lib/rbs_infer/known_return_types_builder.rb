module RbsInfer
  # Módulo que constrói o hash `known_return_types` a partir de
  # members, attr_types e method_type_resolver.
  # Padrão repetido em ReturnTypeResolver e TypeMerger.
  module KnownReturnTypesBuilder
    def build_known_return_types(members, attr_types, method_type_resolver:, target_class:, instance_types:)
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

    # The class-method counterpart of `build_known_return_types`: a
    # name→type map built ONLY from `:class_method` members and the class's
    # singleton RBS. Kept separate from the instance map so a class method
    # and an instance method that share a name resolve against their own
    # surface, never each other's (felixefelip/rbs_infer#33).
    def build_class_method_return_types(members, method_type_resolver:, target_class:)
      types = {}

      members.each do |m|
        next unless m.kind == :class_method
        if m.signature =~ /.*->\s*(.+)$/ && $1.strip != "untyped" && $1.strip != "void"
          types[m.name] = $1.strip
        end
      end

      if method_type_resolver && target_class
        method_type_resolver.resolve_all_class_methods(target_class).each do |name, type|
          types[name] ||= type
        end
      end

      types
    end
  end
end
