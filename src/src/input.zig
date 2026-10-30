//! Translates raw vaxis key / mouse events into App operations.
const std = @import("std");
const vaxis = @import("vaxis");
const model = @import("model.zig");
const App = @import("state.zig").App;

const double_click_ns: i96 = 400 * std.time.ns_per_ms;

pub fn handleKey(app: *App, key: vaxis.Key) !void {
    switch (app.mode) {
        .form => return handleFormKey(app, key),
        .confirm_delete => {
            if (key.matches('y', .{}) or key.matches('Y', .{})) app.deleteSelected();
            app.mode = .normal;
            return;
        },
        .help => {
            app.mode = .normal;
            return;
        },
        .brainstorm => {
            switch (try app.brain.handleKey(key)) {
                .none => {},
                .close => app.mode = .normal,
                .quit => app.quit = true,
            }
            return;
        },
        .log => {
            switch (app.logbook.handleKey(key, &app.params)) {
                .none => {},
                .close => app.mode = .normal,
                .quit => app.quit = true,
                .params_changed => app.saveParams(),
            }
            return;
        },
        .normal => {},
    }
    app.flash = null;
    app.flash_info = false;
    const K = vaxis.Key;

    if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) {
        app.quit = true;
        return;
    }

    // Move the selected task to the neighbouring zone (Shift+arrows or H J K L).
    if (key.matches(K.left, .{ .shift = true }) or key.matches('H', .{})) return app.moveTask(.left);
    if (key.matches(K.right, .{ .shift = true }) or key.matches('L', .{})) return app.moveTask(.right);
    if (key.matches(K.up, .{ .shift = true }) or key.matches('K', .{})) return app.moveTask(.up);
    if (key.matches(K.down, .{ .shift = true }) or key.matches('J', .{})) return app.moveTask(.down);

    // Move the cursor.
    if (key.matches(K.left, .{}) or key.matches('h', .{})) return app.moveCursor(.left);
    if (key.matches(K.right, .{}) or key.matches('l', .{})) return app.moveCursor(.right);
    if (key.matches(K.up, .{}) or key.matches('k', .{})) return app.moveCursor(.up);
    if (key.matches(K.down, .{}) or key.matches('j', .{})) return app.moveCursor(.down);
    if (key.matches(K.tab, .{})) return app.moveCursor(.right);

    if (key.matches('n', .{})) return app.openNew();
    if (key.matches('b', .{})) return app.openBrainstorm();
    if (key.matches('s', .{})) return app.openLog();
    if (key.matches('e', .{}) or key.matches(K.enter, .{})) return app.openEdit();
    if (key.matches('x', .{}) or key.matches(K.delete, .{})) {
        if (app.sel != null) app.mode = .confirm_delete;
        return;
    }
    if (key.matches(K.space, .{})) return app.advance();
    if (key.matches('?', .{})) {
        app.mode = .help;
        return;
    }
    inline for ("1234") |c| {
        if (key.matches(@as(u21, c), .{})) return app.setPriority(c - '0');
    }
}

fn handleFormKey(app: *App, key: vaxis.Key) !void {
    const form = &(app.form orelse return);
    switch (try form.handleKey(key)) {
        .none => {},
        .cancel => app.closeForm(),
        .save => try app.submitForm(),
    }
}

const max_paste = 1024 * 1024;

/// Turn one key event received during a bracketed paste back into text.
/// Enter becomes CR and ctrl+J becomes LF so a CRLF pair collapses to one newline downstream.
pub fn collectPaste(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, key: vaxis.Key) !void {
    if (buf.items.len >= max_paste) return;
    if (key.matches(vaxis.Key.enter, .{})) return buf.append(alloc, '\r');
    if (key.matches('j', .{ .ctrl = true })) return buf.append(alloc, '\n');
    if (key.matches(vaxis.Key.tab, .{})) return buf.append(alloc, '\t');
    if (key.text) |t| return buf.appendSlice(alloc, t);
    if (key.codepoint >= 0x20 and !key.mods.ctrl and !key.mods.alt) {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(key.codepoint, &tmp) catch return;
        try buf.appendSlice(alloc, tmp[0..n]);
    }
}

/// Bracketed paste: goes to whichever text field is active.
pub fn handlePaste(app: *App, text: []const u8) !void {
    switch (app.mode) {
        .brainstorm => try app.brain.handlePaste(text),
        .form => if (app.form) |*f| try f.paste(text),
        else => {},
    }
}

pub fn handleMouse(app: *App, m: vaxis.Mouse) !void {
    if (app.mode == .brainstorm) return app.brain.handleMouse(m);
    if (app.mode == .log) return app.logbook.handleMouse(m);
    if (app.mode != .normal) return;
    const col: i32 = m.col;
    const row: i32 = m.row;

    switch (m.type) {
        .press => switch (m.button) {
            .left => {
                if (app.cardAt(col, row)) |id| {
                    app.select(id);
                    app.drag = .{ .id = id, .sx = col, .sy = row, .col = col, .row = row };

                    const now = std.Io.Clock.awake.now(app.io).nanoseconds;
                    if (app.last_click_id == id and now - app.last_click_ns < double_click_ns) {
                        app.drag = null;
                        app.last_click_id = null;
                        return app.openEdit();
                    }
                    app.last_click_id = id;
                    app.last_click_ns = now;
                } else if (app.zoneAt(col, row)) |z| {
                    app.focusZone(z, 0);
                    app.last_click_id = null;
                }
            },
            .wheel_up, .wheel_down => {
                const z = app.zoneAt(col, row) orelse return;
                const zi = z.index();
                const len = app.lists[zi].len;
                const cap = @max(app.capacity[zi], 1);
                const max_scroll = len -| cap;
                if (m.button == .wheel_up) {
                    app.scroll[zi] -|= 1;
                } else {
                    app.scroll[zi] = @min(app.scroll[zi] + 1, max_scroll);
                }
            },
            else => {},
        },
        .drag, .motion => {
            if (app.drag) |*d| {
                d.col = col;
                d.row = row;
                if (!d.active and (col != d.sx or row != d.sy)) d.active = true;
            }
        },
        .release => {
            if (app.drag) |d| {
                app.drag = null;
                if (d.active) {
                    if (app.zoneAt(d.col, d.row)) |z| app.moveTaskTo(d.id, z);
                }
            }
        },
    }
}
