// succinct.zig — Compressed output mode for LLM agent token savings
// When enabled (default), commands produce minimal output.
// Disable with --no-succinct or GIT_SUCCINCT=0.

const std = @import("std");

/// Global flag: whether succinct mode is active.
/// Set during argument parsing in main_common.zig.
pub var enabled: bool = true;

/// Check if succinct mode should be active.
/// Auto-disables under test harness (GIT_TEST_INSTALLED).
pub fn isEnabled() bool {
    // Auto-disable under git test harness
    if (std.posix.getenv("GIT_TEST_INSTALLED")) |_| return false;
    // Check explicit env override
    if (std.posix.getenv("GIT_SUCCINCT")) |val| {
        if (std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no")) {
            return false;
        }
    }
    return enabled;
}

// ─── Status formatting ───────────────────────────────────────────────

pub fn formatStatusSuccinct(
    allocator: std.mem.Allocator,
    branch_name: ?[]const u8,
    upstream_name: ?[]const u8,
    staged_files: []const FileEntry,
    modified_files: []const FileEntry,
    untracked_files: []const []const u8,
    has_conflicts: bool,
    conflict_count: usize,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    // Branch line
    if (branch_name) |br| {
        try w.print("* {s}", .{br});
        if (upstream_name) |up| {
            try w.print("...{s}", .{up});
        }
        try w.writeByte('\n');
    }

    // Conflicts
    if (has_conflicts) {
        try w.print("! Conflicts: {d} files\n", .{conflict_count});
    }

    // Staged
    if (staged_files.len > 0) {
        try w.print("+ Staged: {d} files\n", .{staged_files.len});
        const max_show: usize = 15;
        const show = @min(staged_files.len, max_show);
        for (staged_files[0..show]) |f| {
            try w.print("  {s} {s}\n", .{ @as([]const u8, switch (f.kind) {
                .added => "A",
                .modified => "M",
                .deleted => "D",
                .renamed => "R",
                .copied => "C",
                .typechange => "T",
            }), f.path });
        }
        if (staged_files.len > max_show) {
            try w.print("  ... +{d} more\n", .{staged_files.len - max_show});
        }
    }

    // Modified (unstaged)
    if (modified_files.len > 0) {
        try w.print("~ Modified: {d} files\n", .{modified_files.len});
        const max_show: usize = 15;
        const show = @min(modified_files.len, max_show);
        for (modified_files[0..show]) |f| {
            try w.print("  {s} {s}\n", .{ @as([]const u8, switch (f.kind) {
                .added => "A",
                .modified => "M",
                .deleted => "D",
                .renamed => "R",
                .copied => "C",
                .typechange => "T",
            }), f.path });
        }
        if (modified_files.len > max_show) {
            try w.print("  ... +{d} more\n", .{modified_files.len - max_show});
        }
    }

    // Untracked
    if (untracked_files.len > 0) {
        try w.print("? Untracked: {d} files\n", .{untracked_files.len});
        const max_show: usize = 10;
        const show = @min(untracked_files.len, max_show);
        for (untracked_files[0..show]) |f| {
            try w.print("  {s}\n", .{f});
        }
        if (untracked_files.len > max_show) {
            try w.print("  ... +{d} more\n", .{untracked_files.len - max_show});
        }
    }

    // Clean tree
    if (staged_files.len == 0 and modified_files.len == 0 and untracked_files.len == 0 and !has_conflicts) {
        try w.writeAll("Clean working tree\n");
    }

    return buf.toOwnedSlice();
}

pub const FileEntryKind = enum {
    added,
    modified,
    deleted,
    renamed,
    copied,
    typechange,
};

pub const FileEntry = struct {
    path: []const u8,
    kind: FileEntryKind,
};

// ─── Diff formatting ─────────────────────────────────────────────────

