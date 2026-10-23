//! Terminal charts. Everything is drawn with block elements (▁▂▃▄▅▆▇█ ▏▎▍▌▋▊▉)
//! and braille dots (2×4 dots per cell, which are square on most terminals), so
//! there are no images and nothing to install.
//!
//! Like draw.zig, every function takes the root window plus absolute coordinates
//! and clips to the rectangle it is given: a chart never draws outside its Rect.
//! Charts never allocate long-lived memory; the ones that need scratch space take
//! the per-frame arena.
const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const draw = @import("draw.zig");

pub const Rect = draw.Rect;
const Color = theme.Color;
const Allocator = std.mem.Allocator;

const v_blocks = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
const h_blocks = [_][]const u8{ " ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" };

/// Colour of the empty part of a gauge / track.
pub const track: Color = theme.glass_hi;

fn put(win: vaxis.Window, x: u16, y: u16, g: []const u8, fg: Color, bg: Color) void {
    win.writeCell(x, y, .{ .char = .{ .grapheme = g, .width = 1 }, .style = .{ .fg = fg, .bg = bg } });
}

fn clamp01(x: f64) f64 {
    if (std.math.isNan(x)) return 0;
    return std.math.clamp(x, 0, 1);
}

fn eighths(frac: f64, cells: usize) usize {
    return @intFromFloat(@round(clamp01(frac) * @as(f64, @floatFromInt(cells * 8))));
}

/// Draw `str` centred in the `w` columns starting at x (clipped).
fn centered(win: vaxis.Window, x: u16, y: u16, w: u16, str: []const u8, style: theme.Style) void {
    if (w == 0 or str.len == 0) return;
    const tw = win.gwidth(str);
    const off: u16 = if (tw < w) (w - tw) / 2 else 0;
    _ = draw.text(win, x + off, y, w - off, str, style);
}

// ---- braille canvas ---------------------------------------------------------------------------------

const braille_utf8 = blk: {
    var t: [256][3]u8 = undefined;
    for (0..256) |i| {
        t[i] = .{ 0xE2, 0xA0 + @as(u8, @intCast(i >> 6)), 0x80 + @as(u8, @intCast(i & 0x3F)) };
    }
    break :blk t;
};

// dot (x in 0..1, y in 0..3) -> bit of the braille pattern
const dot_bit = [2][4]u8{ .{ 0x01, 0x02, 0x04, 0x40 }, .{ 0x08, 0x10, 0x20, 0x80 } };

/// A grid of braille dots covering a Rect: 2 dots per column, 4 per row.
const Canvas = struct {
    r: Rect,
    w: usize, // dots
    h: usize,
    mask: []u8,
    color: []Color,

    fn init(a: Allocator, r: Rect, fg: Color) ?Canvas {
        if (r.w == 0 or r.h == 0) return null;
        const cells = @as(usize, r.w) * r.h;
        const mask = a.alloc(u8, cells) catch return null;
        const color = a.alloc(Color, cells) catch return null;
        @memset(mask, 0);
        @memset(color, fg);
        return .{ .r = r, .w = @as(usize, r.w) * 2, .h = @as(usize, r.h) * 4, .mask = mask, .color = color };
    }

    fn set(self: Canvas, x: i64, y: i64, c: Color) void {
        if (x < 0 or y < 0 or x >= self.w or y >= self.h) return;
        const ux: usize = @intCast(x);
        const uy: usize = @intCast(y);
        const cell = (uy / 4) * @as(usize, self.r.w) + ux / 2;
        self.mask[cell] |= dot_bit[ux % 2][uy % 4];
        self.color[cell] = c;
    }

    /// Bresenham; `dash` > 0 skips every other `dash` dots.
    fn line(self: Canvas, x0: i64, y0: i64, x1: i64, y1: i64, c: Color, dash: u8) void {
        var x = x0;
        var y = y0;
        const dx: i64 = @intCast(@abs(x1 - x0));
        const dy: i64 = -@as(i64, @intCast(@abs(y1 - y0)));
        const sx: i64 = if (x0 < x1) 1 else -1;
        const sy: i64 = if (y0 < y1) 1 else -1;
        var err = dx + dy;
        var step: u32 = 0;
        while (true) {
            if (dash == 0 or (step / dash) % 2 == 0) self.set(x, y, c);
            if (x == x1 and y == y1) break;
            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                x += sx;
            }
            if (e2 <= dx) {
                err += dx;
                y += sy;
            }
            step += 1;
        }
    }

    fn blob(self: Canvas, x: i64, y: i64, c: Color) void {
        self.set(x, y, c);
        self.set(x + 1, y, c);
        self.set(x, y + 1, c);
        self.set(x + 1, y + 1, c);
    }

    fn flush(self: Canvas, win: vaxis.Window, bg: Color) void {
        var cy: u16 = 0;
        while (cy < self.r.h) : (cy += 1) {
            var cx: u16 = 0;
            while (cx < self.r.w) : (cx += 1) {
                const i = @as(usize, cy) * self.r.w + cx;
                const m = self.mask[i];
                if (m == 0) continue;
                put(win, self.r.x + cx, self.r.y + cy, &braille_utf8[m], self.color[i], bg);
            }
        }
    }
};

