// Auto-generated from main_common.zig - cmd_reflog
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

pub fn nativeCmdReflog(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var subcmd: []const u8 = "show";
    var ref_name: []const u8 = "HEAD";
    var ref_name_set = false;
    var end_of_options = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (end_of_options) {
            ref_name = arg;
            ref_name_set = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--") or std.mem.eql(u8, arg, "--end-of-options")) {
            end_of_options = true;
        } else if (std.mem.eql(u8, arg, "show") or std.mem.eql(u8, arg, "expire") or
            std.mem.eql(u8, arg, "delete") or std.mem.eql(u8, arg, "exists"))
        {
            subcmd = arg;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git reflog [show|expire|delete|exists] [<ref>]\n");
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-n") or
            std.mem.startsWith(u8, arg, "--expire=") or std.mem.eql(u8, arg, "--verbose") or
            std.mem.eql(u8, arg, "--rewrite") or std.mem.eql(u8, arg, "--updateref") or
            std.mem.eql(u8, arg, "--stale-fix") or std.mem.eql(u8, arg, "--dry-run"))
        {
            // Accepted flags
            if (std.mem.eql(u8, arg, "-n")) {
                i += 1; // skip count
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // helpers.Unknown option
            if (std.mem.eql(u8, subcmd, "exists")) {
                const emsg = try std.fmt.allocPrint(allocator, "error: unknown option '{s}'\nusage: git reflog exists <ref>\n", .{arg});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(129);
            }
        } else {
            ref_name = arg;
            ref_name_set = true;
        }
    }

    // "exists" with no ref should exit 129
    if (std.mem.eql(u8, subcmd, "exists") and !ref_name_set) {
        try platform_impl.writeStderr("usage: git reflog exists <ref>\n");
        std.process.exit(129);
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    if (std.mem.eql(u8, subcmd, "show")) {
        // helpers.Read reflog file
        var reflog_path: []const u8 = undefined;
        if (std.mem.eql(u8, ref_name, "HEAD")) {
            reflog_path = std.fmt.allocPrint(allocator, "{s}/logs/HEAD", .{git_dir}) catch unreachable;
        } else if (std.mem.startsWith(u8, ref_name, "refs/")) {
            reflog_path = std.fmt.allocPrint(allocator, "{s}/logs/{s}", .{ git_dir, ref_name }) catch unreachable;
        } else {
            reflog_path = std.fmt.allocPrint(allocator, "{s}/logs/refs/heads/{s}", .{ git_dir, ref_name }) catch unreachable;
        }
        defer allocator.free(reflog_path);

        const content = std.fs.cwd().readFileAlloc(allocator, reflog_path, 10 * 1024 * 1024) catch {
            // helpers.No reflog
            return;
        };
        defer allocator.free(content);

        // helpers.Parse and display reflog entries in reverse order
        var entries = std.array_list.Managed([]const u8).init(allocator);
        defer entries.deinit();
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) {
                try entries.append(line);
            }
        }

        // helpers.Output in reverse order
        var entry_idx: usize = entries.items.len;
        var seq: usize = 0;
        while (entry_idx > 0) {
            entry_idx -= 1;
            const line = entries.items[entry_idx];
            // Format: <old-sha1> <new-sha1> <author> <timestamp> <tz>\t<message>
            if (std.mem.indexOfScalar(u8, line, '\t')) |tab| {
                const msg = line[tab + 1..];
                // helpers.Extract new sha
                if (line.len >= 82) {
                    const new_sha = line[41..81];
                    const selector = std.fmt.allocPrint(allocator, "{s}@{{{d}}}", .{ ref_name, seq }) catch continue;
                    defer allocator.free(selector);
                    const output = std.fmt.allocPrint(allocator, "{s} {s}: {s}\n", .{ new_sha[0..@min(7, new_sha.len)], selector, msg }) catch continue;
                    defer allocator.free(output);
                    try platform_impl.writeStdout(output);
                }
            }
            seq += 1;
        }
    } else if (std.mem.eql(u8, subcmd, "expire")) {
        // Expire old reflog entries - for now, no-op
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        // helpers.Delete specific reflog entries - for now, no-op
    } else if (std.mem.eql(u8, subcmd, "exists")) {
        // helpers.Check if a reflog exists - try multiple paths
        var found_reflog = false;
        const p1 = std.fmt.allocPrint(allocator, "{s}/logs/{s}", .{ git_dir, ref_name }) catch unreachable;
        defer allocator.free(p1);
        if (std.fs.cwd().statFile(p1)) |_| { found_reflog = true; } else |_| {}
        if (!found_reflog and std.mem.startsWith(u8, ref_name, "refs/heads/")) {
            const branch = ref_name["refs/heads/".len..];
            const p2 = std.fmt.allocPrint(allocator, "{s}/logs/{s}", .{ git_dir, branch }) catch unreachable;
            defer allocator.free(p2);
            if (std.fs.cwd().statFile(p2)) |_| { found_reflog = true; } else |_| {}
        }
        if (!found_reflog and !std.mem.startsWith(u8, ref_name, "refs/")) {
            const p3 = std.fmt.allocPrint(allocator, "{s}/logs/refs/heads/{s}", .{ git_dir, ref_name }) catch unreachable;
            defer allocator.free(p3);
            if (std.fs.cwd().statFile(p3)) |_| { found_reflog = true; } else |_| {}
        }
        if (!found_reflog) std.process.exit(1);
    }
}


pub fn shouldLogRef(git_dir: []const u8, ref_name: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) bool {
    // helpers.Check core.logAllRefUpdates config
    const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_dir}) catch return false;
    defer allocator.free(config_path);
    const config_data = platform_impl.fs.readFile(allocator, config_path) catch return false;
    defer allocator.free(config_data);
    
    if (helpers.parseConfigValue(config_data, "core.logallrefupdates", allocator) catch null) |val| {
        defer allocator.free(val);
        if (std.ascii.eqlIgnoreCase(val, "always")) return true;
        if (std.ascii.eqlIgnoreCase(val, "true")) {
            // helpers.Only log refs/heads/* and helpers.HEAD
            return std.mem.startsWith(u8, ref_name, "refs/heads/") or std.mem.eql(u8, ref_name, "HEAD");
        }
    }
    return false;
}
