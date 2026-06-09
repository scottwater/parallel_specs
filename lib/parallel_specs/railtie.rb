# frozen_string_literal: true

require 'parallel_specs'

module ParallelSpecs
  class Railtie < ::Rails::Railtie
    rake_tasks do
      require 'parallel_specs/tasks'
    end
  end
end
