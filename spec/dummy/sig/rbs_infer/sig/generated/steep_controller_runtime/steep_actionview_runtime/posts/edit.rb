class ERBPostsEdit
  include ActionViewContext

  def initialize(post_ivar)
    @post = post_ivar
  end

  def render(*args)
    # render partials logic

    case args.first
    when "form"
      ERBPartialPostsForm.new(post: @post)
    end
  end
end
