# String literal
module Example69
  class Foo
    def name
      "name"
    end

    def action
      "delete"
    end

    # type should be literal `'name_delete'`
    def call_name_action
      call(flag_name: true)
    end

    # type should be literal `'delete'`
    def call_action
      call(flag_name: false)
    end

    # type should be literal `'name_delete'`
    def call_dynamic
      name_action_dynamic(flag_name: true)
    end

    # type should be literal `'delete'`
    def call_dynamic_with_name
      name_action_dynamic(flag_name: false)
    end

    # type should stay `Array['name_delete' | 'delete']` — the two call sites disagree,
    # so `flag_name` is `bool` here and neither branch can be dropped
    def call_both
      [name_action_dynamic(flag_name: true), name_action_dynamic(flag_name: false)]
    end

    # type should be literal `'name_delete' | 'delete'` — the call site is a literal `bool`
    def name_action_dynamic(flag_name:)
      call(flag_name: flag_name)
    end

    # type should stay `'name_delete' | 'delete'` — nothing constrains `flag_name`,
    # so neither branch can be dropped
    def call_unknown(flag_name:)
      call(flag_name: flag_name)
    end

    private

    # type should be literal `'name_delete' | 'delete'`
    def call(flag_name: false)
      if flag_name
        "#{name}_#{action}"
      else
        action
      end
    end
  end
end
