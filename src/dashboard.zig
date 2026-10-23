//! The management dashboard behind the Log popup. Three tabs of charts:
//!
//!   Dashboard  KPI cards, hours per day, weekly trend + forecast, time by priority,
//!              board status, when you work, weekday rhythm
//!   Trends     activity heatmap, weekly hours, tasks per week, running total,
//!              task durations (scatter + histogram)
//!   Board      priority matrix, deadlines, work in progress against its usual pace,
//!              how long tasks take, where finished work went
//!
//! Layout adapts to the terminal: KPI cards go 6 → 3 → 2 → 1 per row, and rows of chart
//! panels are dropped from the bottom (and panels from the right) when there isn't room.
//! The numbers all come from stats.zig; the pictures from charts.zig.
const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const draw = @import("draw.zig");
const dates = @import("dates.zig");
const model = @import("model.zig");
const stats = @import("stats.zig");
const worklog = @import("worklog.zig");
const charts = @import("charts.zig");
const vk = @import("viewkit.zig");

const Rect = draw.Rect;
const Ledger = stats.Ledger;
const Allocator = std.mem.Allocator;
const bg = vk.bg;

pub const Data = struct {
    entries: []const worklog.Entry,
    board: *const model.Board,
    params: stats.Params,
    now: i64,
    tz: dates.Tz,
};

/// Everything the panels need, computed once per frame.
pub const View = struct {
    win: vaxis.Window,
    a: Allocator,
    l: *const Ledger,
    data: Data,
    active_secs: i64,
    goal: f64,
    cur: stats.Week,
    prev: stats.Week,
    cmp: stats.Comparison,
    /// the last `window_weeks` weeks, the one in progress last
    recent: []const stats.Week,
    /// the last 53 weeks, for the calendar heatmap
    heat: []const stats.Week,
    /// finished weeks inside the window: what the forecasts are built on
    complete: []const stats.Week,
    snap: stats.BoardSnap,
    streak: stats.Streak,

    pub fn init(win: vaxis.Window, a: Allocator, l: *const Ledger, data: Data) View {
        const p = data.params;
        const active_secs: i64 = @as(i64, p.active_min) * 60;
        const ws = dates.weekStart(l.today);
        const cur = stats.week(l, ws, active_secs);
        return .{
            .win = win,
            .a = a,
            .l = l,
            .data = data,
            .active_secs = active_secs,
            .goal = @floatFromInt(p.goal_hours),
            .cur = cur,
            .prev = stats.week(l, ws - 7, active_secs),
            .cmp = stats.compare(l, cur, active_secs),
            .recent = stats.recentWeeks(a, l, p.window_weeks, active_secs) catch &.{},
            .heat = stats.recentWeeks(a, l, 53, active_secs) catch &.{},
            .complete = stats.completeWeeks(a, l, p.window_weeks, active_secs) catch &.{},
            .snap = stats.boardSnap(data.board, l.today),
            .streak = stats.streak(l, active_secs),
        };
    }
};

// ---- small helpers ---------------------------------------------------------------------------------------

const f = vk.f;

fn segs(a: Allocator, items: []const vk.Seg) vk.Line {
    return a.dupe(vk.Seg, items) catch &.{};
}

fn style(kind: vk.Kind) theme.Style {
    return vk.segStyle(.{ .text = "", .kind = kind }, bg);
}

fn inner(box: Rect) Rect {
    return box.inset(2, 1);
}

fn dim(win: vaxis.Window, x: u16, y: u16, w: u16, text: []const u8) void {
    _ = draw.text(win, x, y, w, text, .{ .fg = theme.bone_faint, .bg = bg });
}

/// A short note in the middle of a panel that has nothing to draw yet.
fn note(v: *const View, r: Rect, text: []const u8) void {
    if (r.w == 0 or r.h == 0) return;
    const w = v.win.gwidth(text);
    const x: u16 = r.x + (if (r.w > w) (r.w - w) / 2 else 0);
    dim(v.win, x, r.y + r.h / 2, r.w, text);
}

fn dayMonth(a: Allocator, day: i32) []const u8 {
    var b: [16]u8 = undefined;
    return a.dupe(u8, dates.formatDayMonth(&b, day)) catch "?";
}

fn niceMax(x: f64) f64 {
    const steps = [_]f64{ 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30, 40, 50, 60, 80, 100, 120 };
    for (steps) |s| if (x <= s) return s;
    return @ceil(x / 10) * 10;
}

fn hours(secs: i64) f64 {
    return stats.secsToHours(secs);
}

const day_max_label = "{d:.0}h";

// ---- panels: frame and row layout ---------------------------------------------------------------------------

const Panel = struct {
    title: []const u8,
    draw: *const fn (*const View, Rect) void,
    min_w: u16 = 32,
    /// shown on the title bar, right-aligned, when it fits
    legend: []const vk.Seg = &.{},
};

const RowSpec = struct {
    min_h: u16,
    grow: bool = true,
    panels: []const Panel,
};

fn drawPanel(v: *const View, box: Rect, p: Panel) void {
    if (box.w < 8 or box.h < 4) return;
    draw.box(v.win, box, theme.line, bg, false, false);
    const title = f(v.a, " {s} ", .{p.title});
    const tw = draw.text(v.win, box.x + 2, box.y, box.w -| 4, title, .{ .fg = theme.bone_dim, .bg = bg, .bold = true });
    if (p.legend.len > 0) {
        var total: u16 = 0;
        for (p.legend, 0..) |s, i| total += v.win.gwidth(s.text) + @as(u16, if (i + 1 < p.legend.len) 2 else 0);
        const needed = total + 2;
        if (box.w >= tw + 6 + needed) {
            var x = box.x + box.w - 2 - total - 1;
            _ = draw.text(v.win, x - 1, box.y, 1, " ", .{ .fg = theme.bone, .bg = bg });
            for (p.legend) |s| {
                x += draw.text(v.win, x, box.y, box.x + box.w - x, s.text, vk.segStyle(s, bg)) + 2;
            }
        }
    }
    p.draw(v, box);
}

