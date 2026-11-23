# example118 and example121 together: `App.run` reads, clears, then reads
# again. The first read finds the cache empty and computes
# `"Catalog::Item"`; the second finds the `:reset` stored in between. Each
# call of `lookup` answers what the cache holds at that point.
#
# Nothing here states a type.
module Example123
  class Catalog
    @lookups = {}

    # Expected: ("Item" entry) -> ("Catalog::Item" | :reset)
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
    # Expected: () -> ("Catalog::Item" | :reset)
    def self.label = Catalog.lookup("Item")
  end

  class App
    # Expected: () -> ["Catalog::Item", :reset]
    def self.run
      before = Reader.label
      Admin.clear
      after = Reader.label
      [before, after]
    end
  end
end
