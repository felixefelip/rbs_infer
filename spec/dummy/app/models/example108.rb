# Active Support 8.0's `ClassAttribute`, copied with the namespace renamed: the
# store `class_attribute` writes for each attribute. `redefine` defines a
# reader and a writer on the class's singleton class with `define_method`,
# from blocks that close over `value` — felixefelip/steep#431.
#
# `Settings.plural_names` reads that store before a reader is defined with
# `class_eval`, so the memo `Settings` holds has to survive the call:
# `define_setting_reader :size` builds `Settings::GeneratedReaders` and defines `size`
# in it.
#
# The writer block hands its own `self` to `redefine`; at run time that is the
# class the writer is called on, but it is typed where the block is written.
#
# Nothing here states a type.
module Example108
  module ClassAttribute
    class << self
      def redefine(owner, name, namespaced_name, value)
        if owner.singleton_class?
          if owner.attached_object.is_a?(Module)
            redefine_method(owner, namespaced_name, private: true) { value }
          else
            redefine_method(owner, name) { value }
          end
        end

        redefine_method(owner.singleton_class, namespaced_name, private: true) { value }

        redefine_method(owner.singleton_class, "#{namespaced_name}=", private: true) do |new_value|
          if owner.equal?(self)
            value = new_value
          else
            ::Example108::ClassAttribute.redefine(self, name, namespaced_name, new_value)
          end
        end
      end

      def redefine_method(owner, name, private: false, &block)
        owner.silence_redefinition_of_method(name)
        owner.define_method(name, &block)
        owner.send(:private, name) if private
      end
    end
  end

  class Settings
    def self.plural_names = __class_attr_plural_names
    ClassAttribute.redefine(self, :plural_names, :__class_attr_plural_names, true)

    def self.generated_readers
      @generated_readers ||= begin
        mod = const_set(:GeneratedReaders, Module.new)
        include mod
        mod
      end
    end

    def self.define_setting_reader(name)
      plural_names
      generated_readers.class_eval "def #{name}; 1; end"
    end
  end

  class Gauge < Settings
    define_setting_reader :size
  end
end
