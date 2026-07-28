# frozen_string_literal: true

# Fixture for felixefelip/rbs_infer#19: the type of `attribute :user` is
# inferred from assignment call-sites in other files
# (`Current.user = @post.user` in PostsController#publish and
# `Current.with(user: ...)` in ProfileFormatterJob), unlocking the type
# of the derived method `self.author_full_name`.
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :author_name, :account, :viewer_name

  # Rails-guides pattern: accessor override calling `super` and deriving
  # another attribute. The expander skips generating this accessor and
  # desugars the `super` into the ivar write; the generated RBS declares
  # the generated accessor in an included GeneratedAttributeMethods
  # module (mirroring Rails' runtime) so `super` resolves under strict.
  def user=(value)
    super(value)
    self.author_name = value&.full_name

    # Same transitive establishment as `author_name`, in the shape a real app writes it:
    # guarded by `unless value.nil?` instead of `&.`, and reading an attribute that is
    # nilable on a plain `User` but PROVEN on `User::Validated` (rbs_rails emits both).
    # The param is `(User & User::Validated)?`, so answering `name` from the first member
    # of the intersection alone loses the marker's stronger type.
    unless value.nil?
      self.viewer_name = value.name
    end
  end

  # `&.` because the attribute is honestly nilable (per-request reset);
  # inference propagates the safe-nav nil → `String?`.
  def self.author_full_name
    user&.full_name
  end
end
