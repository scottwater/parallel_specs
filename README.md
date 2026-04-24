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

## Environment variables

The supported environment variables are:

- `PARALLEL_SPECS_PROCESSORS`
- `PARALLEL_SPECS_DASHBOARD_MODE`
- `PARALLEL_SPECS_HEARTBEAT_INTERVAL`

This gem does not intentionally preserve the old `parallel_tests` executable names, formatter paths, or environment variable aliases.
