# The authentication chain, in the shape a real app writes it. Example14 and
# Example15 model a simpler version: their establisher runs unconditionally and
# always returns truthy, so the alternative is dead code and the halt check is
# decorative — the attribute is set on every path anyway. Three things differ
# here, and each is a separate piece of inference:
#
#   1. `resume` establishes on its TRUTHY exit only. The write sits inside a
#      one-armed `if`, so nothing holds on the path where there was no cookie.
#   2. `from_token` either establishes or HALTS. What proves the attribute
#      across the chain is that every other way out halted, not that some
#      operand always runs.
#   3. `show` dereferences in a DIFFERENT method, reached only past the halt
#      check, so the fact has to survive as an entry fact rather than within
#      one method's flow.
#
# Until all three are covered, `show` is a type error — that is the point of
# the fixture.
class Example16
  class User
    attr_reader :name

    def initialize(name:)
      @name = name
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

  # The action. Runs only past the halt check, and derefs what the chain left.
  def show
    "Hi, #{Registry.user.name.upcase}!"
  end

  # The runner: guard, halt check, action.
  def call
    authenticate

    return if @halted

    show
  end

  private

  # `a || b || c` where `c` always halts: on an exit that did NOT halt, `a` or
  # `b` returned truthy, and each of those established the user.
  def authenticate
    resume || from_token || deny
  end

  # Establishes on the truthy exit only.
  def resume
    if cookie?
      Registry.user = User.new(name: "cookie")
    end
  end

  # Establishes, or halts.
  def from_token
    if token?
      Registry.user = User.new(name: "token")
    else
      halt
    end
  end

  def deny
    halt
  end

  def halt
    @halted = true
  end

  def cookie?
    ENV.key?("EXAMPLE16_COOKIE")
  end

  def token?
    ENV.key?("EXAMPLE16_TOKEN")
  end
end
