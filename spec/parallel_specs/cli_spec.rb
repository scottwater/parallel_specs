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

    it 'switches to runtime recording mode' do
      expect(call(['--record-runtime'])).to include(record_runtime: true, dashboard: false)
    end

    it 'merges extra rspec args passed after --' do
      expect(call(['--', '--tag', '~type:system', '--', 'spec/models'])).to include(
        files: ['spec/models'],
        test_options: ['--tag', '~type:system']
      )
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
end
