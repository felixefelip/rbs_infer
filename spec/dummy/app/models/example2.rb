class Example2
	class User
		attr_reader :name

		def initialize(name:)
			@name = name
		end
	end

	class Foo
		attr_reader :user, :name
		attr_writer :name

		def user=(value)
			@user = value

			self.name = value.name
		end
	end

	def self.run
		user = User.new(name: 'John Doe')

		foo = Foo.new

		foo.user = user

		foo.name.upcase # => "JOHN DOE"
	end
end
