# example117 with a second writer of the cache: `Admin.clear` stores under
# `"Item"` a value `lookup` would not compute. `App.run` clears before it
# reads, so the read finds `:reset` and `Reader.label` answers it.
#
# Nothing here states a type.
module Example118
  class Catalog
    @lookups = {}

    # Expected: ("Item" entry) -> :reset
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
    # Expected: () -> :reset
    def self.label = Catalog.lookup("Item")
  end

  class App
    # Expected: () -> :reset
    def self.run
      Admin.clear
      Reader.label
    end
  end
end
