//! Statistics over the work log. Pure: no terminal, no I/O, and no hidden clock
//! (the caller passes `now` and a time zone), so every number is unit-testable.
//!
//! The model in one paragraph: the log gives us *sessions* (a task sat in
//! "In Progress" from A to B) and *completions*. From those we build a daily
//! ledger (seconds worked and tasks finished per local day), group it into
//! Monday-based weeks, and answer: how did this week go, how does it compare to
//! last week, how is it likely to end, what is the streak, how long do tasks
//! usually take, and how fast is the backlog shrinking.
const std = @import("std");
const dates = @import("dates.zig");
const worklog = @import("worklog.zig");
const model = @import("model.zig");

pub const Tz = dates.Tz;
pub const Session = worklog.Session;

const day_secs: i64 = 86400;
/// z-score for a two-sided 80% interval
const z80: f64 = 1.2815515655446004;
const sim_count = 4000;
const max_days = 20000;

/// The knobs behind the forecasts. All of them are adjustable in the UI.
pub const Params = struct {
    /// weekly target, in hours
    goal_hours: u8 = 15,
    /// minutes of tracked work for a day to count as "active" (completing a task also counts)
    active_min: u16 = 30,
    /// smoothing of the weekly trend, in percent: higher reacts faster to recent weeks
    alpha_pct: u8 = 40,
    /// how many complete weeks of history the models look at
    window_weeks: u8 = 8,

    pub fn alpha(self: Params) f64 {
        return @as(f64, @floatFromInt(self.alpha_pct)) / 100.0;
    }

    pub fn clamp(self: *Params) void {
        self.goal_hours = std.math.clamp(self.goal_hours, 1, 120);
        self.active_min = std.math.clamp(self.active_min, 5, 600);
        self.alpha_pct = std.math.clamp(self.alpha_pct, 5, 95);
        self.window_weeks = std.math.clamp(self.window_weeks, 2, 26);
    }
};

pub const Completion = struct {
    id: u32,
    at: i64,
    took: i64,
    priority: u8,
    title: []const u8,
    /// multiple-choice questions covered (0 = not a practice task)
    tests: u32 = 0,
};

// ---- the ledger -----------------------------------------------------------------------

pub const Ledger = struct {
    tz: Tz,
    now: i64,
    today: i32,
    /// closed sessions plus the ones still running (clipped at `now`)
    sessions: []const Session,
    /// completions that still count (a later "undone" cancels one), oldest first
    completions: []const Completion,
    /// first local day with any activity; equals `today` for an empty log
    first_day: i32,
    /// seconds worked per local day, index = day - first_day
    secs: []const i64,
    /// completions per local day
    done: []const u16,

    pub fn build(a: std.mem.Allocator, tz: Tz, now: i64, entries: []const worklog.Entry, running: []const Session) !Ledger {
        var sessions: std.ArrayList(Session) = .empty;
        var comps: std.ArrayList(Completion) = .empty;
        var live = std.AutoHashMap(u32, usize).init(a); // task id -> index of its current completion

        for (entries) |e| switch (e) {
            .session => |s| try sessions.append(a, s),
            .done => |d| {
                try comps.append(a, .{ .id = d.id, .at = d.at, .took = d.took, .priority = d.priority, .title = d.title });
                try live.put(d.id, comps.items.len - 1);
            },
            .undone => |u| {
                if (live.fetchRemove(u.id)) |kv| comps.items[kv.value].at = std.math.minInt(i64); // tombstone
            },
            .tests => |t| {
                if (live.get(t.id)) |i| comps.items[i].tests = t.tests;
            },
        };
        for (running) |s| {
            var r = s;
            r.end = @min(r.end, now);
            if (r.end > r.start) try sessions.append(a, r);
        }
        // drop tombstones
        var w: usize = 0;
        for (comps.items) |c| {
            if (c.at == std.math.minInt(i64)) continue;
            comps.items[w] = c;
            w += 1;
        }
        comps.shrinkRetainingCapacity(w);

        const today = tz.dayOf(now);
        var first = today;
        var last = today;
        for (sessions.items) |s| {
            first = @min(first, tz.dayOf(s.start));
            last = @max(last, tz.dayOf(s.end - 1));
        }
        for (comps.items) |c| {
            first = @min(first, tz.dayOf(c.at));
            last = @max(last, tz.dayOf(c.at));
        }
        if (last - first >= max_days) first = last - (max_days - 1);

        const n: usize = @intCast(last - first + 1);
        const secs = try a.alloc(i64, n);
        @memset(secs, 0);
        const done = try a.alloc(u16, n);
        @memset(done, 0);

        for (sessions.items) |s| {
            var d = tz.dayOf(s.start);
            const end_day = tz.dayOf(s.end - 1);
            while (d <= end_day) : (d += 1) {
                if (d < first) continue;
                const lo = @max(s.start, tz.dayStart(d));
                const hi = @min(s.end, tz.dayStart(d + 1));
                if (hi > lo) secs[@intCast(d - first)] += hi - lo;
            }
        }
        for (comps.items) |c| {
            const d = tz.dayOf(c.at);
            if (d < first) continue;
            done[@intCast(d - first)] +|= 1;
        }

        return .{
            .tz = tz,
            .now = now,
            .today = today,
            .sessions = sessions.items,
            .completions = comps.items,
            .first_day = first,
            .secs = secs,
            .done = done,
        };
    }

    pub fn hasData(self: *const Ledger) bool {
        return self.sessions.len > 0 or self.completions.len > 0;
    }

    pub fn secsOn(self: *const Ledger, day: i32) i64 {
        if (day < self.first_day or day > self.today) return 0;
        const i: usize = @intCast(day - self.first_day);
        return if (i < self.secs.len) self.secs[i] else 0;
    }

    pub fn doneOn(self: *const Ledger, day: i32) u16 {
        if (day < self.first_day or day > self.today) return 0;
        const i: usize = @intCast(day - self.first_day);
        return if (i < self.done.len) self.done[i] else 0;
    }

    /// Seconds worked inside the half-open time range [t0, t1).
    pub fn workedBetween(self: *const Ledger, t0: i64, t1: i64) i64 {
        var total: i64 = 0;
        for (self.sessions) |s| {
            const lo = @max(s.start, t0);
            const hi = @min(s.end, t1);
            if (hi > lo) total += hi - lo;
        }
        return total;
    }

    pub fn doneBetween(self: *const Ledger, t0: i64, t1: i64) u32 {
        var n: u32 = 0;
        for (self.completions) |c| {
            if (c.at >= t0 and c.at < t1) n += 1;
        }
        return n;
    }

    pub fn isActive(self: *const Ledger, day: i32, active_secs: i64) bool {
        return self.secsOn(day) >= active_secs or self.doneOn(day) > 0;
    }
};

// ---- weeks -------------------------------------------------------------------------------

