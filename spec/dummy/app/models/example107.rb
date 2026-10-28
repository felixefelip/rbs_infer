# frozen_string_literal: true

# A call made on a receiver typed as the base class, as Prism's traversal makes
# `node.accept(visitor)` on a `Prism::Node`. `Shape#paint` hands `self` to the
# canvas, and runs on a `Shape` as well as on its subclasses, so `Canvas#draw`
# receives a `Shape`, and `shape.area(5)` runs the `area` of whichever class it
# holds. A reader knows each override takes `5`, besides the `2` the caller
# passes on a receiver typed as their union.
class Example107
  class Shape
    def paint(canvas)
      canvas.draw(self)
    end

    def area(scale)
      scale
    end
  end

  class Circle < Shape
    def area(scale)
      scale * 3
    end
  end

  class Square < Shape
    def area(scale)
      scale * 4
    end
  end

  class Canvas
    def draw(shape)
      shape.area(5)
    end
  end
end
