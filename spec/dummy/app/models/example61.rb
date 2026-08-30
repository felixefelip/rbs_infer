# `self.class.<class method>(arg)` as a CALL SITE — the shape a model reaches
# its own class methods with, and the one receiver whose identity is in no
# signature: RBS declares `Kernel#class` as `() -> Class`, so resolving the
# chain through the declaration answered `Class`, which names no target. The
# call site was invisible, and `normalize`'s parameter was typed by the OTHER
# call site alone — the `String` of `Example61Caller`, not the union a reader
# sees (felixefelip/rbs_infer#296).
#
# Ruby's answer is the receiver's own singleton, and so is the checker's: Steep
# rewrites this very method per receiver type while building an object's shape
# (`Interface::Builder#replace_kernel_class`).
class Example61
  def self.normalize(key)
    key.to_s
  end

  def normalized_key
    self.class.normalize(:indexed_by)
  end
end
