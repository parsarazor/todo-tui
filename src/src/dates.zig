//! Tiny calendar helpers. Dates are stored as "days since 1970-01-01" (i32).
const std = @import("std");
const builtin = @import("builtin");

pub const Date = struct { y: i32, m: u8, d: u8 };

pub const ParseError = error{Invalid};

pub const Urgency = enum { overdue, soon, normal };

// Howard Hinnant's civil-calendar algorithms.
pub fn daysFromCivil(y_in: i32, m: u8, d: u8) i32 {
    const y: i32 = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe: i32 = y - era * 400;
    const mp: i32 = @mod(@as(i32, m) + 9, 12);
    const doy: i32 = @divFloor(153 * mp + 2, 5) + @as(i32, d) - 1;
    const doe: i32 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn civilFromDays(z_in: i32) Date {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + (if (m <= 2) @as(i32, 1) else 0);
    return .{ .y = y, .m = @intCast(m), .d = @intCast(d) };
}

fn isLeap(y: i32) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

fn daysInMonth(y: i32, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if (isLeap(y)) 29 else 28,
    };
}

fn validYmd(y: i32, m: i32, d: i32) bool {
    if (y < 1970 or y > 9999) return false;
    if (m < 1 or m > 12) return false;
    if (d < 1 or d > daysInMonth(y, @intCast(m))) return false;
    return true;
}

/// Accepts: "" (no deadline), YYYY-MM-DD, MM-DD (next occurrence),
/// +N / +Nd / +Nw (relative), today, tomorrow.
pub fn parse(text_in: []const u8, today: i32) ParseError!?i32 {
    const t = std.mem.trim(u8, text_in, " \t");
    if (t.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(t, "today")) return today;
    if (std.ascii.eqlIgnoreCase(t, "tomorrow")) return today + 1;

    if (t[0] == '+') {
        var s = t[1..];
        var mult: i32 = 1;
        if (s.len > 0) switch (s[s.len - 1]) {
            'd', 'D' => s = s[0 .. s.len - 1],
            'w', 'W' => {
                s = s[0 .. s.len - 1];
                mult = 7;
            },
            else => {},
        };
        const n = std.fmt.parseInt(i32, s, 10) catch return error.Invalid;
        if (n < 0 or n > 3650) return error.Invalid;
        return today + n * mult;
    }

    var it = std.mem.splitScalar(u8, t, '-');
    const a = it.next() orelse return error.Invalid;
    const b = it.next() orelse return error.Invalid;
    const c = it.next();
    if (it.next() != null) return error.Invalid;

    if (c) |cs| {
        if (a.len != 4) return error.Invalid;
        const y = std.fmt.parseInt(i32, a, 10) catch return error.Invalid;
        const m = std.fmt.parseInt(i32, b, 10) catch return error.Invalid;
        const d = std.fmt.parseInt(i32, cs, 10) catch return error.Invalid;
        if (!validYmd(y, m, d)) return error.Invalid;
        return daysFromCivil(y, @intCast(m), @intCast(d));
    }

    const m = std.fmt.parseInt(i32, a, 10) catch return error.Invalid;
    const d = std.fmt.parseInt(i32, b, 10) catch return error.Invalid;
    const y = civilFromDays(today).y;
    if (!validYmd(y, m, d)) return error.Invalid;
    var days = daysFromCivil(y, @intCast(m), @intCast(d));
    if (days < today) {
        if (!validYmd(y + 1, m, d)) return error.Invalid;
        days = daysFromCivil(y + 1, @intCast(m), @intCast(d));
    }
    return days;
}

pub fn format(buf: []u8, days: i32) []const u8 {
    const c = civilFromDays(days);
    // unsigned on purpose: `{d}` on a signed int would print a leading '+'
    const y: u32 = @intCast(c.y);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ y, c.m, c.d }) catch "????-??-??";
}

