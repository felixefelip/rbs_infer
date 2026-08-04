# Example18, with the ONE change that keeps the real Rails chain open: the halt
# happens on an object passed as an ARGUMENT.
#
# Example18 closes end to end because `deny` writes `@halted` on its own `self`.
# Rails does not do that. `request_http_token_authentication` hands `self` to a
# module function, and that function renders on the controller it received:
#
#   def request_http_token_authentication(realm = "Application", message = nil)
#     Token.authentication_request(self, realm, message)     # <- passes self
#   end
#
#   def authentication_request(controller, realm, message = nil)   # self = the Token module
#     controller.__send__ :render, plain: message, status: :unauthorized
#   end
#
# `Responder.deny` below is that function in miniature. The halt is real and it
# is unconditional — but it lands on `host`, a parameter, while the method's own
# `self` is the `Responder` module. `always_halting_ivar` reads the ivars a
# method refines on ITS self, so nothing here proves the tail of a `||` halts,
# and the whole chain stops (felixefelip/steep#126).
#
# The contrast to keep in mind is `fetch_token`: the block's answer crosses the
# very same object boundary without trouble, because a RETURN VALUE travels back
# through a call whoever the receiver was. A side effect does not — which object
# received it is the whole question.
#
# Deliberately NOT reproduced here: Rails reaches `render` through
# `__send__ :render`, which Steep does not resolve (it types as
# `::BasicObject#__send__`). That is a second, independent obstacle, measured in
# #126, and mixing it in would leave the fixture proving two things at once. The
# Basic and Digest variants of the same Rails file write the 401 with plain
# `controller.status = 401`, no `__send__` anywhere, and they would be equally
# stuck — which is what makes the parameter, not the `__send__`, the subject.
#
# `halt` is public for the same reason `render` is: something outside the object
# calls it.
#
# felixefelip/steep#126 landed and `show` type-checks: the callee records the
# calls it makes on each parameter, the caller records where it handed `self`
# over, and together they prove a halt neither frame states alone. The
# `__send__` obstacle above was closed separately (#160), by desugaring the
# dynamic send in the transcription.
class Example19
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

  # The framework's own module, acting on the host it was handed — the shape of
  # `ActionController::HttpAuthentication::Token`.
  module Responder
    def self.deny(host, message)
      host.record(message)
      host.halt
    end
  end

  def show
    "Hi, #{Registry.user.name.upcase}!"
  end

  def call
    authenticate

    return if @halted

    show
  end

  # Public because `Responder.deny` calls it from outside.
  def halt
    @halted = true
  end

  def record(message)
    @message = message
  end

  private

  def authenticate
    from_token || refuse
  end

  # The establishment still happens inside a block, exactly as in Example18.
  def from_token
    with_token do |token|
      if user = lookup(token)
        Registry.user = user
      end
    end
  end

  # And the framework still answers with the block or gives up — but giving up
  # now goes through the argument, and that is what cannot be proven.
  def with_token(&block)
    fetch_token(&block) || refuse
  end

  def fetch_token(&block)
    token = token_value

    unless token.empty?
      block.call(token)
    end
  end

  # The frame that passes `self`. The argument is written right here, on the
  # line — which is why the check #126 proposes is syntactic rather than an
  # alias analysis.
  def refuse
    Responder.deny(self, "denied")
  end

  def lookup(token)
    User.new(name: "token") if token.start_with?("t")
  end

  def token_value
    ENV.fetch("EXAMPLE19_TOKEN", "")
  end
end