/// Stack rows of panels into `area`. A row that doesn't fit is dropped; so are panels
/// of a row that don't fit beside each other.
fn renderRows(v: *const View, area: Rect, rows: []const RowSpec) void {
    var used: u16 = 0;
    var n: usize = 0;
    for (rows) |rs| {
        if (used + rs.min_h > area.h) break;
        used += rs.min_h;
        n += 1;
    }
    if (n == 0) return;

    var grow_n: u16 = 0;
    for (rows[0..n]) |rs| {
        if (rs.grow) grow_n += 1;
    }
    var extra: u16 = area.h - used;
    var y = area.y;
    for (rows[0..n]) |rs| {
        var h = rs.min_h;
        if (rs.grow and grow_n > 0) {
            const share = extra / grow_n;
            h += share;
            extra -= share;
            grow_n -= 1;
        }
        // how many panels fit side by side (1 column gap between them)
        var count: u16 = 0;
        var w_needed: u16 = 0;
        for (rs.panels) |p| {
            const add: u16 = p.min_w + (if (count > 0) @as(u16, 1) else 0);
            if (w_needed + add > area.w and count > 0) break;
            w_needed += add;
            count += 1;
        }
        if (count > 0) {
            const gaps: u16 = count - 1;
            const pw: u16 = (area.w -| gaps) / count;
            var x = area.x;
            for (rs.panels[0..count], 0..) |p, i| {
                const w: u16 = if (i + 1 == count) area.x + area.w - x else pw;
                drawPanel(v, .{ .x = x, .y = y, .w = w, .h = h }, p);
                x += w + 1;
            }
        }
        y += h;
    }
}

// ---- KPI cards ---------------------------------------------------------------------------------------------------

const card_h: u16 = 5;

const Card = struct {
    title: []const u8,
    value: []const u8,
    kind: vk.Kind = .value,
    /// small dim text at the right of the value
    aside: []const u8 = "",
    sub: vk.Line = &.{},
    gauge: ?f64 = null,
    gauge_color: theme.Color = theme.bone,
    spark: ?[]const u8 = null,
};

fn kindColor(k: vk.Kind) theme.Color {
    return vk.segStyle(.{ .text = "", .kind = k }, bg).fg;
}

fn buildCards(v: *const View, spark_w: usize) [6]Card {
    const a = v.a;
    const compact = spark_w < 18; // card too narrow for the long wording
    var out: [6]Card = undefined;
    const p = v.data.params;

    // 1. focus time against the weekly goal
    const frac = if (v.goal > 0) v.cur.hours() / v.goal else 0;
    out[0] = .{
        .title = if (compact) f(a, "FOCUS {d}h", .{p.goal_hours}) else f(a, "FOCUS · GOAL {d}h", .{p.goal_hours}),
        .value = vk.hm(a, v.cur.total),
        .kind = if (frac >= 1) .good else .value,
        .aside = vk.percentText(a, @min(frac, 9.99)),
        .sub = if (v.cmp.has_prev) segs(a, &.{ vk.deltaSeg(a, v.cmp.hours), .{ .text = if (compact) "" else " vs last wk", .kind = .dim } }) else segs(a, &.{.{ .text = "first week of the log", .kind = .dim }}),
        .gauge = frac,
        .gauge_color = if (frac >= 1) theme.ok else theme.bone,
    };

    // 2. tasks finished, with the last few weeks as a sparkline
    var done_vals: [26]f64 = undefined;
    const nv = @min(v.recent.len, @min(done_vals.len, spark_w));
    for (v.recent[v.recent.len - nv ..], 0..) |w, i| done_vals[i] = @floatFromInt(w.done_total);
    out[1] = .{
        .title = if (compact) "DONE" else "TASKS DONE · WEEK",
        .value = f(a, "{d}", .{v.cur.done_total}),
        .aside = if (compact) "" else f(a, "{d}/{d} days active", .{ v.cur.active_days, @max(v.cur.days_counted, 1) }),
        .sub = if (v.cmp.has_prev) segs(a, &.{ vk.deltaSeg(a, v.cmp.done), .{ .text = if (compact) "" else " vs last wk", .kind = .dim } }) else segs(a, &.{.{ .text = "first week of the log", .kind = .dim }}),
        .spark = charts.spark(a, done_vals[0..nv], 0),
    };

    // 3. streak
    const s = v.streak;
    out[2] = .{
        .title = "STREAK",
        .value = if (s.current > 0) f(a, "{d} {s}", .{ s.current, if (s.current == 1) "day" else "days" }) else "none",
        .kind = if (s.current > 0) .good else .bad,
        .aside = if (compact) "" else "→ 7d",
        .sub = segs(a, &.{
            .{ .text = f(a, "best {d}", .{s.longest}), .kind = .label },
            .{ .text = if (compact) "" else f(a, " · active {s}", .{vk.percentText(a, @as(f64, @floatFromInt(s.active_days)) / @as(f64, @floatFromInt(@max(s.total_days, 1))))}), .kind = .dim },
        }),
        .gauge = @as(f64, @floatFromInt(@min(s.current, 7))) / 7.0,
        .gauge_color = theme.ok,
    };

    // 4. chance of reaching the goal
    const seed: u64 = @as(u64, @intCast(@max(dates.weekStart(v.l.today), 0))) *% 0x9E3779B97F4A7C15;
    const proj = stats.projectWeek(a, v.l, v.complete, v.goal, seed) catch null;
    if (v.cur.hours() >= v.goal) {
        out[3] = .{ .title = "GOAL ODDS", .value = "reached ✓", .kind = .good, .sub = segs(a, &.{.{ .text = f(a, "{s} above the goal", .{vk.hmHours(a, v.cur.hours() - v.goal)}), .kind = .dim }}), .gauge = 1, .gauge_color = theme.ok };
    } else if (proj) |pr| {
        const kind = vk.probKind(pr.p_goal);
        out[3] = .{
            .title = "GOAL ODDS",
            .value = vk.probText(a, pr.p_goal),
            .kind = kind,
            .sub = segs(a, &.{ .{ .text = if (compact) "~" else "likely ", .kind = .dim }, .{ .text = vk.hmHours(a, pr.p50), .kind = .value }, .{ .text = if (compact) "" else " by Sunday", .kind = .dim } }),
            .gauge = pr.p_goal,
            .gauge_color = kindColor(kind),
        };
    } else {
        out[3] = .{ .title = "GOAL ODDS", .value = "–", .kind = .dim, .sub = segs(a, &.{.{ .text = if (compact) "needs history" else "needs 2 full weeks", .kind = .dim }}) };
    }

    // 5. backlog and how fast it shrinks
    const open = v.snap.nOpen();
    var bbuf: [26]f64 = undefined;
    const bk = stats.backlog(v.complete, p.alpha(), open, &bbuf);
    var eta: vk.Line = segs(a, &.{.{ .text = "needs 2 full weeks", .kind = .dim }});
    if (bk) |b| {
        if (b.weeks) |wk| {
            eta = segs(a, &.{ .{ .text = f(a, "≈{d:.1} wks", .{wk}), .kind = .value }, .{ .text = if (compact) "" else f(a, " · {d:.1}/wk", .{b.per_week}), .kind = .dim } });
        } else if (open == 0) {
            eta = segs(a, &.{.{ .text = "nothing left to do", .kind = .good }});
        } else eta = segs(a, &.{.{ .text = if (compact) "no pace yet" else "no finished tasks lately", .kind = .dim }});
    }
    const comp = v.snap.completion();
    out[4] = .{
        .title = "BACKLOG",
        .value = f(a, "{d} open", .{open}),
        .aside = if (comp != null and !compact) f(a, "{s} done", .{vk.percentText(a, comp.?)}) else "",
        .sub = eta,
        .gauge = comp orelse 0,
        .gauge_color = theme.ok,
    };

    // 6. deadlines
    const sn = v.snap;
    out[5] = .{
        .title = "DEADLINES",
        .value = if (sn.overdue > 0) f(a, "{d} overdue", .{sn.overdue}) else if (compact) "none late" else "none overdue",
        .kind = if (sn.overdue > 0) .bad else .good,
        .sub = segs(a, &.{
            .{ .text = f(a, "{d} due ≤2d", .{sn.due_soon}), .kind = if (sn.due_soon > 0) .warn else .dim },
            .{ .text = if (compact) "" else f(a, " · {d} this wk", .{sn.due_week}), .kind = .dim },
        }),
    };
    return out;
}

