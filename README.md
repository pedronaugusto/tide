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
