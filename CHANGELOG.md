# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.2] - 2026-08-27

### Added

- `--single`, `--isolate`, and `--isolate-n` grouping controls for keeping
  matching specs together on dedicated workers.

### Changed

- `--record-runtime` now renders the normal dashboard (interactive on a TTY,
  plain in CI) instead of falling back to RSpec's `progress` formatter, so
  recording a runtime log no longer sprays per-example dots across the screen.
  Worker output is captured and shown only on failure, matching ordinary runs.

## [0.9.1] - 2026-06-14

### Added

- Rails database Rake tasks to create, drop, and prepare per-worker test
  databases, following the same `TEST_ENV_NUMBER` convention as the runner —
  so Rails apps no longer need `parallel_tests` solely for its Rake tasks.
- Runner flags to enable plain dashboard output for one-off local runs without
  requiring environment configuration.

### Changed

- Plain dashboard output now mirrors the interactive dashboard summary instead
  of dumping per-worker details and current example names.
- Interactive dashboard reduces visual noise, focusing on the examples counter
  and elapsed timer rather than worker rollups and current spec descriptions.
- Dashboard resize handling recalculates terminal width and clears wrapped rows
  so it recovers cleanly when the terminal changes size.
- Failed-worker rerun output summarizes long commands to keep useful RSpec
  failure output visible on large runs; full commands remain available via an
  explicit environment override.
- Switched linting to Standard and pinned/set the Ruby toolchain version.

### Fixed

- Dashboard keeps polling after receiving bad events instead of stalling.
- Record-runtime worker output is now serialized to avoid interleaved writes.
- Invalid processor environment values are rejected.
- RSpec args are parsed correctly when they follow file paths.
- Missing spec paths are reported clearly.

### Docs

- Added GitHub social preview assets.

## [0.9.0] - 2026

- Initial release.

[Unreleased]: https://github.com/scottwater/parallel_specs/compare/0.92...HEAD
[0.9.2]: https://github.com/scottwater/parallel_specs/compare/0.91...0.92
[0.9.1]: https://github.com/scottwater/parallel_specs/compare/0.9.0...0.91
[0.9.0]: https://github.com/scottwater/parallel_specs/releases/tag/0.9.0
