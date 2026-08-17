class Example40
  module Foo
    def bazinga(*modules)
      modules.reverse_each do |mod|
        mod.send(:bazingado, self)
      end
    end

    private

    def bazingado(base=nil, &block)
      # Memoized on the extending module, not built per call: the block is kept
      # on the holder, so a fresh `Bazinga` per call stores it on an object that
      # is discarded before the replay ever asks for it.
      @_bazingado_holder ||= Example40::Bazinga.new
      @_bazingado_holder.bazingado(base, &block)
    end
  end

  class Bazinga
    def bazingado(base=nil, &block)
      if base.nil?
        @_bazingado_block = block
      else
        base.class_eval(&@_bazingado_block) if @_bazingado_block
      end
    end
  end

  class Baz
    extend Example40::Foo

    bazingado do
      def age
        31
      end
    end
  end

  class BazOther
    extend Example40::Foo

    bazingado do
      def name
        "John Doe"
      end
    end
  end

  class Bar
    extend Example40::Foo

    bazinga(Example40::Baz, Example40::BazOther)

    def call_age
      age + 10
    end
  end
end

class Example40::Bar
  def age
    31
  end
end

class Example40::Bar
  def name
    "John Doe"
  end
end
