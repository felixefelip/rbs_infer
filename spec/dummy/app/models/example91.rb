# example90 with the class handed on before the string is evaluated, the way
# Active Record's `has_many` hands it: `Builder::HasReader.build(self, name)`
# → `define_accessors(model, name)` → `define_readers(mixin, name)` →
# `mixin.class_eval` — felixefelip/steep#255.
#
# `has_reader :comments` builds `Post::GeneratedAssociationMethods`, includes
# it and defines `comments` in it; `has_reader :tags` defines `tags` there.
#
# Nothing here states a type.
module Example91
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

  module Builder
    class HasReader
      def self.build(model, name)
        define_accessors(model, name)
      end

      def self.define_accessors(model, name)
        mixin = model.generated_association_methods
        define_readers(mixin, name)
      end

      def self.define_readers(mixin, name)
        mixin.class_eval "def #{name}; 1; end"
      end
    end
  end

  class Base
    extend Core::ClassMethods

    def self.has_reader(name)
      Builder::HasReader.build(self, name)
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
