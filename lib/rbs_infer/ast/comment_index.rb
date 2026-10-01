module RbsInfer::AST
  # A file's comments grouped by the line they start on.
  #
  # Annotations are looked up per `def`, a few lines above it. Scanning every
  # comment of the file for each def made the lookup quadratic, and each
  # `Location#start_line` is a binary search over the file's line offsets.
  class CommentIndex
    def initialize(comments)
      @by_line = comments.group_by { |comment| comment.location.start_line }
    end

    # Comments starting on `first..last`, in source order.
    def between(first, last)
      (first..last).flat_map { |line| @by_line.fetch(line, []) }
    end

    def on(line)
      @by_line.fetch(line, [])
    end
  end
end
