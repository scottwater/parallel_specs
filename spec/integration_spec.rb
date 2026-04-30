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

  def make_executable(base, file)
    FileUtils.chmod(0o755, File.join(base, file))
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

  def run_specs_with_first_chunk(base, *args, env: {})
    first_chunk = +''
    output = +''
    Dir.chdir(base) do
      IO.popen(env, [*executable, *args], err: [:child, :out]) do |io|
        if IO.select([io], nil, nil, 1)
          chunk = io.read_nonblock(1024, exception: false)
          first_chunk = chunk if chunk.is_a?(String)
          output << first_chunk
        end
        output << io.read.to_s
      end
    end
    [first_chunk, output, $?]
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

      output, status = run_specs(dir, '-n', '2', 'spec', env: { 'PARALLEL_SPECS_HEARTBEAT_INTERVAL' => '0.05' })
      expect(status.exitstatus).to eq(0), output
      expect(output).to match(/\.{3,}.*dashboard workers=2/m)
    end
  end

  it 'flushes heartbeat output before specs finish' do
    Dir.mktmpdir do |dir|
      write(dir, 'spec/a_spec.rb', "RSpec.describe { it('passes') { sleep 1.2; expect(true).to eq(true) } }")

      first_chunk, output, status = run_specs_with_first_chunk(
        dir,
        '-n',
        '1',
        'spec',
        env: { 'PARALLEL_SPECS_HEARTBEAT_INTERVAL' => '0.05' }
      )

      expect(status.exitstatus).to eq(0), output
      expect(first_chunk).to include('.')
    end
  end

  it 'records runtime information with --record-runtime' do
    Dir.mktmpdir do |dir|
      lib_path = File.join(root, 'lib')
      write(dir, 'spec/a_spec.rb', "RSpec.describe { it('passes') { sleep 0.05; expect(true).to eq(true) } }")
      write(dir, 'spec/b_spec.rb', "RSpec.describe { it('passes') { sleep 0.05; expect(true).to eq(true) } }")
      write(dir, 'bin/rspec', <<~RUBY)
        #!/usr/bin/env ruby
        lib_path = #{lib_path.inspect}
        ENV['RUBYLIB'] = [lib_path, ENV['RUBYLIB']].compact.join(File::PATH_SEPARATOR)
        sleep 0.8 if ENV['TEST_ENV_NUMBER'] == '2'
        exec Gem.bin_path('rspec-core', 'rspec'), *ARGV
      RUBY
      make_executable(dir, 'bin/rspec')

      output, status = run_specs(dir, '--record-runtime', '-n', '2', 'spec')
      expect(status.exitstatus).to eq(0), output
      runtime_log = File.join(dir, 'tmp/parallel_runtime_rspec.log')
      expect(File).to exist(runtime_log)
      lines = File.readlines(runtime_log)
      runtime_log_paths = lines.map { |line| line.split(':').first }.sort
      expect(runtime_log_paths).to eq(%w[spec/a_spec.rb spec/b_spec.rb])
      expect(lines).to all(match(%r{^spec/.+_spec.rb:[-.\de]+$}))
    end
  end

  it 'rejects zero process counts' do
    Dir.mktmpdir do |dir|
      output, status = run_specs(dir, '-n', '0', 'spec')

      expect(status.exitstatus).to eq(1), output
      expect(output).to include('Process count must be greater than 0')
      expect(output).not_to include('NoMethodError')
    end
  end
end
