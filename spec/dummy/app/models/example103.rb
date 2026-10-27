# A class whose superclass is picked by the Ruby engine running it, written
# the way concurrent-ruby picks `Concurrent::Map`'s backend
# (felixefelip/rbs_infer#506):
#
#   MapImplementation = case
#                       when Concurrent.on_jruby? then JRubyMapBackend
#                       when Concurrent.on_cruby? then MriMapBackend
#                       ...
#   class Map < Collection::MapImplementation
#
# `RUBY_ENGINE` is the one fact the language runtime pseudo-code states;
# which backend `Store` extends follows from it.
#
# Nothing here states a type.
module Example103
  module Engine
    def self.cruby? = RUBY_ENGINE == "ruby"

    def self.jruby? = RUBY_ENGINE == "jruby"
  end

  class MriBackend
    def initialize
      @entries = {}
    end

    def [](key)
      @entries[key]
    end

    def []=(key, value)
      @entries[key] = value
    end
  end

  class JavaBackend
    def [](key)
      key
    end
  end

  Implementation = case
                   when Engine.jruby? then JavaBackend
                   when Engine.cruby? then MriBackend
                   end

  class Store < Implementation
  end

  class Use
    def stored
      store = Store.new
      store[:a] = :x
      store[:a]
    end
  end
end
