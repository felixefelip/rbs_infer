# A concern's CLASS method — the `class_methods do` block, extended into the
# host — called on the host's constant from another file.
#
# `Example59Labels` writes `Example59.human_name(index)`. That receiver spelling
# is ambiguous by design: `resolve_receiver_type` returns the bare `"Example59"`
# both for a constant receiver (this, a singleton call) and for a value of type
# `Example59` (an instance call), and the matchers are supposed to keep both
# kinds eligible. Only two of the three did — the ancestry matcher asked the
# RBS for the method's owner on the INSTANCE side alone, where `human_name` is
# not, so nothing matched and the parameter stayed `untyped` even though the
# call site says `String` (felixefelip/rbs_infer#293). Every
# `ActiveSupport::Concern` in a project has this shape.
module Example59::Naming
  extend ActiveSupport::Concern

  class_methods do
    def human_name(index)
      index.upcase
    end
  end
end

module Example59::Naming::ClassMethods
  # @type instance: singleton(::Example59) & ::Example59::Naming::ClassMethods
  def human_name(index)
    index.upcase
  end
end
