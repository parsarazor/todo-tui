//! Renders the whole screen and records where things are (for the mouse).
const std = @import("std");
const vaxis = @import("vaxis");
const model = @import("model.zig");
const dates = @import("dates.zig");
const theme = @import("theme.zig");
const draw = @import("draw.zig");
const form_mod = @import("form.zig");
const brain_view = @import("brain_view.zig");
const log_view = @import("log_view.zig");
const state = @import("state.zig");
const App = state.App;
const Rect = draw.Rect;
const Zone = model.Zone;

const min_w = 64;
const min_h = 18;
const card_h = 2;
const card_pitch = 3; // 2 rows + 1 blank

pub fn render(app: *App, win: vaxis.Window, fa: std.mem.Allocator) void {
    win.fill(.{ .style = .{ .bg = theme.black } });
    // vaxis keeps the cursor visible until told otherwise; only the form's
    // text field (drawn later in this frame) turns it back on.
    win.hideCursor();
    app.cards.clearRetainingCapacity();
    app.zone_rects = @splat(.{});

    if (win.width < min_w or win.height < min_h) {
        const msg = "terminal too small — enlarge the window";
        const x = (win.width -| win.gwidth(msg)) / 2;
        _ = draw.text(win, x, win.height / 2, win.width - x, msg, .{ .fg = theme.bone_dim, .bg = theme.black });
        return;
    }

    header(app, win, fa);
    layout(app, win);

    const target: ?Zone = if (app.drag) |d| (if (d.active) app.zoneAt(d.col, d.row) else null) else null;

    // backlog container
    const backlog_rect = app.backlog_rect;
    var backlog_count: usize = 0;
    for (0..4) |i| backlog_count += app.lists[i].len;
    const backlog_focus = app.focus.isMatrix();
    draw.box(win, backlog_rect, if (backlog_focus) theme.line_focus else theme.line, theme.glass, false, false);
    panelTitle(win, fa, backlog_rect, "BACKLOG", backlog_count, theme.bone, theme.glass);

    zone(app, win, fa, .q1, "P1 · DO NOW", target);
    zone(app, win, fa, .q2, "P2 · PLAN", target);
    zone(app, win, fa, .q3, "P3 · DELEGATE", target);
    zone(app, win, fa, .q4, "P4 · DROP", target);
    zone(app, win, fa, .doing, "IN PROGRESS", target);
    zone(app, win, fa, .done, "DONE", target);

    footer(app, win, fa);

    if (app.drag) |d| if (d.active) ghost(app, win, d);

    switch (app.mode) {
        .form => if (app.form) |*f| f.draw_modal(win, fa, app.today),
        .help => helpOverlay(win),
        .brainstorm => brain_view.render(&app.brain, win, fa),
        .log => log_view.render(&app.logbook, win, fa, .{
            .entries = app.worklog.entries.items,
            .board = &app.board,
            .params = app.params,
            .now = app.now,
            .tz = .{},
        }),
        else => {},
    }
}

// ---- layout ---------------------------------------------------------------

fn layout(app: *App, win: vaxis.Window) void {
    const W = win.width;
    const H = win.height;
    const body_y: u16 = 1;
    const body_h: u16 = H - 2;
    const gap: u16 = 1;

    const back_w: u16 = W / 2;
    const rem = W - back_w - 2 * gap;
    const doing_w = rem / 2;
    const done_w = rem - doing_w;

    app.backlog_rect = .{ .x = 0, .y = body_y, .w = back_w, .h = body_h };
    app.zone_rects[Zone.doing.index()] = .{ .x = back_w + gap, .y = body_y, .w = doing_w, .h = body_h };
    app.zone_rects[Zone.done.index()] = .{ .x = back_w + gap + doing_w + gap, .y = body_y, .w = done_w, .h = body_h };

    // 2x2 priority matrix inside the backlog box
    const inner = app.backlog_rect.inset(2, 1);
    const left_w = (inner.w -| 1) / 2;
    const right_w = inner.w -| left_w -| 1;
    const top_h = inner.h / 2;
    const bot_h = inner.h - top_h;
    app.zone_rects[Zone.q1.index()] = .{ .x = inner.x, .y = inner.y, .w = left_w, .h = top_h };
    app.zone_rects[Zone.q2.index()] = .{ .x = inner.x + left_w + 1, .y = inner.y, .w = right_w, .h = top_h };
    app.zone_rects[Zone.q3.index()] = .{ .x = inner.x, .y = inner.y + top_h, .w = left_w, .h = bot_h };
    app.zone_rects[Zone.q4.index()] = .{ .x = inner.x + left_w + 1, .y = inner.y + top_h, .w = right_w, .h = bot_h };
}

