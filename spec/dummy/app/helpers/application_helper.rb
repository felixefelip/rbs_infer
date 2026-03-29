module ApplicationHelper
  # @type self: singleton(ApplicationHelper) & singleton(ApplicationController)
	# @type instance: ApplicationHelper & ApplicationController
  def test_helper_method
		"I'm a helper method"
  end

	def user_name_created_at
		User.first!.created_at
	end

	def user_label_tag
    content_tag(:span, "", class: "badge rounded-pill bg-danger")
	end
end
