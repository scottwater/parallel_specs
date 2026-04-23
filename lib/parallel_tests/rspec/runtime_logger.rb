# frozen_string_literal: true

require 'parallel_tests'
require 'parallel_specs/rspec/runtime_logger'

module ParallelTests
  module RSpec
    RuntimeLogger = ParallelSpecs::RSpec::RuntimeLogger
  end
end
