class Example54
  class Bar
    include Example54::Baz

    def self.call_age
      age + 10
    end
  end
end

class Example54::Bar
  extend Example54::Baz::BananaMethods
end
