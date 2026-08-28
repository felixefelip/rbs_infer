# A guard the checker has already refuted.
#
# `has_nil_return?` used to be a syntactic walk: any bare `return` in the body
# widened the method's return type, however the branch it sits in was typed. So
# a guard written against a value that is already non-nil — the shape every
# `before_action`-established reader has — made a method that never returns nil
# come out `T?`, and every fact downstream of that type went with it.
#
# Steep decides reachability while typing the `if` and reports the dead clause
# as `UnreachableBranch`. These are the spellings it covers.
#
# Three diagnostics stay in the steep baseline and belong there: having declared
# the branch unreachable, Steep still checks its `return` against the declared
# return type and reports `nil` as a mismatch. Same asymmetry, other side of the
# fence — the checker knows the code cannot run and reports it anyway. Filed on
# the fork; the fix erases the three entries, here and in posts_controller.rb.
class Example56
  class Reader
    def name
      "farm"
    end

    def maybe_name
      [nil, "farm"].sample
    end

    # Dead: `name` is non-nil, so `name.nil?` is statically false.
    def label
      return if name.nil?

      name.upcase
    end

    # Dead, positive spelling.
    def shout
      return unless name

      name.upcase
    end

    # LIVE, and the control for the fix: `maybe_name` really can be nil, so the
    # guard really can return and `String?` is the honest answer.
    def maybe_label
      return if maybe_name.nil?

      "loud"
    end
  end

  def self.call
    Reader.new.label.length
  end
end
