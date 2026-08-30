module Example58::Defaults
  extend ActiveSupport::Concern

  class_methods do
    def default_values
      { indexed_by: "all", sorted_by: "latest" }
    end
  end

  def default_indexed_by
    self.class.default_values[:indexed_by]
  end
end
