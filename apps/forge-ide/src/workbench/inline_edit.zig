//! Inline edit (Cmd+K) — selection-scoped AI edit with diff preview.
//!
//! When the user presses Cmd+K with a selection active, an inline prompt box
//! appears floating above the selection. The user types an instruction
//! ("rename to camelCase", "extract function", "add error handling"). On
//! submit, the AI generates a replacement; the new text is rendered as a
//! diff overlay (additions green, deletions red) directly in the editor.
//! Tab accepts, Esc rejects.
//!
//! This is Cursor's killer feature. We approximate it by:
//! 1. Keeping the user's instruction + selection in this State struct.
//! 2. Calling the agent loop with a constrained scope (single file, single
//!    selection range) and `use_inline_edits = true`.
//! 3. Storing the resulting edits as Buffer.decorations (addition/deletion
//!    rows) so the existing review_overlay can render them.
//! 4. editor_accept_inline_edit / editor_reject_inline_edit already exist
//!    on Buffer — they consume the decorations.

const std = @import("std");
const editor = @import("forge-editor");

pub const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    /// True when the inline-edit prompt box should be visible.
    active: bool = false,
    /// The user's instruction text (owned).
    prompt: std.ArrayList(u8),
    /// Path of the file being edited (owned, set on open).
    file_path: ?[]const u8 = null,
    /// Selection range captured when Cmd+K was pressed (0-indexed).
    sel_start_row: usize = 0,
    sel_start_col: usize = 0,
    sel_end_row: usize = 0,
    sel_end_col: usize = 0,
    /// Original selected text (owned, for diffing / revert).
    original_text: ?[]const u8 = null,
    /// Generated replacement text (owned, set after AI responds).
    /// When non-null, the editor is showing a diff preview.
    proposed_text: ?[]const u8 = null,
    /// True while the AI request is in flight.
    pending: bool = false,

    /// Multi-file Composer mode (Cursor parity) — when true, the user
    /// has selected multiple files for the edit. The agent will propose
    /// edits across all listed files. `composer_files` are additional
    /// file paths beyond the active file (owned).
    composer_mode: bool = false,
    composer_files: std.ArrayList([]const u8) = .empty,
    /// Wire-in: ComposerBatch for per-file accept/reject + diff preview.
    /// When non-null, the agent's multi-file proposal is stored here so
    /// the user can review and selectively accept/reject each file's edits.
    composer_batch: ?@import("forge-ai").multi_file_edit.ComposerBatch = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) State {
        return .{
            .allocator = allocator,
            .io = io,
            .prompt = .empty,
        };
    }

    pub fn deinit(self: *State) void {
        self.prompt.deinit(self.allocator);
        if (self.file_path) |p| self.allocator.free(p);
        if (self.original_text) |t| self.allocator.free(t);
        if (self.proposed_text) |t| self.allocator.free(t);
        self.freeComposerFiles();
        self.composer_files.deinit(self.allocator);
        if (self.composer_batch) |*batch| batch.deinit();
        self.* = undefined;
    }

    /// Free all stored Composer file paths.
    pub fn freeComposerFiles(self: *State) void {
        for (self.composer_files.items) |path| self.allocator.free(path);
        self.composer_files.clearRetainingCapacity();
    }

    /// Add a file to the Composer batch. The path is duped (caller may free).
    /// No-op if the file is already in the batch.
    pub fn addComposerFile(self: *State, file_path: []const u8) !void {
        // Avoid duplicates.
        for (self.composer_files.items) |existing| {
            if (std.mem.eql(u8, existing, file_path)) return;
        }
        const owned = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(owned);
        try self.composer_files.append(self.allocator, owned);
        self.composer_mode = self.composer_files.items.len > 0;
    }

    /// Remove a file from the Composer batch by index.
    pub fn removeComposerFile(self: *State, index: usize) void {
        if (index >= self.composer_files.items.len) return;
        self.allocator.free(self.composer_files.items[index]);
        _ = self.composer_files.orderedRemove(index);
        self.composer_mode = self.composer_files.items.len > 0;
    }

    /// Get all files in the Composer batch (active file + additional files).
    /// Caller must free the returned slice (but not the individual paths).
    pub fn allComposerFiles(self: *const State) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(self.allocator);
        if (self.file_path) |fp| try list.append(self.allocator, fp);
        for (self.composer_files.items) |fp| try list.append(self.allocator, fp);
        return try list.toOwnedSlice(self.allocator);
    }

    /// Open the inline-edit prompt box for the given selection.
    /// `original_text` is the currently selected text (caller may free
    /// after this call — we dupe it).
    pub fn open(
        self: *State,
        file_path: []const u8,
        sel_start_row: usize,
        sel_start_col: usize,
        sel_end_row: usize,
        sel_end_col: usize,
        original_text: []const u8,
    ) !void {
        // Reset state from any previous session.
        if (self.file_path) |p| self.allocator.free(p);
        if (self.original_text) |t| self.allocator.free(t);
        if (self.proposed_text) |t| self.allocator.free(t);
        self.proposed_text = null;
        self.prompt.clearRetainingCapacity();
        self.freeComposerFiles();
        self.composer_mode = false;

        self.file_path = try self.allocator.dupe(u8, file_path);
        self.original_text = try self.allocator.dupe(u8, original_text);
        self.sel_start_row = sel_start_row;
        self.sel_start_col = sel_start_col;
        self.sel_end_row = sel_end_row;
        self.sel_end_col = sel_end_col;
        self.active = true;
        self.pending = false;
    }

    pub fn close(self: *State) void {
        self.active = false;
        self.pending = false;
        self.prompt.clearRetainingCapacity();
        self.freeComposerFiles();
        self.composer_mode = false;
        if (self.proposed_text) |t| {
            self.allocator.free(t);
            self.proposed_text = null;
        }
        if (self.composer_batch) |*batch| batch.deinit();
        self.composer_batch = null;
    }

    /// Wire-in: Initialize a ComposerBatch for per-file accept/reject.
    /// Called when the agent returns a multi-file proposal.
    pub fn initComposerBatch(self: *State) !void {
        if (self.composer_batch) |*batch| batch.deinit();
        self.composer_batch = @import("forge-ai").multi_file_edit.ComposerBatch.init(self.allocator);
    }

    /// Wire-in: Toggle accept/reject for a specific file in the batch.
    pub fn toggleComposerAccept(self: *State, index: usize) !void {
        if (self.composer_batch) |*batch| {
            try batch.toggleAccept(index);
        }
    }

    /// Wire-in: Accept all files in the batch.
    pub fn acceptAllComposer(self: *State) !void {
        if (self.composer_batch) |*batch| {
            try batch.acceptAll();
        }
    }

    /// Wire-in: Get the list of accepted file indices.
    pub fn acceptedComposerIndices(self: *State) ![]usize {
        if (self.composer_batch) |*batch| {
            return try batch.acceptedIndices();
        }
        return &.{};
    }

    /// Append a character to the prompt (called from keyboard input).
    pub fn appendChar(self: *State, ch: u8) !void {
        try self.prompt.append(self.allocator, ch);
    }

    /// Append a string to the prompt (for paste).
    pub fn appendSlice(self: *State, s: []const u8) !void {
        try self.prompt.appendSlice(self.allocator, s);
    }

    /// Delete the last character from the prompt (backspace).
    pub fn backspace(self: *State) void {
        if (self.prompt.items.len > 0) {
            _ = self.prompt.pop();
        }
    }

    pub fn promptText(self: *const State) []const u8 {
        return self.prompt.items;
    }

    /// Store the AI-generated replacement text. Caller may free `text`
    /// after this call — we dupe it.
    pub fn setProposed(self: *State, text: []const u8) !void {
        if (self.proposed_text) |t| self.allocator.free(t);
        self.proposed_text = try self.allocator.dupe(u8, text);
        self.pending = false;
    }

    /// Mark that an AI request is in flight.
    pub fn markPending(self: *State) void {
        self.pending = true;
    }

    /// Returns the prompt instruction combined with the original selection
    /// for sending to the agent. Caller owns the returned slice.
    pub fn buildAgentPrompt(self: *State) ![]u8 {
        const orig = self.original_text orelse "";
        const path = self.file_path orelse "untitled";
        return std.fmt.allocPrint(
            self.allocator,
            \\Edit the selected code in {s} according to the user's instruction.
            \\
            \\Instruction: {s}
            \\
            \\Selected code:
            \\```
            \\{s}
            \\```
            \\
            \\Return ONLY the replacement code (no markdown fences, no
            \\explanation). The replacement must be valid for direct
            \\substitution into the selection range.
        ,
            .{ path, self.prompt.items, orig },
        );
    }
};

