# Active Support's own `class_attribute`, read from the installed gem
# (felixefelip/rbs_infer#540). example108 copied the store it writes to; here
# the macro itself is called, and the reader it defines is the one
# `Options.plural_labels` calls.
#
# The reader is written by `class_eval` on a string the macro builds, and
# reads a store written by `define_method`. With both read, the call keeps the
# memo `Dial` holds: `define_option_reader :size` builds
# `Dial::GeneratedOptionReaders` and defines `size` in it.
#
# Nothing here states a type.
module Example110
  class Options
    class_attribute :plural_labels, instance_writer: false, default: true

    def self.generated_option_readers
      @generated_option_readers ||= begin
        mod = const_set(:GeneratedOptionReaders, Module.new)
        include mod
        mod
      end
    end

    def self.define_option_reader(name)
      plural_labels
      generated_option_readers.class_eval "def #{name}; 1; end"
    end
  end

  class Dial < Options
    define_option_reader :size
  end
end
