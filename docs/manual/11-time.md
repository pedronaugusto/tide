# 11. Time

Ada makes her last crossing in the evening, every day. On Saturday mornings the market boat comes down from the
mill, and in four days the fair opens on the far bank. The game keeps the time, moving its clock on as the player
plays; the story says what the hours are called, and what happens when.

```river
facts (world):
  hour: int   (clock)          // the game's clock: an hour a tick

== hollin (calendar)
  [clock hour] [scope world]
= watch
  [size 6] [place part] [names night, morning, afternoon, evening]
= day
  [size 4] [count day]
= week
  [cycle day] [place weekday] [names monday, tuesday, wednesday, thursday, friday, saturday, sunday]
= days_to_fair
  [until day 4] [per day]
```

```river
== last_ferry
  [every day] [at evening] [policy once]
ADA: Last ferry over! Last one tonight!
-> end
```

That is from `stories/11/landing.river`, the landing at Hollin by the clock.

A game's time is kept by tide, a package the game builds in beside riverrun, and this chapter is tide's: it lives in
tide's repository, beside the stories it shows. Everything else in it is the language of
[the manual](https://github.com/pedronaugusto/riverrun/blob/main/docs/manual/README.md), used as the earlier chapters
teach it.

## A clock

```river
facts (world):
  hour: int   (clock)          // the game's clock: an hour a tick
```

`hour` is the game's clock: an int marked `(clock)`, which only the game moves, and only on, never back
([chapter 7](https://github.com/pedronaugusto/riverrun/blob/main/docs/manual/07-the-games-vocabulary.md)). What a
tick is, the game decides: here an hour, in another game a turn, a minute, a part of the day. The story never sets a
clock. Going back in time is the game restoring a moment it saved.

## A calendar

```river
== hollin (calendar)
  [clock hour] [scope world]
= watch
  [size 6] [place part] [names night, morning, afternoon, evening]
= day
  [size 4] [count day]
= week
  [cycle day] [place weekday] [names monday, tuesday, wednesday, thursday, friday, saturday, sunday]
= days_to_fair
  [until day 4] [per day]
```

`== hollin (calendar)` is a section of the kind `calendar`: it reads the clock and calls its ticks by the game's own
names. Nothing goes to it with `->`, and it is never said as a scene is. Its tags, under its heading: `[clock hour]`,
the clock it reads, and `[scope world]`, the scope the facts it keeps are kept in. `[start N]` would say where tick 0
falls in it; here it is the first watch of Monday, the night.

Its parts are its units, its cycles and the time facts it keeps, each tagged under its name:

- **A unit**, `[size …]`: how many of the unit before make one, and ticks for the first. A watch is six hours, a day
  four watches. `[place part]` names the fact that holds which watch of the day it is, and `[names night, morning,
  afternoon, evening]` its places, so `part` is one of those words. `[count day]` names the fact that counts the
  days, from 0. A unit of sizes that change, months of 31, 28 and 31 days, gives several sizes, which repeat in turn.
- **A cycle**, `[cycle day]`: a count that goes round a unit without nesting in it. A week is seven days, named in
  `[names …]`, its place in `weekday`; `[length …]` gives a cycle with no names its length, and `[offset …]` the place
  it is at on day 0.
- **A time fact**, named by its part: `[until day 4] [per day]` keeps `days_to_fair`, the days begun until day 4,
  never below 0. `[since …]` counts from a time instead, and `[drift …]` how far apart two clocks have run.

## The facts it keeps

`part`, `day`, `weekday` and `days_to_fair` are the calendar's: it declares them, the game writes them as the clock
moves, and the story reads them and never declares them. A story that declares one too is a mistake the checker
finds ([below](#when-the-checker-says-no)).

```river
== landing
{ part = night }
  The landing is dark, and the boat tied up under the lantern.
{ else }
  Ada is mending a rope on the landing.
{ days_to_fair > 0 } ADA: {days_to_fair as one: One day | other: {days_to_fair} days} to the fair.
- (bench)
+ Sit on the bench.
  You sit, and the river goes by.
  -> bench
* Go home.
  -> end
```

The landing reads them as it reads any fact: dark at night, and Ada counting down to the fair.

## Moving the clock

In a play you are the game, and you move its clock: `--wait N` before the story starts, and `:wait N` at any point
in it. A calendar's facts follow:

```console
$ riverrun play --wait 6 -i :facts -i 2 landing.river
> :wait 6
== landing
Ada is mending a rope on the landing.
ADA: 4 days to the fair.
* 1 Sit on the bench.
* 2 Go home.
> :facts
  hour = 6
  part = morning
  weekday = monday
  days_to_fair = 4
> 2
-> end
```

Six hours on from midnight it is Monday morning. `:facts` shows what the calendar wrote; `day` is not among them,
since `:facts` lists the facts not at the value they start at, and it is still day 0. Where a story has several
clocks, `:wait N CLOCK` names the one to move.

## A scene that comes due

```river
== last_ferry
  [every day] [at evening] [policy once]
ADA: Last ferry over! Last one tonight!
-> end

== market_boat
  [every week] [at saturday morning]
The market boat comes down from the mill, low in the water.
A BOATMAN: Flour for the fair!
-> end

== fair
  [at day 4 morning]
Across the river, the fair's flags go up.
-> end
```

Tags under a section's heading put it on the calendar, and the game tells it when its time comes:

- `[at …]`: a time, in the calendar's own facts: a count and places, `[at day 4 morning]`, `[at saturday morning]`,
  the first tick where all of them hold. A place is its name alone where no other place has that name, and else its
  fact and its name, `weekday saturday`. The fair comes due once.
- `[every …]`: again and again, every unit or cycle of the calendar, `[every day]`, `[every week]`, from the first
  time `[at …]` names. `[interval N]` makes it every N of them, and `[times N]` stops it after N.
- `[policy …]`: what a move of the clock that passes several of its times does: with `each` it comes due for each,
  the first first, and with `once` it comes due once for them all, saying how many it stands for. `each` is the
  default.
- `[calendar name]`: which calendar the times are of, where a story keeps more than one.

A scene that comes due while the story waits for the player is told then, in the middle of the scene the player is
in, and where it goes, the story goes:

```console
$ riverrun play -i 1 -i ':wait 18' landing.river
== landing
The landing is dark, and the boat tied up under the lantern.
ADA: 4 days to the fair.
* 1 Sit on the bench.
* 2 Go home.
> 1
You sit, and the river goes by.
* 1 Sit on the bench.
* 2 Go home.
> :wait 18
! due last_ferry
  at hour 18
== last_ferry
  [every day] [at evening] [policy once]
ADA: Last ferry over! Last one tonight!
-> end
```

`! due last_ferry` says what came due and at what tick. Ada's call ends with `-> end`, so the evening at the landing
ends with it. Where the story has ended already, a scene that comes due is told anew, as below.

## Taking a scene off the calendar

The river is up, and the game takes the last ferry off for good. `:cancel SCENE` is the game's call into tide that
does it; `:help` lists it with every scene the story puts on the calendar.

```console
$ riverrun play -i 2 -i ':cancel last_ferry' -i ':wait 24' -i ':cancel last_ferry' landing.river
== landing
The landing is dark, and the boat tied up under the lantern.
ADA: 4 days to the fair.
* 1 Sit on the bench.
* 2 Go home.
> 2
-> end
> :cancel last_ferry
! cancelled last_ferry
> :wait 24
> :cancel last_ferry
riverrun: error: the input `:cancel last_ferry`: `last_ferry` is on the calendar no more: it came due for the last time, or was cancelled
```

Monday evening comes and goes, and nothing comes due. A scene off the calendar, because it was cancelled or came
due for the last time, cannot be cancelled again, and the play says why.

## When the checker says no

tide checks a story's time inside `riverrun check`, each tag where it is written, against the calendar it means.
This copy, `mistakes/11/landing.river`, declares `day` itself, asks for a unit the calendar does not have, and
misspells Saturday:

```river refused
facts (world):
  hour: int   (clock)          // the game's clock: an hour a tick
  day: int   (game)            // which day it is
```

```river refused
== last_ferry
  [every fortnight] [at evening] [policy once]
ADA: Last ferry over! Last one tonight!
```

```river refused
== market_boat
  [every week] [at satuday morning]
```

```console
$ riverrun check landing.river
landing.river:15:19-15:22: error: `day` is declared twice: first at landing.river:8:3, then by the calendar `hollin`
landing.river:35:10-35:19: error: `fortnight` is not a unit or a cycle of this calendar
landing.river:40:20-40:35: error: `satuday` is not a place or a count of `hollin`
```

The first says both places `day` is declared; the calendar's `[count day]` already declares it, so the story's row
goes. A time is held to the calendar's facts, so `satuday` is not a place of it, and a schedule on no calendar, a
time the calendar never reaches, or a calendar whose units do not hold together, is said the same way, where it is
written.

## For the programmer who wires the game

The game's vocabulary registers tide. This is the vocabulary these stories are written for,
[stories/vocabulary.zig](stories/vocabulary.zig), whole:

```zig
//! The vocabulary of the game the time chapter's stories are written for:
//! the ferry at Hollin, as riverrun's manual has it, with tide registered so
//! that a story may keep a calendar and schedule its scenes. Your game has
//! its own.

const riverrun = @import("riverrun-compiler");
const tide = @import("tide-compiler");

// the game's subtitles hold 100 columns, and its choices 40
const width: riverrun.check.Width = .{ .line = 100, .choice = 40 };

pub const options: riverrun.check.Options = .{ .width = width };

// the packages the game runs: tide, for its time
pub const packages: []const riverrun.Package = &.{tide.package};
```

`packages` lists `tide.package`, which brings the `calendar` kind, the schedule tags, tide's checks and the block it
compiles into the story. The game's build hands tide's compiler side to riverrun's `addStory` as `tide-compiler`,
`tide.compiler(b.dependency("tide", riverrun.building(b)))`, as [tide's README](../../README.md) says and
[chapter 7](https://github.com/pedronaugusto/riverrun/blob/main/docs/manual/07-the-games-vocabulary.md#the-build)
shows for riverrun. The game loads the story's calendar with `tide.fromStory`, moves its clocks with `advance` (or by
its own elapsed time, at a rate), and tells each scene that comes due, as [tide's design](../design.md) says. In
tide's folder `bay manual` builds the `riverrun` program with this vocabulary into `zig-out/bin`.

## A week at the landing

The player goes home on Monday night, and the game moves the clock on through the week. This is
`stories/11/week.play`:

```console
$ riverrun play --script week.play landing.river
== landing
The landing is dark, and the boat tied up under the lantern.
ADA: 4 days to the fair.
* 1 Sit on the bench.
* 2 Go home.
> 2
-> end
> :wait 18
! due last_ferry
  at hour 18
== last_ferry
  [every day] [at evening] [policy once]
ADA: Last ferry over! Last one tonight!
-> end
> :wait 72
! due last_ferry
  3 times from hour 42, told as one
ADA: Last ferry over! Last one tonight!
-> end
> :facts
  hour = 90
  part = evening
  day = 3
  weekday = thursday
  days_to_fair = 1
> :wait 12
! due fair
  at hour 102
== fair
  [at day 4 morning]
Across the river, the fair's flags go up.
-> end
> :wait 12 hour
! due last_ferry
  at hour 114
== last_ferry
  [every day] [at evening] [policy once]
ADA: Last ferry over! Last one tonight!
-> end
> :wait 12
! due market_boat
  at hour 126
== market_boat
  [every week] [at saturday morning]
The market boat comes down from the mill, low in the water.
A BOATMAN: Flour for the fair!
-> end
> :facts
  hour = 126
  part = morning
  day = 5
  weekday = saturday
```

Each scene is told anew when it comes due, the story having ended. Three evenings passed in one move tell Ada's call
once, `3 times from hour 42, told as one`, since the last ferry's policy is `once`; the fair comes due on Friday
morning, day 4, as `days_to_fair` reaches 0 and leaves `:facts`. On Saturday morning the market boat comes down.
