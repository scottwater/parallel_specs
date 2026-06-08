# frozen_string_literal: true

require 'json'
require 'io/console'
require 'strscan'
require 'uri'

module ParallelSpecs
  class CLI
    class Dashboard
      WorkerState = Struct.new(
        :label,
        :files_count,
        :example_total,
        :passed,
        :failed,
        :pending,
        :current_example,
        :started_at,
        :finished_at,
        :exit_status
      )

      SPINNER = ['-', '\\', '|', '/'].freeze
      PROGRESS_BAR_WIDTH = 24
      REFRESH_INTERVAL = 0.1

      attr_reader :workers

      def plain?
        @mode == :plain
      end

      def initialize(groups:, event_files:, output: $stdout, use_colors: true, mode: :interactive, now: -> { ParallelSpecs.now }, width: nil, refresh_interval: REFRESH_INTERVAL)
        @workers = groups.each_with_index.map do |group, index|
          WorkerState.new(index + 1, group.size, nil, 0, 0, 0, nil, nil, nil, nil)
        end
        @event_files = event_files
        @output = output
        @use_colors = use_colors
        @mode = mode
        @now = now
        @width = width
        @refresh_interval = refresh_interval
        @mutex = Mutex.new
        @event_offsets = Hash.new(0)
        @event_remainders = Hash.new { |hash, key| hash[key] = +"" }
        @spinner_index = 0
        @rendered_rows = 0
        @last_frame = nil
        @dirty = true
      end

      def start
        @mutex.synchronize do
          @started_at = @now.call
          render if interactive?
        end

        return unless interactive?

        @running = true
        @refresh_thread = Thread.new do
          Thread.current.report_on_exception = false if Thread.current.respond_to?(:report_on_exception=)

          begin
            while @running
              sleep @refresh_interval
              @mutex.synchronize do
                poll_once
                @spinner_index += 1
                render if @dirty
              end
            end
          rescue StandardError => e
            @running = false
            warn "parallel_specs: dashboard refresh failed while polling #{event_file_context}: #{e.class}: #{e.message}"
          end
        end
      end

      def stop
        @running = false
        @refresh_thread&.join

        @mutex.synchronize do
          begin
            poll_once
          rescue StandardError => e
            warn "parallel_specs: dashboard final poll failed while polling #{event_file_context}: #{e.class}: #{e.message}"
          end
          render
          @output.puts if interactive?
          @output.flush if @output.respond_to?(:flush)
        end
      end

      def worker_started(process_number)
        synchronize do
          worker = @workers.fetch(process_number)
          worker.started_at ||= @now.call
          @dirty = true
        end
      end

      def worker_finished(process_number, exit_status:)
        synchronize do
          worker = @workers.fetch(process_number)
          worker.started_at ||= @now.call
          worker.finished_at = @now.call
          worker.exit_status = exit_status
          @dirty = true
        end
      end

      def process_event(process_number, event)
        worker = @workers.fetch(process_number)
        worker.started_at ||= @now.call

        case event.fetch('event')
        when 'start'
          worker.example_total = event['total']
        when 'example_started'
          worker.current_example = event['example']
        when 'example_passed'
          worker.passed += 1
          worker.current_example = event['example']
        when 'example_pending'
          worker.pending += 1
          worker.current_example = event['example']
        when 'example_failed'
          worker.failed += 1
          worker.current_example = event['example']
        end

        @dirty = true
      end

      def poll_once
        @event_files.each do |process_number, path|
          next unless File.exist?(path)

          File.open(path, 'r') do |file|
            file.seek(@event_offsets[process_number])
            chunk = file.read.to_s
            @event_offsets[process_number] = file.pos
            next if chunk.empty?

            buffer = @event_remainders[process_number] << chunk
            lines = buffer.split("\n", -1)
            @event_remainders[process_number] = lines.pop.to_s

            lines.each do |line|
              next if line.empty?

              process_event(process_number, JSON.parse(line))
            end
          end
        end
      end

      def frame
        lines = if interactive?
          [header_line, *workers.map { |worker| worker_line(worker) }]
        else
          [plain_header_line, *workers.map { |worker| plain_worker_line(worker) }]
        end
        "#{lines.join("\n")}\n"
      end

      private

      def synchronize(&block)
        @mutex.synchronize(&block)
      end

      def event_file_context
        @event_files.map { |process_number, path| "worker #{process_number + 1}=#{path}" }.join(', ')
      end

      def render
        if interactive?
          render_interactive
        else
          render_plain
        end
        @dirty = false
      end

      def render_interactive
        @render_width = terminal_width
        output = frame
        rows_to_clear = [@rendered_rows, rendered_rows_for(@last_frame, @render_width)].max

        if rows_to_clear.positive?
          @output.print("\e[#{rows_to_clear}A")
          @output.print("\r\e[J")
        end
        @output.print(output)
        @output.flush if @output.respond_to?(:flush)
        @rendered_rows = rendered_rows_for(output, @render_width)
        @last_frame = output
      ensure
        @render_width = nil
      end

      def render_plain
        @output.print(frame)
        @output.flush if @output.respond_to?(:flush)
      end

      def header_line
        examples_seen = workers.sum { |worker| examples_seen_for(worker) }
        total_examples = workers.filter_map(&:example_total)
        example_summary = if total_examples.empty?
          "examples: #{examples_seen}"
        else
          summary = "examples: #{examples_seen}/#{total_examples.sum}"
          summary += ' known' unless total_examples.size == workers.size
          summary
        end

        truncate(
          [example_summary, "elapsed: #{format_duration(elapsed_seconds)}"].join(' | '),
          terminal_width
        )
      end

      def worker_line(worker)
        plain_status = status_text_for(worker)
        colored_status = colorize(plain_status.ljust(9), status_color_for(worker))
        line = format(
          "[%<label>2d] %<status>s %<bar>s %<summary>9s p:%<passed>3d f:%<failed>3d pend:%<pending>3d",
          label: worker.label,
          status: colored_status,
          bar: progress_bar_for(worker),
          summary: progress_summary_for(worker),
          passed: worker.passed,
          failed: worker.failed,
          pending: worker.pending
        )
        truncate(line, terminal_width)
      end

      def plain_header_line
        running = workers.count { |worker| status_for(worker) == :running }
        passed = workers.count { |worker| status_for(worker) == :passed }
        failed = workers.count { |worker| [:failing, :failed].include?(status_for(worker)) }
        examples_seen = workers.sum { |worker| examples_seen_for(worker) }
        total_examples = workers.filter_map(&:example_total)

        parts = [
          'dashboard',
          "workers=#{workers.size}",
          "running=#{running}",
          "passed=#{passed}",
          "failed=#{failed}",
          "examples_seen=#{examples_seen}",
          "elapsed=#{format_duration(elapsed_seconds)}"
        ]

        unless total_examples.empty?
          parts << "examples_total=#{total_examples.sum}"
          parts << "examples_known=#{total_examples.size == workers.size}"
        end

        parts.join(' ')
      end

      def plain_worker_line(worker)
        parts = [
          "worker=#{worker.label}",
          "status=#{plain_status_text_for(worker)}",
          "passed=#{worker.passed}",
          "failed=#{worker.failed}",
          "pending=#{worker.pending}",
          "current_example=#{encode_plain_value(worker.current_example.to_s)}"
        ]

        if worker.example_total
          parts << "completed=#{examples_seen_for(worker)}"
          parts << "total=#{worker.example_total}"
        else
          parts << "files=#{worker.files_count}"
        end

        parts.join(' ')
      end

      def progress_summary_for(worker)
        if worker.example_total
          format('%<completed>d/%<total>d', completed: examples_seen_for(worker), total: worker.example_total)
        else
          format('files:%<count>3d', count: worker.files_count)
        end
      end

      def progress_bar_for(worker)
        return "[#{'.' * PROGRESS_BAR_WIDTH}]" unless worker.example_total

        total = worker.example_total
        completed = [examples_seen_for(worker), total].min
        filled = if total == 0
          PROGRESS_BAR_WIDTH
        else
          [(completed.to_f / total * PROGRESS_BAR_WIDTH).round, PROGRESS_BAR_WIDTH].min
        end
        empty = PROGRESS_BAR_WIDTH - filled
        "[#{'#' * filled}#{'-' * empty}]"
      end

      def examples_seen_for(worker)
        worker.passed + worker.failed + worker.pending
      end

      def status_for(worker)
        if worker.finished_at
          if worker.failed > 0 || worker.exit_status.to_i != 0
            :failed
          else
            :passed
          end
        elsif worker.failed > 0
          :failing
        elsif worker.started_at
          :running
        else
          :queued
        end
      end

      def status_text_for(worker)
        case status_for(worker)
        when :queued then '· queued'
        when :running then "#{SPINNER[@spinner_index % SPINNER.length]} running"
        when :failing then '! failing'
        when :failed then '✗ failed'
        when :passed then '✓ passed'
        end
      end

      def plain_status_text_for(worker)
        case status_for(worker)
        when :queued then 'queued'
        when :running then 'running'
        when :failing then 'failing'
        when :failed then 'failed'
        when :passed then 'passed'
        end
      end

      def status_color_for(worker)
        case status_for(worker)
        when :queued then 90
        when :running then 33
        when :failing, :failed then 31
        when :passed then 32
        end
      end

      def encode_plain_value(value)
        URI.encode_www_form_component(value)
      end

      def colorize(text, color)
        return text unless @use_colors

        "\e[#{color}m#{text}\e[0m"
      end

      def interactive?
        @mode == :interactive
      end

      def elapsed_seconds
        return 0 unless @started_at

        (@now.call - @started_at).to_i
      end

      def format_duration(seconds)
        hours = seconds / 3600
        minutes = (seconds % 3600) / 60
        remaining_seconds = seconds % 60

        if hours > 0
          format('%<hours>d:%<minutes>02d:%<seconds>02d', hours: hours, minutes: minutes, seconds: remaining_seconds)
        else
          format('%<minutes>02d:%<seconds>02d', minutes: minutes, seconds: remaining_seconds)
        end
      end

      def terminal_width
        return @render_width if @render_width

        width = if @width.respond_to?(:call)
          @width.call
        elsif @width
          @width
        else
          console = IO.console
          console&.winsize&.last || 120
        end

        [width.to_i - 1, 1].max
      rescue StandardError
        119
      end

      def rendered_rows_for(output, width)
        return 0 if output.to_s.empty?

        output.lines.sum do |line|
          visible_width = visible_length(line.chomp)
          [((visible_width - 1) / width) + 1, 1].max
        end
      end

      def truncate(text, max_length)
        return '' if max_length <= 0
        return text if visible_length(text) <= max_length
        return '…' if max_length <= 1

        truncated = +''
        visible_count = 0
        scanner = StringScanner.new(text)

        until scanner.eos? || visible_count >= max_length - 1
          if (escape_sequence = scanner.scan(/\e\[[\d;]*m/))
            truncated << escape_sequence
          else
            truncated << scanner.getch
            visible_count += 1
          end
        end

        truncated << '…'
        truncated << "\e[0m" if text.include?("\e[")
        truncated
      end

      def visible_length(text)
        text.gsub(/\e\[[\d;]*m/, '').length
      end
    end
  end
end
