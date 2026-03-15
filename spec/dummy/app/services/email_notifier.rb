# frozen_string_literal: true

class EmailNotifier
  attr_reader :from_address, :delivery_method

  def initialize(from_address: "noreply@example.com", delivery_method: :smtp)
    @from_address = from_address
    @delivery_method = delivery_method
  end

  def notify(user, message)
    {
      to: user.email,
      from: from_address,
      body: message,
      sent_at: Time.current
    }
  end
end