fn axisWidth(win: vaxis.Window, y_top: []const u8) u16 {
    if (y_top.len == 0) return 0;
    return @min(win.gwidth(y_top) + 1, 7);
}

fn axisLabels(win: vaxis.Window, r: Rect, plot_bottom_y: u16, axis_w: u16, y_top: []const u8, bg: Color) void {
    if (axis_w == 0) return;
    const st: theme.Style = .{ .fg = theme.bone_faint, .bg = bg };
    _ = draw.text(win, r.x, r.y, axis_w - 1, y_top, st);
    _ = draw.text(win, r.x, plot_bottom_y, axis_w - 1, "0", st);
}

// ---- vertical columns (bar chart / histogram) -----------------------------------------------------------

pub const Column = struct {
    value: f64,
    color: Color,
    label: []const u8 = "",
    /// printed just above the bar when there is room
    top: []const u8 = "",
    /// a reference tick on the same scale (e.g. the same weekday last week)
    ref: ?f64 = null,
    bold_label: bool = false,
};

pub const ColumnsOpts = struct {
    max: f64,
    /// dashed horizontal line on the same scale (a goal or an average)
    line: ?f64 = null,
    line_color: Color = theme.bone_faint,
    ref_color: Color = theme.p3,
    label_color: Color = theme.bone_dim,
    /// text for the top of the y axis ("6h"); the bottom is always 0
    y_top: []const u8 = "",
    /// draw labels starting at the left edge of their column and let them spill over
    /// the neighbours (for sparse labels such as hours of the day)
    label_left: bool = false,
};

