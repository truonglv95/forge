const std = @import("std");
const multi_cursor_mod = @import("forge-editor").multi_cursor;
const fold_controller_mod = @import("forge-editor").folding;
const inlay_hints_store_mod = @import("inlay_hints_store.zig");
const inline_edit_mod = @import("inline_edit.zig");
const ghost_completion_mod = @import("ghost_completion.zig");
const editor = @import("forge-editor");

pub const EditorController = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    tabs: editor.TabGroup,
    multi_cursor: multi_cursor_mod.MultiCursor,
    fold_controller: fold_controller_mod.FoldController,
    fold_dirty: bool = true,
    inlay_hints: inlay_hints_store_mod.Store,
    inline_edit: inline_edit_mod.State,
    ghost: ghost_completion_mod.Store,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !EditorController {
        return EditorController{
            .allocator = allocator,
            .io = io,
            .tabs = editor.TabGroup.init(allocator),
            .multi_cursor = multi_cursor_mod.MultiCursor.init(allocator),
            .fold_controller = fold_controller_mod.FoldController.init(allocator),
            .inlay_hints = inlay_hints_store_mod.Store.init(allocator),
            .inline_edit = inline_edit_mod.State.init(allocator, io),
            .ghost = ghost_completion_mod.Store.init(allocator, io, .{}),
        };
    }

    pub fn deinit(self: *EditorController) void {
        self.ghost.deinit();
        self.fold_controller.deinit();
        self.multi_cursor.deinit();
        self.inlay_hints.deinit();
        self.inline_edit.deinit();
    }
};
