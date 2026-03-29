// Auto-generated from main_common.zig - cmd_show_ref
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
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

pub fn nativeCmdShowRef(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var verify = false;
    var exists_mode = false;
    var exclude_existing = false;
    var quiet = false;
    var heads = false;
    var tags = false;
    var show_head = false;
    var hash_only = false;
    var hash_len: usize = 40;
    var dereference = false;
    var patterns = std.ArrayList([]const u8).init(allocator);
    defer patterns.deinit();

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git show-ref [--head] [-d | --dereference] [-s | --hash[=<n>]] [--verify] [-q | --quiet] [--tags] [--heads] [--] [<pattern>...]\n");
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--exists")) {
            exists_mode = true;
        } else if (std.mem.eql(u8, arg, "--verify")) {
            verify = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--heads")) {
            heads = true;
        } else if (std.mem.eql(u8, arg, "--tags")) {
            tags = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--dereference")) {
            dereference = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--hash")) {
            hash_only = true;
        } else if (std.mem.startsWith(u8, arg, "--hash=")) {
            hash_only = true;
            hash_len = std.fmt.parseInt(usize, arg["--hash=".len..], 10) catch 40;
        } else if (std.mem.eql(u8, arg, "--exclude-existing") or std.mem.startsWith(u8, arg, "--exclude-existing=")) {
            exclude_existing = true;
        } else if (std.mem.eql(u8, arg, "--head")) {
            show_head = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try patterns.append(args[i]);
            }
            break;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try patterns.append(arg);
        }
    }

    // Check mutual exclusivity of sub-modes
    const sub_mode_count = @as(u8, if (verify) 1 else 0) + @as(u8, if (exists_mode) 1 else 0) + @as(u8, if (exclude_existing) 1 else 0);
    if (sub_mode_count > 1) {
        try platform_impl.writeStderr("fatal: only one of '--exclude-existing', '--verify' or '--exists' can be given\n");
        std.process.exit(129);
        unreachable;
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    if (exists_mode) {
        // --exists mode: check if a single ref exists, exit 0 if yes, 2 if no
        if (patterns.items.len < 1) {
            try platform_impl.writeStderr("error: --exists requires a ref argument\n");
            std.process.exit(129);
            unreachable;
        }
        const ref_name = patterns.items[0];
        // helpers.Check if the ref file or packed-ref entry exists (even dangling symrefs count)
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name });
        defer allocator.free(ref_path);
        if (std.fs.cwd().access(ref_path, .{})) |_| {
            // helpers.Check if it's a directory (directories are not refs)
            const stat = std.fs.cwd().statFile(ref_path) catch return; // can't stat, assume it exists
            if (stat.kind == .directory) {
                try platform_impl.writeStderr("error: failed to look up reference: Is a directory\n");
                std.process.exit(1);
                unreachable;
            }
            return; // exists (even if symref is dangling)
        } else |_| {
            // helpers.Check packed-helpers.refs
            const packed_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
            defer allocator.free(packed_path);
            const packed_data = platform_impl.fs.readFile(allocator, packed_path) catch {
                try platform_impl.writeStderr("error: reference does not exist\n");
                std.process.exit(2);
                unreachable;
            };
            defer allocator.free(packed_data);
            var lines = std.mem.splitScalar(u8, packed_data, '\n');
            while (lines.next()) |line| {
                if (line.len == 0 or line[0] == '#') continue;
                if (line.len >= 41 and line[40] == ' ') {
                    const packed_ref = std.mem.trim(u8, line[41..], " \t\r");
                    if (std.mem.eql(u8, packed_ref, ref_name)) return; // exists in packed-helpers.refs
                }
            }
            try platform_impl.writeStderr("error: reference does not exist\n");
            std.process.exit(2);
            unreachable;
        }
    }
    
    if (verify) {
        // Verify mode: check specific refs exist and point to valid objects
        var found_any = false;
        for (patterns.items) |pattern| {
            const resolved = helpers.readRefDirect(git_dir, pattern, allocator, platform_impl) catch null;
            if (resolved) |hash| {
                defer allocator.free(hash);
                // Verify the object actually exists
                const obj_exists = blk: {
                    const obj = objects.GitObject.load(hash, git_dir, platform_impl, allocator) catch break :blk false;
                    obj.deinit(allocator);
                    break :blk true;
                };
                if (!obj_exists) {
                    if (!quiet) {
                        const msg = std.fmt.allocPrint(allocator, "fatal: '{s}' - not a valid ref\n", .{pattern}) catch continue;
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                    }
                    continue;
                }
                found_any = true;
                if (!quiet) {
                    const end = @min(hash_len, hash.len);
                    if (hash_only) {
                        const output = std.fmt.allocPrint(allocator, "{s}\n", .{hash[0..end]}) catch continue;
                        defer allocator.free(output);
                        try platform_impl.writeStdout(output);
                    } else {
                        const output = std.fmt.allocPrint(allocator, "{s} {s}\n", .{ hash[0..end], pattern }) catch continue;
                        defer allocator.free(output);
                        try platform_impl.writeStdout(output);
                    }
                    // Dereference tag objects when -d is set
                    if (dereference) {
                        const obj = objects.GitObject.load(hash, git_dir, platform_impl, allocator) catch continue;
                        defer obj.deinit(allocator);
                        if (obj.type == .tag) {
                            if (std.mem.indexOf(u8, obj.data, "object ")) |obj_start| {
                                const hash_start = obj_start + 7;
                                if (hash_start + 40 <= obj.data.len) {
                                    const target_hash = obj.data[hash_start..hash_start + 40];
                                    const deref_output = std.fmt.allocPrint(allocator, "{s} {s}^{{}}\n", .{ target_hash, pattern }) catch continue;
                                    defer allocator.free(deref_output);
                                    try platform_impl.writeStdout(deref_output);
                                }
                            }
                        }
                    }
                }
            } else {
                if (!quiet) {
                    const msg = std.fmt.allocPrint(allocator, "fatal: '{s}' - not a valid ref\n", .{pattern}) catch continue;
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                }
            }
        }
        if (!found_any) {
            std.process.exit(1);
        }
        return;
    }

    // List mode: enumerate all helpers.refs
    var ref_list = std.ArrayList(helpers.RefEntry).init(allocator);
    defer {
        for (ref_list.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.hash);
        }
        ref_list.deinit();
    }

    // helpers.Read packed-helpers.refs
    const packed_refs_path = std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir}) catch unreachable;
    defer allocator.free(packed_refs_path);
    if (std.fs.cwd().readFileAlloc(allocator, packed_refs_path, 10 * 1024 * 1024)) |packed_content| {
        defer allocator.free(packed_content);
        var lines = std.mem.splitScalar(u8, packed_content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '^') continue; // peeled line, handled separately
            // format: <hash> <refname>
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

    // helpers.Read loose helpers.refs
    try helpers.collectLooseRefs(allocator, git_dir, "refs", &ref_list, platform_impl);

    // helpers.Sort by name
    std.mem.sort(helpers.RefEntry, ref_list.items, {}, struct {
        fn lessThan(_: void, a: helpers.RefEntry, b: helpers.RefEntry) bool {
            return std.mem.order(u8, a.name, b.name).compare(.lt);
        }
    }.lessThan);

    // Output HEAD if --head is set
    var found = false;
    if (show_head) {
        const head_hash = helpers.readRefDirect(git_dir, "HEAD", allocator, platform_impl) catch null;
        if (head_hash) |hh| {
            defer allocator.free(hh);
            {
                found = true;
                if (!quiet) {
                    const end = @min(hash_len, hh.len);
                    if (hash_only) {
                        const output = std.fmt.allocPrint(allocator, "{s}\n", .{hh[0..end]}) catch unreachable;
                        defer allocator.free(output);
                        try platform_impl.writeStdout(output);
                    } else {
                        const output = std.fmt.allocPrint(allocator, "{s} HEAD\n", .{hh[0..end]}) catch unreachable;
                        defer allocator.free(output);
                        try platform_impl.writeStdout(output);
                    }
                }
            }
        }
    }

    // Filter and output
    for (ref_list.items) |entry| {
        // helpers.Skip broken helpers.refs
        if (entry.broken) continue;

        // Apply filters: --heads and --tags use OR logic
        if (heads or tags) {
            const is_head = std.mem.startsWith(u8, entry.name, "refs/heads/");
            const is_tag = std.mem.startsWith(u8, entry.name, "refs/tags/");
            if (heads and tags) {
                if (!is_head and !is_tag) continue;
            } else if (heads) {
                if (!is_head) continue;
            } else if (tags) {
                if (!is_tag) continue;
            }
        }

        // helpers.Apply patterns (match as suffix after /)
        if (patterns.items.len > 0) {
            var matches = false;
            for (patterns.items) |pattern| {
                // helpers.Exact match
                if (std.mem.eql(u8, entry.name, pattern)) {
                    matches = true;
                    break;
                }
                // Pattern matches as a suffix after /
                if (std.mem.endsWith(u8, entry.name, pattern)) {
                    // helpers.Check there's a / before the match
                    if (entry.name.len > pattern.len and entry.name[entry.name.len - pattern.len - 1] == '/') {
                        matches = true;
                        break;
                    }
                }
                // Pattern with / matches as prefix
                if (std.mem.indexOf(u8, pattern, "/") != null) {
                    if (std.mem.endsWith(u8, entry.name, pattern)) {
                        matches = true;
                        break;
                    }
                }
            }
            if (!matches) continue;
        }

        found = true;
        if (quiet) continue;

        const end = @min(hash_len, entry.hash.len);
        if (hash_only) {
            const output = std.fmt.allocPrint(allocator, "{s}\n", .{entry.hash[0..end]}) catch continue;
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else {
            const output = std.fmt.allocPrint(allocator, "{s} {s}\n", .{ entry.hash[0..end], entry.name }) catch continue;
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        }

        // Dereference tag helpers.objects (for any ref, not just refs/tags/)
        if (dereference) {
            // helpers.Try to load the object and check if it's a tag
            if (objects.GitObject.load(entry.hash, git_dir, platform_impl, allocator)) |obj| {
                defer obj.deinit(allocator);
                if (obj.type == .tag) {
                    // helpers.Parse tag to find object it points to
                    if (std.mem.indexOf(u8, obj.data, "object ")) |obj_start| {
                        const hash_start = obj_start + 7;
                        if (hash_start + 40 <= obj.data.len) {
                            const target_hash = obj.data[hash_start..hash_start + 40];
                            const deref_output = std.fmt.allocPrint(allocator, "{s} {s}^{{}}\n", .{ target_hash, entry.name }) catch continue;
                            defer allocator.free(deref_output);
                            try platform_impl.writeStdout(deref_output);
                        }
                    }
                }
            } else |_| {}
        }
    }

    if (!found) {
        std.process.exit(1);
    }
}

