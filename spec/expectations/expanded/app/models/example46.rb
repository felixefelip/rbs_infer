class Example46
  module Baz
    module BananaWritten
    end

    module BananaDynamic
    end
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
