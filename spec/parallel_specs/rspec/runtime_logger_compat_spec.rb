# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ParallelTests runtime logger compatibility' do
  it 'loads the old formatter path for drop-in wrappers' do
    require 'parallel_tests/rspec/runtime_logger'

    expect(ParallelTests::RSpec::RuntimeLogger).to eq(ParallelSpecs::RSpec::RuntimeLogger)
  end
end
