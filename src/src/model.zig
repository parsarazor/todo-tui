//! Pure task model: no terminal, no I/O. Everything here is unit-testable.
const std = @import("std");
const worklog = @import("worklog.zig");

pub const Status = enum { backlog, doing, done };

/// The six places a task can live. q1..q4 are the priority-matrix quadrants
/// inside the backlog column (q1 = priority 1 ... q4 = priority 4).
pub const Zone = enum(u3) {
    q1,
    q2,
    q3,
    q4,
    doing,
    done,

    pub const count = 6;

    pub fn fromIndex(i: usize) Zone {
        return @enumFromInt(i);
    }
    pub fn index(self: Zone) usize {
        return @intFromEnum(self);
    }
    pub fn isMatrix(self: Zone) bool {
        return self.index() < 4;
    }
    /// Priority number represented by a matrix quadrant.
    pub fn priority(self: Zone) ?u8 {
        return if (self.isMatrix()) @as(u8, @intCast(self.index())) + 1 else null;
    }
};

pub const Dir = enum { left, right, up, down };

/// Spatial neighbour used for cursor movement and keyboard "move task".
pub fn neighbor(z: Zone, dir: Dir, last_matrix: Zone) ?Zone {
    return switch (z) {
        .q1 => switch (dir) {
            .right => .q2,
            .down => .q3,
            else => null,
        },
        .q2 => switch (dir) {
            .left => .q1,
            .down => .q4,
            .right => .doing,
            .up => null,
        },
        .q3 => switch (dir) {
            .up => .q1,
            .right => .q4,
            else => null,
        },
        .q4 => switch (dir) {
            .up => .q2,
            .left => .q3,
            .right => .doing,
            .down => null,
        },
        .doing => switch (dir) {
            .left => last_matrix,
            .right => .done,
            else => null,
        },
        .done => switch (dir) {
            .left => .doing,
            else => null,
        },
    };
}

pub const Task = struct {
    id: u32,
    title: []u8,
    status: Status,
    /// 1 (do first) .. 4 (drop). In the backlog this *is* the quadrant.
    priority: u8,
    /// days since 1970-01-01
    deadline: ?i32,
    /// Seconds already spent in "doing" during earlier sessions.
    spent: i64 = 0,
    /// Unix time the current "doing" session began; non-null only while doing.
    started: ?i64 = null,
    /// Practice task: how many multiple-choice questions it covers (0 = an ordinary task).
    tests: u32 = 0,
};

pub const max_tests: u32 = 9999;

/// Total tracked seconds, including the session that is running right now.
pub fn elapsed(t: Task, now: i64) i64 {
    const live: i64 = if (t.started) |s| @max(now - s, 0) else 0;
    return t.spent + live;
}

pub fn zoneOf(t: Task) Zone {
    return switch (t.status) {
        .doing => .doing,
        .done => .done,
        .backlog => Zone.fromIndex(t.priority - 1),
    };
}

pub const max_title = 200;

