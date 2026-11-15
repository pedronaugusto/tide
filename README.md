# tide

tide keeps a game's time: its clocks, its calendars and what is scheduled, as riverrun facts.

- Clocks the host advances, by ticks or by its own elapsed time at a rate (a ratio of integers, exact, with pause
  and rate zero for clocks only actions move). No clock runs backwards.
- Calendars declared as data: nested units of fixed or repeating sizes, named places, and cycles such as a week or
  a moon; several on one clock. Their counts and places are written as facts only when they change.
- Derived facts: time until or since a tick, and the drift between two clocks, in ticks or a calendar's units.
- Instants and recurrences on a heap per clock, due in a fixed order; a jump's missed occurrences come due each or
  once, by the schedule's policy; nothing allocates after setup.
- Snapshots that restore a moment exactly, an earlier one included, matched by name.
- Calendars and schedules written in a story's `.river` files, registered with a story's build as one package,
  `tide.package`: the `calendar` kind of section, which declares the facts it keeps, and the schedule tags, judged
  and checked inside riverrun's checker, compiled into tide's block and loaded with `tide.fromStory`.
  The compiler side is the `tide-compiler` module, from `compiler(dep)` in tide's `build.zig`, on the one riverrun
  a story's build stands on.
- Played without the game by `riverrun play`, as the game keeps time: a clock the player moves (`:wait`) is moved
  by tide, the calendar's facts follow it, and each schedule that comes due on the way is told and its scene
  played.

The design is [docs/design.md](docs/design.md). A writer learns time from riverrun's manual, whose chapter on it is
tide's: [docs/manual/11-time.md](docs/manual/11-time.md).

## Install

Requires Zig 0.17. Fetch with `zig fetch --save git+https://github.com/pedronaugusto/tide`. The runtime is the
`tide` module, on aegis and riverrun. A story's build that writes calendars and schedules in its `.river` files lists
`tide.package` in its vocabulary and hands `tide.compiler(dep)` to riverrun's `addStory` as the `tide-compiler`
package, both on the riverrun the build stands on.

## Scope

tide owns game time. It reads no wall clock (the host passes elapsed time in), renders nothing and has no event
bus; a clock moves only when the host advances it, and never backwards.

## Testing

`bay test` runs the unit suite: clocks, rates, calendars, schedules and snapshots; the `.river` front end on stories
compiled through riverrun's `addStory`; properties of the compiled block (a plan written reads back as itself,
and any bytes read to a plan or are refused, a block whole or not at all); and the manual's chapter, its stories
checked and every run it shows pinned (`bay dev manual-test` alone).

## Stability

tide is 0.x and tracks Zig 0.17.x. A breaking change comes only in a minor release
(0.1 to 0.2), with a CHANGELOG entry saying what changed and what to write instead; a
patch release never breaks.

## Licence

MIT. See [LICENSE](LICENSE).