fn drawCard(v: *const View, r: Rect, c: Card) void {
    if (r.w < 12 or r.h < card_h) return;
    const win = v.win;
    draw.box(win, r, theme.line, bg, false, false);
    _ = draw.text(win, r.x + 2, r.y, r.w -| 4, f(v.a, " {s} ", .{c.title}), .{ .fg = theme.bone_dim, .bg = bg, .bold = true });
    const x = r.x + 2;
    const w = r.w - 4;
    var vs = vk.segStyle(.{ .text = "", .kind = c.kind }, bg);
    vs.bold = true;
    const vw = draw.text(win, x, r.y + 1, w, c.value, vs);
    if (c.aside.len > 0 and vw + 2 + win.gwidth(c.aside) <= w) {
        _ = draw.textRight(win, x + w, r.y + 1, c.aside, .{ .fg = theme.bone_faint, .bg = bg });
    }
    vk.drawLine(win, x, r.y + 2, w, c.sub, bg);
    if (c.gauge) |g| charts.gauge(win, .{ .x = x, .y = r.y + 3, .w = w, .h = 1 }, g, c.gauge_color);
    if (c.spark) |sp| draw.raw(win, x, r.y + 3, w, sp, .{ .fg = theme.ok, .bg = bg });
}

fn renderCards(v: *const View, area: Rect) u16 {
    if (area.h < card_h or area.w < 12) return 0;
    const cols: u16 = if (area.w >= 101) 6 else if (area.w >= 63) 3 else if (area.w >= 42) 2 else 1;
    var rows: u16 = (6 + cols - 1) / cols;
    // keep at least 9 rows for the charts below, but always show one row of cards
    while (rows > 1 and rows * card_h + 9 > area.h) rows -= 1;
    const shown: usize = @min(6, @as(usize, cols) * rows);
    const cw: u16 = (area.w - (cols - 1)) / cols;
    const cards = buildCards(v, @max(cw, 4) - 4);
    for (cards[0..shown], 0..) |c, i| {
        const col: u16 = @intCast(i % cols);
        const row: u16 = @intCast(i / cols);
        const x = area.x + col * (cw + 1);
        const w: u16 = if (col == cols - 1) area.x + area.w - x else cw;
        drawCard(v, .{ .x = x, .y = area.y + row * card_h, .w = w, .h = card_h }, c);
    }
    return rows * card_h;
}

// ---- panels: Dashboard -----------------------------------------------------------------------------------------

fn panelDaily(v: *const View, box: Rect) void {
    const r = inner(box);
    if (r.w < 21 or r.h < 4) return;
    var cols: [7]charts.Column = undefined;
    var mx: f64 = 1;
    const wide = r.w / 7 >= 5;
    for (0..7) |i| {
        const day = v.cur.start_day + @as(i32, @intCast(i));
        const future = day > v.l.today;
        const h = if (future) 0 else hours(v.cur.secs[i]);
        const ref = hours(v.prev.secs[i]);
        mx = @max(mx, @max(h, ref));
        const is_today = day == v.l.today;
        cols[i] = .{
            .value = h,
            .color = if (is_today) theme.bone else theme.fade(theme.bone, 62),
            .label = if (r.w / 7 >= 5) dates.weekday_names[i] else dates.weekday_names[i][0..2],
            .top = if (wide and h > 0) f(v.a, "{d:.1}", .{h}) else "",
            .ref = if (v.cmp.has_prev or ref > 0) ref else null,
            .bold_label = is_today,
        };
    }
    const m = niceMax(mx);
    charts.columns(v.win, r, bg, &cols, .{ .max = m, .y_top = f(v.a, day_max_label, .{m}) });
}

fn panelTrend(v: *const View, box: Rect) void {
    const r = inner(box);
    if (r.w < 22 or r.h < 5 or v.recent.len == 0) return;
    const vals = v.a.alloc(f64, v.recent.len) catch return;
    var mx: f64 = @max(v.goal, 1);
    for (v.recent, 0..) |w, i| {
        vals[i] = w.hours();
        mx = @max(mx, vals[i]);
    }
    var fbuf: [26]f64 = undefined;
    var next: ?charts.Next = null;
    if (stats.forecastNextWeek(v.complete, v.data.params.alpha(), &fbuf)) |fc| {
        next = .{ .value = fc.next, .lo = fc.lo, .hi = fc.hi };
        mx = @max(mx, fc.hi orelse fc.next);
    }
    const m = niceMax(mx);
    charts.line(v.win, v.a, r, bg, vals, .{
        .max = m,
        .color = theme.bone,
        .goal = v.goal,
        .next = next,
        .y_top = f(v.a, day_max_label, .{m}),
        .x_left = dayMonth(v.a, v.recent[0].start_day),
        .x_right = if (next != null) "next wk" else "now",
    });
}

const prio_names = [4][]const u8{ "P1", "P2", "P3", "P4" };

