# example120 with the admin kept in an array: `App.run` puts an `Admin`
# holding the catalog into `admins`, clears through the array, then reads
# the same catalog. The read finds `:reset` and `Reader#label` answers it.
#
# Nothing here states a type.
module Example125
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
    # Expected: (Example125::Catalog catalog) -> void
    def initialize(catalog)
      @catalog = catalog
    end

    # Expected: () -> :reset
    def clear = @catalog.reset("Item")
  end

  class Reader
    # Expected: (Example125::Catalog catalog) -> void
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
      admins = []
      admins << Admin.new(catalog)
      admins.each(&:clear)
      Reader.new(catalog).label
    end
  end
end
