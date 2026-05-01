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

  describe '#handle_interrupt' do
    it 'exits when interrupted before workers have a pid file' do
      allow(Thread).to receive(:new).and_yield
      expect(Kernel).to receive(:exit)

      cli.send(:handle_interrupt)
    end
  end

  describe '#with_runtime_log_files' do
    around { |example| use_temporary_directory(&example) }

    it 'does not replace an existing runtime log when the run fails' do
      File.write('runtime.log', "known-good\n")
      options = { record_runtime: true, runtime_log: 'runtime.log' }

      expect do
        cli.send(:with_runtime_log_files, [%w[spec/a_spec.rb]], options) do
          File.write(options[:runtime_log_files].fetch(0), "partial\n")
          false
        end
      end.to output(/not updating runtime log runtime\.log; run did not complete successfully/).to_stderr

      expect(File.read('runtime.log')).to eq("known-good\n")
    end
  end

  describe '#merge_runtime_logs' do
    around { |example| use_temporary_directory(&example) }

    it 'does not replace the runtime log when an expected worker log is missing' do
      File.write('runtime.log', "known-good\n")

      expect do
        expect(cli.send(:merge_runtime_logs, { 0 => 'missing-worker.log' }, 'runtime.log')).to be(false)
      end.to output(/missing worker runtime logs: missing-worker\.log/).to_stderr

      expect(File.read('runtime.log')).to eq("known-good\n")
    end

    it 'atomically replaces the runtime log after all expected worker logs exist' do
      FileUtils.mkdir_p('workers')
      File.write('workers/one.log', "spec/a_spec.rb:1.0\n")
      File.write('workers/two.log', "spec/b_spec.rb:2.0\n")

      expect(cli.send(:merge_runtime_logs, { 0 => 'workers/one.log', 1 => 'workers/two.log' }, 'tmp/runtime.log')).to be(true)

      expect(File.read('tmp/runtime.log')).to eq("spec/a_spec.rb:1.0\nspec/b_spec.rb:2.0\n")
      expect(Dir['tmp/runtime.log.*.tmp']).to be_empty
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
