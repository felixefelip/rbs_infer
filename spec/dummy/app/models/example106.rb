# frozen_string_literal: true

# A visitor reached through the node it visits, as Prism's are: `Leaf#accept`
# calls back whichever visitor it was handed, so the visitor's own `visit_leaf`
# has no call site naming its class. `Example106Counter` is handed to `accept`
# directly; `Example106Printer` through the inherited `visit`, which passes
# `self`. A reader knows both `visit_leaf`s receive a `Leaf`.
class Example106
  class Visitor
    def visit(node)
      node.accept(self)
    end

    def visit_leaf(leaf)
      leaf
    end
  end

  class Leaf
    def accept(visitor)
      visitor.visit_leaf(self)
    end

    def weight
      1
    end
  end
end
