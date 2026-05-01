# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ParallelSpecs do
  describe '.stop_all_processes' do
    it 'returns false when no pid file is active' do
      expect(described_class.stop_all_processes).to be(false)
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
end
