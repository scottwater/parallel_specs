# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ParallelSpecs::RSpec::RuntimeLogger do
  before do
    ENV['TEST_ENV_NUMBER'] = ''
  end

  def log_for_a_file
    Tempfile.open('runtime') do |temp|
      temp.close
      file = File.open(temp.path, 'w')
      logger = described_class.new(file)

      example = double(group: double(file_path: "#{Dir.pwd}/spec/foo_spec.rb"))
      logger.example_group_started(example)
      logger.example_group_finished(example)
      logger.start_dump

      File.read(file.path)
    end
  end

  it 'logs runtime with relative paths' do
    expect(log_for_a_file).to match(%r{^spec/foo_spec.rb:[-.e\d]+$})
  end

  it 'does not log when not running in parallel' do
    ENV.delete('TEST_ENV_NUMBER')
    expect(log_for_a_file).to eq('')
  end
end