pub const Week = struct {
    start_day: i32,
    secs: [7]i64,
    done: [7]u16,
    total: i64,
    done_total: u32,
    active_days: u8,
    /// days of this week that count towards averages: 7 for a finished week,
    /// fewer for the current one, and only those since the log began
    days_counted: u8,

    pub fn hours(self: Week) f64 {
        return secsToHours(self.total);
    }

    pub fn avgPerDayHours(self: Week) f64 {
        if (self.days_counted == 0) return 0;
        return self.hours() / @as(f64, @floatFromInt(self.days_counted));
    }
};

pub fn secsToHours(s: i64) f64 {
    return @as(f64, @floatFromInt(s)) / 3600.0;
}

pub fn week(l: *const Ledger, start_day: i32, active_secs: i64) Week {
    var w: Week = .{
        .start_day = start_day,
        .secs = @splat(0),
        .done = @splat(0),
        .total = 0,
        .done_total = 0,
        .active_days = 0,
        .days_counted = 0,
    };
    for (0..7) |i| {
        const d = start_day + @as(i32, @intCast(i));
        w.secs[i] = l.secsOn(d);
        w.done[i] = l.doneOn(d);
        w.total += w.secs[i];
        w.done_total += w.done[i];
        if (l.isActive(d, active_secs)) w.active_days += 1;
    }
    const from = @max(start_day, l.first_day);
    const to = @min(start_day + 6, l.today);
    if (to >= from) w.days_counted = @intCast(to - from + 1);
    return w;
}

/// One before/after pair, with the percentage change when it means something.
pub const Delta = struct {
    cur: f64,
    prev: f64,

    pub fn pct(self: Delta) ?f64 {
        if (self.prev <= 0) return null;
        return (self.cur - self.prev) / self.prev * 100.0;
    }
};

pub const Comparison = struct {
    /// false when the log doesn't reach back to the previous week
    has_prev: bool,
    /// true when `cur` is the week in progress: totals are then compared with the
    /// previous week at the same point in time, not with its full total
    aligned: bool,
    hours: Delta,
    per_day: Delta,
    done: Delta,
};

pub fn compare(l: *const Ledger, cur: Week, active_secs: i64) Comparison {
    const prev_start = cur.start_day - 7;
    const prev = week(l, prev_start, active_secs);
    const has_prev = prev_start + 6 >= l.first_day;
    const this_week = dates.weekStart(l.today) == cur.start_day;

    var c: Comparison = .{
        .has_prev = has_prev,
        .aligned = this_week,
        .hours = .{ .cur = cur.hours(), .prev = prev.hours() },
        .per_day = .{ .cur = cur.avgPerDayHours(), .prev = prev.avgPerDayHours() },
        .done = .{ .cur = @floatFromInt(cur.done_total), .prev = @floatFromInt(prev.done_total) },
    };
    if (this_week) {
        const t0 = l.tz.dayStart(cur.start_day);
        const elapsed = l.now - t0;
        const p0 = l.tz.dayStart(prev_start);
        c.hours.prev = secsToHours(l.workedBetween(p0, p0 + elapsed));
        c.done.prev = @floatFromInt(l.doneBetween(p0, p0 + elapsed));
    }
    return c;
}

// ---- forecasting ---------------------------------------------------------------------------

/// The last `window` complete weeks, oldest first. A week is complete when it is
/// over and the log already existed on its Monday.
pub fn completeWeeks(a: std.mem.Allocator, l: *const Ledger, window: u8, active_secs: i64) ![]Week {
    var first_full = dates.weekStart(l.first_day);
    if (first_full < l.first_day) first_full += 7;
    const current = dates.weekStart(l.today);

    var list: std.ArrayList(Week) = .empty;
    var w = first_full;
    while (w < current) : (w += 7) try list.append(a, week(l, w, active_secs));
    const all = list.items;
    return if (all.len > window) all[all.len - window ..] else all;
}

pub const Ewma = struct {
    level: f64,
    /// std dev of one-step-ahead errors; needs at least three points
    sigma: ?f64,
    /// least-squares slope per step; needs at least three points
    slope: ?f64,
};

/// Exponentially weighted moving average of a series (oldest first), with the
/// spread of its one-step-ahead forecast errors. Needs at least two points.
pub fn ewma(series: []const f64, alpha: f64) ?Ewma {
    if (series.len < 2) return null;
    var level = series[0];
    var sq: f64 = 0;
    for (series[1..]) |x| {
        const err = x - level;
        sq += err * err;
        level = alpha * x + (1 - alpha) * level;
    }
    var out: Ewma = .{ .level = level, .sigma = null, .slope = null };
    if (series.len >= 3) {
        out.sigma = @sqrt(sq / @as(f64, @floatFromInt(series.len - 1)));
        // least squares: slope = cov(i, x) / var(i)
        const n: f64 = @floatFromInt(series.len);
        var mean_x: f64 = 0;
        for (series) |x| mean_x += x;
        mean_x /= n;
        const mean_i = (n - 1) / 2;
        var num: f64 = 0;
        var den: f64 = 0;
        for (series, 0..) |x, i| {
            const di = @as(f64, @floatFromInt(i)) - mean_i;
            num += di * (x - mean_x);
            den += di * di;
        }
        out.slope = num / den;
    }
    return out;
}

pub const WeekForecast = struct {
    /// complete weeks the model is built on
    n: usize,
    /// expected hours next week
    next: f64,
    /// 80% interval for next week (hours), when there's enough history
    lo: ?f64,
    hi: ?f64,
    /// hours gained (or lost) per week, least-squares trend
    slope: ?f64,
};

pub fn forecastNextWeek(weeks: []const Week, alpha: f64, buf: []f64) ?WeekForecast {
    const n = @min(weeks.len, buf.len);
    for (weeks[weeks.len - n ..], 0..) |w, i| buf[i] = w.hours();
    const e = ewma(buf[0..n], alpha) orelse return null;
    var f: WeekForecast = .{ .n = n, .next = e.level, .lo = null, .hi = null, .slope = e.slope };
    if (e.sigma) |s| {
        f.lo = @max(0, e.level - z80 * s);
        f.hi = e.level + z80 * s;
    }
    return f;
}

pub const Projection = struct {
    /// hours already worked this week (today included)
    so_far: f64,
    /// 10th / 50th / 90th percentile of the simulated final total, in hours
    p10: f64,
    p50: f64,
    p90: f64,
    /// probability that the final total reaches the weekly goal
    p_goal: f64,
};

fn percentile(sorted: []const f64, q: f64) f64 {
    const idx = std.math.clamp(q, 0, 1) * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(idx));
    const hi: usize = @min(lo + 1, sorted.len - 1);
    const frac = idx - @as(f64, @floatFromInt(lo));
    return sorted[lo] * (1 - frac) + sorted[hi] * frac;
}

