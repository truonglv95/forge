const std = @import("std");
const lsp = @import("forge-lsp");
const editor = @import("forge-editor");
const panel_scroll = @import("../ui/panel_scroll.zig");

pub const Line = struct {
    label: []const u8,

    pub fn deinit(self: *Line, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    edit: ?lsp.rename.WorkspaceEdit = null,
    lines: []Line = &.{},
    active: bool = false,
    new_name: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        self.clear();
        if (self.new_name.len > 0) self.allocator.free(self.new_name);
    }

    pub fn clear(self: *Store) void {
        if (self.edit) |*edit| edit.deinit(self.allocator);
        self.edit = null;
        for (self.lines) |*line| line.deinit(self.allocator);
        self.allocator.free(self.lines);
        self.lines = &.{};
        self.active = false;
        if (self.new_name.len > 0) {
            self.allocator.free(self.new_name);
            self.new_name = "";
        }
    }

    pub fn setPreview(
        self: *Store,
        workspace_path: []const u8,
        tabs: *editor.TabGroup,
        new_name: []const u8,
        edit: lsp.rename.WorkspaceEdit,
    ) !void {
        self.clear();
        self.edit = edit;
        self.new_name = try self.allocator.dupe(u8, new_name);

        var list: std.ArrayList(Line) = .empty;
        errdefer {
            for (list.items) |*line| line.deinit(self.allocator);
            list.deinit(self.allocator);
        }

        for (edit.files) |file_edit| {
            const rel = try lsp.navigation.uriToRelativePath(self.allocator, workspace_path, file_edit.uri);
            const path = rel orelse continue;
            defer self.allocator.free(path);

            const doc = findDoc(tabs, path);
            for (file_edit.edits) |text_edit| {
                const old_snippet = snippetFromDoc(doc, text_edit);
                const label = try std.fmt.allocPrint(self.allocator, "{s}:{d}:{d}  \"{s}\" -> \"{s}\"", .{
                    path,
                    text_edit.line + 1,
                    text_edit.character + 1,
                    old_snippet,
                    text_edit.new_text,
                });
                try list.append(self.allocator, .{ .label = label });
            }
        }

        self.lines = try list.toOwnedSlice(self.allocator);
        self.active = self.lines.len > 0;
        if (!self.active) {
            if (self.edit) |*owned| owned.deinit(self.allocator);
            self.edit = null;
        }
    }

    pub fn hitTest(
        editor_x: f32,
        panel_y: f32,
        panel_h: f32,
        x: f32,
        y: f32,
        scroll_y: f32,
    ) ?usize {
        const top = panel_y + panel_scroll.bottom_content_top;
        const viewport = panel_scroll.bottomViewportHeight(panel_h);
        if (x < editor_x or y < top or y >= top + viewport) return null;
        const float_line = (y - top + scroll_y) / panel_scroll.bottom_line_h;
        if (float_line < 1) return null;
        const line: usize = @intFromFloat(float_line - 1);
        return line;
    }
};

fn findDoc(tabs: *editor.TabGroup, path: []const u8) ?*editor.Document {
    for (tabs.tabs.items) |*doc| {
        if (std.mem.eql(u8, doc.path, path)) return doc;
    }
    return null;
}

fn snippetFromDoc(doc: ?*editor.Document, edit: lsp.rename.TextEdit) []const u8 {
    if (doc == null) return "?";
    if (edit.line != edit.end_line) return "<multi-line>";
    const line = doc.?.buffer.lineAt(@intCast(edit.line));
    const start = @min(@as(usize, @intCast(edit.character)), line.len);
    const end = @min(@as(usize, @intCast(edit.end_character)), line.len);
    if (end <= start) return "?";
    return line[start..end];
}