pub fn weekday(days: i32) []const u8 {
    // 1970-01-01 was a Thursday.
    const names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    return names[@intCast(@mod(days, 7))];
}

pub fn relative(buf: []u8, deadline: i32, today: i32) []const u8 {
    const diff = deadline - today;
    return switch (diff) {
        0 => "today",
        1 => "tomorrow",
        -1 => "1d overdue",
        else => if (diff > 0)
            std.fmt.bufPrint(buf, "in {d}d", .{diff}) catch "soon"
        else
            std.fmt.bufPrint(buf, "{d}d overdue", .{-diff}) catch "overdue",
    };
}

pub fn urgency(deadline: i32, today: i32) Urgency {
    if (deadline < today) return .overdue;
    if (deadline - today <= 2) return .soon;
    return .normal;
}

// ---- local "today" ------------------------------------------------------

const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;

/// Seconds since the Unix epoch (UTC). Used for task timers.
pub fn unixNow(io: std.Io) i64 {
    const ns: i96 = std.Io.Clock.real.now(io).nanoseconds;
    return @intCast(@divFloor(ns, 1_000_000_000));
}

/// "42s", "12m 05s", "3h 07m", "2d 4h".
pub fn formatDuration(buf: []u8, secs_in: i64) []const u8 {
    const secs: u64 = @intCast(@max(secs_in, 0));
    const r = if (secs < 60)
        std.fmt.bufPrint(buf, "{d}s", .{secs})
    else if (secs < 3600)
        std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ secs / 60, secs % 60 })
    else if (secs < 86400)
        std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ secs / 3600, secs % 3600 / 60 })
    else
        std.fmt.bufPrint(buf, "{d}d {d}h", .{ secs / 86400, secs % 86400 / 3600 });
    return r catch "?";
}

/// "just now", "12m ago", "3h ago", "5d ago".
pub fn formatAgo(buf: []u8, secs_in: i64) []const u8 {
    const secs: u64 = @intCast(@max(secs_in, 0));
    const r = if (secs < 60)
        std.fmt.bufPrint(buf, "just now", .{})
    else if (secs < 3600)
        std.fmt.bufPrint(buf, "{d}m ago", .{secs / 60})
    else if (secs < 86400)
        std.fmt.bufPrint(buf, "{d}h ago", .{secs / 3600})
    else
        std.fmt.bufPrint(buf, "{d}d ago", .{secs / 86400});
    return r catch "?";
}

/// A time zone, as far as this app cares: how many seconds east of UTC it is at a
/// given moment. `fixed` exists so tests don't depend on the machine's zone.
pub const Tz = struct {
    fixed: ?i64 = null,

    pub fn offset(self: Tz, t: i64) i64 {
        if (self.fixed) |f| return f;
        if (comptime builtin.os.tag != .windows and builtin.link_libc) {
            var tm: Tm = undefined;
            const tt = t;
            if (localtime_r(&tt, &tm) != null) return tm.tm_gmtoff;
        }
        return 0;
    }

    /// Local calendar day (days since 1970-01-01) containing the Unix time `t`.
    pub fn dayOf(self: Tz, t: i64) i32 {
        return @intCast(@divFloor(t + self.offset(t), 86400));
    }

    /// Unix time of local midnight at the start of `day`.
    pub fn dayStart(self: Tz, day: i32) i64 {
        const base: i64 = @as(i64, day) * 86400;
        return base - self.offset(base + 43200);
    }

    /// Hour of the local day (0-23) for `t`.
    pub fn hourOf(self: Tz, t: i64) u8 {
        return @intCast(@mod(@divFloor(t + self.offset(t), 3600), 24));
    }
};

/// Weekday with Monday = 0 ... Sunday = 6.
pub fn weekdayIndex(day: i32) u8 {
    return @intCast(@mod(day + 3, 7)); // 1970-01-01 was a Thursday
}

/// The Monday on or before `day`.
pub fn weekStart(day: i32) i32 {
    return day - weekdayIndex(day);
}

