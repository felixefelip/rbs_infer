# example120 and example122 together: `App.run` reads the catalog, clears
# it, then reads it again. The first read finds the cache empty and
# computes `"Catalog::Item"`; the second finds the `:reset` stored in
# between. Each call of `lookup` answers what the cache holds at that point.
#
# Nothing here states a type.
module Example124
  class Catalog
    # Expected: () -> void
    def initialize
      @lookups = {}
    end

    # Expected: ("Item" entry) -> ("Catalog::Item" | :reset)
    def lookup(entry)
      found = @lookups[entry]
      return found if found

      value = "Catalog::#{entry}"
      @lookups[entry] = value
      value
    end

    # Expected: ("Item" entry) -> :reset
    def reset(entry)
      @lookups[entry] = :reset
    end
  end

  class Admin
    # Expected: (Example124::Catalog catalog) -> void
    def initialize(catalog)
      @catalog = catalog
    end

    # Expected: () -> :reset
    def clear = @catalog.reset("Item")
  end

  class Reader
    # Expected: (Example124::Catalog catalog) -> void
    def initialize(catalog)
      @catalog = catalog
    end

    # Expected: () -> ("Catalog::Item" | :reset)
    def label = @catalog.lookup("Item")
  end

  class App
    # Expected: () -> ["Catalog::Item", :reset]
    def self.run
      catalog = Catalog.new
      reader = Reader.new(catalog)
      before = reader.label
      Admin.new(catalog).clear
      after = reader.label
      [before, after]
    end
  end
end
