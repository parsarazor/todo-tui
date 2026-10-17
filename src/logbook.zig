//! State and keys of the Log popup: a week-by-week log and an insights report.
//! Drawing is in log_view.zig; the numbers come from stats.zig.
const std = @import("std");
const vaxis = @import("vaxis");
const draw = @import("draw.zig");
const stats = @import("stats.zig");

pub const Tab = enum { week, insights };
pub const Action = enum { none, close, quit, params_changed };

pub const Logbook = struct {
    tab: Tab = .week,
    /// 0 = this week, -1 = last week, ...
    week_offset: i32 = 0,
    /// selected weekday in the week view, Monday = 0
    day: u8 = 0,
    scroll: usize = 0,
    detail_scroll: usize = 0,

    // measured by the renderer every frame
    min_offset: i32 = 0,
    today_weekday: u8 = 0,
    total_lines: usize = 0,
    page: usize = 10,
    detail_lines: usize = 0,
    detail_page: usize = 5,
    tab_hits: [2]draw.Rect = @splat(.{}),
    day_hits: [7]draw.Rect = @splat(.{}),

    pub fn open(self: *Logbook, today_weekday: u8) void {
        self.week_offset = 0;
        self.day = today_weekday;
        self.today_weekday = today_weekday;
        self.detail_scroll = 0;
    }

    fn maxScroll(total: usize, page: usize) usize {
        return total -| page;
    }

    pub fn handleKey(self: *Logbook, key: vaxis.Key, params: *stats.Params) Action {
        const K = vaxis.Key;
        if (key.matches('c', .{ .ctrl = true })) return .quit;
        if (key.matches(K.escape, .{}) or key.matches('s', .{}) or key.matches('q', .{})) return .close;

        if (key.matches(K.tab, .{}) or key.matches(K.tab, .{ .shift = true })) {
            self.tab = if (self.tab == .week) .insights else .week;
            return .none;
        }
        if (key.matches('1', .{})) self.tab = .week;
        if (key.matches('2', .{})) self.tab = .insights;

        switch (self.tab) {
            .week => {
                if ((key.matches(K.left, .{}) or key.matches('h', .{})) and self.week_offset > self.min_offset) {
                    self.week_offset -= 1;
                    self.detail_scroll = 0;
                }
                if ((key.matches(K.right, .{}) or key.matches('l', .{})) and self.week_offset < 0) {
                    self.week_offset += 1;
                    self.detail_scroll = 0;
                }
                if (key.matches('t', .{})) {
                    self.week_offset = 0;
                    self.day = self.today_weekday;
                    self.detail_scroll = 0;
                }
                if (key.matches(K.up, .{}) or key.matches('k', .{})) {
                    self.day -|= 1;
                    self.detail_scroll = 0;
                }
                if (key.matches(K.down, .{}) or key.matches('j', .{})) {
                    self.day = @min(self.day + 1, 6);
                    self.detail_scroll = 0;
                }
                if (key.matches(K.page_up, .{})) self.detail_scroll -|= self.detail_page;
                if (key.matches(K.page_down, .{}))
                    self.detail_scroll = @min(self.detail_scroll + self.detail_page, maxScroll(self.detail_lines, self.detail_page));
            },
            .insights => {
                const max = maxScroll(self.total_lines, self.page);
                if (key.matches(K.up, .{}) or key.matches('k', .{})) self.scroll -|= 1;
                if (key.matches(K.down, .{}) or key.matches('j', .{})) self.scroll = @min(self.scroll + 1, max);
                if (key.matches(K.page_up, .{})) self.scroll -|= self.page;
                if (key.matches(K.page_down, .{})) self.scroll = @min(self.scroll + self.page, max);
                if (key.matches(K.home, .{})) self.scroll = 0;
                if (key.matches(K.end, .{})) self.scroll = max;

                const before = params.*;
                if (key.matches('g', .{})) params.goal_hours -|= 1;
                if (key.matches('G', .{})) params.goal_hours +|= 1;
                if (key.matches('m', .{})) params.active_min -|= 5;
                if (key.matches('M', .{})) params.active_min +|= 5;
                if (key.matches('a', .{})) params.alpha_pct -|= 5;
                if (key.matches('A', .{})) params.alpha_pct +|= 5;
                if (key.matches('w', .{})) params.window_weeks -|= 1;
                if (key.matches('W', .{})) params.window_weeks +|= 1;
                params.clamp();
                if (!std.meta.eql(before, params.*)) return .params_changed;
            },
        }
        return .none;
    }

    pub fn handleMouse(self: *Logbook, m: vaxis.Mouse) void {
        if (m.type != .press) return;
        switch (m.button) {
            .left => {
                for (self.tab_hits, 0..) |r, i| {
                    if (r.w > 0 and r.contains(m.col, m.row)) self.tab = @enumFromInt(i);
                }
                if (self.tab == .week) for (self.day_hits, 0..) |r, i| {
                    if (r.w > 0 and r.contains(m.col, m.row)) {
                        self.day = @intCast(i);
                        self.detail_scroll = 0;
                    }
                };
            },
            .wheel_up => switch (self.tab) {
                .week => self.detail_scroll -|= 1,
                .insights => self.scroll -|= 3,
            },
            .wheel_down => switch (self.tab) {
                .week => self.detail_scroll = @min(self.detail_scroll + 1, maxScroll(self.detail_lines, self.detail_page)),
                .insights => self.scroll = @min(self.scroll + 3, maxScroll(self.total_lines, self.page)),
            },
            else => {},
        }
    }
};
