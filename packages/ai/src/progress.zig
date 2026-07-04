const std = @import("std");

pub const Phase = enum {
    context_built,
    sending,
    streaming,
    parsing,
    proposal_ready,
};

pub fn emit(phase: Phase, progress_writer: ?*std.Io.Writer) void {
    if (progress_writer) |writer| {
        writer.print("[forge] {s}\n", .{@tagName(phase)}) catch {};
    }
}

pub fn emitJson(phase: Phase, progress_writer: ?*std.Io.Writer) void {
    if (progress_writer) |writer| {
        writer.print("{{\"type\":\"progress\",\"phase\":\"{s}\"}}\n", .{@tagName(phase)}) catch {};
    }
}

pub fn emitIf(progress_writer: ?*std.Io.Writer, progress_json: bool, phase: Phase) void {
    if (progress_json) {
        emitJson(phase, progress_writer);
    } else {
        emit(phase, progress_writer);
    }
}
