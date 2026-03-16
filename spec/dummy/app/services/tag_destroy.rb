# Example with a instance variable wifh attr_reader

class TagDestroy
  attr_reader :tag

	def initialize(tag_id)
		@tag = Tag.find(tag_id)
	end

	def call
		tag.destroy
	end
end
