# A class memo handed back behind a fiber-local, the shape of I18n's
# `fallbacks`. Nothing calls `settings=`, so nothing writes the key: the
# current thread's locals stay unset, the read answers nil, and the reader
# hands back the memo, so `name` is `:default`.
#
# Still `untyped`, for three reasons: the RBS declares no `@@settings`
# (felixefelip/rbs_infer#590), `@x ||= allocate` declares `Thread.current`'s
# memo as `nil` (felixefelip/rbs_infer#591), and the write in `settings=`
# still counts though nothing calls it (felixefelip/steep#570).
class Example113
  @@settings = nil

  class << self
    def settings
      @@settings ||= Example113Settings.new
      Thread.current[:example113_settings] || @@settings
    end

    def settings=(settings)
      @@settings = settings
      Thread.current[:example113_settings] = @@settings
    end
  end

  def name = Example113.settings.name
end

class Example113Settings
  def initialize
    @name = :default
  end

  attr_reader :name
end