fn panelPriority(v: *const View, box: Rect) void {
    const r = inner(box);
    if (r.w < 16 or r.h < 4 or v.recent.len == 0) return;
    const t0 = v.l.tz.dayStart(v.recent[0].start_day);
    const secs = stats.timeByPriority(v.l, t0, v.data.now + 1);
    var total: i64 = 0;
    for (secs) |s| total += s;
    if (total <= 0) return note(v, r, "no tracked time yet");

    // donut on the left (a ring of dots is square when the cell box is twice as wide as tall)
    var legend_x = r.x;
    if (r.w >= 28 and r.h >= 5) {
        const dh: u16 = @min(r.h, (r.w * 9 / 20) / 2);
        const dw: u16 = dh * 2;
        const dr: Rect = .{ .x = r.x, .y = r.y + (r.h - dh) / 2, .w = dw, .h = dh };
        var parts: [4]charts.Part = undefined;
        for (secs, 0..) |s, i| parts[i] = .{ .value = @floatFromInt(s), .color = theme.priorityColor(@intCast(i + 1)) };
        charts.donut(v.win, v.a, dr, bg, &parts, 0.62);
        const ctr = vk.hm(v.a, total);
        const cw = v.win.gwidth(ctr);
        if (dw >= cw + 10 and dh >= 3) _ = draw.text(v.win, dr.x + (dw - cw) / 2, dr.y + dh / 2, cw, ctr, .{ .fg = theme.bone, .bg = bg, .bold = true });
        legend_x = r.x + dw + 2;
    }
    const lw: u16 = r.x + r.w - legend_x;
    const first_y = r.y + (r.h -| 5) / 2;
    dim(v.win, legend_x, first_y, lw, f(v.a, "last {d} weeks", .{v.recent.len}));
    for (secs, 0..) |s, i| {
        const y = first_y + 1 + @as(u16, @intCast(i));
        if (y >= r.y + r.h) break;
        vk.drawLine(v.win, legend_x, y, lw, &.{
            .{ .text = "● ", .color = theme.priorityColor(@intCast(i + 1)) },
            .{ .text = prio_names[i], .color = theme.priorityColor(@intCast(i + 1)) },
            .{ .text = f(v.a, "  {s:<8}", .{vk.hm(v.a, s)}), .kind = .value },
            .{ .text = vk.percentText(v.a, @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(total))), .kind = .dim },
        }, bg);
    }
}

