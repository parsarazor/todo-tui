//! Draws the Log popup: a week view (hours per day, totals, comparison with the
//! previous week, what happened on the selected day) and an insights report
//! (forecasts, probabilities, streaks, durations, rhythm).
const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const draw = @import("draw.zig");
const dates = @import("dates.zig");
const model = @import("model.zig");
const stats = @import("stats.zig");
const worklog = @import("worklog.zig");
const lbk = @import("logbook.zig");
const vk = @import("viewkit.zig");
const dashboard = @import("dashboard.zig");

const Rect = draw.Rect;
const Ledger = stats.Ledger;
const Allocator = std.mem.Allocator;
const bg = theme.glass;

pub const Data = dashboard.Data;

// ---- shared helpers live in viewkit.zig -------------------------------------------------------

const Kind = vk.Kind;
const Seg = vk.Seg;
const Line = vk.Line;
const Lines = vk.Lines;
const f = vk.f;
const add = vk.add;
const blank = vk.blank;
const drawLine = vk.drawLine;
const drawLines = vk.drawLines;
const hm = vk.hm;
const hmHours = vk.hmHours;
const clip = vk.clip;
const bar = vk.bar;
const probKind = vk.probKind;
const percentText = vk.percentText;
const probText = vk.probText;
const deltaSeg = vk.deltaSeg;
const hints = vk.hints;
const clock = vk.clock;


// ---- entry point ---------------------------------------------------------------------------------

pub fn render(lb: *lbk.Logbook, win: vaxis.Window, fa: Allocator, data: Data) void {
    const r: Rect = .{ .x = 4, .y = 2, .w = win.width -| 8, .h = win.height -| 4 };
    if (r.w < 44 or r.h < 12) return;
    win.fill(.{ .style = .{ .bg = theme.black } });
    draw.box(win, r, theme.line_focus, bg, false, false);

    // tasks sitting in "In Progress" are work in flight: count them up to now
    var running: std.ArrayList(worklog.Session) = .empty;
    for (data.board.tasks.items) |t| {
        if (t.status != .doing) continue;
        const start = t.started orelse continue;
        running.append(fa, .{ .id = t.id, .start = start, .end = data.now, .priority = t.priority, .title = t.title }) catch {};
    }
    const l = Ledger.build(fa, data.tz, data.now, data.entries, running.items) catch return;

    lb.min_offset = @divFloor(dates.weekStart(l.first_day) - dates.weekStart(l.today), 7);
    lb.week_offset = std.math.clamp(lb.week_offset, lb.min_offset, 0);
    lb.today_weekday = dates.weekdayIndex(l.today);

    // title bar and tabs
    _ = draw.text(win, r.x + 2, r.y, 14, " DASHBOARD ", .{ .fg = theme.bone, .bg = bg, .bold = true });
    if (l.hasData()) {
        var b: [16]u8 = undefined;
        const since = f(fa, " since {s} ", .{dates.formatDayMonth(&b, l.first_day)});
        _ = draw.textRight(win, r.x + r.w - 2, r.y, since, .{ .fg = theme.bone_dim, .bg = bg });
    }
    const tabs = [_][]const u8{ "Dashboard", "Trends", "Board", "Practice", "Week", "Insights" };
    var tx = r.x + 3;
    for (tabs, 0..) |name, i| {
        const label = f(fa, " {s} ", .{name});
        const w = win.gwidth(label);
        const active = @intFromEnum(lb.tab) == i;
        const rect: Rect = .{ .x = tx, .y = r.y + 1, .w = w, .h = 1 };
        lb.tab_hits[i] = rect;
        draw.fill(win, rect, if (active) theme.glass_hi else bg);
        _ = draw.text(win, tx, r.y + 1, w, label, .{ .fg = if (active) theme.bone else theme.bone_dim, .bg = if (active) theme.glass_hi else bg, .bold = active });
        tx += w + 1;
    }

    const area: Rect = .{ .x = r.x + 3, .y = r.y + 3, .w = r.w - 6, .h = (r.y + r.h - 3) -| (r.y + 3) };
    switch (lb.tab) {
        .dashboard, .trends, .board, .practice => {
            dashboard.render(@enumFromInt(@intFromEnum(lb.tab)), win, fa, &l, data, area);
            hints(win, area.x, r.y + r.h - 2, area.w, &.{
                .{ "g/G", "goal" },
                .{ "w/W", "window" },
                .{ "m/M", "active day" },
                .{ "1-6", "tabs" },
                .{ "tab", "next" },
                .{ "esc", "close" },
            });
        },
        .week => weekTab(lb, win, fa, r, &l, data),
        .insights => insightsTab(lb, win, fa, r, &l, data),
    }
}