pub fn columns(win: vaxis.Window, r: Rect, bg: Color, cols: []const Column, o: ColumnsOpts) void {
    if (cols.len == 0 or r.h < 3 or r.w < cols.len) return;
    const axis_w = axisWidth(win, o.y_top);
    if (r.w <= axis_w) return;
    const plot_x = r.x + axis_w;
    const plot_w = r.w - axis_w;
    const n: u16 = @intCast(cols.len);
    const slot = plot_w / n;
    if (slot == 0) return;
    const gap: u16 = if (slot >= 3) 1 else 0;
    const bar_w: u16 = @min(slot - gap, 7);
    const pad: u16 = (slot - bar_w) / 2;
    const plot_h: u16 = r.h - 1; // the bottom row holds the labels
    const bottom: u16 = r.y + plot_h - 1;
    const max = if (o.max > 0) o.max else 1;

    axisLabels(win, r, bottom, axis_w, o.y_top, bg);

    if (o.line) |lv| {
        const k: u16 = @intFromFloat(@round(clamp01(lv / max) * @as(f64, @floatFromInt(plot_h - 1))));
        var x: u16 = 0;
        while (x < plot_w) : (x += 1) put(win, plot_x + x, bottom - k, "╌", o.line_color, bg);
    }

    for (cols, 0..) |c, i| {
        const sx: u16 = plot_x + @as(u16, @intCast(i)) * slot;
        const bx = sx + pad;
        var e = eighths(c.value / max, plot_h);
        if (c.value > 0 and e == 0) e = 1;
        var k: u16 = 0;
        while (k < plot_h) : (k += 1) {
            const cell: usize = @min(e -| (@as(usize, k) * 8), 8);
            if (cell == 0) break;
            var x: u16 = 0;
            while (x < bar_w) : (x += 1) put(win, bx + x, bottom - k, v_blocks[cell], c.color, bg);
        }
        if (c.ref) |rv| {
            const re = eighths(rv / max, plot_h);
            const rk: u16 = @intCast(@min(re / 8, plot_h - 1));
            const covered = e > @as(usize, rk) * 8;
            var x: u16 = 0;
            while (x < bar_w) : (x += 1) put(win, bx + x, bottom - rk, "━", o.ref_color, if (covered) c.color else bg);
        }
        if (c.top.len > 0) {
            const rows_used: u16 = @intCast((e + 7) / 8);
            if (rows_used < plot_h) {
                const ty = bottom - rows_used;
                centered(win, sx, ty, slot, c.top, .{ .fg = theme.bone_dim, .bg = bg });
            }
        }
        if (c.label.len > 0 and o.label_left) {
            const room = plot_x + plot_w - sx;
            _ = draw.text(win, sx, r.y + plot_h, @min(room, 6), c.label, .{ .fg = if (c.bold_label) theme.bone else o.label_color, .bg = bg, .bold = c.bold_label });
        } else if (c.label.len > 0) {
            centered(win, sx, r.y + plot_h, slot, c.label, .{ .fg = if (c.bold_label) theme.bone else o.label_color, .bg = bg, .bold = c.bold_label });
        }
    }
}

// ---- horizontal bars -----------------------------------------------------------------------------------

pub const HBar = struct {
    label: []const u8,
    value: f64,
    color: Color,
    /// right-hand text: the number behind the bar
    text: []const u8 = "",
    label_color: Color = theme.bone_dim,
};

/// One bar per `step` rows. `max` is the value that fills the whole bar.
pub fn hbars(win: vaxis.Window, r: Rect, bg: Color, rows: []const HBar, max_in: f64, label_w: u16, text_w: u16, step: u16) void {
    if (r.w < label_w + text_w + 4 or r.h == 0) return;
    const max = if (max_in > 0) max_in else 1;
    const bar_w: u16 = r.w - label_w - text_w - 2;
    const x0 = r.x + label_w + 1;
    var i: u16 = 0;
    for (rows) |row| {
        const y = r.y + i * step;
        if (y >= r.y + r.h) break;
        i += 1;
        _ = draw.text(win, r.x, y, label_w, row.label, .{ .fg = row.label_color, .bg = bg });
        // track, then the filled part on top of it
        var x: u16 = 0;
        while (x < bar_w) : (x += 1) put(win, x0 + x, y, " ", theme.bone, track);
        const e = eighths(row.value / max, bar_w);
        var cell: u16 = 0;
        while (cell * 8 < e) : (cell += 1) {
            const part = @min(e - @as(usize, cell) * 8, 8);
            put(win, x0 + cell, y, h_blocks[part], row.color, track);
        }
        if (row.text.len > 0) _ = draw.text(win, x0 + bar_w + 1, y, text_w, row.text, .{ .fg = theme.bone, .bg = bg });
    }
}

// ---- stacked bar -----------------------------------------------------------------------------------------

pub const Part = struct { value: f64, color: Color };

