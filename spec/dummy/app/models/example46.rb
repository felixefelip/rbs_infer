class Example46
  module Baz
    BananaWritten = Module.new

    const_set(:BananaDynamic, Module.new)
  end

  class Bar
    def written
      Example46::Baz::BananaWritten
    end

    def dynamic
      Example46::Baz::BananaDynamic
    end
  end
end