fn panelStatus(v: *const View, box: Rect) void {
    const r = inner(box);
    if (r.w < 20 or r.h < 3) return;
    const sn = v.snap;
    if (sn.nTotal() == 0) return note(v, r, "the board is empty");
    const c_back = theme.line_focus;
    const c_doing = theme.p3;
    const c_done = theme.ok;
    const parts = [_]charts.Part{
        .{ .value = @floatFromInt(sn.nBacklog()), .color = c_back },
        .{ .value = @floatFromInt(sn.nDoing()), .color = c_doing },
        .{ .value = @floatFromInt(sn.nDone()), .color = c_done },
    };
    charts.stacked(v.win, .{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, bg, &parts);
    const names = [3][]const u8{ "backlog", "in progress", "done" };
    const counts = [3]u32{ sn.nBacklog(), sn.nDoing(), sn.nDone() };
    const colors = [3]theme.Color{ c_back, c_doing, c_done };
    var y = r.y + 2;
    for (0..3) |i| {
        if (y >= r.y + r.h) return;
        vk.drawLine(v.win, r.x, y, r.w, &.{
            .{ .text = "■ ", .color = colors[i] },
            .{ .text = f(v.a, "{s:<12}", .{names[i]}), .kind = .label },
            .{ .text = f(v.a, "{d:>3}", .{counts[i]}), .kind = .value },
            .{ .text = f(v.a, "  {s}", .{vk.percentText(v.a, @as(f64, @floatFromInt(counts[i])) / @as(f64, @floatFromInt(sn.nTotal())))}), .kind = .dim },
        }, bg);
        y += 1;
    }
    // open tasks per priority
    if (r.y + r.h >= y + 5) {
        y += 1;
        var rows: [4]charts.HBar = undefined;
        var mx: f64 = 1;
        for (0..4) |i| {
            const n = sn.backlog[i] + sn.doing[i];
            mx = @max(mx, @as(f64, @floatFromInt(n)));
            rows[i] = .{ .label = prio_names[i], .value = @floatFromInt(n), .color = theme.priorityColor(@intCast(i + 1)), .text = f(v.a, "{d}", .{n}), .label_color = theme.priorityColor(@intCast(i + 1)) };
        }
        dim(v.win, r.x, y - 1, r.w, "open by priority");
        charts.hbars(v.win, .{ .x = r.x, .y = y, .w = r.w, .h = @min(4, r.y + r.h - y) }, bg, &rows, mx, 2, 3, 1);
    }
}

fn panelHours(v: *const View, box: Rect) void {
    const r = inner(box);
    if (r.w < 29 or r.h < 4) return;
    const hist = stats.hourHistogram(v.l, v.data.params.window_weeks);
    var peak: f64 = 0;
    var peak_i: usize = 0;
    for (hist, 0..) |x, i| if (x > peak) {
        peak = x;
        peak_i = i;
    };
    if (peak <= 0) return note(v, r, "no tracked time yet");
    var cols: [24]charts.Column = undefined;
    const labels = [24][]const u8{ "0", "", "", "", "", "", "6", "", "", "", "", "", "12", "", "", "", "", "", "18", "", "", "", "", "" };
    for (hist, 0..) |x, i| cols[i] = .{ .value = x, .color = if (i == peak_i) theme.ok else theme.fade(theme.bone, 62), .label = labels[i] };
    charts.columns(v.win, r, bg, &cols, .{ .max = peak, .y_top = f(v.a, "{d:.1}h", .{peak}), .label_left = true });
}

fn panelWeekday(v: *const View, box: Rect) void {
    const r = inner(box);
    if (r.w < 18 or r.h < 3) return;
    if (v.complete.len == 0) return note(v, r, "needs one full week");
    const avg = stats.weekdayAverages(v.complete);
    var best: usize = 0;
    var mx: f64 = 0;
    for (avg, 0..) |x, i| if (x > mx) {
        mx = x;
        best = i;
    };
    var rows: [7]charts.HBar = undefined;
    for (avg, 0..) |x, i| {
        const is_best = i == best and mx > 0;
        rows[i] = .{
            .label = dates.weekday_names[i],
            .value = x,
            .color = if (is_best) theme.ok else theme.fade(theme.bone, 62),
            .text = f(v.a, "{d:.1}h", .{x}),
            .label_color = if (is_best) theme.ok else theme.bone_dim,
        };
    }
    const step: u16 = if (r.h >= 14) 2 else 1;
    charts.hbars(v.win, r, bg, &rows, mx, 3, 5, step);
}

// ---- panels: Trends ----------------------------------------------------------------------------------------------

fn panelHeat(v: *const View, box: Rect) void {
    const r = inner(box);
    if (r.w < 20 or r.h < 8 or v.heat.len == 0) return;
    // right-hand summary when there is room, otherwise the grid takes everything
    const summary_w: u16 = 30;
    const with_summary = r.w >= 4 + 2 * 12 + summary_w + 2;
    const grid_w: u16 = if (with_summary) r.w - summary_w - 2 else r.w;
    const fit: usize = (grid_w - 4) / 2;

    // start at the week the log began (but show at least 12 weeks), at most what fits
    const first_week = dates.weekStart(v.l.first_day);
    const since: usize = @intCast(@divFloor(dates.weekStart(v.l.today) - first_week, 7) + 1);
    const n: usize = @min(v.heat.len, @min(fit, @max(since, 12)));
    const weeks = v.heat[v.heat.len - n ..];

    const vals = v.a.alloc([7]?f64, n) catch return;
    const labels = v.a.alloc([]const u8, n) catch return;
    var mx: f64 = 1;
    for (weeks, 0..) |w, wi| {
        const c = dates.civilFromDays(w.start_day);
        labels[wi] = if (c.d <= 7) dates.month_names[c.m - 1] else "";
        for (0..7) |d| {
            const day = w.start_day + @as(i32, @intCast(d));
            if (day > v.l.today or day < v.l.first_day) {
                vals[wi][d] = null;
            } else {
                vals[wi][d] = hours(w.secs[d]);
                mx = @max(mx, hours(w.secs[d]));
            }
        }
    }
    charts.heatmap(v.win, .{ .x = r.x, .y = r.y, .w = grid_w, .h = 8 }, bg, vals, labels, mx, .{ .week = n - 1, .day = dates.weekdayIndex(v.l.today) });

    // legend under the grid
    if (r.h >= 9) {
        const y = r.y + 8;
        dim(v.win, r.x + 4, y, 5, "less");
        var x = r.x + 9;
        for (0..charts.heat_levels) |lvl| {
            _ = draw.text(v.win, x, y, 1, "■", .{ .fg = charts.heatColor(lvl), .bg = bg });
            x += 2;
        }
        dim(v.win, x, y, 24, f(v.a, "more  (≤{s}/day)", .{vk.hmHours(v.a, mx)}));
    }

    if (with_summary) {
        const sx = r.x + grid_w + 2;
        var best_day: i64 = 0;
        var best_day_idx: i32 = v.l.today;
        var d = v.l.first_day;
        while (d <= v.l.today) : (d += 1) {
            const sc = v.l.secsOn(d);
            if (sc > best_day) {
                best_day = sc;
                best_day_idx = d;
            }
        }
        var best_week: i64 = 0;
        var best_week_start: i32 = v.cur.start_day;
        for (v.heat) |w| if (w.total > best_week) {
            best_week = w.total;
            best_week_start = w.start_day;
        };
        const s = v.streak;
        var y = r.y + 1;
        const rows = [_]vk.Line{
            &.{.{ .text = "SUMMARY", .kind = .head }},
            &.{ .{ .text = "active days  ", .kind = .label }, .{ .text = f(v.a, "{d} of {d}", .{ s.active_days, s.total_days }), .kind = .value } },
            &.{ .{ .text = "streak       ", .kind = .label }, .{ .text = f(v.a, "{d} now · {d} best", .{ s.current, s.longest }), .kind = .value } },
            &.{ .{ .text = "best day     ", .kind = .label }, .{ .text = if (best_day > 0) f(v.a, "{s} · {s}", .{ vk.hm(v.a, best_day), dayMonth(v.a, best_day_idx) }) else "–", .kind = .value } },
            &.{ .{ .text = "best week    ", .kind = .label }, .{ .text = if (best_week > 0) f(v.a, "{s} · {s}", .{ vk.hm(v.a, best_week), dayMonth(v.a, best_week_start) }) else "–", .kind = .value } },
            &.{ .{ .text = "tasks done   ", .kind = .label }, .{ .text = f(v.a, "{d} total", .{v.l.completions.len}), .kind = .value } },
        };
        for (rows) |line| {
            if (y >= r.y + r.h) break;
            vk.drawLine(v.win, sx, y, summary_w, line, bg);
            y += 1;
        }
    }
}

fn weekLabel(v: *const View, i: usize, step: usize) []const u8 {
    if (i % step != 0) return "";
    return dayMonth(v.a, v.recent[i].start_day);
}

fn panelDoneWeekly(v: *const View, box: Rect) void {
    const r = inner(box);
    const n = v.recent.len;
    if (r.w < 20 or r.h < 4 or n == 0) return;
    const cols = v.a.alloc(charts.Column, n) catch return;
    var mx: f64 = 1;
    for (v.recent) |w| mx = @max(mx, @as(f64, @floatFromInt(w.done_total)));
    const m = niceMax(mx);
    const slot: usize = @max((r.w -| 4) / n, 1);
    const step: usize = @max((7 + slot - 1) / slot, 1); // labels are ~6 wide
    for (v.recent, 0..) |w, i| {
        const is_cur = i + 1 == n;
        cols[i] = .{
            .value = @floatFromInt(w.done_total),
            .color = if (is_cur) theme.bone else theme.ok,
            .label = weekLabel(v, i, step),
            .top = if (slot >= 3 and w.done_total > 0) f(v.a, "{d}", .{w.done_total}) else "",
            .bold_label = is_cur,
        };
    }
    charts.columns(v.win, r, bg, cols, .{ .max = m, .y_top = f(v.a, "{d:.0}", .{m}), .label_left = true });
}

fn panelCumulative(v: *const View, box: Rect) void {
    const r = inner(box);
    if (r.w < 22 or r.h < 5 or v.recent.len == 0) return;
    const cum = stats.cumulativeDone(v.a, v.l, v.recent) catch return;
    var mx: f64 = 1;
    for (cum) |x| mx = @max(mx, x);
    const m = niceMax(mx);
    charts.line(v.win, v.a, r, bg, cum, .{
        .max = m,
        .color = theme.ok,
        .y_top = f(v.a, "{d:.0}", .{m}),
        .x_left = dayMonth(v.a, v.recent[0].start_day),
        .x_right = f(v.a, "{d:.0} tasks", .{cum[cum.len - 1]}),
    });
}

fn panelScatter(v: *const View, box: Rect) void {
    const r = inner(box);
    if (r.w < 22 or r.h < 5 or v.recent.len == 0) return;
    const t0 = v.l.tz.dayStart(v.recent[0].start_day);
    const span: f64 = @floatFromInt(@max(v.data.now - t0, 1));
    var mx: i64 = 0;
    for (v.l.completions) |c| {
        if (c.took > 0 and c.at >= t0) mx = @max(mx, c.took);
    }
    if (mx == 0) return note(v, r, "finish tasks with tracked time");
    var pts: std.ArrayList(charts.Point) = .empty;
    const lmax = @log(1.0 + @as(f64, @floatFromInt(mx)) / 60.0);
    for (v.l.completions) |c| {
        if (c.took <= 0 or c.at < t0) continue;
        const y = @log(1.0 + @as(f64, @floatFromInt(c.took)) / 60.0) / lmax;
        pts.append(v.a, .{ .x = @as(f64, @floatFromInt(c.at - t0)) / span, .y = y, .color = theme.priorityColor(c.priority) }) catch {};
    }
    charts.scatter(v.win, v.a, r, bg, pts.items, vk.hm(v.a, mx), dayMonth(v.a, v.recent[0].start_day), "now");
}

const dur_labels = [stats.dur_buckets][]const u8{ "<15m", "<30m", "<1h", "<2h", "<4h", "4h+" };

fn panelDurHist(v: *const View, box: Rect) void {
    const r = inner(box);
    if (r.w < 24 or r.h < 4) return;
    const h = stats.durationHistogram(v.l);
    var mx: u32 = 0;
    var tot: u32 = 0;
    var mode: usize = 0;
    for (h, 0..) |x, i| {
        tot += x;
        if (x > mx) {
            mx = x;
            mode = i;
        }
    }
    if (tot == 0) return note(v, r, "no finished tasks with tracked time");
    var cols: [stats.dur_buckets]charts.Column = undefined;
    for (h, 0..) |x, i| cols[i] = .{
        .value = @floatFromInt(x),
        .color = if (i == mode) theme.ok else theme.fade(theme.bone, 62),
        .label = dur_labels[i],
        .top = if (x > 0) f(v.a, "{d}", .{x}) else "",
    };
    charts.columns(v.win, r, bg, &cols, .{ .max = niceMax(@floatFromInt(mx)), .y_top = f(v.a, "{d}", .{mx}) });
}

// ---- panels: Board ------------------------------------------------------------------------------------------------

const quad_names = [4][]const u8{ "P1 · DO NOW", "P2 · PLAN", "P3 · DELEGATE", "P4 · DROP" };
const quad_short = [4][]const u8{ "P1 DO", "P2 PLAN", "P3 DELEG", "P4 DROP" };

fn panelMatrix(v: *const View, box: Rect) void {
    const r = inner(box);
    if (r.w < 24 or r.h < 6) return;
    const half_w = (r.w - 1) / 2;
    const half_h = r.h / 2;
    for (0..4) |i| {
        const col: u16 = @intCast(i % 2);
        const row: u16 = @intCast(i / 2);
        const q: Rect = .{
            .x = r.x + col * (half_w + 1),
            .y = r.y + row * half_h,
            .w = if (col == 1) r.x + r.w - (r.x + half_w + 1) else half_w,
            .h = if (row == 1) r.y + r.h - (r.y + half_h) else half_h,
        };
        const pc = theme.priorityColor(@intCast(i + 1));
        draw.box(v.win, q, theme.fade(pc, 75), bg, false, false);
        _ = draw.text(v.win, q.x + 2, q.y, q.w -| 3, f(v.a, " {s} ", .{if (q.w >= 20) quad_names[i] else quad_short[i]}), .{ .fg = pc, .bg = bg, .bold = true });
        const inn = q.inset(2, 1);
        if (inn.w == 0 or inn.h == 0) continue;
        const n = v.snap.backlog[i];
        var cs = style(.value);
        cs.bold = true;
        cs.fg = if (n > 0) pc else theme.bone_faint;
        const vw = draw.text(v.win, inn.x, inn.y, inn.w, f(v.a, "{d}", .{n}), cs);
        dim(v.win, inn.x + vw + 1, inn.y, inn.w -| (vw + 1), "waiting");
        if (inn.h >= 2) dim(v.win, inn.x, inn.y + 1, inn.w, f(v.a, "▸{d}  ✓{d}", .{ v.snap.doing[i], v.snap.done[i] }));
    }
}

fn panelDeadlines(v: *const View, box: Rect) void {
    const r = inner(box);
    if (r.w < 22 or r.h < 5) return;
    const sn = v.snap;
    if (sn.nOpen() == 0) return note(v, r, "no open tasks");
    const labels = [5][]const u8{ "overdue", "≤ 2 days", "3-7 days", "later", "no date" };
    const vals = [5]u32{ sn.overdue, sn.due_soon, sn.due_week, sn.due_later, sn.no_deadline };
    const colors = [5]theme.Color{ theme.p1, theme.p2, theme.p3, theme.ok, theme.bone_faint };
    var mx: f64 = 1;
    var rows: [5]charts.HBar = undefined;
    for (vals, 0..) |x, i| {
        mx = @max(mx, @as(f64, @floatFromInt(x)));
        rows[i] = .{ .label = labels[i], .value = @floatFromInt(x), .color = colors[i], .text = f(v.a, "{d}", .{x}), .label_color = if (i == 0 and x > 0) theme.p1 else theme.bone_dim };
    }
    const step: u16 = if (r.h >= 10) 2 else 1;
    charts.hbars(v.win, r, bg, &rows, mx, 8, 3, step);
}

fn panelRunning(v: *const View, box: Rect) void {
    const r = inner(box);
    if (r.w < 24 or r.h < 2) return;
    // roomy panels keep title, gauge and numbers on one row; narrow ones use two rows per task
    const two_rows = r.w < 46;
    var y = r.y;
    var any = false;
    for (v.data.board.tasks.items) |t| {
        if (t.status != .doing) continue;
        any = true;
        const need: u16 = if (two_rows) 2 else 1;
        if (y + need > r.y + r.h) break;
        const el = model.elapsed(t, v.data.now);
        const typ = stats.typicalDuration(v.a, v.l, t.priority) catch null;
        const pc = theme.priorityColor(t.priority);
        const title_w: u16 = if (two_rows) r.w else @min(r.w / 2, 30);
        _ = draw.text(v.win, r.x, y, 3, f(v.a, "P{d}", .{t.priority}), .{ .fg = pc, .bg = bg, .bold = true });
        _ = draw.text(v.win, r.x + 3, y, title_w -| 3, t.title, .{ .fg = theme.bone, .bg = bg });
        const gy = if (two_rows) y + 1 else y;
        const gx = if (two_rows) r.x + 3 else r.x + title_w + 1;
        const info_w: u16 = 14;
        const right = r.x + r.w;
        if (right > gx + info_w + 4) {
            const gw = right - gx - info_w - 1;
            if (typ) |ty| {
                const elf: f64 = @floatFromInt(el);
                const colr = if (elf <= ty.median) theme.ok else if (elf <= ty.p80) theme.p2 else theme.p1;
                charts.gauge(v.win, .{ .x = gx, .y = gy, .w = gw, .h = 1 }, elf / @max(ty.p80, 1), colr);
                _ = draw.text(v.win, gx + gw + 1, gy, info_w, f(v.a, "{s} / ~{s}", .{ vk.hm(v.a, el), vk.hm(v.a, @intFromFloat(ty.median)) }), .{ .fg = theme.bone_dim, .bg = bg });
            } else {
                _ = draw.text(v.win, gx, gy, right - gx, f(v.a, "{s} so far", .{vk.hm(v.a, el)}), .{ .fg = theme.bone_dim, .bg = bg });
            }
        }
        y += need;
    }
    if (!any) note(v, r, "nothing in progress");
}

fn panelDurPrio(v: *const View, box: Rect) void {
    const r = inner(box);
    if (r.w < 26 or r.h < 4) return;
    var rows: [4]charts.HBar = undefined;
    var mx: f64 = 0;
    var any = false;
    for (0..4) |i| {
        const p: u8 = @intCast(i + 1);
        const d = stats.durations(v.a, v.l, p) catch null;
        if (d) |dd| {
            any = true;
            mx = @max(mx, dd.p80);
            rows[i] = .{ .label = prio_names[i], .value = dd.median, .color = theme.priorityColor(p), .text = f(v.a, "{s} · ≤{s}", .{ vk.hm(v.a, @intFromFloat(dd.median)), vk.hm(v.a, @intFromFloat(dd.p80)) }), .label_color = theme.priorityColor(p) };
        } else {
            rows[i] = .{ .label = prio_names[i], .value = 0, .color = theme.priorityColor(p), .text = "–", .label_color = theme.priorityColor(p) };
        }
    }
    if (!any) return note(v, r, "no finished tasks with tracked time");
    dim(v.win, r.x, r.y, r.w, "typical time · 80% finish within");
    const step: u16 = if (r.h >= 10) 2 else 1;
    charts.hbars(v.win, .{ .x = r.x, .y = r.y + 1, .w = r.w, .h = r.h - 1 }, bg, &rows, mx, 2, 16, step);
}

fn panelDonePrio(v: *const View, box: Rect) void {
    const r = inner(box);
    if (r.w < 20 or r.h < 4 or v.recent.len == 0) return;
    const t0 = v.l.tz.dayStart(v.recent[0].start_day);
    const dn = stats.doneByPriority(v.l, t0, v.data.now + 1);
    var total: u32 = 0;
    for (dn) |x| total += x;
    if (total == 0) return note(v, r, "no finished tasks yet");
    var legend_x = r.x;
    if (r.w >= 26 and r.h >= 5) {
        const dh: u16 = @min(r.h, (r.w * 9 / 20) / 2);
        const dw: u16 = dh * 2;
        const dr: Rect = .{ .x = r.x, .y = r.y + (r.h - dh) / 2, .w = dw, .h = dh };
        var parts: [4]charts.Part = undefined;
        for (dn, 0..) |x, i| parts[i] = .{ .value = @floatFromInt(x), .color = theme.priorityColor(@intCast(i + 1)) };
        charts.donut(v.win, v.a, dr, bg, &parts, 0.62);
        const ctr = f(v.a, "{d}", .{total});
        const cw = v.win.gwidth(ctr);
        if (dw >= cw + 10 and dh >= 3) _ = draw.text(v.win, dr.x + (dw - cw) / 2, dr.y + dh / 2, cw, ctr, .{ .fg = theme.bone, .bg = bg, .bold = true });
        legend_x = r.x + dw + 2;
    }
    const lw: u16 = r.x + r.w - legend_x;
    const first_y = r.y + (r.h -| 5) / 2;
    dim(v.win, legend_x, first_y, lw, f(v.a, "done, last {d} weeks", .{v.recent.len}));
    for (dn, 0..) |x, i| {
        const y = first_y + 1 + @as(u16, @intCast(i));
        if (y >= r.y + r.h) break;
        vk.drawLine(v.win, legend_x, y, lw, &.{
            .{ .text = "● ", .color = theme.priorityColor(@intCast(i + 1)) },
            .{ .text = prio_names[i], .color = theme.priorityColor(@intCast(i + 1)) },
            .{ .text = f(v.a, "  {d:<4}", .{x}), .kind = .value },
            .{ .text = vk.percentText(v.a, @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(total))), .kind = .dim },
        }, bg);
    }
}