/// A single bar split into coloured parts, with sub-cell precision: the cell where
/// two parts meet is a partial block drawn in the left colour over the right one.
pub fn stacked(win: vaxis.Window, r: Rect, bg: Color, parts: []const Part) void {
    if (r.w == 0 or r.h == 0 or parts.len == 0) return;
    var total: f64 = 0;
    for (parts) |p| total += @max(p.value, 0);
    var y: u16 = 0;
    while (y < r.h) : (y += 1) {
        var x: u16 = 0;
        while (x < r.w) : (x += 1) put(win, r.x + x, r.y + y, " ", theme.bone, track);
    }
    if (total <= 0) return;

    const total_e: f64 = @floatFromInt(@as(usize, r.w) * 8);
    var bounds: [16]usize = undefined; // cumulative end of each part, in eighths
    const np = @min(parts.len, bounds.len);
    var acc: f64 = 0;
    for (parts[0..np], 0..) |p, i| {
        acc += @max(p.value, 0);
        bounds[i] = if (i == np - 1) @as(usize, r.w) * 8 else @intFromFloat(@round(acc / total * total_e));
    }
    var cx: u16 = 0;
    while (cx < r.w) : (cx += 1) {
        const s: usize = @as(usize, cx) * 8;
        var li: usize = 0;
        while (li < np - 1 and bounds[li] <= s) li += 1;
        var ri: usize = li;
        while (ri < np - 1 and bounds[ri] < s + 8) ri += 1;
        var row: u16 = 0;
        while (row < r.h) : (row += 1) {
            if (li == ri) {
                put(win, r.x + cx, r.y + row, "█", parts[li].color, bg);
            } else {
                const left = bounds[li] - s;
                put(win, r.x + cx, r.y + row, h_blocks[@min(left, 8)], parts[li].color, parts[ri].color);
            }
        }
    }
}

// ---- gauge & sparkline --------------------------------------------------------------------------------------

/// A one-row progress bar on a dark track.
pub fn gauge(win: vaxis.Window, r: Rect, frac: f64, color: Color) void {
    if (r.w == 0 or r.h == 0) return;
    var x: u16 = 0;
    while (x < r.w) : (x += 1) put(win, r.x + x, r.y, " ", theme.bone, track);
    const e = eighths(frac, r.w);
    var cell: u16 = 0;
    while (cell * 8 < e) : (cell += 1) {
        const part = @min(e - @as(usize, cell) * 8, 8);
        put(win, r.x + cell, r.y, h_blocks[part], color, track);
    }
}

/// "▁▃▅▇▅▂": one block per value, scaled to `max` (or to the largest value when max is 0).
pub fn spark(a: Allocator, values: []const f64, max_in: f64) []const u8 {
    var max = max_in;
    if (max <= 0) for (values) |v| {
        max = @max(max, v);
    };
    var buf: std.ArrayList(u8) = .empty;
    for (values) |v| {
        const lvl: usize = if (max > 0) @intFromFloat(@round(clamp01(v / max) * 8)) else 0;
        const g = if (v > 0 and lvl == 0) v_blocks[1] else v_blocks[lvl];
        buf.appendSlice(a, if (lvl == 0 and v <= 0) "▁" else g) catch {};
    }
    return buf.items;
}

// ---- line chart (braille) ---------------------------------------------------------------------------------

pub const Next = struct { value: f64, lo: ?f64 = null, hi: ?f64 = null };

pub const LineOpts = struct {
    max: f64,
    color: Color = theme.bone,
    /// dotted horizontal reference line (a goal)
    goal: ?f64 = null,
    goal_color: Color = theme.bone_faint,
    /// one more point after the series: a forecast, optionally with an 80% range
    next: ?Next = null,
    next_color: Color = theme.p2,
    y_top: []const u8 = "",
    x_left: []const u8 = "",
    x_right: []const u8 = "",
};

