//! The statistics parameters, saved next to the board as plain `key=value` lines.
const std = @import("std");
const stats = @import("stats.zig");
const storage = @import("storage.zig");

pub fn load(io: std.Io, alloc: std.mem.Allocator, path: []const u8, params: *stats.Params) !void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer alloc.free(data);
    parse(params, data);
}

pub fn parse(params: *stats.Params, data: []const u8) void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.fmt.parseInt(u32, std.mem.trim(u8, line[eq + 1 ..], " \t"), 10) catch continue;
        const small: u8 = @intCast(@min(val, 255));
        if (std.mem.eql(u8, key, "goal_hours")) params.goal_hours = small;
        if (std.mem.eql(u8, key, "active_min")) params.active_min = @intCast(@min(val, 65535));
        if (std.mem.eql(u8, key, "alpha_pct")) params.alpha_pct = small;
        if (std.mem.eql(u8, key, "window_weeks")) params.window_weeks = small;
    }
    params.clamp();
}

pub fn save(io: std.Io, alloc: std.mem.Allocator, path: []const u8, params: stats.Params) !void {
    const text = try std.fmt.allocPrint(alloc, "goal_hours={d}\nactive_min={d}\nalpha_pct={d}\nwindow_weeks={d}\n", .{ params.goal_hours, params.active_min, params.alpha_pct, params.window_weeks });
    defer alloc.free(text);
    try storage.atomicWrite(io, alloc, path, text);
}

test "parse clamps and ignores junk" {
    var p: stats.Params = .{};
    parse(&p, "goal_hours=20\nactive_min=1\nalpha_pct=999\nwindow_weeks=abc\nnonsense\nother=5\n");
    try std.testing.expectEqual(@as(u8, 20), p.goal_hours);
    try std.testing.expectEqual(@as(u16, 5), p.active_min); // clamped up
    try std.testing.expectEqual(@as(u8, 95), p.alpha_pct); // clamped down
    try std.testing.expectEqual(@as(u8, 8), p.window_weeks); // unreadable value keeps the default
}
