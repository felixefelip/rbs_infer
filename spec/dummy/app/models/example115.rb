# A hash built with a default block and read by a key nothing stored: the
# read runs the block with the key, so `missing_label` is "missing". Core
# declares the block's key `::Hash::_Key`, so `key.to_s` is still reported.
class Example115
  def label_for(key)
    labels = Hash.new { |_labels, missing| missing.to_s }
    labels[key]
  end
end

class Example115Caller
  def missing_label = Example115.new.label_for(:missing)
end
