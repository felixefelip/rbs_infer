# frozen_string_literal: true

require_relative "rbs_infer/version"
require_relative "rbs_infer/analyzer"
require_relative "rbs_infer/railtie" if defined?(Rails::Railtie)
