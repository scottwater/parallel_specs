# frozen_string_literal: true

require 'parallel_specs'
require 'parallel_specs/rspec/logger_base'

class ParallelSpecs::RSpec::RuntimeLogger < ParallelSpecs::RSpec::LoggerBase
  RSpec::Core::Formatters.register(self, :example_group_started, :example_group_finished, :start_dump)

  def initialize(*args)
    super
    @example_times = Hash.new(0)
    @group_nesting = 0
  end

  def example_group_started(example_group)
    @time = ParallelSpecs.now if @group_nesting.zero?
    @group_nesting += 1
    super
  end

  def example_group_finished(notification)
    @group_nesting -= 1
    if @group_nesting.zero?
      @example_times[notification.group.file_path] += ParallelSpecs.now - @time
    end
    super if defined?(super)
  end

  def seed(*); end
  def dump_summary(*); end
  def dump_failures(*); end
  def dump_failure(*); end
  def dump_pending(*); end

  def start_dump(*)
    return unless ENV['TEST_ENV_NUMBER']

    lock_output do
      @example_times.sort_by(&:last).reverse_each do |file, time|
        relative_path = file.sub(%r{^#{Regexp.escape(Dir.pwd)}/}, '').sub(%r{^\./}, '')
        @output.puts "#{relative_path}:#{[time, 0].max}"
      end
    end
    @output.flush
  end
end
