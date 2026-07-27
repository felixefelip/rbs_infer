# frozen_string_literal: true

module RbsInfer::Project
  # Registry of plugins that answer "which class does this FILE belong to?", for sources
  # whose class identity is not written in them.
  #
  # A `.rb` file names its class (`class Foo`), so the reverse index finds it by reading
  # the text. An ERB template does not: `app/views/posts/edit.html.erb` is the body of
  # `ERBPostsEdit`, but nothing in the file says so — the mapping is a convention of
  # whatever framework owns the directory layout. Without it a template is read, parsed and
  # then never selected as a caller of anything, so the calls it makes are invisible.
  #
  # The core knows no convention: extensions register at require time, and the contract is
  # one method.
  #
  #   owner.owner_class(path) #=> String (fully-qualified class) | nil (not mine)
  #
  # Resolvers must be cheap on the no-op path (gate on the extension or a path fragment
  # before doing real work) — this is asked once per file while indexing.
  module SourceOwners
    @owners = []

    module_function

    def register(owner)
      @owners << owner unless @owners.include?(owner)
      owner
    end

    def unregister(owner)
      @owners.delete(owner)
    end

    def owners
      @owners.dup
    end

    # The first resolver to claim the file wins, so a more specific extension can be
    # registered ahead of a general one. Returns nil when none claims it.
    def owner_class(path)
      @owners.each do |owner|
        name = owner.owner_class(path)
        return name if name
      end
      nil
    end
  end
end
