const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const objects = helpers.objects;
const refs = helpers.refs;
const commit_graph_mod = @import("git/commit_graph.zig");

pub fn cmdShortlog(passed_allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const allocator = if (comptime @import("builtin").target.os.tag != .freestanding and @import("builtin").target.os.tag != .wasi)
        std.heap.c_allocator
    else
        passed_allocator;
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("shortlog: not supported in freestanding mode\n");
        return;
    }

    var numbered = false;
    var summary = false;
    var email = false;
    var committish: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--numbered")) {
            numbered = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--summary")) {
            summary = true;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--email")) {
            email = true;
        } else if (std.mem.eql(u8, arg, "-sn") or std.mem.eql(u8, arg, "-ns")) {
            summary = true;
            numbered = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            break;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (committish == null) committish = arg;
        }
    }

    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    var start_commit: []u8 = undefined;
    if (committish) |commit_ref| {
        start_commit = helpers.resolveCommittish(git_path, commit_ref, platform_impl, allocator) catch {
            try platform_impl.writeStderr("fatal: bad revision\n");
            std.process.exit(128);
        };
    } else {
        const cc = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
        if (cc == null) {
            try platform_impl.writeStderr("fatal: no commits\n");
            std.process.exit(128);
        }
        start_commit = cc.?;
    }
    defer allocator.free(start_commit);

    // Count commits per author
    const AuthorCount = struct { name: []const u8, count: u32 };
    var author_map = std.StringHashMap(u32).init(allocator);
    defer {
        var it = author_map.iterator();
        while (it.next()) |entry| allocator.free(@constCast(entry.key_ptr.*));
        author_map.deinit();
    }

    // Try commit-graph fast path
    if (commit_graph_mod.CommitGraph.open(git_path, allocator)) |cg| {
        
        var visited = std.AutoHashMap(u32, void).init(allocator);
        defer visited.deinit();
        var stack = std.array_list.Managed(u32).init(allocator);
        defer stack.deinit();

        if (cg.findCommit(start_commit)) |pos| {
            try stack.append(pos);
            while (stack.items.len > 0) {
                const last = stack.items.len - 1;
                const cur = stack.items[last];
                stack.items.len = last;
                if (visited.contains(cur)) continue;
                try visited.put(cur, {});

                // Get author from object
                var hash_hex: [40]u8 = undefined;
                cg.getOidHex(cur, &hash_hex);
                if (objects.GitObject.load(&hash_hex, git_path, platform_impl, allocator)) |obj| {
                    defer obj.deinit(allocator);
                    const author = extractAuthor(obj.data, email);
                    if (author.len > 0) {
                        if (author_map.getPtr(author)) |cnt| {
                            cnt.* += 1;
                        } else {
                            try author_map.put(try allocator.dupe(u8, author), 1);
                        }
                    }
                } else |_| {}

                // Add parents
                const cd = cg.getCommitData(cur);
                if (cd.parent1 != commit_graph_mod.CommitGraph.GRAPH_NO_PARENT) {
                    try stack.append(cd.parent1);
                }
                if (cd.parent2 != commit_graph_mod.CommitGraph.GRAPH_NO_PARENT and cd.parent2 & commit_graph_mod.CommitGraph.GRAPH_EXTRA_EDGES == 0) {
                    try stack.append(cd.parent2);
                }
            }
        }
    } else {
        // Fallback: regular object loading
        var visited = std.StringHashMap(void).init(allocator);
        defer {
            var it = visited.iterator();
            while (it.next()) |entry| allocator.free(@constCast(entry.key_ptr.*));
            visited.deinit();
        }
        var stack = std.array_list.Managed([]u8).init(allocator);
        defer {
            for (stack.items) |h| allocator.free(h);
            stack.deinit();
        }
        try stack.append(try allocator.dupe(u8, start_commit));

        while (stack.items.len > 0) {
            const last2 = stack.items.len - 1;
            const cur = stack.items[last2];
            stack.items.len = last2;
            if (visited.contains(cur)) { allocator.free(cur); continue; }
            try visited.put(cur, {});

            const obj = objects.GitObject.load(cur, git_path, platform_impl, allocator) catch continue;
            defer obj.deinit(allocator);
            if (obj.type != .commit) continue;

            const author = extractAuthor(obj.data, email);
            if (author.len > 0) {
                if (author_map.getPtr(author)) |cnt| {
                    cnt.* += 1;
                } else {
                    try author_map.put(try allocator.dupe(u8, author), 1);
                }
            }

            var lines = std.mem.splitScalar(u8, obj.data, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) break;
                if (std.mem.startsWith(u8, line, "parent ") and line.len >= 47) {
                    try stack.append(try allocator.dupe(u8, line[7..47]));
                }
            }
        }
    }

    // Collect and sort results
    var results = std.array_list.Managed(AuthorCount).init(allocator);
    defer results.deinit();
    var map_it = author_map.iterator();
    while (map_it.next()) |entry| {
        try results.append(.{ .name = entry.key_ptr.*, .count = entry.value_ptr.* });
    }

    if (numbered) {
        std.mem.sort(AuthorCount, results.items, {}, struct {
            fn cmp(_: void, a: AuthorCount, b: AuthorCount) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.cmp);
    } else {
        std.mem.sort(AuthorCount, results.items, {}, struct {
            fn cmp(_: void, a: AuthorCount, b: AuthorCount) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.cmp);
    }

    // Output
    var out_buf = std.array_list.Managed(u8).init(allocator);
    defer out_buf.deinit();
    for (results.items) |entry| {
        if (summary) {
            var buf: [12]u8 = undefined;
            const num_str = std.fmt.bufPrint(&buf, "{d}", .{entry.count}) catch continue;
            // Right-justify to 6 chars
            var i: usize = 0;
            while (i + num_str.len < 6) : (i += 1) try out_buf.append(' ');
            try out_buf.appendSlice(num_str);
            try out_buf.append('\t');
            try out_buf.appendSlice(entry.name);
            try out_buf.append('\n');
        } else {
            try out_buf.appendSlice(entry.name);
            var buf: [16]u8 = undefined;
            const cnt_str = std.fmt.bufPrint(&buf, " ({d}):\n", .{entry.count}) catch continue;
            try out_buf.appendSlice(cnt_str);
        }
    }
    if (out_buf.items.len > 0) {
        try platform_impl.writeStdout(out_buf.items);
    }
}

fn extractAuthor(data: []const u8, include_email: bool) []const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "author ")) {
            const author_data = line[7..];
            if (include_email) {
                // Include up to and including >
                if (std.mem.indexOf(u8, author_data, ">")) |gt| {
                    return author_data[0 .. gt + 1];
                }
            } else {
                // Just the name (before <)
                if (std.mem.indexOf(u8, author_data, " <")) |lt| {
                    return author_data[0..lt];
                }
                if (std.mem.indexOf(u8, author_data, ">")) |gt| {
                    return author_data[0 .. gt + 1];
                }
            }
            return author_data;
        }
    }
    return "";
}
