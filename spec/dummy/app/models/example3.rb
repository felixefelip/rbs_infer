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
			@user = value

			self.name = value.name
		end
	end

	def self.run
		user = User.new(name: 'John Doe')

		Foo.user = user

		Foo.name.upcase # => "JOHN DOE"
	end
end