// ---- panels -----------------------------------------------------------------

fn panelTitle(win: vaxis.Window, fa: std.mem.Allocator, r: Rect, title: []const u8, count: usize, fg: theme.Color, bg: theme.Color) void {
    const s = std.fmt.allocPrint(fa, " {s} ", .{title}) catch return;
    const used = draw.text(win, r.x + 2, r.y, r.w -| 4, s, .{ .fg = fg, .bg = bg, .bold = true });
    const c = std.fmt.allocPrint(fa, " {d} ", .{count}) catch return;
    const cw = win.gwidth(c);
    if (r.w > used + cw + 6) {
        _ = draw.text(win, r.x + r.w - 2 - cw, r.y, cw, c, .{ .fg = theme.bone_dim, .bg = bg });
    }
}

fn zone(app: *App, win: vaxis.Window, fa: std.mem.Allocator, z: Zone, title: []const u8, target: ?Zone) void {
    const r = app.zone_rects[z.index()];
    if (r.w < 8 or r.h < 4) return;
    const zi = z.index();
    const ids = app.lists[zi];
    const focused = app.focus == z;
    const is_target = target != null and target.? == z;
    const accent = theme.zoneAccent(z);

    var line: theme.Color = if (z.isMatrix())
        theme.fade(accent, if (focused) 100 else 55)
    else if (focused) theme.line_focus else theme.line;
    if (is_target) line = accent;

    draw.box(win, r, line, theme.glass, is_target, focused and z.isMatrix());

    // title on the top border
    const title_fg = if (z.isMatrix()) theme.fade(accent, if (focused) 100 else 80) else theme.bone;
    const shown = std.fmt.allocPrint(fa, " {s} ", .{title}) catch title;
    _ = draw.text(win, r.x + 2, r.y, r.w -| 4, shown, .{ .fg = title_fg, .bg = theme.glass, .bold = true });
    const count_s = std.fmt.allocPrint(fa, " {d} ", .{ids.len}) catch "";
    const cw = win.gwidth(count_s);
    if (r.w > cw + 6) _ = draw.text(win, r.x + r.w - 2 - cw, r.y, cw, count_s, .{ .fg = theme.bone_dim, .bg = theme.glass });

    // cards
    const inner = r.inset(1, 1);
    const cx = inner.x + 1;
    const cw2 = inner.w -| 2;
    if (cw2 < 6 or inner.h == 0) return;

    if (ids.len == 0) {
        const msg = if (is_target) "drop here" else "empty";
        _ = draw.text(win, cx, inner.y, cw2, msg, .{ .fg = if (is_target) accent else theme.bone_faint, .bg = theme.glass, .italic = true });
        return;
    }

    const cap: usize = @max(1, (@as(usize, inner.h) + 1) / card_pitch);
    app.capacity[zi] = cap;
    if (ids.len <= cap) {
        app.scroll[zi] = 0;
    } else {
        app.scroll[zi] = @min(app.scroll[zi], ids.len - cap);
    }
    const first = app.scroll[zi];
    const last = @min(ids.len, first + cap);

    var i = first;
    while (i < last) : (i += 1) {
        const id = ids[i];
        const t = app.board.getConst(id) orelse continue;
        const rect: Rect = .{
            .x = cx,
            .y = inner.y + @as(u16, @intCast((i - first) * card_pitch)),
            .w = cw2,
            .h = card_h,
        };
        if (rect.y + card_h > inner.y + inner.h) break;
        const dragged = if (app.drag) |d| d.active and d.id == id else false;
        card(app, win, fa, t, rect, app.sel != null and app.sel.? == id and focused, dragged);
        app.cards.append(app.alloc, .{ .id = id, .rect = rect }) catch {};
    }

    // overflow markers on the bottom border
    if (first > 0) {
        const s = std.fmt.allocPrint(fa, " ▴ {d} ", .{first}) catch "";
        _ = draw.text(win, r.x + 2, r.y + r.h - 1, 12, s, .{ .fg = theme.bone_dim, .bg = theme.glass });
    }
    if (last < ids.len) {
        const s = std.fmt.allocPrint(fa, " ▾ {d} ", .{ids.len - last}) catch "";
        const w = win.gwidth(s);
        _ = draw.text(win, r.x + r.w - 2 - w, r.y + r.h - 1, w, s, .{ .fg = theme.bone_dim, .bg = theme.glass });
    }
}

