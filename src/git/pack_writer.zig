const std = @import("std");

/// A ref name -> hash mapping for updating refs after clone/fetch.
pub const RefUpdate = struct {
    name: []const u8, // e.g. "refs/heads/main", "refs/tags/v1.0"
    hash: []const u8, // 40-char hex SHA-1
};

/// Update refs after a clone operation.
/// For bare repos: writes refs/heads/*, refs/tags/* directly and sets HEAD.
/// For non-bare repos: writes refs/remotes/origin/* for branches, refs/tags/* for tags, and sets HEAD.
pub fn updateRefsAfterClone(allocator: std.mem.Allocator, git_dir: []const u8, ref_updates: []const RefUpdate, bare: bool) !void {
    var head_ref: ?[]const u8 = null;
    var head_hash: ?[]const u8 = null;

    // First pass: find HEAD hash if present (remote tells us what the default branch is)
    for (ref_updates) |ref| {
        if (std.mem.eql(u8, ref.name, "HEAD")) {
            head_hash = ref.hash;
            break;
        }
    }

    for (ref_updates) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            if (bare) {
                // Bare clone: write directly to refs/heads/*
                try writeRefFile(allocator, git_dir, ref.name, ref.hash);
            } else {
                // Non-bare: write to refs/remotes/origin/*
                const branch = ref.name["refs/heads/".len..];
                const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{branch});
                defer allocator.free(remote_ref);
                try writeRefFile(allocator, git_dir, remote_ref, ref.hash);
            }
            // Track first branch as HEAD target
            if (head_ref == null) {
                head_ref = ref.name;
            }
            // If remote's HEAD hash matches this branch, prefer it
            if (head_hash) |hh| {
                if (std.mem.eql(u8, ref.hash, hh)) {
                    head_ref = ref.name;
                }
            }
            // Prefer "main" or "master" as fallback
            const branch = ref.name["refs/heads/".len..];
            if (std.mem.eql(u8, branch, "main") or std.mem.eql(u8, branch, "master")) {
                // Only override if we don't already have a HEAD-hash match
                if (head_hash == null) {
                    head_ref = ref.name;
                }
            }
        } else if (std.mem.startsWith(u8, ref.name, "refs/tags/")) {
            // Tags always go to refs/tags/* in both bare and non-bare
            try writeRefFile(allocator, git_dir, ref.name, ref.hash);
        }
    }

    // Write HEAD as symbolic ref
    if (head_ref) |hr| {
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
        defer allocator.free(head_path);
        const content = try std.fmt.allocPrint(allocator, "ref: {s}\n", .{hr});
        defer allocator.free(content);
        const file = try std.fs.cwd().createFile(head_path, .{});
        defer file.close();
        try file.writeAll(content);
    }
}

/// Update refs after a fetch operation.
/// Writes refs/remotes/origin/* for branches, refs/tags/* for tags, and FETCH_HEAD.
pub fn updateRefsAfterFetch(allocator: std.mem.Allocator, git_dir: []const u8, ref_updates: []const RefUpdate) !void {
    var fetch_head = std.ArrayList(u8).init(allocator);
    defer fetch_head.deinit();

    for (ref_updates) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            const branch = ref.name["refs/heads/".len..];
            const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{branch});
            defer allocator.free(remote_ref);
            try writeRefFile(allocator, git_dir, remote_ref, ref.hash);

            // Add to FETCH_HEAD
            try fetch_head.writer().print("{s}\t\tbranch '{s}' of remote\n", .{ ref.hash, branch });
        } else if (std.mem.startsWith(u8, ref.name, "refs/tags/")) {
            try writeRefFile(allocator, git_dir, ref.name, ref.hash);
        }
    }

    // Write FETCH_HEAD
    if (fetch_head.items.len > 0) {
        const fh_path = try std.fmt.allocPrint(allocator, "{s}/FETCH_HEAD", .{git_dir});
        defer allocator.free(fh_path);
        const file = try std.fs.cwd().createFile(fh_path, .{});
        defer file.close();
        try file.writeAll(fetch_head.items);
    }
}

