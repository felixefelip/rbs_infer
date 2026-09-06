module Example63
  class Foo
    def build_my_block
      Foo.class_eval(&my_block)
    end

		def my_block
			proc do
				def greet
					"Hello"
				end
			end
		end
  end

	def self.run_without_block
		Foo.new.greet # NoMethodError: undefined method `greet'
	end

	def self.run_with_block
		Foo.new.build_my_block
		Foo.new.greet # works
	end
end
