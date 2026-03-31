// checkout-index command
const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const objects = helpers.objects;
const index_mod = helpers.index_mod;

fn hexFromSha1(sha1: [20]u8) [40]u8 {
    const hex_chars = "0123456789abcdef";
    var result: [40]u8 = undefined;
    for (sha1, 0..) |b, i| {
        result[i * 2] = hex_chars[b >> 4];
        result[i * 2 + 1] = hex_chars[b & 0xf];
    }
    return result;
}

pub fn cmdCheckoutIndex(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var all = false;
    var force = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        }
    }

    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch return;
    defer allocator.free(git_path);
    const repo_root = std.fs.path.dirname(git_path) orelse ".";

    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
    defer idx.deinit();

    if (all) {
        for (idx.entries.items) |entry| {
            const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path }) catch continue;
            defer allocator.free(full_path);

            // Create parent directories
            if (std.fs.path.dirname(entry.path)) |dir| {
                const dir_full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, dir }) catch continue;
                defer allocator.free(dir_full);
                std.fs.cwd().makePath(dir_full) catch {};
            }

            // Read blob and write to file
            const hex = hexFromSha1(entry.sha1);
            const obj = objects.GitObject.load(&hex, git_path, platform_impl, allocator) catch continue;
            defer obj.deinit(allocator);
            
            if (force) {
                std.fs.cwd().deleteFile(full_path) catch {};
            }
            
            const file = std.fs.cwd().createFile(full_path, .{}) catch continue;
            defer file.close();
            file.writeAll(obj.data) catch continue;
        }
    }
}
