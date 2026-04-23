# frozen_string_literal: true

require 'optparse'
require 'pathname'
require 'shellwords'
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

      num_processes = ParallelSpecs.determine_number_of_processes(options[:count])
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
          report_number_of_tests(groups) unless dashboard

          dashboard&.start
          begin
            test_results = execute_in_parallel(groups, groups.size, options) do |group, index|
              @runner.run_tests(group, index, num_processes, options)
            end
          ensure
            dashboard&.stop
          end

          report_results(test_results)
          report_dashboard_failures(test_results) if dashboard
        end
      end

      report_time_taken(&runner)
      if any_test_failed?(test_results)
        warn final_fail_message
        exit 1
      end
    end

    def execute_in_parallel(items, num_processes, options)
      ParallelSpecs.with_pid_file do
        simulate_output_for_ci(plain_dashboard?(options)) do
          Parallel.map_with_index(items, in_threads: num_processes) do |item, index|
            options[:dashboard_runner]&.worker_started(index)
            result = yield(item, index)
            options[:dashboard_runner]&.worker_finished(index, exit_status: result[:exit_status])
            result
          end
        end
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

        options[:dashboard_event_files] = event_files
        options[:dashboard_runner] = ParallelSpecs::CLI::Dashboard.new(
          groups: groups,
          event_files: event_files,
          mode: dashboard_mode,
          use_colors: use_colors?
        )

        yield options[:dashboard_runner]
      ensure
        options.delete(:dashboard_event_files)
        options.delete(:dashboard_runner)
      end
    end

    def report_results(test_results)
      results = @runner.find_results(test_results.map { |result| result[:stdout] }.join)
      puts
      puts @runner.summarize_results(results)
    end

    def report_dashboard_failures(test_results)
      failures = test_results.reject { |result| result[:exit_status].zero? }
      return if failures.empty?

      puts "\nFailed worker output:\n"
      failures.each do |result|
        worker_label = result.dig(:env, 'TEST_ENV_NUMBER')
        worker_label = '1' if worker_label.to_s.empty?
        puts "--- worker #{worker_label} ---"
        puts result[:stdout]
      end
    end

    def report_number_of_tests(groups)
      num_processes = groups.size
      num_tests = groups.map(&:size).sum
      tests_per_process = num_processes.zero? ? 0 : num_tests / num_processes
      puts "#{pluralize(num_processes, 'process')} for #{pluralize(num_tests, @runner.test_file_name)}, ~ #{pluralize(tests_per_process, @runner.test_file_name)} per process"
    end

    def any_test_failed?(test_results)
      test_results.any? { |result| !result[:exit_status].zero? }
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
        opts.on('-o', '--test-options OPTIONS', 'Pass these options to rspec') { |arg| options[:test_options] = Shellwords.shellsplit(arg) }
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
        opts.on('-v', '--version', 'Show version') { puts ParallelSpecs::VERSION; exit 0 }
        opts.on('-h', '--help', 'Show this help') { puts opts; exit 0 }
      end.parse!(argv)

      options[:dashboard] = !options[:record_runtime]

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

    def final_fail_message
      message = 'Specs Failed'
      use_colors? ? "\e[31m#{message}\e[0m" : message
    end

    def use_colors?
      $stdout.tty?
    end

    def plain_dashboard?(options)
      options[:dashboard_runner]&.plain?
    end

    def dashboard_mode
      override = ENV['PARALLEL_SPECS_DASHBOARD_MODE']
      return override.to_sym if %w[interactive plain].include?(override)

      if ENV['CI'] || !$stdout.tty?
        :plain
      else
        :interactive
      end
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
