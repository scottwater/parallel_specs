# frozen_string_literal: true

require 'spec_helper'
require 'parallel_specs/test/runner'

RSpec.describe ParallelSpecs::Test::Runner do
  describe '.execute_command' do
    def call(*args)
      ParallelSpecs.with_pid_file { described_class.execute_command(*args) }
    end

    def run_with_file(contents)
      Tempfile.open(['runner', '.rb']) do |file|
        file.write(contents)
        file.flush
        yield file.path
      end
    end

    it 'sets worker environment variables' do
      run_with_file(<<~RUBY) do |path|
        puts [
          ENV['TEST_ENV_NUMBER'],
          ENV['PARALLEL_SPECS_GROUPS'],
          File.exist?(ENV['PARALLEL_SPECS_PID_FILE']).to_s
        ].join(',')
      RUBY
        result = call(['ruby', path], 1, 4, dashboard: false)
        expect(result[:stdout].chomp).to eq('2,4,true')
      end
    end

    it 'captures the RSpec seed from worker output' do
      run_with_file("puts 'Randomized with seed 12345'") do |path|
        result = call(['ruby', path], 1, 4, dashboard: true)
        expect(result[:seed]).to eq('12345')
      end
    end

    it 'sets the dashboard log env var when dashboard output is enabled' do
      run_with_file("puts File.basename(ENV['PARALLEL_SPECS_DASHBOARD_EVENT_LOG'])") do |path|
        result = call(['ruby', path], 1, 4, dashboard_event_files: { 1 => '/tmp/worker-2.jsonl' }, dashboard: true)
        expect(result[:stdout].chomp).to eq('worker-2.jsonl')
      end
    end

    it 'streams output when not using the dashboard' do
      run_with_file('puts 123') do |path|
        expect do
          call(['ruby', path], 1, 4, dashboard: false)
        end.to output(/123/).to_stdout
      end
    end

    it 'returns signal based exit status for terminated processes', unless: Gem.win_platform? do
      run_with_file("Process.kill('KILL', Process.pid)") do |path|
        result = call(['ruby', path], 1, 4, dashboard: false)
        expect(result[:exit_status]).to eq(137)
      end
    end

    it 'removes worker pids when output capture raises' do
      run_with_file('puts 123') do |path|
        allow(described_class).to receive(:capture_output).and_raise('capture failed')

        ParallelSpecs.with_pid_file do
          expect do
            described_class.execute_command(['ruby', path], 1, 4, dashboard: false)
          end.to raise_error(RuntimeError, 'capture failed')
          expect(ParallelSpecs.pids.all).to be_empty
        end
      end
    end
  end

  describe '.find_tests' do
    around { |example| use_temporary_directory(&example) }

    before do
      FileUtils.mkdir_p('spec/models')
      FileUtils.mkdir_p('spec/services')
      FileUtils.mkdir_p('spec/controllers')
      File.write('spec/models/user_spec.rb', 'x')
      File.write('spec/models/slow_user_spec.rb', 'x')
      File.write('spec/services/user_sync_spec.rb', 'x')
      File.write('spec/controllers/users_controller_spec.rb', 'x')
    end

    it 'filters discovered directory files with include and exclude patterns' do
      files = described_class.send(
        :find_tests,
        ['spec'],
        pattern: /models|services/,
        exclude_pattern: /slow/
      )

      expect(files).to eq(%w[spec/models/user_spec.rb spec/services/user_sync_spec.rb])
    end

    it 'filters explicit file inputs' do
      files = described_class.send(
        :find_tests,
        %w[spec/models/user_spec.rb spec/controllers/users_controller_spec.rb],
        pattern: /models/,
        exclude_pattern: /slow/
      )

      expect(files).to eq(%w[spec/models/user_spec.rb])
    end
  end

  describe '.print_command' do
    it 'prints a copy-pasteable command with rerun environment' do
      expect do
        described_class.print_command(['bundle', 'exec', 'rspec', 'spec/a spec.rb'], {
          'TEST_ENV_NUMBER' => '2',
          'PARALLEL_SPECS_GROUPS' => '4',
          'PARALLEL_SPECS_PID_FILE' => '/tmp/ignored'
        })
      end.to output("TEST_ENV_NUMBER=2 PARALLEL_SPECS_GROUPS=4 bundle exec rspec spec/a\\ spec.rb\n").to_stdout
    end
  end
end
