// Auto-generated from main_common.zig - cmd_show_index
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");

// Re-export commonly used types from helpers
const objects = helpers.objects;
const index_mod = helpers.index_mod;
const refs = helpers.refs;
const tree_mod = helpers.tree_mod;
const gitignore_mod = helpers.gitignore_mod;
const config_mod = helpers.config_mod;
const config_helpers_mod = helpers.config_helpers_mod;
const diff_mod = helpers.diff_mod;
const diff_stats_mod = helpers.diff_stats_mod;
const network = helpers.network;
const zlib_compat_mod = helpers.zlib_compat_mod;
const build_options = @import("build_options");
const version_mod = @import("version.zig");
const wildmatch_mod = @import("wildmatch.zig");

pub fn nativeCmdShowIndex(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    _ = args;
    _ = command_index;
    const allocator = std.heap.page_allocator;
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    
    var header: [8]u8 = undefined;
    const nread = stdin.read(&header) catch {
        try platform_impl.writeStderr("fatal: unable to read pack index\n");
        std.process.exit(128);
    };
    if (nread < 8) {
        try platform_impl.writeStderr("fatal: unable to read pack index\n");
        std.process.exit(128);
    }
    
    const magic = std.mem.readInt(u32, header[0..4], .big);
    const version = std.mem.readInt(u32, header[4..8], .big);
    
    if (magic == 0xff744f63 and version == 2) {
        var fanout_bytes: [256 * 4]u8 = undefined;
        const fr = stdin.readAll(&fanout_bytes) catch {
            try platform_impl.writeStderr("fatal: unable to read fanout\n");
            std.process.exit(128);
        };
        if (fr < 256 * 4) {
            try platform_impl.writeStderr("fatal: truncated pack index\n");
            std.process.exit(128);
        }
        const num_objects = std.mem.readInt(u32, fanout_bytes[255 * 4 ..][0..4], .big);
        
        const hash_data = allocator.alloc(u8, num_objects * 20) catch {
            std.process.exit(128);
        };
        defer allocator.free(hash_data);
        _ = stdin.readAll(hash_data) catch {};
        
        const crc_data = allocator.alloc(u8, num_objects * 4) catch {
            std.process.exit(128);
        };
        defer allocator.free(crc_data);
        _ = stdin.readAll(crc_data) catch {};
        
        const offset_data = allocator.alloc(u8, num_objects * 4) catch {
            std.process.exit(128);
        };
        defer allocator.free(offset_data);
        _ = stdin.readAll(offset_data) catch {};
        
        var i: u32 = 0;
        while (i < num_objects) : (i += 1) {
            const offset = std.mem.readInt(u32, offset_data[i * 4 ..][0..4], .big);
            const hash_bytes = hash_data[i * 20 ..][0..20];
            var hash_hex: [40]u8 = undefined;
            for (hash_bytes, 0..) |b, j| {
                const hex_chars = "0123456789abcdef";
                hash_hex[j * 2] = hex_chars[b >> 4];
                hash_hex[j * 2 + 1] = hex_chars[b & 0xf];
            }
            const crc = std.mem.readInt(u32, crc_data[i * 4 ..][0..4], .big);
            const out = try std.fmt.allocPrint(allocator, "{d} {s} ({x:0>8})\n", .{ offset, hash_hex, crc });
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        }
    } else {
        try platform_impl.writeStderr("fatal: unsupported pack index version\n");
        std.process.exit(128);
    }
}
