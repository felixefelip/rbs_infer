class Example3
	class User
		attr_reader :name

		def initialize(name:)
			@name = name
		end
	end

	class Foo
    module GeneratedAttributes
		  attr_accessor :user, :name
		  attr_writer :foo_instance
    end

	  include GeneratedAttributes

    def self.foo_instance
		  @foo_instance ||= Foo.new
    end

    def self.user
		  foo_instance.user
    end

		def self.user=(value)
			foo_instance.user = value
		end

		def self.name
		  foo_instance.name
		end

		def self.name=(value)
			foo_instance.name = value
		end

		def user=(value)
			super(value)

			self.name = value&.name
		end
	end

	def self.run
		user = User.new(name: 'John Doe')

		Foo.user = user

		Foo.user.name.upcase
		Foo.foo_instance.user.name.upcase
		Foo.foo_instance.name.upcase
		Foo.name.upcase # => "JOHN DOE"

		Foo.user = nil

		# Foo.user.name.upcase # error not method
		# Foo.foo_instance.user.name.upcase # error not method
		# Foo.foo_instance.name.upcase # error not method
		# Foo.name.upcase # error not method
	end
end
