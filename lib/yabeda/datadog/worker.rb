# frozen_string_literal: true

require "yabeda/datadog/worker/send"
require "yabeda/datadog/worker/register"
require "yabeda/datadog/queue_full_behavior"

module Yabeda
  module Datadog
    # = Perform actions async
    class Worker
      DROP_WARNING_INTERVAL = 1000

      def self.start(config)
        queue_size = config.queue_size
        num_threads = config.num_threads
        queue_full_behavior = QueueFullBehavior.parse(config.queue_full_behavior)
        Logging.instance.info(
          "start worker; queue size: #{queue_size}; threads #{num_threads}; queue full: #{queue_full_behavior}",
        )

        queue = SizedQueue.new(queue_size)
        instance = new(queue, queue_full_behavior: queue_full_behavior)
        instance.spawn_threads(num_threads)
        instance
      end

      attr_reader :dropped_count

      def initialize(queue, queue_full_behavior: :block)
        @queue = queue
        @threads = []
        @queue_full_behavior = QueueFullBehavior.parse(queue_full_behavior)
        @dropped_count = 0
      end

      # With queue_full_behavior :block (the default) this waits for room in the queue.
      # With :drop it never waits: when the queue is full or closed the action is discarded.
      def enqueue(action, payload)
        return queue.push([action, payload]) unless @queue_full_behavior == :drop

        begin
          queue.push([action, payload], true)
          nil
        rescue ThreadError, ClosedQueueError
          record_drop(action)
          nil
        end
      end

      def spawn_threads(num_threads)
        num_threads.times do
          threads << Thread.new do
            grouped_actions = Hash.new { |hash, key| hash[key] = [] }

            while running? || actions_left?
              batch_size = 0
              # wait for actions, blocks the current thread
              action_key, action_payload = wait_for_action
              if action_key
                grouped_actions[action_key].push(action_payload)
                batch_size += 1
              end

              # group a batch of actions
              while batch_size < Yabeda::Datadog.config.batch_size
                begin
                  action_key, action_payload = dequeue_action
                  grouped_actions[action_key].push(action_payload)
                  batch_size += 1
                rescue ThreadError
                  break # exit batch loop if we drain the queue
                end
              end

              # invoke actions in batches
              grouped_actions.each_pair do |group_key, group_payload|
                self.class.const_get(group_key, false).call(group_payload)
              end

              grouped_actions.clear
            end
          end
        end

        true
      end

      def spawned_threads_count
        threads.size
      end

      def stop
        Logging.instance.info("stop worker")
        queue.close
        threads.each(&:exit)
        threads.clear
        true
      end

      private

      attr_reader :queue, :threads, :logger

      def record_drop(action)
        @dropped_count += 1
        return unless @dropped_count == 1 || (@dropped_count % DROP_WARNING_INTERVAL).zero?

        Logging.instance.warn(
          "queue is full or closed; dropped #{action} (#{@dropped_count} dropped so far, queue_full_behavior: drop)",
        )
      end

      def actions_left?
        !queue.empty?
      end

      def no_acitons?
        queue.empty?
      end

      def dequeue_action
        queue.pop(true)
      end

      def wait_for_action
        queue.pop(false)
      end

      def running?
        !queue.closed?
      end
    end
  end
end
