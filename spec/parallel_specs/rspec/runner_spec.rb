# frozen_string_literal: true

require 'spec_helper'
require 'parallel_specs/rspec/runner'

runtime_formatter_args = lambda do |path|
  ['--format', 'progress', '--format', 'ParallelSpecs::RSpec::RuntimeLogger', '--out', path]
end

RSpec.describe ParallelSpecs::RSpec::Runner do
  test_tests_in_groups(described_class, '_spec.rb')

  describe '.tests_in_groups' do
    around { |example| use_temporary_directory(&example) }

    it 'warns and falls back when a custom default runtime log is missing' do
      FileUtils.mkdir_p('spec')
      File.write('spec/a_spec.rb', 'x')

      expect do
        groups = described_class.tests_in_groups(['spec'], 1, runtime_log: 'missing.log')
        expect(groups).to eq([['spec/a_spec.rb']])
      end.to output(/runtime log missing\.log was not found; falling back to filesize grouping/).to_stderr
    end

    it 'warns and falls back when the default runtime log is malformed' do
      FileUtils.mkdir_p('spec')
      File.write('spec/a_spec.rb', 'x')
      File.write('runtime.log', "spec/a_spec.rb:not-a-number\n")

      expect do
        groups = described_class.tests_in_groups(['spec'], 1, runtime_log: 'runtime.log')
        expect(groups).to eq([['spec/a_spec.rb']])
      end.to output(/unable to use runtime log runtime\.log: Invalid runtime value.*falling back to filesize grouping/).to_stderr
    end

    it 'raises on malformed runtime values when runtime grouping is explicit' do
      FileUtils.mkdir_p('spec')
      File.write('spec/a_spec.rb', 'x')
      File.write('runtime.log', "spec/a_spec.rb:not-a-number\n")

      expect do
        described_class.tests_in_groups(['spec'], 1, runtime_log: 'runtime.log', group_by: :runtime)
      end.to raise_error(ParallelSpecs::Test::Runner::RuntimeLogParseError, /Invalid runtime value/)
    end
  end

  describe '.run_tests' do
    before do
      allow(ParallelSpecs).to receive(:bundler_enabled?).and_return(false)
    end

    it 'adds the dashboard formatter by default' do
      should_run_with ['rspec'], '--format', 'ParallelSpecs::RSpec::DashboardLogger'
      described_class.run_tests('spec/foo_spec.rb', 0, 2, dashboard: true)
    end

    it 'adds runtime logging formatters when recording runtime' do
      should_run_with ['rspec'], *runtime_formatter_args.call('tmp/runtime.log')
      described_class.run_tests('spec/foo_spec.rb', 0, 2, record_runtime: true, runtime_log: 'tmp/runtime.log')
    end

    it 'uses the worker runtime log when provided' do
      should_run_with ['rspec'], *runtime_formatter_args.call('tmp/worker-2.log')
      options = {
        record_runtime: true,
        runtime_log: 'tmp/runtime.log',
        runtime_log_files: { 1 => 'tmp/worker-2.log' }
      }
      described_class.run_tests('spec/foo_spec.rb', 1, 2, options)
    end
  end
end
