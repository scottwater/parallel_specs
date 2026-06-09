# Parallel Specs

![Parallel Specs social preview](assets/github-social-preview-rspecish.png)

A focused extraction of the RSpec pieces from `parallel_tests` with only the parts this gem actually needs:

- a live local dashboard
- a plain-text CI / LLM friendly summary
- runtime-log generation for balanced spec splitting
- modern Ruby only

## Setup

Add the gem to your app's Gemfile:

```ruby
group :test do
  gem 'parallel_specs'
end
```

Then install it:

```bash
bundle install
```

For Rails apps, configure the test database name to include `TEST_ENV_NUMBER`. The first worker uses a blank value, then workers 2, 3, and so on use their worker number:

```yaml
# config/database.yml
test:
  database: my_app_test<%= ENV['TEST_ENV_NUMBER'] %>
```

If you previously used `parallel_tests`, this is the same database naming convention. Once the `parallel_specs` Rake tasks are available, you can remove `parallel_tests` if you were only keeping it for database setup.

## Commands

```bash
bundle exec parallel_specs
bundle exec parallel_specs -n 6
bundle exec parallel_specs --dashboard-mode plain
bundle exec parallel_specs --plain
bundle exec parallel_specs --plain-dashboard
bundle exec parallel_specs --test-options='--tag ~type:system'
bundle exec parallel_specs --record-runtime
```

Local TTY runs render the interactive dashboard. CI and other non-TTY runs automatically fall back to the plain text summary. Use `--plain`, `--dashboard-mode plain`, or `--plain-dashboard` to force plain dashboard output without setting an environment variable.

Plain dashboard output is intentionally minimal: it prints the examples counter and elapsed time, then relies on the process exit status and the final RSpec summary for success or failure. It does not print per-worker rows or current example names.

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

## Rails database tasks

Rails apps that use `TEST_ENV_NUMBER` in `config/database.yml` can prepare per-worker test databases without depending on `parallel_tests`.

The most common workflow is:

```bash
# Create all worker databases once
bundle exec rake parallel:create

# Load the current schema into each worker database
bundle exec rake parallel:load_schema

# Run the specs
bundle exec parallel_specs
```

After changing migrations, refresh the worker databases with:

```bash
bundle exec rake parallel:prepare
```

`parallel:prepare` checks for pending migrations, dumps the schema or structure once, and then loads it into each worker database.

To reset everything from scratch:

```bash
bundle exec rake parallel:drop
bundle exec rake parallel:create
bundle exec rake parallel:load_schema
```

Each task accepts an optional worker count:

```bash
bundle exec rake 'parallel:create[4]'
bundle exec rake 'parallel:prepare[4]'
bundle exec parallel_specs -n 4
```

If no count is provided, the tasks use `PARALLEL_SPECS_PROCESSORS` or the detected processor count. Use the same count for database prep and spec runs.

The gem also exposes compatible `parallel:setup`, `parallel:migrate`, `parallel:rollback`, `parallel:load_structure`, `parallel:seed`, and `parallel:rake` tasks.

Set `PARALLEL_SPECS_RAILS_ENV` to prepare an environment other than `test`.

## Environment variables

The supported environment variables are:

- `PARALLEL_SPECS_PROCESSORS` sets the default worker count when `-n` is not provided and when Rails database tasks are run without a count.
- `PARALLEL_SPECS_DASHBOARD_MODE` can be `interactive` or `plain` to override automatic dashboard selection. You can also use `--plain`, `--dashboard-mode plain`, or `--plain-dashboard` for a single run.
- `PARALLEL_SPECS_HEARTBEAT_INTERVAL` sets the plain-dashboard heartbeat interval in seconds.
- `PARALLEL_SPECS_FULL_RERUN_COMMANDS=1` prints full failed-worker rerun commands even when they are long.
- `PARALLEL_SPECS_RERUN_COMMAND_SPEC_FILE_LIMIT` sets how many spec files a failed-worker rerun command may include before it is summarized instead of printed. The default is 25.
- `PARALLEL_SPECS_RERUN_COMMAND_CHAR_LIMIT` sets the maximum failed-worker rerun command length before it is summarized instead of printed. The default is 2000.
- `PARALLEL_SPECS_RAILS_ENV` sets the Rails environment used by the `parallel:*` database tasks. The default is `test`.
- `CI` makes dashboard output default to plain mode.

Worker processes continue to receive `TEST_ENV_NUMBER` for compatibility with existing test-environment isolation setup.

This gem does not intentionally preserve the old `parallel_tests` executable names, formatter paths, or environment variable aliases.

## Acknowledgements

This gem is largely based on the excellent work from [`parallel_tests`](https://github.com/grosser/parallel_tests), especially its approach to grouping test files, assigning `TEST_ENV_NUMBER`, and preparing per-worker Rails test databases.
