//! Application state and every operation that changes it. No drawing here,
//! and no raw input handling either: input.zig translates events into these calls.
const std = @import("std");
const model = @import("model.zig");
const storage = @import("storage.zig");
const dates = @import("dates.zig");
const draw = @import("draw.zig");
const Form = @import("form.zig").Form;
const Brain = @import("brainstorm.zig").Brain;
const worklog = @import("worklog.zig");
const stats = @import("stats.zig");
const settings = @import("settings.zig");
const Logbook = @import("logbook.zig").Logbook;

pub const Mode = enum { normal, form, confirm_delete, help, brainstorm, log };

/// Where everything lives on disk.
pub const Paths = struct {
    board: []const u8,
    notes: []const u8,
    log: []const u8,
    settings: []const u8,
};

pub const Drag = struct {
    id: u32,
    sx: i32,
    sy: i32,
    col: i32,
    row: i32,
    active: bool = false,
};

pub const CardHit = struct { id: u32, rect: draw.Rect };

pub const App = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    board: model.Board,
    path: []const u8,
    /// History of work sessions and completions (see worklog.zig)
    worklog: worklog.Log,
    log_path: []const u8,
    /// the Log popup and the knobs behind its forecasts
    logbook: Logbook = .{},
    params: stats.Params = .{},
    settings_path: []const u8,
    today: i32,
    now: i64,

    mode: Mode = .normal,
    focus: model.Zone = .q1,
    last_matrix: model.Zone = .q1,
    sel: ?u32 = null,
    drag: ?Drag = null,
    quit: bool = false,
    flash: ?[]const u8 = null,
    /// show the flash as a plain notice instead of an error
    flash_info: bool = false,

    // per-zone view state
    scroll: [model.Zone.count]usize = @splat(0),
    capacity: [model.Zone.count]usize = @splat(1),
    lists: [model.Zone.count][]const u32 = @splat(&.{}),

    // filled by ui.zig every frame; used for mouse hit-testing
    zone_rects: [model.Zone.count]draw.Rect = @splat(.{}),
    backlog_rect: draw.Rect = .{},
    cards: std.ArrayList(CardHit) = .empty,

    // form modal
    form: ?Form = null,
    editing: ?u32 = null,
    new_status: model.Status = .backlog,

    // brainstorm popup (topics + free-writing pages)
    brain: Brain,

    // double click detection
    last_click_id: ?u32 = null,
    last_click_ns: i96 = 0,

    lists_arena: std.heap.ArenaAllocator,
    frame_arena: std.heap.ArenaAllocator,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, paths: Paths) App {
        const now = dates.unixNow(io);
        return .{
            .alloc = alloc,
            .io = io,
            .board = model.Board.init(alloc),
            .path = paths.board,
            .worklog = worklog.Log.init(alloc),
            .log_path = paths.log,
            .settings_path = paths.settings,
            .today = dates.todayLocal(io),
            .now = now,
            .brain = Brain.init(alloc, io, paths.notes, now),
            .lists_arena = .init(alloc),
            .frame_arena = .init(alloc),
        };
    }

    pub fn deinit(self: *App) void {
        if (self.form) |*f| f.deinit();
        self.brain.deinit();
        self.worklog.deinit();
        self.cards.deinit(self.alloc);
        self.lists_arena.deinit();
        self.frame_arena.deinit();
        self.board.deinit();
    }

    /// Refresh the clocks; called on every event and every timer tick.
    pub fn tickClock(self: *App) void {
        self.today = dates.todayLocal(self.io);
        self.now = dates.unixNow(self.io);
        self.brain.now = self.now;
    }

    pub fn openLog(self: *App) void {
        self.logbook.open(dates.weekdayIndex(dates.Tz.dayOf(.{}, self.now)));
        self.mode = .log;
    }

    pub fn saveParams(self: *App) void {
        settings.save(self.io, self.alloc, self.settings_path, self.params) catch {
            self.flash = "could not write the settings file";
        };
    }

    pub fn openBrainstorm(self: *App) void {
        self.brain.openPopup();
        self.mode = .brainstorm;
    }

    /// True while any task has a running stopwatch (the UI needs to redraw each second).
    pub fn hasRunning(self: *const App) bool {
        return self.lists[model.Zone.doing.index()].len > 0;
    }

    pub fn persist(self: *App) void {
        storage.save(self.io, self.alloc, self.path, &self.board) catch {
            self.flash = "could not write the board file";
        };
        // whatever the change did to the stopwatch also goes into the history
        const logged = self.board.drainEvents(&self.worklog) catch false;
        if (logged) worklog.save(self.io, self.alloc, self.log_path, &self.worklog) catch {
            self.flash = "could not write the work log";
        };
    }

    // ---- derived data -----------------------------------------------------

    /// Rebuild the sorted per-zone lists and repair the selection.
    pub fn refresh(self: *App) !void {
        _ = self.lists_arena.reset(.retain_capacity);
        const a = self.lists_arena.allocator();
        for (0..model.Zone.count) |i| {
            self.lists[i] = try self.board.idsIn(a, model.Zone.fromIndex(i));
        }
        if (self.sel) |id| {
            if (self.locate(id)) |z| self.focus = z else self.sel = null;
        }
        if (self.focus.isMatrix()) self.last_matrix = self.focus;
    }

    pub fn locate(self: *const App, id: u32) ?model.Zone {
        for (self.lists, 0..) |l, i| {
            for (l) |x| if (x == id) return model.Zone.fromIndex(i);
        }
        return null;
    }

    pub fn selIndex(self: *const App) ?usize {
        const id = self.sel orelse return null;
        for (self.lists[self.focus.index()], 0..) |x, i| if (x == id) return i;
        return null;
    }

    pub fn ensureVisible(self: *App) void {
        const zi = self.focus.index();
        const idx = self.selIndex() orelse return;
        const cap = @max(self.capacity[zi], 1);
        if (idx < self.scroll[zi]) {
            self.scroll[zi] = idx;
        } else if (idx >= self.scroll[zi] + cap) {
            self.scroll[zi] = idx + 1 - cap;
        }
    }

    // ---- hit testing --------------------------------------------------------

    pub fn cardAt(self: *const App, col: i32, row: i32) ?u32 {
        for (self.cards.items) |c| if (c.rect.contains(col, row)) return c.id;
        return null;
    }

    pub fn zoneAt(self: *const App, col: i32, row: i32) ?model.Zone {
        for (self.zone_rects, 0..) |r, i| {
            if (r.w > 0 and r.contains(col, row)) return model.Zone.fromIndex(i);
        }
        return null;
    }

    // ---- selection / cursor ---------------------------------------------------

    pub fn select(self: *App, id: u32) void {
        self.sel = id;
        if (self.locate(id)) |z| self.focus = z;
        if (self.focus.isMatrix()) self.last_matrix = self.focus;
        self.ensureVisible();
    }

    pub fn focusZone(self: *App, z: model.Zone, prefer_idx: usize) void {
        self.focus = z;
        if (z.isMatrix()) self.last_matrix = z;
        const l = self.lists[z.index()];
        self.sel = if (l.len == 0) null else l[@min(prefer_idx, l.len - 1)];
        self.ensureVisible();
    }

    pub fn moveCursor(self: *App, dir: model.Dir) void {
        switch (dir) {
            .left, .right => {
                if (model.neighbor(self.focus, dir, self.last_matrix)) |z| {
                    self.focusZone(z, self.selIndex() orelse 0);
                }
            },
            .down => {
                const l = self.lists[self.focus.index()];
                const cur = self.selIndex();
                const next: usize = if (cur) |c| c + 1 else 0;
                if (next < l.len) {
                    self.sel = l[next];
                } else if (model.neighbor(self.focus, .down, self.last_matrix)) |z| {
                    self.focusZone(z, 0);
                }
                self.ensureVisible();
            },
            .up => {
                const l = self.lists[self.focus.index()];
                if (self.selIndex()) |c| {
                    if (c > 0) {
                        self.sel = l[c - 1];
                        self.ensureVisible();
                        return;
                    }
                }
                if (model.neighbor(self.focus, .up, self.last_matrix)) |z| {
                    self.focusZone(z, std.math.maxInt(usize));
                }
            },
        }
    }

    // ---- task operations ------------------------------------------------------

    pub fn moveTask(self: *App, dir: model.Dir) void {
        const id = self.sel orelse return;
        const z = model.neighbor(self.focus, dir, self.last_matrix) orelse return;
        self.moveTaskTo(id, z);
    }

    pub fn moveTaskTo(self: *App, id: u32, z: model.Zone) void {
        self.board.moveToZone(id, z, self.now);
        self.sel = id;
        self.persist();
        self.refresh() catch {};
        self.ensureVisible();
    }

    pub fn setPriority(self: *App, p: u8) void {
        const id = self.sel orelse return;
        const t = self.board.getConst(id) orelse return;
        if (t.status == .backlog) {
            self.moveTaskTo(id, model.Zone.fromIndex(p - 1));
        } else {
            self.board.setPriority(id, p);
            self.persist();
            self.refresh() catch {};
            self.ensureVisible();
        }
    }

    pub fn advance(self: *App) void {
        const id = self.sel orelse return;
        self.board.advance(id, self.now);
        self.persist();
        self.refresh() catch {};
        self.ensureVisible();
    }

    pub fn deleteSelected(self: *App) void {
        const id = self.sel orelse return;
        const idx = self.selIndex() orelse 0;
        self.board.remove(id, self.now);
        self.sel = null;
        self.persist();
        self.refresh() catch {};
        self.focusZone(self.focus, idx);
    }

    // ---- form -------------------------------------------------------------------

    pub fn openNew(self: *App) !void {
        var f = Form.init(self.alloc);
        f.priority = self.focus.priority() orelse 2;
        self.new_status = switch (self.focus) {
            .doing => .doing,
            .done => .done,
            else => .backlog,
        };
        self.form = f;
        self.editing = null;
        self.mode = .form;
    }

    pub fn openEdit(self: *App) !void {
        const id = self.sel orelse return;
        const t = self.board.getConst(id) orelse return;
        var f = Form.init(self.alloc);
        errdefer f.deinit();
        try f.title.insertSliceAtCursor(t.title);
        if (t.deadline) |d| {
            var b: [16]u8 = undefined;
            try f.deadline.insertSliceAtCursor(dates.format(&b, d));
        }
        f.priority = t.priority;
        f.is_edit = true;
        self.form = f;
        self.editing = id;
        self.mode = .form;
    }

    pub fn closeForm(self: *App) void {
        if (self.form) |*f| f.deinit();
        self.form = null;
        self.editing = null;
        self.mode = .normal;
    }

    /// Validate and apply the form. Leaves it open (with an error) if invalid.
    pub fn submitForm(self: *App) !void {
        const f = &(self.form orelse return);

        const title_raw = try f.title.toOwnedContents(self.alloc);
        defer self.alloc.free(title_raw);
        const title = std.mem.trim(u8, title_raw, " \t");
        if (title.len == 0) {
            f.err = "a task needs a title";
            f.field = .title;
            return;
        }

        const dl_raw = try f.deadline.toOwnedContents(self.alloc);
        defer self.alloc.free(dl_raw);
        const deadline = dates.parse(dl_raw, self.today) catch {
            f.err = null; // the live preview under the field already explains it
            f.field = .deadline;
            return;
        };

        if (self.editing) |id| {
            try self.board.update(id, title, f.priority, deadline);
            self.sel = id;
        } else {
            self.sel = try self.board.add(title, self.new_status, f.priority, deadline, self.now);
        }
        self.persist();
        self.closeForm();
        try self.refresh();
        self.ensureVisible();
    }
};
