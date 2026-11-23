# example117 with the cache on an instance, filled in `initialize`.
#
# Only `lookup` writes `@lookups`, and what it stores under a key is what it
# computes again for that key. So a hit answers what a miss does:
# `Reader.label` is `"Catalog::Item"`.
#
# Nothing here states a type.
module Example119
  class Catalog
    # Expected: () -> void
    def initialize
      @lookups = {}
    end

    # Expected: ("Item" entry) -> "Catalog::Item"
    def lookup(entry)
      found = @lookups[entry]
      return found if found

      value = "Catalog::#{entry}"
      @lookups[entry] = value
      value
    end
  end

  class Reader
    # Expected: () -> "Catalog::Item"
    def self.label = Catalog.new.lookup("Item")
  end
end
