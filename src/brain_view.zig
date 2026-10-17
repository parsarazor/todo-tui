//! Draws the brainstorm popup. Deliberately plain: one panel, a few dim hints,
//! and on a topic page nothing but your words.
const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const draw = @import("draw.zig");
const dates = @import("dates.zig");
const editor = @import("editor.zig");
const bs = @import("brainstorm.zig");
const Rect = draw.Rect;

const bg = theme.glass;
const row_pitch = 3; // title, preview, blank

pub fn render(b: *bs.Brain, win: vaxis.Window, fa: std.mem.Allocator) void {
    const r: Rect = .{ .x = 4, .y = 2, .w = win.width -| 8, .h = win.height -| 4 };
    if (r.w < 40 or r.h < 10) return;
    b.hits.clearRetainingCapacity();
    // Cover the board completely: a half-hidden board behind the popup is just noise.
    win.fill(.{ .style = .{ .bg = theme.black } });
    draw.box(win, r, theme.line_focus, bg, false, false);
    switch (b.view) {
        .list => list(b, win, fa, r),
        .page => page(b, win, fa, r),
    }
}

fn titleBar(win: vaxis.Window, fa: std.mem.Allocator, r: Rect, title: []const u8, right: []const u8) void {
    var avail: u16 = r.w -| 4;
    if (right.len > 0) {
        const rs = std.fmt.allocPrint(fa, " {s} ", .{right}) catch "";
        const w = win.gwidth(rs);
        _ = draw.text(win, r.x + r.w - 2 - w, r.y, w, rs, .{ .fg = theme.bone_dim, .bg = bg });
        avail -|= w + 1;
    }
    const ts = std.fmt.allocPrint(fa, " {s} ", .{title}) catch title;
    _ = draw.text(win, r.x + 2, r.y, avail, ts, .{ .fg = theme.bone, .bg = bg, .bold = true });
}

/// "key label   key label" along one row, stopping when it no longer fits.
fn hints(win: vaxis.Window, x: u16, y: u16, w: u16, items: []const [2][]const u8) void {
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

fn firstLine(body: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len > 0) return t;
    }
    return "";
}

// ---- topic list ------------------------------------------------------------------------

fn list(b: *bs.Brain, win: vaxis.Window, fa: std.mem.Allocator, r: Rect) void {
    const n = b.notes.topics.items.len;
    const count = std.fmt.allocPrint(fa, "{d} {s}", .{ n, if (n == 1) "topic" else "topics" }) catch "";
    titleBar(win, fa, r, "BRAINSTORM", count);

    const x = r.x + 3;
    const w = r.w - 6;
    var y = r.y + 2;

    if (b.prompt == .new_topic or b.prompt == .rename) {
        const label = if (b.prompt == .new_topic) "New topic" else "Rename topic";
        _ = draw.text(win, x, y, w, label, .{ .fg = theme.bone_dim, .bg = bg });
        const field: Rect = .{ .x = x, .y = y + 1, .w = w, .h = 1 };
        draw.fill(win, field, theme.glass_hi);
        const inner = field.inset(1, 0);
        if (inner.w > 0) {
            const child = win.child(.{ .x_off = @intCast(inner.x), .y_off = @intCast(inner.y), .width = inner.w, .height = 1 });
            b.title_input.drawWithStyle(child, .{ .fg = theme.bone, .bg = theme.glass_hi });
        }
        y += 3;
    }

    const bottom = r.y + r.h - 3; // exclusive; the hint row is r.y + r.h - 2
    const avail: u16 = bottom -| y;
    const cap: usize = @max(1, (@as(usize, avail) + 1) / row_pitch);
    b.capacity = cap;

    if (n == 0) {
        if (b.prompt == .none) {
            const cy = y + avail / 3;
            const m1 = "Nothing here yet";
            const m2 = "press n to start a topic — each one is a blank page for your thoughts";
            _ = draw.text(win, x + (w -| win.gwidth(m1)) / 2, cy, w, m1, .{ .fg = theme.bone_dim, .bg = bg });
            _ = draw.text(win, x + (w -| @min(win.gwidth(m2), w)) / 2, cy + 2, w, m2, .{ .fg = theme.bone_faint, .bg = bg });
        }
    } else {
        if (b.sel >= n) b.sel = n - 1;
        if (b.sel < b.scroll) b.scroll = b.sel else if (b.sel >= b.scroll + cap) b.scroll = b.sel + 1 - cap;

        var i = b.scroll;
        var k: u16 = 0;
        while (i < n and i < b.scroll + cap) : ({
            i += 1;
            k += 1;
        }) {
            const t = b.notes.topics.items[i];
            const row: Rect = .{ .x = r.x + 2, .y = y + k * row_pitch, .w = r.w - 4, .h = 2 };
            if (row.y + 1 >= bottom + 1) break;
            const selected = i == b.sel;
            const rbg = if (selected) theme.glass_hi else bg;
            draw.fill(win, row, rbg);
            if (selected) {
                _ = draw.text(win, row.x, row.y, 1, "▌", .{ .fg = theme.bone, .bg = rbg });
                _ = draw.text(win, row.x, row.y + 1, 1, "▌", .{ .fg = theme.bone, .bg = rbg });
            }
            const tx = row.x + 3;
            const tw = row.w -| 4;
            _ = draw.text(win, tx, row.y, tw, t.title, .{ .fg = theme.bone, .bg = rbg, .bold = selected });

            var ab: [24]u8 = undefined;
            const meta = std.fmt.allocPrint(fa, "{d} words · {s}", .{ editor.wordCount(t.body), dates.formatAgo(&ab, b.now - t.updated) }) catch "";
            const mw = win.gwidth(meta);
            const meta_x = tx + tw -| mw;
            _ = draw.text(win, meta_x, row.y + 1, mw, meta, .{ .fg = theme.bone_faint, .bg = rbg });

            const pv = firstLine(t.body);
            const pw = meta_x -| tx -| 2;
            if (pv.len > 0)
                _ = draw.text(win, tx, row.y + 1, pw, pv, .{ .fg = theme.bone_dim, .bg = rbg })
            else
                _ = draw.text(win, tx, row.y + 1, pw, "empty page", .{ .fg = theme.bone_faint, .bg = rbg, .italic = true });

            b.hits.append(b.alloc, .{ .idx = i, .rect = row }) catch {};
        }

        if (b.scroll > 0) {
            const s = std.fmt.allocPrint(fa, " ▴ {d} ", .{b.scroll}) catch "";
            _ = draw.text(win, r.x + 2, r.y + r.h - 1, 12, s, .{ .fg = theme.bone_dim, .bg = bg });
        }
        const below = n - @min(n, b.scroll + cap);
        if (below > 0) {
            const s = std.fmt.allocPrint(fa, " ▾ {d} ", .{below}) catch "";
            const sw = win.gwidth(s);
            _ = draw.text(win, r.x + r.w - 2 - sw, r.y + r.h - 1, sw, s, .{ .fg = theme.bone_dim, .bg = bg });
        }
    }

    // hint row
    const hy = r.y + r.h - 2;
    switch (b.prompt) {
        .confirm_delete => {
            const title = if (n > 0) b.notes.topics.items[b.sel].title else "";
            const s = std.fmt.allocPrint(fa, "Delete “{s}” and everything written in it?   y = delete · any other key = cancel", .{title}) catch "";
            _ = draw.text(win, x, hy, w, s, .{ .fg = theme.p1, .bg = bg, .bold = true });
        },
        .new_topic, .rename => hints(win, x, hy, w, &.{
            .{ "enter", "confirm" },
            .{ "esc", "cancel" },
        }),
        .none => hints(win, x, hy, w, &.{
            .{ "enter", "open" },
            .{ "n", "new" },
            .{ "r", "rename" },
            .{ "x", "delete" },
            .{ "⇧↑↓", "reorder" },
            .{ "esc", "close" },
        }),
    }
}

