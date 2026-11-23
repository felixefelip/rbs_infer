# A cache a class keeps in an ivar of its own, read when the app runs rather
# than while the class loads: the shape of Active Record's `compute_type`
# (felixefelip/rbs_infer#660).
#
# Only `lookup` writes `@lookups`, and what it stores under a key is what it
# computes again for that key. So a hit answers what a miss does:
# `Reader.label` is `"Catalog::Item"`.
#
# Nothing here states a type.
module Example117
  class Catalog
    @lookups = {}

    # Expected: ("Item" entry) -> "Catalog::Item"
    def self.lookup(entry)
      found = @lookups[entry]
      return found if found

      value = "Catalog::#{entry}"
      @lookups[entry] = value
      value
    end
  end

  class Reader
    # Expected: () -> "Catalog::Item"
    def self.label = Catalog.lookup("Item")
  end
end
