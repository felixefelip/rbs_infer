# frozen_string_literal: true

require "rubocop"

module RuboCop
  module Cop
    module Project
      # Metrics/ClassLength with a per-file ceiling. A file listed in `Ceilings`
      # may keep its largest class at the recorded size but not grow it, and when
      # that class shrinks the ceiling has to come down with it — so the record
      # never lags the code and the slack never comes back.
      #
      # Keyed by file rather than by class name because a cop reads one file at a
      # time: a class reopened in a second file is a second, smaller node, and
      # would read as the class having shrunk.
      #
      #   Project/ClassLengthCeiling:
      #     Max: 400
      #     Ceilings:
      #       lib/rbs_infer/inference/new_call_collector.rb: 740
      class ClassLengthCeiling < Metrics::ClassLength
        GREW = "Class has too many lines. [%<length>d/%<max>d]"
        SHRANK = "Largest class shrank to %<length>d lines; lower this file's ceiling in .rubocop.yml from %<max>d."
        BACK_UNDER = "No class here is over %<max>d lines any more; remove this file's ceiling from .rubocop.yml."

        def on_new_investigation
          super
          @largest = nil
        end

        def on_investigation_end
          report_stale_ceiling if ceiling && @largest
          super
        end

        private

        def check_code_length(node)
          return super unless ceiling

          length = build_code_length_calculator(node).calculate
          @largest = [length, node] if @largest.nil? || length > @largest.first
          add_offense(location(node), message: format(GREW, length: length, max: ceiling)) if length > ceiling
        end

        def report_stale_ceiling
          length, node = @largest
          if length <= max_length
            add_offense(location(node), message: format(BACK_UNDER, max: max_length))
          elsif length < ceiling
            add_offense(location(node), message: format(SHRANK, length: length, max: ceiling))
          end
        end

        def ceiling
          ceilings = cop_config.fetch("Ceilings", nil) || {}
          path = processed_source.file_path or return
          ceilings[PathUtil.smart_path(path)]
        end
      end
    end
  end
end