fn card(app: *App, win: vaxis.Window, fa: std.mem.Allocator, t: *const model.Task, r: Rect, selected: bool, dragged: bool) void {
    const done = t.status == .done;
    const bg = if (selected) theme.glass_hi else theme.glass;
    draw.fill(win, r, bg);

    const pcol = theme.priorityColor(t.priority);
    const bar_col = if (dragged or done) theme.bone_faint else if (selected) pcol else theme.fade(pcol, 60);
    _ = draw.text(win, r.x, r.y, 1, "▌", .{ .fg = bar_col, .bg = bg });
    _ = draw.text(win, r.x, r.y + 1, 1, "▌", .{ .fg = bar_col, .bg = bg });

    const tx = r.x + 2;
    const tw = r.w -| 2;
    const title_style: theme.Style = if (dragged)
        .{ .fg = theme.bone_faint, .bg = bg }
    else if (done)
        .{ .fg = theme.bone_faint, .bg = bg, .strikethrough = true }
    else
        .{ .fg = theme.bone, .bg = bg, .bold = selected };
    _ = draw.text(win, tx, r.y, tw, t.title, title_style);

    // meta line: "P1  in 5d · 10-05 ............ ▶ 12m 05s"
    const label = std.fmt.allocPrint(fa, "P{d}", .{t.priority}) catch "P?";
    const lw = draw.text(win, tx, r.y + 1, tw, label, .{ .fg = if (done or dragged) theme.bone_faint else pcol, .bg = bg, .bold = true });
    const mx = tx + lw + 2;
    var mw = r.w -| (mx - r.x);

    // stopwatch, right-aligned: running (▶), paused (⏸) or finished (took ...)
    const el = model.elapsed(t.*, app.now);
    if (el > 0 or t.status == .doing) {
        // vaxis cells keep a pointer to their text until the frame is flushed,
        // so the string must live in the frame arena, not on the stack.
        var db: [24]u8 = undefined;
        const dur = fa.dupe(u8, dates.formatDuration(&db, el)) catch "?";
        // plain narrow glyphs only: ▶ and ⏸ are ambiguous-width in many terminals
        const glyph: []const u8 = switch (t.status) {
            .doing => "▸ ",
            .backlog => "‖ ",
            .done => "took ",
        };
        const gw = win.gwidth(glyph);
        const dw = win.gwidth(dur);
        if (gw + dw + 8 < mw) {
            const right = r.x + r.w; // one past the card's last column
            const dx = right - 1 - dw;
            const gx = dx - gw;
            const g_col: theme.Color = if (dragged) theme.bone_faint else switch (t.status) {
                .doing => theme.ok,
                .done => theme.bone_dim,
                .backlog => theme.bone_faint,
            };
            const d_col: theme.Color = if (dragged) theme.bone_faint else switch (t.status) {
                .doing => theme.bone,
                .done => theme.ok,
                .backlog => theme.bone_dim,
            };
            _ = draw.text(win, gx, r.y + 1, gw, glyph, .{ .fg = g_col, .bg = bg });
            _ = draw.text(win, dx, r.y + 1, dw, dur, .{ .fg = d_col, .bg = bg, .bold = t.status == .doing });
            mw = gx -| mx -| 2;
        }
    }
    if (t.deadline) |d| {
        var b1: [16]u8 = undefined;
        var b2: [32]u8 = undefined;
        // "5d overdue · 09-25" (year only shown when it isn't the current one)
        const cd = dates.civilFromDays(d);
        const same_year = cd.y == dates.civilFromDays(app.today).y;
        const short = if (same_year)
            (std.fmt.bufPrint(&b1, "{d:0>2}-{d:0>2}", .{ cd.m, cd.d }) catch "")
        else
            dates.format(&b1, d);
        const s = std.fmt.allocPrint(fa, "{s} · {s}", .{ dates.relative(&b2, d, app.today), short }) catch "";
        const col: theme.Color = if (done or dragged) theme.bone_faint else switch (dates.urgency(d, app.today)) {
            .overdue => theme.p1,
            .soon => theme.p2,
            .normal => theme.bone_dim,
        };
        _ = draw.text(win, mx, r.y + 1, mw, s, .{ .fg = col, .bg = bg });
    } else {
        // a bare dash when the timer leaves too little room for the words
        const msg: []const u8 = if (mw >= 11) "no deadline" else "—";
        _ = draw.text(win, mx, r.y + 1, mw, msg, .{ .fg = theme.bone_faint, .bg = bg });
    }
}

