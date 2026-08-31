# frozen_string_literal: true

# The call site that discharges `Post::Exportable#export_stamp`'s precondition.
# `find_each` yields `(Post & Post::Validated)`, and that marker types
# `created_at` non-nil — the whole proof, written where a reader sees it.
class PostExporter
  def call
    Post.all.find_each do |post|
      post.export_stamp
    end
  end
end
