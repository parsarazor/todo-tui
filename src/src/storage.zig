//! Plain-text persistence. One task per line (format KANBAN4):
//!   id <TAB> status <TAB> priority <TAB> YYYY-MM-DD|- <TAB> spent_secs <TAB> started_unix|- <TAB> tests <TAB> title
//! KANBAN4 only adds the `tests` column (practice questions, 0 = ordinary task) to KANBAN2.
//! Files written by earlier versions (KANBAN1, KANBAN2) still load; the first save upgrades them
//! and keeps the original next to it as board.tsv.kanbanN.bak.
//! Human-readable and easy to diff / back up.
const std = @import("std");
const model = @import("model.zig");
const dates = @import("dates.zig");

const magic_v1 = "KANBAN1";
const magic = "KANBAN2";
const magic_v3 = "KANBAN3";
const magic_v4 = "KANBAN4";

/// $KANBAN_FILE, else $XDG_DATA_HOME/kanban/board.tsv, else ~/.local/share/kanban/board.tsv
pub fn resolvePath(io: std.Io, alloc: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("KANBAN_FILE")) |p| return alloc.dupe(u8, p);

    const dir = blk: {
        if (env.get("XDG_DATA_HOME")) |x| break :blk try std.fmt.allocPrint(alloc, "{s}/kanban", .{x});
        const home = env.get("HOME") orelse return error.NoHomeDirectory;
        break :blk try std.fmt.allocPrint(alloc, "{s}/.local/share/kanban", .{home});
    };
    defer alloc.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    return std.fmt.allocPrint(alloc, "{s}/board.tsv", .{dir});
}

/// A file with nothing but whitespace in it holds no data, which is not an error:
/// it's what `touch` or an interrupted first run leaves behind.
pub fn isBlank(data: []const u8) bool {
    return std.mem.trim(u8, data, " \t\r\n").len == 0;
}

/// The first line of a file (at most 60 bytes, control characters shown as '?'),
/// for error messages about files we don't recognise. Caller owns the result.
pub fn firstLine(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1024 * 1024));
    defer alloc.free(data);
    const end = @min(std.mem.indexOfScalar(u8, data, '\n') orelse data.len, 60);
    const out = try alloc.dupe(u8, data[0..end]);
    for (out) |*c| {
        if (c.* < 0x20 or c.* == 0x7f) c.* = '?';
    }
    return out;
}

/// What loading found, so the app can tell the user when it converted something.
pub const Report = struct {
    /// 1 to 4 (the KANBAN format version of the file), 0 for no file / blank file
    version: u8 = 0,
    tasks: usize = 0,
    /// lines in a record type we don't know (only possible in KANBAN3 files)
    skipped: usize = 0,
    /// where the untouched original was copied before we first rewrite it
    backed_up: bool = false,
};

/// Read a board. KANBAN1 and KANBAN2 are ours. KANBAN3 comes from another build of
/// this app: the same task line as KANBAN2 with a leading record type, `T` for
/// tasks. We import the `T` lines, count whatever else is there, and never rewrite
/// the original without keeping a copy of it (see `load`).
pub fn parse(board: *model.Board, data: []const u8, now: i64) !Report {
    var report: Report = .{};
    if (isBlank(data)) return report;

    var lines = std.mem.splitScalar(u8, data, '\n');
    const header = lines.next() orelse return report;
    const head = std.mem.trimEnd(u8, header, "\r");
    report.version = if (std.mem.eql(u8, head, magic_v1)) 1 else if (std.mem.eql(u8, head, magic)) 2 else if (std.mem.eql(u8, head, magic_v3)) 3 else if (std.mem.eql(u8, head, magic_v4)) 4 else return error.BadFormat;
    const v1 = report.version == 1;
    const has_tests = report.version == 4;
    const typed = report.version == 3;

    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        if (typed) {
            const kind = f.next() orelse continue;
            if (!std.mem.eql(u8, kind, "T")) {
                report.skipped += 1;
                continue;
            }
        }
        const id_s = f.next() orelse continue;
        const st_s = f.next() orelse continue;
        const pr_s = f.next() orelse continue;
        const dl_s = f.next() orelse continue;
        const spent_s = if (!v1) (f.next() orelse continue) else "0";
        const start_s = if (!v1) (f.next() orelse continue) else "-";
        const tests_s = if (has_tests) (f.next() orelse continue) else "0";
        const title = f.rest();

        const id = std.fmt.parseInt(u32, id_s, 10) catch continue;
        const status = std.meta.stringToEnum(model.Status, st_s) orelse continue;
        const prio = std.fmt.parseInt(u8, pr_s, 10) catch continue;
        const deadline: ?i32 = if (std.mem.eql(u8, dl_s, "-"))
            null
        else
            (dates.parse(dl_s, 0) catch null);
        const spent = std.fmt.parseInt(i64, spent_s, 10) catch 0;
        var started: ?i64 = if (std.mem.eql(u8, start_s, "-")) null else (std.fmt.parseInt(i64, start_s, 10) catch null);
        // A task in "doing" always has a running timer (older files had none).
        if (status == .doing and started == null) started = now;
        const tests = std.fmt.parseInt(u32, tests_s, 10) catch 0;
        try board.restore(id, title, status, prio, deadline, spent, started, tests);
        report.tasks += 1;
    }
    return report;
}

