# frozen_string_literal: true

RSpec.describe 'parallel_specs.gemspec' do
  subject(:specification) { Gem::Specification.load('parallel_specs.gemspec') }

  it 'bounds runtime dependencies to tested major versions' do
    dependencies = specification.runtime_dependencies.to_h do |dependency|
      [dependency.name, dependency.requirement.to_s]
    end

    expect(dependencies.fetch('parallel')).to eq('>= 1.28, < 3')
    expect(dependencies.fetch('rspec-core')).to eq('>= 3.13, < 4')
  end
end
