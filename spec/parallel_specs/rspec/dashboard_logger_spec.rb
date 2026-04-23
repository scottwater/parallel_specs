# frozen_string_literal: true

require 'json'
require 'spec_helper'
require 'parallel_specs/rspec/dashboard_logger'

RSpec.describe ParallelSpecs::RSpec::DashboardLogger do
  around do |example|
    Tempfile.open('dashboard-events') do |file|
      ENV['PARALLEL_SPECS_DASHBOARD_EVENT_LOG'] = file.path
      example.run
    end
  ensure
    ENV.delete('PARALLEL_SPECS_DASHBOARD_EVENT_LOG')
  end

  let(:logger) { described_class.new(StringIO.new) }
  let(:example_notification) { double(example: double(full_description: 'Foo foo')) }

  it 'can be required directly by rspec formatter loading' do
    command = [
      RbConfig.ruby,
      '-rrspec/core',
      '-I', File.expand_path('../../../lib', __dir__),
      '-e', "require 'parallel_specs/rspec/dashboard_logger'; puts ParallelSpecs::RSpec::DashboardLogger.name"
    ]

    output = IO.popen(command, err: [:child, :out], &:read)
    expect($?.success?).to eq(true), output
    expect(output).to include('ParallelSpecs::RSpec::DashboardLogger')
  end

  it 'writes json events for rspec notifications' do
    logger.start(double(count: 3))
    logger.example_started(example_notification)
    logger.example_passed(example_notification)
    logger.close

    path = ENV.fetch('PARALLEL_SPECS_DASHBOARD_EVENT_LOG')
    expect(File.readlines(path).map { |line| JSON.parse(line) }).to eq(
      [
        { 'event' => 'start', 'total' => 3 },
        { 'event' => 'example_started', 'example' => 'Foo foo' },
        { 'event' => 'example_passed', 'example' => 'Foo foo' }
      ]
    )
  end
end
