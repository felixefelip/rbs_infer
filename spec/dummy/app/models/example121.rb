# example118 with the reads and the writes the other way around: `App.run`
# reads before it clears. The read finds the cache empty, so `lookup`
# computes `"Catalog::Item"`; the `:reset` stored after it is never read.
#
# Nothing here states a type.
module Example121
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

    # Expected: ("Item" entry) -> :reset
    def self.reset(entry)
      @lookups[entry] = :reset
    end
  end

  class Admin
    # Expected: () -> :reset
    def self.clear = Catalog.reset("Item")
  end

  class Reader
    # Expected: () -> "Catalog::Item"
    def self.label = Catalog.lookup("Item")
  end

  class App
    # Expected: () -> "Catalog::Item"
    def self.run
      label = Reader.label
      Admin.clear
      label
    end
  end
end
