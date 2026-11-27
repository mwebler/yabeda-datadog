# frozen_string_literal: true

RSpec.describe Yabeda::Datadog::QueueFullBehavior do
  describe "::parse" do
    it "normalizes symbols, strings and blanks" do
      expect([:drop, "drop", "DROP", " :drop "].map { |value| described_class.parse(value) }).to all(eq(:drop))
      expect([nil, "", :block, "block"].map { |value| described_class.parse(value) }).to all(eq(:block))
    end

    it "rejects unknown values" do
      expect { described_class.parse("retry") }.to raise_error(Yabeda::Datadog::QueueFullBehaviorError)
    end
  end
end
