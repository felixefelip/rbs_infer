# example89 with the memo where Active Record writes it: a method of a module
# the class extends (`ActiveRecord::Core::ClassMethods#generated_association_methods`),
# not a `def self.` of the class — felixefelip/steep#254.
#
# `has_reader :comments` in `Post` runs `generated_association_methods` on
# `Post`, which builds `Post::GeneratedAssociationMethods` and includes it;
# `has_reader :tags` finds it built. So `comments` and `tags` are defined in
# that module, and only the first call declares and includes it.
#
# Nothing here states a type.
module Example90
  module Core
    module ClassMethods
      def generated_association_methods
        @generated_association_methods ||= begin
          mod = const_set(:GeneratedAssociationMethods, Module.new)
          include mod
          mod
        end
      end
    end
  end

  class Base
    extend Core::ClassMethods

    def self.has_reader(name)
      generated_association_methods.class_eval "def #{name}; 1; end"
    end
  end

  class Post < Base
    has_reader :comments
    has_reader :tags
  end

  class Use
    def self.comments = Post.new.comments
    def self.tags = Post.new.tags
  end
end