pub fn load(io: std.Io, alloc: std.mem.Allocator, path: []const u8, board: *model.Board, now: i64) !Report {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer alloc.free(data);

    var report = try parse(board, data, now);

    // The first save will rewrite this file in our own format. Keep the original,
    // byte for byte, next to it (once: an existing backup is never overwritten).
    if (report.version >= 1 and report.version <= 3) {
        const bak = try std.fmt.allocPrint(alloc, "{s}.kanban{d}.bak", .{ path, report.version });
        defer alloc.free(bak);
        const exists = if (std.Io.Dir.cwd().readFileAlloc(io, bak, alloc, .limited(0))) |d| blk: {
            alloc.free(d);
            break :blk true;
        } else |err| err != error.FileNotFound;
        if (!exists) {
            try atomicWrite(io, alloc, bak, data);
            report.backed_up = true;
        }
    }
    return report;
}

pub fn save(io: std.Io, alloc: std.mem.Allocator, path: []const u8, board: *const model.Board) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, magic_v4 ++ "\n");

    var buf: [16]u8 = undefined;
    for (board.tasks.items) |t| {
        const dl: []const u8 = if (t.deadline) |d| dates.format(&buf, d) else "-";
        var sb: [24]u8 = undefined;
        const st: []const u8 = if (t.started) |s| (std.fmt.bufPrint(&sb, "{d}", .{s}) catch "-") else "-";
        try out.print(alloc, "{d}\t{s}\t{d}\t{s}\t{d}\t{s}\t{d}\t{s}\n", .{ t.id, @tagName(t.status), t.priority, dl, t.spent, st, t.tests, t.title });
    }

    try atomicWrite(io, alloc, path, out.items);
}

/// Write to a temp file, then rename: a crash never leaves a half-written file.
pub fn atomicWrite(io: std.Io, alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = data });
    try cwd.rename(tmp, cwd, path, io);
}

test "blank files are not data" {
    try std.testing.expect(isBlank(""));
    try std.testing.expect(isBlank(" \n\r\n\t"));
    try std.testing.expect(!isBlank("KANBAN2\n"));
}

test "KANBAN3 import keeps tasks, skips other record types" {
    const a = std.testing.allocator;
    var b = model.Board.init(a);
    defer b.deinit();
    const data =
        "KANBAN3\n" ++
        "T\t1\tbacklog\t1\t2026-10-01\t3463\t-\tTheory of Comp Review ch 0\n" ++
        "T\t2\tdone\t2\t2026-10-02\t894995\t-\tread recomendation system articles\n" ++
        "T\t3\tbacklog\t1\t-\t0\t-\tIELTS\n" ++
        "S\t3\t100\t200\tsome record we don't know\n" ++
        "T\t4\tdone\t3\t2026-10-01\t0\t-\twhen i write new task\n";
    const r = try parse(&b, data, 1000);
    try std.testing.expectEqual(@as(u8, 3), r.version);
    try std.testing.expectEqual(@as(usize, 4), r.tasks);
    try std.testing.expectEqual(@as(usize, 1), r.skipped);
    try std.testing.expectEqualStrings("IELTS", b.getConst(3).?.title);
    try std.testing.expectEqual(@as(i64, 894995), b.getConst(2).?.spent);
    try std.testing.expectEqual(model.Status.done, b.getConst(2).?.status);
    try std.testing.expect(b.getConst(1).?.deadline != null);
    try std.testing.expectEqual(@as(u32, 5), b.next_id);
}

test "unknown headers are still rejected" {
    const a = std.testing.allocator;
    var b = model.Board.init(a);
    defer b.deinit();
    try std.testing.expectError(error.BadFormat, parse(&b, "KANBAN9\n1\tbacklog\t1\t-\t0\t-\tx\n", 0));
    try std.testing.expectEqual(@as(u8, 0), (try parse(&b, "  \n", 0)).version);
}

test "KANBAN4 round trip keeps the question count, and KANBAN2 still loads" {
    const a = std.testing.allocator;
    var b = model.Board.init(a);
    defer b.deinit();
    _ = try b.addTests("quiz ch1", .backlog, 2, null, 40, 0);
    _ = try b.add("plain", .backlog, 1, null, 0);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, magic_v4 ++ "\n");
    for (b.tasks.items) |t| try out.print(a, "{d}\t{s}\t{d}\t-\t{d}\t-\t{d}\t{s}\n", .{ t.id, @tagName(t.status), t.priority, t.spent, t.tests, t.title });
    var back = model.Board.init(a);
    defer back.deinit();
    const r = try parse(&back, out.items, 0);
    try std.testing.expectEqual(@as(u8, 4), r.version);
    try std.testing.expectEqual(@as(u32, 40), back.getConst(1).?.tests);
    try std.testing.expectEqual(@as(u32, 0), back.getConst(2).?.tests);
    try std.testing.expectEqualStrings("quiz ch1", back.getConst(1).?.title);

    var old = model.Board.init(a);
    defer old.deinit();
    const r2 = try parse(&old, "KANBAN2\n1\tbacklog\t2\t-\t0\t-\tfrom the old days\n", 0);
    try std.testing.expectEqual(@as(u8, 2), r2.version);
    try std.testing.expectEqual(@as(u32, 0), old.getConst(1).?.tests);
    try std.testing.expectEqualStrings("from the old days", old.getConst(1).?.title);
}
