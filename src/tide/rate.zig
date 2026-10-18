//! How fast a clock runs: ticks per unit of the host's elapsed time, as a
//! ratio of integers. Elapsed time is converted exactly: the fraction of a
//! tick left over is carried to the next call, so many small elapses and one
//! large one reach the same tick, and no float ever drifts.

const std = @import("std");

pub const Rate = struct {
    /// Ticks gained for every `per` units of elapsed time.
    ticks: u32,
    per: u32,

    /// One tick per unit of elapsed time.
    pub const one: Rate = .{ .ticks = 1, .per = 1 };
    /// A clock the host advances itself, a step at a time: elapsed time moves it not at all.
    pub const zero: Rate = .{ .ticks = 0, .per = 1 };

    pub fn valid(r: Rate) bool {
        return r.per > 0;
    }
};

/// A rate with what is left over of a tick, in `1 / rate.per` parts.
pub const Meter = struct {
    rate: Rate = .one,
    paused: bool = false,
    /// Always below `rate.per`.
    carry: u64 = 0,

    /// The whole ticks `elapsed` is worth, the fraction kept for next time. Paused, nothing.
    pub fn convert(m: *Meter, elapsed: u64) u64 {
        std.debug.assert(m.rate.valid());
        std.debug.assert(m.carry < m.rate.per);
        if (m.paused) return 0;
        const parts = @as(u128, elapsed) * m.rate.ticks + m.carry;
        m.carry = @intCast(parts % m.rate.per); // safe: below `per`, a u32
        const whole = parts / m.rate.per;
        return std.math.cast(u64, whole) orelse std.math.maxInt(u64);
    }

    /// A new rate from now on; the fraction of a tick carried under the old one is dropped, so a rate always
    /// means the same from the moment it is set.
    pub fn set(m: *Meter, rate: Rate) void {
        std.debug.assert(rate.valid());
        m.rate = rate;
        m.carry = 0;
    }
};

test "many small elapses reach the tick one large one does" {
    var small: Meter = .{ .rate = .{ .ticks = 7, .per = 3 } };
    var large: Meter = small;
    var sum: u64 = 0;
    for (0..1000) |_| sum += small.convert(1);
    try std.testing.expectEqual(large.convert(1000), sum);
    try std.testing.expectEqual(small.carry, large.carry);
}

test "a paused or zero rate moves nothing, and keeps its fraction" {
    var m: Meter = .{ .rate = .{ .ticks = 1, .per = 2 } };
    try std.testing.expectEqual(@as(u64, 0), m.convert(1));
    m.paused = true;
    try std.testing.expectEqual(@as(u64, 0), m.convert(100));
    m.paused = false;
    try std.testing.expectEqual(@as(u64, 1), m.convert(1));
    m.set(.zero);
    try std.testing.expectEqual(@as(u64, 0), m.convert(1_000_000));
}
