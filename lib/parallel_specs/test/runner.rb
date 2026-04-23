# frozen_string_literal: true

require 'shellwords'
require 'parallel_specs'

module ParallelSpecs
  module Test
    class Runner
      RuntimeLogTooSmallError = Class.new(StandardError)

      class << self
        def runtime_log
          'tmp/parallel_runtime_test.log'
        end

        def test_suffix
          /_(test|spec)\.rb$/
        end

        def default_test_folder
          'test'
        end

        def test_file_name
          'test'
        end

        def run_tests(test_files, process_number, num_processes, options)
          require_list = test_files.map { |file| file.gsub(' ', '\\ ') }.join(' ')
          execute_command(build_command(require_list, options), process_number, num_processes, options)
        end

        def line_is_result?(line)
          line =~ /\d+ failure(?!:)/
        end

        def tests_in_groups(tests, num_groups, options = {})
          ParallelSpecs::Grouper.in_even_groups_by_size(tests_with_size(tests, options), num_groups)
        end

        def tests_with_size(tests, options)
          tests = find_tests(tests, options)

          case options[:group_by]
          when :found
            tests.map! { |test| [test, 1] }
          when :filesize
            sort_by_filesize(tests)
          when :runtime
            sort_by_runtime(
              tests,
              runtimes(tests, options),
              options.merge(allowed_missing: (options[:allowed_missing_percent] || 50) / 100.0)
            )
          when nil
            begin
              known_runtimes = runtimes(tests, options)
            rescue StandardError
              known_runtimes = {}
            end
            if known_runtimes.size * 1.5 > tests.size
              puts 'Using recorded test runtime' unless options[:quiet]
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
          number = test_env_number(process_number, options).to_s
          env = (options[:env] || {}).merge(
            'TEST_ENV_NUMBER' => number,
            'PARALLEL_TEST_GROUPS' => num_processes.to_s,
            'PARALLEL_PID_FILE' => ParallelSpecs.pid_file_path
          )

          if (dashboard_event_files = options[:dashboard_event_files])
            event_path = dashboard_event_files.fetch(process_number)
            env['PARALLEL_SPECS_DASHBOARD_EVENT_LOG'] = event_path
            env['PARALLEL_TESTS_DASHBOARD_EVENT_LOG'] = event_path
          end

          cmd = cmd.map { |part| part.gsub('$TEST_ENV_NUMBER', number).gsub('${TEST_ENV_NUMBER}', number) }
          print_command(cmd, env) if report_process_command?(options) && !options[:serialize_stdout]
          execute_command_and_capture_output(env, cmd, options)
        end

        def print_command(command, env)
          env_str = %w[TEST_ENV_NUMBER PARALLEL_TEST_GROUPS].map { |name| "#{name}=#{env[name]}" }.join(' ')
          puts [env_str, Shellwords.shelljoin(command)].join(' ')
        end

        def execute_command_and_capture_output(env, cmd, options)
          popen_options = {}
          popen_options[:err] = [:child, :out] if options[:combine_stderr]

          pid = nil
          output = IO.popen(env, cmd, popen_options) do |io|
            pid = io.pid
            ParallelSpecs.pids.add(pid)
            capture_output(io, env, options)
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

          seed = output[/seed (\d+)/, 1]
          if report_process_command?(options) && options[:serialize_stdout] && !options[:dashboard_runner]
            output = "#{Shellwords.shelljoin(cmd)}\n#{output}"
          end

          { env: env, stdout: output, exit_status: exit_status, command: cmd, seed: seed }
        end

        def find_results(test_output)
          test_output.lines.filter_map do |line|
            line = line.chomp.gsub(/\e\[\d+m/, '')
            line if line_is_result?(line)
          end
        end

        def test_env_number(process_number, options = {})
          process_number.zero? && !options[:first_is_1] ? '' : process_number + 1
        end

        def summarize_results(results)
          sum_up_results(results).sort.map { |word, count| "#{count} #{word}#{'s' if count != 1}" }.join(', ')
        end

        def command_with_seed(cmd, seed)
          [*remove_command_arguments(cmd, '--seed', '--order'), '--seed', seed]
        end

        protected

        def executable
          configured = ENV['PARALLEL_SPECS_EXECUTABLE'] || ENV['PARALLEL_TESTS_EXECUTABLE']
          configured ? Shellwords.shellsplit(configured) : determine_executable
        end

        def determine_executable
          ['ruby']
        end

        def build_command(file_list, options)
          build_test_command(file_list, options)
        end

        def build_test_command(file_list, options)
          [*executable, '-Itest', '-e', "%w[#{file_list}].each { |f| require %{./#{f}} }", '--', *options[:test_options]]
        end

        def sum_up_results(results)
          results.join(' ').gsub(/s\b/, '').scan(/(\d+) (\w+)/).each_with_object(Hash.new(0)) do |(number, word), sum|
            sum[word] += number.to_i
          end
        end

        def capture_output(out, env, options = {})
          result = +''
          begin
            loop do
              chunk = out.readpartial(1_000_000)
              chunk = chunk.force_encoding(Encoding.default_internal) if Encoding.default_internal
              result << chunk
              next if options[:serialize_stdout]

              message = options[:prefix_output_with_test_env_number] ? "[TEST GROUP #{env['TEST_ENV_NUMBER']}] #{chunk}" : chunk
              $stdout.print(message)
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
            if allowed_missing < 0
              log = options[:runtime_log] || runtime_log
              raise RuntimeLogTooSmallError, "Runtime log file '#{log}' does not contain sufficient data to sort #{tests.size} test files, please update or remove it."
            end
            [test, time]
          end

          puts "Runtime found for #{tests.count(&:last)} of #{tests.size} tests" if options[:verbose]
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

        def find_tests(tests, options = {})
          suffix_pattern = options[:suffix] || test_suffix
          include_pattern = options[:pattern] || //
          exclude_pattern = options[:exclude_pattern]

          (tests || []).flat_map do |file_or_folder|
            if File.directory?(file_or_folder)
              files = Dir[File.join(file_or_folder, '**{,/*/**}/*')].uniq.sort
              files = files.grep(suffix_pattern).grep(include_pattern)
              files -= files.grep(exclude_pattern) if exclude_pattern
              files
            else
              file_or_folder
            end
          end.uniq
        end

        def remove_command_arguments(command, *args)
          remove_next = false
          command.select do |arg|
            if remove_next
              remove_next = false
              false
            elsif args.include?(arg)
              remove_next = true
              false
            else
              true
            end
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

        def report_process_command?(options)
          options[:verbose] || options[:verbose_process_command]
        end
      end
    end
  end
end
