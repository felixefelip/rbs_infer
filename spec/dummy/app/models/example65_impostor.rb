# Same forward name (`dispatch`), unrelated hierarchy, arguments that resemble
# nothing else here. What it guards: a filter that stopped proving WHICH class
# the receiver reaches would cross these types into `Example65Greeter#handle`,
# and every one of those snapshots would move.
class Example65Impostor < Example65::Rival
  def handle(flag, mode:)
    flag ? mode : nil
  end
end
