class Example14
  class User
    attr_reader :name

    def initialize(name:)
      @name = name
    end
  end

  def run
    verify

    return if @halted # when @halted is false @user is not nil

    "Hi, #{@user.name.upcase}!"
  end

  private

  def halt
    @halted = true
  end

  def verify
    set_user || halt
  end

  def set_user
    @user = User.new(name: "Joe")
  end
end
