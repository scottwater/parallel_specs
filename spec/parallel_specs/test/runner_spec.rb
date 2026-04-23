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

    it 'sets both dashboard log env vars when dashboard output is enabled' do
      run_with_file("puts [ENV['PARALLEL_SPECS_DASHBOARD_EVENT_LOG'], ENV['PARALLEL_TESTS_DASHBOARD_EVENT_LOG']].map { |v| File.basename(v) }.join(':')") do |path|
        result = call(['ruby', path], 1, 4, dashboard_event_files: { 1 => '/tmp/worker-2.jsonl' })
        expect(result[:stdout].chomp).to eq('worker-2.jsonl:worker-2.jsonl')
      end
    end

    it 'does not prepend the command when serializing output with a dashboard runner' do
      run_with_file('puts 123') do |path|
        result = call(['ruby', path], 1, 4, serialize_stdout: true, verbose_process_command: true, dashboard_runner: Object.new)
        expect(result[:stdout].chomp).to eq('123')
      end
    end

    it 'returns signal based exit status for terminated processes', unless: Gem.win_platform? do
      run_with_file("Process.kill('KILL', Process.pid)") do |path|
        result = call(['ruby', path], 1, 4, {})
        expect(result[:exit_status]).to eq(137)
      end
    end
  end
end
