# A cache an `inherited` hook sets on each subclass, the shape of Active
# Record's type-candidates cache (felixefelip/rbs_infer#392, item 8). The
# read of a key nothing stored runs the hash's default block, so `labeled`
# writes `title_label` on `Example116Child`.
class Example116
  def initialize
    @backend = Hash.new { |_hash, key| key.to_s }
  end

  def [](key) = @backend[key]
end

class Example116Base
  def self.inherited(subclass)
    super
    subclass.instance_variable_set(:@example116_labels, Example116.new)
  end

  def self.label_for(key) = @example116_labels[key]

  def self.labeled(key)
    class_eval "def #{label_for(key)}_label; :labeled; end"
  end
end

class Example116Child < Example116Base
  labeled :title
end
