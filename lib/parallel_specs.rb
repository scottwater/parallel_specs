# frozen_string_literal: true

require 'parallel'
require 'rbconfig'
require 'tempfile'

module ParallelSpecs
  WINDOWS = (RbConfig::CONFIG['host_os'] =~ /cygwin|mswin|mingw|bccwin|wince|emx/)
  RUBY_BINARY = File.join(RbConfig::CONFIG['bindir'], RbConfig::CONFIG['ruby_install_name'])
  DEFAULT_MULTIPLY_PROCESSES = 1.0

  autoload :CLI, 'parallel_specs/cli'
  autoload :VERSION, 'parallel_specs/version'
  autoload :Grouper, 'parallel_specs/grouper'
  autoload :Pids, 'parallel_specs/pids'

  class << self
    def determine_number_of_processes(count)
      Integer([
        count,
        ENV['PARALLEL_TEST_PROCESSORS'],
        Parallel.processor_count
      ].detect { |value| !value.to_s.strip.empty? })
    end

    def determine_multiple(multiple)
      Float([
        multiple,
        ENV['PARALLEL_TEST_MULTIPLY_PROCESSES'],
        DEFAULT_MULTIPLY_PROCESSES
      ].detect { |value| !value.to_s.strip.empty? })
    end

    def with_pid_file
      Tempfile.open('parallel_specs-pidfile') do |file|
        ENV['PARALLEL_PID_FILE'] = file.path
        @pids = pids
        yield
      ensure
        ENV['PARALLEL_PID_FILE'] = nil
        @pids = nil
      end
    end

    def pids
      @pids ||= Pids.new(pid_file_path)
    end

    def pid_file_path
      ENV.fetch('PARALLEL_PID_FILE')
    end

    def stop_all_processes
      pids.all.each { |pid| Process.kill(:INT, pid) }
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def bundler_enabled?
      return true if Object.const_defined?(:Bundler)

      previous = nil
      current = File.expand_path(Dir.pwd)
      until !File.directory?(current) || current == previous
        return true if File.exist?(File.join(current, 'Gemfile'))
        previous = current
        current = File.expand_path('..', current)
      end

      false
    end

    def with_ruby_binary(command)
      WINDOWS ? [RUBY_BINARY, '--', command] : [command]
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def delta
      before = now.to_f
      yield
      now.to_f - before
    end
  end
end
