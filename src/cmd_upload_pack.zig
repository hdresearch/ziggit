const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const objects = helpers.objects;
const refs = helpers.refs;
const version_mod = @import("version.zig");

/// Minimal git upload-pack implementation (protocol v0/v1).
/// Advertises refs with capabilities, then waits for wants/haves negotiation.
pub fn cmdUploadPack(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var repo_path: ?[]const u8 = null;
    var advertise_refs_only = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--strict")) {
            // ignore
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            _ = args.next(); // skip value
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            // ignore
        } else if (std.mem.eql(u8, arg, "--stateless-rpc")) {
            // ignore for now
        } else if (std.mem.eql(u8, arg, "--advertise-refs")) {
            advertise_refs_only = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            repo_path = arg;
        }
    }

    if (repo_path == null) {
        try platform_impl.writeStderr("fatal: upload-pack requires a repository argument\n");
        std.process.exit(128);
    }

    // Change to the repo directory if needed, find .git
    const path = repo_path.?;
    var git_dir: []const u8 = undefined;

    // Try path/.git first, then path itself (bare repo)
    const dot_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{path});
    defer allocator.free(dot_git);
    const is_dot_git = blk: {
        std.fs.cwd().access(dot_git, .{}) catch break :blk false;
        break :blk true;
    };

    if (is_dot_git) {
        git_dir = dot_git;
    } else {
        // Might be a bare repo
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{path});
        defer allocator.free(head_path);
        std.fs.cwd().access(head_path, .{}) catch {
            try platform_impl.writeStderr("fatal: not a git repository\n");
            std.process.exit(128);
        };
        git_dir = path;
    }

    // Collect all refs
    var ref_list = std.array_list.Managed(RefEntry).init(allocator);
    defer {
        for (ref_list.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.hash);
        }
        ref_list.deinit();
    }

    // Read HEAD
    const head_file = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_file);
    if (std.fs.cwd().readFileAlloc(allocator, head_file, 1024)) |head_content| {
        defer allocator.free(head_content);
        const trimmed = std.mem.trim(u8, head_content, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            // Symbolic ref - resolve it
            const ref_name = trimmed[5..];
            const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name });
            defer allocator.free(ref_path);
            if (std.fs.cwd().readFileAlloc(allocator, ref_path, 1024)) |ref_content| {
                defer allocator.free(ref_content);
                const hash = std.mem.trim(u8, ref_content, " \t\r\n");
                if (hash.len >= 40) {
                    try ref_list.append(.{
                        .name = try allocator.dupe(u8, "HEAD"),
                        .hash = try allocator.dupe(u8, hash[0..40]),
                    });
                }
            } else |_| {
                // HEAD points to unborn branch - try packed-refs
                if (resolvePackedRef(allocator, git_dir, ref_name)) |hash| {
                    try ref_list.append(.{
                        .name = try allocator.dupe(u8, "HEAD"),
                        .hash = hash,
                    });
                } else |_| {}
            }
        } else if (trimmed.len >= 40) {
            // Detached HEAD
            try ref_list.append(.{
                .name = try allocator.dupe(u8, "HEAD"),
                .hash = try allocator.dupe(u8, trimmed[0..40]),
            });
        }
    } else |_| {}

    // Read refs from refs/ directory and packed-refs
    try collectRefs(allocator, git_dir, "refs", &ref_list);
    try collectPackedRefs(allocator, git_dir, &ref_list);

    // Sort refs by name (HEAD should be first)
    // Simple bubble sort to avoid type issues
    var si: usize = 0;
    while (si < ref_list.items.len) : (si += 1) {
        var sj: usize = si + 1;
        while (sj < ref_list.items.len) : (sj += 1) {
            const a_name = ref_list.items[si].name;
            const b_name = ref_list.items[sj].name;
            const swap = blk: {
                if (std.mem.eql(u8, b_name, "HEAD")) break :blk true;
                if (std.mem.eql(u8, a_name, "HEAD")) break :blk false;
                break :blk std.mem.order(u8, a_name, b_name) == .gt;
            };
            if (swap) {
                const tmp = ref_list.items[si];
                ref_list.items[si] = ref_list.items[sj];
                ref_list.items[sj] = tmp;
            }
        }
    }

    const capabilities = "multi_ack thin-pack side-band side-band-64k ofs-delta shallow deepen-since deepen-not deepen-relative no-progress include-tag multi_ack_detailed symref=HEAD:refs/heads/master object-format=sha1 agent=git/2.43.0";

    // Write refs advertisement
    if (ref_list.items.len == 0) {
        // No refs - send capabilities line with null hash
        const line = try std.fmt.allocPrint(allocator, "0000000000000000000000000000000000000000 capabilities^{{}}\x00{s}\n", .{capabilities});
        defer allocator.free(line);
        try writePktLine(platform_impl, line);
    } else {
        for (ref_list.items, 0..) |entry, i| {
            if (i == 0) {
                // First line includes capabilities
                const line = try std.fmt.allocPrint(allocator, "{s} {s}\x00{s}\n", .{ entry.hash, entry.name, capabilities });
                defer allocator.free(line);
                try writePktLine(platform_impl, line);
            } else {
                const line = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ entry.hash, entry.name });
                defer allocator.free(line);
                try writePktLine(platform_impl, line);
            }
        }
    }

    // Flush packet
    try platform_impl.writeStdout("0000");

    if (advertise_refs_only) return;

    // Read client requests (wants/haves)
    // For now, just read until we get a flush packet and handle basic negotiation
    const stdin = std.fs.File.stdin();
    var buf: [65536]u8 = undefined;

    while (true) {
        // Read pkt-line length (4 hex bytes)
        var len_buf: [4]u8 = undefined;
        const bytes_read = stdin.read(&len_buf) catch break;
        if (bytes_read < 4) break;

        if (std.mem.eql(u8, &len_buf, "0000")) {
            // Flush packet - end of request
            break;
        }

        const pkt_len = std.fmt.parseInt(u16, &len_buf, 16) catch break;
        if (pkt_len < 4) break;
        const data_len = pkt_len - 4;
        if (data_len > buf.len) break;

        const data_read = stdin.read(buf[0..data_len]) catch break;
        if (data_read < data_len) break;

        const line_data = buf[0..data_read];
        const trimmed = std.mem.trim(u8, line_data, " \t\r\n");
        _ = trimmed;

        // For a simple case (no wants), just continue reading
    }

    // Send NAK
    try writePktLine(platform_impl, "NAK\n");
}