pub const Board = struct {
    alloc: std.mem.Allocator,
    tasks: std.ArrayList(Task) = .empty,
    next_id: u32 = 1,
    /// Work-log entries produced by status changes, waiting to be handed to the log.
    pending: std.ArrayList(worklog.Entry) = .empty,

    pub fn init(alloc: std.mem.Allocator) Board {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Board) void {
        for (self.tasks.items) |t| self.alloc.free(t.title);
        self.tasks.deinit(self.alloc);
        for (self.pending.items) |e| e.deinit(self.alloc);
        self.pending.deinit(self.alloc);
    }

    fn cleanTitle(self: *Board, raw: []const u8) ![]u8 {
        var s = std.mem.trim(u8, raw, " \t\r\n");
        if (s.len > max_title) {
            var end: usize = max_title;
            while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1; // don't cut a UTF-8 sequence
            s = s[0..end];
        }
        const out = try self.alloc.dupe(u8, s);
        for (out) |*c| {
            if (c.* < 0x20 or c.* == 0x7f) c.* = ' ';
        }
        return out;
    }

    pub fn add(self: *Board, title: []const u8, status: Status, priority: u8, deadline: ?i32, now: i64) !u32 {
        return self.addTests(title, status, priority, deadline, 0, now);
    }

    pub fn addTests(self: *Board, title: []const u8, status: Status, priority: u8, deadline: ?i32, tests: u32, now: i64) !u32 {
        const id = self.next_id;
        try self.restore(id, title, status, priority, deadline, 0, if (status == .doing) now else null, tests);
        if (status == .done) self.emitDone(&self.tasks.items[self.tasks.items.len - 1], now);
        return id;
    }

    /// Insert with a known id (used by storage).
    pub fn restore(self: *Board, id: u32, title: []const u8, status: Status, priority: u8, deadline: ?i32, spent: i64, started: ?i64, tests: u32) !void {
        const owned = try self.cleanTitle(title);
        errdefer self.alloc.free(owned);
        try self.tasks.append(self.alloc, .{
            .id = id,
            .title = owned,
            .status = status,
            .priority = std.math.clamp(priority, 1, 4),
            .deadline = deadline,
            .spent = @max(spent, 0),
            .started = if (status == .doing) started else null,
            .tests = @min(tests, max_tests),
        });
        if (id >= self.next_id) self.next_id = id + 1;
    }

    pub fn indexOf(self: *const Board, id: u32) ?usize {
        for (self.tasks.items, 0..) |t, i| if (t.id == id) return i;
        return null;
    }

    pub fn get(self: *Board, id: u32) ?*Task {
        const i = self.indexOf(id) orelse return null;
        return &self.tasks.items[i];
    }

    pub fn getConst(self: *const Board, id: u32) ?*const Task {
        const i = self.indexOf(id) orelse return null;
        return &self.tasks.items[i];
    }

    pub fn remove(self: *Board, id: u32, now: i64) void {
        const i = self.indexOf(id) orelse return;
        if (self.tasks.items[i].status == .doing) self.closeSession(&self.tasks.items[i], now);
        self.alloc.free(self.tasks.items[i].title);
        _ = self.tasks.orderedRemove(i);
    }

    pub fn update(self: *Board, id: u32, title: []const u8, priority: u8, deadline: ?i32, tests: u32) !void {
        const t = self.get(id) orelse return;
        const owned = try self.cleanTitle(title);
        self.alloc.free(t.title);
        t.title = owned;
        t.priority = std.math.clamp(priority, 1, 4);
        t.deadline = deadline;
        const n = @min(tests, max_tests);
        // a finished task keeps its completion in the log: tell the log about the new count
        if (t.status == .done and n != t.tests) self.emit(.{ .tests = .{ .id = t.id, .tests = n } });
        t.tests = n;
    }

    // ---- status changes, stopwatch and work log ----------------------------------

    fn emit(self: *Board, e: worklog.Entry) void {
        self.pending.append(self.alloc, e) catch e.deinit(self.alloc);
    }

    fn emitDone(self: *Board, t: *const Task, at: i64) void {
        const title = self.alloc.dupe(u8, t.title) catch return;
        self.emit(.{ .done = .{ .id = t.id, .at = at, .took = elapsed(t.*, at), .priority = t.priority, .title = title } });
        if (t.tests > 0) self.emit(.{ .tests = .{ .id = t.id, .tests = t.tests } });
    }

    /// End the running stopwatch session: bank its seconds and log it.
    fn closeSession(self: *Board, t: *Task, now: i64) void {
        const start = t.started orelse return;
        t.started = null;
        t.spent += @max(now - start, 0);
        if (now <= start) return;
        const title = self.alloc.dupe(u8, t.title) catch return;
        self.emit(.{ .session = .{ .id = t.id, .start = start, .end = now, .priority = t.priority, .title = title } });
    }

    /// Change status and keep the stopwatch and the log consistent: entering
    /// "doing" starts it, leaving "doing" banks and logs the session, entering
    /// Done logs a completion, leaving Done revokes it.
    fn transition(self: *Board, t: *Task, new: Status, now: i64) void {
        if (t.status == new) return;
        if (t.status == .doing) self.closeSession(t, now);
        if (t.status == .done) self.emit(.{ .undone = .{ .id = t.id, .at = now } });
        if (new == .doing) t.started = now;
        t.status = new;
        if (new == .done) self.emitDone(t, now);
    }

    /// Move everything the board has logged since the last call into `log`.
    pub fn drainEvents(self: *Board, log: *worklog.Log) !bool {
        if (self.pending.items.len == 0) return false;
        defer self.pending.clearRetainingCapacity();
        for (self.pending.items) |e| try log.adopt(e);
        return true;
    }

    pub fn moveToZone(self: *Board, id: u32, zone: Zone, now: i64) void {
        const t = self.get(id) orelse return;
        switch (zone) {
            .doing => self.transition(t, .doing, now),
            .done => self.transition(t, .done, now),
            else => {
                self.transition(t, .backlog, now);
                t.priority = zone.priority().?;
            },
        }
    }

    pub fn setPriority(self: *Board, id: u32, p: u8) void {
        const t = self.get(id) orelse return;
        t.priority = std.math.clamp(p, 1, 4);
    }

    /// backlog -> doing -> done
    pub fn advance(self: *Board, id: u32, now: i64) void {
        const t = self.get(id) orelse return;
        self.transition(t, switch (t.status) {
            .backlog => .doing,
            .doing => .done,
            .done => .done,
        }, now);
    }

    const SortCtx = struct {
        board: *const Board,
        fn less(ctx: SortCtx, a: u32, b: u32) bool {
            const ta = ctx.board.getConst(a).?;
            const tb = ctx.board.getConst(b).?;
            if (ta.priority != tb.priority) return ta.priority < tb.priority;
            const da = ta.deadline orelse std.math.maxInt(i32);
            const db = tb.deadline orelse std.math.maxInt(i32);
            if (da != db) return da < db;
            return ta.id < tb.id;
        }
    };

    /// Ids living in `zone`, ordered by priority, then earliest deadline, then age.
    pub fn idsIn(self: *const Board, alloc: std.mem.Allocator, zone: Zone) ![]u32 {
        var list: std.ArrayList(u32) = .empty;
        errdefer list.deinit(alloc);
        for (self.tasks.items) |t| {
            if (zoneOf(t) == zone) try list.append(alloc, t.id);
        }
        std.mem.sort(u32, list.items, SortCtx{ .board = self }, SortCtx.less);
        return list.toOwnedSlice(alloc);
    }
};

