require "rbs"

module RbsInfer
  class Analyzer

  # Utilitário para extrair informações de classes/módulos usando RBS::Parser.
  # Substitui os parsers ad-hoc baseados em regex por parsing oficial da AST RBS.
  module RbsParserUtil
    module_function

    # Extrai superclass, tipos de método, includes e class methods de uma classe/módulo.
    # Equivalente ao antigo parse_rbs_class_block, mas usando RBS::Parser.
    def class_info_from_rbs(content, class_name)
      _, _, declarations = RBS::Parser.parse_signature(content)
      normalized = class_name.sub(/\A::/, "")

      superclass = nil
      types = {}
      includes = []
      class_method_types = {}

      find_declaration(declarations, normalized) do |decl|
        superclass = extract_superclass(decl)
        extract_members(decl.members, types, includes, class_method_types, normalized)
      end

      RbsClassInfo.new(superclass:, types:, includes:, class_method_types:)
    end

    # Verifica se um módulo contém sub-módulo ClassMethods (declarado, não incluído).
    def has_class_methods_submodule?(content, module_name)
      _, _, declarations = RBS::Parser.parse_signature(content)
      normalized = module_name.sub(/\A::/, "")

      found = false
      find_declaration(declarations, normalized) do |decl|
        decl.members.each do |member|
          if member.is_a?(RBS::AST::Declarations::Module) && member.name.to_s == "ClassMethods"
            found = true
            break
          end
        end
      end
      found
    end

    # Encontra uma declaração pelo FQN, navegando recursivamente pela AST.
    # Chama o bloco quando encontra a declaração alvo.
    def find_declaration(declarations, target_fqn, current_prefix = "", &block)
      declarations.each do |decl|
        next unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

        decl_name = decl.name.to_s.sub(/\A::/, "")
        fqn = if decl.name.namespace.absolute? || current_prefix.empty?
                decl_name
              else
                "#{current_prefix}::#{decl_name}"
              end

        if fqn == target_fqn
          block.call(decl)
        end

        # Recursar em membros que são declarações aninhadas
        nested = decl.members.select { |m|
          m.is_a?(RBS::AST::Declarations::Class) || m.is_a?(RBS::AST::Declarations::Module)
        }
        find_declaration(nested, target_fqn, fqn, &block) if nested.any?
      end
    end

    def extract_superclass(decl)
      return nil unless decl.is_a?(RBS::AST::Declarations::Class)
      decl.super_class&.name&.to_s&.sub(/\A::/, "")
    end

    def extract_members(members, types, includes, class_method_types, parent_fqn)
      members.each do |member|
        case member
        when RBS::AST::Members::MethodDefinition
          ret = extract_return_type(member)
          next unless ret
          name = member.name.to_s
          if member.kind == :singleton
            class_method_types[name] ||= ret
          else
            types[name] ||= ret
          end
        when RBS::AST::Members::Include
          mod_name = member.name.to_s.sub(/\A::/, "")
          # Qualificar nomes não-qualificados com o namespace pai
          if !mod_name.include?("::") && parent_fqn.include?("::")
            parent_ns = parent_fqn.split("::")[0..-2].join("::")
            mod_name = "#{parent_ns}::#{mod_name}"
          end
          includes << mod_name
        when RBS::AST::Members::AttrReader, RBS::AST::Members::AttrAccessor, RBS::AST::Members::AttrWriter
          type_str = member.type.to_s
          types[member.name.to_s] ||= type_str unless type_str == "untyped"
        end
      end
    end

    def extract_return_type(method_def)
      overload = method_def.overloads.first
      return nil unless overload
      overload.method_type.type.return_type.to_s
    end
  end

  end
end
