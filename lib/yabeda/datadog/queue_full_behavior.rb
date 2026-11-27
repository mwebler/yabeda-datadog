# frozen_string_literal: true

module Yabeda
  module Datadog
    # = What Worker#enqueue does when its queue is full: :block (wait for room) or :drop (discard)
    module QueueFullBehavior
      BEHAVIORS = %i[block drop].freeze

      # Accepts :drop, "drop", "DROP" or ":drop" (values from environment variables are strings).
      def self.parse(value)
        normalized = value.to_s.strip.downcase.sub(/\A:/, "")
        return :block if normalized.empty?

        behavior = normalized.to_sym
        raise QueueFullBehaviorError, value unless BEHAVIORS.include?(behavior)

        behavior
      end
    end
  end
end
