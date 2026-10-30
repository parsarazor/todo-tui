//! All colours in one place. Pure black canvas, near-black "glass" panels,
//! bone-white text; the priority colours are muted so they read as outlines,
//! not as neon.
const vaxis = @import("vaxis");
const model = @import("model.zig");

pub const Color = vaxis.Color;
pub const Style = vaxis.Style;

pub const black: Color = .{ .rgb = .{ 0, 0, 0 } };
pub const glass: Color = .{ .rgb = .{ 11, 11, 14 } }; // panel surface
pub const glass_hi: Color = .{ .rgb = .{ 27, 27, 32 } }; // selected / raised surface
pub const glass_sheen: Color = .{ .rgb = .{ 18, 18, 22 } }; // title strip

pub const bone: Color = .{ .rgb = .{ 227, 218, 201 } }; // main text
pub const bone_dim: Color = .{ .rgb = .{ 146, 140, 127 } }; // secondary text
pub const bone_faint: Color = .{ .rgb = .{ 84, 81, 75 } }; // tertiary / done

pub const line: Color = .{ .rgb = .{ 54, 54, 60 } }; // idle border
pub const line_focus: Color = .{ .rgb = .{ 168, 161, 146 } }; // focused neutral border

pub const p1: Color = .{ .rgb = .{ 212, 88, 78 } }; // urgent + important
pub const p2: Color = .{ .rgb = .{ 219, 172, 82 } }; // important
pub const p3: Color = .{ .rgb = .{ 98, 150, 208 } }; // urgent
pub const p4: Color = .{ .rgb = .{ 126, 148, 128 } }; // neither
pub const ok: Color = .{ .rgb = .{ 112, 168, 122 } }; // done accent

pub fn priorityColor(p: u8) Color {
    return switch (p) {
        1 => p1,
        2 => p2,
        3 => p3,
        else => p4,
    };
}

/// Scale an rgb colour toward black. `pct` is 0..100.
pub fn fade(c: Color, pct: u8) Color {
    return switch (c) {
        .rgb => |v| .{ .rgb = .{
            @intCast(@as(u16, v[0]) * pct / 100),
            @intCast(@as(u16, v[1]) * pct / 100),
            @intCast(@as(u16, v[2]) * pct / 100),
        } },
        else => c,
    };
}

pub fn zoneAccent(z: model.Zone) Color {
    return switch (z) {
        .q1 => p1,
        .q2 => p2,
        .q3 => p3,
        .q4 => p4,
        .doing => bone,
        .done => ok,
    };
}

pub fn plain(fg: Color, bg: Color) Style {
    return .{ .fg = fg, .bg = bg };
}
