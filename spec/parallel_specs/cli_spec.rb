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

    it 'parses file include and exclude patterns' do
      options = call(['spec', '--pattern', 'models|services', '--exclude-pattern', 'slow'])

      expect(options[:pattern]).to match('spec/models/user_spec.rb')
      expect(options[:pattern]).not_to match('spec/controllers/users_spec.rb')
      expect(options[:exclude_pattern]).to match('spec/models/slow_user_spec.rb')
    end

    it 'parses fail-fast mode' do
      expect(call(['--fail-fast'])).to include(fail_fast: true)
    end

    it 'parses dashboard mode' do
      expect(call(['--dashboard-mode', 'plain'])).to include(dashboard_mode: :plain)
      expect(call(['--plain-dashboard'])).to include(dashboard_mode: :plain)
      expect(call(['--plain'])).to include(dashboard_mode: :plain)
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

    it 'signals tracked workers on the first interrupt when they did not already receive terminal Ctrl-C' do
      allow(Thread).to receive(:new).and_yield
      allow($stdin).to receive(:tty?).and_return(false)
      allow($stdout).to receive(:tty?).and_return(false)

      ParallelSpecs.with_pid_file do
        ParallelSpecs.pids.add(123)
        allow(Process).to receive(:getpgid).with(123).and_return(Process.getpgrp)
        expect(Process).to receive(:kill).with(:INT, 123)
        expect(Kernel).not_to receive(:exit)

        cli.send(:handle_interrupt)
      end
    end

    it 'does not double-signal workers that already received terminal Ctrl-C' do
      allow(Thread).to receive(:new).and_yield
      allow($stdout).to receive(:tty?).and_return(true)

      ParallelSpecs.with_pid_file do
        ParallelSpecs.pids.add(123)
        allow(Process).to receive(:getpgid).with(123).and_return(Process.getpgrp)
        expect(Process).not_to receive(:kill)
        expect(Kernel).not_to receive(:exit)

        cli.send(:handle_interrupt)
      end
    end
  end

  describe '#execute_in_parallel' do
    it 'stops remaining workers after a failed result when fail-fast is enabled' do
      expect(ParallelSpecs).to receive(:stop_all_processes)

      results = cli.send(:execute_in_parallel, [:group], 1, fail_fast: true) do
        { exit_status: 1 }
      end

      expect(results).to eq([{ exit_status: 1 }])
    end

    it 'does not stop remaining workers after a failed result by default' do
      expect(ParallelSpecs).not_to receive(:stop_all_processes)

      results = cli.send(:execute_in_parallel, [:group], 1, {}) do
        { exit_status: 1 }
      end

      expect(results).to eq([{ exit_status: 1 }])
    end
  end

  describe '#run_tests_in_parallel' do
    around { |example| use_temporary_directory(&example) }

    it 'exits unsuccessfully when runtime recording cannot merge worker logs' do
      runner = Class.new do
        class << self
          def tests_in_groups(_files, _num_processes, _options)
            [%w[spec/a_spec.rb]]
          end

          def run_tests(_group, _index, _num_processes, _options)
            { stdout: '1 example, 0 failures', exit_status: 0, env: {} }
          end

          def find_results(_output)
            []
          end

          def summarize_results(_results)
            '1 example, 0 failures'
          end

          def test_file_name
            'spec'
          end
        end
      end
      cli.instance_variable_set(:@runner, runner)

      expect do
        expect do
          cli.send(:run_tests_in_parallel, 1, files: ['spec'], record_runtime: true, runtime_log: 'runtime.log', dashboard: false)
        end.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      end.to output(/missing worker runtime logs/).to_stderr
    end
  end

  describe '#report_failure_rerun_commands' do
    let(:runner) do
      Class.new do
        class << self
          def rerun_command(command, seed: nil)
            seed ? [*command, '--seed', seed] : command
          end

          def print_command(command, _env)
            puts command.join(' ')
          end

          def test_file_name
            'spec'
          end
        end
      end
    end

    before do
      cli.instance_variable_set(:@runner, runner)
    end

    it 'prints rerun commands for failed workers with captured seeds' do
      results = [
        { exit_status: 0, command: ['rspec', 'spec/pass_spec.rb'], env: {} },
        { exit_status: 1, command: ['rspec', 'spec/fail_spec.rb'], env: {}, seed: '1234' }
      ]

      expect do
        cli.send(:report_failure_rerun_commands, results)
      end.to output(/Rerun failed worker commands:\nrspec spec\/fail_spec\.rb --seed 1234/).to_stdout
    end

    it 'summarizes failed worker rerun commands when a command includes many spec files' do
      command = ['rspec', *(1..26).map { |index| "spec/file_#{index}_spec.rb" }]
      results = [{ exit_status: 1, command: command, env: { 'TEST_ENV_NUMBER' => '2' }, seed: '1234' }]

      expect do
        cli.send(:report_failure_rerun_commands, results)
      end.to output(<<~OUTPUT).to_stdout

        Full worker rerun commands omitted to keep failure output readable.
        1 failed worker included 26 specs.
        RSpec failure output above includes failed example locations.
        Set PARALLEL_SPECS_FULL_RERUN_COMMANDS=1 to print full worker rerun commands.
        worker 2: 26 specs, seed 1234
      OUTPUT
    end

    it 'prints long failed worker rerun commands when explicitly requested' do
      ENV['PARALLEL_SPECS_FULL_RERUN_COMMANDS'] = '1'
      command = ['rspec', *(1..26).map { |index| "spec/file_#{index}_spec.rb" }]
      results = [{ exit_status: 1, command: command, env: {}, seed: '1234' }]

      expect do
        cli.send(:report_failure_rerun_commands, results)
      end.to output(/Rerun failed worker commands:\nrspec spec\/file_1_spec\.rb.*--seed 1234/m).to_stdout
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

    it 'does not replace the runtime log when no worker logs were produced' do
      File.write('runtime.log', "known-good\n")

      expect do
        expect(cli.send(:merge_runtime_logs, {}, 'runtime.log')).to be(false)
      end.to output(/no worker runtime logs were produced/).to_stderr

      expect(File.read('runtime.log')).to eq("known-good\n")
    end

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

    it 'respects the option override' do
      allow($stdout).to receive(:tty?).and_return(true)
      ENV['CI'] = '1'
      expect(cli.send(:dashboard_mode, dashboard_mode: :interactive)).to eq(:interactive)
    end

    it 'respects the override env var' do
      allow($stdout).to receive(:tty?).and_return(false)
      ENV['PARALLEL_SPECS_DASHBOARD_MODE'] = 'interactive'
      expect(cli.send(:dashboard_mode)).to eq(:interactive)
    end
  end
end
