# The collection `Example68#latest` forwards to. Split out for one reason: it
# lets `latest` be a ONE-LINE forwarder, which is what fizzy's `last_event`
# (`card.events.order(:created_at).last`) is, and what the delegation registry
# reads as a delegate.
class Example68Store
  def entries
    [Example68Entry.new("opened", 1), Example68Entry.new(nil, 0)]
  end

  def newest
    return nil if entries.empty?

    entries.last
  end
end
