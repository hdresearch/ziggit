// Auto-generated from main_common.zig - cmd_verify
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

pub fn nativeCmdVerifyCommit(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    const allocator = std.heap.page_allocator;
    const rest = args[command_index + 1 ..];
    
    for (rest) |arg| {
        if (arg.len > 0 and arg[0] == '-') continue;
        
        const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
            try platform_impl.writeStderr("fatal: not a git repository\n");
            std.process.exit(128);
        };
        defer allocator.free(git_path);
        
        const hash = helpers.resolveRevision(git_path, arg, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "error: {s}: no such commit\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };
        defer allocator.free(hash);
        
        const obj = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "error: {s}: cannot read object\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };
        defer obj.deinit(allocator);
        
        if (std.mem.indexOf(u8, obj.data, "gpgsig ") == null) {
            try platform_impl.writeStderr("error: no signature found\n");
            std.process.exit(1);
        }
    }
}


pub fn nativeCmdVerifyTag(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    const allocator = std.heap.page_allocator;
    const rest = args[command_index + 1 ..];
    
    for (rest) |arg| {
        if (arg.len > 0 and arg[0] == '-') continue;
        
        const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
            try platform_impl.writeStderr("fatal: not a git repository\n");
            std.process.exit(128);
        };
        defer allocator.free(git_path);
        
        const ref_str = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{arg});
        defer allocator.free(ref_str);
        
        const tag_hash_opt = refs.resolveRef(git_path, ref_str, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "error: {s}: no such tag\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };
        const tag_hash = tag_hash_opt orelse {
            const msg = try std.fmt.allocPrint(allocator, "error: {s}: no such tag\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };
        defer allocator.free(tag_hash);
        
        const obj = objects.GitObject.load(tag_hash, git_path, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "error: {s}: cannot read tag\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };
        defer obj.deinit(allocator);
        
        if (obj.type != .tag) {
            const msg = try std.fmt.allocPrint(allocator, "error: {s}: cannot verify a non-tag object\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        }
        
        if (std.mem.indexOf(u8, obj.data, "-----BEGIN") == null) {
            try platform_impl.writeStderr("error: no signature found\n");
            std.process.exit(1);
        }
    }
}
