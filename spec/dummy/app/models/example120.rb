# example119 with a second writer of the cache: `Admin#clear` stores under
# `"Item"` a value `lookup` would not compute. `App.run` clears the catalog
# it then reads, so the read finds `:reset` and `Reader#label` answers it.
#
# Nothing here states a type.
module Example120
  class Catalog
    # Expected: () -> void
    def initialize
      @lookups = {}
    end

    # Expected: ("Item" entry) -> :reset
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
    # Expected: (Example120::Catalog catalog) -> void
    def initialize(catalog)
      @catalog = catalog
    end

    # Expected: () -> :reset
    def clear = @catalog.reset("Item")
  end

  class Reader
    # Expected: (Example120::Catalog catalog) -> void
    def initialize(catalog)
      @catalog = catalog
    end

    # Expected: () -> :reset
    def label = @catalog.lookup("Item")
  end

  class App
    # Expected: () -> :reset
    def self.run
      catalog = Catalog.new
      Admin.new(catalog).clear
      Reader.new(catalog).label
    end
  end
end
