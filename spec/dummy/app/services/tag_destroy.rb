# Example with a instance variable wifh attr_reader

class TagDestroy
  attr_reader :tag, :user

	def initialize(tag_id, user_id)
		@tag = Tag.find(tag_id)
    atribui_user(user_id)
	end

	def call
		tag.destroy
	end

	private

	def atribui_user(user_id)
		@user = User.find(user_id)
	end

  def user_name
		user.name
  end
end