pub fn line(win: vaxis.Window, a: Allocator, r: Rect, bg: Color, values: []const f64, o: LineOpts) void {
    if (values.len == 0 or r.h < 3 or r.w < 8) return;
    const axis_w = axisWidth(win, o.y_top);
    const has_x = o.x_left.len > 0 or o.x_right.len > 0;
    if (r.w <= axis_w + 4) return;
    const plot: Rect = .{ .x = r.x + axis_w, .y = r.y, .w = r.w - axis_w, .h = if (has_x) r.h - 1 else r.h };
    const cv = Canvas.init(a, plot, o.color) orelse return;
    const max = if (o.max > 0) o.max else 1;
    const n: usize = values.len + @as(usize, if (o.next != null) 1 else 0);
    const W: i64 = @intCast(cv.w);
    const H: i64 = @intCast(cv.h);

    if (o.goal) |g| {
        const gy = yDot(g, max, H);
        var x: i64 = 0;
        while (x < W) : (x += 3) cv.set(x, gy, o.goal_color);
    }

    var px: i64 = 0;
    var py: i64 = 0;
    for (values, 0..) |v, i| {
        const x = xDot(i, n, W);
        const y = yDot(v, max, H);
        if (i > 0) cv.line(px, py, x, y, o.color, 0);
        px = x;
        py = y;
    }
    for (values, 0..) |v, i| cv.blob(xDot(i, n, W) - @as(i64, if (i + 1 == n) 1 else 0), yDot(v, max, H) - 1, o.color);

    if (o.next) |nx| {
        const x = xDot(n - 1, n, W);
        const y = yDot(nx.value, max, H);
        cv.line(px, py, x, y, o.next_color, 2);
        if (nx.lo != null and nx.hi != null) {
            const y_lo = yDot(nx.lo.?, max, H);
            const y_hi = yDot(nx.hi.?, max, H);
            cv.line(x - 1, y_hi, x - 1, y_lo, o.next_color, 1);
            cv.line(x - 3, y_hi, x + 0, y_hi, o.next_color, 0);
            cv.line(x - 3, y_lo, x + 0, y_lo, o.next_color, 0);
        }
        cv.blob(x - 2, y - 1, o.next_color);
        cv.blob(x - 2, y, o.next_color);
    }
    cv.flush(win, bg);

    axisLabels(win, r, plot.y + plot.h - 1, axis_w, o.y_top, bg);
    if (has_x) {
        const y = r.y + r.h - 1;
        const st: theme.Style = .{ .fg = theme.bone_faint, .bg = bg };
        _ = draw.text(win, plot.x, y, plot.w / 2, o.x_left, st);
        if (o.x_right.len > 0) _ = draw.textRight(win, r.x + r.w, y, o.x_right, st);
    }
}

fn xDot(i: usize, n: usize, w: i64) i64 {
    if (n <= 1) return @divTrunc(w, 2);
    const span: i64 = w - 3; // leave room for the point marker
    return @divTrunc(@as(i64, @intCast(i)) * span, @as(i64, @intCast(n - 1)));
}

fn yDot(v: f64, max: f64, h: i64) i64 {
    const top: i64 = 2; // keep markers inside the plot
    const span: f64 = @floatFromInt(h - 1 - top);
    return (h - 1) - @as(i64, @intFromFloat(@round(clamp01(v / max) * span)));
}

// ---- scatter (braille) -----------------------------------------------------------------------------------------

pub const Point = struct {
    /// both 0..1
    x: f64,
    y: f64,
    color: Color,
};