test "move and sort" {
    const a = std.testing.allocator;
    var b = Board.init(a);
    defer b.deinit();
    const t1 = try b.add("late", .backlog, 1, 200, 0);
    const t2 = try b.add("early", .backlog, 1, 100, 0);
    const t3 = try b.add("none", .backlog, 1, null, 0);
    const ids = try b.idsIn(a, .q1);
    defer a.free(ids);
    try std.testing.expectEqualSlices(u32, &.{ t2, t1, t3 }, ids);

    b.moveToZone(t1, .q3, 0);
    try std.testing.expectEqual(Zone.q3, zoneOf(b.getConst(t1).?.*));
    b.moveToZone(t1, .doing, 0);
    try std.testing.expectEqual(@as(u8, 3), b.getConst(t1).?.priority); // priority is kept
    b.advance(t1, 0);
    try std.testing.expectEqual(Zone.done, zoneOf(b.getConst(t1).?.*));
}

test "title is sanitised" {
    const a = std.testing.allocator;
    var b = Board.init(a);
    defer b.deinit();
    const id = try b.add("  hello\tworld\n ", .backlog, 9, null, 0);
    try std.testing.expectEqualStrings("hello world", b.getConst(id).?.title);
    try std.testing.expectEqual(@as(u8, 4), b.getConst(id).?.priority);
}

