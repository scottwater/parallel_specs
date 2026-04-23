# Parallel Specs

A focused extraction of the RSpec pieces from `parallel_tests` with only the parts this gem actually needs:

- a live local dashboard
- a plain-text CI / LLM friendly summary
- runtime-log generation for balanced spec splitting
- modern Ruby only

## Commands

```bash
bundle exec parallel_specs
bundle exec parallel_specs -n 6
bundle exec parallel_specs --test-options='--tag ~type:system'
bundle exec parallel_specs --record-runtime
```

Local TTY runs render the interactive dashboard. CI and other non-TTY runs automatically fall back to the plain text summary.

## Runtime balancing

Regular runs automatically use `tmp/parallel_runtime_rspec.log` when it contains enough data.

Generate or refresh that file with:

```bash
bundle exec parallel_specs --record-runtime
```

Or point at a custom file:

```bash
bundle exec parallel_specs --record-runtime --runtime-log tmp/my_runtime.log
```

## Compatibility retained on purpose

To stay close to a drop-in replacement for existing app wrappers, the gem still ships:

- `parallel_rspec` as an executable alias
- `ParallelTests::RSpec::RuntimeLogger` as a compatibility formatter path

Everything else from the broader `parallel_tests` surface area was intentionally left out.