pub fn scatter(win: vaxis.Window, a: Allocator, r: Rect, bg: Color, pts: []const Point, y_top: []const u8, x_left: []const u8, x_right: []const u8) void {
    if (r.h < 3 or r.w < 8) return;
    const axis_w = axisWidth(win, y_top);
    const has_x = x_left.len > 0 or x_right.len > 0;
    if (r.w <= axis_w + 4) return;
    const plot: Rect = .{ .x = r.x + axis_w, .y = r.y, .w = r.w - axis_w, .h = if (has_x) r.h - 1 else r.h };
    const cv = Canvas.init(a, plot, theme.bone) orelse return;
    const W: i64 = @intCast(cv.w);
    const H: i64 = @intCast(cv.h);
    for (pts) |p| {
        const x: i64 = @intFromFloat(@round(clamp01(p.x) * @as(f64, @floatFromInt(W - 2))));
        const y: i64 = (H - 2) - @as(i64, @intFromFloat(@round(clamp01(p.y) * @as(f64, @floatFromInt(H - 2)))));
        cv.blob(x, y, p.color);
    }
    cv.flush(win, bg);
    axisLabels(win, r, plot.y + plot.h - 1, axis_w, y_top, bg);
    if (has_x) {
        const y = r.y + r.h - 1;
        const st: theme.Style = .{ .fg = theme.bone_faint, .bg = bg };
        _ = draw.text(win, plot.x, y, plot.w / 2, x_left, st);
        if (x_right.len > 0) _ = draw.textRight(win, r.x + r.w, y, x_right, st);
    }
}

// ---- donut (braille) ------------------------------------------------------------------------------------------------

/// A ring split into parts, clockwise from the top. The ring is as large as fits in `r`
/// and is centred in it. `hole` is the inner radius as a fraction of the outer one.
pub fn donut(win: vaxis.Window, a: Allocator, r: Rect, bg: Color, parts: []const Part, hole: f64) void {
    if (r.w < 4 or r.h < 2 or parts.len == 0) return;
    const cv = Canvas.init(a, r, theme.bone) orelse return;
    var total: f64 = 0;
    for (parts) |p| total += @max(p.value, 0);
    const np = @min(parts.len, 8);

    var ends: [8]f64 = undefined; // cumulative end angle of each part, 0..1 of a full turn
    var acc: f64 = 0;
    for (parts[0..np], 0..) |p, i| {
        acc += @max(p.value, 0);
        ends[i] = if (total > 0) acc / total else 0;
    }

    const rad: f64 = @as(f64, @floatFromInt(@min(cv.w, cv.h))) / 2.0;
    const cx: f64 = @as(f64, @floatFromInt(cv.w)) / 2.0;
    const cy: f64 = @as(f64, @floatFromInt(cv.h)) / 2.0;
    const inner = rad * std.math.clamp(hole, 0, 0.9);

    var counts = a.alloc([8]u8, cv.mask.len) catch return;
    @memset(counts, @splat(0));

    var y: usize = 0;
    while (y < cv.h) : (y += 1) {
        var x: usize = 0;
        while (x < cv.w) : (x += 1) {
            const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
            const d = @sqrt(dx * dx + dy * dy);
            if (d > rad or d < inner) continue;
            var turn = std.math.atan2(dx, -dy) / (2.0 * std.math.pi);
            if (turn < 0) turn += 1;
            var pi: usize = 0;
            if (total > 0) {
                while (pi < np - 1 and turn >= ends[pi]) pi += 1;
            }
            const cell = (y / 4) * @as(usize, r.w) + x / 2;
            cv.mask[cell] |= dot_bit[x % 2][y % 4];
            counts[cell][pi] +|= 1;
        }
    }
    // each cell takes the colour of the part that owns most of its dots
    for (cv.mask, 0..) |m, i| {
        if (m == 0) continue;
        var best: usize = 0;
        for (counts[i], 0..) |cnt, k| if (cnt > counts[i][best]) {
            best = k;
        };
        cv.color[i] = if (total > 0) parts[best].color else track;
    }
    cv.flush(win, bg);
}

// ---- heatmap (calendar) -------------------------------------------------------------------------------------------

pub const heat_levels = 5;

pub fn heatColor(level: usize) Color {
    return switch (level) {
        0 => .{ .rgb = .{ 40, 40, 46 } },
        1 => theme.fade(theme.ok, 38),
        2 => theme.fade(theme.ok, 58),
        3 => theme.fade(theme.ok, 80),
        else => theme.ok,
    };
}

