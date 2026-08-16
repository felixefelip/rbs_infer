class Module
  def banana(*modules)
    raise ArgumentError, "wrong number of arguments (given 0, expected 1+)" if modules.empty?

    modules.reverse_each do |mod|
      mod.send(:bananed, self)
    end

    self
  end

  private

  def bananed
  end
end
