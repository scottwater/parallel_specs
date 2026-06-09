# frozen_string_literal: true

require 'parallel_specs'
require 'rake'
require 'shellwords'

module ParallelSpecs
  module Tasks
    class << self
      def rails_env
        ENV['PARALLEL_SPECS_RAILS_ENV'] || 'test'
      end

      def run_in_parallel(command, options = {})
        command = command.compact
        num_processes = task_process_count(options[:count])

        thread_count = options[:non_parallel] ? 1 : num_processes
        results = Parallel.map(0...num_processes, in_threads: thread_count) do |process_number|
          env = worker_env(process_number, num_processes)
          expanded_command = expand_worker_env(command, env)
          run_command(env, expanded_command)
        end

        abort unless results.all?
      end

      def run_command(env, command)
        system(env, *command)
      end

      def worker_env(process_number, num_processes)
        {
          'TEST_ENV_NUMBER' => test_env_number(process_number),
          'PARALLEL_SPECS_GROUPS' => num_processes.to_s,
          'DISABLE_SPRING' => '1'
        }
      end

      def test_env_number(process_number)
        process_number.zero? ? '' : (process_number + 1).to_s
      end

      def suppress_output(command, ignore_regex)
        command.compact!
        activate_pipefail = 'set -o pipefail'
        remove_ignored_lines = %{(grep -v #{Shellwords.escape(ignore_regex)} || true)}

        if system('/bin/bash', '-c', "#{activate_pipefail} 2>/dev/null")
          shell_command = "#{activate_pipefail} && (#{Shellwords.shelljoin(command)}) | #{remove_ignored_lines}"
          ['/bin/bash', '-c', shell_command]
        else
          command
        end
      end

      def suppress_schema_load_output(command)
        suppress_output(command, '^   ->\\|^-- ')
      end

      def check_for_pending_migrations
        %w[db:abort_if_pending_migrations app:db:abort_if_pending_migrations].each do |task_name|
          if Rake::Task.task_defined?(task_name)
            Rake::Task[task_name].invoke
            break
          end
        end
      end

      def purge_before_load
        return unless defined?(ActiveRecord) && ActiveRecord.version > Gem::Version.new('4.2.0')

        Rake::Task.task_defined?('db:purge') ? 'db:purge' : 'app:db:purge'
      end

      def schema_format_based_on_rails_version
        if active_record_7_or_greater?
          ActiveRecord.schema_format
        else
          ActiveRecord::Base.schema_format
        end
      end

      def schema_type_based_on_rails_version
        if active_record_61_or_greater? || schema_format_based_on_rails_version == :ruby
          'schema'
        else
          'structure'
        end
      end

      def configured_databases
        return [] unless defined?(ActiveRecord) && active_record_61_or_greater?

        @configured_databases ||= ActiveRecord::Tasks::DatabaseTasks.setup_initial_database_yaml
      end

      def for_each_database(&block)
        block&.call(nil)
        return unless defined?(ActiveRecord::Tasks::DatabaseTasks)
        return unless ActiveRecord::Tasks::DatabaseTasks.respond_to?(:for_each)

        ActiveRecord::Tasks::DatabaseTasks.for_each(configured_databases) do |name|
          block&.call(name)
        end
      end

      def define_task_unless_defined(task_name, *args, &block)
        return if Rake::Task.task_defined?("parallel:#{task_name}")

        Rake::Task.define_task(task_name.to_sym, *args, &block)
      end

      private

      def task_process_count(count)
        num_processes = ParallelSpecs.determine_number_of_processes(count)
        abort 'Process count must be greater than 0' unless num_processes.positive?

        num_processes
      end

      def expand_worker_env(command, env)
        command.map do |part|
          part.gsub('$TEST_ENV_NUMBER', env['TEST_ENV_NUMBER'])
            .gsub('${TEST_ENV_NUMBER}', env['TEST_ENV_NUMBER'])
        end
      end

      def active_record_7_or_greater?
        ActiveRecord.version >= Gem::Version.new('7.0')
      end

      def active_record_61_or_greater?
        ActiveRecord.version >= Gem::Version.new('6.1.0')
      end
    end
  end
end

namespace :parallel do
  desc 'Setup test databases via db:setup --> parallel:setup[num_cpus]'
  ParallelSpecs::Tasks.define_task_unless_defined(:setup, :count) do |_, args|
    command = [$PROGRAM_NAME, 'db:setup', "RAILS_ENV=#{ParallelSpecs::Tasks.rails_env}"]
    ParallelSpecs::Tasks.run_in_parallel(ParallelSpecs::Tasks.suppress_schema_load_output(command), args)
  end

  ParallelSpecs::Tasks.for_each_database do |name|
    task_name = 'create'
    task_name += ":#{name}" if name

    desc "Create test#{" #{name}" if name} database via db:#{task_name} --> parallel:#{task_name}[num_cpus]"
    ParallelSpecs::Tasks.define_task_unless_defined(task_name, :count) do |_, args|
      ParallelSpecs::Tasks.run_in_parallel(
        [$PROGRAM_NAME, "db:#{task_name}", "RAILS_ENV=#{ParallelSpecs::Tasks.rails_env}"],
        args
      )
    end
  end

  ParallelSpecs::Tasks.for_each_database do |name|
    task_name = 'drop'
    task_name += ":#{name}" if name

    desc "Drop test#{" #{name}" if name} database via db:#{task_name} --> parallel:#{task_name}[num_cpus]"
    ParallelSpecs::Tasks.define_task_unless_defined(task_name, :count) do |_, args|
      ParallelSpecs::Tasks.run_in_parallel(
        [
          $PROGRAM_NAME,
          "db:#{task_name}",
          "RAILS_ENV=#{ParallelSpecs::Tasks.rails_env}",
          'DISABLE_DATABASE_ENVIRONMENT_CHECK=1'
        ],
        args
      )
    end
  end

  desc 'Update test databases by dumping and loading --> parallel:prepare[num_cpus]'
  ParallelSpecs::Tasks.define_task_unless_defined(:prepare, :count) do |_, args|
    ParallelSpecs::Tasks.check_for_pending_migrations

    if defined?(ActiveRecord) && [:ruby, :sql].include?(ParallelSpecs::Tasks.schema_format_based_on_rails_version)
      type = ParallelSpecs::Tasks.schema_type_based_on_rails_version
      Rake::Task["db:#{type}:dump"].invoke
      ActiveRecord::Base.remove_connection if ActiveRecord::Base.configurations.any?
      Rake::Task["parallel:load_#{type}"].invoke(args[:count])
    else
      task_name = Rake::Task.task_defined?('db:test:prepare') ? 'db:test:prepare' : 'app:db:test:prepare'
      ParallelSpecs::Tasks.run_in_parallel([$PROGRAM_NAME, task_name], args.to_hash.merge(non_parallel: true))
    end
  end

  ParallelSpecs::Tasks.for_each_database do |name|
    task_name = 'migrate'
    task_name += ":#{name}" if name

    desc "Update test#{" #{name}" if name} database via db:#{task_name} --> parallel:#{task_name}[num_cpus]"
    ParallelSpecs::Tasks.define_task_unless_defined(task_name, :count) do |_, args|
      ParallelSpecs::Tasks.run_in_parallel(
        [$PROGRAM_NAME, "db:#{task_name}", "RAILS_ENV=#{ParallelSpecs::Tasks.rails_env}"],
        args
      )
    end
  end

  desc 'Rollback test databases via db:rollback --> parallel:rollback[num_cpus]'
  ParallelSpecs::Tasks.define_task_unless_defined(:rollback, :count) do |_, args|
    ParallelSpecs::Tasks.run_in_parallel(
      [$PROGRAM_NAME, 'db:rollback', "RAILS_ENV=#{ParallelSpecs::Tasks.rails_env}"],
      args
    )
  end

  ParallelSpecs::Tasks.for_each_database do |name|
    rails_task = 'db:schema:load'
    rails_task += ":#{name}" if name

    task_name = 'load_schema'
    task_name += ":#{name}" if name

    desc "Load dumped schema for test#{" #{name}" if name} database via #{rails_task} --> parallel:#{task_name}[num_cpus]"
    ParallelSpecs::Tasks.define_task_unless_defined(task_name, :count) do |_, args|
      command = [
        $PROGRAM_NAME,
        ParallelSpecs::Tasks.purge_before_load,
        rails_task,
        "RAILS_ENV=#{ParallelSpecs::Tasks.rails_env}",
        'DISABLE_DATABASE_ENVIRONMENT_CHECK=1'
      ]
      ParallelSpecs::Tasks.run_in_parallel(ParallelSpecs::Tasks.suppress_schema_load_output(command), args)
    end
  end

  desc 'Load structure for test databases via db:structure:load --> parallel:load_structure[num_cpus]'
  ParallelSpecs::Tasks.define_task_unless_defined(:load_structure, :count) do |_, args|
    ParallelSpecs::Tasks.run_in_parallel(
      [
        $PROGRAM_NAME,
        ParallelSpecs::Tasks.purge_before_load,
        'db:structure:load',
        "RAILS_ENV=#{ParallelSpecs::Tasks.rails_env}",
        'DISABLE_DATABASE_ENVIRONMENT_CHECK=1'
      ],
      args
    )
  end

  desc 'Load the seed data from db/seeds.rb via db:seed --> parallel:seed[num_cpus]'
  ParallelSpecs::Tasks.define_task_unless_defined(:seed, :count) do |_, args|
    ParallelSpecs::Tasks.run_in_parallel(
      [$PROGRAM_NAME, 'db:seed', "RAILS_ENV=#{ParallelSpecs::Tasks.rails_env}"],
      args
    )
  end

  desc 'Launch given rake command in parallel'
  ParallelSpecs::Tasks.define_task_unless_defined(:rake, :command, :count) do |_, args|
    ParallelSpecs::Tasks.run_in_parallel(
      [$PROGRAM_NAME, args.command, "RAILS_ENV=#{ParallelSpecs::Tasks.rails_env}"],
      args
    )
  end
end
