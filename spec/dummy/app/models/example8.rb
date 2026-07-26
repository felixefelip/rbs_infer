class Example8
  def run_name
    @name = 'John Doe'
    show(:name)
  end

  def run_age
    @value = 42
    show(:age)
  end

  def show(which)
    case which
    when :name
      @name.upcase # => "JOHN DOE" (:name partition)
    when :age
      @value.abs   # => 42         (:age partition)
    end
  end
end
