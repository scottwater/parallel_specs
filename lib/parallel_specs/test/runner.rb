# frozen_string_literal: true

require 'parallel_specs'

module ParallelSpecs
  module Test
    class Runner
      RuntimeLogTooSmallError = Class.new(StandardError)

      class << self
        def tests_in_groups(tests, num_groups, options = {})
          ParallelSpecs::Grouper.in_even_groups_by_size(tests_with_size(tests, options), num_groups)
        end

        def tests_with_size(tests, options)
          tests = find_tests(tests)

          case options[:group_by]
          when :found
            tests.map! { |test| [test, 1] }
          when :runtime
            sort_by_runtime(
              tests,
              runtimes(tests, options),
              options.merge(allowed_missing: (options[:allowed_missing_percent] || 50) / 100.0)
            )
          when :filesize
            sort_by_filesize(tests)
          when nil
            begin
              known_runtimes = runtimes(tests, options)
            rescue StandardError
              known_runtimes = {}
            end

            if known_runtimes.size * 1.5 > tests.size
              puts 'Using recorded test runtime'
              sort_by_runtime(tests, known_runtimes)
            else
              sort_by_filesize(tests)
            end
          else
            raise ArgumentError, "Unsupported option #{options[:group_by]}"
          end

          tests
        end

        def execute_command(cmd, process_number, num_processes, options)
          env = {
            'TEST_ENV_NUMBER' => test_env_number(process_number),
            'PARALLEL_TEST_GROUPS' => num_processes.to_s,
            'PARALLEL_PID_FILE' => ParallelSpecs.pid_file_path
          }

          if (dashboard_event_files = options[:dashboard_event_files])
            env['PARALLEL_SPECS_DASHBOARD_EVENT_LOG'] = dashboard_event_files.fetch(process_number)
          end

          execute_command_and_capture_output(env, cmd, options)
        end

        def execute_command_and_capture_output(env, cmd, options)
          pid = nil
          output = IO.popen(env, cmd, err: [:child, :out]) do |io|
            pid = io.pid
            ParallelSpecs.pids.add(pid)
            capture_output(io, options[:dashboard])
          end
          ParallelSpecs.pids.delete(pid) if pid

          status = $?
          exit_status = if status.exitstatus
            status.exitstatus
          elsif status.termsig
            status.termsig + 128
          else
            1
          end

          { env: env, stdout: output, exit_status: exit_status, command: cmd }
        end

        def find_results(test_output)
          test_output.lines.filter_map do |line|
            line = line.chomp.gsub(/\e\[\d+m/, '')
            line if line_is_result?(line)
          end
        end

        def summarize_results(results)
          sum_up_results(results).sort.map { |word, count| "#{count} #{word}#{'s' if count != 1}" }.join(', ')
        end

        protected

        def capture_output(out, dashboard)
          result = +''
          begin
            loop do
              chunk = out.readpartial(1_000_000)
              chunk = chunk.force_encoding(Encoding.default_internal) if Encoding.default_internal
              result << chunk
              next if dashboard

              $stdout.print(chunk)
              $stdout.flush
            end
          rescue EOFError
            nil
          end
          result
        end

        def sort_by_runtime(tests, runtimes, options = {})
          allowed_missing = tests.size * (options[:allowed_missing] || 1.0)
          tests.sort!
          tests.map! do |test|
            time = runtimes[test]
            allowed_missing -= 1 unless time
            if allowed_missing.negative?
              log = options[:runtime_log] || runtime_log
              raise RuntimeLogTooSmallError, "Runtime log file '#{log}' does not contain sufficient data to sort #{tests.size} test files, please update or remove it."
            end
            [test, time]
          end

          set_unknown_runtime(tests, options)
        end

        def runtimes(tests, options)
          File.read(options[:runtime_log] || runtime_log).split("\n").each_with_object({}) do |line, times|
            test, _, time = line.rpartition(':')
            times[test] = time.to_f if test && time && tests.include?(test)
          end
        end

        def sort_by_filesize(tests)
          tests.sort!
          tests.map! { |test| [test, File.stat(test).size] }
        end

        def find_tests(tests)
          tests.flat_map do |file_or_folder|
            if File.directory?(file_or_folder)
              Dir[File.join(file_or_folder, '**/*_spec.rb')].uniq.sort
            else
              file_or_folder
            end
          end.uniq
        end

        def test_env_number(process_number)
          process_number.zero? ? '' : (process_number + 1).to_s
        end

        def sum_up_results(results)
          results.join(' ').gsub(/s\b/, '').scan(/(\d+) (\w+)/).each_with_object(Hash.new(0)) do |(number, word), sum|
            sum[word] += number.to_i
          end
        end

        private

        def set_unknown_runtime(tests, options)
          known, unknown = tests.partition(&:last)
          return tests if unknown.empty?

          unknown_runtime = options[:unknown_runtime] || (known.empty? ? 1 : known.map!(&:last).sum / known.size)
          unknown.each { |entry| entry[1] = unknown_runtime }
          tests
        end
      end
    end
  end
end
