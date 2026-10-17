//! A small multi-line text editor core: a byte buffer, a cursor and soft word
//! wrapping. No drawing and no I/O; the brainstorm page renders what this
//! computes. Everything is UTF-8 aware (the cursor never lands inside a
//! multi-byte character) and everything that can be tested without a terminal is.
const std = @import("std");
const vaxis = @import("vaxis");

pub const Method = vaxis.gwidth.Method;

/// One visual (wrapped) line: bytes [start, end) of the buffer, never containing '\n'.
pub const Row = struct { start: usize, end: usize };

pub const Editor = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Byte offset of the cursor, always on a character boundary.
    cursor: usize = 0,
    /// Column to aim for while moving up/down through short lines.
    goal_col: ?u16 = null,
    /// First visible visual row (maintained by the renderer).
    scroll: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Editor {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Editor) void {
        self.buf.deinit(self.alloc);
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.buf.items;
    }

    /// Replace everything; the cursor goes to the end so you can keep writing.
    pub fn setText(self: *Editor, t: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.alloc, t);
        self.cursor = self.buf.items.len;
        self.goal_col = null;
        self.scroll = 0;
    }

    // ---- boundaries ----------------------------------------------------------

    fn prevBoundary(self: *const Editor, i: usize) usize {
        if (i == 0) return 0;
        var j = i - 1;
        while (j > 0 and (self.buf.items[j] & 0xC0) == 0x80) j -= 1;
        return j;
    }

    fn nextBoundary(self: *const Editor, i: usize) usize {
        const t = self.buf.items;
        if (i >= t.len) return t.len;
        var j = i + 1;
        while (j < t.len and (t[j] & 0xC0) == 0x80) j += 1;
        return j;
    }

    // ---- editing -------------------------------------------------------------

    /// Insert at the cursor. Tabs become four spaces, CR/CRLF become '\n',
    /// other control characters are dropped.
    pub fn insert(self: *Editor, s: []const u8) !void {
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(self.alloc);
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            switch (c) {
                '\n' => try tmp.append(self.alloc, '\n'),
                '\r' => {
                    if (i + 1 < s.len and s[i + 1] == '\n') continue;
                    try tmp.append(self.alloc, '\n');
                },
                '\t' => try tmp.appendSlice(self.alloc, "    "),
                0...8, 11, 12, 14...31, 0x7f => {},
                else => try tmp.append(self.alloc, c),
            }
        }
        if (tmp.items.len == 0) return;
        try self.buf.insertSlice(self.alloc, self.cursor, tmp.items);
        self.cursor += tmp.items.len;
        self.goal_col = null;
    }

    fn erase(self: *Editor, from: usize, to: usize) void {
        if (to <= from) return;
        self.buf.replaceRange(self.alloc, from, to - from, &.{}) catch unreachable; // shrinking never allocates
        self.cursor = from;
        self.goal_col = null;
    }

    pub fn backspace(self: *Editor) void {
        if (self.cursor == 0) return;
        self.erase(self.prevBoundary(self.cursor), self.cursor);
    }

    pub fn deleteForward(self: *Editor) void {
        const to = self.nextBoundary(self.cursor);
        if (to == self.cursor) return;
        const from = self.cursor;
        self.erase(from, to);
    }

    pub fn deleteWordBack(self: *Editor) void {
        self.erase(self.wordLeftFrom(self.cursor), self.cursor);
    }

    /// Delete to the end of the logical line (or the line break itself if already there).
    pub fn deleteToLineEnd(self: *Editor) void {
        const t = self.buf.items;
        if (self.cursor >= t.len) return;
        const nl = std.mem.indexOfScalarPos(u8, t, self.cursor, '\n');
        const from = self.cursor;
        const to = if (nl) |n| (if (n == from) n + 1 else n) else t.len;
        self.erase(from, to);
    }

    pub fn deleteToLineStart(self: *Editor) void {
        const t = self.buf.items;
        const start = if (std.mem.lastIndexOfScalar(u8, t[0..self.cursor], '\n')) |n| n + 1 else 0;
        self.erase(start, self.cursor);
    }

    // ---- horizontal movement -----------------------------------------------------

    pub fn moveLeft(self: *Editor) void {
        self.cursor = self.prevBoundary(self.cursor);
        self.goal_col = null;
    }

    pub fn moveRight(self: *Editor) void {
        self.cursor = self.nextBoundary(self.cursor);
        self.goal_col = null;
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\n';
    }

    fn wordLeftFrom(self: *const Editor, from: usize) usize {
        const t = self.buf.items;
        var i = from;
        while (i > 0 and isSpace(t[i - 1])) i -= 1;
        while (i > 0 and !isSpace(t[i - 1])) i -= 1;
        return i;
    }

    pub fn wordLeft(self: *Editor) void {
        self.cursor = self.wordLeftFrom(self.cursor);
        self.goal_col = null;
    }

    pub fn wordRight(self: *Editor) void {
        const t = self.buf.items;
        var i = self.cursor;
        while (i < t.len and isSpace(t[i])) i += 1;
        while (i < t.len and !isSpace(t[i])) i += 1;
        self.cursor = i;
        self.goal_col = null;
    }

    pub fn moveToStart(self: *Editor) void {
        self.cursor = 0;
        self.goal_col = null;
    }

    pub fn moveToEnd(self: *Editor) void {
        self.cursor = self.buf.items.len;
        self.goal_col = null;
    }

    // ---- layout ---------------------------------------------------------------------

    /// Wrap the buffer to `width` columns. Break at spaces when possible, in the
    /// middle of a word when a word is wider than the page. Spaces may hang past
    /// the right edge. The caller owns the result (use a frame arena).
    pub fn layout(self: *const Editor, a: std.mem.Allocator, width_in: u16, method: Method) ![]Row {
        const width = @max(width_in, 1);
        var rows: std.ArrayList(Row) = .empty;
        errdefer rows.deinit(a);
        const t = self.buf.items;

        var ls: usize = 0;
        while (true) {
            const le = std.mem.indexOfScalarPos(u8, t, ls, '\n') orelse t.len;
            try wrapLine(a, &rows, t, ls, le, width, method);
            if (le >= t.len) break;
            ls = le + 1;
        }
        return rows.toOwnedSlice(a);
    }

    fn cpLen(b: u8) usize {
        return std.unicode.utf8ByteSequenceLength(b) catch 1;
    }

    fn wrapLine(a: std.mem.Allocator, rows: *std.ArrayList(Row), t: []const u8, ls: usize, le: usize, width: u16, method: Method) !void {
        if (ls == le) {
            try rows.append(a, .{ .start = ls, .end = ls });
            return;
        }
        var pos = ls;
        while (pos < le) {
            var w: u16 = 0;
            var i = pos;
            var last_break: ?usize = null; // index just after the most recent space
            var overflow = false;
            while (i < le) {
                const n = @min(cpLen(t[i]), le - i);
                const cw = vaxis.gwidth.gwidth(t[i .. i + n], method);
                if (w + cw > width and i > pos and t[i] != ' ') {
                    overflow = true;
                    break;
                }
                w += cw;
                i += n;
                if (t[i - 1] == ' ') last_break = i;
            }
            if (!overflow) {
                try rows.append(a, .{ .start = pos, .end = le });
                return;
            }
            const end = if (last_break) |b| (if (b > pos) b else i) else i;
            try rows.append(a, .{ .start = pos, .end = end });
            pos = end;
        }
    }

    /// Index of the row the cursor (or any offset) is on: the last row starting at or before it.
    pub fn rowOf(rows: []const Row, offset: usize) usize {
        var r: usize = 0;
        for (rows, 0..) |row, i| {
            if (row.start <= offset) r = i else break;
        }
        return r;
    }

    /// Display column of `offset` within its row.
    pub fn colOf(self: *const Editor, row: Row, offset: usize, method: Method) u16 {
        const o = std.math.clamp(offset, row.start, row.end);
        return vaxis.gwidth.gwidth(self.buf.items[row.start..o], method);
    }

    /// Where the cursor may sit at the end of a row: just before the soft-wrap
    /// boundary rather than on the next row's first character.
    fn rowEndCursor(self: *const Editor, rows: []const Row, idx: usize) usize {
        const row = rows[idx];
        if (idx + 1 < rows.len and rows[idx + 1].start == row.end and row.end > row.start)
            return self.prevBoundary(row.end);
        return row.end;
    }

    fn offsetAtCol(self: *const Editor, rows: []const Row, idx: usize, col: u16, method: Method) usize {
        const row = rows[idx];
        const limit = self.rowEndCursor(rows, idx);
        const t = self.buf.items;
        var i = row.start;
        var w: u16 = 0;
        while (i < limit) {
            const n = @min(cpLen(t[i]), limit - i);
            const cw = vaxis.gwidth.gwidth(t[i .. i + n], method);
            if (w + cw > col) break;
            w += cw;
            i += n;
        }
        return i;
    }

    pub fn moveVertical(self: *Editor, rows: []const Row, delta: i32, method: Method) void {
        if (rows.len == 0) return;
        const cur = rowOf(rows, self.cursor);
        const target: i64 = @as(i64, @intCast(cur)) + delta;
        if (target < 0) {
            self.cursor = rows[0].start;
            self.goal_col = null;
            return;
        }
        if (target >= rows.len) {
            self.cursor = self.buf.items.len;
            self.goal_col = null;
            return;
        }
        const col = self.goal_col orelse self.colOf(rows[cur], self.cursor, method);
        self.cursor = self.offsetAtCol(rows, @intCast(target), col, method);
        self.goal_col = col;
    }

    pub fn moveRowStart(self: *Editor, rows: []const Row) void {
        if (rows.len == 0) return;
        self.cursor = rows[rowOf(rows, self.cursor)].start;
        self.goal_col = null;
    }

    pub fn moveRowEnd(self: *Editor, rows: []const Row) void {
        if (rows.len == 0) return;
        self.cursor = self.rowEndCursor(rows, rowOf(rows, self.cursor));
        self.goal_col = null;
    }
};

