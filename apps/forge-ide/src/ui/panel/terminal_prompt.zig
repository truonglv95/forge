const std = @import("std");
const git_status = @import("../../git/status.zig");

pub const SegmentKind = enum {
    folder,
    muted,
    branch,
    marker_deleted,
    marker_modified,
    marker_staged,
    marker_untracked,
    marker_conflict,
    marker_ahead,
    marker_behind,
    chevron,
    command,
    plain,
};

pub const Segment = struct {
    offset: usize,
    length: usize,
    kind: SegmentKind,
};

/// Builds an IDE terminal prompt like: `➜ forge git:(main) `
pub fn format(
    workspace_path: []const u8,
    git: ?*const git_status.Status,
    buf: []u8,
) []const u8 {
    return buildPromptText(workspace_path, git, buf).text;
}

pub fn buildPromptText(
    workspace_path: []const u8,
    git: ?*const git_status.Status,
    buf: []u8,
) struct { text: []const u8, prompt_end: usize } {
    var len: usize = 0;

    len = appendSlice(buf, len, "➜ ");

    const folder = std.fs.path.basename(workspace_path);
    len = appendSlice(buf, len, folder);

    if (git) |status| {
        if (status.is_repo) {
            if (status.branch) |branch| {
                len = appendSlice(buf, len, " git:(");
                len = appendSlice(buf, len, branch);
                len = appendSlice(buf, len, ")");
            }
            var markers: [24]u8 = undefined;
            const marker_slice = dirtyMarkers(status, &markers);
            if (marker_slice.len > 0) {
                len = appendSlice(buf, len, " [");
                len = appendSlice(buf, len, marker_slice);
                len = appendSlice(buf, len, "]");
            }
        }
    }

    len = appendSlice(buf, len, " ");
    return .{ .text = buf[0..len], .prompt_end = len };
}

/// Styles `line` when it begins with the workspace prompt; remainder is treated as command text.
pub fn buildLineSegments(
    workspace_path: []const u8,
    git: ?*const git_status.Status,
    line: []const u8,
    prompt_buf: []u8,
    segments: []Segment,
) usize {
    const prompt = buildPromptText(workspace_path, git, prompt_buf);
    if (line.len >= prompt.text.len and std.mem.eql(u8, line[0..prompt.text.len], prompt.text)) {
        var count = buildPromptSegments(workspace_path, git, prompt.text, segments);
        if (line.len > prompt.text.len and count < segments.len) {
            segments[count] = .{
                .offset = prompt.text.len,
                .length = line.len - prompt.text.len,
                .kind = .command,
            };
            count += 1;
        }
        return count;
    }

    if (segments.len == 0) return 0;
    segments[0] = .{ .offset = 0, .length = line.len, .kind = .plain };
    return 1;
}

