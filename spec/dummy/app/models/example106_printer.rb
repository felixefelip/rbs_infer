# frozen_string_literal: true

class Example106Printer < Example106::Visitor
  def visit_leaf(leaf)
    "leaf of weight #{leaf.weight}"
  end
end
