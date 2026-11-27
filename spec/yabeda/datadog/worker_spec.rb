# frozen_string_literal: true

RSpec.describe Yabeda::Datadog::Worker do
  let(:num_threads) { 2 }
  let(:queue_size) { 10 }
  let(:queue_full_behavior) { :block }
  let(:config) do
    instance_double(
      "Yabeda::Datadog::Config",
      queue_size: queue_size, num_threads: num_threads, queue_full_behavior: queue_full_behavior,
    )
  end

  describe "::start" do
    let(:worker) { instance_spy("Yabeda::Datadog::Worker") }

    before do
      allow(described_class).to receive(:new).and_return(worker)
    end

    it "create an instance of worker" do
      instance = described_class.start(config)
      expect(instance).to eq(worker)
    end

    it "spawns worker treads" do
      described_class.start(config)
      expect(worker).to have_received(:spawn_threads).with(num_threads)
    end

    it "blocks on a full queue by default" do
      described_class.start(config)
      expect(described_class).to have_received(:new).with(kind_of(SizedQueue), queue_full_behavior: :block)
    end

    context "when queue_full_behavior comes from an environment variable" do
      let(:queue_full_behavior) { "drop" }

      it "accepts the string value" do
        described_class.start(config)
        expect(described_class).to have_received(:new).with(kind_of(SizedQueue), queue_full_behavior: :drop)
      end
    end

    context "when queue_full_behavior is unknown" do
      let(:queue_full_behavior) { "retry" }

      it "raises a config error" do
        expect { described_class.start(config) }.to raise_error(Yabeda::Datadog::QueueFullBehaviorError)
      end
    end
  end

  describe "::start with YABEDA_DATADOG_QUEUE_FULL_BEHAVIOR set" do
    def clear_anyway_env_cache
      Anyway.env.clear if Anyway.respond_to?(:env) && Anyway.env.respond_to?(:clear)
    end

    around do |example|
      begin
        ENV["YABEDA_DATADOG_QUEUE_FULL_BEHAVIOR"] = "drop"
        clear_anyway_env_cache
        example.run
      ensure
        ENV.delete("YABEDA_DATADOG_QUEUE_FULL_BEHAVIOR")
        clear_anyway_env_cache
      end
    end

    it "drops instead of blocking" do
      config = Yabeda::Datadog::Config.new
      worker = described_class.start(config)
      worker.stop

      expect(worker.enqueue(:SEND, data: 1)).to be_nil
      expect(worker.dropped_count).to eq(1)
    end
  end

  describe "#enqueue" do
    let(:queue) { Queue.new }
    let(:worker) { described_class.new(queue) }

    it "adds action and payload to queue" do
      worker.enqueue(:SEND, data: 1)
      expect(queue.pop).to eq([:SEND, { data: 1 }])
    end

    context "when the queue is full" do
      let(:queue) { SizedQueue.new(1) }

      before { worker.enqueue(:SEND, data: 1) }

      it "waits for room by default" do
        pusher = Thread.new { worker.enqueue(:SEND, data: 2) }

        expect(pusher.join(0.1)).to be_nil
        queue.pop
        expect(pusher.join(1)).to eq(pusher)
      end
    end

    context "when the queue is full and queue_full_behavior is :drop" do
      let(:queue) { SizedQueue.new(1) }
      let(:worker) { described_class.new(queue, queue_full_behavior: :drop) }

      before { worker.enqueue(:SEND, data: 1) }

      it "drops the action instead of waiting" do
        expect(worker.enqueue(:SEND, data: 2)).to be_nil
        expect(queue.size).to eq(1)
        expect(worker.dropped_count).to eq(1)
      end

      it "warns on the first drop and then every 1000th" do
        allow(Yabeda::Datadog::Logging.instance).to receive(:warn)

        1001.times { worker.enqueue(:SEND, data: 2) }

        expect(Yabeda::Datadog::Logging.instance).to have_received(:warn).twice
      end
    end

    context "when the queue is closed" do
      let(:queue) { SizedQueue.new(1) }

      before { queue.close }

      it "raises by default" do
        expect { worker.enqueue(:SEND, data: 1) }.to raise_error(ClosedQueueError)
      end

      it "drops the action with queue_full_behavior: :drop" do
        dropping_worker = described_class.new(queue, queue_full_behavior: :drop)

        expect(dropping_worker.enqueue(:SEND, data: 1)).to be_nil
        expect(dropping_worker.dropped_count).to eq(1)
      end
    end
  end

  describe "#spawn_threads" do
    let(:queue) { Queue.new }
    let(:worker) { described_class.new(queue) }

    before do
      allow(described_class::SEND).to receive(:call)
      allow(described_class::REGISTER).to receive(:call)
    end

    it "spawns given number of therads" do
      worker.spawn_threads(5)
      expect(worker.spawned_threads_count).to eq(5)
    end

    it "dispatches enqueued actions" do
      worker.enqueue(:SEND, a: 1)
      worker.enqueue(:SEND, b: 2)
      worker.enqueue(:REGISTER, name: :a)

      worker.spawn_threads(1)
      sleep(0.1)

      expect(described_class::SEND).to have_received(:call).with([{ a: 1 }, { b: 2 }])
      expect(described_class::REGISTER).to have_received(:call).with([{ name: :a }])
    end

    it "returns true" do
      expect(worker.spawn_threads(0)).to eq(true)
    end
  end

  describe "#stop" do
    let(:queue) { Queue.new }
    let(:worker) { described_class.new(queue) }
    let(:fake_thread) { instance_spy("Thread") }

    it "close worker's queue" do
      expect(queue).not_to be_closed
      worker.stop
      expect(queue).to be_closed
    end

    it "terminates all threads" do
      allow(Thread).to receive(:new).and_return(fake_thread)
      worker.spawn_threads(4)
      worker.stop
      expect(fake_thread).to have_received(:exit).exactly(4).times
    end

    it "empties treads list" do
      worker.spawn_threads(4)
      expect(worker.spawned_threads_count).to eq(4)
      worker.stop
      expect(worker.spawned_threads_count).to eq(0)
    end

    it "returns true" do
      expect(worker.stop).to eq(true)
    end
  end
end