// ---- header / footer ----------------------------------------------------------

fn header(app: *App, win: vaxis.Window, fa: std.mem.Allocator) void {
    _ = draw.text(win, 1, 0, 8, "KANBAN", .{ .fg = theme.bone, .bg = theme.black, .bold = true });

    var open: usize = 0;
    var doing: usize = 0;
    var done: usize = 0;
    var overdue: usize = 0;
    for (app.board.tasks.items) |t| {
        switch (t.status) {
            .backlog => open += 1,
            .doing => doing += 1,
            .done => done += 1,
        }
        if (t.status != .done) {
            if (t.deadline) |d| if (d < app.today) {
                overdue += 1;
            };
        }
    }
    const stats = std.fmt.allocPrint(fa, "{d} backlog · {d} doing · {d} done", .{ open, doing, done }) catch "";
    _ = draw.text(win, 9, 0, win.width -| 40, stats, .{ .fg = theme.bone_dim, .bg = theme.black });

    var b: [16]u8 = undefined;
    const date_s = std.fmt.allocPrint(fa, "{s} {s}", .{ dates.weekday(app.today), dates.format(&b, app.today) }) catch "";
    var right = draw.textRight(win, win.width -| 1, 0, date_s, .{ .fg = theme.bone_dim, .bg = theme.black });
    if (overdue > 0) {
        const o = std.fmt.allocPrint(fa, "{d} overdue   ", .{overdue}) catch "";
        _ = draw.textRight(win, right, 0, o, .{ .fg = theme.p1, .bg = theme.black, .bold = true });
        right = 0;
    }
}

const hints = [_][2][]const u8{
    .{ "n", "new" },
    .{ "b", "brainstorm" },
    .{ "s", "log" },
    .{ "e", "edit" },
    .{ "x", "delete" },
    .{ "⇧←↑↓→", "move task" },
    .{ "1-4", "priority" },
    .{ "space", "advance" },
    .{ "drag", "mouse" },
    .{ "?", "help" },
    .{ "q", "quit" },
};

