# A method that picks a class by a key of its options hash, called with a hash
# literal — the shape of Active Record's `association_class`, which picks
# `HasManyThroughAssociation` or `HasManyAssociation` on `options[:through]`
# (felixefelip/steep#210).
#
# `Comments.through` passes `{ through: :posts }`, so it is a `ThroughAssociation`
# class; `Comments.plain` passes `{}` and `Comments.dependent` passes a hash
# without `:through`, so both are a `PlainAssociation` class.
#
# Nothing here states a type.
module Example95
  class PlainAssociation; end
  class ThroughAssociation; end

  class Reflection
    def self.association_class(options)
      options[:through] ? ThroughAssociation : PlainAssociation
    end
  end

  class Comments
    def self.through = Reflection.association_class({ through: :posts })
    def self.plain = Reflection.association_class({})
    def self.dependent = Reflection.association_class({ dependent: :destroy })
  end
end
