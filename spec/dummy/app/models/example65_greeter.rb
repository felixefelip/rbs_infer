# One of the two concrete handlers. In its own file, like `Example60`'s pair:
# three same-named `handle` methods in ONE file made every one of them report
# the first's return type, which would have muddied what this example is for.
class Example65Greeter < Example65::Dispatcher
  def handle(name, greeting:)
    "#{greeting}, #{name}"
  end
end
