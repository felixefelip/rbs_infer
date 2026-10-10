# frozen_string_literal: true

require "spec_helper"
require "rbs_infer"

RSpec.describe RbsInfer::Inference::IvarTypeInferrer do
  describe "#collect_prism_initialized_ivars" do
    def resolver_for(target_class)
      described_class.new(
        target_class: target_class, method_type_resolver: nil, constant_resolver: nil,
        instance_types: [], steep_bridge: nil
      )
    end

    # A sibling class's `initialize` must not make the target's same-named ivar
    # look initialized — otherwise the definite-init `?` is wrongly skipped
    # (felixefelip/rbs_infer#71, cross-class pooling of #38/#69).
    it "scopes to the target class, ignoring a sibling's initialize" do
      tree = Prism.parse(<<~RUBY).value
        class Outer
          class User
            def initialize(name:)
              @name = name
            end
          end

          class Foo
            def set_name(v)
              @name = v
            end
          end
        end
      RUBY

      # Foo writes @name only outside initialize → NOT definitely initialized.
      expect(resolver_for("Outer::Foo").collect_prism_initialized_ivars(tree)).not_to include("name")
      # User writes @name in initialize → definitely initialized.
      expect(resolver_for("Outer::User").collect_prism_initialized_ivars(tree)).to include("name")
    end

    # An ivar written in a method that `initialize` invokes on self is
    # definitely initialized (the constructor always runs it) — a human reads
    # it as non-nil, so the definite-init `?` must be skipped
    # (felixefelip/rbs_infer#71: TagDestroy#user set in atribui_user).
    it "reaches ivars set in a method invoked (transitively) from initialize" do
      tree = Prism.parse(<<~RUBY).value
        class Svc
          def initialize(id)
            @posts = []
            assign_user(id)
          end

          def assign_user(id)
            @user = User.find(id)
            build_profile
          end

          def build_profile
            @profile = Profile.new
          end

          def lazy_xml
            @xml = parse
          end
        end
      RUBY

      init = resolver_for("Svc").collect_prism_initialized_ivars(tree)
      # Direct + one hop (assign_user) + two hops (build_profile).
      expect(init).to include("posts", "user", "profile")
      # @xml is set only in lazy_xml, never reached from initialize → nilable.
      expect(init).not_to include("xml")
    end
  end
end
