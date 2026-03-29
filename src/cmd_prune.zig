// Auto-generated from main_common.zig - cmd_prune
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

pub fn nativeCmdPrune(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var verbose = false;
    var dry_run = false;
    var expire: []const u8 = "";
    var no_expire = false;
    var positional_args = std.ArrayListUnmanaged([]const u8){};
    defer positional_args.deinit(allocator);
    var saw_dashdash = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (saw_dashdash) {
            positional_args.append(allocator, arg) catch {};
            continue;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.startsWith(u8, arg, "--expire=")) {
            expire = arg["--expire=".len..];
        } else if (std.mem.eql(u8, arg, "--expire")) {
            i += 1;
            if (i < args.len) {
                expire = args[i];
            } else {
                try platform_impl.writeStderr("error: option `expire' requires a value\n");
                std.process.exit(128);
            }
        } else if (std.mem.eql(u8, arg, "--no-expire")) {
            no_expire = true;
        } else if (std.mem.eql(u8, arg, "--progress") or std.mem.eql(u8, arg, "--no-progress")) {
            // Accepted
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStderr("usage: git prune [-n] [-v] [--progress] [--expire <time>] [--] [<head>...]\n");
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--")) {
            saw_dashdash = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            const msg = std.fmt.allocPrint(allocator, "error: unknown option `{s}'\nusage: git prune [-n] [-v] [--progress] [--expire <time>] [--] [<head>...]\n", .{arg}) catch unreachable;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        } else {
            positional_args.append(allocator, arg) catch {};
        }
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // helpers.Validate positional args are valid object helpers.refs
    for (positional_args.items) |pos_arg| {
        // helpers.Try to resolve the arg as an object reference
        const resolved = helpers.resolveRevision(git_dir, pos_arg, platform_impl, allocator) catch {
            const msg = std.fmt.allocPrint(allocator, "fatal: not a valid object name: '{s}'\n", .{pos_arg}) catch unreachable;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        allocator.free(resolved);
    }

    // helpers.Validate expire value before proceeding
    if (!no_expire and expire.len > 0) {
        _ = helpers.parseExpireTime(expire) catch {
            const msg = std.fmt.allocPrint(allocator, "fatal: malformed expiration date '{s}'\n", .{expire}) catch unreachable;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
    }

    try helpers.doNativePrune(allocator, git_dir, platform_impl, expire);
}


pub fn nativeCmdPrunePacked(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    _ = args;
    _ = command_index;
    const allocator = std.heap.page_allocator;
    
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);
    
    const objects_dir = try std.fmt.allocPrint(allocator, "{s}/objects", .{git_path});
    defer allocator.free(objects_dir);
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/pack", .{objects_dir});
    defer allocator.free(pack_dir);
    
    // helpers.Collect packed object hashes from idx files
    var packed_objs = std.StringHashMap(void).init(allocator);
    defer {
        var kit = packed_objs.keyIterator();
        while (kit.next()) |key| allocator.free(@constCast(key.*));
        packed_objs.deinit();
    }
    
    if (std.fs.cwd().openDir(pack_dir, .{ .iterate = true })) |*dir| {
        defer @constCast(dir).close();
        var diter = dir.iterate();
        while (diter.next() catch null) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".idx")) {
                const idx_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name });
                defer allocator.free(idx_path);
                const idx_data = platform_impl.fs.readFile(allocator, idx_path) catch continue;
                defer allocator.free(idx_data);
                if (idx_data.len < 8 + 256 * 4) continue;
                const idx_magic = std.mem.readInt(u32, idx_data[0..4], .big);
                const idx_ver = std.mem.readInt(u32, idx_data[4..8], .big);
                if (idx_magic != 0xff744f63 or idx_ver != 2) continue;
                const n = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
                const hash_start: usize = 8 + 256 * 4;
                var oi: u32 = 0;
                while (oi < n) : (oi += 1) {
                    const off = hash_start + oi * 20;
                    if (off + 20 > idx_data.len) break;
                    var hex: [40]u8 = undefined;
                    for (idx_data[off..][0..20], 0..) |b, j| {
                        const hc = "0123456789abcdef";
                        hex[j * 2] = hc[b >> 4];
                        hex[j * 2 + 1] = hc[b & 0xf];
                    }
                    const key = allocator.dupe(u8, &hex) catch continue;
                    packed_objs.put(key, {}) catch {};
                }
            }
        }
    } else |_| {}
    
    // helpers.Remove loose helpers.objects that are in packs
    for (0..256) |pv| {
        const ph = try std.fmt.allocPrint(allocator, "{x:0>2}", .{pv});
        defer allocator.free(ph);
        const ld = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir, ph });
        defer allocator.free(ld);
        if (std.fs.cwd().openDir(ld, .{ .iterate = true })) |*dir| {
            defer @constCast(dir).close();
            var diter = dir.iterate();
            while (diter.next() catch null) |entry| {
                if (entry.name.len == 38) {
                    const fh = try std.fmt.allocPrint(allocator, "{s}{s}", .{ ph, entry.name });
                    defer allocator.free(fh);
                    if (packed_objs.contains(fh)) {
                        const fp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ld, entry.name });
                        defer allocator.free(fp);
                        std.fs.cwd().deleteFile(fp) catch {};
                    }
                }
            }
        } else |_| {}
    }
}
