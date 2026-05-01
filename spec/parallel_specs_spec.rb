# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ParallelSpecs do
  describe '.stop_all_processes' do
    it 'returns false when no pid file is active' do
      expect(described_class.stop_all_processes).to be(false)
    end

    it 'returns false when the pid file has no tracked workers' do
      described_class.with_pid_file do
        expect(described_class.stop_all_processes).to be(false)
      end
    end

    it 'returns false when no tracked workers could be signaled' do
      described_class.with_pid_file do
        described_class.pids.add(111)
        allow(Process).to receive(:kill).and_raise(Errno::ESRCH)

        expect do
          expect(described_class.stop_all_processes).to be(false)
        end.to output(/unable to interrupt worker pid 111/).to_stderr
      end
    end

    it 'continues interrupting later pids when one pid is stale' do
      described_class.with_pid_file do
        described_class.pids.add(111)
        described_class.pids.add(222)
        signaled_pids = []

        allow(Process).to receive(:kill) do |_signal, pid|
          signaled_pids << pid
          raise Errno::ESRCH if pid == 111
        end

        expect do
          expect(described_class.stop_all_processes).to be(true)
        end.to output(/unable to interrupt worker pid 111/).to_stderr
        expect(signaled_pids).to eq([111, 222])
      end
    end
  end

  describe '.determine_number_of_processes' do
    it 'uses PARALLEL_SPECS_PROCESSORS when no explicit count is provided' do
      ENV['PARALLEL_SPECS_PROCESSORS'] = '3'

      expect(described_class.determine_number_of_processes(nil)).to eq(3)
    end

    it 'prefers the explicit count over PARALLEL_SPECS_PROCESSORS' do
      ENV['PARALLEL_SPECS_PROCESSORS'] = '3'

      expect(described_class.determine_number_of_processes(2)).to eq(2)
    end
  end
end
