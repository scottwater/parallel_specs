# frozen_string_literal: true

require 'parallel_specs/test/runner'

module ParallelSpecs
  module RSpec
    class Runner < ParallelSpecs::Test::Runner
      class << self
        def run_tests(test_files, process_number, num_processes, options)
          execute_command(
            build_test_command(test_files, process_number, options),
            process_number,
            num_processes,
            options
          )
        end

        def runtime_log
          'tmp/parallel_runtime_rspec.log'
        end

        def default_test_folder
          'spec'
        end

        def test_file_name
          'spec'
        end

        def line_is_result?(line)
          line =~ /\d+ examples?, \d+ failures?/
        end

        def summarize_results(results)
          text = super
          return text unless $stdout.tty?

          sums = send(:sum_up_results, results)
          color_code = if sums['failure'] > 0
            31
          elsif sums['pending'] > 0
            33
          else
            32
          end
          "\e[#{color_code}m#{text}\e[0m"
        end

        private

        def build_test_command(file_list, process_number, options)
          [
            *executable,
            *options.fetch(:test_options, []),
            *color,
            *record_runtime_formatters(process_number, options),
            *dashboard_formatter(options),
            *file_list
          ]
        end

        def executable
          if File.exist?('bin/rspec')
            ParallelSpecs.with_ruby_binary('bin/rspec')
          elsif ParallelSpecs.bundler_enabled?
            %w[bundle exec rspec]
          else
            ['rspec']
          end
        end

        def color
          %w[--color --tty] if $stdout.tty?
        end

        def dashboard_formatter(options)
          ['--format', 'ParallelSpecs::RSpec::DashboardLogger'] if options[:dashboard]
        end

        def record_runtime_formatters(process_number, options)
          return [] unless options[:record_runtime]

          runtime_log_path = options.fetch(:runtime_log_files, {}).fetch(process_number) do
            options[:runtime_log] || runtime_log
          end

          ['--format', 'progress', '--format', 'ParallelSpecs::RSpec::RuntimeLogger', '--out', runtime_log_path]
        end
      end
    end
  end
end
