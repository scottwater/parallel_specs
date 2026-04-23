# frozen_string_literal: true

require 'spec_helper'
require 'parallel_specs/cli'

RSpec.describe ParallelSpecs::CLI do
  subject(:cli) { described_class.new }

  describe '#parse_options!' do
    def call(argv)
      cli.send(:parse_options!, argv)
    end

    it 'defaults to spec and dashboard mode' do
      expect(call([])).to include(files: ['spec'], dashboard: true)
    end

    it 'parses runtime balancing options' do
      expect(call(['spec', '--group-by', 'runtime', '--runtime-log', 'tmp/runtime.log', '--unknown-runtime', '5'])).to include(
        files: ['spec'],
        group_by: :runtime,
        runtime_log: 'tmp/runtime.log',
        unknown_runtime: 5.0,
        dashboard: true
      )
    end

    it 'disables the dashboard when recording runtime' do
      expect(call(['--record-runtime'])).to include(record_runtime: true, dashboard: false)
    end

    it 'merges extra rspec args passed after --' do
      expect(call(['--', '--tag', '~type:system', '--', 'spec/models'])).to include(
        files: ['spec/models'],
        test_options: ['--tag', '~type:system']
      )
    end

    it 'raises when verbose and quiet are both set' do
      expect { call(['--verbose', '--quiet']) }.to raise_error(RuntimeError, /mutually exclusive/)
    end
  end

  describe '#dashboard_mode' do
    it 'uses interactive mode on a tty by default' do
      allow($stdout).to receive(:tty?).and_return(true)
      expect(cli.send(:dashboard_mode)).to eq(:interactive)
    end

    it 'uses plain mode in ci' do
      allow($stdout).to receive(:tty?).and_return(true)
      ENV['CI'] = '1'
      expect(cli.send(:dashboard_mode)).to eq(:plain)
    end

    it 'respects the override env var' do
      allow($stdout).to receive(:tty?).and_return(false)
      ENV['PARALLEL_SPECS_DASHBOARD_MODE'] = 'interactive'
      expect(cli.send(:dashboard_mode)).to eq(:interactive)
    end
  end

  describe '#report_failure_rerun_command' do
    it 'prints the rerun command when requested' do
      cli.instance_variable_set(:@runner, ParallelSpecs::RSpec::Runner)
      failed = [{ exit_status: 1, command: %w[bundle exec rspec spec/foo_spec.rb], seed: nil, env: { 'TEST_ENV_NUMBER' => '', 'PARALLEL_TEST_GROUPS' => '2' } }]

      expect do
        cli.send(:report_failure_rerun_command, failed, verbose_rerun_command: true)
      end.to output(/Re-run with/).to_stdout
    end
  end
end
