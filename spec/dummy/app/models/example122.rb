# example120 with the reads and the writes the other way around: `App.run`
# reads the catalog before it clears it. The read finds the cache empty, so
# `lookup` computes `"Catalog::Item"`; the `:reset` stored after it is never
# read.
#
# Nothing here states a type.
module Example122
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

    # Expected: ("Item" entry) -> :reset
    def reset(entry)
      @lookups[entry] = :reset
    end
  end

  class Admin
    # Expected: (Example122::Catalog catalog) -> void
    def initialize(catalog)
      @catalog = catalog
    end

    # Expected: () -> :reset
    def clear = @catalog.reset("Item")
  end

  class Reader
    # Expected: (Example122::Catalog catalog) -> void
    def initialize(catalog)
      @catalog = catalog
    end

    # Expected: () -> "Catalog::Item"
    def label = @catalog.lookup("Item")
  end

  class App
    # Expected: () -> "Catalog::Item"
    def self.run
      catalog = Catalog.new
      label = Reader.new(catalog).label
      Admin.new(catalog).clear
      label
    end
  end
end
