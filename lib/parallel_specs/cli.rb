# frozen_string_literal: true

require 'optparse'
require 'pathname'
require 'shellwords'
require 'tempfile'
require 'tmpdir'

require 'parallel_specs'
require 'parallel_specs/cli/dashboard'
require 'parallel_specs/rspec/runner'

module ParallelSpecs
  class CLI
    def initialize
      @runner = ParallelSpecs::RSpec::Runner
    end

    def run(argv)
      Signal.trap('INT') { handle_interrupt }

      options = parse_options!(argv)
      ENV['DISABLE_SPRING'] ||= '1'
      options[:first_is_1] ||= first_is_1?

      num_processes = ParallelSpecs.determine_number_of_processes(options[:count])
      num_processes = (num_processes * ParallelSpecs.determine_multiple(options[:multiply_processes])).round

      run_tests_in_parallel(num_processes, options)
    end

    private

    def handle_interrupt
      @graceful_shutdown_attempted ||= false
      Kernel.exit if @graceful_shutdown_attempted

      Thread.new do
        if Gem.win_platform? || ((child_pid = ParallelSpecs.pids.all.first) && Process.getpgid(child_pid) != Process.pid)
          ParallelSpecs.stop_all_processes
        end
      end

      @graceful_shutdown_attempted = true
    end

    def run_tests_in_parallel(num_processes, options)
      test_results = nil

      runner = lambda do
        groups = @runner.tests_in_groups(options[:files], num_processes, options)
        groups.reject!(&:empty?)

        with_dashboard(groups, options) do |dashboard|
          report_number_of_tests(groups) unless options[:quiet] || dashboard

          dashboard&.start
          begin
            test_results = execute_in_parallel(groups, groups.size, options) do |group, index|
              @runner.run_tests(group, index, num_processes, options)
            end
          ensure
            dashboard&.stop
          end

          report_dashboard_process_commands(test_results, options) if dashboard
          report_results(test_results, options) unless options[:quiet]
          report_dashboard_failures(test_results) if dashboard
        end
      end

      options[:quiet] ? runner.call : report_time_taken(&runner)

      return unless any_test_failed?(test_results)

      warn final_fail_message
      exit(
        if options[:failure_exit_code]
          options[:failure_exit_code]
        elsif options[:highest_exit_status]
          test_results.map { |data| data.fetch(:exit_status) }.max
        else
          1
        end
      )
    end

    def execute_in_parallel(items, num_processes, options)
      Tempfile.open('parallel_specs-lock') do |lock|
        ParallelSpecs.with_pid_file do
          simulate_output_for_ci(serialize_stdout_heartbeat?(options)) do
            Parallel.map_with_index(items, in_threads: num_processes) do |item, index|
              options[:dashboard_runner]&.worker_started(index)
              result = yield(item, index)
              options[:dashboard_runner]&.worker_finished(index, exit_status: result[:exit_status])
              reprint_output(result, lock.path) if options[:serialize_stdout] && !options[:dashboard_runner]
              ParallelSpecs.stop_all_processes if options[:fail_fast] && result[:exit_status] != 0
              result
            end
          end
        end
      end
    end

    def reprint_output(result, lockfile)
      lock(lockfile) do
        $stdout.puts
        $stdout.puts result[:stdout]
        $stdout.flush
      end
    end

    def with_dashboard(groups, options)
      return yield unless options[:dashboard]

      Dir.mktmpdir('parallel_specs-dashboard') do |dir|
        event_files = groups.each_index.to_h do |index|
          path = File.join(dir, "worker-#{index + 1}.jsonl")
          File.write(path, '')
          [index, path]
        end

        mode = dashboard_mode
        options[:dashboard_event_files] = event_files
        options[:dashboard_runner] = ParallelSpecs::CLI::Dashboard.new(
          groups: groups,
          event_files: event_files,
          mode: mode,
          use_colors: mode == :interactive && use_colors?
        )
        options[:dashboard_serialize_stdout_was] = options[:serialize_stdout]
        options[:serialize_stdout] = true

        yield options[:dashboard_runner]
      ensure
        options[:serialize_stdout] = options.delete(:dashboard_serialize_stdout_was)
        options.delete(:dashboard_event_files)
        options.delete(:dashboard_runner)
      end
    end

    def lock(lockfile)
      File.open(lockfile) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    end

    def report_results(test_results, options)
      results = @runner.find_results(test_results.map { |result| result[:stdout] }.join)
      puts
      puts @runner.summarize_results(results)
      report_failure_rerun_command(test_results, options)
    end

    def report_dashboard_process_commands(test_results, options)
      return unless options[:verbose] || options[:verbose_process_command]

      puts "\nCommands executed by each worker:\n\n"
      test_results.each do |result|
        @runner.print_command(result[:command], result[:env] || {})
      end
    end

    def report_dashboard_failures(test_results)
      failures = test_results.reject { |result| result[:exit_status] == 0 }
      return if failures.empty?

      puts "\nFailed worker output:\n"
      failures.each do |result|
        worker_label = result.dig(:env, 'TEST_ENV_NUMBER')
        worker_label = '1' if worker_label.to_s.empty?
        puts "--- worker #{worker_label} ---"
        puts result[:stdout]
      end
    end

    def report_failure_rerun_command(test_results, options)
      failures = test_results.reject { |result| result[:exit_status] == 0 }
      return if failures.empty?
      return unless options[:verbose] || options[:verbose_rerun_command]

      puts "\n\nTests failed for a worker. Re-run with:\n\n"
      failures.each do |result|
        command = result[:command]
        command = @runner.command_with_seed(command, result[:seed]) if result[:seed]
        @runner.print_command(command, result[:env] || {})
      end
    end

    def report_number_of_tests(groups)
      num_processes = groups.size
      num_tests = groups.map(&:size).sum
      tests_per_process = num_processes.zero? ? 0 : num_tests / num_processes
      puts "#{pluralize(num_processes, 'process')} for #{pluralize(num_tests, @runner.test_file_name)}, ~ #{pluralize(tests_per_process, @runner.test_file_name)} per process"
    end

    def any_test_failed?(test_results)
      test_results.any? { |result| result[:exit_status] != 0 }
    end

    def parse_options!(argv)
      newline_padding = 33
      options = { dashboard: true }

      OptionParser.new do |opts|
        opts.banner = <<~BANNER
          Run RSpec files in parallel with a dashboard locally and plain text output in CI.

          [optional] Only selected files & folders:
            parallel_specs spec/models spec/services

          [optional] Pass rspec options and files via `--`:
            parallel_specs -- --tag ~type:system -- spec/models

          Options are:
        BANNER

        opts.on('-n PROCESSES', Integer, 'How many processes to use, default: available CPUs') { |n| options[:count] = n }
        opts.on('-m COUNT', '--multiply-processes COUNT', Float, 'Use given number as a multiplier of processes to run') { |m| options[:multiply_processes] = m }
        opts.on('-o', '--test-options OPTIONS', 'Pass these options to rspec') { |arg| options[:test_options] = Shellwords.shellsplit(arg) }
        opts.on('-p', '--pattern PATTERN', 'Run specs matching this regex pattern') { |pattern| options[:pattern] = /#{pattern}/ }
        opts.on('--exclude-pattern PATTERN', 'Exclude specs matching this regex pattern') { |pattern| options[:exclude_pattern] = /#{pattern}/ }
        opts.on('--group-by TYPE', heredoc(<<~TEXT, newline_padding)) { |type| options[:group_by] = type.to_sym }
          group specs by:
          found - order of finding files
          filesize - by size of the file
          runtime - info from runtime log
          default - runtime when runtime log is filled otherwise filesize
        TEXT
        opts.on('--runtime-log PATH', 'Location of previously recorded spec runtimes') { |path| options[:runtime_log] = path }
        opts.on('--allowed-missing COUNT', Integer, 'Allowed percentage of missing runtimes (default = 50)') { |percent| options[:allowed_missing_percent] = percent }
        opts.on('--unknown-runtime SECONDS', Float, 'Use given number as unknown runtime (otherwise use average time)') { |time| options[:unknown_runtime] = time }
        opts.on('--record-runtime', 'Run with the runtime logger and write tmp/parallel_runtime_rspec.log') { options[:record_runtime] = true }
        opts.on('--serialize-stdout', 'Serialize stdout output, nothing will be written until a worker is done') { options[:serialize_stdout] = true }
        opts.on('--combine-stderr', 'Combine stderr into stdout, useful with --serialize-stdout') { options[:combine_stderr] = true }
        opts.on('--[no-]dashboard', 'Show the dashboard locally and a plain summary in CI (default: on)') { |value| options[:dashboard] = value }
        opts.on('--first-is-1', 'Use 1 as TEST_ENV_NUMBER for the first process') { options[:first_is_1] = true }
        opts.on('--fail-fast', 'Stop all groups when one group fails') { options[:fail_fast] = true }
        opts.on('--highest-exit-status', 'Exit with the highest exit status provided by spec run(s)') { options[:highest_exit_status] = true }
        opts.on('--failure-exit-code INT', Integer, 'Specify the exit code to use when specs fail') { |code| options[:failure_exit_code] = code }
        opts.on('--verbose', 'Print debug output') { options[:verbose] = true }
        opts.on('--verbose-command', 'Combines --verbose-process-command and --verbose-rerun-command') { options.merge!(verbose_process_command: true, verbose_rerun_command: true) }
        opts.on('--verbose-process-command', 'Print the command executed by each worker before it begins') { options[:verbose_process_command] = true }
        opts.on('--verbose-rerun-command', 'After a worker fails, print the command executed by that worker') { options[:verbose_rerun_command] = true }
        opts.on('--quiet', 'Print only spec output') { options[:quiet] = true }
        opts.on('-v', '--version', 'Show version') { puts ParallelSpecs::VERSION; exit 0 }
        opts.on('-h', '--help', 'Show this help') { puts opts; exit 0 }
      end.parse!(argv)

      raise 'Both options are mutually exclusive: verbose & quiet' if options[:verbose] && options[:quiet]
      raise "Can't pass --failure-exit-code and --highest-exit-status" if options[:failure_exit_code] && options[:highest_exit_status]

      options[:dashboard] = false if options[:record_runtime]

      files, remaining = extract_file_paths(argv)
      files = [@runner.default_test_folder] if files.empty?
      options[:files] = files.map { |file_path| Pathname.new(file_path).cleanpath.to_s }
      append_test_options(options, remaining)
      options
    end

    def extract_file_paths(argv)
      dash_index = argv.rindex('--')
      file_args_at = (dash_index || -1) + 1
      [argv[file_args_at..], argv[0...(dash_index || 0)]]
    end

    def extract_test_options(argv)
      dash_index = argv.index('--') || -1
      argv[dash_index + 1..]
    end

    def append_test_options(options, argv)
      new_opts = extract_test_options(argv)
      return if new_opts.empty?

      options[:test_options] ||= []
      options[:test_options].concat(new_opts)
    end

    def report_time_taken(&block)
      seconds = ParallelSpecs.delta(&block).to_i
      puts "\nTook #{pluralize(seconds, 'second')}#{detailed_duration(seconds)}"
    end

    def detailed_duration(seconds)
      parts = [seconds / 3600, (seconds % 3600) / 60, seconds % 60].drop_while(&:zero?)
      return if parts.size < 2

      " (#{parts.map { |part| format('%02d', part) }.join(':').sub(/^0/, '')})"
    end

    def serialize_stdout_heartbeat?(options)
      return false unless options[:serialize_stdout]
      return true unless (dashboard = options[:dashboard_runner])

      dashboard.plain?
    end

    def final_fail_message
      message = 'Specs Failed'
      use_colors? ? "\e[31m#{message}\e[0m" : message
    end

    def use_colors?
      $stdout.tty?
    end

    def dashboard_mode
      override = ENV['PARALLEL_SPECS_DASHBOARD_MODE'] || ENV['PARALLEL_TESTS_DASHBOARD_MODE']
      return override.to_sym if %w[interactive plain].include?(override)

      if ENV['CI'] || !$stdout.tty?
        :plain
      else
        :interactive
      end
    end

    def first_is_1?
      %w[1 true].include?(ENV['PARALLEL_TEST_FIRST_IS_1'])
    end

    def simulate_output_for_ci(simulate)
      if simulate
        progress_indicator = Thread.new do
          interval = Float(ENV['PARALLEL_TEST_HEARTBEAT_INTERVAL'] || 60)
          loop do
            sleep interval
            print '.'
          end
        end
        result = yield
        progress_indicator.exit
        result
      else
        yield
      end
    end

    def heredoc(text, newline_padding)
      text.rstrip.gsub("\n", "\n#{' ' * newline_padding}")
    end

    def pluralize(number, singular)
      return "1 #{singular}" if number == 1
      return "#{number} #{singular}es" if singular.end_with?('s', 'sh', 'ch', 'x', 'z')

      "#{number} #{singular}s"
    end
  end
end