pub fn heatLevel(value: f64, max: f64) usize {
    if (value <= 0 or max <= 0) return 0;
    return std.math.clamp(@as(usize, @intFromFloat(@ceil(value / max * 4))), 1, 4);
}

/// Calendar heatmap: one column per week (2 cells wide), one row per weekday.
/// `values[w][d]` is the amount for weekday d (Mon = 0) of week w, or null for a day that
/// hasn't happened yet. `labels[w]` is printed above week w when non-empty and room allows.
pub fn heatmap(win: vaxis.Window, r: Rect, bg: Color, values: []const [7]?f64, labels: []const []const u8, max: f64, today: ?struct { week: usize, day: usize }) void {
    const label_w: u16 = 4;
    if (r.h < 8 or r.w < label_w + 2 or values.len == 0) return;
    const weeks_fit: usize = (r.w - label_w) / 2;
    const shown = @min(values.len, weeks_fit);
    const first = values.len - shown;

    const names = [7][]const u8{ "Mon", "", "Wed", "", "Fri", "", "Sun" };
    for (names, 0..) |nm, d| {
        if (nm.len > 0) _ = draw.text(win, r.x, r.y + 1 + @as(u16, @intCast(d)), label_w - 1, nm, .{ .fg = theme.bone_faint, .bg = bg });
    }
    var next_label_x: u16 = 0;
    for (values[first..], first..) |wk, wi| {
        const x: u16 = r.x + label_w + @as(u16, @intCast(wi - first)) * 2;
        if (wi < labels.len and labels[wi].len > 0 and x >= next_label_x) {
            const used = draw.text(win, x, r.y, r.x + r.w - x, labels[wi], .{ .fg = theme.bone_faint, .bg = bg });
            next_label_x = x + used + 1;
        }
        for (wk, 0..) |maybe, d| {
            const y = r.y + 1 + @as(u16, @intCast(d));
            const v = maybe orelse continue;
            const is_today = if (today) |t| t.week == wi and t.day == d else false;
            const col = if (is_today and v <= 0) theme.bone_faint else heatColor(heatLevel(v, max));
            put(win, x, y, "■", col, bg);
        }
    }
}

// ---- test helper ------------------------------------------------------------------------------------------------------------

/// Plain-text copy of a screen (one line per row, trailing blanks trimmed).
pub fn dumpScreen(a: Allocator, screen: *const vaxis.Screen) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var y: u16 = 0;
    while (y < screen.height) : (y += 1) {
        const start = out.items.len;
        var x: u16 = 0;
        while (x < screen.width) : (x += 1) {
            const c = screen.readCell(x, y) orelse continue;
            const g = c.char.grapheme;
            try out.appendSlice(a, if (g.len == 0) " " else g);
        }
        while (out.items.len > start and out.items[out.items.len - 1] == ' ') _ = out.pop();
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

const testing = std.testing;

fn testWindow(screen: *vaxis.Screen) vaxis.Window {
    return .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = screen.width, .height = screen.height, .screen = screen };
}

test "columns draw proportional bars, labels and a goal line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 6, .cols = 20, .x_pixel = 0, .y_pixel = 0 });
    const win = testWindow(&screen);
    const cols = [_]Column{
        .{ .value = 4, .color = theme.bone, .label = "A" },
        .{ .value = 2, .color = theme.bone, .label = "B" },
        .{ .value = 0, .color = theme.bone, .label = "C" },
    };
    columns(win, .{ .x = 0, .y = 0, .w = 18, .h = 6 }, theme.glass, &cols, .{ .max = 4, .line = 1 });
    const text = try dumpScreen(a, &screen);
    var rows = std.mem.splitScalar(u8, text, '\n');
    var lines: [6][]const u8 = undefined;
    for (&lines) |*l| l.* = rows.next().?;
    try testing.expect(std.mem.indexOf(u8, lines[0], "█") != null); // tallest bar reaches the top
    try testing.expect(std.mem.indexOf(u8, lines[1], "█") != null);
    try testing.expect(std.mem.indexOf(u8, lines[3], "█") != null); // B is half height: rows 2-4
    try testing.expect(std.mem.indexOf(u8, lines[5], "A") != null);
    try testing.expect(std.mem.indexOf(u8, lines[5], "C") != null);
    try testing.expect(std.mem.indexOf(u8, lines[3], "╌") != null); // goal line at 1/4 height, visible beside the bars
}

