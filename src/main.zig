const std = @import("std");
const vaxis = @import("vaxis");
const storage = @import("storage.zig");
const worklog = @import("worklog.zig");
const settings = @import("settings.zig");
const input = @import("input.zig");
const ui = @import("ui.zig");
const App = @import("state.zig").App;

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    // Bracketed paste arrives as paste_start, the text as ordinary key presses, paste_end.
    paste_start,
    paste_end,
    tick, // once a second, so running timers move
};

fn tickLoop(io: std.Io, loop: *vaxis.Loop(Event)) std.Io.Cancelable!void {
    while (true) {
        try io.sleep(.fromSeconds(1), .awake);
        _ = loop.tryPostEvent(.tick) catch return; // queue closed -> we're quitting
    }
}

/// Report a data file we can't use and stop, without touching it and without a stack trace.
fn fatal(io: std.Io, alloc: std.mem.Allocator, path: []const u8, err: anyerror) noreturn {
    if (err == error.BadFormat) {
        const first = storage.firstLine(io, alloc, path) catch "";
        std.debug.print(
            "kanban: {s} is not a kanban file (it starts with \"{s}\").\n" ++
                "Nothing was changed. To start fresh, move it aside:\n    mv \"{s}\" \"{s}.bak\"\n",
            .{ path, first, path, path },
        );
    } else {
        std.debug.print("kanban: cannot read {s}: {s}\n", .{ path, @errorName(err) });
    }
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    const path = try storage.resolvePath(io, alloc, init.environ_map);
    defer alloc.free(path);

    const notes_path = try std.fmt.allocPrint(alloc, "{s}.notes", .{path});
    defer alloc.free(notes_path);

    const log_path = try std.fmt.allocPrint(alloc, "{s}.log", .{path});
    defer alloc.free(log_path);
    const settings_path = try std.fmt.allocPrint(alloc, "{s}.settings", .{path});
    defer alloc.free(settings_path);

    var app = App.init(alloc, io, .{ .board = path, .notes = notes_path, .log = log_path, .settings = settings_path });
    defer app.deinit();
    settings.load(io, alloc, settings_path, &app.params) catch {}; // unreadable settings: keep the defaults
    worklog.load(io, alloc, log_path, &app.worklog) catch |err| fatal(io, alloc, log_path, err);
    const report = storage.load(io, alloc, path, &app.board, app.now) catch |err| fatal(io, alloc, path, err);
    const notice: ?[]u8 = if (report.version == 3)
        std.fmt.allocPrint(alloc, "imported {d} tasks from a KANBAN3 board{s}. Your original is kept as {s}.kanban3.bak", .{
            report.tasks,
            if (report.skipped > 0) std.fmt.allocPrint(alloc, " ({d} other {s} stay only in the backup)", .{ report.skipped, if (report.skipped == 1) "line" else "lines" }) catch "" else "",
            std.fs.path.basename(path),
        }) catch null
    else
        null;
    defer if (notice) |n| alloc.free(n);
    if (notice) |n| {
        app.flash = n;
        app.flash_info = true;
    }
    app.brain.load() catch |err| fatal(io, alloc, notes_path, err);
    try app.refresh();
    app.focusZone(.q1, 0);

    var buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, alloc, init.environ_map, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    var ticker = try io.concurrent(tickLoop, .{ io, &loop });
    defer ticker.cancel(io) catch {};

    try vx.enterAltScreen(writer);
    try vx.setMouseMode(writer, true);
    try vx.setBracketedPaste(writer, true);
    defer vx.setBracketedPaste(writer, false) catch {};
    try writer.flush();
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    // While a paste is in flight we collect its keys and insert them in one go:
    // a pasted newline must be text, not "Enter", and one redraw beats thousands.
    var pasting = false;
    var paste_buf: std.ArrayList(u8) = .empty;
    defer paste_buf.deinit(alloc);

    while (!app.quit) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (pasting) {
                    try input.collectPaste(&paste_buf, alloc, key);
                    continue;
                }
                try input.handleKey(&app, key);
            },
            .paste_start => {
                pasting = true;
                paste_buf.clearRetainingCapacity();
                continue;
            },
            .paste_end => {
                pasting = false;
                try input.handlePaste(&app, paste_buf.items);
            },
            .mouse => |m| try input.handleMouse(&app, vx.translateMouse(m)),
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
            .tick => {
                app.tickClock();
                // autosave notes at most one second after the last keystroke
                const was_dirty = app.brain.isDirty();
                app.brain.flush();
                // nothing running (and no "saving…" label to clear): skip the redraw entirely
                if (!app.hasRunning() and !(was_dirty and app.mode == .brainstorm)) continue;
            },
        }
        app.tickClock();
        try app.refresh();

        _ = app.frame_arena.reset(.retain_capacity);
        const win = vx.window();
        win.clear();
        ui.render(&app, win, app.frame_arena.allocator());
        try vx.render(writer);
        try writer.flush();
    }
    app.brain.flush();
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("model.zig");
    _ = @import("dates.zig");
    _ = @import("editor.zig");
    _ = @import("notes.zig");
    _ = @import("worklog.zig");
    _ = @import("stats.zig");
    _ = @import("settings.zig");
}
