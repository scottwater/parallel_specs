# frozen_string_literal: true

require "spec_helper"

RSpec.describe ParallelSpecs::Grouper do
  let(:items) do
    [
      ["spec/features/a_spec.rb", 2],
      ["spec/features/b_spec.rb", 1],
      ["spec/models/a_spec.rb", 8],
      ["spec/models/b_spec.rb", 7],
      ["spec/models/c_spec.rb", 6],
      ["spec/models/d_spec.rb", 5]
    ]
  end

  it "keeps singled files together while allowing the group to be topped up" do
    groups = described_class.in_even_groups_by_size(items, 3, single_process: [/spec\/features/])

    expect(groups[0]).to eq(%w[spec/features/a_spec.rb spec/features/b_spec.rb spec/models/c_spec.rb])
  end

  it "keeps singled files alone on one worker when isolated" do
    groups = described_class.in_even_groups_by_size(items, 3, single_process: [/spec\/features/], isolate: true)

    expect(groups[0]).to eq(%w[spec/features/a_spec.rb spec/features/b_spec.rb])
    expect(groups.drop(1).flatten).to contain_exactly(
      "spec/models/a_spec.rb",
      "spec/models/b_spec.rb",
      "spec/models/c_spec.rb",
      "spec/models/d_spec.rb"
    )
  end

  it "spreads singled files across the requested dedicated workers" do
    groups = described_class.in_even_groups_by_size(items, 4, single_process: [/spec\/features/], isolate_count: 2)

    expect(groups.first(2).flatten).to contain_exactly("spec/features/a_spec.rb", "spec/features/b_spec.rb")
    expect(groups.first(2).flatten).to all(match(%r{\Aspec/features/}))
    expect(groups.drop(2).flatten).to contain_exactly(
      "spec/models/a_spec.rb",
      "spec/models/b_spec.rb",
      "spec/models/c_spec.rb",
      "spec/models/d_spec.rb"
    )
  end

  it "rejects a non-positive isolated worker count" do
    expect do
      described_class.in_even_groups_by_size(items, 3, single_process: [/spec\/features/], isolate_count: 0)
    end.to raise_error(
      ParallelSpecs::ConfigurationError,
      "Isolated process count must be greater than 0"
    )
  end

  it "rejects an isolated worker count that leaves no worker for other specs" do
    expect do
      described_class.in_even_groups_by_size(items, 3, single_process: [/spec\/features/], isolate_count: 3)
    end.to raise_error(
      ParallelSpecs::ConfigurationError,
      "Isolated process count must be less than total process count"
    )
  end
end