/// Monte Carlo projection of how this week will end. For every remaining day
/// (and the rest of today) we resample what you did on that weekday in recent
/// weeks, with a little noise so a handful of samples still gives a smooth
/// spread, and add it to what's already done. The result is a distribution.
pub fn projectWeek(a: std.mem.Allocator, l: *const Ledger, weeks: []const Week, goal_hours: f64, seed: u64) !?Projection {
    if (weeks.len < 2) return null;

    var per_day: [7]std.ArrayList(f64) = @splat(.empty);
    var all: std.ArrayList(f64) = .empty;
    for (weeks) |w| for (0..7) |d| {
        const h = secsToHours(w.secs[d]);
        try per_day[d].append(a, h);
        try all.append(a, h);
    };
    var mean: f64 = 0;
    for (all.items) |h| mean += h;
    mean /= @floatFromInt(all.items.len);
    var varsum: f64 = 0;
    for (all.items) |h| varsum += (h - mean) * (h - mean);
    const bandwidth = 0.25 * @sqrt(varsum / @as(f64, @floatFromInt(all.items.len)));

    const cur = week(l, dates.weekStart(l.today), 0);
    const today_idx: usize = dates.weekdayIndex(l.today);
    const today_so_far = secsToHours(l.secsOn(l.today));
    const so_far = cur.hours();

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const totals = try a.alloc(f64, sim_count);

    for (totals) |*t| {
        var total = so_far;
        // the rest of today: a typical total for this weekday, but never less than what's done
        const today_samples = if (per_day[today_idx].items.len > 0) per_day[today_idx].items else all.items;
        var tries: u8 = 0;
        while (tries < 12) : (tries += 1) {
            const s = draw(rng, today_samples, bandwidth);
            if (s >= today_so_far) {
                total += s - today_so_far;
                break;
            }
        }
        var d = today_idx + 1;
        while (d < 7) : (d += 1) {
            const samples = if (per_day[d].items.len > 0) per_day[d].items else all.items;
            total += draw(rng, samples, bandwidth);
        }
        t.* = total;
    }
    std.mem.sort(f64, totals, {}, std.sort.asc(f64));

    var hits: usize = 0;
    for (totals) |t| {
        if (t >= goal_hours) hits += 1;
    }
    return .{
        .so_far = so_far,
        .p10 = percentile(totals, 0.10),
        .p50 = percentile(totals, 0.50),
        .p90 = percentile(totals, 0.90),
        .p_goal = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(totals.len)),
    };
}

fn draw(rng: std.Random, samples: []const f64, bandwidth: f64) f64 {
    const base = samples[rng.uintLessThan(usize, samples.len)];
    return @max(0, base + bandwidth * rng.floatNorm(f64));
}

// ---- streaks ---------------------------------------------------------------------------------

pub const Streak = struct {
    /// consecutive active days; if today isn't active yet it counts back from yesterday
    current: u32,
    today_active: bool,
    longest: u32,
    active_days: u32,
    /// days since the log began, today included
    total_days: u32,
    /// P(a day is active | the day before was). Laplace-smoothed Markov estimate.
    p_continue: ?f64,
    /// P(a day is active | the day before wasn't)
    p_restart: ?f64,
    /// how many day-to-day transitions those two estimates rest on
    samples: u32,
};

pub fn streak(l: *const Ledger, active_secs: i64) Streak {
    const today = l.today;
    var s: Streak = .{
        .current = 0,
        .today_active = l.isActive(today, active_secs),
        .longest = 0,
        .active_days = 0,
        .total_days = @intCast(today - l.first_day + 1),
        .p_continue = null,
        .p_restart = null,
        .samples = 0,
    };

    var run: u32 = 0;
    var d = l.first_day;
    while (d <= today) : (d += 1) {
        if (l.isActive(d, active_secs)) {
            run += 1;
            s.active_days += 1;
            s.longest = @max(s.longest, run);
        } else run = 0;
    }

    // current: walk back from today, or from yesterday while today is still open
    var cur = if (s.today_active) today else today - 1;
    while (cur >= l.first_day and l.isActive(cur, active_secs)) : (cur -= 1) s.current += 1;

    // Markov transitions over finished days only (today is still in progress)
    var aa: u32 = 0;
    var ai: u32 = 0;
    var ia: u32 = 0;
    var ii: u32 = 0;
    d = l.first_day + 1;
    while (d < today) : (d += 1) {
        const before = l.isActive(d - 1, active_secs);
        const now_active = l.isActive(d, active_secs);
        if (before) {
            if (now_active) aa += 1 else ai += 1;
        } else {
            if (now_active) ia += 1 else ii += 1;
        }
    }
    s.samples = aa + ai + ia + ii;
    if (s.samples >= 3) {
        s.p_continue = @as(f64, @floatFromInt(aa + 1)) / @as(f64, @floatFromInt(aa + ai + 2));
        s.p_restart = @as(f64, @floatFromInt(ia + 1)) / @as(f64, @floatFromInt(ia + ii + 2));
    }
    return s;
}

// ---- throughput and durations ------------------------------------------------------------------

pub const Backlog = struct {
    /// tasks finished per week (smoothed) and how much that varies
    per_week: f64,
    sigma: ?f64,
    /// weeks to clear `open` tasks at that pace, with an 80% range
    weeks: ?f64,
    weeks_lo: ?f64,
    /// null when the pace is too uncertain to bound the slow end
    weeks_hi: ?f64,
    n: usize,
};

pub fn backlog(weeks: []const Week, alpha: f64, open: usize, buf: []f64) ?Backlog {
    const n = @min(weeks.len, buf.len);
    for (weeks[weeks.len - n ..], 0..) |w, i| buf[i] = @floatFromInt(w.done_total);
    const e = ewma(buf[0..n], alpha) orelse return null;
    var b: Backlog = .{ .per_week = e.level, .sigma = e.sigma, .weeks = null, .weeks_lo = null, .weeks_hi = null, .n = n };
    if (open == 0 or e.level < 0.05) return b;
    const o: f64 = @floatFromInt(open);
    b.weeks = o / e.level;
    if (e.sigma) |s| {
        b.weeks_lo = o / (e.level + z80 * s);
        const slow = e.level - z80 * s;
        if (slow > 0.15 * e.level) b.weeks_hi = o / slow;
    }
    return b;
}

pub const Dur = struct {
    n: usize,
    median: f64,
    p80: f64,
    mean: f64,
};

fn durOf(a: std.mem.Allocator, l: *const Ledger, priority: ?u8) !?Dur {
    var xs: std.ArrayList(f64) = .empty;
    for (l.completions) |c| {
        if (c.took <= 0) continue;
        if (priority) |p| if (c.priority != p) continue;
        try xs.append(a, @floatFromInt(c.took));
    }
    if (xs.items.len == 0) return null;
    std.mem.sort(f64, xs.items, {}, std.sort.asc(f64));
    var sum: f64 = 0;
    for (xs.items) |x| sum += x;
    return .{
        .n = xs.items.len,
        .median = percentile(xs.items, 0.5),
        .p80 = percentile(xs.items, 0.8),
        .mean = sum / @as(f64, @floatFromInt(xs.items.len)),
    };
}

/// How long finished tasks of this priority took (null priority = all tasks).
pub fn durations(a: std.mem.Allocator, l: *const Ledger, priority: ?u8) !?Dur {
    return durOf(a, l, priority);
}