// ---- tabs ------------------------------------------------------------------------------------------------------------

const legend_hours = [_]vk.Seg{ .{ .text = "━ last week", .color = theme.p3 } };
const legend_trend = [_]vk.Seg{
    .{ .text = "━ hours", .kind = .plain },
    .{ .text = "┈ goal", .kind = .dim },
    .{ .text = "◦ forecast", .color = theme.p2 },
};
const legend_prio = [_]vk.Seg{
    .{ .text = "● P1", .color = theme.p1 },
    .{ .text = "● P2", .color = theme.p2 },
    .{ .text = "● P3", .color = theme.p3 },
    .{ .text = "● P4", .color = theme.p4 },
};

const dash_rows = [_]RowSpec{
    .{ .min_h = 11, .panels = &.{
        .{ .title = "HOURS PER DAY", .draw = panelDaily, .min_w = 34, .legend = &legend_hours },
        .{ .title = "WEEKLY TREND", .draw = panelTrend, .min_w = 34, .legend = &legend_trend },
        .{ .title = "TIME BY PRIORITY", .draw = panelPriority, .min_w = 34 },
    } },
    .{ .min_h = 10, .panels = &.{
        .{ .title = "BOARD STATUS", .draw = panelStatus, .min_w = 32 },
        .{ .title = "WHEN YOU WORK", .draw = panelHours, .min_w = 34 },
        .{ .title = "WEEKDAY RHYTHM", .draw = panelWeekday, .min_w = 28 },
    } },
};

