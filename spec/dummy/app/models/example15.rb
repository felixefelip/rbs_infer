class Example15
  class User
    attr_reader :name

    def initialize(name:)
      @name
    end
  end

  class Registry
    def self.user
      @user
    end

    def self.user=(value)
      @user = value
    end
  end

  def run
    verify

    return if @halted # when @halted is false @user is not nil

    "Hi, #{Registry.user.name.upcase}!"
  end

  private

  def halt
    @halted = true
  end

  def verify
    set_user || halt
  end

  def set_user
    Registry.user = User.new(name: "Joe")
  end
end
