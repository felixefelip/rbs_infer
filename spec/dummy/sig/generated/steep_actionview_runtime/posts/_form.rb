class ERBPartialsPostsForm
  include ActionViewContext

  def initialize(post)
    @post = post
  end

  def render(*args)
    # render partials logic

    case args.first
    when "form"
      ERBPartialPostsForm.new(post: @post)
    end
  end

  private

  attr_reader :post
end