fn writePktLine(platform_impl: *const platform_mod.Platform, data: []const u8) !void {
    const total_len = data.len + 4;
    var len_hex: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&len_hex, "{x:0>4}", .{total_len}) catch return;
    try platform_impl.writeStdout(&len_hex);
    try platform_impl.writeStdout(data);
}

fn resolvePackedRef(allocator: std.mem.Allocator, git_dir: []const u8, ref_name: []const u8) ![]const u8 {
    const packed_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_path);
    const content = try std.fs.cwd().readFileAlloc(allocator, packed_path, 10 * 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
        // Format: <hash> <refname>
        if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
            const hash = line[0..sp];
            const name = line[sp + 1 ..];
            if (std.mem.eql(u8, name, ref_name) and hash.len >= 40) {
                return try allocator.dupe(u8, hash[0..40]);
            }
        }
    }
    return error.NotFound;
}

const RefEntry = struct {
    name: []const u8,
    hash: []const u8,
};

fn collectRefs(allocator: std.mem.Allocator, git_dir: []const u8, prefix: []const u8, ref_list: *std.array_list.Managed(RefEntry)) !void {
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, prefix });
    defer allocator.free(dir_path);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        if (entry.kind == .directory) {
            defer allocator.free(full_name);
            try collectRefs(allocator, git_dir, full_name, ref_list);
        } else {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, full_name });
            defer allocator.free(file_path);
            if (std.fs.cwd().readFileAlloc(allocator, file_path, 1024)) |content| {
                defer allocator.free(content);
                const hash = std.mem.trim(u8, content, " \t\r\n");
                if (hash.len >= 40) {
                    try ref_list.append(.{
                        .name = full_name,
                        .hash = try allocator.dupe(u8, hash[0..40]),
                    });
                } else {
                    allocator.free(full_name);
                }
            } else |_| {
                allocator.free(full_name);
            }
        }
    }
}

fn collectPackedRefs(allocator: std.mem.Allocator, git_dir: []const u8, ref_list: *std.array_list.Managed(RefEntry)) !void {
    const packed_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_path);
    const content = std.fs.cwd().readFileAlloc(allocator, packed_path, 10 * 1024 * 1024) catch return;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
        if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
            const hash = line[0..sp];
            const name = line[sp + 1 ..];
            if (hash.len >= 40 and std.mem.startsWith(u8, name, "refs/")) {
                // Check if already in list (loose refs take precedence)
                var found = false;
                for (ref_list.items) |existing| {
                    if (std.mem.eql(u8, existing.name, name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try ref_list.append(.{
                        .name = try allocator.dupe(u8, name),
                        .hash = try allocator.dupe(u8, hash[0..40]),
                    });
                }
            }
        }
    }
}
