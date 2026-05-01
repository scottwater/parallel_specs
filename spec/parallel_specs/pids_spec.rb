# frozen_string_literal: true

require 'spec_helper'
require 'parallel_specs/pids'

RSpec.describe ParallelSpecs::Pids do
  around { |example| use_temporary_directory(&example) }

  subject(:pids) { described_class.new('pids.json') }

  it 'returns a copy of tracked pids' do
    pids.add(123)

    pids.all << 456

    expect(pids.all).to eq([123])
  end

  it 'synchronizes add and delete operations' do
    threads = 10.times.map do |index|
      Thread.new do
        pids.add(index)
        pids.delete(index) if index.even?
      end
    end

    threads.each(&:join)

    expect(pids.all).to match_array([1, 3, 5, 7, 9])
  end
end
