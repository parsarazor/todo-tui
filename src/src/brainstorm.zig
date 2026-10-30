//! The brainstorm popup's state machine: a topic list and, inside a topic, a
//! blank page you can write on. It owns no drawing (see brain_view.zig) and
//! doesn't know about the kanban board; main/state/input just forward events
//! and act on the returned Action.
const std = @import("std");
const vaxis = @import("vaxis");
const notes_mod = @import("notes.zig");
const editor_mod = @import("editor.zig");
const draw = @import("draw.zig");
const TextInput = vaxis.widgets.TextInput;

pub const View = enum { list, page };
pub const Prompt = enum { none, new_topic, rename, confirm_delete };
pub const Action = enum { none, close, quit };
pub const Hit = struct { idx: usize, rect: draw.Rect };

const double_click_ns: i96 = 400 * std.time.ns_per_ms;

pub const Brain = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    now: i64,

    notes: notes_mod.Notes,

    view: View = .list,
    prompt: Prompt = .none,
    sel: usize = 0,
    scroll: usize = 0,
    capacity: usize = 1,

    // the open page
    ed: editor_mod.Editor,
    open_id: ?u32 = null,
    /// text in the editor differs from the topic's stored body
    edit_dirty: bool = false,
    /// topics differ from what's on disk
    notes_dirty: bool = false,

    title_input: TextInput,

    // measured by the renderer, used for up/down/home/end on wrapped text
    page_w: u16 = 60,
    page_h: u16 = 10,
    method: editor_mod.Method = .wcwidth,

    hits: std.ArrayList(Hit) = .empty,
    last_click_idx: ?usize = null,
    last_click_ns: i96 = 0,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, path: []const u8, now: i64) Brain {
        return .{
            .alloc = alloc,
            .io = io,
            .path = path,
            .now = now,
            .notes = notes_mod.Notes.init(alloc),
            .ed = editor_mod.Editor.init(alloc),
            .title_input = TextInput.init(alloc),
        };
    }

    pub fn deinit(self: *Brain) void {
        self.notes.deinit();
        self.ed.deinit();
        self.title_input.deinit();
        self.hits.deinit(self.alloc);
    }

    pub fn load(self: *Brain) !void {
        try notes_mod.load(self.io, self.alloc, self.path, &self.notes);
    }

    // ---- saving ------------------------------------------------------------------

    /// Copy the editor text into the open topic.
    fn commit(self: *Brain) void {
        defer self.edit_dirty = false;
        const id = self.open_id orelse return;
        const idx = self.notes.indexOf(id) orelse return;
        const changed = self.notes.setBody(idx, self.ed.text(), self.now) catch return;
        if (changed) self.notes_dirty = true;
    }

    fn persist(self: *Brain) void {
        notes_mod.save(self.io, self.alloc, self.path, &self.notes) catch return;
        self.notes_dirty = false;
    }

    /// Write anything unsaved to disk. Cheap when nothing changed, so it's
    /// called on the 1s tick, when leaving a page, closing the popup and quitting.
    pub fn flush(self: *Brain) void {
        if (self.edit_dirty) self.commit();
        if (self.notes_dirty) self.persist();
    }

    pub fn isDirty(self: *const Brain) bool {
        return self.edit_dirty or self.notes_dirty;
    }

    // ---- navigation ----------------------------------------------------------------

    pub fn openPopup(self: *Brain) void {
        self.view = .list;
        self.prompt = .none;
        self.open_id = null;
        if (self.sel >= self.notes.topics.items.len) self.sel = self.notes.topics.items.len -| 1;
    }

    fn openPage(self: *Brain) void {
        if (self.sel >= self.notes.topics.items.len) return;
        const t = self.notes.topics.items[self.sel];
        self.ed.setText(t.body) catch return;
        self.open_id = t.id;
        self.edit_dirty = false;
        self.view = .page;
        self.prompt = .none;
    }

    fn leavePage(self: *Brain) void {
        self.commit();
        if (self.open_id) |id| {
            if (self.notes.indexOf(id)) |i| self.sel = i;
        }
        self.open_id = null;
        self.view = .list;
        self.flush();
    }

    fn rows(self: *Brain, a: std.mem.Allocator) ![]editor_mod.Row {
        return self.ed.layout(a, self.page_w, self.method);
    }

    // ---- keys ------------------------------------------------------------------------

    pub fn handleKey(self: *Brain, key: vaxis.Key) !Action {
        if (key.matches('c', .{ .ctrl = true })) {
            self.flush();
            return .quit;
        }
        return switch (self.view) {
            .list => self.listKey(key),
            .page => self.pageKey(key),
        };
    }

    fn listKey(self: *Brain, key: vaxis.Key) !Action {
        if (self.prompt != .none) return self.promptKey(key);
        const K = vaxis.Key;
        const n = self.notes.topics.items.len;

        if (key.matches(K.escape, .{}) or key.matches('b', .{}) or key.matches('q', .{})) {
            self.flush();
            return .close;
        }
        if (key.matches(K.up, .{ .shift = true }) or key.matches('K', .{})) return self.reorder(-1);
        if (key.matches(K.down, .{ .shift = true }) or key.matches('J', .{})) return self.reorder(1);

        if (key.matches(K.up, .{}) or key.matches('k', .{})) self.sel -|= 1;
        if (key.matches(K.down, .{}) or key.matches('j', .{})) {
            if (self.sel + 1 < n) self.sel += 1;
        }
        if (key.matches(K.enter, .{}) or key.matches(K.right, .{}) or key.matches('l', .{})) self.openPage();

        if (key.matches('n', .{})) {
            self.title_input.clearRetainingCapacity();
            self.prompt = .new_topic;
        }
        if (key.matches('r', .{}) and n > 0) {
            self.title_input.clearRetainingCapacity();
            try self.title_input.insertSliceAtCursor(self.notes.topics.items[self.sel].title);
            self.prompt = .rename;
        }
        if ((key.matches('x', .{}) or key.matches(K.delete, .{})) and n > 0) self.prompt = .confirm_delete;
        return .none;
    }

    fn reorder(self: *Brain, delta: i32) Action {
        if (self.notes.topics.items.len == 0) return .none;
        self.sel = self.notes.move(self.sel, delta);
        self.notes_dirty = true;
        self.persist();
        return .none;
    }

    fn promptKey(self: *Brain, key: vaxis.Key) !Action {
        const K = vaxis.Key;
        if (self.prompt == .confirm_delete) {
            if (key.matches('y', .{}) or key.matches('Y', .{})) {
                self.notes.remove(self.sel);
                self.sel = @min(self.sel, self.notes.topics.items.len -| 1);
                self.notes_dirty = true;
                self.persist();
            }
            self.prompt = .none;
            return .none;
        }
        if (key.matches(K.escape, .{})) {
            self.prompt = .none;
            return .none;
        }
        if (key.matches(K.enter, .{})) {
            const raw = try self.title_input.toOwnedContents(self.alloc);
            defer self.alloc.free(raw);
            if (std.mem.trim(u8, raw, " \t").len == 0) return .none; // keep asking
            switch (self.prompt) {
                .new_topic => {
                    _ = try self.notes.add(raw, self.now);
                    self.sel = 0;
                    self.notes_dirty = true;
                    self.persist();
                    self.openPage(); // straight onto the blank page
                },
                .rename => {
                    try self.notes.rename(self.sel, raw);
                    self.notes_dirty = true;
                    self.persist();
                },
                else => {},
            }
            self.prompt = .none;
            return .none;
        }
        try self.title_input.update(.{ .key_press = key });
        return .none;
    }

    fn pageKey(self: *Brain, key: vaxis.Key) !Action {
        const K = vaxis.Key;
        const ed = &self.ed;

        if (key.matches(K.escape, .{})) {
            self.leavePage();
            return .none;
        }
        if (key.matches('s', .{ .ctrl = true })) {
            self.commit();
            self.persist();
            return .none;
        }

        var edited = true;
        if (key.matches(K.enter, .{})) {
            try ed.insert("\n");
        } else if (key.matches(K.tab, .{})) {
            try ed.insert("    ");
        } else if (key.matches(K.backspace, .{ .ctrl = true }) or key.matches(K.backspace, .{ .alt = true }) or key.matches('w', .{ .ctrl = true })) {
            ed.deleteWordBack();
        } else if (key.matches(K.backspace, .{})) {
            ed.backspace();
        } else if (key.matches(K.delete, .{})) {
            ed.deleteForward();
        } else if (key.matches('k', .{ .ctrl = true })) {
            ed.deleteToLineEnd();
        } else if (key.matches('u', .{ .ctrl = true })) {
            ed.deleteToLineStart();
        } else {
            edited = false;
            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const page: i32 = @max(@as(i32, self.page_h) - 1, 1);

            if (key.matches(K.left, .{ .ctrl = true }) or key.matches(K.left, .{ .alt = true })) {
                ed.wordLeft();
            } else if (key.matches(K.right, .{ .ctrl = true }) or key.matches(K.right, .{ .alt = true })) {
                ed.wordRight();
            } else if (key.matches(K.left, .{})) {
                ed.moveLeft();
            } else if (key.matches(K.right, .{})) {
                ed.moveRight();
            } else if (key.matches(K.up, .{})) {
                ed.moveVertical(try self.rows(a), -1, self.method);
            } else if (key.matches(K.down, .{})) {
                ed.moveVertical(try self.rows(a), 1, self.method);
            } else if (key.matches(K.page_up, .{})) {
                ed.moveVertical(try self.rows(a), -page, self.method);
            } else if (key.matches(K.page_down, .{})) {
                ed.moveVertical(try self.rows(a), page, self.method);
            } else if (key.matches(K.home, .{ .ctrl = true })) {
                ed.moveToStart();
            } else if (key.matches(K.end, .{ .ctrl = true })) {
                ed.moveToEnd();
            } else if (key.matches(K.home, .{}) or key.matches('a', .{ .ctrl = true })) {
                ed.moveRowStart(try self.rows(a));
            } else if (key.matches(K.end, .{}) or key.matches('e', .{ .ctrl = true })) {
                ed.moveRowEnd(try self.rows(a));
            } else if (key.text) |t| {
                if (!key.mods.ctrl and !key.mods.alt) {
                    try ed.insert(t);
                    edited = true;
                }
            }
        }
        if (edited) self.edit_dirty = true;
        return .none;
    }

    pub fn handlePaste(self: *Brain, text: []const u8) !void {
        if (self.prompt == .new_topic or self.prompt == .rename) {
            var buf: [256]u8 = undefined;
            try self.title_input.insertSliceAtCursor(editor_mod.flattenLine(&buf, text));
            return;
        }
        if (self.view == .page and self.prompt == .none) {
            try self.ed.insert(text);
            self.edit_dirty = true;
        }
    }

    // ---- mouse (topic list only) ----------------------------------------------------------

    pub fn handleMouse(self: *Brain, m: vaxis.Mouse) void {
        if (self.view != .list or self.prompt != .none) return;
        const n = self.notes.topics.items.len;
        if (m.type != .press) return;
        switch (m.button) {
            .wheel_up => self.sel -|= 1,
            .wheel_down => {
                if (self.sel + 1 < n) self.sel += 1;
            },
            .left => for (self.hits.items) |h| {
                if (!h.rect.contains(m.col, m.row)) continue;
                self.sel = h.idx;
                const t = std.Io.Clock.awake.now(self.io).nanoseconds;
                if (self.last_click_idx == h.idx and t - self.last_click_ns < double_click_ns) {
                    self.last_click_idx = null;
                    self.openPage();
                } else {
                    self.last_click_idx = h.idx;
                    self.last_click_ns = t;
                }
                break;
            },
            else => {},
        }
    }
};