const trend_rows = [_]RowSpec{
    .{ .min_h = 11, .grow = false, .panels = &.{
        .{ .title = "ACTIVITY · HOURS PER DAY", .draw = panelHeat, .min_w = 40 },
    } },
    .{ .min_h = 9, .panels = &.{
        .{ .title = "WEEKLY HOURS", .draw = panelTrend, .min_w = 34, .legend = &legend_trend },
        .{ .title = "TASKS DONE PER WEEK", .draw = panelDoneWeekly, .min_w = 34 },
        .{ .title = "TASKS DONE · RUNNING TOTAL", .draw = panelCumulative, .min_w = 34 },
    } },
    .{ .min_h = 9, .panels = &.{
        .{ .title = "TASK DURATIONS", .draw = panelScatter, .min_w = 34, .legend = &legend_prio },
        .{ .title = "HOW LONG TASKS TAKE", .draw = panelDurHist, .min_w = 32 },
        .{ .title = "WEEKDAY RHYTHM", .draw = panelWeekday, .min_w = 28 },
    } },
};

const board_rows = [_]RowSpec{
    .{ .min_h = 10, .panels = &.{
        .{ .title = "PRIORITY MATRIX", .draw = panelMatrix, .min_w = 36 },
        .{ .title = "BOARD STATUS", .draw = panelStatus, .min_w = 32 },
        .{ .title = "DEADLINES", .draw = panelDeadlines, .min_w = 30 },
    } },
    .{ .min_h = 9, .panels = &.{
        .{ .title = "IN PROGRESS · VS USUAL PACE", .draw = panelRunning, .min_w = 36 },
        .{ .title = "HOW LONG TASKS TAKE", .draw = panelDurPrio, .min_w = 34 },
        .{ .title = "FINISHED BY PRIORITY", .draw = panelDonePrio, .min_w = 30 },
    } },
};

