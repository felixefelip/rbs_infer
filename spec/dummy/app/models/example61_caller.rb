# The other call site, the one that was always visible. What the snapshot
# records is that `normalize` takes BOTH: a parameter typed from one of two
# call sites reads as an answer, and it is the narrower one.
class Example61Caller
  def normalize_name
    Example61.normalize("indexed_by")
  end
end