/// Copy `src` into `dst` as one line: control characters become spaces, a CRLF
/// pair counts once, and a cut-off multi-byte character is dropped.
pub fn flattenLine(dst: []u8, src: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len and n < dst.len) : (i += 1) {
        const c = src[i];
        if (c == '\r' and i + 1 < src.len and src[i + 1] == '\n') continue;
        dst[n] = if (c < 0x20) ' ' else c;
        n += 1;
    }
    if (i < src.len) { // truncated: don't leave half a character behind
        while (n > 0 and (dst[n - 1] & 0xC0) == 0x80) n -= 1;
        if (n > 0 and dst[n - 1] >= 0xC0) n -= 1;
    }
    return dst[0..n];
}

pub fn wordCount(s: []const u8) usize {
    var n: usize = 0;
    var in_word = false;
    for (s) |c| {
        const sp = c == ' ' or c == '\n' or c == '\t' or c == '\r';
        if (!sp and !in_word) n += 1;
        in_word = !sp;
    }
    return n;
}

// ---- tests -----------------------------------------------------------------------

const testing = std.testing;

fn rowsText(a: std.mem.Allocator, e: *const Editor, rows: []const Row) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (rows, 0..) |r, i| {
        if (i > 0) try out.append(a, '|');
        try out.appendSlice(a, e.text()[r.start..r.end]);
    }
    return out.toOwnedSlice(a);
}

