# frozen_string_literal: true

require 'fileutils'
require 'rspec/core'
require 'rspec/core/formatters/base_text_formatter'

module ParallelSpecs
  module RSpec
  end
end

class ParallelSpecs::RSpec::LoggerBase < RSpec::Core::Formatters::BaseTextFormatter
  def initialize(*args)
    super

    @output ||= args[0]
    case @output
    when String
      FileUtils.mkdir_p(File.dirname(@output))
      File.open(@output, 'w') {}
      @output = File.open(@output, 'a')
    when File
      @output.close
      @output = File.open(@output.path, 'a')
    end
  end

  def close(*)
    @output.close if IO === @output && @output != $stdout
  end

  protected

  def lock_output
    if @output.is_a?(File)
      begin
        @output.flock(File::LOCK_EX)
        yield
      ensure
        @output.flock(File::LOCK_UN)
      end
    else
      yield
    end
  end
end
