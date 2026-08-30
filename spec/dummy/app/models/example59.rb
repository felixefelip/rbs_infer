# The host: `human_name` reaches it through the SINGLETON ancestry — the
# `extend ::Example59::Naming::ClassMethods` the concern's expansion emits —
# which no name in the caller spells and only the RBS knows.
class Example59
  include Naming
end
