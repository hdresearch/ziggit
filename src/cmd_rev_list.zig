// Auto-generated from main_common.zig - cmd_rev_list
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");

// Re-export commonly used types from helpers
const objects = helpers.objects;
const commit_graph_mod = @import("git/commit_graph.zig");
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

pub fn cmdRevList(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("rev-list: not supported in freestanding mode\n");
        return;
    }

    // helpers.Find .git directory first
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    var do_count = false;
    var max_count: ?i64 = null;
    var skip_count: u32 = 0;
    var reverse = false;
    var topo_order = false;
    var show_objects = false;
    var no_object_names = false;
    var in_commit_order = false;
    var all_refs = false;
    var graph = false;
    var no_walk = false;
    var show_parents = false;
    var show_children = false;
    var format_str: ?[]const u8 = null;
    var no_commit_header = false;
    var include_refs = std.array_list.Managed([]const u8).init(allocator);
    defer include_refs.deinit();
    var exclude_refs = std.array_list.Managed([]const u8).init(allocator);
    defer exclude_refs.deinit();

    // helpers.Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--count")) {
            do_count = true;
        } else if (std.mem.eql(u8, arg, "--reverse")) {
            reverse = true;
        } else if (std.mem.eql(u8, arg, "--topo-order")) {
            topo_order = true;
        } else if (std.mem.eql(u8, arg, "--date-order")) {
            topo_order = false; // date-order overrides topo
        } else if (std.mem.eql(u8, arg, "--author-date-order")) {
            topo_order = false; // author-date-order overrides topo
        } else if (std.mem.eql(u8, arg, "--objects") or std.mem.eql(u8, arg, "--objects-edge")) {
            show_objects = true;
        } else if (std.mem.eql(u8, arg, "--no-object-names")) {
            no_object_names = true;
        } else if (std.mem.eql(u8, arg, "--in-commit-order")) {
            in_commit_order = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            all_refs = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            // helpers.Read helpers.refs from stdin
            const stdin_data = blk: {
                var buf = std.array_list.Managed(u8).init(allocator);
                var tmp: [4096]u8 = undefined;
                while (true) {
                    const n = std.posix.read(0, &tmp) catch break;
                    if (n == 0) break;
                    buf.appendSlice(tmp[0..n]) catch break;
                }
                break :blk buf.toOwnedSlice() catch "";
            };
            defer if (stdin_data.len > 0) allocator.free(stdin_data);
            var stdin_lines = std.mem.splitScalar(u8, stdin_data, '\n');
            while (stdin_lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;
                if (std.mem.indexOf(u8, trimmed, "..") != null) {
                    const dot_pos = std.mem.indexOf(u8, trimmed, "..").?;
                    const from_ref = if (dot_pos == 0) "HEAD" else trimmed[0..dot_pos];
                    const to_ref = if (dot_pos + 2 >= trimmed.len) "HEAD" else trimmed[dot_pos + 2 ..];
                    try exclude_refs.append(from_ref);
                    try include_refs.append(to_ref);
                } else if (trimmed.len > 0 and trimmed[0] == '^') {
                    try exclude_refs.append(trimmed[1..]);
                } else {
                    try include_refs.append(trimmed);
                }
            }
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            // Suppress output (but still set exit code)
        } else if (std.mem.eql(u8, arg, "--no-walk") or std.mem.startsWith(u8, arg, "--no-walk=")) {
            no_walk = true;
            max_count = 1;
        } else if (std.mem.eql(u8, arg, "--parents")) {
            show_parents = true;
        } else if (std.mem.eql(u8, arg, "--children")) {
            show_children = true;
        } else if (std.mem.eql(u8, arg, "--graph")) {
            graph = true;
        } else if (std.mem.startsWith(u8, arg, "--max-count=")) {
            max_count = std.fmt.parseInt(i64, arg[12..], 10) catch {
                const msg = std.fmt.allocPrint(allocator, "fatal: '{s}': not an integer\n", .{arg[12..]}) catch return;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            };
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--max-count")) {
            if (args.next()) |count_str| {
                max_count = std.fmt.parseInt(i64, count_str, 10) catch {
                    const msg = std.fmt.allocPrint(allocator, "fatal: '{s}': not an integer\n", .{count_str}) catch return;
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                    unreachable;
                };
            }
        } else if (std.mem.startsWith(u8, arg, "-n")) {
            // -n<N> form (e.g. -n1)
            max_count = std.fmt.parseInt(i64, arg[2..], 10) catch {
                const msg = std.fmt.allocPrint(allocator, "fatal: '{s}': not an integer\n", .{arg[2..]}) catch return;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            };
        } else if (std.mem.startsWith(u8, arg, "--skip=")) {
            skip_count = std.fmt.parseInt(u32, arg[7..], 10) catch {
                const msg = std.fmt.allocPrint(allocator, "fatal: '{s}': not an integer\n", .{arg[7..]}) catch return;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            };
        } else if (std.mem.eql(u8, arg, "--skip")) {
            if (args.next()) |skip_str| {
                skip_count = std.fmt.parseInt(u32, skip_str, 10) catch {
                    const msg = std.fmt.allocPrint(allocator, "fatal: '{s}': not an integer\n", .{skip_str}) catch return;
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                    unreachable;
                };
            }
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and std.ascii.isDigit(arg[1])) {
            max_count = std.fmt.parseInt(i64, arg[1..], 10) catch {
                const msg = std.fmt.allocPrint(allocator, "fatal: '{s}': not an integer\n", .{arg[1..]}) catch return;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            };
        } else if (std.mem.startsWith(u8, arg, "--not")) {
            // Next positional arg is excluded
        } else if (std.mem.eql(u8, arg, "--")) {
            break; // helpers.End of revisions
        } else if (std.mem.startsWith(u8, arg, "--") and arg.len > 2 and std.ascii.isDigit(arg[2])) {
            // --1 etc are not valid options
            const msg = std.fmt.allocPrint(allocator, "error: unknown option `{s}'\n", .{arg[2..]}) catch return;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
            unreachable;
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            format_str = arg["--format=".len..];
        } else if (std.mem.startsWith(u8, arg, "--pretty=format:")) {
            format_str = arg["--pretty=format:".len..];
        } else if (std.mem.startsWith(u8, arg, "--pretty=tformat:")) {
            format_str = arg["--pretty=tformat:".len..];
        } else if (std.mem.eql(u8, arg, "--pretty=oneline") or std.mem.eql(u8, arg, "--oneline")) {
            if (std.mem.eql(u8, arg, "--oneline")) {
                format_str = "%h %s";
            } else {
                format_str = "%H %s";
            }
            no_commit_header = true;
        } else if (std.mem.eql(u8, arg, "--no-commit-header")) {
            no_commit_header = true;
        } else if (std.mem.startsWith(u8, arg, "--pretty=")) {
            // helpers.Other pretty formats - ignore for now
        } else if (std.mem.eql(u8, arg, "--header")) {
            // helpers.Show raw header - ignore for now
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // helpers.Skip unknown flags
        } else if (std.mem.indexOf(u8, arg, "..") != null) {
            // Range: A..B means ^A B (exclude A ancestors, include B ancestors)
            const dot_pos = std.mem.indexOf(u8, arg, "..").?;
            const from_ref = if (dot_pos == 0) "HEAD" else arg[0..dot_pos];
            const to_ref = if (dot_pos + 2 >= arg.len) "HEAD" else arg[dot_pos + 2 ..];
            try exclude_refs.append(from_ref);
            try include_refs.append(to_ref);
        } else if (arg.len > 0 and arg[0] == '^') {
            try exclude_refs.append(arg[1..]);
        } else {
            try include_refs.append(arg);
        }
    }

    // --graph and --no-walk are mutually exclusive
    if (graph and no_walk) {
        try platform_impl.writeStderr("fatal: --graph and --no-walk are incompatible\n");
        std.process.exit(1);
    }

    // helpers.If --all, add all helpers.refs
    if (all_refs) {
        // helpers.Add helpers.HEAD
        try include_refs.append("HEAD");
        // helpers.Add all branches
        const heads_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{git_path});
        defer allocator.free(heads_path);
        if (std.fs.cwd().openDir(heads_path, .{ .iterate = true })) |*dir_ptr| {
            var dir = dir_ptr.*;
            defer dir.close();
            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (entry.kind == .file) {
                    const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{entry.name});
                    try include_refs.append(ref_name);
                }
            }
        } else |_| {}
        // helpers.Add all tags
        const tags_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_path});
        defer allocator.free(tags_path);
        if (std.fs.cwd().openDir(tags_path, .{ .iterate = true })) |*dir_ptr| {
            var dir = dir_ptr.*;
            defer dir.close();
            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (entry.kind == .file) {
                    const ref_name = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{entry.name});
                    try include_refs.append(ref_name);
                }
            }
        } else |_| {}
    }

    // helpers.Default to helpers.HEAD if no helpers.refs specified
    if (include_refs.items.len == 0) {
        try include_refs.append("HEAD");
    }

    // helpers.Resolve all include/exclude helpers.refs
    var include_hashes = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (include_hashes.items) |h| allocator.free(h);
        include_hashes.deinit();
    }
    var exclude_hashes = std.StringHashMap(void).init(allocator);
    defer {
        var eit = exclude_hashes.iterator();
        while (eit.next()) |entry| allocator.free(@constCast(entry.key_ptr.*));
        exclude_hashes.deinit();
    }

    for (include_refs.items) |ref_str| {
        const hash = helpers.resolveRevision(git_path, ref_str, platform_impl, allocator) catch continue;
        try include_hashes.append(hash);
    }

    // helpers.Resolve excludes and walk their ancestors into the exclude set
    for (exclude_refs.items) |ref_str| {
        const hash = helpers.resolveRevision(git_path, ref_str, platform_impl, allocator) catch continue;
        // helpers.Walk all ancestors of excluded helpers.refs
        try helpers.walkAncestors(git_path, hash, &exclude_hashes, platform_impl, allocator);
        allocator.free(hash);
    }

    if (include_hashes.items.len == 0) {
        try platform_impl.writeStderr("fatal: bad default revision 'HEAD'\n");
        std.process.exit(128);
    }

    // Ultra-fast path: --count with commit-graph (no object decompression needed)
    if (do_count and !topo_order and skip_count == 0 and format_str == null and !show_objects and !show_parents and !show_children and !graph) {
        if (commit_graph_mod.CommitGraph.open(git_path, allocator)) |cg| {
            // Use commit-graph for pure parent traversal - no zlib needed!
            if (exclude_hashes.count() == 0) {
                var cg_visited = std.AutoHashMap(u32, void).init(allocator);
                defer cg_visited.deinit();
                var cg_stack = std.array_list.Managed(u32).init(allocator);
                defer cg_stack.deinit();

                var all_found = true;
                for (include_hashes.items) |h| {
                    if (cg.findCommit(h)) |pos| {
                        try cg_stack.append(pos);
                    } else {
                        all_found = false;
                        break;
                    }
                }

                if (all_found) {
                    var total_count: usize = 0;
                    while (cg_stack.items.len > 0) {
                        const last_idx = cg_stack.items.len - 1;
                        const pos = cg_stack.items[last_idx];
                        cg_stack.items.len = last_idx;
                        if (cg_visited.contains(pos)) continue;
                        try cg_visited.put(pos, {});
                        total_count += 1;
                        const cd = cg.getCommitData(pos);
                        if (cd.parent1 != commit_graph_mod.CommitGraph.GRAPH_NO_PARENT) {
                            try cg_stack.append(cd.parent1);
                        }
                        if (cd.parent2 != commit_graph_mod.CommitGraph.GRAPH_NO_PARENT and cd.parent2 & commit_graph_mod.CommitGraph.GRAPH_EXTRA_EDGES == 0) {
                            try cg_stack.append(cd.parent2);
                        }
                    }
                    if (max_count) |mc| {
                        if (mc >= 0) total_count = @min(total_count, @as(usize, @intCast(mc)));
                    }
                    var buf: [20]u8 = undefined;
                    const count_str = std.fmt.bufPrint(&buf, "{d}\n", .{total_count}) catch unreachable;
                    try platform_impl.writeStdout(count_str);
                    return;
                }
            }
        }
    }

    // Fast path for --count: simple DFS, no sorting needed
    if (do_count and !topo_order and skip_count == 0 and format_str == null and !show_objects and !show_parents and !show_children and !graph) {
        var count_visited = std.StringHashMap(void).init(allocator);
        defer {
            var vit = count_visited.iterator();
            while (vit.next()) |entry| allocator.free(@constCast(entry.key_ptr.*));
            count_visited.deinit();
        }
        var count_stack = std.array_list.Managed([]u8).init(allocator);
        defer {
            for (count_stack.items) |h| allocator.free(h);
            count_stack.deinit();
        }
        for (include_hashes.items) |h| {
            try count_stack.append(try allocator.dupe(u8, h));
        }
        var total_count: usize = 0;
        while (count_stack.items.len > 0) {
            const current = count_stack.pop() orelse break;
            if (count_visited.contains(current)) {
                allocator.free(current);
                continue;
            }
            if (exclude_hashes.contains(current)) {
                allocator.free(current);
                continue;
            }
            try count_visited.put(current, {});
            const obj = objects.GitObject.load(current, git_path, platform_impl, allocator) catch continue;
            defer obj.deinit(allocator);
            if (obj.type != .commit) continue;
            total_count += 1;
            // Parse only parent lines from header
            var lines_iter = std.mem.splitScalar(u8, obj.data, '\n');
            while (lines_iter.next()) |line| {
                if (line.len == 0) break;
                if (std.mem.startsWith(u8, line, "parent ") and line.len >= 47) {
                    try count_stack.append(try allocator.dupe(u8, line[7..47]));
                }
            }
        }
        if (max_count) |mc| {
            if (mc >= 0) {
                const limit = @as(usize, @intCast(mc));
                total_count = @min(total_count, limit);
            }
        }
        var buf: [20]u8 = undefined;
        const count_str = std.fmt.bufPrint(&buf, "{d}\n", .{total_count}) catch unreachable;
        try platform_impl.writeStdout(count_str);
        return;
    }

    // helpers.Collect all reachable commits with timestamps for sorting
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var vit = visited.iterator();
        while (vit.next()) |entry| allocator.free(@constCast(entry.key_ptr.*));
        visited.deinit();
    }

    const CommitInfo = struct {
        hash: []u8,
        commit_ts: i64,
        author_ts: i64,
        parents: [][]const u8,
    };

    var all_commits = std.array_list.Managed(CommitInfo).init(allocator);
    defer {
        for (all_commits.items) |ci| {
            allocator.free(ci.hash);
            for (ci.parents) |p| allocator.free(@constCast(p));
            allocator.free(ci.parents);
        }
        all_commits.deinit();
    }

    // helpers.BFS to collect all commits
    var queue = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (queue.items) |h| allocator.free(h);
        queue.deinit();
    }

    for (include_hashes.items) |h| {
        try queue.append(try allocator.dupe(u8, h));
    }

    while (queue.items.len > 0) {
        const current = queue.pop() orelse break;

        if (visited.contains(current)) {
            allocator.free(current);
            continue;
        }
        if (exclude_hashes.contains(current)) {
            allocator.free(current);
            continue;
        }

        try visited.put(try allocator.dupe(u8, current), {});

        // helpers.Load commit
        const obj = objects.GitObject.load(current, git_path, platform_impl, allocator) catch {
            allocator.free(current);
            continue;
        };
        defer obj.deinit(allocator);
        if (obj.type != .commit) {
            allocator.free(current);
            continue;
        }

        var parents_list = std.array_list.Managed([]const u8).init(allocator);
        var commit_ts: i64 = 0;
        var author_ts: i64 = 0;
        var clines = std.mem.splitSequence(u8, obj.data, "\n");
        while (clines.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                const parent = line[7..];
                if (parent.len == 40) {
                    try parents_list.append(try allocator.dupe(u8, parent));
                    try queue.append(try allocator.dupe(u8, parent));
                }
            } else if (std.mem.startsWith(u8, line, "committer ")) {
                commit_ts = helpers.parseTimestampFromLine(line) catch 0;
            } else if (std.mem.startsWith(u8, line, "author ")) {
                author_ts = helpers.parseTimestampFromLine(line) catch 0;
            } else if (line.len == 0) break;
        }

        try all_commits.append(.{
            .hash = current,
            .commit_ts = commit_ts,
            .author_ts = author_ts,
            .parents = try parents_list.toOwnedSlice(),
        });
    }

    // helpers.Sort based on order mode
    if (topo_order) {
        // Kahn's algorithm for topological sort
        // In-degree = number of children (commits that have this as parent)
        var in_degree = std.StringHashMap(usize).init(allocator);
        defer in_degree.deinit();

        // Initialize in-degree to 0 for all commits
        for (all_commits.items) |ci| {
            try in_degree.put(ci.hash, 0);
        }

        // helpers.Count in-degrees (how many children each commit has)
        for (all_commits.items) |ci| {
            for (ci.parents) |p| {
                if (in_degree.getPtr(p)) |deg| {
                    deg.* += 1;
                }
            }
        }

        // helpers.Build index map for fast lookup
        var hash_to_idx = std.StringHashMap(usize).init(allocator);
        defer hash_to_idx.deinit();
        for (all_commits.items, 0..) |ci, idx| {
            try hash_to_idx.put(ci.hash, idx);
        }

        var result = std.array_list.Managed([]u8).init(allocator);
        defer {
            for (result.items) |h| allocator.free(h);
            result.deinit();
        }

        // helpers.Start with commits that have in-degree 0 (no children)
        // helpers.Use a priority queue sorted by timestamp to break ties
        var ready = std.array_list.Managed(usize).init(allocator);
        defer ready.deinit();

        for (all_commits.items, 0..) |ci, idx| {
            if (in_degree.get(ci.hash).? == 0) {
                try ready.append(idx);
            }
        }

        while (ready.items.len > 0) {
            // Pick the commit with the highest commit timestamp among ready commits
            var best_idx: usize = 0;
            var best_ts: i64 = all_commits.items[ready.items[0]].commit_ts;
            for (ready.items, 0..) |ri, k| {
                const ts = all_commits.items[ri].commit_ts;
                if (ts > best_ts) {
                    best_ts = ts;
                    best_idx = k;
                }
            }

            const ci_idx = ready.orderedRemove(best_idx);
            const ci = all_commits.items[ci_idx];

            try result.append(try allocator.dupe(u8, ci.hash));

            // Decrease in-degree of parents
            for (ci.parents) |p| {
                if (in_degree.getPtr(p)) |deg| {
                    deg.* -= 1;
                    if (deg.* == 0) {
                        if (hash_to_idx.get(p)) |pidx| {
                            try ready.append(pidx);
                        }
                    }
                }
            }
        }

        // helpers.Now apply skip/max_count/reverse on result
        const skipped_results = if (skip_count > 0 and skip_count < result.items.len)
            result.items[skip_count..]
        else if (skip_count >= result.items.len)
            result.items[0..0]
        else
            result.items;

        const final_results_topo = if (max_count) |mc| blk: {
            if (mc < 0) break :blk skipped_results;
            const limit = @as(usize, @intCast(mc));
            break :blk if (limit < skipped_results.len) skipped_results[0..limit] else skipped_results;
        } else skipped_results;

        // helpers.Output using the shared output logic
        try helpers.outputRevListResults(final_results_topo, reverse, do_count, format_str, no_commit_header, show_objects, no_object_names, in_commit_order, git_path, allocator, platform_impl, show_parents, show_children);
        return;
    }

    // Default: sort by commit timestamp (descending) for date-order, or by commit timestamp for default
    std.mem.sort(CommitInfo, all_commits.items, {}, struct {
        fn cmp(_: void, a: CommitInfo, b: CommitInfo) bool {
            return a.commit_ts > b.commit_ts;
        }
    }.cmp);

    var result = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (result.items) |h| allocator.free(h);
        result.deinit();
    }
    for (all_commits.items) |ci| {
        try result.append(try allocator.dupe(u8, ci.hash));
    }

    // helpers.Apply skip
    const skipped_results = if (skip_count > 0 and skip_count < result.items.len)
        result.items[skip_count..]
    else if (skip_count >= result.items.len)
        result.items[0..0]
    else
        result.items;

    // helpers.Apply max_count to output (negative means unlimited)
    const final_results = if (max_count) |mc| blk: {
        if (mc < 0) break :blk skipped_results;
        const limit = @as(usize, @intCast(mc));
        break :blk if (limit < skipped_results.len) skipped_results[0..limit] else skipped_results;
    } else skipped_results;

    try helpers.outputRevListResults(final_results, reverse, do_count, format_str, no_commit_header, show_objects, no_object_names, in_commit_order, git_path, allocator, platform_impl, show_parents, show_children);
}


