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
  end
end
