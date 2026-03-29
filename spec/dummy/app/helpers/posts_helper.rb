# frozen_string_literal: true

module PostsHelper
  def post_status_badge(post)
    css_class = case post.status.to_s
                when "published" then "bg-success"
                when "archived" then "bg-secondary"
                else "bg-warning"
                end

    content_tag(:span, post.status.to_s.capitalize, class: "badge #{css_class}")
  end

  def post_summary(post, length = 150)
    content_tag(:p, post.summary(length), class: "text-muted")
  end
end
