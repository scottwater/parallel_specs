# frozen_string_literal: true
name = 'parallel_specs'
require_relative 'lib/parallel_specs/version'

Gem::Specification.new name, ParallelSpecs::VERSION do |s|
  s.summary = 'Parallel RSpec with a live dashboard, plain CI output, and runtime balancing'
  s.authors = ['Scott Watermasysk']
  s.email = 'scott@example.com'
  s.homepage = 'https://github.com/your-org/parallel_specs'
  s.license = 'MIT'
  s.required_ruby_version = '>= 3.2.0'
  s.files = Dir['{lib,bin}/**/*'] + ['README.md']
  s.bindir = 'bin'
  s.executables = ['parallel_specs', 'parallel_rspec']

  s.add_dependency 'parallel'
  s.add_dependency 'rspec-core'
end
