const std = @import("std");
const kernel = @import("forge-kernel");
const builtin = @import("builtin");

var active_cancel_state: ?*std.atomic.Value(bool) = null;

fn handleSigInt(_: std.posix.SIG) callconv(.c) void {
    if (active_cancel_state) |state| {
        state.store(true, .release);
    }
}

pub const Scope = struct {
    source: kernel.cancellation.CancellationTokenSource,
    sigint_installed: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Scope {
        return .{
            .source = try kernel.cancellation.CancellationTokenSource.init(allocator),
        };
    }

    pub fn installSigint(self: *Scope) void {
        if (self.sigint_installed or builtin.os.tag == .windows) return;
        active_cancel_state = self.source.shared_state;

        const sa = std.posix.Sigaction{
            .handler = .{ .handler = handleSigInt },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESTART,
        };
        std.posix.sigaction(std.posix.SIG.INT, &sa, null);
        self.sigint_installed = true;
    }

    pub fn token(self: *Scope) kernel.cancellation.CancellationToken {
        return self.source.getToken();
    }

    pub fn cancel(self: *Scope) void {
        self.source.cancel();
    }

    pub fn deinit(self: *Scope) void {
        if (self.sigint_installed and active_cancel_state == self.source.shared_state) {
            active_cancel_state = null;
            const default_sa = std.posix.Sigaction{
                .handler = .{ .handler = std.posix.SIG.DFL },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(std.posix.SIG.INT, &default_sa, null);
        }
        self.source.deinit();
    }
};

test "Scope cancellation token works" {
    var scope = try Scope.init(std.testing.allocator);
    defer scope.deinit();

    const token = scope.token();
    try std.testing.expect(!token.isCancelled());
    scope.cancel();
    try std.testing.expect(token.isCancelled());
}