pub const weekday_names = [7][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
pub const month_names = [12][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// "12 Oct"
pub fn formatDayMonth(buf: []u8, day: i32) []const u8 {
    const c = civilFromDays(day);
    return std.fmt.bufPrint(buf, "{d} {s}", .{ c.d, month_names[c.m - 1] }) catch "?";
}

/// Today's date in the machine's local time zone (falls back to UTC).
pub fn todayLocal(io: std.Io) i32 {
    const ns: i96 = std.Io.Clock.real.now(io).nanoseconds;
    const secs: i64 = @intCast(@divFloor(ns, 1_000_000_000));
    var off: i64 = 0;
    if (comptime builtin.os.tag != .windows and builtin.link_libc) {
        var tm: Tm = undefined;
        if (localtime_r(&secs, &tm) != null) off = tm.tm_gmtoff;
    }
    return @intCast(@divFloor(secs + off, 86400));
}

test "civil round trip" {
    const d = daysFromCivil(2026, 9, 30);
    const c = civilFromDays(d);
    try std.testing.expectEqual(@as(i32, 2026), c.y);
    try std.testing.expectEqual(@as(u8, 9), c.m);
    try std.testing.expectEqual(@as(u8, 30), c.d);
    try std.testing.expectEqualStrings("Wed", weekday(d));
}

test "parse" {
    const today = daysFromCivil(2026, 9, 30);
    try std.testing.expectEqual(@as(?i32, null), try parse("  ", today));
    try std.testing.expectEqual(@as(?i32, today + 3), try parse("+3", today));
    try std.testing.expectEqual(@as(?i32, today + 14), try parse("+2w", today));
    try std.testing.expectEqual(@as(?i32, today + 1), try parse("Tomorrow", today));
    try std.testing.expectEqual(@as(?i32, daysFromCivil(2026, 10, 5)), try parse("2026-10-05", today));
    try std.testing.expectEqual(@as(?i32, daysFromCivil(2026, 12, 1)), try parse("12-01", today));
    // month-day already passed this year rolls to next year
    try std.testing.expectEqual(@as(?i32, daysFromCivil(2027, 1, 5)), try parse("01-05", today));
    try std.testing.expectError(error.Invalid, parse("2026-02-30", today));
    try std.testing.expectError(error.Invalid, parse("soon", today));
}

test "weeks start on Monday" {
    const wed = daysFromCivil(2026, 10, 14);
    try std.testing.expectEqual(@as(u8, 2), weekdayIndex(wed));
    try std.testing.expectEqual(daysFromCivil(2026, 10, 12), weekStart(wed));
    try std.testing.expectEqual(daysFromCivil(2026, 10, 12), weekStart(daysFromCivil(2026, 10, 18))); // Sunday
    try std.testing.expectEqual(daysFromCivil(2026, 10, 19), weekStart(daysFromCivil(2026, 10, 19))); // Monday
    const tz: Tz = .{ .fixed = 3600 * 3 };
    try std.testing.expectEqual(wed, tz.dayOf(tz.dayStart(wed) + 5));
    try std.testing.expectEqual(wed - 1, tz.dayOf(tz.dayStart(wed) - 1));
    try std.testing.expectEqual(@as(u8, 0), tz.hourOf(tz.dayStart(wed)));
}

test "durations" {
    var b: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0s", formatDuration(&b, -5));
    try std.testing.expectEqualStrings("42s", formatDuration(&b, 42));
    try std.testing.expectEqualStrings("12m 05s", formatDuration(&b, 12 * 60 + 5));
    try std.testing.expectEqualStrings("3h 07m", formatDuration(&b, 3 * 3600 + 7 * 60 + 59));
    try std.testing.expectEqualStrings("2d 4h", formatDuration(&b, 2 * 86400 + 4 * 3600));
}

test "format has no sign" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("2026-09-30", format(&b, daysFromCivil(2026, 9, 30)));
}
