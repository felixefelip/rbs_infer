# rbs_infer reopens Post and points `assignments` at our proxy
class Post
  def assignments
    Post_Assignment::ActiveRecord_Associations_CollectionProxy.new(self)
  end
end

# our proxy IS a real CollectionProxy → inherits where/each/... (no blast radius);
# only construction is overridden, with the deref inlined through a non-nil local.
class Post_Assignment::ActiveRecord_Associations_CollectionProxy < Assignment::ActiveRecord_Associations_CollectionProxy
  def initialize(owner)
    @owner = owner
  end

  def create!(attrs = nil)
    record = Assignment.new
    post = @owner              # the association owner, a non-nil Post
    record.post = post
    record.owner = post.user   # contract-free deref — source-mapped to `default:`
    record
  end
end

