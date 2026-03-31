const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const objects = helpers.objects;
const refs = helpers.refs;
const commit_graph_mod = @import("git/commit_graph.zig");
const builtin = @import("builtin");

pub fn cmdShortlog(passed_allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const allocator = if (comptime builtin.target.os.tag != .freestanding and builtin.target.os.tag != .wasi)
        std.heap.c_allocator
    else
        passed_allocator;
    if (builtin.target.os.tag == .freestanding) {
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

    const debug_timing = false;
    var t0: i128 = 0;
    if (debug_timing) t0 = std.time.nanoTimestamp();

    var author_map = std.StringHashMap(AuthorEntry).init(allocator);
    defer {
        var it = author_map.iterator();
        while (it.next()) |entry| {
            allocator.free(@constCast(entry.key_ptr.*));
            for (entry.value_ptr.subjects.items) |s| allocator.free(@constCast(s));
            entry.value_ptr.subjects.deinit(allocator);
        }
        author_map.deinit();
    }

    if (debug_timing) {
        const dt = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1e6;
        std.debug.print("setup: {d:.1}ms\n", .{dt});
    }

    // Try commit-graph fast path
    if (commit_graph_mod.CommitGraph.open(git_path, allocator)) |cg| {
        // Setup direct pack access
        const pack_dir_path = std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_path}) catch null;
        defer if (pack_dir_path) |p| allocator.free(p);

        var pack_data_arr: [8][]const u8 = .{""} ** 8;
        var idx_data_arr: [8][]const u8 = .{""} ** 8;
        var num_packs: usize = 0;

        if (pack_dir_path) |pdp| {
            var pack_dir = std.fs.cwd().openDir(pdp, .{ .iterate = true }) catch null;
            if (pack_dir) |*pd| {
                defer pd.close();
                var pit = pd.iterate();
                while (pit.next() catch null) |pentry| {
                    if (num_packs >= 8) break;
                    if (pentry.kind != .file or !std.mem.endsWith(u8, pentry.name, ".idx")) continue;
                    const idx_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pdp, pentry.name }) catch continue;
                    defer allocator.free(idx_path);
                    const pp = std.fmt.allocPrint(allocator, "{s}/{s}.pack", .{ pdp, pentry.name[0 .. pentry.name.len - 4] }) catch continue;
                    defer allocator.free(pp);
                    const idx_d = objects.getCachedIdx(idx_path) orelse blk: {
                        if (objects.mmapFile(idx_path)) |mapped| {
                            objects.addToCacheEx(allocator, idx_path, mapped, true, "", "", false);
                            break :blk @as([]const u8, mapped);
                        }
                        break :blk null;
                    };
                    const pack_d = objects.getCachedPack(pp) orelse blk: {
                        if (objects.mmapFile(pp)) |mapped| {
                            objects.addToCacheEx(allocator, "", "", false, pp, mapped, true);
                            break :blk @as([]const u8, mapped);
                        }
                        break :blk null;
                    };
                    if (idx_d != null and pack_d != null) {
                        idx_data_arr[num_packs] = idx_d.?;
                        pack_data_arr[num_packs] = pack_d.?;
                        num_packs += 1;
                    }
                }
            }
        }

        if (debug_timing) {
            const dt = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1e6;
            std.debug.print("pack setup: {d:.1}ms\n", .{dt});
        }

        // Walk commit-graph: collect all reachable commit positions
        const num_commits = cg.num_commits;
        const bitset_words = (num_commits + 63) / 64;
        const visited_bits = allocator.alloc(u64, bitset_words) catch null;
        defer if (visited_bits) |b| allocator.free(b);

        if (visited_bits) |bits| {
            @memset(bits, 0);

            author_map.ensureTotalCapacity(@intCast(@min(num_commits, 1024))) catch {};

            // Phase 1: Walk commit-graph to collect all reachable commit positions
            var commit_positions = std.array_list.Managed(u32).init(allocator);
            defer commit_positions.deinit();
            try commit_positions.ensureTotalCapacity(8192);

            {
                var stack = std.array_list.Managed(u32).init(allocator);
                try stack.ensureTotalCapacity(4096);
                defer stack.deinit();

                if (cg.findCommit(start_commit)) |pos| {
                    try stack.append(pos);
                    while (stack.items.len > 0) {
                        const cur = stack.items[stack.items.len - 1];
                        stack.items.len -= 1;

                        const word_idx = cur / 64;
                        const bit_mask = @as(u64, 1) << @truncate(cur % 64);
                        if (bits[word_idx] & bit_mask != 0) continue;
                        bits[word_idx] |= bit_mask;

                        commit_positions.appendAssumeCapacity(cur);

                        const cd = cg.getCommitData(cur);
                        if (cd.parent1 != commit_graph_mod.CommitGraph.GRAPH_NO_PARENT) {
                            stack.append(cd.parent1) catch {};
                        }
                        if (cd.parent2 != commit_graph_mod.CommitGraph.GRAPH_NO_PARENT and cd.parent2 & commit_graph_mod.CommitGraph.GRAPH_EXTRA_EDGES == 0) {
                            stack.append(cd.parent2) catch {};
                        }
                    }
                }
            }

            if (debug_timing) {
                const dt = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1e6;
                std.debug.print("graph walk ({d} commits): {d:.1}ms\n", .{commit_positions.items.len, dt});
            }

            // Phase 2: For each commit, look up pack offset, then sort by offset for cache-friendly access
            const PosAndOffset = struct { cg_pos: u32, pack_idx: u16, pack_offset: u48 };
            var sorted_commits = std.array_list.Managed(PosAndOffset).init(allocator);
            defer sorted_commits.deinit();
            try sorted_commits.ensureTotalCapacity(commit_positions.items.len);

            for (commit_positions.items) |cg_pos| {
                const oid_bytes = cg.getOidBytes(cg_pos);
                for (0..num_packs) |pi| {
                    if (objects.findOffsetInIdx(idx_data_arr[pi], oid_bytes.*)) |offset| {
                        sorted_commits.appendAssumeCapacity(.{
                            .cg_pos = cg_pos,
                            .pack_idx = @intCast(pi),
                            .pack_offset = @intCast(offset),
                        });
                        break;
                    }
                }
            }

            // Sort by pack offset for sequential access
            std.mem.sort(PosAndOffset, sorted_commits.items, {}, struct {
                fn cmp(_: void, a: PosAndOffset, b: PosAndOffset) bool {
                    if (a.pack_idx != b.pack_idx) return a.pack_idx < b.pack_idx;
                    return a.pack_offset < b.pack_offset;
                }
            }.cmp);

            if (debug_timing) {
                const dt = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1e6;
                std.debug.print("idx lookup + sort: {d:.1}ms\n", .{dt});
            }

            // Phase 3: Process each commit in pack-offset order
            for (sorted_commits.items) |entry| {
                const pack_data = pack_data_arr[entry.pack_idx];
                const idx_data = idx_data_arr[entry.pack_idx];

                var commit_data: ?[]const u8 = null;
                var obj_holder: ?objects.GitObject = null;

                if (objects.readPackCommitHeaderPartial(pack_data, idx_data, entry.pack_offset)) |data| {
                    commit_data = data;
                }
                if (commit_data == null) {
                    var hash_hex: [40]u8 = undefined;
                    cg.getOidHex(entry.cg_pos, &hash_hex);
                    if (objects.GitObject.load(&hash_hex, git_path, platform_impl, allocator)) |obj| {
                        obj_holder = obj;
                        commit_data = obj.data;
                    } else |_| {}
                }
                defer if (obj_holder) |obj| obj.deinit(allocator);

                if (commit_data) |data| {
                    addToAuthorMap(allocator, &author_map, data, email);
                }
            }
        }
    if (debug_timing) {
        const dt = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1e6;
        std.debug.print("pack reading done: {d:.1}ms\n", .{dt});
    }
    } else {
        // Fallback: regular object loading (no commit-graph)
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
            const last_idx = stack.items.len - 1;
            const cur = stack.items[last_idx];
            stack.items.len = last_idx;
            if (visited.contains(cur)) { allocator.free(cur); continue; }
            try visited.put(cur, {});

            const obj = objects.GitObject.load(cur, git_path, platform_impl, allocator) catch continue;
            defer obj.deinit(allocator);
            if (obj.type != .commit) continue;

            addToAuthorMap(allocator, &author_map, obj.data, email);

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
    const AuthorResult = struct { name: []const u8, count: u32, subjects: []const []const u8 };
    var results = std.array_list.Managed(AuthorResult).init(allocator);
    try results.ensureTotalCapacity(author_map.count());
    defer results.deinit();
    var map_it = author_map.iterator();
    while (map_it.next()) |entry| {
        results.appendAssumeCapacity(.{ .name = entry.key_ptr.*, .count = entry.value_ptr.count, .subjects = entry.value_ptr.subjects.items });
    }

    if (numbered) {
        std.mem.sort(AuthorResult, results.items, {}, struct {
            fn cmp(_: void, a: AuthorResult, b: AuthorResult) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.cmp);
    } else {
        std.mem.sort(AuthorResult, results.items, {}, struct {
            fn cmp(_: void, a: AuthorResult, b: AuthorResult) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.cmp);
    }

    // Reverse subjects within each author to get chronological order
    for (results.items) |*entry| {
        std.mem.reverse([]const u8, @constCast(entry.subjects));
    }

    // Output with pre-allocated buffer
    var out_buf = std.array_list.Managed(u8).init(allocator);
    try out_buf.ensureTotalCapacity(results.items.len * 80);
    defer out_buf.deinit();
    for (results.items) |entry| {
        if (summary) {
            var buf: [12]u8 = undefined;
            const num_str = std.fmt.bufPrint(&buf, "{d}", .{entry.count}) catch continue;
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
            for (entry.subjects) |subj| {
                try out_buf.appendSlice("      ");
                try out_buf.appendSlice(subj);
                try out_buf.append('\n');
            }
            try out_buf.append('\n');
        }
    }
    if (out_buf.items.len > 0) {
        try platform_impl.writeStdout(out_buf.items);
    }
}

fn extractAuthor(data: []const u8, include_email: bool) []const u8 {
    // Fast scan for "author " at line start
    var pos: usize = 0;
    while (pos + 7 < data.len) {
        if (data[pos] == 'a' and std.mem.eql(u8, data[pos..][0..7], "author ")) {
            const author_start = pos + 7;
            var end = author_start;
            while (end < data.len and data[end] != '\n') : (end += 1) {}
            const author_line = data[author_start..end];
            if (include_email) {
                if (std.mem.indexOf(u8, author_line, ">")) |gt| {
                    return author_line[0 .. gt + 1];
                }
            } else {
                if (std.mem.indexOf(u8, author_line, " <")) |lt| {
                    return author_line[0..lt];
                }
                if (std.mem.indexOf(u8, author_line, ">")) |gt| {
                    return author_line[0 .. gt + 1];
                }
            }
            return author_line;
        }
        // Skip to next line
        while (pos < data.len and data[pos] != '\n') : (pos += 1) {}
        pos += 1;
        // Empty line = end of headers
        if (pos < data.len and data[pos] == '\n') break;
    }
    return "";
}

fn extractSubject(data: []const u8) []const u8 {
    if (std.mem.indexOf(u8, data, "\n\n")) |sep| {
        const msg = data[sep + 2 ..];
        // Subject is the first line of the message
        if (std.mem.indexOfScalar(u8, msg, '\n')) |nl| {
            return msg[0..nl];
        }
        return msg;
    }
    return "";
}

fn addToAuthorMap(allocator: std.mem.Allocator, author_map: *std.StringHashMap(AuthorEntry), data: []const u8, include_email: bool) void {
    const author = extractAuthor(data, include_email);
    if (author.len == 0) return;
    const subject = extractSubject(data);

    if (author_map.getPtr(author)) |entry| {
        entry.count += 1;
        if (subject.len > 0) {
            entry.subjects.append(allocator, allocator.dupe(u8, subject) catch return) catch {};
        }
    } else {
        var subjects = std.ArrayListUnmanaged([]const u8){};
        if (subject.len > 0) {
            subjects.append(allocator, allocator.dupe(u8, subject) catch return) catch {};
        }
        author_map.put(allocator.dupe(u8, author) catch return, .{ .name = author, .count = 1, .subjects = subjects }) catch {};
    }
}

const AuthorEntry = struct { name: []const u8, count: u32, subjects: std.ArrayListUnmanaged([]const u8) };
