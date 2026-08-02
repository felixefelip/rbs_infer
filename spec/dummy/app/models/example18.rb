# The authentication chain again, with the one thing Example16 leaves out: the
# establishment happens INSIDE A BLOCK.
#
# Example16 is this same shape written with direct calls, and it closes end to
# end (felixefelip/steep#121, #122). Example17 has blocks, but only as a
# question about signatures — no fact ever crosses one. Nothing until now had
# both, which is exactly the gap felixefelip/rbs_infer#144 is about: an app
# writes
#
#   authenticate_or_request_with_http_token do |token|
#     Current.identity = identity if identity = Identity.find_by_token(token)
#   end
#
# and what makes the fact true lives in the gem, three methods away.
#
# So `with_token` and `fetch_token` below are that gem, in miniature. They are
# not a model of Rails — the real source is transcribed elsewhere (#146). They
# are here because the real one halts by rendering on a controller it received
# as an ARGUMENT, and proving that is an aliasing question with nothing to do
# with blocks. `deny` halts on its own `self`, so the block boundary is the only
# unsolved thing in this file.
#
# What each link needs:
#
#   1. `fetch_token` — its value IS the block's call (#123, stage 2a).
#   2. `with_token`  — answers with the block or halts, so the fact is gated on
#      the halt (stage 2b).
#   3. `from_token`  — the call site: a truthy answer means the block ran and
#      answered truthy, so what the BLOCK established holds. This is stage 3,
#      and it is the one that does not exist yet.
#   4. `show`        — dereferences in another method, past the halt check, so
#      the fact has to survive as an entry fact.
#
# Until 3 lands, `show` is a type error. That is the point of the fixture.
class Example18
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

  # The app level: establish, or halt. Same `|| deny` the framework uses one
  # frame down — Rails has both, and so does a real app.
  def authenticate
    from_token || deny
  end

  # THE POINT OF THE FIXTURE. The write sits inside a block handed to somebody
  # else, and nothing about this method's own body says whether it ran.
  def from_token
    with_token do |token|
      if user = lookup(token)
        Registry.user = user
      end
    end
  end

  # The framework, in miniature: answers with the block, or halts.
  def with_token(&block)
    fetch_token(&block) || deny
  end

  # Its value IS the block's value — the `unless` only adds a falsy way out.
  def fetch_token(&block)
    token = token_value

    unless token.empty?
      block.call(token)
    end
  end

  def deny
    halt
  end

  def halt
    @halted = true
  end

  # The name is a literal, as in Example16: the ONLY nilability this fixture is
  # about is `Registry.user`. Feeding the token through would make `name`
  # nilable too, and `show` would then fail for two reasons that read alike.
  def lookup(token)
    User.new(name: "token") if token.start_with?("t")
  end

  def token_value
    ENV.fetch("EXAMPLE18_TOKEN", "")
  end
end
