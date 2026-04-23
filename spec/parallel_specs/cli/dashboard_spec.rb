# frozen_string_literal: true

require 'spec_helper'
require 'parallel_specs/cli/dashboard'

RSpec.describe ParallelSpecs::CLI::Dashboard do
  let(:output) { OutputLogger.new([]) }
  let(:clock) { Array.new(50) { |index| index * 5 }.each }
  let(:now) { -> { clock.next } }
  let(:event_files) { { 0 => event_file_1, 1 => event_file_2 } }
  let(:mode) { :interactive }

  let(:event_file_1) do
    file = Tempfile.new('dashboard-worker-1')
    file.close
    file.path
  end

  let(:event_file_2) do
    file = Tempfile.new('dashboard-worker-2')
    file.close
    file.path
  end

  subject(:dashboard) do
    described_class.new(
      groups: [['a_spec.rb', 'b_spec.rb'], ['c_spec.rb']],
      event_files: event_files,
      output: output,
      use_colors: false,
      mode: mode,
      now: now,
      width: 200,
      refresh_interval: 0.01
    )
  end

  after do
    [event_file_1, event_file_2].each { |path| FileUtils.rm_f(path) }
  end

  it 'renders worker states and counts' do
    dashboard.worker_started(0)
    dashboard.process_event(0, 'event' => 'start', 'total' => 2)
    dashboard.process_event(0, 'event' => 'example_started', 'example' => 'Foo foo')
    dashboard.process_event(0, 'event' => 'example_passed', 'example' => 'Foo foo')
    dashboard.worker_finished(0, exit_status: 0)

    frame = dashboard.frame

    expect(frame).to include('Parallel RSpec dashboard')
    expect(frame).to include('workers: 2')
    expect(frame).to include('passed: 1')
    expect(frame).to include('[ 1] ✓ passed')
    expect(frame).to include('[############------------]')
    expect(frame).to include('[ 2] · queued')
  end

  it 'polls jsonl event files' do
    File.write(event_file_1, <<~JSONL)
      {"event":"start","total":2}
      {"event":"example_started","example":"Foo foo"}
      {"event":"example_passed","example":"Foo foo"}
    JSONL

    dashboard.poll_once

    worker = dashboard.workers.first
    expect(worker.example_total).to eq(2)
    expect(worker.passed).to eq(1)
    expect(worker.current_example).to eq('Foo foo')
  end

  context 'in plain mode' do
    let(:mode) { :plain }
    let(:now) { -> { Time.now.to_i } }

    it 'renders machine-friendly plain text lines' do
      dashboard.worker_started(0)
      dashboard.process_event(0, 'event' => 'start', 'total' => 2)
      dashboard.process_event(0, 'event' => 'example_passed', 'example' => 'Foo foo')
      dashboard.worker_finished(0, exit_status: 0)

      frame = dashboard.frame

      expect(frame).to include('dashboard workers=2 running=0 passed=1 failed=0 examples_seen=1')
      expect(frame).to include('worker=1 status=passed passed=1 failed=0 pending=0 completed=1 total=2')
      expect(frame).to include('worker=2 status=queued passed=0 failed=0 pending=0 files=1')
      expect(frame).not_to include("\e[")
    end
  end
end