/// What to expect of a task of this priority: its own priority's history when
/// there are at least three samples, otherwise everything.
pub fn typicalDuration(a: std.mem.Allocator, l: *const Ledger, priority: u8) !?Dur {
    if (try durOf(a, l, priority)) |d| if (d.n >= 3) return d;
    return durOf(a, l, null);
}

// ---- one day, in detail ------------------------------------------------------------------------------

pub const TaskTime = struct { id: u32, title: []const u8, priority: u8, secs: i64 };

pub const DayDetail = struct {
    /// tasks worked on that day with the time spent that day, longest first
    worked: []const TaskTime,
    /// tasks finished that day, in order
    done: []const Completion,
    total_secs: i64,
};

pub fn dayDetail(a: std.mem.Allocator, l: *const Ledger, day: i32) !DayDetail {
    const t0 = l.tz.dayStart(day);
    const t1 = l.tz.dayStart(day + 1);

    var worked: std.ArrayList(TaskTime) = .empty;
    var total: i64 = 0;
    for (l.sessions) |s| {
        const lo = @max(s.start, t0);
        const hi = @min(s.end, t1);
        if (hi <= lo) continue;
        total += hi - lo;
        const existing = for (worked.items) |*w| {
            if (w.id == s.id) break w;
        } else null;
        if (existing) |w| {
            w.secs += hi - lo;
        } else {
            try worked.append(a, .{ .id = s.id, .title = s.title, .priority = s.priority, .secs = hi - lo });
        }
    }
    std.mem.sort(TaskTime, worked.items, {}, struct {
        fn longer(_: void, x: TaskTime, y: TaskTime) bool {
            return x.secs > y.secs;
        }
    }.longer);

    var done: std.ArrayList(Completion) = .empty;
    for (l.completions) |c| {
        if (c.at >= t0 and c.at < t1) try done.append(a, c);
    }
    return .{ .worked = worked.items, .done = done.items, .total_secs = total };
}

// ---- rhythm ---------------------------------------------------------------------------------------

/// Average hours worked on each weekday (Mon..Sun) over the given complete weeks.
pub fn weekdayAverages(weeks: []const Week) [7]f64 {
    var out: [7]f64 = @splat(0);
    if (weeks.len == 0) return out;
    for (weeks) |w| for (0..7) |d| {
        out[d] += secsToHours(w.secs[d]);
    };
    for (&out) |*v| v.* /= @floatFromInt(weeks.len);
    return out;
}

/// Hours worked in each hour of the day (0-23) over the last `weeks_back` weeks.
pub fn hourHistogram(l: *const Ledger, weeks_back: u8) [24]f64 {
    var secs: [24]i64 = @splat(0);
    const lo = l.now - @as(i64, weeks_back) * 7 * day_secs;
    for (l.sessions) |s| {
        var t = @max(s.start, lo);
        const end = @min(s.end, l.now);
        while (t < end) {
            const off = l.tz.offset(t);
            const boundary = (@divFloor(t + off, 3600) + 1) * 3600 - off;
            const next = @min(end, boundary);
            secs[l.tz.hourOf(t)] += next - t;
            t = next;
        }
    }
    var out: [24]f64 = undefined;
    for (secs, 0..) |s, i| out[i] = secsToHours(s);
    return out;
}

// ---- dashboard series -------------------------------------------------------------------------------

/// The last `n` weeks ending with the one in progress, oldest first. Weeks from
/// before the log began are simply all zeros, so charts keep a fixed width.
pub fn recentWeeks(a: std.mem.Allocator, l: *const Ledger, n: usize, active_secs: i64) ![]Week {
    const out = try a.alloc(Week, n);
    const cur = dates.weekStart(l.today);
    for (out, 0..) |*w, i| {
        const back: i32 = @intCast(n - 1 - i);
        w.* = week(l, cur - back * 7, active_secs);
    }
    return out;
}

/// Seconds worked per priority (index 0 = P1 ... 3 = P4) inside [t0, t1).
pub fn timeByPriority(l: *const Ledger, t0: i64, t1: i64) [4]i64 {
    var out: [4]i64 = @splat(0);
    for (l.sessions) |s| {
        const lo = @max(s.start, t0);
        const hi = @min(s.end, t1);
        if (hi > lo) out[std.math.clamp(s.priority, 1, 4) - 1] += hi - lo;
    }
    return out;
}

/// Completions per priority (index 0 = P1 ... 3 = P4) inside [t0, t1).
pub fn doneByPriority(l: *const Ledger, t0: i64, t1: i64) [4]u32 {
    var out: [4]u32 = @splat(0);
    for (l.completions) |c| {
        if (c.at >= t0 and c.at < t1) out[std.math.clamp(c.priority, 1, 4) - 1] += 1;
    }
    return out;
}

pub const dur_buckets = 6;
/// Upper edges of the duration buckets: <15m, 15-30m, 30m-1h, 1-2h, 2-4h, 4h+
pub const dur_edges = [dur_buckets - 1]i64{ 15 * 60, 30 * 60, 60 * 60, 2 * 3600, 4 * 3600 };

/// How many finished tasks fall into each duration bucket (tasks with no tracked time are skipped).
pub fn durationHistogram(l: *const Ledger) [dur_buckets]u32 {
    var out: [dur_buckets]u32 = @splat(0);
    for (l.completions) |c| {
        if (c.took <= 0) continue;
        var i: usize = 0;
        while (i < dur_edges.len and c.took >= dur_edges[i]) i += 1;
        out[i] += 1;
    }
    return out;
}

/// Running total of finished tasks at the end of each given week (everything
/// finished before the first week is included, so the line starts at its true level).
pub fn cumulativeDone(a: std.mem.Allocator, l: *const Ledger, weeks: []const Week) ![]f64 {
    const out = try a.alloc(f64, weeks.len);
    if (weeks.len == 0) return out;
    var total: u32 = l.doneBetween(std.math.minInt(i64), l.tz.dayStart(weeks[0].start_day));
    for (weeks, 0..) |w, i| {
        total += w.done_total;
        out[i] = @floatFromInt(total);
    }
    return out;
}

/// Where every task on the board stands right now, split by priority, plus how
/// the open ones sit against their deadlines.
pub const BoardSnap = struct {
    backlog: [4]u32 = @splat(0),
    doing: [4]u32 = @splat(0),
    done: [4]u32 = @splat(0),
    /// open tasks (backlog + in progress) by deadline
    overdue: u32 = 0,
    /// due today or within two days (same cut-off the board uses for its warning colour)
    due_soon: u32 = 0,
    /// due in 3 to 7 days
    due_week: u32 = 0,
    due_later: u32 = 0,
    no_deadline: u32 = 0,

    fn sum(xs: [4]u32) u32 {
        var t: u32 = 0;
        for (xs) |x| t += x;
        return t;
    }
    pub fn nBacklog(self: BoardSnap) u32 {
        return sum(self.backlog);
    }
    pub fn nDoing(self: BoardSnap) u32 {
        return sum(self.doing);
    }
    pub fn nDone(self: BoardSnap) u32 {
        return sum(self.done);
    }
    pub fn nOpen(self: BoardSnap) u32 {
        return self.nBacklog() + self.nDoing();
    }
    pub fn nTotal(self: BoardSnap) u32 {
        return self.nOpen() + self.nDone();
    }
    /// finished share of all tasks on the board; null on an empty board
    pub fn completion(self: BoardSnap) ?f64 {
        const t = self.nTotal();
        if (t == 0) return null;
        return @as(f64, @floatFromInt(self.nDone())) / @as(f64, @floatFromInt(t));
    }
};

