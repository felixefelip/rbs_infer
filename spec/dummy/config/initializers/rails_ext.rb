# `lib/rails_ext` is excluded from `autoload_lib` (see config/application.rb):
# the files there reopen framework classes, so their paths don't name a
# Zeitwerk-autoloadable constant and nothing would ever load them implicitly.
#
# Most of them are static fixtures — rbs_infer reads the source, the dummy
# never runs it — and `active_storage_authorization.rb` in particular cannot
# be loaded, since the dummy doesn't require `active_storage/engine`.
#
# `module.rb` is the exception: `app/models/example39.rb` calls `Module#banana`
# in a class body, so it has to exist by the time the model is loaded.
require Rails.root.join("lib/rails_ext/module")
