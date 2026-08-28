module Example55::Baz
  extend Example55::Foo

  banana_class_method do
    def age
      31
    end
  end
end

module Example55::Baz::BananaMethods
  # @type instance: singleton(::Example55::Bar) & ::Example55::Baz::BananaMethods
  def age
    31
  end
end
