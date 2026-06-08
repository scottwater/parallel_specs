# frozen_string_literal: true

require 'optparse'
require 'fileutils'
require 'pathname'
require 'shellwords'
require 'tmpdir'

require 'parallel_specs'
require 'parallel_specs/cli/dashboard'
require 'parallel_specs/rspec/runner'

module ParallelSpecs
  class CLI
    DEFAULT_RERUN_COMMAND_SPEC_FILE_LIMIT = 25
    DEFAULT_RERUN_COMMAND_CHAR_LIMIT = 2_000

    def initialize
      @runner = ParallelSpecs::RSpec::Runner
    end

    def run(argv)
      Signal.trap('INT') { handle_interrupt }

      options = parse_options!(argv)
      ENV['DISABLE_SPRING'] ||= '1'

      num_processes = ParallelSpecs.determine_number_of_processes(options[:count])
      abort 'Process count must be greater than 0' unless num_processes.positive?

      run_tests_in_parallel(num_processes, options)
    end

    private

    def handle_interrupt
      @graceful_shutdown_attempted ||= false
      Kernel.exit if @graceful_shutdown_attempted

      @graceful_shutdown_attempted = true
      Thread.new do
        case interrupt_action
        when :stop_workers
          Kernel.exit unless ParallelSpecs.stop_all_processes
        when :wait_for_process_group_interrupt
          # Terminal Ctrl-C is delivered to the whole foreground process group.
          # In that case workers have already seen SIGINT, so avoid sending a
          # second signal that could escalate RSpec from graceful shutdown to
          # immediate termination.
          nil
        when :exit
          Kernel.exit
        else
          Kernel.exit
        end
      end
    end

    def interrupt_action
      return :exit unless ParallelSpecs.pid_file_available?
      tracked_pids = ParallelSpecs.pids.all
      return :exit if tracked_pids.empty?
      return :stop_workers if Gem.win_platform?

      child_pid = tracked_pids.first
      child_process_group = Process.getpgid(child_pid)
      return :stop_workers unless child_process_group == Process.getpgrp

      terminal_signal_reaches_process_group? ? :wait_for_process_group_interrupt : :stop_workers
    rescue Errno::ESRCH, Errno::EPERM
      :stop_workers
    rescue KeyError
      :exit
    end

    def terminal_signal_reaches_process_group?
      $stdout.tty?
    end

    def run_tests_in_parallel(num_processes, options)
      test_results = nil
      @runtime_log_merge_failed = false

      runner = lambda do
        groups = @runner.tests_in_groups(options[:files], num_processes, options)
        groups.reject!(&:empty?)

        with_runtime_log_files(groups, options) do
          if groups.empty?
            report_number_of_tests(groups)
            test_results = []
            report_results(test_results)
            false
          else
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
              report_failure_rerun_commands(test_results)
              runtime_log_mergeable?(test_results)
            end
          end
        end
      end

      report_time_taken(&runner)
      if any_test_failed?(test_results) || @runtime_log_merge_failed || @graceful_shutdown_attempted
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
            ParallelSpecs.stop_all_processes if options[:fail_fast] && !result[:exit_status].zero?
            result
          end
        end
      end
    end

    def with_runtime_log_files(groups, options)
      return yield unless options[:record_runtime]

      runtime_log = options[:runtime_log] || @runner.runtime_log
      should_merge_runtime_logs = false

      Dir.mktmpdir('parallel_specs-runtime') do |dir|
        runtime_log_files = groups.each_index.to_h do |index|
          [index, File.join(dir, "worker-#{index + 1}.log")]
        end

        options[:runtime_log_files] = runtime_log_files
        should_merge_runtime_logs = yield
      ensure
        if runtime_log_files && should_merge_runtime_logs
          @runtime_log_merge_failed = true unless merge_runtime_logs(runtime_log_files, runtime_log)
        elsif runtime_log_files
          warn "parallel_specs: not updating runtime log #{runtime_log}; run did not complete successfully"
        end
        options.delete(:runtime_log_files)
      end
    end

    def merge_runtime_logs(runtime_log_files, runtime_log)
      if runtime_log_files.empty?
        warn "parallel_specs: not updating runtime log #{runtime_log}; no worker runtime logs were produced"
        return false
      end

      missing_logs = runtime_log_files.values.reject { |path| File.file?(path) }
      unless missing_logs.empty?
        warn "parallel_specs: not updating runtime log #{runtime_log}; missing worker runtime logs: #{missing_logs.join(', ')}"
        return false
      end

      FileUtils.mkdir_p(File.dirname(runtime_log))
      temporary_runtime_log = "#{runtime_log}.#{Process.pid}.tmp"
      File.open(temporary_runtime_log, 'w') do |output|
        runtime_log_files.each_value do |path|
          File.foreach(path) { |line| output.write(line) }
        end
      end
      FileUtils.mv(temporary_runtime_log, runtime_log)
      true
    ensure
      FileUtils.rm_f(temporary_runtime_log) if temporary_runtime_log && File.exist?(temporary_runtime_log)
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

    def report_failure_rerun_commands(test_results)
      failures = test_results.reject { |result| result[:exit_status].zero? }
      return if failures.empty?

      rerun_commands = failures.map do |result|
        { result: result, command: @runner.rerun_command(result[:command], seed: result[:seed]) }
      end

      if print_full_rerun_commands?(rerun_commands)
        puts "\nRerun failed worker commands:\n"
        rerun_commands.each do |entry|
          @runner.print_command(entry[:command], entry[:result][:env] || {})
        end
      else
        report_failure_rerun_command_summary(rerun_commands)
      end
    end

    def print_full_rerun_commands?(rerun_commands)
      return true if truthy_env?('PARALLEL_SPECS_FULL_RERUN_COMMANDS')

      rerun_commands.all? do |entry|
        rerun_command_spec_file_count(entry[:command]) <= rerun_command_spec_file_limit &&
          rerun_command_length(entry[:command], entry[:result][:env] || {}) <= rerun_command_char_limit
      end
    end

    def report_failure_rerun_command_summary(rerun_commands)
      total_spec_files = rerun_commands.sum { |entry| rerun_command_spec_file_count(entry[:command]) }

      puts "\nFull worker rerun commands omitted to keep failure output readable."
      puts "#{pluralize(rerun_commands.size, 'failed worker')} included #{pluralize(total_spec_files, @runner.test_file_name)}."
      puts 'RSpec failure output above includes failed example locations.'
      puts 'Set PARALLEL_SPECS_FULL_RERUN_COMMANDS=1 to print full worker rerun commands.'

      rerun_commands.each do |entry|
        result = entry[:result]
        worker_label = result.dig(:env, 'TEST_ENV_NUMBER')
        worker_label = '1' if worker_label.to_s.empty?
        seed = result[:seed] ? ", seed #{result[:seed]}" : ''
        puts "worker #{worker_label}: #{pluralize(rerun_command_spec_file_count(entry[:command]), @runner.test_file_name)}#{seed}"
      end
    end

    def rerun_command_spec_file_count(command)
      command.count { |arg| arg.end_with?('_spec.rb') }
    end

    def rerun_command_length(command, env)
      rerun_env = env.slice('TEST_ENV_NUMBER', 'PARALLEL_SPECS_GROUPS').reject { |_key, value| value.to_s.empty? }
      env_string = rerun_env.map { |key, value| "#{key}=#{Shellwords.escape(value)}" }.join(' ')
      [env_string, Shellwords.shelljoin(command)].reject(&:empty?).join(' ').length
    end

    def rerun_command_spec_file_limit
      positive_integer_env('PARALLEL_SPECS_RERUN_COMMAND_SPEC_FILE_LIMIT') || DEFAULT_RERUN_COMMAND_SPEC_FILE_LIMIT
    end

    def rerun_command_char_limit
      positive_integer_env('PARALLEL_SPECS_RERUN_COMMAND_CHAR_LIMIT') || DEFAULT_RERUN_COMMAND_CHAR_LIMIT
    end

    def positive_integer_env(name)
      Integer(ENV.fetch(name, nil)).then { |value| value.positive? ? value : nil }
    rescue ArgumentError, TypeError
      nil
    end

    def truthy_env?(name)
      %w[1 true yes].include?(ENV.fetch(name, '').downcase)
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

    def runtime_log_mergeable?(test_results)
      !@graceful_shutdown_attempted && test_results && !test_results.empty? && test_results.all? { |result| result[:exit_status].zero? }
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
        opts.on('--pattern PATTERN', 'Only run spec files matching PATTERN') { |pattern| options[:pattern] = Regexp.new(pattern) }
        opts.on('--exclude-pattern PATTERN', 'Skip spec files matching PATTERN') { |pattern| options[:exclude_pattern] = Regexp.new(pattern) }
        opts.on('--runtime-log PATH', 'Read spec runtimes from PATH; with --record-runtime, write the completed run there') { |path| options[:runtime_log] = path }
        opts.on('--allowed-missing COUNT', Integer, 'Allowed percentage of missing runtimes (default = 50)') { |percent| options[:allowed_missing_percent] = percent }
        opts.on('--unknown-runtime SECONDS', Float, 'Use given number as unknown runtime (otherwise use average time)') { |time| options[:unknown_runtime] = time }
        opts.on('--record-runtime', 'Record runtimes and replace the runtime log only after a successful complete run') { options[:record_runtime] = true }
        opts.on('--fail-fast', 'Stop remaining workers after one worker fails') { options[:fail_fast] = true }
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
      return yield unless simulate

      progress_indicator = Thread.new do
        interval = Float(ENV['PARALLEL_SPECS_HEARTBEAT_INTERVAL'] || 60)
        loop do
          sleep interval
          $stdout.print '.'
          $stdout.flush
        end
      end

      yield
    ensure
      progress_indicator&.exit
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