pub fn boardSnap(board: *const model.Board, today: i32) BoardSnap {
    var s: BoardSnap = .{};
    for (board.tasks.items) |t| {
        const pi: usize = std.math.clamp(t.priority, 1, 4) - 1;
        switch (t.status) {
            .backlog => s.backlog[pi] += 1,
            .doing => s.doing[pi] += 1,
            .done => {
                s.done[pi] += 1;
                continue;
            },
        }
        if (t.deadline) |d| {
            const diff = d - today;
            if (diff < 0) s.overdue += 1 else if (diff <= 2) s.due_soon += 1 else if (diff <= 7) s.due_week += 1 else s.due_later += 1;
        } else s.no_deadline += 1;
    }
    return s;
}

// ---- practice (multiple-choice questions) ---------------------------------------------------

/// What one week of practice looked like. Time and questions are credited to the week
/// in which the practice task was finished.
pub const PracticeWeek = struct {
    start_day: i32,
    tests: u32 = 0,
    secs: i64 = 0,
    /// finished practice tasks
    sessions: u32 = 0,
    /// questions per local day, Monday first
    per_day: [7]u32 = @splat(0),

    /// average seconds per question, null when there is nothing to divide
    pub fn pace(self: PracticeWeek) ?f64 {
        if (self.tests == 0 or self.secs <= 0) return null;
        return @as(f64, @floatFromInt(self.secs)) / @as(f64, @floatFromInt(self.tests));
    }
};

/// The last `n` weeks (oldest first, the one in progress last) of practice.
pub fn practiceWeeks(a: std.mem.Allocator, l: *const Ledger, n: usize) ![]PracticeWeek {
    const out = try a.alloc(PracticeWeek, n);
    const cur = dates.weekStart(l.today);
    for (out, 0..) |*w, i| {
        const back: i32 = @intCast(n - 1 - i);
        w.* = .{ .start_day = cur - back * 7 };
    }
    for (l.completions) |c| {
        if (c.tests == 0) continue;
        const day = l.tz.dayOf(c.at);
        const ws = dates.weekStart(day);
        const back = @divExact(cur - ws, 7);
        if (back < 0 or back >= n) continue;
        const w = &out[n - 1 - @as(usize, @intCast(back))];
        w.tests += c.tests;
        w.secs += c.took;
        w.sessions += 1;
        w.per_day[@intCast(day - ws)] += c.tests;
    }
    return out;
}

pub const PracticeTotals = struct { tests: u32 = 0, secs: i64 = 0, sessions: u32 = 0, best_week_tests: u32 = 0, best_week_start: i32 = 0 };

/// Everything ever finished (all weeks, not just the recent ones).
pub fn practiceTotals(l: *const Ledger) PracticeTotals {
    var t: PracticeTotals = .{};
    var best_tests: u32 = 0;
    var best_start: i32 = 0;
    // weekly sums, found by sorting nothing: completions are oldest first, so a running sum works
    var cur_week: i32 = std.math.minInt(i32);
    var cur_sum: u32 = 0;
    for (l.completions) |c| {
        if (c.tests == 0) continue;
        t.tests += c.tests;
        t.secs += c.took;
        t.sessions += 1;
        const ws = dates.weekStart(l.tz.dayOf(c.at));
        if (ws != cur_week) {
            cur_week = ws;
            cur_sum = 0;
        }
        cur_sum += c.tests;
        if (cur_sum > best_tests) {
            best_tests = cur_sum;
            best_start = ws;
        }
    }
    t.best_week_tests = best_tests;
    t.best_week_start = best_start;
    return t;
}

// ---- tests -------------------------------------------------------------------------------------------

const testing = std.testing;
const tz0: Tz = .{ .fixed = 0 };
const D = dates.daysFromCivil;

fn at(day: i32, hour: i64) i64 {
    return @as(i64, day) * day_secs + hour * 3600;
}

/// Four complete weeks (14 Sep .. 11 Oct 2026) with 2h sessions on weekdays,
/// except week two which stops after Wednesday, plus the current week up to
/// Wednesday 14 Oct 15:00 (3h Mon, 1h Tue, 1h Wed finished, nothing running).
fn scenario(a: std.mem.Allocator, list: *std.ArrayList(worklog.Entry)) !void {
    var id: u32 = 0;
    const starts = [_]i32{ D(2026, 9, 14), D(2026, 9, 21), D(2026, 9, 28), D(2026, 10, 5) };
    for (starts, 0..) |ws, wi| {
        const days: i32 = if (wi == 1) 3 else 5;
        var d: i32 = 0;
        while (d < days) : (d += 1) {
            id += 1;
            try list.append(a, .{ .session = .{ .id = id, .start = at(ws + d, 10), .end = at(ws + d, 12), .priority = 2, .title = "work" } });
        }
    }
    const cw = D(2026, 10, 12);
    try list.append(a, .{ .session = .{ .id = 100, .start = at(cw, 9), .end = at(cw, 12), .priority = 1, .title = "mon" } });
    try list.append(a, .{ .session = .{ .id = 101, .start = at(cw + 1, 9), .end = at(cw + 1, 10), .priority = 1, .title = "tue" } });
    try list.append(a, .{ .session = .{ .id = 102, .start = at(cw + 2, 9), .end = at(cw + 2, 10), .priority = 3, .title = "wed" } });
}

test "week totals, averages and the aligned comparison" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: std.ArrayList(worklog.Entry) = .empty;
    try scenario(a, &entries);

    const now = at(D(2026, 10, 14), 15);
    const l = try Ledger.build(a, tz0, now, entries.items, &.{});
    try testing.expectEqual(D(2026, 9, 14), l.first_day);

    const cur = week(&l, D(2026, 10, 12), 1800);
    try testing.expectApproxEqAbs(@as(f64, 5), cur.hours(), 1e-9);
    try testing.expectEqual(@as(u8, 3), cur.days_counted);
    try testing.expectApproxEqAbs(@as(f64, 5.0 / 3.0), cur.avgPerDayHours(), 1e-9);
    try testing.expectEqual(@as(u8, 3), cur.active_days);

    const w1 = week(&l, D(2026, 9, 21), 1800);
    try testing.expectApproxEqAbs(@as(f64, 6), w1.hours(), 1e-9);
    try testing.expectEqual(@as(u8, 7), w1.days_counted);

    // current week is compared with last week *up to the same moment*: Mon 2h + Tue 2h + Wed 10-12 = 6h
    const c = compare(&l, cur, 1800);
    try testing.expect(c.aligned and c.has_prev);
    try testing.expectApproxEqAbs(@as(f64, 6), c.hours.prev, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -100.0 / 6.0), c.hours.pct().?, 1e-9);
    // average per day: this week so far vs the whole previous week (10h / 7 days)
    try testing.expectApproxEqAbs(@as(f64, 10.0 / 7.0), c.per_day.prev, 1e-9);

    // a finished week is compared with the full week before it
    const c2 = compare(&l, week(&l, D(2026, 10, 5), 1800), 1800);
    try testing.expect(!c2.aligned);
    try testing.expectApproxEqAbs(@as(f64, 10), c2.hours.cur, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), c2.hours.prev, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), c2.hours.pct().?, 1e-9);

    // the first week has nothing before it
    try testing.expect(!compare(&l, week(&l, D(2026, 9, 14), 1800), 1800).has_prev);
}

