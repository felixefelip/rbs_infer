module Example109
  module Core
    module ClassMethods
      def generated_relation_methods
        @generated_relation_methods ||= begin
          mod = const_set(:GeneratedRelationMethods, Module.new)
          private_constant :GeneratedRelationMethods
          include mod

          mod
        end
      end
    end
  end
end
