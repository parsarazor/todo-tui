//! The "new / edit task" modal: title, deadline, priority.
const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const draw = @import("draw.zig");
const dates = @import("dates.zig");
const editor = @import("editor.zig");
const TextInput = vaxis.widgets.TextInput;

pub const Field = enum { title, tests, deadline, priority };

/// Quick picks for the number of questions, stepped with ← / →.
pub const presets = [_]u32{ 10, 20, 30, 40, 50, 100 };
pub const Result = enum { none, save, cancel };

pub const priority_names = [4][]const u8{ "DO NOW", "PLAN", "DELEGATE", "DROP" };

pub const Form = struct {
    title: TextInput,
    deadline: TextInput,
    priority: u8 = 1,
    field: Field = .title,
    err: ?[]const u8 = null,
    is_edit: bool = false,
    /// Practice mode (ctrl+p): the task is a set of multiple-choice questions.
    practice: bool = false,
    /// number of questions in practice mode
    tests: u32 = 20,
    /// the next digit typed replaces the number instead of extending it
    fresh: bool = true,

    pub fn init(alloc: std.mem.Allocator) Form {
        return .{ .title = TextInput.init(alloc), .deadline = TextInput.init(alloc) };
    }

    pub fn deinit(self: *Form) void {
        self.title.deinit();
        self.deadline.deinit();
    }

    fn step(self: *Form, delta: i8) void {
        var n: i8 = @intCast(@intFromEnum(self.field));
        while (true) {
            n = @mod(n + delta, 4);
            const f: Field = @enumFromInt(@as(u2, @intCast(n)));
            if (f == .tests and !self.practice) continue; // only exists in practice mode
            self.field = f;
            break;
        }
        if (self.field == .tests) self.fresh = true;
    }

    /// Switch practice mode on or off. Switching on jumps straight to the question count.
    pub fn togglePractice(self: *Form) void {
        self.practice = !self.practice;
        self.err = null;
        if (self.practice) {
            self.field = .tests;
            self.fresh = true;
        } else if (self.field == .tests) {
            self.field = .title;
        }
    }

    fn nextPreset(self: *Form, up: bool) void {
        if (up) {
            for (presets) |p| if (p > self.tests) {
                self.tests = p;
                return;
            };
        } else {
            var i = presets.len;
            while (i > 0) {
                i -= 1;
                if (presets[i] < self.tests) {
                    self.tests = presets[i];
                    return;
                }
            }
        }
    }

    fn typeTests(self: *Form, key: vaxis.Key) void {
        inline for ("0123456789") |c| {
            if (key.matches(@as(u21, c), .{})) {
                const d: u32 = c - '0';
                const base: u32 = if (self.fresh) 0 else self.tests;
                self.tests = @min(base * 10 + d, 9999);
                self.fresh = false;
                return;
            }
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            self.tests /= 10;
            self.fresh = false;
        } else if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
            self.nextPreset(true);
        } else if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
            self.nextPreset(false);
        } else if (key.matches('+', .{}) or key.matches('=', .{})) {
            self.tests = @min(self.tests + 1, 9999);
        } else if (key.matches('-', .{})) {
            self.tests -|= 1;
        }
    }

    /// Pasted text goes into the focused field as one line.
    pub fn paste(self: *Form, text: []const u8) !void {
        var buf: [512]u8 = undefined;
        const line = editor.flattenLine(&buf, text);
        switch (self.field) {
            .title => try self.title.insertSliceAtCursor(line),
            .deadline => try self.deadline.insertSliceAtCursor(line),
            .tests, .priority => {},
        }
        self.err = null;
    }

    pub fn handleKey(self: *Form, key: vaxis.Key) !Result {
        if (key.matches(vaxis.Key.escape, .{})) return .cancel;
        if (key.matches('s', .{ .ctrl = true })) return .save;
        if (key.matches(vaxis.Key.tab, .{ .shift = true }) or key.matches(vaxis.Key.up, .{})) {
            self.step(-1);
            return .none;
        }
        if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.down, .{})) {
            self.step(1);
            return .none;
        }
        if (key.matches('p', .{ .ctrl = true })) {
            self.togglePractice();
            return .none;
        }
        if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) {
            // practice tasks are quick to capture: title, number, enter
            if (self.field == .priority or self.field == .tests) return .save;
            self.step(1);
            return .none;
        }
        self.err = null;
        switch (self.field) {
            .title => try self.title.update(.{ .key_press = key }),
            .deadline => try self.deadline.update(.{ .key_press = key }),
            .tests => self.typeTests(key),
            .priority => {
                if ((key.matches(vaxis.Key.left, .{}) or key.matches('h', .{}) or key.matches('-', .{})) and self.priority > 1)
                    self.priority -= 1;
                if ((key.matches(vaxis.Key.right, .{}) or key.matches('l', .{}) or key.matches('+', .{}) or key.matches(vaxis.Key.space, .{})) and self.priority < 4)
                    self.priority += 1;
                inline for ("1234") |c| {
                    if (key.matches(@as(u21, c), .{})) self.priority = c - '0';
                }
            },
        }
        return .none;
    }

    fn label(win: vaxis.Window, x: u16, y: u16, w: u16, s: []const u8, focused: bool) void {
        if (focused) {
            _ = draw.text(win, x, y, 2, "▸", .{ .fg = theme.bone, .bg = theme.glass_sheen });
            _ = draw.text(win, x + 2, y, w - 2, s, .{ .fg = theme.bone, .bg = theme.glass_sheen, .bold = true });
        } else {
            _ = draw.text(win, x + 2, y, w - 2, s, .{ .fg = theme.bone_dim, .bg = theme.glass_sheen });
        }
    }

    fn input(win: vaxis.Window, arena: std.mem.Allocator, ti: *TextInput, r: draw.Rect, focused: bool) void {
        draw.fill(win, r, theme.glass_hi);
        const inner = r.inset(1, 0);
        if (inner.w == 0) return;
        const child = win.child(.{ .x_off = @intCast(inner.x), .y_off = @intCast(inner.y), .width = inner.w, .height = 1 });
        const style: theme.Style = .{ .fg = theme.bone, .bg = theme.glass_hi };
        if (focused) {
            ti.drawWithStyle(child, style);
        } else {
            const s = ti.toOwnedContents(arena) catch "";
            _ = draw.text(win, inner.x, inner.y, inner.w, s, style);
        }
    }

    pub fn draw_modal(self: *Form, win: vaxis.Window, arena: std.mem.Allocator, today: i32) void {
        const w: u16 = @min(64, win.width -| 4);
        const h: u16 = if (self.practice) 19 else 15;
        const r: draw.Rect = .{ .x = (win.width - w) / 2, .y = (win.height -| h) / 2, .w = w, .h = h };
        draw.box(win, r, theme.line_focus, theme.glass_sheen, false, false);
        _ = draw.text(win, r.x + 2, r.y, 24, if (self.practice) (if (self.is_edit) " EDIT PRACTICE " else " NEW PRACTICE ") else if (self.is_edit) " EDIT TASK " else " NEW TASK ", .{ .fg = theme.bone, .bg = theme.glass_sheen, .bold = true });

        const x = r.x + 3;
        const iw = r.w - 6;
        const dim: theme.Style = .{ .fg = theme.bone_faint, .bg = theme.glass_sheen };

        label(win, x, r.y + 2, iw, "Title", self.field == .title);
        input(win, arena, &self.title, .{ .x = x, .y = r.y + 3, .w = iw, .h = 1 }, self.field == .title);

        // practice mode adds a "Questions" block between title and deadline
        var y0: u16 = r.y + 5;
        if (self.practice) {
            label(win, x, y0, iw, "Questions  (multiple-choice)", self.field == .tests);
            const focused = self.field == .tests;
            const num = std.fmt.allocPrint(arena, " {d} ", .{self.tests}) catch "";
            const nw = win.gwidth(num);
            const num_bg = if (focused) theme.bone else theme.glass_hi;
            draw.fill(win, .{ .x = x + 2, .y = y0 + 1, .w = nw + 2, .h = 1 }, num_bg);
            _ = draw.text(win, x + 3, y0 + 1, nw, num, .{ .fg = if (focused) theme.black else theme.bone, .bg = num_bg, .bold = true });
            var px = x + 3 + nw + 3;
            for (presets) |pv| {
                const ps = std.fmt.allocPrint(arena, " {d} ", .{pv}) catch continue;
                const pw = win.gwidth(ps);
                if (px + pw > r.x + r.w - 2) break;
                const on = self.tests == pv;
                const st: theme.Style = if (on)
                    .{ .fg = theme.black, .bg = theme.ok, .bold = true }
                else
                    .{ .fg = theme.bone_dim, .bg = theme.glass_hi };
                draw.fill(win, .{ .x = px, .y = y0 + 1, .w = pw, .h = 1 }, st.bg);
                _ = draw.text(win, px, y0 + 1, pw, ps, st);
                px += pw + 1;
            }
            const hint = if (focused) "type a number · ←/→ presets · +/- by one · enter saves" else "ctrl+p switches practice off";
            _ = draw.text(win, x + 2, y0 + 2, iw - 2, hint, dim);
            y0 += 4;
        }

        label(win, x, y0, iw, "Deadline  (optional)", self.field == .deadline);
        input(win, arena, &self.deadline, .{ .x = x, .y = y0 + 1, .w = iw, .h = 1 }, self.field == .deadline);

        // live preview of what the deadline text means
        const dl_text = self.deadline.toOwnedContents(arena) catch "";
        if (std.mem.trim(u8, dl_text, " ").len == 0) {
            _ = draw.text(win, x + 2, y0 + 2, iw - 2, "no deadline · try 2026-10-05, 10-05, +3, +2w, today, tomorrow", dim);
        } else if (dates.parse(dl_text, today)) |maybe| {
            const d = maybe.?;
            var b1: [16]u8 = undefined;
            var b2: [32]u8 = undefined;
            const s = std.fmt.allocPrint(arena, "→ {s} {s} · {s}", .{ dates.weekday(d), dates.format(&b1, d), dates.relative(&b2, d, today) }) catch "";
            _ = draw.text(win, x + 2, y0 + 2, iw - 2, s, .{ .fg = theme.bone_dim, .bg = theme.glass_sheen });
        } else |_| {
            _ = draw.text(win, x + 2, y0 + 2, iw - 2, "can't read that — try 2026-10-05, 10-05, +3, today, tomorrow", .{ .fg = theme.p1, .bg = theme.glass_sheen });
        }

        label(win, x, y0 + 4, iw, "Priority  (matrix square)", self.field == .priority);
        var cx = x + 2;
        for (priority_names, 0..) |name, i| {
            const p: u8 = @intCast(i + 1);
            const s = std.fmt.allocPrint(arena, " {d} {s} ", .{ p, name }) catch continue;
            const cw = win.gwidth(s);
            if (cx + cw > r.x + r.w - 2) break;
            const chosen = self.priority == p;
            const col = theme.priorityColor(p);
            const st: theme.Style = if (chosen)
                .{ .fg = theme.black, .bg = col, .bold = true }
            else
                .{ .fg = theme.fade(col, 80), .bg = theme.glass_hi };
            draw.fill(win, .{ .x = cx, .y = y0 + 5, .w = cw, .h = 1 }, st.bg);
            _ = draw.text(win, cx, y0 + 5, cw, s, st);
            cx += cw + 1;
        }

        if (self.err) |e| _ = draw.text(win, x + 2, y0 + 7, iw - 2, e, .{ .fg = theme.p1, .bg = theme.glass_sheen });
        _ = draw.text(win, x, y0 + 8, iw, "tab next · enter confirm · ctrl+s save · ctrl+p practice · esc cancel", dim);
    }
};