// ---- week tab ---------------------------------------------------------------------------------------

fn weekTab(lb: *lbk.Logbook, win: vaxis.Window, fa: Allocator, r: Rect, l: *const Ledger, data: Data) void {
    const params = data.params;
    const active_secs: i64 = @as(i64, params.active_min) * 60;
    const ws = dates.weekStart(l.today) + lb.week_offset * 7;
    const w = stats.week(l, ws, active_secs);
    const cmp = stats.compare(l, w, active_secs);

    const ix = r.x + 3;
    const iw = r.w - 6;
    const top = r.y + 3;
    const content_bottom = r.y + r.h - 3; // exclusive
    const wide = iw >= 112;
    const left_w: u16 = if (wide) 66 else iw;

    // header: which week
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    const end_day = ws + 6;
    const year = dates.civilFromDays(end_day).y;
    const range = f(fa, "{s} – {s} {d}", .{ dates.formatDayMonth(&b1, ws), dates.formatDayMonth(&b2, end_day), year });
    const when: Seg = switch (lb.week_offset) {
        0 => .{ .text = "  this week", .kind = .good },
        -1 => .{ .text = "  last week", .kind = .dim },
        else => .{ .text = f(fa, "  {d} weeks ago", .{-lb.week_offset}), .kind = .dim },
    };
    drawLine(win, ix, top, iw, &.{ .{ .text = "WEEK  ", .kind = .head }, .{ .text = range, .kind = .value }, when }, bg);

    // seven day rows with bars
    var max_day: i64 = 4 * 3600;
    for (w.secs) |s| max_day = @max(max_day, s);
    const bar_x = ix + 10;
    const bw: u16 = @min(36, left_w -| 32);
    for (0..7) |i| {
        const day = ws + @as(i32, @intCast(i));
        const y = top + 2 + @as(u16, @intCast(i));
        lb.day_hits[i] = .{};
        if (y >= content_bottom) break;
        const row: Rect = .{ .x = ix, .y = y, .w = left_w, .h = 1 };
        lb.day_hits[i] = row;
        const selected = lb.day == i;
        const rbg = if (selected) theme.glass_hi else bg;
        draw.fill(win, row, rbg);
        const future = day > l.today;
        const is_today = day == l.today;

        if (selected) _ = draw.text(win, ix, y, 2, "▸", .{ .fg = theme.bone, .bg = rbg });
        const label = f(fa, "{s} {d:>2}", .{ dates.weekday_names[i], dates.civilFromDays(day).d });
        _ = draw.text(win, ix + 2, y, 7, label, .{ .fg = if (future) theme.bone_faint else if (is_today) theme.bone else theme.bone_dim, .bg = rbg, .bold = is_today });

        const secs = w.secs[i];
        if (!future and bw >= 4) {
            const frac = @as(f64, @floatFromInt(secs)) / @as(f64, @floatFromInt(max_day));
            const col = if (is_today) theme.bone else theme.fade(theme.bone, 70);
            draw.raw(win, bar_x, y, bw, bar(fa, frac, bw), .{ .fg = col, .bg = rbg });
        }
        const hx = bar_x + bw + 2;
        if (!future) {
            if (secs > 0)
                _ = draw.text(win, hx, y, 9, hm(fa, secs), .{ .fg = theme.bone, .bg = rbg })
            else
                _ = draw.text(win, hx, y, 9, "–", .{ .fg = theme.bone_faint, .bg = rbg });
            if (w.done[i] > 0) _ = draw.text(win, hx + 10, y, 8, f(fa, "✓ {d}", .{w.done[i]}), .{ .fg = theme.ok, .bg = rbg });
        }
    }

    // totals
    var y = top + 2 + 7 + 1;
    const avg_secs: i64 = if (w.days_counted > 0) @divFloor(w.total, w.days_counted) else 0;
    if (y + 1 < content_bottom) {
        drawLine(win, ix, y, left_w, &.{
            .{ .text = "total ", .kind = .label },
            .{ .text = hm(fa, w.total), .kind = .value },
            .{ .text = "    avg / day ", .kind = .label },
            .{ .text = hm(fa, avg_secs), .kind = .value },
            .{ .text = f(fa, " over {d} {s}", .{ w.days_counted, if (w.days_counted == 1) "day" else "days" }), .kind = .dim },
        }, bg);
        drawLine(win, ix, y + 1, left_w, &.{
            .{ .text = "tasks done ", .kind = .label },
            .{ .text = f(fa, "{d}", .{w.done_total}), .kind = .value },
            .{ .text = "    active days ", .kind = .label },
            .{ .text = f(fa, "{d}", .{w.active_days}), .kind = .value },
            .{ .text = f(fa, " of {d}", .{w.days_counted}), .kind = .dim },
        }, bg);
    }
    y += 3;

    // comparison with the week before
    if (y + 1 < content_bottom) {
        if (!cmp.has_prev) {
            drawLine(win, ix, y, left_w, &.{.{ .text = "no earlier week in the log to compare with yet", .kind = .dim }}, bg);
            y += 2;
        } else {
            const head: Seg = if (cmp.aligned)
                .{ .text = f(fa, "vs last week at the same point  ({s} {s})", .{ dates.weekday_names[dates.weekdayIndex(l.today)], clock(fa, l.tz, l.now) }), .kind = .label }
            else
                .{ .text = "vs the week before", .kind = .label };
            drawLine(win, ix, y, left_w, &.{head}, bg);
            y += 1;
            const rows = [3]struct { name: []const u8, d: stats.Delta, as_time: bool }{
                .{ .name = "hours", .d = cmp.hours, .as_time = true },
                .{ .name = "avg / day", .d = cmp.per_day, .as_time = true },
                .{ .name = "tasks done", .d = cmp.done, .as_time = false },
            };
            for (rows) |row| {
                if (y >= content_bottom) break;
                const cur = if (row.as_time) hmHours(fa, row.d.cur) else f(fa, "{d}", .{@as(u32, @intFromFloat(row.d.cur))});
                const prev = if (row.as_time) hmHours(fa, row.d.prev) else f(fa, "{d}", .{@as(u32, @intFromFloat(row.d.prev))});
                drawLine(win, ix, y, left_w, &.{
                    .{ .text = f(fa, "  {s:<11}", .{row.name}), .kind = .label },
                    .{ .text = f(fa, "{s:<9}", .{cur}), .kind = .value },
                    .{ .text = "was ", .kind = .dim },
                    .{ .text = f(fa, "{s:<9}", .{prev}), .kind = .label },
                    deltaSeg(fa, row.d),
                }, bg);
                y += 1;
            }
            y += 1;
        }
    }

    // what happened on the selected day
    const day = ws + @as(i32, lb.day);
    const dx: u16 = if (wide) ix + left_w + 4 else ix;
    const dy: u16 = if (wide) top else y;
    const dw: u16 = if (wide) iw - left_w - 4 else iw;
    var lines: Lines = .empty;
    dayLines(fa, l, day, dw, &lines);
    const dh: u16 = if (content_bottom > dy) content_bottom - dy else 0;
    lb.detail_lines = lines.items.len;
    lb.detail_page = @max(dh, 1);
    lb.detail_scroll = @min(lb.detail_scroll, lines.items.len -| lb.detail_page);
    if (dh >= 3) {
        drawLines(win, dx, dy, dw, dh, lines.items, lb.detail_scroll);
        if (lb.detail_scroll + dh < lines.items.len)
            _ = draw.text(win, dx + dw -| 2, dy + dh - 1, 1, "▾", .{ .fg = theme.bone_dim, .bg = bg });
    }

    hints(win, ix, r.y + r.h - 2, iw, &.{
        .{ "←→", "week" },
        .{ "↑↓", "day" },
        .{ "t", "this week" },
        .{ "PgUp/PgDn", "details" },
        .{ "tab", "next tab" },
        .{ "esc", "close" },
    });
}

