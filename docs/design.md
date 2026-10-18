# tide's design

tide keeps a game's time: its clocks, its calendar, and what is scheduled to happen when. It writes time as
riverrun facts, so dialogue, quests and the world read one time without knowing tide. It knows no engine and no
game. This page is the design it is built to; nothing is built yet.

## What it owns

tide owns **game time**: clocks the host advances, a calendar the game declares, and schedules. It owns no wall
clock (the host passes elapsed time in), no rendering and no event bus. *Protects:* one time every system agrees on,
replayable exactly.

## Clocks

- A **clock** is a monotonic count of the game's smallest unit (a turn, a minute, a tick), advanced only by the
  host: `advance(clock, n)`. Several clocks run side by side: world time, time played, a region's time.
- A clock has a **rate** and can be **paused**: the host passes real elapsed time and tide converts it, so time
  scale, pause, sleep and skipping a day are one call each.
- A clock is a riverrun `(clock)` fact, saved and restored with every other fact.

## Calendars

A game declares its calendar as data: its units (minutes, slots, days, weeks, seasons), their sizes, their names,
and its start. Persona's after school, evening and night are slots of a day; a space game's calendar may be seconds
alone. tide derives the calendar's facts from the clock (`day`, `weekday`, `slot`, `season`), so a condition reads
`weekday = sunday and slot = evening` and wakes only when that changes.

## Schedules

- **Instants:** "when this clock reaches this value", in a heap, so a clock moving pops only what is due and a
  step with nothing due costs one comparison.
- **Recurrences:** every day at a slot, every Sunday evening, every hour, a number of times or for ever, written
  in the calendar's own units and expanded lazily, one occurrence at a time.
- **Timers** relative to now, for a host's own needs.

What is due is returned from `advance` as a list, in time order, deterministic for the same advances; the host
records each as a fact. Nothing reads tide directly: riverrun and cairn read its facts, and cairn indexes its own
timed conditions by the clock facts' values, so neither depends on tide nor tide on them.

## Events become facts

tide has no event bus, and neither does cairn. A thing that happens (an item picked up, a wolf killed, a scheduled
moment reached) is recorded by the host as a fact (a count, a set, a time), and conditions read facts. An event
only heard is lost when a game loads, and a world toggled by events goes wrong after a load or a patch; a fact is
saved, replicated and re-read. Flow graphs that wait on messages become conditions over the facts the messages
would have set.

## Packages

riverrun for facts and `(clock)` facts; aegis for ids and bounds; shakedown for tests; the gate as the family's.

## Napkin math

A heap of 100,000 scheduled instants is a few megabytes; `advance` pops what is due in O(k log n) for k due, and a
step with nothing due costs one comparison.