test "wrap at spaces, hard-break long words, keep blank lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = Editor.init(testing.allocator);
    defer e.deinit();

    try e.setText("hello world foo");
    try testing.expectEqualStrings("hello |world |foo", try rowsText(a, &e, try e.layout(a, 8, .wcwidth)));

    try e.setText("abcdefghij");
    try testing.expectEqualStrings("abcd|efgh|ij", try rowsText(a, &e, try e.layout(a, 4, .wcwidth)));

    try e.setText("one\n\ntwo\n");
    const rows = try e.layout(a, 20, .wcwidth);
    try testing.expectEqual(@as(usize, 4), rows.len); // one, blank, two, trailing blank
    try testing.expectEqualStrings("one||two|", try rowsText(a, &e, rows));
}

test "typing, deleting and utf-8" {
    var e = Editor.init(testing.allocator);
    defer e.deinit();
    try e.insert("héllo\twörld\r\nx");
    try testing.expectEqualStrings("héllo    wörld\nx", e.text());
    e.backspace();
    e.backspace(); // removes the newline
    try testing.expectEqualStrings("héllo    wörld", e.text());
    e.moveLeft();
    e.moveLeft();
    e.moveLeft();
    e.moveLeft();
    e.backspace(); // cursor sits between 'w' and 'ö', so this removes the 'w'
    try testing.expectEqualStrings("héllo    örld", e.text());
    e.deleteForward(); // removes 'ö' as one whole character
    try testing.expectEqualStrings("héllo    rld", e.text());
    e.deleteWordBack();
    try testing.expectEqualStrings("rld", e.text());
}