test "stopwatch" {
    const a = std.testing.allocator;
    var b = Board.init(a);
    defer b.deinit();
    const id = try b.add("work", .backlog, 1, null, 1000);
    try std.testing.expectEqual(@as(i64, 0), elapsed(b.getConst(id).?.*, 5000));

    b.moveToZone(id, .doing, 1000); // start
    try std.testing.expectEqual(@as(i64, 90), elapsed(b.getConst(id).?.*, 1090)); // live

    b.moveToZone(id, .q2, 1100); // pause: 100s banked
    try std.testing.expectEqual(@as(i64, 100), elapsed(b.getConst(id).?.*, 9999));

    b.moveToZone(id, .doing, 2000); // resume
    b.advance(id, 2050); // finish: +50s
    try std.testing.expectEqual(Zone.done, zoneOf(b.getConst(id).?.*));
    try std.testing.expectEqual(@as(i64, 150), elapsed(b.getConst(id).?.*, 99999)); // frozen

    // straight to done never started a timer
    const id2 = try b.add("quick", .backlog, 2, null, 0);
    b.moveToZone(id2, .done, 500);
    try std.testing.expectEqual(@as(i64, 0), elapsed(b.getConst(id2).?.*, 600));

    // created directly in "doing" starts immediately
    const id3 = try b.add("now", .doing, 3, null, 700);
    try std.testing.expectEqual(@as(i64, 30), elapsed(b.getConst(id3).?.*, 730));

    // clock going backwards never yields negative time
    try std.testing.expectEqual(@as(i64, 0), elapsed(b.getConst(id3).?.*, 100));
}

test "status changes feed the work log" {
    const a = std.testing.allocator;
    var b = Board.init(a);
    defer b.deinit();
    var log = worklog.Log.init(a);
    defer log.deinit();

    const id = try b.add("job", .backlog, 2, null, 0);
    try std.testing.expect(!(try b.drainEvents(&log))); // creating a backlog task logs nothing
    b.moveToZone(id, .doing, 1000); // starts the stopwatch, nothing to log yet
    try std.testing.expectEqual(@as(usize, 0), b.pending.items.len);
    b.moveToZone(id, .done, 1600); // closes the session and records the completion
    b.moveToZone(id, .doing, 2000); // reopening revokes the completion
    b.remove(id, 2300); // deleting a running task still logs the work done
    try std.testing.expect(try b.drainEvents(&log));
    try std.testing.expect(!(try b.drainEvents(&log)));

    const e = log.entries.items;
    try std.testing.expectEqual(@as(usize, 4), e.len);
    try std.testing.expectEqual(@as(i64, 1000), e[0].session.start);
    try std.testing.expectEqual(@as(i64, 1600), e[0].session.end);
    try std.testing.expectEqual(@as(i64, 600), e[1].done.took);
    try std.testing.expectEqualStrings("job", e[1].done.title);
    try std.testing.expectEqual(@as(i64, 2000), e[2].undone.at); // revoked at the moment it was reopened
    try std.testing.expectEqual(@as(i64, 2000), e[3].session.start);
    try std.testing.expectEqual(@as(i64, 2300), e[3].session.end);

    // a task created straight into Done counts as finished, with no time
    _ = try b.add("quick", .done, 1, null, 5000);
    try std.testing.expect(try b.drainEvents(&log));
    try std.testing.expectEqual(@as(i64, 0), log.entries.items[4].done.took);
}

test "practice tasks log their question count with the completion" {
    const a = std.testing.allocator;
    var b = Board.init(a);
    defer b.deinit();
    var log = worklog.Log.init(a);
    defer log.deinit();

    const id = try b.addTests("chapter 3 quiz", .backlog, 2, null, 30, 0);
    try std.testing.expectEqual(@as(u32, 30), b.getConst(id).?.tests);
    b.moveToZone(id, .doing, 1000);
    b.moveToZone(id, .done, 1900);
    try std.testing.expect(try b.drainEvents(&log));
    try std.testing.expectEqual(@as(usize, 3), log.entries.items.len); // session, done, tests
    try std.testing.expectEqual(@as(u32, 30), log.entries.items[2].tests.tests);

    // correcting the count of a finished task is logged too
    try b.update(id, "chapter 3 quiz", 2, null, 25);
    try std.testing.expect(try b.drainEvents(&log));
    try std.testing.expectEqual(@as(u32, 25), log.entries.items[3].tests.tests);

    // ordinary tasks log nothing extra, and the count is capped
    const id2 = try b.add("plain", .done, 1, null, 5000);
    try std.testing.expectEqual(@as(u32, 0), b.getConst(id2).?.tests);
    const id3 = try b.addTests("huge", .backlog, 1, null, 1_000_000, 0);
    try std.testing.expectEqual(max_tests, b.getConst(id3).?.tests);
}
