# frozen_string_literal: true

require 'parallel_specs/test/runner'

module ParallelSpecs
  module RSpec
    class Runner < ParallelSpecs::Test::Runner
      class << self
        def run_tests(test_files, process_number, num_processes, options)
          execute_command(build_command(test_files, options), process_number, num_processes, options)
        end

        def determine_executable
          if File.exist?('bin/rspec')
            ParallelSpecs.with_ruby_binary('bin/rspec')
          elsif ParallelSpecs.bundler_enabled?
            %w[bundle exec rspec]
          else
            ['rspec']
          end
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

        def test_suffix
          /(_spec\.rb|\.feature)$/
        end

        def line_is_result?(line)
          line =~ /\d+ examples?, \d+ failures?/
        end

        def build_test_command(file_list, options)
          [
            *executable,
            *options[:test_options],
            *color,
            *spec_opts,
            *record_runtime_formatters(options),
            *dashboard_formatter(options),
            *file_list
          ]
        end

        def command_with_seed(cmd, seed)
          [*remove_command_arguments(cmd, '--seed', '--order'), '--seed', seed]
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

        def color
          %w[--color --tty] if $stdout.tty?
        end

        def spec_opts
          options_file = ['.rspec_parallel', 'spec/parallel_spec.opts', 'spec/spec.opts'].detect { |file| File.file?(file) }
          ['-O', options_file] if options_file
        end

        def dashboard_formatter(options)
          ['--format', 'ParallelSpecs::RSpec::DashboardLogger'] if options[:dashboard]
        end

        def record_runtime_formatters(options)
          return [] unless options[:record_runtime]

          ['--format', 'progress', '--format', 'ParallelSpecs::RSpec::RuntimeLogger', '--out', (options[:runtime_log] || runtime_log)]
        end
      end
    end
  end
end
