# frozen_string_literal: true

# A concern method that only types under the CALLER's marker.
#
# `created_at` is nilable on a bare `Post` and non-nil on `Post::Validated`, so
# `export_stamp` carries an inferred `not_nil self.created_at` precondition — a
# contract Steep keys by the type whose SOURCE declares the method, which for a
# concern is the module: `Post::Exportable#export_stamp`.
#
# Its sole call site (`PostExporter`) hands it a `(Post & Post::Validated)`,
# which proves exactly that. The call site was never counted: a receiver type
# decomposes to `Post` and `Post::Validated` and never names the module the
# `def` lives in, so the contract matched no call site, `Enforcement` saw none,
# and the marker the caller had already proven never reached the body
# (felixefelip/steep#157). The assertion is what `steep check` says about this
# file: unenforced, the body reads `created_at` as nilable and reports
# `(TimeWithZone | nil) does not have method iso8601` — an entry in
# `steep_baseline.txt`, alongside an `enforced: false` in `steep_contracts.yml`.
# Enforced, both are gone.
#
# The guard is not decoration: a single-send body is a forward-delegate shape,
# which the delegation inliner rewrites at the call site and so never checks the
# precondition there.
module Post::Exportable
  extend ActiveSupport::Concern

  def export_stamp
    return "" if title.nil?

    created_at.iso8601
  end
end