pub fn buildPromptSegments(
    workspace_path: []const u8,
    git: ?*const git_status.Status,
    prompt_text: []const u8,
    segments: []Segment,
) usize {
    var count: usize = 0;
    var offset: usize = 0;

    if (prompt_text.len >= 4 and count < segments.len) {
        const chevron = "➜ ";
        const n = @min(chevron.len, prompt_text.len - offset);
        segments[count] = .{ .offset = offset, .length = n, .kind = .chevron };
        count += 1;
        offset += n;
    }

    const folder = std.fs.path.basename(workspace_path);
    if (folder.len > 0 and count < segments.len) {
        const n = @min(folder.len, prompt_text.len - offset);
        segments[count] = .{ .offset = offset, .length = n, .kind = .folder };
        count += 1;
        offset += n;
    }

    if (git) |status| {
        if (status.is_repo and status.branch != null) {
            if (offset < prompt_text.len and count < segments.len) {
                const git_open = " git:(";
                const n = @min(git_open.len, prompt_text.len - offset);
                segments[count] = .{ .offset = offset, .length = n, .kind = .muted };
                count += 1;
                offset += n;
            }
            if (status.branch) |branch| {
                const n = @min(branch.len, prompt_text.len - offset);
                if (n > 0 and count < segments.len) {
                    segments[count] = .{ .offset = offset, .length = n, .kind = .branch };
                    count += 1;
                    offset += n;
                }
            }
            if (offset < prompt_text.len and count < segments.len) {
                const git_close = ")";
                const n = @min(git_close.len, prompt_text.len - offset);
                segments[count] = .{ .offset = offset, .length = n, .kind = .muted };
                count += 1;
                offset += n;
            }
        }

        var markers: [24]u8 = undefined;
        const marker_slice = dirtyMarkers(status, &markers);
        if (marker_slice.len > 0) {
            if (offset < prompt_text.len and count < segments.len) {
                const open = " [";
                const n = @min(open.len, prompt_text.len - offset);
                segments[count] = .{ .offset = offset, .length = n, .kind = .muted };
                count += 1;
                offset += n;
            }
            var mi: usize = 0;
            while (mi < marker_slice.len and offset < prompt_text.len and count < segments.len) {
                const seq_len = std.unicode.utf8ByteSequenceLength(marker_slice[mi]) catch 1;
                const marker_end = @min(mi + seq_len, marker_slice.len);
                const n = @min(seq_len, prompt_text.len - offset);
                segments[count] = .{
                    .offset = offset,
                    .length = n,
                    .kind = markerKindForSlice(marker_slice[mi..marker_end]),
                };
                count += 1;
                offset += n;
                mi += seq_len;
            }
            if (offset < prompt_text.len and count < segments.len) {
                const close = "]";
                const n = @min(close.len, prompt_text.len - offset);
                segments[count] = .{ .offset = offset, .length = n, .kind = .muted };
                count += 1;
                offset += n;
            }
        }
    }

    if (offset < prompt_text.len and count < segments.len) {
        const trailing = prompt_text[offset..];
        segments[count] = .{ .offset = offset, .length = trailing.len, .kind = .muted };
        count += 1;
    }

    return count;
}

fn markerKindForSlice(slice: []const u8) SegmentKind {
    if (std.mem.eql(u8, slice, "✘")) return .marker_deleted;
    if (std.mem.eql(u8, slice, "!")) return .marker_modified;
    if (std.mem.eql(u8, slice, "+")) return .marker_staged;
    if (std.mem.eql(u8, slice, "?")) return .marker_untracked;
    if (std.mem.eql(u8, slice, "~")) return .marker_conflict;
    if (std.mem.eql(u8, slice, "⇡")) return .marker_ahead;
    if (std.mem.eql(u8, slice, "⇣")) return .marker_behind;
    return .plain;
}

fn appendSlice(buf: []u8, offset: usize, slice: []const u8) usize {
    const room = buf.len - offset;
    if (room == 0) return offset;
    const n = @min(slice.len, room);
    @memcpy(buf[offset..][0..n], slice[0..n]);
    return offset + n;
}

fn dirtyMarkers(status: *const git_status.Status, out: []u8) []const u8 {
    var len: usize = 0;
    var has_staged = false;
    var has_modified = false;
    var has_deleted = false;
    var has_untracked = false;
    var has_conflict = false;

    for (status.entries) |entry| {
        const index = entry.status[0];
        const worktree = entry.status[1];
        if (index == '?' or worktree == '?') has_untracked = true;
        if (index == 'U' or worktree == 'U') has_conflict = true;
        if (index == 'D' or worktree == 'D') has_deleted = true;
        if (index == 'M' or index == 'A' or index == 'R' or index == 'C') has_staged = true;
        if (worktree == 'M' or worktree == 'D') has_modified = true;
    }

    if (has_deleted) len = appendSlice(out, len, "✘");
    if (has_modified) len = appendSlice(out, len, "!");
    if (has_staged) len = appendSlice(out, len, "+");
    if (has_untracked) len = appendSlice(out, len, "?");
    if (has_conflict) len = appendSlice(out, len, "~");
    if (status.ahead > 0) len = appendSlice(out, len, "⇡");
    if (status.behind > 0) len = appendSlice(out, len, "⇣");
    return out[0..len];
}
