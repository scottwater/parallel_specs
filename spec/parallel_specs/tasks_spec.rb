# frozen_string_literal: true

require 'spec_helper'
require 'rake'
require 'parallel_specs/tasks'

RSpec.describe ParallelSpecs::Tasks do
  def fresh_rake_application
    previous_application = Rake.application
    Rake.application = Rake::Application.new
    load File.expand_path('../../lib/parallel_specs/tasks.rb', __dir__)
    yield
  ensure
    Rake.application = previous_application
  end

  describe '.rails_env' do
    it 'defaults to test' do
      expect(described_class.rails_env).to eq('test')
    end

    it 'uses PARALLEL_SPECS_RAILS_ENV' do
      ENV['PARALLEL_SPECS_RAILS_ENV'] = 'ci'

      expect(described_class.rails_env).to eq('ci')
    end

  end

  describe '.worker_env' do
    it 'sets the worker database suffixes used by Rails database.yml' do
      expect(described_class.worker_env(0, 3)).to include(
        'TEST_ENV_NUMBER' => '',
        'PARALLEL_SPECS_GROUPS' => '3',
        'DISABLE_SPRING' => '1'
      )
      expect(described_class.worker_env(1, 3)).to include('TEST_ENV_NUMBER' => '2')
    end
  end

  describe '.run_in_parallel' do
    it 'runs the command once per worker with TEST_ENV_NUMBER' do
      calls = Queue.new
      allow(described_class).to receive(:run_command) do |env, command|
        calls << [env, command]
        true
      end

      described_class.run_in_parallel(['rake', 'db:create-$TEST_ENV_NUMBER'], count: 2)

      results = 2.times.map { calls.pop }
      expect(results.map { |env, _command| env['TEST_ENV_NUMBER'] }).to contain_exactly('', '2')
      expect(results.map { |_env, command| command }).to contain_exactly(
        ['rake', 'db:create-'],
        ['rake', 'db:create-2']
      )
    end

    it 'aborts when any worker command fails' do
      allow(described_class).to receive(:run_command).and_return(true, false)
      expect(described_class).to receive(:abort)

      described_class.run_in_parallel(['rake', 'db:create'], count: 2)
    end
  end

  describe '.suppress_schema_load_output' do
    it 'filters noisy schema load lines' do
      allow(described_class).to receive(:suppress_output)

      described_class.suppress_schema_load_output(['rake', 'db:schema:load'])

      expect(described_class).to have_received(:suppress_output).with(['rake', 'db:schema:load'], '^   ->\\|^-- ')
    end
  end

  describe '.check_for_pending_migrations' do
    it 'invokes a pending migration task when present' do
      fresh_rake_application do
        invoked = false
        Rake::Task.define_task('db:abort_if_pending_migrations') { invoked = true }

        described_class.check_for_pending_migrations

        expect(invoked).to be(true)
      end
    end
  end

  describe '.purge_before_load' do
    context 'without ActiveRecord' do
      it 'does not add a purge task' do
        hide_const('ActiveRecord') if Object.const_defined?(:ActiveRecord)

        expect(described_class.purge_before_load).to be_nil
      end
    end

    context 'with ActiveRecord > 4.2.0' do
      before do
        stub_const('ActiveRecord', double(version: Gem::Version.new('7.0.0')))
      end

      it 'uses db:purge when available' do
        allow(Rake::Task).to receive(:task_defined?).with('db:purge').and_return(true)

        expect(described_class.purge_before_load).to eq('db:purge')
      end

      it 'falls back to app:db:purge' do
        allow(Rake::Task).to receive(:task_defined?).with('db:purge').and_return(false)

        expect(described_class.purge_before_load).to eq('app:db:purge')
      end
    end
  end

  describe 'rake tasks' do
    it 'defines the Rails database tasks needed by parallel specs' do
      fresh_rake_application do
        expect(Rake::Task.task_defined?('parallel:create')).to be(true)
        expect(Rake::Task.task_defined?('parallel:drop')).to be(true)
        expect(Rake::Task.task_defined?('parallel:load_schema')).to be(true)
        expect(Rake::Task.task_defined?('parallel:prepare')).to be(true)
      end
    end

    it 'does not redefine a task that another gem already provided' do
      fresh_rake_application do
        Rake::Task['parallel:create'].clear
        Rake.application.instance_variable_get('@tasks').delete('parallel:create')
        Rake::Task.define_task('parallel:create') { 'existing task' }

        load File.expand_path('../../lib/parallel_specs/tasks.rb', __dir__)

        expect(Rake::Task['parallel:create'].actions.size).to eq(1)
      end
    end

    it 'runs parallel:create through the Rails db:create task' do
      fresh_rake_application do
        allow(described_class).to receive(:run_in_parallel)

        Rake::Task['parallel:create'].invoke(2)

        expect(described_class).to have_received(:run_in_parallel).with(
          [kind_of(String), 'db:create', 'RAILS_ENV=test'],
          kind_of(Rake::TaskArguments)
        )
      end
    end

    it 'runs parallel:load_schema through db:schema:load with purge' do
      fresh_rake_application do
        allow(described_class).to receive(:purge_before_load).and_return('db:purge')
        allow(described_class).to receive(:suppress_schema_load_output) { |command| command }
        allow(described_class).to receive(:run_in_parallel)

        Rake::Task['parallel:load_schema'].invoke(2)

        expect(described_class).to have_received(:run_in_parallel).with(
          [kind_of(String), 'db:purge', 'db:schema:load', 'RAILS_ENV=test', 'DISABLE_DATABASE_ENVIRONMENT_CHECK=1'],
          kind_of(Rake::TaskArguments)
        )
      end
    end
  end
end
