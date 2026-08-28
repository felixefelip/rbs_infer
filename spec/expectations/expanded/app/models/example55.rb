class Example55
  class Bar
    include Example55::Baz

    def self.call_age
      age + 10
    end
  end
end

class Example55::Bar
  extend Example55::Baz::BananaMethods
end
