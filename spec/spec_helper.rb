# frozen_string_literal: true

require 'bundler/setup'
require 'fileutils'
require 'stringio'
require 'tempfile'
require 'timeout'
require 'tmpdir'

require 'parallel_specs'
require 'parallel_specs/rspec/dashboard_logger'
require 'parallel_specs/rspec/runtime_logger'

OutputLogger = Struct.new(:output) do
  def puts(value = nil)
    output << "#{value}\n"
  end

  def print(value = nil)
    output << value.to_s
  end
end

module SpecHelper
  def size_of(group)
    group.map { |test| File.stat(test).size }.sum
  end

  def use_temporary_directory(&block)
    Dir.mktmpdir { |dir| Dir.chdir(dir, &block) }
  end

  def with_files(files)
    Dir.mktmpdir do |root|
      files.each do |file|
        FileUtils.mkdir_p(File.join(root, File.dirname(file)))
        FileUtils.touch(File.join(root, file))
      end
      yield root
    end
  end

  def should_run_with(command, *args)
    expect(ParallelSpecs::Test::Runner).to receive(:execute_command) do |actual, *_rest|
      expect(actual.first(command.length)).to eq(command)
      args.each { |arg| expect(actual).to include(arg) }
    end
  end

  def should_not_run_with(arg)
    expect(ParallelSpecs::Test::Runner).to receive(:execute_command) do |actual, *_rest|
      expect(actual).not_to include(arg)
    end
  end
end

module SharedExamples
  def test_tests_in_groups(klass, suffix)
    describe '.tests_in_groups' do
      let(:log) { klass.runtime_log }
      let(:test_root) { 'temp' }

      around { |example| use_temporary_directory(&example) }

      before do
        FileUtils.mkdir_p(test_root)
        @files = (0..7).map { |index| "#{test_root}/x#{index}#{suffix}" }
        @files.each { |file| File.write(file, 'x' * 100) }
        FileUtils.mkdir_p(File.dirname(log))
      end

      def setup_runtime_log
        File.open(log, 'w') do |file|
          @files[1..].each { |path| file.puts "#{path}:#{@files.index(path)}" }
          file.puts "#{@files[0]}:10"
        end
      end

      it 'partitions them into groups by equal size' do
        groups = klass.tests_in_groups([test_root], 2)
        expect(groups.map { |group| size_of(group) }).to eq([400, 400])
      end

      it 'partitions by runtime when runtime data is available' do
        allow(klass).to receive(:puts)
        setup_runtime_log

        groups = klass.tests_in_groups([test_root], 2)
        expect(groups[0]).to eq([@files[0], @files[1], @files[3], @files[5]])
        expect(groups[1]).to eq([@files[2], @files[4], @files[6], @files[7]])
      end

      it 'uses round-robin grouping when grouped by found order' do
        expect(klass).to receive(:find_tests).and_return(%w[file1.rb file2.rb file3.rb file4.rb])
        groups = klass.tests_in_groups(%w[file1.rb file2.rb file3.rb file4.rb], 2, group_by: :found)
        expect(groups).to eq([%w[file1.rb file3.rb], %w[file2.rb file4.rb]])
      end
    end
  end
end

RSpec::Matchers.define :include_exactly_times do |expected, times|
  match { |actual| actual.scan(expected).size == times }
end

TestTookTooLong = Class.new(Timeout::Error)

RSpec.configure do |config|
  config.include SpecHelper
  config.extend SharedExamples

  config.around do |example|
    Timeout.timeout(30, TestTookTooLong, &example)
  end

  config.after do
    %w[
      CI
      DISABLE_SPRING
      PARALLEL_PID_FILE
      PARALLEL_SPECS_DASHBOARD_EVENT_LOG
      PARALLEL_SPECS_DASHBOARD_MODE
      PARALLEL_SPECS_EXECUTABLE
      PARALLEL_TESTS_DASHBOARD_EVENT_LOG
      PARALLEL_TESTS_DASHBOARD_MODE
      PARALLEL_TESTS_EXECUTABLE
      PARALLEL_TEST_FIRST_IS_1
      PARALLEL_TEST_GROUPS
      PARALLEL_TEST_HEARTBEAT_INTERVAL
      PARALLEL_TEST_MULTIPLY_PROCESSES
      PARALLEL_TEST_PROCESSORS
      TEST_ENV_NUMBER
    ].each { |name| ENV.delete(name) }
  end
end
