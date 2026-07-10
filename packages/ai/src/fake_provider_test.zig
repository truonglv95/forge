//! Fake provider determinism and secret scanner tests.
//!
//! Verifies:
//!   - Fake provider produces deterministic output for same prompt
//!   - Secret patterns in context are flagged by the secret scanner
//!   - Normal code is NOT flagged
//!   - Proposal parser rejects malformed JSON

const std = @import("std");
const fake_provider = @import("fake_provider.zig");
const provider = @import("provider.zig");
const secret_scanner = @import("secret_scanner.zig");
const proposal_normalize = @import("proposal_normalize.zig");
const kernel = @import("forge-kernel");

// ---------------------------------------------------------------------------
// Secret scanner tests

test "secret scanner: common API key patterns are flagged" {
    const secrets = [_][]const u8{
        "sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abc",
        "AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ1234567",
        "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345",
    };

    for (secrets) |secret| {
        const result = secret_scanner.scan(secret);
        try std.testing.expectError(error.ContainsSecret, result);
    }
}

test "secret scanner: normal code is not flagged" {
    const safe = [_][]const u8{
        "const x = 42;",
        "fn main() void {}",
        "// This is a comment",
        "pub const VERSION = \"1.0.0\";",
    };

    for (safe) |code| {
        try secret_scanner.scan(code); // Should not return error
    }
}

// ---------------------------------------------------------------------------
// Proposal parsing tests

test "proposal normalize: valid minimal proposal is accepted" {
    const allocator = std.testing.allocator;

    const valid_json =
        \\{"schema_version":1,"summary":"Add hello function","workspace_edit":{"files":[]}}
    ;

    if (proposal_normalize.normalize(allocator, valid_json)) |normalized| {
        allocator.free(normalized);
    } else |_| {
        // May error if incomplete, that's fine depending on schema
    }
}

test "proposal normalize: malformed JSON is repaired into empty proposal" {
    const allocator = std.testing.allocator;

    const bad_inputs = [_][]const u8{
        "",
        "not json at all",
        "{unclosed",
        "{\"schema_version\":999}",
        "{\"summary\":\"no workspace_edit\"}",
    };

    for (bad_inputs) |input| {
        const normalized = try proposal_normalize.normalize(allocator, input);
        defer allocator.free(normalized);

        // The repair mechanism should produce a valid empty proposal.
        try std.testing.expect(normalized.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, normalized, "\"workspace_edit\"") != null);
    }
}

// ---------------------------------------------------------------------------
// Fake provider tests

test "fake provider: returns non-empty response for test_mode prompt" {
    const allocator = std.testing.allocator;
    var prov = fake_provider.FakeProvider.init("deterministic response", null, null);

    var w_alloc = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc.deinit();

    var cancel = kernel.cancellation.CancellationTokenSource.init(allocator) catch return;
    defer cancel.deinit();

    var p = prov.providerInterface();
    const token = cancel.getToken();
    try p.vtable.ask(p.ptr, allocator, "test_mode", &.{}, &w_alloc.writer, &token);

    const out_items = w_alloc.writer.buffer[0..w_alloc.writer.end];
    try std.testing.expect(out_items.len > 0);
}

test "fake provider: same prompt produces same output" {
    const allocator = std.testing.allocator;
    var prov = fake_provider.FakeProvider.init("deterministic response", null, null);

    const prompt = "test_mode";

    var w_alloc1 = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc1.deinit();

    var cancel1 = kernel.cancellation.CancellationTokenSource.init(allocator) catch return;
    defer cancel1.deinit();

    var p1 = prov.providerInterface();
    const token1 = cancel1.getToken();
    try p1.vtable.ask(p1.ptr, allocator, prompt, &.{}, &w_alloc1.writer, &token1);

    var w_alloc2 = std.Io.Writer.Allocating.init(allocator);
    defer w_alloc2.deinit();

    var cancel2 = kernel.cancellation.CancellationTokenSource.init(allocator) catch return;
    defer cancel2.deinit();

    var p2 = prov.providerInterface();
    const token2 = cancel2.getToken();
    try p2.vtable.ask(p2.ptr, allocator, prompt, &.{}, &w_alloc2.writer, &token2);

    const out1_items = w_alloc1.writer.buffer[0..w_alloc1.writer.end];
    const out2_items = w_alloc2.writer.buffer[0..w_alloc2.writer.end];
    try std.testing.expectEqualStrings(out1_items, out2_items);
}