fn prioritySeg(a: Allocator, p: u8) Seg {
    return .{ .text = f(a, "  P{d}", .{p}), .color = theme.priorityColor(p) };
}

fn dayLines(a: Allocator, l: *const Ledger, day: i32, pane_w: u16, lines: *Lines) void {
    const title_max: usize = @intCast(std.math.clamp(@as(i32, pane_w) - 28, 12, 34));
    var b: [16]u8 = undefined;
    const det = stats.dayDetail(a, l, day) catch return;
    add(a, lines, &.{
        .{ .text = f(a, "{s} {s}", .{ dates.weekday_names[dates.weekdayIndex(day)], dates.formatDayMonth(&b, day) }), .kind = .head },
        .{ .text = f(a, "  ·  {s} worked  ·  {d} done", .{ hm(a, det.total_secs), det.done.len }), .kind = .label },
    });
    if (det.done.len == 0 and det.worked.len == 0) {
        add(a, lines, &.{.{ .text = if (day > l.today) "that day hasn't happened yet" else "nothing logged this day", .kind = .dim }});
        return;
    }
    blank(a, lines);
    for (det.done) |c| {
        const today_secs = for (det.worked) |wk| {
            if (wk.id == c.id) break wk.secs;
        } else 0;
        const that_day: Seg = if (today_secs > 0 and today_secs != c.took)
            .{ .text = f(a, "  ({s} that day)", .{hm(a, today_secs)}), .kind = .dim }
        else
            .{ .text = "" };
        add(a, lines, &.{
            .{ .text = "✓ ", .kind = .good },
            .{ .text = f(a, "{s}  ", .{clock(a, l.tz, c.at)}), .kind = .dim },
            .{ .text = clip(a, c.title, title_max) },
            .{ .text = "  took ", .kind = .dim },
            .{ .text = if (c.took > 0) hm(a, c.took) else "–", .kind = .value },
            that_day,
            prioritySeg(a, c.priority),
        });
    }
    for (det.worked) |wk| {
        const finished = for (det.done) |c| {
            if (c.id == wk.id) break true;
        } else false;
        if (finished) continue;
        add(a, lines, &.{
            .{ .text = "· ", .kind = .dim },
            .{ .text = clip(a, wk.title, title_max) },
            .{ .text = "  " },
            .{ .text = hm(a, wk.secs), .kind = .value },
            .{ .text = " that day", .kind = .dim },
            prioritySeg(a, wk.priority),
        });
    }
}

