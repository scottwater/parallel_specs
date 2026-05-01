# frozen_string_literal: true

require 'parallel'
require 'rbconfig'
require 'tempfile'

module ParallelSpecs
  WINDOWS = (RbConfig::CONFIG['host_os'] =~ /cygwin|mswin|mingw|bccwin|wince|emx/)
  RUBY_BINARY = File.join(RbConfig::CONFIG['bindir'], RbConfig::CONFIG['ruby_install_name'])

  autoload :CLI, 'parallel_specs/cli'
  autoload :VERSION, 'parallel_specs/version'
  autoload :Grouper, 'parallel_specs/grouper'
  autoload :Pids, 'parallel_specs/pids'

  class << self
    def determine_number_of_processes(count)
      Integer([
        count,
        ENV['PARALLEL_SPECS_PROCESSORS'],
        Parallel.processor_count
      ].detect { |value| !value.to_s.strip.empty? })
    end

    def with_pid_file
      previous_pid_file = ENV['PARALLEL_SPECS_PID_FILE']
      Tempfile.open('parallel_specs-pidfile') do |file|
        ENV['PARALLEL_SPECS_PID_FILE'] = file.path
        @pids = pids
        yield
      ensure
        ENV['PARALLEL_SPECS_PID_FILE'] = previous_pid_file
        @pids = nil
      end
    end

    def pids
      @pids ||= Pids.new(pid_file_path)
    end

    def pid_file_available?
      !ENV['PARALLEL_SPECS_PID_FILE'].to_s.empty?
    end

    def pid_file_path
      ENV.fetch('PARALLEL_SPECS_PID_FILE')
    end

    def stop_all_processes
      return false unless pid_file_available?

      pids.all.each do |pid|
        Process.kill(:INT, pid)
      rescue Errno::ESRCH, Errno::EPERM => e
        warn "parallel_specs: unable to interrupt worker pid #{pid}: #{e.class}: #{e.message}"
      end
      true
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
