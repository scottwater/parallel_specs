# frozen_string_literal: true

require 'spec_helper'
require 'parallel_specs/rspec/runner'

RSpec.describe ParallelSpecs::RSpec::Runner do
  test_tests_in_groups(described_class, '_spec.rb')

  describe '.run_tests' do
    before do
      allow(ParallelSpecs).to receive(:bundler_enabled?).and_return(false)
    end

    it 'adds the dashboard formatter by default' do
      should_run_with ['rspec'], '--format', 'ParallelSpecs::RSpec::DashboardLogger'
      described_class.run_tests('spec/foo_spec.rb', 0, 2, dashboard: true)
    end

    it 'adds runtime logging formatters when recording runtime' do
      should_run_with ['rspec'], '--format', 'progress', '--format', 'ParallelSpecs::RSpec::RuntimeLogger', '--out', 'tmp/runtime.log'
      described_class.run_tests('spec/foo_spec.rb', 0, 2, record_runtime: true, runtime_log: 'tmp/runtime.log')
    end
  end
end
