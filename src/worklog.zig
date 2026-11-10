//! The work log: an append-only history of what happened on the board, kept
//! apart from the tasks themselves so it survives edits and deletions.
//!
//!   session  a stretch of work: a task sat in "In Progress" from `start` to `end`
//!   done     a task was moved into Done (`took` = its total tracked seconds then)
//!   undone   a task left Done again (its completion no longer counts)
//!
//! Every entry carries a snapshot of the task's title and priority. The file
//! (WORKLOG1) is one entry per line, tab-separated, so it's easy to grep:
//!   S <id> <start> <end> <priority> <title>
//!   D <id> <at> <took_secs> <priority> <title>
//!   U <id> <at>
const std = @import("std");
const storage = @import("storage.zig");

const magic = "WORKLOG1";

pub const Session = struct { id: u32, start: i64, end: i64, priority: u8, title: []const u8 };
pub const Done = struct { id: u32, at: i64, took: i64, priority: u8, title: []const u8 };
pub const Undone = struct { id: u32, at: i64 };

pub const Entry = union(enum) {
    session: Session,
    done: Done,
    undone: Undone,

    pub fn deinit(self: Entry, alloc: std.mem.Allocator) void {
        switch (self) {
            .session => |s| alloc.free(s.title),
            .done => |d| alloc.free(d.title),
            .undone => {},
        }
    }
};

pub const Log = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(alloc: std.mem.Allocator) Log {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Log) void {
        for (self.entries.items) |e| e.deinit(self.alloc);
        self.entries.deinit(self.alloc);
    }

    /// Take ownership of `e` (its title must have been allocated with this log's allocator).
    pub fn adopt(self: *Log, e: Entry) !void {
        errdefer e.deinit(self.alloc);
        try self.entries.append(self.alloc, e);
    }
};

pub fn serialize(a: std.mem.Allocator, log: *const Log) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, magic ++ "\n");
    for (log.entries.items) |e| switch (e) {
        .session => |s| try out.print(a, "S\t{d}\t{d}\t{d}\t{d}\t{s}\n", .{ s.id, s.start, s.end, s.priority, s.title }),
        .done => |d| try out.print(a, "D\t{d}\t{d}\t{d}\t{d}\t{s}\n", .{ d.id, d.at, d.took, d.priority, d.title }),
        .undone => |u| try out.print(a, "U\t{d}\t{d}\n", .{ u.id, u.at }),
    };
    return out.toOwnedSlice(a);
}

/// Timestamps outside 1970-01-01 .. 9999-12-31 (UTC) are clamped into it on load, so
/// a corrupted or hostile log can't overflow day arithmetic further down.
pub const min_time: i64 = 0;
pub const max_time: i64 = 253402300799;

pub fn clampTime(t: i64) i64 {
    return std.math.clamp(t, min_time, max_time);
}

fn parseTime(text: ?[]const u8) ?i64 {
    return clampTime(std.fmt.parseInt(i64, text orelse return null, 10) catch return null);
}

pub fn parse(log: *Log, data: []const u8) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    const header = lines.next() orelse return;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, header, "\r"), magic)) return error.BadFormat;

    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 3) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const kind = f.next() orelse continue;
        const id = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        switch (kind[0]) {
            'S' => {
                const start = parseTime(f.next()) orelse continue;
                const end = parseTime(f.next()) orelse continue;
                const prio = std.fmt.parseInt(u8, f.next() orelse continue, 10) catch continue;
                if (end <= start) continue;
                const title = try log.alloc.dupe(u8, f.rest());
                try log.adopt(.{ .session = .{ .id = id, .start = start, .end = end, .priority = std.math.clamp(prio, 1, 4), .title = title } });
            },
            'D' => {
                const at = parseTime(f.next()) orelse continue;
                const took = parseTime(f.next()) orelse continue;
                const prio = std.fmt.parseInt(u8, f.next() orelse continue, 10) catch continue;
                const title = try log.alloc.dupe(u8, f.rest());
                try log.adopt(.{ .done = .{ .id = id, .at = at, .took = took, .priority = std.math.clamp(prio, 1, 4), .title = title } });
            },
            'U' => {
                const at = parseTime(f.next()) orelse continue;
                try log.adopt(.{ .undone = .{ .id = id, .at = at } });
            },
            else => {},
        }
    }
}

pub fn load(io: std.Io, alloc: std.mem.Allocator, path: []const u8, log: *Log) !void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer alloc.free(data);
    if (storage.isBlank(data)) return;
    try parse(log, data);
}

pub fn save(io: std.Io, alloc: std.mem.Allocator, path: []const u8, log: *const Log) !void {
    const data = try serialize(alloc, log);
    defer alloc.free(data);
    try storage.atomicWrite(io, alloc, path, data);
}

test "round trip" {
    const a = std.testing.allocator;
    var log = Log.init(a);
    defer log.deinit();
    try log.adopt(.{ .session = .{ .id = 1, .start = 100, .end = 400, .priority = 2, .title = try a.dupe(u8, "write thesis") } });
    try log.adopt(.{ .done = .{ .id = 1, .at = 400, .took = 300, .priority = 2, .title = try a.dupe(u8, "write thesis") } });
    try log.adopt(.{ .undone = .{ .id = 1, .at = 500 } });

    const data = try serialize(a, &log);
    defer a.free(data);
    var back = Log.init(a);
    defer back.deinit();
    try parse(&back, data);
    try std.testing.expectEqual(@as(usize, 3), back.entries.items.len);
    try std.testing.expectEqualStrings("write thesis", back.entries.items[1].done.title);
    try std.testing.expectEqual(@as(i64, 300), back.entries.items[1].done.took);
    try std.testing.expectEqual(@as(i64, 500), back.entries.items[2].undone.at);
}

test "out-of-range timestamps are clamped" {
    const a = std.testing.allocator;
    var log = Log.init(a);
    defer log.deinit();
    try parse(&log, magic ++ "\nS\t1\t0\t9223372036854775807\t1\tx\nS\t2\t-180000000000000\t5\t1\ty\nD\t3\t-9223372036854775808\t-7\t1\tz\n");
    try std.testing.expectEqual(@as(usize, 3), log.entries.items.len);
    try std.testing.expectEqual(max_time, log.entries.items[0].session.end);
    try std.testing.expectEqual(min_time, log.entries.items[1].session.start);
    try std.testing.expectEqual(min_time, log.entries.items[2].done.at);
    try std.testing.expectEqual(@as(i64, 0), log.entries.items[2].done.took);
}
