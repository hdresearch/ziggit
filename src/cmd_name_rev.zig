// Auto-generated from main_common.zig - cmd_name_rev
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_tag = @import("cmd_tag.zig");
const cmd_show_ref = @import("cmd_show_ref.zig");

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

pub fn nativeCmdNameRev(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var name_only = false;
    var stdin_mode = false;
    var annotate_stdin = false;
    var refs_pattern: ?[]const u8 = null;
    var exclude_patterns = std.ArrayList([]const u8).init(allocator);
    defer exclude_patterns.deinit();
    var targets = std.ArrayList([]const u8).init(allocator);
    defer targets.deinit();

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--name-only")) {
            name_only = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            stdin_mode = true;
        } else if (std.mem.eql(u8, arg, "--annotate-stdin")) {
            stdin_mode = true;
            annotate_stdin = true;
        } else if (std.mem.startsWith(u8, arg, "--refs=")) {
            refs_pattern = arg["--refs=".len..];
        } else if (std.mem.eql(u8, arg, "--tags")) {
            refs_pattern = "refs/tags/*";
        } else if (std.mem.startsWith(u8, arg, "--exclude=")) {
            try exclude_patterns.append(arg["--exclude=".len..]);
        } else if (std.mem.eql(u8, arg, "--exclude")) {
            if (i + 1 < args.len) { i += 1; try exclude_patterns.append(args[i]); }
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git name-rev [<options>] <commit>...\n");
            std.process.exit(129);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try targets.append(arg);
        }
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // helpers.Collect all helpers.refs for naming
    var ref_list = std.ArrayList(helpers.RefEntry).init(allocator);
    defer {
        for (ref_list.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.hash);
        }
        ref_list.deinit();
    }

    const packed_refs_path = std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir}) catch unreachable;
    defer allocator.free(packed_refs_path);
    if (std.fs.cwd().readFileAlloc(allocator, packed_refs_path, 10 * 1024 * 1024)) |packed_content| {
        defer allocator.free(packed_content);
        var lines = std.mem.splitScalar(u8, packed_content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            if (std.mem.indexOfScalar(u8, line, ' ')) |space_idx| {
                const hash = line[0..space_idx];
                const name = line[space_idx + 1..];
                if (hash.len >= 40) {
                    try ref_list.append(.{
                        .name = try allocator.dupe(u8, name),
                        .hash = try allocator.dupe(u8, hash[0..40]),
                    });
                }
            }
        }
    } else |_| {}
    try helpers.collectLooseRefs(allocator, git_dir, "refs", &ref_list, platform_impl);

    // helpers.Handle annotate-stdin mode
    if (stdin_mode and annotate_stdin) {
        // helpers.Build hash -> name map by walking commit history from each ref
        var hash_to_name = std.StringHashMap([]const u8).init(allocator);
        defer hash_to_name.deinit();
        
        for (ref_list.items) |entry| {
            // Filter by refs_pattern
            if (refs_pattern) |pat| {
                if (std.mem.endsWith(u8, pat, "/*")) {
                    if (!std.mem.startsWith(u8, entry.name, pat[0..pat.len - 1])) continue;
                } else if (!std.mem.eql(u8, entry.name, pat)) continue;
            }
            // helpers.Check exclude patterns
            var excluded = false;
            for (exclude_patterns.items) |excl| {
                var short = entry.name;
                if (std.mem.startsWith(u8, entry.name, "refs/tags/")) short = entry.name["refs/tags/".len..];
                if (std.mem.eql(u8, short, excl)) { excluded = true; break; }
            }
            if (excluded) continue;
            
            // helpers.Resolve to commit hash (dereference tags)
            var commit_hash = entry.hash;
            var tag_target_owned: ?[]u8 = null;
            const obj = objects.GitObject.load(entry.hash, git_dir, platform_impl, allocator) catch continue;
            defer obj.deinit(allocator);
            if (obj.type == .tag) {
                tag_target_owned = helpers.parseTagObject(obj.data, allocator) catch continue;
                commit_hash = tag_target_owned.?;
            }
            defer if (tag_target_owned) |t| allocator.free(t);
            
            var short_name = entry.name;
            if (std.mem.startsWith(u8, entry.name, "refs/tags/")) short_name = entry.name["refs/tags/".len..];
            
            // helpers.Walk commit chain assigning names
            var walk_hash = allocator.dupe(u8, commit_hash) catch continue;
            var dist: usize = 0;
            while (dist < 1000) : (dist += 1) {
                {
                    const name_str = if (dist == 0) 
                        (allocator.dupe(u8, short_name) catch break)
                    else 
                        (std.fmt.allocPrint(allocator, "{s}~{d}", .{ short_name, dist }) catch break);
                    // helpers.Only set if no name exists or new name is shorter (better)
                    if (hash_to_name.get(walk_hash)) |existing| {
                        if (name_str.len < existing.len) {
                            hash_to_name.put(allocator.dupe(u8, walk_hash) catch break, name_str) catch break;
                        } else {
                            allocator.free(name_str);
                        }
                    } else {
                        hash_to_name.put(allocator.dupe(u8, walk_hash) catch break, name_str) catch break;
                    }
                }
                const c_obj = objects.GitObject.load(walk_hash, git_dir, platform_impl, allocator) catch break;
                defer c_obj.deinit(allocator);
                var parent_hash: ?[]const u8 = null;
                var li = std.mem.splitScalar(u8, c_obj.data, '\n');
                while (li.next()) |line| {
                    if (std.mem.startsWith(u8, line, "parent ")) { parent_hash = line["parent ".len..]; break; }
                    if (line.len == 0) break;
                }
                if (parent_hash) |ph| {
                    allocator.free(walk_hash);
                    walk_hash = allocator.dupe(u8, ph) catch break;
                } else break;
            }
            allocator.free(walk_hash);
        }
        
        // helpers.Read stdin and annotate
        const stdin_content = helpers.readStdin(allocator, 10 * 1024 * 1024) catch "";
        defer if (stdin_content.len > 0) allocator.free(stdin_content);
        
        var lines = std.mem.splitScalar(u8, stdin_content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var output = std.ArrayList(u8).init(allocator);
            defer output.deinit();
            var j: usize = 0;
            while (j < line.len) {
                if (j + 40 <= line.len and helpers.isValidHexString(line[j..j + 40])) {
                    const hex = line[j..j + 40];
                    if (hash_to_name.get(hex)) |name| {
                        if (name_only) {
                            try output.appendSlice(name);
                        } else {
                            try output.appendSlice(hex);
                            try output.append(' ');
                            try output.append('(');
                            try output.appendSlice(name);
                            try output.append(')');
                        }
                    } else {
                        try output.appendSlice(hex);
                    }
                    j += 40;
                } else {
                    try output.append(line[j]);
                    j += 1;
                }
            }
            try output.append('\n');
            try platform_impl.writeStdout(output.items);
        }
        return;
    }

    for (targets.items) |target| {
        // helpers.Resolve the target to a full hash
        const resolved = refs.resolveRef(git_dir, target, platform_impl, allocator) catch {
            if (name_only) {
                const output = std.fmt.allocPrint(allocator, "undefined\n", .{}) catch continue;
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            } else {
                const output = std.fmt.allocPrint(allocator, "{s} undefined\n", .{target}) catch continue;
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
            continue;
        };
        const hash = resolved orelse {
            if (name_only) {
                try platform_impl.writeStdout("undefined\n");
            } else {
                const output = std.fmt.allocPrint(allocator, "{s} undefined\n", .{target}) catch continue;
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
            continue;
        };
        defer allocator.free(hash);

        // helpers.Find best matching ref
        var best_name: ?[]const u8 = null;
        for (ref_list.items) |entry| {
            if (std.mem.eql(u8, entry.hash, hash)) {
                // helpers.Use shortest/best ref name
                if (best_name == null) {
                    best_name = entry.name;
                }
            }
        }

        if (best_name) |name| {
            // helpers.Format ref name (strip refs/heads/, refs/tags/, etc.)
            var short_name = name;
            if (std.mem.startsWith(u8, name, "refs/tags/")) {
                short_name = std.fmt.allocPrint(allocator, "tags/{s}", .{name["refs/tags/".len..]}) catch name;
            } else if (std.mem.startsWith(u8, name, "refs/heads/")) {
                short_name = name["refs/heads/".len..];
            } else if (std.mem.startsWith(u8, name, "refs/remotes/")) {
                short_name = std.fmt.allocPrint(allocator, "remotes/{s}", .{name["refs/remotes/".len..]}) catch name;
            }

            if (name_only) {
                const output = std.fmt.allocPrint(allocator, "{s}\n", .{short_name}) catch continue;
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            } else {
                const output = std.fmt.allocPrint(allocator, "{s} {s}\n", .{ target, short_name }) catch continue;
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        } else {
            if (name_only) {
                try platform_impl.writeStdout("undefined\n");
            } else {
                const output = std.fmt.allocPrint(allocator, "{s} undefined\n", .{target}) catch continue;
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        }
    }
}