pub const Tab = enum { dashboard, trends, board };

/// Draw one of the chart tabs inside `area` (the popup's content area).
pub fn render(tab: Tab, win: vaxis.Window, a: Allocator, l: *const Ledger, data: Data, area: Rect) void {
    if (area.w < 20 or area.h < 6) return;
    if (!l.hasData() and data.board.tasks.items.len == 0) {
        const msg = "Nothing logged yet. Add a task, move it to In Progress and finish it: charts build up from there.";
        _ = draw.text(win, area.x, area.y + 1, area.w, msg, .{ .fg = theme.bone_dim, .bg = bg });
        return;
    }
    const v = View.init(win, a, l, data);
    switch (tab) {
        .dashboard => {
            const used = renderCards(&v, area);
            if (area.h > used) renderRows(&v, .{ .x = area.x, .y = area.y + used, .w = area.w, .h = area.h - used }, &dash_rows);
        },
        .trends => renderRows(&v, area, &trend_rows),
        .board => renderRows(&v, area, &board_rows),
    }
}

// ---- tests ------------------------------------------------------------------------------------------------------------------

const testing = std.testing;
const D = dates.daysFromCivil;

fn tsec(day: i32, hour: i64) i64 {
    return @as(i64, day) * 86400 + hour * 3600;
}

/// A believable month of history for the render tests below.
fn fixture(a: Allocator, board: *model.Board, entries: *std.ArrayList(worklog.Entry)) !i64 {
    const now = tsec(D(2026, 10, 14), 15);
    var id: u32 = 0;
    var d: i32 = D(2026, 9, 1);
    while (d < D(2026, 10, 14)) : (d += 1) {
        const wd = dates.weekdayIndex(d);
        if (wd >= 5 and @mod(d, 3) != 0) continue;
        id += 1;
        const prio: u8 = @intCast(1 + @mod(d, 4));
        const start = tsec(d, 8 + @mod(d, 6));
        const len: i64 = (1 + @mod(d, 4)) * 1800;
        try entries.append(a, .{ .session = .{ .id = id, .start = start, .end = start + len, .priority = prio, .title = "work" } });
        if (@mod(d, 2) == 0) try entries.append(a, .{ .done = .{ .id = id, .at = start + len, .took = len, .priority = prio, .title = "work" } });
    }
    _ = try board.add("ship the release", .doing, 1, D(2026, 10, 15), now - 1800);
    _ = try board.add("write the report", .backlog, 2, D(2026, 10, 10), now);
    _ = try board.add("clean the inbox", .backlog, 3, null, now);
    _ = try board.add("learn zig comptime", .backlog, 2, D(2026, 11, 20), now);
    _ = try board.add("old task", .done, 4, null, now);
    return now;
}

fn renderOnce(a: Allocator, tab: Tab, cols: u16, rows: u16) ![]u8 {
    var board = model.Board.init(a);
    var entries: std.ArrayList(worklog.Entry) = .empty;
    const now = try fixture(a, &board, &entries);
    var screen = try vaxis.Screen.init(a, .{ .rows = rows, .cols = cols, .x_pixel = 0, .y_pixel = 0 });
    const win: vaxis.Window = .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = cols, .height = rows, .screen = &screen };
    const data: Data = .{ .entries = entries.items, .board = &board, .params = .{}, .now = now, .tz = .{ .fixed = 0 } };
    const l = try Ledger.build(a, data.tz, now, entries.items, &.{});
    render(tab, win, a, &l, data, .{ .x = 0, .y = 0, .w = cols, .h = rows });
    return charts.dumpScreen(a, &screen);
}

test "every tab renders at every size without crashing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tabs = [_]Tab{ .dashboard, .trends, .board };
    var rows: u16 = 1;
    while (rows <= 60) : (rows += 3) {
        var cols: u16 = 1;
        while (cols <= 220) : (cols += 7) {
            for (tabs) |t| _ = try renderOnce(a, t, cols, rows);
        }
    }
}

test "the dashboard shows its cards and charts on a normal terminal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try renderOnce(a, .dashboard, 106, 38);
    if (debug_dump) std.debug.print("\n{s}\n", .{text});
    for ([_][]const u8{ "FOCUS", "DONE", "STREAK", "GOAL ODDS", "BACKLOG", "DEADLINES", "HOURS PER DAY", "WEEKLY TREND", "TIME BY PRIORITY", "BOARD STATUS", "WHEN YOU WORK" }) |needle| {
        if (std.mem.indexOf(u8, text, needle) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ needle, text });
            return error.TestExpectedEqual;
        }
    }
}

test "trends and board tabs show their charts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try renderOnce(a, .trends, 106, 38);
    if (debug_dump) std.debug.print("\n{s}\n", .{t});
    for ([_][]const u8{ "ACTIVITY", "WEEKLY HOURS", "TASKS DONE PER WEEK", "TASK DURATIONS", "HOW LONG TASKS TAKE" }) |needle| {
        if (std.mem.indexOf(u8, t, needle) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ needle, t });
            return error.TestExpectedEqual;
        }
    }
    const b = try renderOnce(a, .board, 106, 25);
    if (debug_dump) std.debug.print("\n{s}\n", .{b});
    for ([_][]const u8{ "PRIORITY MATRIX", "DEADLINES", "IN PROGRESS", "FINISHED BY PRIORITY", "ship the" }) |needle| {
        if (std.mem.indexOf(u8, b, needle) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ needle, b });
            return error.TestExpectedEqual;
        }
    }
}

/// Flip to true to print every rendered tab while running `zig build test`.
const debug_dump = false;
