class Example4
	class Foo
    def self.name
		  @name
    end

		def self.name=(value)
	    @name= value
		end
	end

	def run
		Foo.name.upcase # error not method

		Foo.name = 'John Doe'
		Foo.name.upcase # => "JOHN DOE"
	end
end
