# frozen_string_literal: true

# Fixture for felixefelip/rbs_infer#19: the type of `attribute :user` is
# inferred from assignment call-sites in other files
# (`Current.user = @post.user` in PostsController#publish and
# `Current.with(user: ...)` in ProfileFormatterJob), unlocking the type
# of the derived method `self.author_full_name`.
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :author_name

  # Rails-guides pattern: accessor override calling `super` and deriving
  # another attribute. The expander skips generating this accessor and
  # desugars the `super` into the ivar write; the generated RBS declares
  # the generated accessor in an included GeneratedAttributeMethods
  # module (mirroring Rails' runtime) so `super` resolves under strict.
  def user=(value)
    super(value)
    self.author_name = value&.full_name
  end

  # `&.` because the attribute is honestly nilable (per-request reset);
  # inference propagates the safe-nav nil → `String?`.
  def self.author_full_name
    user&.full_name
  end
end
