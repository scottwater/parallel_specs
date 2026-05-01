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

Runtime logs are replaced only after a successful, complete run where every worker produces its runtime log. Failed, interrupted, incomplete, or no-spec runs preserve the previous runtime log.

Or point at a custom file:

```bash
bundle exec parallel_specs --record-runtime --runtime-log tmp/my_runtime.log
```

`--runtime-log PATH` is used as the input path for balancing and, with `--record-runtime`, as the output destination for the completed run.

## Environment variables

The supported environment variables are:

- `PARALLEL_SPECS_PROCESSORS` sets the default worker count when `-n` is not provided.
- `PARALLEL_SPECS_DASHBOARD_MODE` can be `interactive` or `plain` to override automatic dashboard selection.
- `PARALLEL_SPECS_HEARTBEAT_INTERVAL` sets the plain-dashboard heartbeat interval in seconds.
- `CI` makes dashboard output default to plain mode.

Worker processes continue to receive `TEST_ENV_NUMBER` for compatibility with existing test-environment isolation setup.

This gem does not intentionally preserve the old `parallel_tests` executable names, formatter paths, or environment variable aliases.
