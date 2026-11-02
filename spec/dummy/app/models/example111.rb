# A class reopened as Ruby writes it, `< Enumerator`, while core RBS declares it
# generic, `Enumerator::Lazy[out E, out R = void] < Enumerator[E, R]`. The
# generated declaration names the declared superclass: `Enumerator[untyped,
# untyped]` would be a second, different one, which takes down the whole
# environment.
class Example111
  def self.second_of(list) = list.lazy.example111_second
end

class Enumerator::Lazy < Enumerator
  def example111_second = drop(1).first
end
