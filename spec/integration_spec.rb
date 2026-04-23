# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'parallel_specs integration' do
  def root
    File.expand_path('..', __dir__)
  end

  def executable
    [RbConfig.ruby, File.join(root, 'bin/parallel_specs')]
  end

  def write(base, file, content)
    path = File.join(base, file)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def run_specs(base, *args, env: {})
    output = ''
    Dir.chdir(base) do
      IO.popen(env, [*executable, *args], err: [:child, :out]) do |io|
        output = io.read
      end
    end
    [output, $?]
  end

  it 'prints a plain dashboard summary in non-tty mode' do
    Dir.mktmpdir do |dir|
      write(dir, 'spec/a_spec.rb', "RSpec.describe { it('passes') { expect(true).to eq(true) } }")
      write(dir, 'spec/b_spec.rb', "RSpec.describe { it('passes') { expect(true).to eq(true) } }")

      output, status = run_specs(dir, '-n', '2', 'spec')
      expect(status.exitstatus).to eq(0), output
      expect(output).to match(/^dashboard workers=2.*$/)
      expect(output).to match(/^worker=1 status=.*$/)
      expect(output).to include('2 examples, 0 failures')
    end
  end

  it 'keeps heartbeat output in plain dashboard mode' do
    Dir.mktmpdir do |dir|
      write(dir, 'spec/a_spec.rb', "RSpec.describe { it('passes') { sleep 0.25; expect(true).to eq(true) } }")
      write(dir, 'spec/b_spec.rb', "RSpec.describe { it('passes') { sleep 0.35; expect(true).to eq(true) } }")

      output, status = run_specs(dir, '-n', '2', 'spec', env: { 'PARALLEL_TEST_HEARTBEAT_INTERVAL' => '0.05' })
      expect(status.exitstatus).to eq(0), output
      expect(output).to match(/\.{3,}.*dashboard workers=2/m)
    end
  end

  it 'records runtime information with --record-runtime' do
    Dir.mktmpdir do |dir|
      write(dir, 'spec/a_spec.rb', "RSpec.describe { it('passes') { sleep 0.05; expect(true).to eq(true) } }")
      write(dir, 'spec/b_spec.rb', "RSpec.describe { it('passes') { sleep 0.05; expect(true).to eq(true) } }")

      output, status = run_specs(dir, '--record-runtime', '-n', '2', 'spec')
      expect(status.exitstatus).to eq(0), output
      runtime_log = File.join(dir, 'tmp/parallel_runtime_rspec.log')
      expect(File).to exist(runtime_log)
      lines = File.readlines(runtime_log)
      expect(lines).to all(match(%r{^spec/.+_spec.rb:[-.\de]+$}))
    end
  end
end
