class Example55
  class Bar
    include Example55::Baz

    def self.call_age
      age + 10
    end
  end
end
