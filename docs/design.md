# tide's design

tide keeps a game's time: its clocks, its calendar, and what is scheduled to happen when. It writes time as
riverrun facts, so dialogue, quests and the world read one time without knowing tide. It knows no engine and no
game. This page is the design it is built to; the core is built (clocks, calendars, derived facts, schedules,
snapshots), and the `.river` front end below comes with riverrun's registered kinds.

## What it owns

tide owns **game time**: clocks the host advances, a calendar the game declares, and schedules. It owns no wall
clock (the host passes elapsed time in), no rendering and no event bus. *Protects:* one time every system agrees on,
replayable exactly.

## Clocks

- A **clock** is a monotonic count of the game's smallest unit (a turn, a minute, a second), advanced only by the
  host: `advance(clock, n)`. Several run side by side, each with its own rate and its own facts: world time, a dream
  world, another planet, a ship in stasis.
- A clock has a **rate**, a ratio of integers (`3 ticks per 5` of the host's elapsed time), and can be **paused**;
  `elapse(clock, t)` converts the host's elapsed time at that rate, carrying the fraction of a tick left over, so
  many small elapses and one large one reach the same tick and nothing drifts. A rate changes at any moment, from
  that moment; the fraction carried under the old one is dropped.
- **Rate zero** is a clock only actions move: a minute a line of dialogue, a slot an activity, a turn.
- **No clock runs backwards.** Going back is restoring a saved moment (below); a time loop restores the world's
  facts and keeps the player's; WAKE's history restores a moment. A warp the story asks for is the host performing
  an action through `advance`; the story never sets time.
- A clock writes its tick to a riverrun `(clock)` fact, only when it changed.

## Calendars

A calendar reads a clock's ticks as the game's own time, declared as data:

- **Units** nest, smallest first: a slot of ticks, a day of slots, a month of days, a year of months. A unit's size
  is fixed or a repeating list of sizes, so months of 31, 28, 31… days and a leap cycle are data, and no date
  arithmetic is written for a calendar. A unit may name its places in the next (the slots of a day, the months of a
  year).
- **Cycles** count a unit round without nesting: a week of seven named days across months, a moon of four phases
  across weeks, a festival calendar beside the week.
- **A start**: where the clock's tick zero falls in the calendar.

From a tick, a calendar reads each unit's count since its zero (`day`), each unit's place in the next (`slot`, a
`one of` where it has names), and each cycle's place (`weekday`, `phase`), and writes the facts bound to them only
when they change. Several calendars may read one clock. `next(from, wants)` finds the first tick where places hold
(the next Sunday evening), stepping by the finest unit named, bounded by a named error.

## Derived facts

riverrun has no arithmetic, so time arithmetic is tide's, kept as ordinary int facts and written only when they
change:

- **until** a tick, never below zero, in ticks or in a calendar's units begun between: `days_left` until the fifth
  of May;
- **since** a tick, zero before it;
- **drift** between two clocks, signed, in whole units of a size the story declares: earth against the ship, in
  years.

## Schedules

- **Instants:** `at(clock, tick)`, and `after(clock, n)` from now.
- **Recurrences:** a first tick and a step, every so many ticks or every so many of a calendar's units (at the same
  place in each: the first of every month, a place past a shorter month's end on its last tick), a number of times
  or for ever. A recurrence is its declaration and the number of its next occurrence; each occurrence is worked
  out when needed, one at a time.
- **One queue a clock:** a binary heap by tick, then by the order things were scheduled in, so equal ticks come due
  in a fixed order. It keeps each schedule's place, so cancelling removes it where it is and the heap holds nothing
  dead. Its room is set when tide is made; nothing allocates after.
- **A jump** (sleep, wait, the next day) passes what came due in between. Each schedule says what then happens:
  `each` comes due once for each occurrence, in order; `once` comes due as one, at its first occurrence, with how
  many it stands for.
- `advance` returns what came due in time order, into the host's buffer. If the buffer fills, the clock stops where
  it is and the call says how far it still has to go; the host advances again by that, so the result is the same
  as one call with room enough.

What came due is the host's to record as facts. Nothing reads tide directly: riverrun and cairn read its facts, and
cairn indexes its own timed conditions by the clock facts' values, so neither depends on tide nor tide on them.

## Saved moments

A snapshot is tide's own bytes: every clock's tick, rate, pause and carried fraction, and every schedule with its
order and a recurrence's next occurrence. Clocks and calendars are matched by name, and what no longer matches is
reported. A restore replaces every schedule with the saved ones and writes the facts back, so a restore to an
earlier moment comes due exactly as the first time.

Schedules are not facts because facts are a story's fixed declarations and schedules come and go; a clock's tick is
both, a fact the story reads and a value the snapshot keeps, and a restore writes the fact from the snapshot.

## Shapes it serves

- **A calendar game** (Persona's kind): a clock at rate zero moved a slot per activity; the day rolls over; a
  deadline's `days_left` counts down; what the day offers reads `weekday` and `slot`.
- **Real time with a rate**: a world clock at minutes per second, paused in menus, skipped a day by one `advance`
  whose schedules come due `each` or `once`.
- **Resuming**: the host hands the time it was away to `elapse`, at once or in pieces; the result is the same.
- **Several clocks**: a dream world, another planet, relativity, each its own rate and facts, with `drift` between.
- **Several calendars on a clock**: a moon, a festival year, beside the week.
- **Going back**: a time loop or a life's history restores a saved moment, never a clock running backwards.

## In the story

tide adds vocabulary to `.river`, never grammar, as cairn does:

- **The calendar is written in the story**, so writers and the checker know it: a section of kind `calendar` whose
  tags declare its units, names and start.

  ```
  == year (calendar)          # units minute 60, slot 4, day 7, week 52 · slots morning, noon, afternoon, evening
                              # days monday … sunday · start 1985-04-12 evening
  ```

  From it the checker knows the calendar's facts (`day`, `weekday`, `slot`, `week`) and their values, so
  `weekday = sunday and slot = evening` is checked like any condition, and a typo fails the build.
- **Times are a tag type** that any section, quest or pool candidate may carry: `# at day 12 evening`, `# every
  sunday evening · times 5`. tide's schema types them; what comes due is recorded as a fact the story reads.
- **No builtins:** a clock is a `(clock)` fact, so `since()` and comparisons are riverrun's and cairn's own.

The front end is a translation: a `(calendar)` section becomes a calendar's declaration, its facts a binding, and
a time tag an instant or a recurrence. The runtime reads them from the block tide owns in the compiled story.

## Events become facts

tide has no event bus, and neither does cairn. A thing that happens (an item picked up, a wolf killed, a scheduled
moment reached) is recorded by the host as a fact (a count, a set, a time), and conditions read facts. An event
only heard is lost when a game loads, and a world toggled by events goes wrong after a load or a patch; a fact is
saved, replicated and re-read. Flow graphs that wait on messages become conditions over the facts the messages
would have set.

## Packages

riverrun for facts and `(clock)` facts; aegis for ids and bounds; shakedown for tests; the gate as the family's.

## Bounds

Clocks 32, calendars 16, derived facts 256, schedules held at once 1,048,576 (the host's `room`), units 8 and
cycles 8 a calendar, 4,800 sizes in a unit's repeating list, a clock's tick to `maxInt(i64)` as a riverrun int;
`next` searches a million units. Each is a named error.

## Napkin math

A schedule is about 140 bytes (its slot, a heap entry, its place and its free-list room): 100,000 is about
14 MB, all taken when tide is made. `advance` pops what is due in
O(k log n) for k due, and a step with nothing due costs one comparison.
