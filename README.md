# Parallel Specs

A focused extraction of the `parallel_tests` RSpec runner with:

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

`parallel_specs` defaults to the dashboard locally and plain text in CI / non-TTY environments.

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

## Compatibility

The gem also ships a `parallel_rspec` executable and compatibility formatter paths so existing wrapper scripts can migrate with minimal changes.
