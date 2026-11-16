# Changelog

All notable changes are documented here, following Keep a Changelog 1.1.0.

## [Unreleased]

### Added

- Clocks the host advances, by ticks or by elapsed time at an exact rate, with pause and rate zero; no clock runs
  backwards.
- Calendars declared as data: nested units of fixed or repeating sizes, named places and cycles, several on one
  clock, written as facts only when they change.
- Derived facts: time until or since a tick, and the drift between two clocks.
- Instants and recurrences on a heap per clock, due in a fixed order; a jump's missed occurrences come due each or
  once, by the schedule's policy; nothing allocates after setup.
- Snapshots that restore a moment exactly.
- Scheduled scenes in a story, cancelled by the game with `:cancel` in `riverrun play`; the checker refuses a
  schedule by the runtime's own rule (`times 0`, an `interval` of 0, a first time past what a clock counts).
- The manual's chapter on time, [docs/manual/11-time.md](docs/manual/11-time.md), every block held by the test step.
