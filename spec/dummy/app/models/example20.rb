# Example19, with the ONE change that is left between here and the real chain:
# WHERE the call carrying the block sits.
#
# Example19 closes because the block call is the method's value, and the rule
# that turns "the block established X" into a fact about the method that passed
# it reads exactly that (`collect_block_call_establishments`):
#
#     value = returned_value(body)
#     return [] unless value&.type == :block
#
# `returned_value` unwraps one `if`, and only a one-armed one. Fizzy nests two,
# and the inner one has an `else`:
#
#     def authenticate_by_bearer_token
#       if request.authorization.to_s.include?("Bearer")
#         if bearer_token_authenticatable_request?
#           authenticate_or_request_with_http_token do |token|
#             Current.identity = identity if identity = Identity.find_by_...
#           end
#         else
#           request_http_token_authentication          # halts
#         end
#       end
#     end
#
# Refusing an `else` is right in general — with one, the block may never run, so
# the fact does not hold unconditionally. But this `else` HALTS, which is what
# makes the fact sound on every exit that returns: either the block ran and
# answered, or nothing returned at all. That is the shape felixefelip/steep#121
# already models for a constant WRITE — a clause whose alternative halts — so
# the fact should come out halt-gated and compose with what exists, rather than
# needing new machinery.
#
# Everything else is Example19's, deliberately: the halt still lands on an
# argument (proven by felixefelip/steep#127), the block still crosses the object
# boundary, `Registry.user` is still written inside the block. If `show` stops
# being an error, the nesting is the only thing that changed.
#
# Until then, `show` is a type error. That is the point of the fixture.
class Example20
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

  # The one difference from Example19. The block call is two conditionals deep,
  # and the inner alternative is the halt.
  def from_token
    if bearer_request?
      if json_request?
        with_token do |token|
          if user = lookup(token)
            Registry.user = user
          end
        end
      else
        refuse
      end
    end
  end

  def with_token(&block)
    fetch_token(&block) || refuse
  end

  def fetch_token(&block)
    token = token_value

    unless token.empty?
      block.call(token)
    end
  end

  def refuse
    Responder.deny(self, "denied")
  end

  def lookup(token)
    User.new(name: "token") if token.start_with?("t")
  end

  def bearer_request?
    token_value.start_with?("t")
  end

  def json_request?
    ENV.fetch("EXAMPLE20_FORMAT", "json") == "json"
  end

  def token_value
    ENV.fetch("EXAMPLE20_TOKEN", "")
  end
end