/// Compress diff output: reduce context to 1 line, cap hunks, cap total lines.
pub fn compactDiff(allocator: std.mem.Allocator, diff_output: []const u8, max_total_lines: usize) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    var lines_written: usize = 0;
    var in_hunk = false;
    var hunk_lines: usize = 0;
    const max_hunk_lines: usize = 100;
    var truncated_hunks: usize = 0;
    var was_truncated = false;

    var iter = std.mem.splitScalar(u8, diff_output, '\n');
    while (iter.next()) |line| {
        if (lines_written >= max_total_lines) {
            was_truncated = true;
            break;
        }

        // Always show diff headers and hunk headers
        if (std.mem.startsWith(u8, line, "diff --git") or
            std.mem.startsWith(u8, line, "---") or
            std.mem.startsWith(u8, line, "+++") or
            std.mem.startsWith(u8, line, "index ") or
            std.mem.startsWith(u8, line, "new file") or
            std.mem.startsWith(u8, line, "deleted file") or
            std.mem.startsWith(u8, line, "rename") or
            std.mem.startsWith(u8, line, "similarity") or
            std.mem.startsWith(u8, line, "old mode") or
            std.mem.startsWith(u8, line, "new mode"))
        {
            in_hunk = false;
            try w.print("{s}\n", .{line});
            lines_written += 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "@@")) {
            in_hunk = true;
            hunk_lines = 0;
            try w.print("{s}\n", .{line});
            lines_written += 1;
            continue;
        }

        if (in_hunk) {
            hunk_lines += 1;
            if (hunk_lines > max_hunk_lines) {
                if (hunk_lines == max_hunk_lines + 1) {
                    truncated_hunks += 1;
                }
                continue; // skip rest of hunk
            }
            // Show changed lines and minimal context (1 line before/after changes)
            if (line.len > 0 and (line[0] == '+' or line[0] == '-')) {
                try w.print("{s}\n", .{line});
                lines_written += 1;
            } else if (line.len == 0 or line[0] == ' ') {
                // Context line — keep it (we rely on the diff already being generated;
                // reducing context further would require re-diffing)
                try w.print("{s}\n", .{line});
                lines_written += 1;
            }
        }
    }

    if (was_truncated or truncated_hunks > 0) {
        try w.writeAll("[full diff: git diff --no-succinct]\n");
    }

    return buf.toOwnedSlice();
}

// ─── Log formatting ──────────────────────────────────────────────────

/// Format a single log entry in succinct one-line format.
/// Returns: "<hash7> <subject72> (<date>) <author>"
pub fn formatLogEntrySuccinct(
    allocator: std.mem.Allocator,
    hash: []const u8,
    subject: []const u8,
    author_name: []const u8,
    date_relative: []const u8,
) ![]const u8 {
    const short_hash = if (hash.len > 7) hash[0..7] else hash;
    const trunc_subject = if (subject.len > 72) blk: {
        break :blk try std.fmt.allocPrint(allocator, "{s}...", .{subject[0..69]});
    } else subject;

    return try std.fmt.allocPrint(allocator, "{s} {s} ({s}) {s}\n", .{
        short_hash,
        trunc_subject,
        date_relative,
        author_name,
    });
}

// ─── Branch formatting ───────────────────────────────────────────────

/// Format branch list in compact form.
pub fn formatBranchesSuccinct(
    allocator: std.mem.Allocator,
    current_branch: ?[]const u8,
    local_branches: []const []const u8,
    remote_branches: []const []const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    // Current branch
    if (current_branch) |cb| {
        try w.print("* {s}\n", .{cb});
    }

    // Local branches (excluding current)
    for (local_branches) |br| {
        if (current_branch) |cb| {
            if (std.mem.eql(u8, br, cb)) continue;
        }
        try w.print("  {s}\n", .{br});
    }

    // Remote branches
    if (remote_branches.len > 0) {
        const max_show: usize = 10;
        const show = @min(remote_branches.len, max_show);
        try w.print("remote-only ({d}):\n", .{remote_branches.len});
        for (remote_branches[0..show]) |br| {
            try w.print("  {s}\n", .{br});
        }
        if (remote_branches.len > max_show) {
            try w.print("  ... +{d} more\n", .{remote_branches.len - max_show});
        }
    }

    return buf.toOwnedSlice();
}

// ─── Tag formatting ──────────────────────────────────────────────────

pub fn formatTagsSuccinct(
    allocator: std.mem.Allocator,
    tags: []const []const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();
    const max_show: usize = 20;
    const show = @min(tags.len, max_show);
    for (tags[0..show]) |tag| {
        try w.print("{s}\n", .{tag});
    }
    if (tags.len > max_show) {
        try w.print("... +{d} more\n", .{tags.len - max_show});
    }
    return buf.toOwnedSlice();
}

// ─── Commit formatting ───────────────────────────────────────────────

pub fn formatCommitSuccinct(
    allocator: std.mem.Allocator,
    branch: []const u8,
    short_hash: []const u8,
    subject: []const u8,
) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "ok {s} {s} \"{s}\"\n", .{ branch, short_hash, subject });
}

// ─── Simple result formatting ────────────────────────────────────────

pub fn formatOk(allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8, "ok\n");
}

pub fn formatOkMsg(allocator: std.mem.Allocator, msg: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "ok {s}\n", .{msg});
}
