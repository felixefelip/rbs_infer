class SingletonIvarProbe
  # Written while the class body runs (`self` is the class), so `@config` is a
  # class-instance variable that IS definitely initialized → non-nil.
  @config = "default"

  # `@config` reassigned in a singleton method: same class-instance slot, so it
  # stays `self.@config` and the class-body init above keeps it non-nilable.
  def self.configure
    @config = "custom"
  end

  # `@singleton_ivar` is only ever written here, in a singleton method, with no
  # class-body initializer → `self.@singleton_ivar: String?`.
  def self.build
    @singleton_ivar = "classe"
  end

  class << self
    # `self` inside a `class << self` method is also the class, so `@label` is a
    # class-instance variable too → `self.@label: String?`.
    def label
      @label = "singleton"
    end
  end

  # A plain instance variable, definitely initialized in `initialize` → `String`.
  def initialize
    @instance_ivar = "instancia"
  end
end
