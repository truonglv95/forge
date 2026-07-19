const std = @import("std");
const time = std.time;

pub const Span = struct {
    category: []const u8,
    name: []const u8,
    start_ts: i64,
    end_ts: i64 = 0,

    pub fn end(self: *Span) void {
        self.end_ts = time.microTimestamp();
        recordSpan(self.*);
    }
};

var trace_file: ?std.fs.File = null;
var is_first_span: bool = true;
var mutex = std.Thread.Mutex{};

pub fn init(out_path: []const u8) !void {
    const file = try std.fs.cwd().createFile(out_path, .{});
    try file.writeAll("[\n");
    trace_file = file;
}

pub fn deinit() void {
    if (trace_file) |f| {
        f.writeAll("\n]\n") catch {};
        f.close();
        trace_file = null;
    }
}

pub fn startSpan(category: []const u8, name: []const u8) Span {
    return .{
        .category = category,
        .name = name,
        .start_ts = time.microTimestamp(),
    };
}

pub fn recordSpan(span: Span) void {
    if (trace_file == null) return;
    mutex.lock();
    defer mutex.unlock();
    const f = trace_file.?;
    if (!is_first_span) {
        f.writeAll(",\n") catch return;
    }
    is_first_span = false;

    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf,
        \\  {{"name": "{s}", "cat": "{s}", "ph": "X", "ts": {d}, "dur": {d}, "pid": 1, "tid": 1}}
    , .{
        span.name,
        span.category,
        span.start_ts,
        span.end_ts - span.start_ts,
    }) catch return;
    f.writeAll(s) catch return;
}

pub fn recordEvent(category: []const u8, name: []const u8, start_ts: i64, end_ts: i64) void {
    recordSpan(.{
        .category = category,
        .name = name,
        .start_ts = start_ts,
        .end_ts = end_ts,
    });
}
