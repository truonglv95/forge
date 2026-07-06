const std = @import("std");
const search_engine = @import("../search/engine.zig");

pub fn runSearch(wb: anytype) !void {
    const query = try wb.search_buffer.content();
    defer wb.search_buffer.allocator.free(query);
    if (wb.search_results) |*results| results.deinit(wb.allocator);
    wb.search_results = try search_engine.searchWorkspace(
        wb.allocator,
        wb.io,
        wb.workspace_root,
        &wb.explorer,
        query,
    );
    wb.search_scroll_y = 0;
    var buf: [96]u8 = undefined;
    const count = wb.search_results.?.matches.len;
    const msg = try std.fmt.bufPrint(&buf, "Search: {d} result(s)", .{count});
    try wb.setStatus(msg);
}

pub fn handleSearchClick(wb: anytype, hit: @import("../ui/sidebar/search_panel.zig").Hit) !void {
    switch (hit) {
        .run_search => try wb.dispatch(.search_run),
        .open_result => |index| {
            const results = wb.search_results orelse return;
            if (index >= results.matches.len) return;
            const match = results.matches[index];
            const path = try wb.allocator.dupe(u8, match.path);
            defer wb.allocator.free(path);
            try wb.dispatch(.{ .open_file = path });
            if (match.line) |line| {
                if (wb.activeBuffer()) |buf| {
                    if (line < buf.lineCount()) {
                        buf.cursor.row = line;
                        buf.cursor.col = 0;
                    }
                }
            }
        },
    }
}
