class Example4
  class Foo
    def self.name
		  @name
    end

    def self.name=(value)
	    @name= value
    end
  end

  class Bar
	  def foo_name
		  Foo.name
	  end
  end

  def run
    Foo.name.upcase # error not method

		Foo.name = 'John Doe'
    Foo.name.upcase # => "JOHN DOE"

    Bar.new.foo_name.upcase # => "JOHN DOE"
  end
end