test "sessions are split at midnight and running ones count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = D(2026, 10, 13);
    var entries: std.ArrayList(worklog.Entry) = .empty;
    try entries.append(a, .{ .session = .{ .id = 1, .start = at(d, 22), .end = at(d + 1, 2), .priority = 1, .title = "late night" } });
    const running = [_]Session{.{ .id = 2, .start = at(d + 1, 8), .end = at(d + 1, 20), .priority = 2, .title = "now" }};
    const l = try Ledger.build(a, tz0, at(d + 1, 9), entries.items, &running); // "now" is 09:00, so the running one is clipped
    try testing.expectEqual(@as(i64, 2 * 3600), l.secsOn(d));
    try testing.expectEqual(@as(i64, 3 * 3600), l.secsOn(d + 1)); // 2h from the night + 1h running
    // a zone 3h east of UTC moves 22:00-02:00 UTC to 01:00-05:00 local: all of it on the next local day
    const east = try Ledger.build(a, .{ .fixed = 3 * 3600 }, at(d + 1, 9), entries.items, &.{});
    try testing.expectEqual(@as(i64, 4 * 3600), east.secsOn(d + 1));
    try testing.expectEqual(@as(i64, 0), east.secsOn(d));
}

test "undone cancels a completion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = D(2026, 10, 13);
    var entries: std.ArrayList(worklog.Entry) = .empty;
    try entries.append(a, .{ .done = .{ .id = 1, .at = at(d, 10), .took = 600, .priority = 1, .title = "a" } });
    try entries.append(a, .{ .done = .{ .id = 2, .at = at(d, 11), .took = 600, .priority = 1, .title = "b" } });
    try entries.append(a, .{ .undone = .{ .id = 1, .at = at(d, 12) } });
    try entries.append(a, .{ .done = .{ .id = 1, .at = at(d, 13), .took = 900, .priority = 1, .title = "a again" } });
    try entries.append(a, .{ .undone = .{ .id = 2, .at = at(d, 14) } });
    const l = try Ledger.build(a, tz0, at(d, 15), entries.items, &.{});
    try testing.expectEqual(@as(usize, 1), l.completions.len);
    try testing.expectEqualStrings("a again", l.completions[0].title);
    try testing.expectEqual(@as(u16, 1), l.doneOn(d));
}

test "ewma, forecast and trend" {
    const e = ewma(&.{ 10, 6, 10, 10 }, 0.4).?;
    try testing.expectApproxEqAbs(@as(f64, 9.424), e.level, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.5483), e.sigma.?, 1e-3);
    try testing.expect(ewma(&.{5}, 0.4) == null);
    try testing.expect(ewma(&.{ 5, 6 }, 0.4).?.sigma == null); // two points: no spread estimate
    try testing.expectApproxEqAbs(@as(f64, 1), ewma(&.{ 1, 2, 3, 4 }, 0.5).?.slope.?, 1e-9);
}

test "streaks and the markov estimate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: std.ArrayList(worklog.Entry) = .empty;
    try scenario(a, &entries);
    const now = at(D(2026, 10, 14), 15);
    const l = try Ledger.build(a, tz0, now, entries.items, &.{});
    const s = streak(&l, 1800);
    try testing.expectEqual(@as(u32, 3), s.current); // Mon, Tue, Wed
    try testing.expect(s.today_active);
    try testing.expectEqual(@as(u32, 5), s.longest);
    try testing.expectEqual(@as(u32, 31), s.total_days); // 14 Sep .. 14 Oct
    try testing.expectEqual(@as(u32, 21), s.active_days); // 5 + 3 + 5 + 5 + 3
    // finished days 15 Sep .. 13 Oct give 29 day-to-day transitions:
    // active->active 15, active->idle 4, idle->active 4, idle->idle 6
    try testing.expectEqual(@as(u32, 29), s.samples);
    try testing.expectApproxEqAbs(@as(f64, 16.0 / 21.0), s.p_continue.?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5.0 / 12.0), s.p_restart.?, 1e-9);

    // an idle today keeps yesterday's streak alive, but a second idle day breaks it
    const tue_night = try Ledger.build(a, tz0, at(D(2026, 10, 13), 23), entries.items, &.{});
    try testing.expectEqual(@as(u32, 2), streak(&tue_night, 1800).current);
    const thu = try Ledger.build(a, tz0, at(D(2026, 10, 15), 8), entries.items, &.{});
    const s_thu = streak(&thu, 1800);
    try testing.expect(!s_thu.today_active);
    try testing.expectEqual(@as(u32, 3), s_thu.current); // Wed's day still counts, Thursday is just not done yet
    const fri = try Ledger.build(a, tz0, at(D(2026, 10, 16), 8), entries.items, &.{});
    try testing.expectEqual(@as(u32, 0), streak(&fri, 1800).current);
}

test "projection is a sane, reproducible distribution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: std.ArrayList(worklog.Entry) = .empty;
    try scenario(a, &entries);
    const l = try Ledger.build(a, tz0, at(D(2026, 10, 14), 15), entries.items, &.{});
    const weeks = try completeWeeks(a, &l, 8, 1800);
    try testing.expectEqual(@as(usize, 4), weeks.len);

    const p = (try projectWeek(a, &l, weeks, 12, 42)).?;
    try testing.expectApproxEqAbs(@as(f64, 5), p.so_far, 1e-9);
    try testing.expect(p.p10 <= p.p50 and p.p50 <= p.p90);
    try testing.expect(p.p10 >= p.so_far); // work already done can't vanish
    try testing.expect(p.p_goal > 0 and p.p_goal < 1);

    const again = (try projectWeek(a, &l, weeks, 12, 42)).?;
    try testing.expectEqual(p.p50, again.p50); // same seed, same answer
    try testing.expectEqual(@as(f64, 1), (try projectWeek(a, &l, weeks, 0, 42)).?.p_goal);
    try testing.expectEqual(@as(f64, 0), (try projectWeek(a, &l, weeks, 500, 42)).?.p_goal);
    // a bigger goal is never more likely
    try testing.expect((try projectWeek(a, &l, weeks, 20, 42)).?.p_goal <= p.p_goal);
    // too little history: no projection rather than an invented one
    try testing.expect((try projectWeek(a, &l, weeks[0..1], 12, 42)) == null);

    var buf: [26]f64 = undefined;
    const f = forecastNextWeek(weeks, 0.4, &buf).?;
    try testing.expectApproxEqAbs(@as(f64, 9.424), f.next, 1e-9);
    try testing.expect(f.lo.? < f.next and f.next < f.hi.?);
}

