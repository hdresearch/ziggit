// Auto-generated from main_common.zig - cmd_mktree
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

pub fn nativeCmdMktree(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var missing_ok = false;
    var batch = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--missing")) {
            missing_ok = true;
        } else if (std.mem.eql(u8, arg, "--batch")) {
            batch = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git mktree [--missing] [--batch]\n");
            std.process.exit(129);
        }
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // helpers.Read tree entries from stdin
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const stdin_data = stdin.readToEndAlloc(allocator, 100 * 1024 * 1024) catch {
        try platform_impl.writeStderr("fatal: error reading from stdin\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(stdin_data);

    var entries = std.ArrayList(objects.TreeEntry).init(allocator);
    defer entries.deinit();

    var lines = std.mem.splitScalar(u8, stdin_data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Format: <mode> <type> <hash>\t<name>
        // or: <mode> helpers.SP <type> helpers.SP <hash> TAB <name>
        if (std.mem.indexOfScalar(u8, line, '\t')) |tab_idx| {
            const name = line[tab_idx + 1..];
            // Reject recursive ls-tree output (paths with '/')
            if (std.mem.indexOfScalar(u8, name, '/') != null) {
                try platform_impl.writeStderr("fatal: path with slash in mktree input: ");
                try platform_impl.writeStderr(name);
                try platform_impl.writeStderr("\n");
                std.process.exit(128);
            }
            const prefix = line[0..tab_idx];
            // helpers.Split prefix by spaces
            var parts = std.mem.splitScalar(u8, prefix, ' ');
            const mode = parts.next() orelse continue;
            _ = parts.next(); // type
            const hash = parts.next() orelse continue;
            try entries.append(objects.TreeEntry.init(mode, name, hash));
        }
    }

    // helpers.Sort entries by name (git tree sorting: directories get trailing '/' for comparison)
    const SortCtx = struct {
        pub fn lessThan(_: @This(), a: objects.TreeEntry, b: objects.TreeEntry) bool {
            // helpers.Git sorts tree entries by comparing names, but directories have
            // an implicit trailing '/' for comparison purposes
            const a_is_dir = std.mem.eql(u8, a.mode, "040000") or std.mem.eql(u8, a.mode, "40000");
            const b_is_dir = std.mem.eql(u8, b.mode, "040000") or std.mem.eql(u8, b.mode, "40000");
            const a_name = a.name;
            const b_name = b.name;

            // helpers.Compare byte by byte, appending '/' to directory names
            var ai: usize = 0;
            var bi: usize = 0;
            while (true) {
                const ac: u8 = if (ai < a_name.len) a_name[ai] else if (a_is_dir and ai == a_name.len) '/' else 0;
                const bc: u8 = if (bi < b_name.len) b_name[bi] else if (b_is_dir and bi == b_name.len) '/' else 0;
                if (ac == 0 and bc == 0) return false;
                if (ac < bc) return true;
                if (ac > bc) return false;
                ai += 1;
                bi += 1;
            }
        }
    };
    std.mem.sort(objects.TreeEntry, entries.items, SortCtx{}, SortCtx.lessThan);

    // helpers.Create tree object
    const tree_obj = objects.createTreeObject(entries.items, allocator) catch {
        try platform_impl.writeStderr("fatal: error creating tree object\n");
        std.process.exit(128);
        unreachable;
    };
    defer tree_obj.deinit(allocator);

    const hash = tree_obj.store(git_dir, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: error storing tree object\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(hash);

    const output = std.fmt.allocPrint(allocator, "{s}\n", .{hash}) catch unreachable;
    defer allocator.free(output);
    try platform_impl.writeStdout(output);
}
