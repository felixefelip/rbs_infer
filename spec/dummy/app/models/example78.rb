module Example78
  class Peel
    def self.short_name(index)
      index
    end

    # the method should returns `-> ":index`
    def self.extract_arg(method)
      argument = Peel.singleton_class.public_instance_method(method).parameters[0][1]

      argument
    end

    extract_arg :short_name
  end
end
