# frozen_string_literal: true

class Example105Caller
  def dog
    Example105Dog.new.introduce
  end

  def cat
    Example105Cat.new.introduce
  end
end
