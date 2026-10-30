//! Brainstorm topics: a list of titled free-text pages, plus their on-disk
//! format. Pure data + (de)serialisation; the popup lives in brainstorm.zig.
//!
//! File format (BRAINSTORM1), one topic per line, newest first:
//!   id <TAB> updated_unix <TAB> title <TAB> body
//! where title and body escape \ as \\, newline as \n and tab as \t,
//! so the file stays one line per topic and easy to grep or back up.
const std = @import("std");
const storage = @import("storage.zig");

const magic = "BRAINSTORM1";
pub const max_title = 120;

pub const Topic = struct {
    id: u32,
    title: []u8,
    body: []u8,
    updated: i64,
};

pub const Notes = struct {
    alloc: std.mem.Allocator,
    topics: std.ArrayList(Topic) = .empty,
    next_id: u32 = 1,

    pub fn init(alloc: std.mem.Allocator) Notes {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Notes) void {
        for (self.topics.items) |t| {
            self.alloc.free(t.title);
            self.alloc.free(t.body);
        }
        self.topics.deinit(self.alloc);
    }

    fn cleanTitle(self: *Notes, raw: []const u8) ![]u8 {
        var s = std.mem.trim(u8, raw, " \t\r\n");
        if (s.len > max_title) {
            var end: usize = max_title;
            while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
            s = s[0..end];
        }
        if (s.len == 0) s = "Untitled";
        const out = try self.alloc.dupe(u8, s);
        for (out) |*c| {
            if (c.* < 0x20 or c.* == 0x7f) c.* = ' ';
        }
        return out;
    }

    /// New topics go to the top of the list.
    pub fn add(self: *Notes, title: []const u8, now: i64) !u32 {
        const t = try self.cleanTitle(title);
        errdefer self.alloc.free(t);
        const body = try self.alloc.dupe(u8, "");
        errdefer self.alloc.free(body);
        const id = self.next_id;
        try self.topics.insert(self.alloc, 0, .{ .id = id, .title = t, .body = body, .updated = now });
        self.next_id += 1;
        return id;
    }

    pub fn indexOf(self: *const Notes, id: u32) ?usize {
        for (self.topics.items, 0..) |t, i| if (t.id == id) return i;
        return null;
    }

    pub fn remove(self: *Notes, idx: usize) void {
        const t = self.topics.orderedRemove(idx);
        self.alloc.free(t.title);
        self.alloc.free(t.body);
    }

    pub fn rename(self: *Notes, idx: usize, title: []const u8) !void {
        const owned = try self.cleanTitle(title);
        self.alloc.free(self.topics.items[idx].title);
        self.topics.items[idx].title = owned;
    }

    /// Returns true when the body actually changed.
    pub fn setBody(self: *Notes, idx: usize, body: []const u8, now: i64) !bool {
        const t = &self.topics.items[idx];
        if (std.mem.eql(u8, t.body, body)) return false;
        const owned = try self.alloc.dupe(u8, body);
        self.alloc.free(t.body);
        t.body = owned;
        t.updated = now;
        return true;
    }

    /// Swap with a neighbour; returns the topic's new index.
    pub fn move(self: *Notes, idx: usize, delta: i32) usize {
        const target: i64 = @as(i64, @intCast(idx)) + delta;
        if (target < 0 or target >= self.topics.items.len) return idx;
        const j: usize = @intCast(target);
        std.mem.swap(Topic, &self.topics.items[idx], &self.topics.items[j]);
        return j;
    }
};

// ---- text format -----------------------------------------------------------------

fn escapeInto(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\t' => try out.appendSlice(a, "\\t"),
        '\r' => {},
        else => try out.append(a, c),
    };
}

fn unescape(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            try out.append(a, switch (s[i]) {
                'n' => '\n',
                't' => '\t',
                else => s[i],
            });
        } else try out.append(a, s[i]);
    }
    return out.toOwnedSlice(a);
}

pub fn serialize(a: std.mem.Allocator, notes: *const Notes) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, magic ++ "\n");
    for (notes.topics.items) |t| {
        try out.print(a, "{d}\t{d}\t", .{ t.id, t.updated });
        try escapeInto(&out, a, t.title);
        try out.append(a, '\t');
        try escapeInto(&out, a, t.body);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

pub fn parse(notes: *Notes, data: []const u8) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    const header = lines.next() orelse return;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, header, "\r"), magic)) return error.BadFormat;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const id = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        const updated = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch 0;
        const title_raw = f.next() orelse continue;
        const body_raw = f.rest();

        const title = try unescape(notes.alloc, title_raw);
        errdefer notes.alloc.free(title);
        const body = try unescape(notes.alloc, body_raw);
        errdefer notes.alloc.free(body);
        try notes.topics.append(notes.alloc, .{ .id = id, .title = title, .body = body, .updated = updated });
        if (id >= notes.next_id) notes.next_id = id + 1;
    }
}

pub fn load(io: std.Io, alloc: std.mem.Allocator, path: []const u8, notes: *Notes) !void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer alloc.free(data);
    if (storage.isBlank(data)) return;
    try parse(notes, data);
}

pub fn save(io: std.Io, alloc: std.mem.Allocator, path: []const u8, notes: *const Notes) !void {
    const data = try serialize(alloc, notes);
    defer alloc.free(data);
    try storage.atomicWrite(io, alloc, path, data);
}

test "round trip with awkward text" {
    const a = std.testing.allocator;
    var n = Notes.init(a);
    defer n.deinit();
    const id = try n.add("Theory of computation", 100);
    _ = try n.setBody(n.indexOf(id).?, "line one\n\tindented \\ backslash\nlast", 200);
    _ = try n.add("  second\ttopic  ", 300);

    const data = try serialize(a, &n);
    defer a.free(data);

    var m = Notes.init(a);
    defer m.deinit();
    try parse(&m, data);
    try std.testing.expectEqual(@as(usize, 2), m.topics.items.len);
    try std.testing.expectEqualStrings("second topic", m.topics.items[0].title);
    try std.testing.expectEqualStrings("Theory of computation", m.topics.items[1].title);
    try std.testing.expectEqualStrings("line one\n\tindented \\ backslash\nlast", m.topics.items[1].body);
    try std.testing.expectEqual(@as(i64, 200), m.topics.items[1].updated);
    try std.testing.expectEqual(@as(u32, 3), m.next_id);
}

test "list operations" {
    const a = std.testing.allocator;
    var n = Notes.init(a);
    defer n.deinit();
    _ = try n.add("a", 0);
    _ = try n.add("b", 0);
    _ = try n.add("", 0);
    try std.testing.expectEqualStrings("Untitled", n.topics.items[0].title);
    try std.testing.expectEqual(@as(usize, 1), n.move(0, 1));
    try std.testing.expectEqualStrings("b", n.topics.items[0].title);
    try std.testing.expectEqual(@as(usize, 2), n.move(2, 1)); // can't go past the end
    n.remove(0);
    try std.testing.expectEqual(@as(usize, 2), n.topics.items.len);
    try std.testing.expect(!(try n.setBody(0, "", 5))); // unchanged body keeps its timestamp
}