// ---- a topic's page ------------------------------------------------------------------------

fn page(b: *bs.Brain, win: vaxis.Window, fa: std.mem.Allocator, r: Rect) void {
    const id = b.open_id orelse return;
    const idx = b.notes.indexOf(id) orelse return;
    const topic = b.notes.topics.items[idx];

    const words = editor.wordCount(b.ed.text());
    const wc = std.fmt.allocPrint(fa, "{d} {s}", .{ words, if (words == 1) "word" else "words" }) catch "";
    titleBar(win, fa, r, topic.title, wc);

    const text_w: u16 = @min(88, r.w - 8);
    const x0 = r.x + (r.w - text_w) / 2;
    const y0 = r.y + 2;
    const h: u16 = r.h -| 5;
    b.page_w = text_w;
    b.page_h = h;
    b.method = win.screen.width_method;

    const rows = b.ed.layout(fa, text_w, b.method) catch return;
    const cr = editor.Editor.rowOf(rows, b.ed.cursor);

    // keep the cursor row on screen
    if (cr < b.ed.scroll) b.ed.scroll = cr else if (cr >= b.ed.scroll + h) b.ed.scroll = cr + 1 - h;
    b.ed.scroll = @min(b.ed.scroll, rows.len -| 1);

    const body_style: vaxis.Style = .{ .fg = theme.bone, .bg = bg };
    const t = b.ed.text();
    var k: u16 = 0;
    while (k < h and b.ed.scroll + k < rows.len) : (k += 1) {
        const row = rows[b.ed.scroll + k];
        draw.raw(win, x0, y0 + k, text_w, t[row.start..row.end], body_style);
    }

    if (t.len == 0) {
        draw.raw(win, x0, y0, text_w, "Write freely — ideas, questions, things to settle with yourself…", .{ .fg = theme.bone_faint, .bg = bg, .italic = true });
    }

    if (b.ed.scroll > 0) _ = draw.text(win, r.x + r.w - 4, y0, 1, "▴", .{ .fg = theme.bone_faint, .bg = bg });
    if (b.ed.scroll + h < rows.len) _ = draw.text(win, r.x + r.w - 4, y0 + h - 1, 1, "▾", .{ .fg = theme.bone_faint, .bg = bg });

    // the one place a text cursor is wanted
    const col = b.ed.colOf(rows[cr], b.ed.cursor, b.method);
    win.showCursor(x0 + @min(col, text_w -| 1), y0 + @as(u16, @intCast(cr - b.ed.scroll)));

    const hy = r.y + r.h - 2;
    hints(win, x0, hy, text_w, &.{.{ "esc", "back to topics" }});
    const state: []const u8 = if (b.isDirty()) "saving…" else "saved";
    _ = draw.textRight(win, x0 + text_w, hy, state, .{ .fg = theme.bone_faint, .bg = bg });
}
