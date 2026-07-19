const std = @import("std");
const testing = std.testing;
const workspace = @import("forge-workspace");
const lsp_controller = @import("lsp_controller.zig");

test "LspController init and deinit" {
    var ws_dir = testing.tmpDir(.{});
    defer ws_dir.cleanup();

    const io = std.testing.io;
    const ws_path = "/tmp/fake_workspace";

    const root = workspace.WorkspaceRoot.init(ws_dir.dir, ws_path);

    var controller = try lsp_controller.LspController.init(testing.allocator, io, ws_path, root);
    defer controller.deinit();

    try testing.expect(controller.outline_symbols.len == 0);
}
