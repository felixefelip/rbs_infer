# frozen_string_literal: true

module RbsInfer::Project::StoredBlockReplayExpander
  # Everything a file was read as writing, in one place.
  #
  # These fourteen collections are what crosses the boundary between the three
  # phases: the lexical walk fills them, the corpus walk merges another file's
  # into them, and the resolution reads them. That boundary already existed —
  # it was a `protected attr_reader` listing them one by one and an `absorb`
  # concatenating them one by one — and this is the same interface with a name
  # (felixefelip/rbs_infer#306).
  #
  # Two of them carry a BLOCK — `literal_replays` and `stored_calls` — and they
  # can cross a file boundary only because each entry carries the source it was
  # sliced from. Without that they could not: a block is a pair of offsets, and
  # reading them against the wrong file cuts the wrong text
  # (felixefelip/rbs_infer#265).
  #
  # Held rather than copied: the arrays are handed out and mutated in place, so
  # a reader taken early keeps seeing what is appended later. That was
  # load-bearing until the phases were split — `CallGraph` used to be built
  # before the last delegations were concatenated onto the very array it had
  # been handed, and only worked because it was the same object. It no longer
  # relies on it: `resolve_shapes` finishes before any resolution starts. The
  # sharing stays because the collections are still filled in one phase and read
  # in another, but nothing now depends on a write landing after a read.
  class ShapeSet
    COLLECTIONS = %i[storages readers replay_methods inward_replays literal_replays forwards
                     stored_calls module_calls foreign_module_calls deferrals slot_inits
                     resolved_delegations resolved_inward_extends resolved_own_replays].freeze

    COLLECTIONS.each { |name| attr_reader(name) }

    def initialize
      COLLECTIONS.each { |name| instance_variable_set(:"@#{name}", []) }
    end

    # Takes on everything another file said.
    #
    # Every collection but one is a straight concatenation. `module_calls` is the
    # exception and the asymmetry is the point: another file's call sites are
    # read for ONE question — which modules it registered on a waypoint — and
    # never emitted from, because this pass rewrites one source and a call site
    # elsewhere names a target it cannot reopen. So they land in
    # `foreign_module_calls`, where nothing that emits will look
    # (felixefelip/rbs_infer#300).
    def merge(other)
      (COLLECTIONS - %i[module_calls foreign_module_calls]).each do |name|
        public_send(name).concat(other.public_send(name))
      end
      @foreign_module_calls.concat(other.module_calls)
      self
    end

    # `resolved_delegations` is REPLACED rather than appended to when a file is
    # read on another's behalf: `collect_shapes` resolves them once, against the
    # declarations of the file they were written in, and there is nothing to
    # append to yet.
    def replace(name, values)
      instance_variable_set(:"@#{name}", values)
    end
  end
end
