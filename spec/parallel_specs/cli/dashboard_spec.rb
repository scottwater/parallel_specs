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

    expect(frame).to include('examples: 1/2 known')
    expect(frame).to include('elapsed:')
    expect(frame).not_to include('workers: 2')
    expect(frame).not_to include('passed: 1')
    expect(frame).to include('[ 1] ✓ passed')
    expect(frame).to include('[############------------]')
    expect(frame).not_to include('Foo foo')
    expect(frame).to include('[ 2] · queued')
  end

  it 'warns when final polling fails during stop' do
    allow(dashboard).to receive(:poll_once).and_raise(StandardError, 'final poll failed')

    original_stderr = $stderr
    captured_stderr = StringIO.new
    $stderr = captured_stderr
    begin
      expect { dashboard.stop }.not_to raise_error
    ensure
      $stderr = original_stderr
    end

    expect(captured_stderr.string).to match(/dashboard final poll failed while polling worker 1=.*final poll failed/)
  end

  it 'warns when the refresh thread fails' do
    allow(dashboard).to receive(:poll_once).and_raise(StandardError, 'bad json')

    original_stderr = $stderr
    captured_stderr = StringIO.new
    $stderr = captured_stderr
    begin
      dashboard.start
      sleep 0.03
      dashboard.stop
    ensure
      $stderr = original_stderr
    end

    expect(captured_stderr.string).to match(/dashboard refresh failed while polling worker 1=.*bad json/)
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

  it 'checks the terminal width on each render so resize can recover' do
    widths = [80, 20]
    dashboard = described_class.new(
      groups: [['a_spec.rb'], ['b_spec.rb']],
      event_files: event_files,
      output: output,
      use_colors: false,
      mode: :interactive,
      now: now,
      width: -> { widths.shift || 20 }
    )

    expect(dashboard.send(:terminal_width)).to eq(79)
    expect(dashboard.send(:terminal_width)).to eq(19)
  end

  context 'in plain mode' do
    let(:mode) { :plain }
    let(:now) { -> { Time.now.to_i } }

    it 'renders the same concise summary as the interactive header' do
      dashboard.worker_started(0)
      dashboard.process_event(0, 'event' => 'start', 'total' => 2)
      dashboard.process_event(0, 'event' => 'example_passed', 'example' => 'Foo foo')
      dashboard.worker_finished(0, exit_status: 0)

      frame = dashboard.frame

      expect(frame).to eq("examples: 1/2 known | elapsed: 00:00\n")
      expect(frame).not_to include('worker=')
      expect(frame).not_to include('Foo foo')
      expect(frame).not_to include("\e[")
    end
  end
end
