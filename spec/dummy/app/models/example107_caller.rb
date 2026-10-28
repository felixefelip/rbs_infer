# frozen_string_literal: true

class Example107Caller
  def total
    shapes = [Example107::Circle.new, Example107::Square.new]
    shapes.sum { |shape| shape.area(2) }
  end

  def painted
    canvas = Example107::Canvas.new
    [
      Example107::Shape.new.paint(canvas),
      Example107::Circle.new.paint(canvas),
      Example107::Square.new.paint(canvas)
    ]
  end
end