// ---- insights tab -------------------------------------------------------------------------------------

fn insightsTab(lb: *lbk.Logbook, win: vaxis.Window, fa: Allocator, r: Rect, l: *const Ledger, data: Data) void {
    const ix = r.x + 3;
    const iw = r.w - 6;
    const top = r.y + 3;
    const h: u16 = (r.y + r.h - 3) -| top;

    var lines: Lines = .empty;
    insightLines(fa, l, data, &lines);

    lb.total_lines = lines.items.len;
    lb.page = @max(h, 1);
    lb.scroll = @min(lb.scroll, lines.items.len -| lb.page);
    drawLines(win, ix, top, iw, h, lines.items, lb.scroll);
    if (lb.scroll > 0) _ = draw.text(win, ix + iw -| 2, top, 1, "▴", .{ .fg = theme.bone_dim, .bg = bg });
    if (lb.scroll + h < lines.items.len) _ = draw.text(win, ix + iw -| 2, top + h - 1, 1, "▾", .{ .fg = theme.bone_dim, .bg = bg });

    hints(win, ix, r.y + r.h - 2, iw, &.{
        .{ "↑↓", "scroll" },
        .{ "g/G", "goal" },
        .{ "m/M", "active day" },
        .{ "a/A", "smoothing" },
        .{ "w/W", "window" },
        .{ "tab", "next tab" },
        .{ "esc", "close" },
    });
}

