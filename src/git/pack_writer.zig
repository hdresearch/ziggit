const std = @import("std");

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
    const checksum_hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(stored_checksum)});
    errdefer allocator.free(checksum_hex);

    // Use stack buffer for pack directory path
    var pack_dir_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const pack_dir = std.fmt.bufPrint(&pack_dir_buf, "{s}/objects/pack", .{git_dir}) catch return error.PathTooLong;
    std.fs.cwd().makePath(pack_dir) catch {};

    // Use stack buffer for pack file path
    var pack_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
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
