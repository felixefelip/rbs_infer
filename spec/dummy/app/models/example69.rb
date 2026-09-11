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
      call(name: true)
    end

    # type should be literal `'delete'`
    def call_action
      call(name: false)
    end

    private

    def call(name: true) # type should be literal `'name_delete' | 'delete'`
      if name
        "#{self.name}_#{action}"
      else
        action
      end
    end
  end
end