fn footer(app: *App, win: vaxis.Window, fa: std.mem.Allocator) void {
    const y = win.height - 1;
    if (app.mode == .brainstorm or app.mode == .log) return; // the popups carry their own hints
    if (app.mode == .confirm_delete) {
        if (app.sel) |id| if (app.board.getConst(id)) |t| {
            const s = std.fmt.allocPrint(fa, "Delete “{s}”?   y = delete · any other key = cancel", .{t.title}) catch return;
            _ = draw.text(win, 1, y, win.width -| 2, s, .{ .fg = theme.p1, .bg = theme.black, .bold = true });
            return;
        };
    }
    if (app.flash) |m| {
        _ = draw.text(win, 1, y, win.width -| 2, m, .{ .fg = if (app.flash_info) theme.ok else theme.p1, .bg = theme.black });
        return;
    }
    var x: u16 = 1;
    for (hints) |h| {
        const kw = win.gwidth(h[0]);
        const dw = win.gwidth(h[1]);
        if (x + kw + 1 + dw + 3 > win.width) break;
        _ = draw.text(win, x, y, kw, h[0], .{ .fg = theme.bone, .bg = theme.black, .bold = true });
        _ = draw.text(win, x + kw + 1, y, dw, h[1], .{ .fg = theme.bone_faint, .bg = theme.black });
        x += kw + 1 + dw + 3;
    }
}

// ---- drag ghost & help --------------------------------------------------------

fn ghost(app: *App, win: vaxis.Window, d: state.Drag) void {
    const t = app.board.getConst(d.id) orelse return;
    const gw: i32 = 34;
    // sit to the right of the pointer, or flip to its left near the screen edge
    const want_x: i32 = if (d.col + 2 + gw > win.width) d.col - gw - 1 else d.col + 2;
    const col: u16 = @intCast(std.math.clamp(want_x, 0, @as(i32, win.width) - 1));
    const row: u16 = @intCast(std.math.clamp(d.row - 1, 0, @as(i32, win.height) - 3));
    const w: u16 = @min(@as(u16, gw), win.width - col);
    if (w < 6) return;
    const r: Rect = .{ .x = col, .y = row, .w = w, .h = 3 };
    draw.box(win, r, theme.priorityColor(t.priority), theme.glass_hi, false, true);
    _ = draw.text(win, r.x + 2, r.y + 1, w -| 4, t.title, .{ .fg = theme.bone, .bg = theme.glass_hi, .bold = true });
}

const help_lines = [_][2][]const u8{
    .{ "← ↑ ↓ →   h j k l", "move the cursor" },
    .{ "⇧+arrows  H J K L", "move the task to the next square / column" },
    .{ "drag with the mouse", "drop on any square or column" },
    .{ "n", "new task in the focused square / column" },
    .{ "b", "brainstorm: a blank page per topic" },
    .{ "s", "log: hours per day, streaks, forecasts" },
    .{ "e  Enter  double-click", "edit title, deadline, priority" },
    .{ "1 2 3 4", "set priority (moves it to that square)" },
    .{ "space", "advance: backlog → in progress → done" },
    .{ "x", "delete (asks first)" },
    .{ "mouse wheel", "scroll a long list" },
    .{ "q  ctrl+c", "quit — everything is saved as you go" },
};

fn helpOverlay(win: vaxis.Window) void {
    const w: u16 = @min(70, win.width -| 4);
    const h: u16 = help_lines.len + 4;
    const r: Rect = .{ .x = (win.width - w) / 2, .y = (win.height -| h) / 2, .w = w, .h = h };
    draw.box(win, r, theme.line_focus, theme.glass_sheen, false, false);
    _ = draw.text(win, r.x + 2, r.y, 12, " KEYS ", .{ .fg = theme.bone, .bg = theme.glass_sheen, .bold = true });
    for (help_lines, 0..) |l, i| {
        const y = r.y + 2 + @as(u16, @intCast(i));
        _ = draw.text(win, r.x + 3, y, 24, l[0], .{ .fg = theme.bone, .bg = theme.glass_sheen, .bold = true });
        _ = draw.text(win, r.x + 29, y, w -| 32, l[1], .{ .fg = theme.bone_dim, .bg = theme.glass_sheen });
    }
    _ = draw.text(win, r.x + 3, r.y + r.h - 1, w -| 6, " any key to close ", .{ .fg = theme.bone_faint, .bg = theme.glass_sheen });
}
