module Example57Windowed
  extend ActiveSupport::Concern

  included do
    def window_days
      30
    end
  end
end
