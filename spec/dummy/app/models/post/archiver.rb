# frozen_string_literal: true

# A namespaced service object, the shape Rails apps write it in: the class lives
# under the model's namespace (`app/models/post/archiver.rb`) and the model calls
# it by its BARE name, because Ruby resolves a constant from the enclosing
# namespace outward (felixefelip/rbs_infer#129).
class Post
  class Archiver
    def initialize(post)
      @post = post
    end

    # Mirrors the real shape this was found in: the service reaches back through
    # the model into an association, so the return type is the owner-specific
    # collection proxy — a type that only exists because the association was itself
    # resolved from the owner's namespace (felixefelip/rbs_infer#128).
    def call
      @post.comments.each(&:touch)
    end

    def self.run(post)
      new(post).call
    end
  end
end
