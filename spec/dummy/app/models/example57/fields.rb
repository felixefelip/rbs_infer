module Example57::Fields
  extend ActiveSupport::Concern

  included do
    def creation_window
      7
    end
  end
end
