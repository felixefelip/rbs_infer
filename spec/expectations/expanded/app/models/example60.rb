# `delegate ..., to: <reader>` — the ordinary half. `stamp` takes two
# parameters, and the delegated `Example60#stamp` has to take them too.
#
# Nothing here states them: `Example60Printer#stamp` is itself typed from the
# call site below, and the delegate copies what the previous pass wrote down.
class Example60
  include Labels

  delegate :stamp, to: :example60_printer

  def example60_printer
    Example60Printer.new
  end

  def print_label
    example60_printer.stamp("tag", 2)
  end
end

class Example60
  def stamp(...);  _ = example60_printer;  _.stamp(...);rescue NoMethodError => e;  if _.nil? && e.name == :stamp;    raise ::ActiveSupport::DelegationError.nil_target(:stamp, :'example60_printer');  else;    raise;  end;end
end

class Example60
  extend ::Example60::Labels::ClassMethods
end
