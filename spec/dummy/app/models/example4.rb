class Example4
  class Foo
    def self.name
      @name
    end

    def self.name=(value)
      @name = value
    end
  end

  class Bar
    def foo_name_before
      Example4::Foo.name.upcase # error not method
    end

    def foo_name
      Example4::Foo.name.upcase # => "JOHN DOE"
    end

    def foo_name_after
      Example4::Foo.name.upcase # error not method
    end
  end

  def run
    Example4::Foo.name.upcase # error not method

    Example4::Bar.new.foo_name_before # error not method

    Example4::Foo.name = 'John Doe'
    Example4::Foo.name.upcase # => "JOHN DOE"

    Example4::Bar.new.foo_name.upcase # => "JOHN DOE"

    Example4::Foo.name = nil

    Example4::Foo.name.upcase # error not method
    Example4::Bar.new.foo_name_after # error not method
  end
end