fn press(f: *Form, cp: u21) !Result {
    return f.handleKey(.{ .codepoint = cp });
}

test "practice mode: tab skips the question field when it is off, digits replace then extend" {
    const a = std.testing.allocator;
    var f = Form.init(a);
    defer f.deinit();
    f.tests = 20;

    // practice off: tab goes title -> deadline -> priority -> title
    try std.testing.expectEqual(Result.none, try f.handleKey(.{ .codepoint = vaxis.Key.tab }));
    try std.testing.expectEqual(Field.deadline, f.field);
    _ = try f.handleKey(.{ .codepoint = vaxis.Key.tab });
    _ = try f.handleKey(.{ .codepoint = vaxis.Key.tab });
    try std.testing.expectEqual(Field.title, f.field);

    // ctrl+p switches practice on and jumps to the number
    try std.testing.expectEqual(Result.none, try f.handleKey(.{ .codepoint = 'p', .mods = .{ .ctrl = true } }));
    try std.testing.expect(f.practice);
    try std.testing.expectEqual(Field.tests, f.field);

    // the first digit replaces the suggestion, the next ones extend it
    _ = try press(&f, '4');
    try std.testing.expectEqual(@as(u32, 4), f.tests);
    _ = try press(&f, '5');
    try std.testing.expectEqual(@as(u32, 45), f.tests);
    _ = try press(&f, vaxis.Key.backspace);
    try std.testing.expectEqual(@as(u32, 4), f.tests);
    // never more than four digits
    for ("99999") |c| _ = try press(&f, c);
    try std.testing.expectEqual(@as(u32, 9999), f.tests);

    // presets step through the list, +/- by one
    f.tests = 20;
    _ = try press(&f, vaxis.Key.right);
    try std.testing.expectEqual(@as(u32, 30), f.tests);
    _ = try press(&f, vaxis.Key.left);
    _ = try press(&f, vaxis.Key.left);
    try std.testing.expectEqual(@as(u32, 10), f.tests);
    _ = try press(&f, vaxis.Key.left); // already at the smallest preset
    try std.testing.expectEqual(@as(u32, 10), f.tests);
    _ = try press(&f, '+');
    try std.testing.expectEqual(@as(u32, 11), f.tests);

    // enter on the question field saves straight away
    try std.testing.expectEqual(Result.save, try f.handleKey(.{ .codepoint = vaxis.Key.enter }));

    // switching practice off again leaves the field and the number alone
    _ = try f.handleKey(.{ .codepoint = 'p', .mods = .{ .ctrl = true } });
    try std.testing.expect(!f.practice);
    try std.testing.expectEqual(Field.title, f.field);
}
