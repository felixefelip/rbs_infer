# frozen_string_literal: true

class Example106Counter < Example106::Visitor
  def visit_leaf(leaf)
    leaf.weight
  end
end
