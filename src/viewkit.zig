//! Small shared toolkit for the Log views: rich-text lines, number/time
//! formatting, delta arrows, key hints. Used by log_view.zig and dashboard.zig.
const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const draw = @import("draw.zig");
const dates = @import("dates.zig");
const stats = @import("stats.zig");

pub const Allocator = std.mem.Allocator;
pub const bg = theme.glass;

// ---- tiny rich-text lines ------------------------------------------------------------------

pub const Kind = enum { head, label, value, good, bad, warn, dim, plain };
pub const Seg = struct { text: []const u8, kind: Kind = .plain, color: ?theme.Color = null };
pub const Line = []const Seg;
pub const Lines = std.ArrayList(Line);

pub fn segStyle(s: Seg, row_bg: theme.Color) theme.Style {
    const fg: theme.Color = s.color orelse switch (s.kind) {
        .head, .value, .plain => theme.bone,
        .label => theme.bone_dim,
        .good => theme.ok,
        .bad => theme.p1,
        .warn => theme.p2,
        .dim => theme.bone_faint,
    };
    return .{ .fg = fg, .bg = row_bg, .bold = s.kind == .head };
}

pub fn f(a: Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, fmt, args) catch "?";
}

pub fn add(a: Allocator, lines: *Lines, segs: []const Seg) void {
    const owned = a.dupe(Seg, segs) catch return;
    lines.append(a, owned) catch {};
}

pub fn blank(a: Allocator, lines: *Lines) void {
    add(a, lines, &.{});
}

pub fn drawLine(win: vaxis.Window, x: u16, y: u16, w: u16, line: Line, row_bg: theme.Color) void {
    var cx: u16 = x;
    const end = x + w;
    for (line) |s| {
        if (cx >= end) break;
        cx += draw.text(win, cx, y, end - cx, s.text, segStyle(s, row_bg));
    }
}

pub fn drawLines(win: vaxis.Window, x: u16, y: u16, w: u16, h: u16, lines: []const Line, scroll: usize) void {
    var i: usize = 0;
    while (i < h and scroll + i < lines.len) : (i += 1) drawLine(win, x, y + @as(u16, @intCast(i)), w, lines[scroll + i], bg);
}

// ---- formatting helpers -----------------------------------------------------------------------

/// "3h 07m" / "45m" / "0m", rounded to the nearest minute.
pub fn hm(a: Allocator, secs: i64) []const u8 {
    const m: u64 = @intCast(@divFloor(@max(secs, 0) + 30, 60));
    if (m == 0 and secs > 0) return "<1m"; // some work happened, just not a whole minute
    if (m < 60) return f(a, "{d}m", .{m});
    return f(a, "{d}h {d:0>2}m", .{ m / 60, m % 60 });
}

pub fn hmHours(a: Allocator, hours: f64) []const u8 {
    return hm(a, @intFromFloat(@round(@max(hours, 0) * 3600)));
}

pub fn clip(a: Allocator, s: []const u8, max: usize) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (n == max) return f(a, "{s}…", .{s[0..i]});
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        n += 1;
    }
    return s;
}

pub const partial_blocks = [_][]const u8{ "", "▏", "▎", "▍", "▌", "▋", "▊", "▉" };

pub fn bar(a: Allocator, frac: f64, cells: usize) []const u8 {
    const eighths: usize = @intFromFloat(@round(std.math.clamp(frac, 0, 1) * @as(f64, @floatFromInt(cells * 8))));
    var buf: std.ArrayList(u8) = .empty;
    for (0..eighths / 8) |_| buf.appendSlice(a, "█") catch {};
    buf.appendSlice(a, partial_blocks[eighths % 8]) catch {};
    return buf.items;
}

pub fn probKind(p: f64) Kind {
    return if (p >= 0.66) .good else if (p >= 0.33) .warn else .bad;
}

pub fn percentText(a: Allocator, p: f64) []const u8 {
    return f(a, "{d}%", .{@as(u32, @intFromFloat(@round(std.math.clamp(p, 0, 1) * 100)))});
}

/// A probability estimated from data: never claim certainty either way.
pub fn probText(a: Allocator, p: f64) []const u8 {
    if (p < 0.005) return "<1%";
    if (p > 0.995) return ">99%";
    return percentText(a, p);
}

/// ▲ +23% (green) / ▼ -12% (red). More is better for everything we compare.
pub fn deltaSeg(a: Allocator, d: stats.Delta) Seg {
    if (d.pct()) |p| {
        const mag = @abs(p);
        if (mag < 0.05) return .{ .text = "= 0%", .kind = .dim };
        const num = if (mag >= 1000) ">999" else if (mag >= 10) f(a, "{d:.0}", .{mag}) else f(a, "{d:.1}", .{mag});
        return if (p > 0)
            .{ .text = f(a, "▲ +{s}%", .{num}), .kind = .good }
        else
            .{ .text = f(a, "▼ -{s}%", .{num}), .kind = .bad };
    }
    if (d.cur > 0) return .{ .text = "▲ new", .kind = .good }; // nothing to compare with
    return .{ .text = "–", .kind = .dim };
}

pub fn hints(win: vaxis.Window, x: u16, y: u16, w: u16, items: []const [2][]const u8) void {
    var cx = x;
    for (items) |h| {
        const kw = win.gwidth(h[0]);
        const lw = win.gwidth(h[1]);
        if (cx + kw + 1 + lw > x + w) break;
        _ = draw.text(win, cx, y, kw, h[0], .{ .fg = theme.bone, .bg = bg, .bold = true });
        _ = draw.text(win, cx + kw + 1, y, lw, h[1], .{ .fg = theme.bone_faint, .bg = bg });
        cx += kw + 1 + lw + 3;
    }
}

pub fn clock(a: Allocator, tz: dates.Tz, t: i64) []const u8 {
    const mins: u64 = @intCast(@divFloor(@mod(t + tz.offset(t), 86400), 60));
    return f(a, "{d:0>2}:{d:0>2}", .{ mins / 60, mins % 60 });
}