test "State open/close lifecycle" {
    const allocator = std.testing.allocator;
    var s = State.init(allocator, undefined);
    defer s.deinit();

    try s.open("main.zig", 1, 0, 1, 10, "fn hello()");
    try std.testing.expect(s.active);
    try std.testing.expectEqualStrings("main.zig", s.file_path.?);
    try std.testing.expectEqualStrings("fn hello()", s.original_text.?);

    s.close();
    try std.testing.expect(!s.active);
}

test "State prompt editing" {
    const allocator = std.testing.allocator;
    var s = State.init(allocator, undefined);
    defer s.deinit();

    try s.open("a.zig", 0, 0, 0, 5, "hello");
    try s.appendSlice("rename to goodbye");
    try std.testing.expectEqualStrings("rename to goodbye", s.promptText());

    s.backspace();
    try std.testing.expectEqualStrings("rename to goodby", s.promptText());
}

test "buildAgentPrompt includes instruction and selection" {
    const allocator = std.testing.allocator;
    var s = State.init(allocator, undefined);
    defer s.deinit();

    try s.open("main.zig", 0, 0, 0, 5, "hello");
    try s.appendSlice("rename to goodbye");
    const prompt = try s.buildAgentPrompt();
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "rename to goodbye") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "hello") != null);
}
