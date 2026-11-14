# tide's design

tide keeps a game's time: its clocks, its calendar, and what is scheduled to happen when. It writes time as
riverrun facts, so dialogue, quests and the world read one time without knowing tide. It knows no engine and no
game. This page is the design it is built to; the core is built (clocks, calendars, derived facts, schedules,
snapshots), and so is the `.river` front end below, on riverrun's packages.

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
  facts and keeps the player's; a game's flashback restores a moment. A warp the story asks for is the host performing
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

tide adds vocabulary to `.river`, never grammar, as cairn does: one `riverrun.Package`, `tide.package`, which a
game's vocabulary lists. The calendar is a section of kind `calendar`; its parts are its units, its cycles and the
time facts it keeps; a schedule is tags on any section, or on a part of a scene or a registered kind. The calendar
declares the facts it keeps, so the story reads them and never declares them.

```
facts (time):
  turn:  int   (clock)

== school (calendar)
  [clock turn] [scope time]
= slot
  [size 1] [place slot] [names morning, noon, afternoon, evening]
= day
  [size 4] [count day]
= week
  [cycle day] [place weekday] [names monday, tuesday, wednesday, thursday, friday, saturday, sunday]
= days_left
  [until day 34] [per day]

== ramen
  [every week] [at sunday evening] [times 5]
{ weekday = sunday and slot = evening } RYUJI: yo. ramen?
-> end
```

- **A calendar** (`[clock …]`, `[start …]`, `[scope …]` under its heading) reads a `(clock)` fact the story
  declares. Each part's tags stand under its heading, a row of their own. A unit part has a `size` (in the unit
  before, ticks for the first; several sizes repeat in turn), and may name the fact that holds its place in the next
  unit (`place`), with the `names` of its places, and the int fact that counts it (`count`). A cycle part goes round
  a unit (`[cycle day] [length 7] [offset 3]`), its place a fact too; its `length` may be left to its `names`.
- **The calendar's facts are its own declarations** (riverrun's `Kind.declare`), the game's to write and tide's to
  keep, in the scope `scope` names: a place is a `one of` its names, or an int where it has none; a count and a
  time fact are ints. A story that declares one of them too is refused with both places.
- **Time facts** are parts named by their int fact: `until` or `since` an instant, counted `per` a unit or a
  number of ticks, or `drift` against another clock, `per` a unit of fixed size.
- **An instant** is words in the calendar's own facts: a count (`day 34`) and places, each a place fact and its
  value (`weekday sunday`) or a place's name alone where no other place takes it (`sunday evening`); the first
  tick at or after the count's start where every place holds. A schedule is one instant (`at`) or a recurrence
  (`every` a unit or cycle, from `at` where it is given, `interval`, `times`, `policy each|once`); `calendar name`
  says which where a story has several, else the calendar its `at` names.
- **Checked inside riverrun's check.** Each of tide's tags is judged where it stands (`Schema.Value.judge`): an
  instant against its calendar, `every` and `cycle` against its units, `clock` and `drift` against the story's
  `(clock)` facts, so `[at sundy evening]` fails with its file and line. What only the whole shows (a calendar that
  does not hold together, a time it never reaches, a schedule with no calendar to mean) is tide's check, a pass of
  riverrun's checker. Both report through riverrun's diagnostics, so `addStory` prints them as riverrun's own; the
  compile pass meets none of them, and would refuse the story where it is written if it did.
- **No builtins:** a clock is a `(clock)` fact, so `since()` and comparisons are riverrun's and cairn's own.
- **In a game's build,** as riverrun's design has every package: the vocabulary lists `tide.package`, and the
  build hands `addStory` tide's compiler side, `tide.compiler(b.dependency("tide", riverrun.building(b)))`, as
  `tide-compiler`, on the riverrun the compiler stands on. tide's development compiles its school year this way and
  tells it with the game's riverrun and tide, which would not compile were either another instance.

**Why parts, not tags of the section, and not a `(time)` section:** a calendar's units, cycles and time facts each
have a name and their own few tags, which is what a part is; the time facts are counted in the calendar's units,
so they belong to it; and a section of its own would declare a second place where time is written.

**Why the calendar declares its facts:** a slot's names, a week's days and a unit's count are the calendar's
shape, so they are written once, beside it, and every condition that names them is held to them. A schedule's keys
are then tide's alone, a fixed list, never a list of the game's fact names its vocabulary must repeat.

**The block.** tide's compile pass works out every instant from the calendar while the story builds and writes
the result as tide's block (version 1) in the compiled story: the clocks, the calendars with their units and
cycles, the time facts, and the schedules, each keyed by the section that carries it. Loading is then a
translation: `tide.fromStory(gpa, story, store, options)` checks the block against the story it came with (every
fact of its kind, every section there), takes the names from the story, starts the tide and takes each schedule,
which comes due with its section's id as its key. A story that declares no time has no block. The reader refuses
any block cut short, too long, with a count past its bound or an unknown tag; it has a fuzz target.

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
