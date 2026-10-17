//! The "new / edit task" modal: title, deadline, priority.
const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const draw = @import("draw.zig");
const dates = @import("dates.zig");
const editor = @import("editor.zig");
const TextInput = vaxis.widgets.TextInput;

pub const Field = enum { title, deadline, priority };
pub const Result = enum { none, save, cancel };

pub const priority_names = [4][]const u8{ "DO NOW", "PLAN", "DELEGATE", "DROP" };

pub const Form = struct {
    title: TextInput,
    deadline: TextInput,
    priority: u8 = 1,
    field: Field = .title,
    err: ?[]const u8 = null,
    is_edit: bool = false,

    pub fn init(alloc: std.mem.Allocator) Form {
        return .{ .title = TextInput.init(alloc), .deadline = TextInput.init(alloc) };
    }

    pub fn deinit(self: *Form) void {
        self.title.deinit();
        self.deadline.deinit();
    }

    fn step(self: *Form, delta: i8) void {
        const n: i8 = @intCast(@intFromEnum(self.field));
        self.field = @enumFromInt(@as(u2, @intCast(@mod(n + delta, 3))));
    }

    /// Pasted text goes into the focused field as one line.
    pub fn paste(self: *Form, text: []const u8) !void {
        var buf: [512]u8 = undefined;
        const line = editor.flattenLine(&buf, text);
        switch (self.field) {
            .title => try self.title.insertSliceAtCursor(line),
            .deadline => try self.deadline.insertSliceAtCursor(line),
            .priority => {},
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
        if (key.matches(vaxis.Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) {
            if (self.field == .priority) return .save;
            self.step(1);
            return .none;
        }
        self.err = null;
        switch (self.field) {
            .title => try self.title.update(.{ .key_press = key }),
            .deadline => try self.deadline.update(.{ .key_press = key }),
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
        const h: u16 = 15;
        const r: draw.Rect = .{ .x = (win.width - w) / 2, .y = (win.height -| h) / 2, .w = w, .h = h };
        draw.box(win, r, theme.line_focus, theme.glass_sheen, false, false);
        _ = draw.text(win, r.x + 2, r.y, 20, if (self.is_edit) " EDIT TASK " else " NEW TASK ", .{ .fg = theme.bone, .bg = theme.glass_sheen, .bold = true });

        const x = r.x + 3;
        const iw = r.w - 6;

        label(win, x, r.y + 2, iw, "Title", self.field == .title);
        input(win, arena, &self.title, .{ .x = x, .y = r.y + 3, .w = iw, .h = 1 }, self.field == .title);

        label(win, x, r.y + 5, iw, "Deadline  (optional)", self.field == .deadline);
        input(win, arena, &self.deadline, .{ .x = x, .y = r.y + 6, .w = iw, .h = 1 }, self.field == .deadline);

        // live preview of what the deadline text means
        const dl_text = self.deadline.toOwnedContents(arena) catch "";
        const dim: theme.Style = .{ .fg = theme.bone_faint, .bg = theme.glass_sheen };
        if (std.mem.trim(u8, dl_text, " ").len == 0) {
            _ = draw.text(win, x + 2, r.y + 7, iw - 2, "no deadline · try 2026-10-05, 10-05, +3, +2w, today, tomorrow", dim);
        } else if (dates.parse(dl_text, today)) |maybe| {
            const d = maybe.?;
            var b1: [16]u8 = undefined;
            var b2: [32]u8 = undefined;
            const s = std.fmt.allocPrint(arena, "→ {s} {s} · {s}", .{ dates.weekday(d), dates.format(&b1, d), dates.relative(&b2, d, today) }) catch "";
            _ = draw.text(win, x + 2, r.y + 7, iw - 2, s, .{ .fg = theme.bone_dim, .bg = theme.glass_sheen });
        } else |_| {
            _ = draw.text(win, x + 2, r.y + 7, iw - 2, "can't read that — try 2026-10-05, 10-05, +3, today, tomorrow", .{ .fg = theme.p1, .bg = theme.glass_sheen });
        }

        label(win, x, r.y + 9, iw, "Priority  (matrix square)", self.field == .priority);
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
            draw.fill(win, .{ .x = cx, .y = r.y + 10, .w = cw, .h = 1 }, st.bg);
            _ = draw.text(win, cx, r.y + 10, cw, s, st);
            cx += cw + 1;
        }

        if (self.err) |e| _ = draw.text(win, x + 2, r.y + 12, iw - 2, e, .{ .fg = theme.p1, .bg = theme.glass_sheen });
        _ = draw.text(win, x, r.y + 13, iw, "tab next · enter confirm · ctrl+s save · esc cancel", dim);
    }
};
