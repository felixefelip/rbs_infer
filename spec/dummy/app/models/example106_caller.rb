# frozen_string_literal: true

class Example106Caller
  def count
    Example106::Leaf.new.accept(Example106Counter.new)
  end

  def label
    Example106Printer.new.visit(Example106::Leaf.new)
  end
end