test "stacked bar fills the whole width and splits at the right place" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 1, .cols = 10, .x_pixel = 0, .y_pixel = 0 });
    const win = testWindow(&screen);
    const red: Color = .{ .rgb = .{ 200, 0, 0 } };
    const blue: Color = .{ .rgb = .{ 0, 0, 200 } };
    stacked(win, .{ .x = 0, .y = 0, .w = 10, .h = 1 }, theme.glass, &.{ .{ .value = 25, .color = red }, .{ .value = 75, .color = blue } });
    // 25% of 10 cells = 2.5 cells: cells 0,1 red, cell 2 half red over blue, 3.. blue
    try testing.expectEqualStrings("█", screen.readCell(1, 0).?.char.grapheme);
    try testing.expectEqualStrings("▌", screen.readCell(2, 0).?.char.grapheme);
    try testing.expect(std.meta.eql(screen.readCell(2, 0).?.style.fg, red));
    try testing.expect(std.meta.eql(screen.readCell(2, 0).?.style.bg, blue));
    try testing.expect(std.meta.eql(screen.readCell(9, 0).?.style.fg, blue));
}

test "donut, line and scatter stay inside their rectangle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = try vaxis.Screen.init(a, .{ .rows = 12, .cols = 40, .x_pixel = 0, .y_pixel = 0 });
    const win = testWindow(&screen);
    const box: Rect = .{ .x = 5, .y = 2, .w = 20, .h = 8 };
    donut(win, a, box, theme.glass, &.{ .{ .value = 1, .color = theme.p1 }, .{ .value = 2, .color = theme.p2 }, .{ .value = 1, .color = theme.p3 } }, 0.6);
    line(win, a, box, theme.glass, &.{ 1, 3, 2, 4, 3 }, .{ .max = 4, .next = .{ .value = 3, .lo = 2, .hi = 4 }, .goal = 3, .y_top = "4h", .x_left = "a", .x_right = "b" });
    scatter(win, a, box, theme.glass, &.{ .{ .x = 0, .y = 0, .color = theme.p1 }, .{ .x = 1, .y = 1, .color = theme.p2 } }, "", "", "");
    var y: u16 = 0;
    while (y < screen.height) : (y += 1) {
        var x: u16 = 0;
        while (x < screen.width) : (x += 1) {
            const inside = x >= box.x and x < box.x + box.w and y >= box.y and y < box.y + box.h;
            if (!inside) try testing.expectEqualStrings(" ", screen.readCell(x, y).?.char.grapheme);
        }
    }
    const text = try dumpScreen(a, &screen);
    try testing.expect(std.mem.indexOf(u8, text, "⣿") != null or std.mem.indexOf(u8, text, "⠿") != null or text.len > 100);
}

test "heat levels" {
    try testing.expectEqual(@as(usize, 0), heatLevel(0, 5));
    try testing.expectEqual(@as(usize, 1), heatLevel(0.1, 5));
    try testing.expectEqual(@as(usize, 2), heatLevel(2.0, 5));
    try testing.expectEqual(@as(usize, 3), heatLevel(2.6, 5));
    try testing.expectEqual(@as(usize, 4), heatLevel(5, 5));
    try testing.expectEqual(@as(usize, 4), heatLevel(50, 5));
}

test "sparkline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("▁▄█", spark(arena.allocator(), &.{ 0, 2, 4 }, 0));
}