test "cursor movement across wrapped rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = Editor.init(testing.allocator);
    defer e.deinit();
    try e.setText("hello world foo\nxy");
    var rows = try e.layout(a, 8, .wcwidth); // "hello |world |foo|xy"
    e.cursor = 3; // he|llo
    e.moveVertical(rows, 1, .wcwidth);
    try testing.expectEqual(@as(usize, 6 + 3), e.cursor); // wor|ld
    e.moveVertical(rows, 1, .wcwidth);
    try testing.expectEqual(@as(usize, 12 + 3), e.cursor); // end of "foo"
    e.moveVertical(rows, 1, .wcwidth);
    try testing.expectEqual(@as(usize, 16 + 2), e.cursor); // end of "xy" (goal col 3 clamps)
    e.moveVertical(rows, -1, .wcwidth);
    try testing.expectEqual(@as(usize, 12 + 3), e.cursor); // remembers goal col 3
    e.moveVertical(rows, -3, .wcwidth);
    try testing.expectEqual(@as(usize, 0), e.cursor);

    e.cursor = 7;
    rows = try e.layout(a, 8, .wcwidth);
    e.moveRowStart(rows);
    try testing.expectEqual(@as(usize, 6), e.cursor);
    e.moveRowEnd(rows); // soft-wrapped row: stays before the trailing space
    try testing.expectEqual(@as(usize, 11), e.cursor);
    try testing.expectEqual(@as(usize, 1), Editor.rowOf(rows, e.cursor));
}

test "line kills" {
    var e = Editor.init(testing.allocator);
    defer e.deinit();
    try e.setText("alpha beta\ngamma");
    e.cursor = 6;
    e.deleteToLineEnd();
    try testing.expectEqualStrings("alpha \ngamma", e.text());
    e.deleteToLineEnd(); // at the break: joins lines
    try testing.expectEqualStrings("alpha gamma", e.text());
    e.deleteToLineStart();
    try testing.expectEqualStrings("gamma", e.text());
}

test "flattenLine" {
    var b: [16]u8 = undefined;
    try testing.expectEqualStrings("a b c d", flattenLine(&b, "a\r\nb\nc\rd"));
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("ab", flattenLine(&small, "abé!")); // 'é' would be cut in half
}

test "word count" {
    try testing.expectEqual(@as(usize, 0), wordCount(" \n "));
    try testing.expectEqual(@as(usize, 4), wordCount("a  b\nc\td"));
}
