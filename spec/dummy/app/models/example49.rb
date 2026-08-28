class Example49
  module Baz
    def color
      "yellow"
    end
  end

  class Bar
    extend Example49::Baz

    def self.call_color
      color.upcase
    end

    def self.call_age
      age + 10
    end
  end
end

module Example49::Baz
  def age
    31
  end
end
