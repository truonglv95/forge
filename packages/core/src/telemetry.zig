const std = @import("std");
const time = std.time;
const c = @cImport({
    @cInclude("sys/time.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

fn microTimestamp() i64 {
    var tv: c.timeval = undefined;
    _ = c.gettimeofday(&tv, null);
    return @as(i64, tv.tv_sec) * 1000000 + @as(i64, tv.tv_usec);
}

pub const Span = struct {
    category: []const u8,
    name: []const u8,
    start_ts: i64,
    end_ts: i64 = 0,

    pub fn end(self: *Span) void {
        self.end_ts = microTimestamp();
        recordSpan(self.*);
    }
};

var trace_fd: c_int = -1;
var is_first_span: bool = true;
var mutex = @import("forge-util").sync.Mutex{};

pub fn init(out_path: [:0]const u8) !void {
    const fd = c.open(out_path.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_int, 0o666));
    if (fd == -1) return error.FailedToOpen;
    _ = c.write(fd, "[\n", 2);
    trace_fd = fd;
}

pub fn deinit() void {
    if (trace_fd != -1) {
        _ = c.write(trace_fd, "\n]\n", 3);
        _ = c.close(trace_fd);
        trace_fd = -1;
    }
}

pub fn startSpan(category: []const u8, name: []const u8) Span {
    return .{
        .category = category,
        .name = name,
        .start_ts = microTimestamp(),
    };
}

pub fn recordSpan(span: Span) void {
    if (trace_fd != -1) {
        mutex.lock();
        defer mutex.unlock();
        if (!is_first_span) {
            _ = c.write(trace_fd, ",\n", 2);
        } else {
            is_first_span = false;
        }

        var buf: [1024]u8 = undefined;
        const s = std.fmt.bufPrint(&buf,
            \\  {{"name": "{s}", "cat": "{s}", "ph": "X", "ts": {d}, "dur": {d}, "pid": 1, "tid": 1}}
        , .{
            span.name,
            span.category,
            span.start_ts,
            span.end_ts - span.start_ts,
        }) catch return;
        _ = c.write(trace_fd, s.ptr, s.len);
    }
}

pub fn recordEvent(category: []const u8, name: []const u8, start_ts: i64, end_ts: i64) void {
    recordSpan(.{
        .category = category,
        .name = name,
        .start_ts = start_ts,
        .end_ts = end_ts,
    });
}