fn insightLines(a: Allocator, l: *const Ledger, data: Data, lines: *Lines) void {
    const p = data.params;
    const active_secs: i64 = @as(i64, p.active_min) * 60;
    const goal: f64 = @floatFromInt(p.goal_hours);

    // parameters: the knobs behind every estimate below
    add(a, lines, &.{.{ .text = "PARAMETERS", .kind = .head }});
    add(a, lines, &.{
        .{ .text = "weekly goal ", .kind = .label },
        .{ .text = f(a, "{d}h", .{p.goal_hours}), .kind = .value },
        .{ .text = " (g/G)", .kind = .dim },
        .{ .text = "     active day = at least ", .kind = .label },
        .{ .text = f(a, "{d} min", .{p.active_min}), .kind = .value },
        .{ .text = " (m/M)", .kind = .dim },
    });
    add(a, lines, &.{
        .{ .text = "smoothing ", .kind = .label },
        .{ .text = f(a, "{d}%", .{p.alpha_pct}), .kind = .value },
        .{ .text = " (a/A)", .kind = .dim },
        .{ .text = "     history window ", .kind = .label },
        .{ .text = f(a, "{d} weeks", .{p.window_weeks}), .kind = .value },
        .{ .text = " (w/W)", .kind = .dim },
    });
    blank(a, lines);

    if (!l.hasData()) {
        add(a, lines, &.{.{ .text = "Nothing logged yet.", .kind = .plain }});
        add(a, lines, &.{.{ .text = "Move a task into In Progress and finish it: hours, streaks and forecasts build up from there.", .kind = .dim }});
        return;
    }

    const weeks = stats.completeWeeks(a, l, p.window_weeks, active_secs) catch &.{};
    const cur = stats.week(l, dates.weekStart(l.today), active_secs);
    const n_weeks = weeks.len;

    // ---- this week
    add(a, lines, &.{.{ .text = "THIS WEEK", .kind = .head }});
    const frac = if (goal > 0) cur.hours() / goal else 0;
    add(a, lines, &.{
        .{ .text = "so far ", .kind = .label },
        .{ .text = hm(a, cur.total), .kind = .value },
        .{ .text = f(a, " of {d}h   ", .{p.goal_hours}), .kind = .dim },
        .{ .text = bar(a, frac, 20), .kind = if (frac >= 1) .good else .plain },
        .{ .text = f(a, "  {s}", .{percentText(a, @min(frac, 9.99))}), .kind = .dim },
    });
    const week_start_day = dates.weekStart(l.today);
    const seed: u64 = @as(u64, @intCast(@max(week_start_day, 0))) *% 0x9E3779B97F4A7C15;
    const proj = stats.projectWeek(a, l, weeks, goal, seed) catch null;
    if (proj) |pr| {
        add(a, lines, &.{
            .{ .text = "likely finish ", .kind = .label },
            .{ .text = hmHours(a, pr.p50), .kind = .value },
            .{ .text = f(a, "   80% of simulated weeks end between {s} and {s}", .{ hmHours(a, pr.p10), hmHours(a, pr.p90) }), .kind = .dim },
        });
        if (cur.hours() >= goal) {
            add(a, lines, &.{ .{ .text = f(a, "goal of {d}h ", .{p.goal_hours}), .kind = .label }, .{ .text = "reached ✓", .kind = .good } });
        } else {
            add(a, lines, &.{
                .{ .text = f(a, "chance of reaching {d}h ", .{p.goal_hours}), .kind = .label },
                .{ .text = probText(a, pr.p_goal), .kind = probKind(pr.p_goal) },
                .{ .text = "   from 4000 simulated rest-of-weeks", .kind = .dim },
            });
        }
    } else {
        add(a, lines, &.{.{ .text = f(a, "projection needs 2 complete weeks of history (you have {d})", .{n_weeks}), .kind = .dim }});
    }
    blank(a, lines);

    // ---- next week
    add(a, lines, &.{.{ .text = "NEXT WEEK", .kind = .head }});
    var fbuf: [26]f64 = undefined;
    if (stats.forecastNextWeek(weeks, p.alpha(), &fbuf)) |fc| {
        if (fc.lo != null and fc.hi != null) {
            add(a, lines, &.{
                .{ .text = "expected ", .kind = .label },
                .{ .text = hmHours(a, fc.next), .kind = .value },
                .{ .text = f(a, "   80% range {s} – {s}", .{ hmHours(a, fc.lo.?), hmHours(a, fc.hi.?) }), .kind = .dim },
            });
        } else {
            add(a, lines, &.{
                .{ .text = "expected ", .kind = .label },
                .{ .text = hmHours(a, fc.next), .kind = .value },
                .{ .text = "   (no range yet: needs 3 complete weeks)", .kind = .dim },
            });
        }
        if (fc.slope) |s| {
            const t: Seg = if (s > 0.05)
                .{ .text = f(a, "▲ +{d:.1}h per week", .{s}), .kind = .good }
            else if (s < -0.05)
                .{ .text = f(a, "▼ -{d:.1}h per week", .{-s}), .kind = .bad }
            else
                .{ .text = "flat", .kind = .dim };
            add(a, lines, &.{ .{ .text = "trend ", .kind = .label }, t });
        }
        add(a, lines, &.{.{ .text = f(a, "built from {d} complete {s}, recent ones weighted more", .{ fc.n, if (fc.n == 1) "week" else "weeks" }), .kind = .dim }});
    } else {
        add(a, lines, &.{.{ .text = "needs at least 2 complete weeks of history", .kind = .dim }});
    }
    blank(a, lines);

    // ---- streak
    add(a, lines, &.{.{ .text = "STREAK", .kind = .head }});
    const s = stats.streak(l, active_secs);
    if (s.current > 0) {
        add(a, lines, &.{
            .{ .text = "current ", .kind = .label },
            .{ .text = f(a, "{d} {s}", .{ s.current, if (s.current == 1) "day" else "days" }), .kind = .good },
            .{ .text = if (s.today_active) "" else "   today isn't active yet: do something to keep it going", .kind = .warn },
        });
    } else {
        add(a, lines, &.{ .{ .text = "current ", .kind = .label }, .{ .text = "none", .kind = .bad }, .{ .text = "   your next active day starts a new one", .kind = .dim } });
    }
    add(a, lines, &.{
        .{ .text = "longest ", .kind = .label },
        .{ .text = f(a, "{d} {s}", .{ s.longest, if (s.longest == 1) "day" else "days" }), .kind = .value },
        .{ .text = "     active days ", .kind = .label },
        .{ .text = f(a, "{d} of {d}", .{ s.active_days, s.total_days }), .kind = .value },
        .{ .text = f(a, "  ({s})", .{percentText(a, @as(f64, @floatFromInt(s.active_days)) / @as(f64, @floatFromInt(s.total_days)))}), .kind = .dim },
    });
    if (s.p_continue) |pc| {
        if (s.current > 0) {
            add(a, lines, &.{
                .{ .text = "chance it continues tomorrow ", .kind = .label },
                .{ .text = probText(a, pc), .kind = probKind(pc) },
                .{ .text = f(a, "   from {d} day-to-day transitions", .{s.samples}), .kind = .dim },
            });
            if (s.current < 7) {
                const reach = std.math.pow(f64, pc, @floatFromInt(7 - s.current));
                add(a, lines, &.{ .{ .text = "chance of reaching 7 days ", .kind = .label }, .{ .text = probText(a, reach), .kind = probKind(reach) } });
            }
            if (pc < 0.99) add(a, lines, &.{ .{ .text = "expected extra days ", .kind = .label }, .{ .text = f(a, "{d:.1}", .{pc / (1 - pc)}), .kind = .value } });
        } else if (s.p_restart) |pr| {
            add(a, lines, &.{
                .{ .text = "chance you start again tomorrow ", .kind = .label },
                .{ .text = probText(a, pr), .kind = probKind(pr) },
                .{ .text = f(a, "   from {d} day-to-day transitions", .{s.samples}), .kind = .dim },
            });
        }
    } else {
        add(a, lines, &.{.{ .text = "probabilities need a few more days of history", .kind = .dim }});
    }
    blank(a, lines);

    // ---- backlog
    add(a, lines, &.{.{ .text = "BACKLOG", .kind = .head }});
    var backlog_n: usize = 0;
    var doing_n: usize = 0;
    for (data.board.tasks.items) |t| switch (t.status) {
        .backlog => backlog_n += 1,
        .doing => doing_n += 1,
        .done => {},
    };
    const open = backlog_n + doing_n;
    add(a, lines, &.{
        .{ .text = "open tasks ", .kind = .label },
        .{ .text = f(a, "{d}", .{open}), .kind = .value },
        .{ .text = f(a, "   ({d} backlog, {d} in progress)", .{ backlog_n, doing_n }), .kind = .dim },
    });
    var bbuf: [26]f64 = undefined;
    if (stats.backlog(weeks, p.alpha(), open, &bbuf)) |bk| {
        add(a, lines, &.{
            .{ .text = "finished per week ", .kind = .label },
            .{ .text = f(a, "{d:.1}", .{bk.per_week}), .kind = .value },
            .{ .text = if (bk.sigma) |sg| f(a, "  ± {d:.1}", .{sg}) else "", .kind = .dim },
        });
        if (bk.weeks) |wk| {
            var b: [16]u8 = undefined;
            const finish_day = l.today + @as(i32, @intFromFloat(@round(wk * 7)));
            const range: []const u8 = if (bk.weeks_lo != null and bk.weeks_hi != null)
                f(a, "   80% range {d:.1} – {d:.1}", .{ bk.weeks_lo.?, bk.weeks_hi.? })
            else if (bk.weeks_lo != null)
                f(a, "   80% range from {d:.1} (slow end too uncertain)", .{bk.weeks_lo.?})
            else
                "";
            add(a, lines, &.{
                .{ .text = "at this pace ", .kind = .label },
                .{ .text = f(a, "≈ {d:.1} weeks", .{wk}), .kind = .value },
                .{ .text = range, .kind = .dim },
            });
            add(a, lines, &.{.{ .text = f(a, "around {s} if no new tasks arrive", .{dates.formatDayMonth(&b, finish_day)}), .kind = .dim }});
        } else if (open > 0) {
            add(a, lines, &.{.{ .text = "no finished tasks lately, so there's no pace to extrapolate", .kind = .dim }});
        }
    } else {
        add(a, lines, &.{.{ .text = "pace needs at least 2 complete weeks of history", .kind = .dim }});
    }
    blank(a, lines);

    // ---- durations
    add(a, lines, &.{.{ .text = "HOW LONG TASKS TAKE", .kind = .head }});
    for (1..5) |pi| {
        const pr: u8 = @intCast(pi);
        const d = stats.durations(a, l, pr) catch null;
        if (d) |dd| {
            add(a, lines, &.{
                .{ .text = f(a, "P{d}  ", .{pr}), .color = theme.priorityColor(pr) },
                .{ .text = "typically ", .kind = .label },
                .{ .text = hm(a, @intFromFloat(dd.median)), .kind = .value },
                .{ .text = "   80% finish within ", .kind = .label },
                .{ .text = hm(a, @intFromFloat(dd.p80)), .kind = .value },
                .{ .text = f(a, "   ({d} {s})", .{ dd.n, if (dd.n == 1) "task" else "tasks" }), .kind = .dim },
            });
        } else {
            add(a, lines, &.{ .{ .text = f(a, "P{d}  ", .{pr}), .color = theme.priorityColor(pr) }, .{ .text = "no finished tasks with tracked time yet", .kind = .dim } });
        }
    }
    for (data.board.tasks.items) |t| {
        if (t.status != .doing) continue;
        const el = model.elapsed(t, data.now);
        const typ = stats.typicalDuration(a, l, t.priority) catch null;
        var segs: std.ArrayList(Seg) = .empty;
        segs.appendSlice(a, &.{
            .{ .text = "▸ ", .kind = .good },
            .{ .text = clip(a, t.title, 30) },
            .{ .text = f(a, "   {s} so far", .{hm(a, el)}), .kind = .dim },
        }) catch {};
        if (typ) |ty| {
            const elf: f64 = @floatFromInt(el);
            segs.append(a, .{ .text = f(a, " · typical {s}   ", .{hm(a, @intFromFloat(ty.median))}), .kind = .dim }) catch {};
            segs.append(a, if (elf <= ty.median)
                .{ .text = "on pace", .kind = .good }
            else if (elf <= ty.p80)
                .{ .text = "past typical", .kind = .warn }
            else
                .{ .text = "running long", .kind = .bad }) catch {};
        }
        add(a, lines, segs.items);
    }
    blank(a, lines);

    // ---- rhythm
    add(a, lines, &.{.{ .text = "RHYTHM", .kind = .head }});
    if (weeks.len > 0) {
        const avg = stats.weekdayAverages(weeks);
        var best: usize = 0;
        var top_avg: f64 = 0;
        for (avg, 0..) |v, i| if (v > top_avg) {
            top_avg = v;
            best = i;
        };
        add(a, lines, &.{.{ .text = "average hours per weekday", .kind = .label }});
        for (avg, 0..) |v, i| {
            add(a, lines, &.{
                .{ .text = f(a, "  {s}  ", .{dates.weekday_names[i]}), .kind = if (i == best and top_avg > 0) .good else .dim },
                .{ .text = bar(a, if (top_avg > 0) v / top_avg else 0, 24), .kind = if (i == best and top_avg > 0) .good else .plain },
                .{ .text = f(a, "  {d:.1}h", .{v}), .kind = .dim },
            });
        }
        if (top_avg > 0) add(a, lines, &.{
            .{ .text = "most productive day ", .kind = .label },
            .{ .text = dates.weekday_names[best], .kind = .good },
        });
    } else {
        add(a, lines, &.{.{ .text = "weekday averages need one complete week of history", .kind = .dim }});
    }
    const hist = stats.hourHistogram(l, p.window_weeks);
    var peak: usize = 0;
    var peak_v: f64 = 0;
    for (hist, 0..) |v, i| if (v > peak_v) {
        peak_v = v;
        peak = i;
    };
    if (peak_v > 0) {
        const ramp = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
        var spark: std.ArrayList(u8) = .empty;
        for (hist) |v| spark.appendSlice(a, ramp[@intFromFloat(@round(v / peak_v * 8))]) catch {};
        blank(a, lines);
        add(a, lines, &.{.{ .text = "when you work (hour of day)", .kind = .label }});
        add(a, lines, &.{ .{ .text = "  " }, .{ .text = spark.items } });
        add(a, lines, &.{.{ .text = "  0     6     12    18   23", .kind = .dim }});
        add(a, lines, &.{
            .{ .text = "peak hour ", .kind = .label },
            .{ .text = f(a, "{d:0>2}:00 – {d:0>2}:00", .{ peak, (peak + 1) % 24 }), .kind = .value },
        });
    }
    blank(a, lines);
    add(a, lines, &.{.{ .text = "Forecasts are estimates from your own recent history, not promises: more weeks of data make them steadier.", .kind = .dim }});
}