test "complete weeks leave out the partial first week" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: std.ArrayList(worklog.Entry) = .empty;
    // history begins on a Wednesday: that week is incomplete and must not drag the model down
    const wed = D(2026, 9, 16);
    try entries.append(a, .{ .session = .{ .id = 1, .start = at(wed, 10), .end = at(wed, 12), .priority = 1, .title = "x" } });
    try entries.append(a, .{ .session = .{ .id = 2, .start = at(wed + 7, 10), .end = at(wed + 7, 14), .priority = 1, .title = "y" } });
    // now = Thursday 8 Oct: weeks of 21 Sep and 28 Sep are over; the week of 5 Oct is still running
    const l = try Ledger.build(a, tz0, at(D(2026, 10, 8), 9), entries.items, &.{});
    const weeks = try completeWeeks(a, &l, 8, 1800);
    try testing.expectEqual(@as(usize, 2), weeks.len);
    try testing.expectEqual(D(2026, 9, 21), weeks[0].start_day); // first Monday after the log began
    try testing.expectApproxEqAbs(@as(f64, 4), weeks[0].hours(), 1e-9);
}

test "day detail merges sessions per task" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = D(2026, 10, 13);
    var entries: std.ArrayList(worklog.Entry) = .empty;
    try entries.append(a, .{ .session = .{ .id = 1, .start = at(d, 9), .end = at(d, 10), .priority = 1, .title = "alpha" } });
    try entries.append(a, .{ .session = .{ .id = 2, .start = at(d, 10), .end = at(d, 13), .priority = 2, .title = "beta" } });
    try entries.append(a, .{ .session = .{ .id = 1, .start = at(d, 14), .end = at(d, 14) + 1800, .priority = 1, .title = "alpha" } });
    try entries.append(a, .{ .done = .{ .id = 1, .at = at(d, 15), .took = 5400, .priority = 1, .title = "alpha" } });
    try entries.append(a, .{ .session = .{ .id = 3, .start = at(d - 1, 9), .end = at(d - 1, 10), .priority = 1, .title = "yesterday" } });
    const l = try Ledger.build(a, tz0, at(d, 20), entries.items, &.{});
    const det = try dayDetail(a, &l, d);
    try testing.expectEqual(@as(usize, 2), det.worked.len);
    try testing.expectEqualStrings("beta", det.worked[0].title); // longest first
    try testing.expectEqual(@as(i64, 3 * 3600), det.worked[0].secs);
    try testing.expectEqual(@as(i64, 5400), det.worked[1].secs); // 1h + 30m of alpha, merged
    try testing.expectEqual(@as(usize, 1), det.done.len);
    try testing.expectEqual(@as(i64, 5400), det.done[0].took);
    try testing.expectEqual(l.secsOn(d), det.total_secs);
}

test "durations, backlog eta and rhythm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: std.ArrayList(worklog.Entry) = .empty;
    try scenario(a, &entries);
    const d = D(2026, 10, 1);
    const tooks = [_]i64{ 3600, 7200, 1800, 5400 };
    for (tooks, 0..) |t, i| try entries.append(a, .{ .done = .{ .id = @intCast(200 + i), .at = at(d + @as(i32, @intCast(i)), 12), .took = t, .priority = 2, .title = "t" } });
    try entries.append(a, .{ .done = .{ .id = 300, .at = at(d, 13), .took = 0, .priority = 2, .title = "instant" } }); // no tracked time: ignored
    const l = try Ledger.build(a, tz0, at(D(2026, 10, 14), 15), entries.items, &.{});

    const dur = (try durations(a, &l, 2)).?;
    try testing.expectEqual(@as(usize, 4), dur.n);
    try testing.expectApproxEqAbs(@as(f64, 4500), dur.median, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 6120), dur.p80, 1e-9);
    try testing.expect((try durations(a, &l, 4)) == null);
    // priority 4 has no history, so the typical duration falls back to all tasks
    try testing.expectEqual(@as(usize, 4), (try typicalDuration(a, &l, 4)).?.n);

    const weeks = try completeWeeks(a, &l, 8, 1800);
    var buf: [26]f64 = undefined;
    const b = backlog(weeks, 0.4, 12, &buf).?;
    try testing.expect(b.per_week > 0 and b.weeks.? > 0);
    try testing.expect(backlog(weeks, 0.4, 0, &buf).?.weeks == null); // nothing open, nothing to estimate

    const avg = weekdayAverages(weeks);
    try testing.expectApproxEqAbs(@as(f64, 2), avg[0], 1e-9); // Mondays: 2h every week
    try testing.expectApproxEqAbs(@as(f64, 1.5), avg[3], 1e-9); // Thursdays: 2h three times, 0h once
    try testing.expectEqual(@as(f64, 0), avg[6]);

    const hist = hourHistogram(&l, 8);
    try testing.expect(hist[10] > 0 and hist[11] > 0);
    try testing.expectEqual(@as(f64, 0), hist[3]);
}

test "recent weeks keep a fixed width and start before the log" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: std.ArrayList(worklog.Entry) = .empty;
    try scenario(a, &entries);
    const l = try Ledger.build(a, tz0, at(D(2026, 10, 14), 15), entries.items, &.{});
    const ws = try recentWeeks(a, &l, 6, 1800);
    try testing.expectEqual(@as(usize, 6), ws.len);
    try testing.expectEqual(D(2026, 10, 12), ws[5].start_day);
    try testing.expectEqual(D(2026, 9, 7), ws[0].start_day);
    try testing.expectEqual(@as(i64, 0), ws[0].total); // before the log began
    try testing.expectApproxEqAbs(@as(f64, 10), ws[1].hours(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5), ws[5].hours(), 1e-9);
}

test "time and completions by priority" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: std.ArrayList(worklog.Entry) = .empty;
    try scenario(a, &entries);
    try entries.append(a, .{ .done = .{ .id = 1, .at = at(D(2026, 10, 13), 9), .took = 600, .priority = 3, .title = "x" } });
    try entries.append(a, .{ .done = .{ .id = 2, .at = at(D(2026, 10, 14), 9), .took = 600, .priority = 1, .title = "y" } });
    try entries.append(a, .{ .done = .{ .id = 3, .at = at(D(2026, 10, 14), 10), .took = 600, .priority = 1, .title = "z" } });
    const l = try Ledger.build(a, tz0, at(D(2026, 10, 14), 15), entries.items, &.{});
    const t = timeByPriority(&l, std.math.minInt(i64), std.math.maxInt(i64));
    try testing.expectEqual(@as(i64, 4 * 3600), t[0]); // mon 3h + tue 1h
    try testing.expectEqual(@as(i64, 36 * 3600), t[1]); // 18 two-hour sessions
    try testing.expectEqual(@as(i64, 3600), t[2]);
    try testing.expectEqual(@as(i64, 0), t[3]);
    // only this week
    const wk = timeByPriority(&l, l.tz.dayStart(D(2026, 10, 12)), l.tz.dayStart(D(2026, 10, 19)));
    try testing.expectEqual(@as(i64, 4 * 3600), wk[0]);
    try testing.expectEqual(@as(i64, 0), wk[1]);
    const d = doneByPriority(&l, std.math.minInt(i64), std.math.maxInt(i64));
    try testing.expectEqual([4]u32{ 2, 0, 1, 0 }, d);
}

