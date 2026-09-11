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

    def call_dynamic
      name_action_dynamic(flag_name: true)
    end

    def name_action_dynamic(flag_name)
      call(flag_name: flag_name)
    end

    private

    def call(flag_name: false) # type should be literal `'name_delete' | 'delete'`
      if flag_name
        "#{name}_#{action}"
      else
        action
      end
    end
  end
end