/// Write a ref file: {git_dir}/{ref_name} containing the hash.
fn writeRefFile(allocator: std.mem.Allocator, git_dir: []const u8, ref_name: []const u8, hash: []const u8) !void {
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name });
    defer allocator.free(full_path);

    // Ensure parent directory exists
    if (std.mem.lastIndexOfScalar(u8, full_path, '/')) |last_slash| {
        std.fs.cwd().makePath(full_path[0..last_slash]) catch {};
    }

    const content = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
    defer allocator.free(content);

    const file = try std.fs.cwd().createFile(full_path, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Save pack data to disk at {git_dir}/objects/pack/pack-{sha1_hex}.pack
/// Validates PACK magic, version, and checksum. Returns the sha1 hex string (owned by caller).
pub fn savePack(allocator: std.mem.Allocator, git_dir: []const u8, pack_bytes: []const u8) ![]u8 {
    return savePackInternal(allocator, git_dir, pack_bytes, true);
}

/// Save pack data without re-verifying SHA-1 checksum (trusts the stored checksum).
/// Use this when pack data comes from a trusted source (e.g., just downloaded via HTTPS).
pub fn savePackFast(allocator: std.mem.Allocator, git_dir: []const u8, pack_bytes: []const u8) ![]u8 {
    return savePackInternal(allocator, git_dir, pack_bytes, false);
}

fn savePackInternal(allocator: std.mem.Allocator, git_dir: []const u8, pack_bytes: []const u8, verify: bool) ![]u8 {
    // Validate minimum size: 12 header + 20 checksum
    if (pack_bytes.len < 32) return error.PackFileTooSmall;

    // Validate PACK magic
    if (!std.mem.eql(u8, pack_bytes[0..4], "PACK")) return error.InvalidPackSignature;

    // Validate version (must be 2)
    const version = std.mem.readInt(u32, pack_bytes[4..8], .big);
    if (version != 2) return error.UnsupportedPackVersion;

    // Read object count (for validation - must be readable)
    _ = std.mem.readInt(u32, pack_bytes[8..12], .big);

    const content_end = pack_bytes.len - 20;
    const stored_checksum = pack_bytes[content_end..][0..20];

    if (verify) {
        // Verify SHA-1 checksum (expensive for large packs)
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(pack_bytes[0..content_end]);
        var computed: [20]u8 = undefined;
        hasher.final(&computed);

        if (!std.mem.eql(u8, &computed, stored_checksum)) {
            return error.PackChecksumMismatch;
        }
    }

    // Build hex string from stored checksum (avoids recomputing when verify=false)
    const checksum_hex_arr = std.fmt.bytesToHex(stored_checksum.*, .lower);
    const checksum_hex = try allocator.dupe(u8, &checksum_hex_arr);
    errdefer allocator.free(checksum_hex);

    // Use stack buffer for pack directory path
    var pack_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pack_dir = std.fmt.bufPrint(&pack_dir_buf, "{s}/objects/pack", .{git_dir}) catch return error.PathTooLong;
    std.fs.cwd().makePath(pack_dir) catch {};

    // Use stack buffer for pack file path
    var pack_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pack_path = std.fmt.bufPrint(&pack_path_buf, "{s}/pack-{s}.pack", .{ pack_dir, checksum_hex }) catch return error.PathTooLong;

    const file = try std.fs.cwd().createFile(pack_path, .{});
    defer file.close();
    try file.writeAll(pack_bytes);

    return checksum_hex;
}

/// Return the full path to the .pack file for a given checksum hex
pub fn packPath(allocator: std.mem.Allocator, git_dir: []const u8, checksum_hex: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.pack", .{ git_dir, checksum_hex });
}

/// Return the full path to the .idx file for a given checksum hex
pub fn idxPath(allocator: std.mem.Allocator, git_dir: []const u8, checksum_hex: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.idx", .{ git_dir, checksum_hex });
}
