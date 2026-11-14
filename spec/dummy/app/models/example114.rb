# A block handed on as an ordinary argument, the shape of concurrent-ruby's map
# backends: `initialize` never calls its block, it passes it to `set_backend`,
# which calls it with the map and the missing key. So the block takes two
# parameters, the first being the map itself.
class Example114
  def initialize(&default_proc)
    set_backend(default_proc)
    @default_proc = default_proc
  end

  def [](key)
    @backend[key]
  end

  private

  def set_backend(default_proc)
    @backend = if default_proc
                 Hash.new { |_hash, key| default_proc.call(self, key) }
               else
                 {}
               end
  end
end

class Example114Caller
  # Returns "missing": `:missing` is not in the hash, so the read runs the
  # default block. Inferred as `untyped` until a read through a hash's default
  # block folds (felixefelip/rbs_infer#623). The block's `key` is
  # `::Hash::_Key`, as core declares `Hash.new`'s block, so `key.to_s` is
  # reported until then too.
  def lookup = Example114.new { |_map, key| key.to_s }[:missing]
end
