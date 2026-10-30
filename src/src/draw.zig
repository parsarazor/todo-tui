//! Small drawing primitives on top of vaxis.Window. Everything takes
//! absolute (root-window) coordinates so hit-testing and drawing agree.
const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,

    pub fn contains(r: Rect, col: i32, row: i32) bool {
        return col >= r.x and col < @as(i32, r.x) + r.w and
            row >= r.y and row < @as(i32, r.y) + r.h;
    }

    pub fn inset(r: Rect, dx: u16, dy: u16) Rect {
        if (r.w <= 2 * dx or r.h <= 2 * dy) return .{ .x = r.x + dx, .y = r.y + dy };
        return .{ .x = r.x + dx, .y = r.y + dy, .w = r.w - 2 * dx, .h = r.h - 2 * dy };
    }
};

fn sub(win: vaxis.Window, r: Rect) ?vaxis.Window {
    if (r.w == 0 or r.h == 0) return null;
    return win.child(.{ .x_off = @intCast(r.x), .y_off = @intCast(r.y), .width = r.w, .height = r.h });
}

pub fn fill(win: vaxis.Window, r: Rect, bg: theme.Color) void {
    const c = sub(win, r) orelse return;
    c.fill(.{ .style = .{ .bg = bg } });
}

const Glyphs = struct { tl: []const u8, t: []const u8, tr: []const u8, v: []const u8, br: []const u8, bl: []const u8 };
const rounded: Glyphs = .{ .tl = "╭", .t = "─", .tr = "╮", .v = "│", .br = "╯", .bl = "╰" };
const heavy: Glyphs = .{ .tl = "┏", .t = "━", .tr = "┓", .v = "┃", .br = "┛", .bl = "┗" };

fn put(win: vaxis.Window, x: u16, y: u16, g: []const u8, style: theme.Style) void {
    win.writeCell(x, y, .{ .char = .{ .grapheme = g, .width = 1 }, .style = style });
}

/// Filled panel with a 1-cell outline.
pub fn box(win: vaxis.Window, r: Rect, line: theme.Color, bg: theme.Color, thick: bool, bold: bool) void {
    if (r.w < 2 or r.h < 2) return;
    fill(win, r, bg);
    const g = if (thick) heavy else rounded;
    const st: theme.Style = .{ .fg = line, .bg = bg, .bold = bold };
    const right = r.x + r.w - 1;
    const bottom = r.y + r.h - 1;
    var i: u16 = r.x + 1;
    while (i < right) : (i += 1) {
        put(win, i, r.y, g.t, st);
        put(win, i, bottom, g.t, st);
    }
    i = r.y + 1;
    while (i < bottom) : (i += 1) {
        put(win, r.x, i, g.v, st);
        put(win, right, i, g.v, st);
    }
    put(win, r.x, r.y, g.tl, st);
    put(win, right, r.y, g.tr, st);
    put(win, r.x, bottom, g.bl, st);
    put(win, right, bottom, g.br, st);
}

/// Print one line of text clipped to `max_w` columns, with an ellipsis when cut.
/// Returns the number of columns used.
pub fn text(win: vaxis.Window, x: u16, y: u16, max_w: u16, str: []const u8, style: theme.Style) u16 {
    if (max_w == 0 or x >= win.width or y >= win.height) return 0;
    const line_win = win.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = max_w, .height = 1 });
    const total = line_win.gwidth(str);
    if (total <= max_w) {
        _ = line_win.printSegment(.{ .text = str, .style = style }, .{ .wrap = .none });
        return total;
    }
    // Truncate on code point boundaries, leaving one column for the ellipsis.
    var used: u16 = 0;
    var end: usize = 0;
    const view = std.unicode.Utf8View.init(str) catch {
        _ = line_win.printSegment(.{ .text = str, .style = style }, .{ .wrap = .none });
        return max_w;
    };
    var it = view.iterator();
    while (it.nextCodepointSlice()) |cp| {
        const w = line_win.gwidth(cp);
        if (used + w > max_w -| 1) break;
        used += w;
        end += cp.len;
    }
    _ = line_win.printSegment(.{ .text = str[0..end], .style = style }, .{ .wrap = .none });
    _ = line_win.printSegment(.{ .text = "…", .style = style }, .{ .wrap = .none, .col_offset = used });
    return used + 1;
}

/// Right-aligned variant; returns the x where the text starts.
pub fn textRight(win: vaxis.Window, right_edge: u16, y: u16, str: []const u8, style: theme.Style) u16 {
    const w = win.gwidth(str);
    const x = right_edge -| w;
    _ = text(win, x, y, w, str, style);
    return x;
}

/// Like `text` but clipped silently (no ellipsis): for wrapped paragraphs where
/// a trailing space may hang one column past the edge.
pub fn raw(win: vaxis.Window, x: u16, y: u16, max_w: u16, str: []const u8, style: theme.Style) void {
    if (max_w == 0 or x >= win.width or y >= win.height) return;
    const line_win = win.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = max_w, .height = 1 });
    _ = line_win.printSegment(.{ .text = str, .style = style }, .{ .wrap = .none });
}
