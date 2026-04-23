# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'rspec/core'
require 'rspec/core/formatters/base_text_formatter'

module ParallelSpecs
  module RSpec
  end
end

class ParallelSpecs::RSpec::DashboardLogger < RSpec::Core::Formatters::BaseTextFormatter
  RSpec::Core::Formatters.register(
    self,
    :start,
    :example_started,
    :example_passed,
    :example_pending,
    :example_failed
  )

  def initialize(output)
    super

    path = ENV['PARALLEL_SPECS_DASHBOARD_EVENT_LOG'] || ENV['PARALLEL_TESTS_DASHBOARD_EVENT_LOG']
    raise 'A dashboard event log env var is required for DashboardLogger' if path.to_s.empty?

    FileUtils.mkdir_p(File.dirname(path))
    @event_output = File.open(path, 'a')
    @event_output.sync = true
  end

  def start(notification)
    emit(event: 'start', total: notification.count)
  end

  def example_started(notification)
    emit_example('example_started', notification)
  end

  def example_passed(notification)
    emit_example('example_passed', notification)
  end

  def example_pending(notification)
    emit_example('example_pending', notification)
  end

  def example_failed(notification)
    emit_example('example_failed', notification)
  end

  def close(*)
    @event_output.close unless @event_output.closed?
  end

  private

  def emit_example(event_name, notification)
    emit(event: event_name, example: notification.example.full_description)
  end

  def emit(payload)
    @event_output.puts(JSON.generate(payload))
  end
end