test "duration histogram buckets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = D(2026, 10, 13);
    var entries: std.ArrayList(worklog.Entry) = .empty;
    const tooks = [_]i64{ 600, 899, 900, 2000, 3600, 7199, 20000, 0 };
    for (tooks, 0..) |t, i| try entries.append(a, .{ .done = .{ .id = @intCast(i + 1), .at = at(d, 9), .took = t, .priority = 2, .title = "t" } });
    const l = try Ledger.build(a, tz0, at(d, 15), entries.items, &.{});
    const h = durationHistogram(&l);
    try testing.expectEqual([dur_buckets]u32{ 2, 1, 1, 2, 0, 1 }, h); // the 0s task is skipped
}

test "cumulative completions include everything before the first week" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: std.ArrayList(worklog.Entry) = .empty;
    try entries.append(a, .{ .done = .{ .id = 1, .at = at(D(2026, 9, 1), 9), .took = 60, .priority = 1, .title = "old" } });
    try entries.append(a, .{ .done = .{ .id = 2, .at = at(D(2026, 10, 6), 9), .took = 60, .priority = 1, .title = "a" } });
    try entries.append(a, .{ .done = .{ .id = 3, .at = at(D(2026, 10, 13), 9), .took = 60, .priority = 1, .title = "b" } });
    try entries.append(a, .{ .done = .{ .id = 4, .at = at(D(2026, 10, 14), 9), .took = 60, .priority = 1, .title = "c" } });
    const l = try Ledger.build(a, tz0, at(D(2026, 10, 14), 15), entries.items, &.{});
    const ws = try recentWeeks(a, &l, 2, 1800); // Oct 5 and Oct 12
    const cum = try cumulativeDone(a, &l, ws);
    try testing.expectEqual(@as(f64, 2), cum[0]); // old + a
    try testing.expectEqual(@as(f64, 4), cum[1]);
}

test "board snapshot splits tasks and deadlines" {
    const a = testing.allocator;
    var board = model.Board.init(a);
    defer board.deinit();
    const today = D(2026, 10, 14);
    _ = try board.add("late", .backlog, 1, today - 2, 0);
    _ = try board.add("today", .backlog, 2, today, 0);
    _ = try board.add("in 5 days", .doing, 2, today + 5, 0);
    _ = try board.add("far", .backlog, 4, today + 30, 0);
    _ = try board.add("none", .backlog, 3, null, 0);
    _ = try board.add("finished late", .done, 1, today - 9, 0); // done tasks never count as overdue
    const s = boardSnap(&board, today);
    try testing.expectEqual([4]u32{ 1, 1, 1, 1 }, s.backlog);
    try testing.expectEqual([4]u32{ 0, 1, 0, 0 }, s.doing);
    try testing.expectEqual([4]u32{ 1, 0, 0, 0 }, s.done);
    try testing.expectEqual(@as(u32, 1), s.overdue);
    try testing.expectEqual(@as(u32, 1), s.due_soon);
    try testing.expectEqual(@as(u32, 1), s.due_week);
    try testing.expectEqual(@as(u32, 1), s.due_later);
    try testing.expectEqual(@as(u32, 1), s.no_deadline);
    try testing.expectEqual(@as(u32, 5), s.nOpen());
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 6.0), s.completion().?, 1e-9);
    try testing.expect((BoardSnap{}).completion() == null);
}

test "practice weeks, totals and pace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries: std.ArrayList(worklog.Entry) = .empty;
    // two weeks ago: 50 questions in 25 min; last week: 20 + 40 questions; this week: 30 in 15 min
    const items = [_]struct { id: u32, day: i32, took: i64, n: u32 }{
        .{ .id = 1, .day = D(2026, 9, 29), .took = 1500, .n = 50 },
        .{ .id = 2, .day = D(2026, 10, 6), .took = 600, .n = 20 },
        .{ .id = 3, .day = D(2026, 10, 8), .took = 2400, .n = 40 },
        .{ .id = 4, .day = D(2026, 10, 14), .took = 900, .n = 30 },
    };
    for (items) |it| {
        try entries.append(a, .{ .done = .{ .id = it.id, .at = at(it.day, 10), .took = it.took, .priority = 2, .title = "quiz" } });
        try entries.append(a, .{ .tests = .{ .id = it.id, .tests = it.n } });
    }
    // an ordinary task, a practice task that was reopened, and a count that was corrected
    try entries.append(a, .{ .done = .{ .id = 5, .at = at(D(2026, 10, 14), 11), .took = 100, .priority = 1, .title = "plain" } });
    try entries.append(a, .{ .done = .{ .id = 6, .at = at(D(2026, 10, 13), 11), .took = 100, .priority = 1, .title = "oops" } });
    try entries.append(a, .{ .tests = .{ .id = 6, .tests = 99 } });
    try entries.append(a, .{ .undone = .{ .id = 6, .at = at(D(2026, 10, 13), 12) } });
    try entries.append(a, .{ .tests = .{ .id = 1, .tests = 60 } }); // corrected 50 -> 60
    const l = try Ledger.build(a, tz0, at(D(2026, 10, 14), 15), entries.items, &.{});

    const ws = try practiceWeeks(a, &l, 3);
    try testing.expectEqual(@as(usize, 3), ws.len);
    try testing.expectEqual(D(2026, 9, 28), ws[0].start_day);
    try testing.expectEqual(@as(u32, 60), ws[0].tests);
    try testing.expectEqual(@as(u32, 60), ws[1].tests);
    try testing.expectEqual(@as(i64, 3000), ws[1].secs);
    try testing.expectEqual(@as(u32, 2), ws[1].sessions);
    try testing.expectEqual(@as(u32, 30), ws[2].tests);
    try testing.expectEqual(@as(u32, 30), ws[2].per_day[2]); // Wednesday the 14th
    try testing.expectApproxEqAbs(@as(f64, 50), ws[1].pace().?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 30), ws[2].pace().?, 1e-9);

    const t = practiceTotals(&l);
    try testing.expectEqual(@as(u32, 150), t.tests);
    try testing.expectEqual(@as(u32, 4), t.sessions);
    try testing.expectEqual(@as(u32, 60), t.best_week_tests);
    try testing.expectEqual(D(2026, 9, 28), t.best_week_start);

    // weeks before the log began are empty, not missing
    const wide = try practiceWeeks(a, &l, 6);
    try testing.expectEqual(@as(u32, 0), wide[0].tests);
    try testing.expect(wide[0].pace() == null);
}
