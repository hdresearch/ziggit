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

    const AuthorCount = struct { name: []const u8, count: u32 };
    var author_map = std.StringHashMap(u32).init(allocator);
    defer {
        var it = author_map.iterator();
        while (it.next()) |entry| allocator.free(@constCast(entry.key_ptr.*));
        author_map.deinit();
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

        // Initialize zlib once for streaming decompression
        objects.initCZlib();
        const inflate_init2_fn = objects.getInflateInit2Fn() orelse return;
        const inflate_fn = objects.getInflateFn() orelse return;
        const inflate_end_fn = objects.getInflateEndFn() orelse return;
        const inflate_reset_fn = objects.getInflateResetFn() orelse return;

        var zstream: objects.ZStream = std.mem.zeroes(objects.ZStream);
        if (inflate_init2_fn(&zstream, 15, "1.2.13", @sizeOf(objects.ZStream)) != 0) return;
        defer _ = inflate_end_fn(&zstream);

        // Walk commit-graph and process each commit inline
        const num_commits = cg.num_commits;
        const bitset_words = (num_commits + 63) / 64;
        const visited_bits = allocator.alloc(u64, bitset_words) catch null;
        defer if (visited_bits) |b| allocator.free(b);

        if (visited_bits) |bits| {
            @memset(bits, 0);

            // Pre-allocate map
            author_map.ensureTotalCapacity(@intCast(@min(num_commits, 1024))) catch {};

            var stack = std.array_list.Managed(u32).init(allocator);
            try stack.ensureTotalCapacity(8192);
            defer stack.deinit();

            var decomp_buf: [1024]u8 = undefined;

            if (cg.findCommit(start_commit)) |pos| {
                try stack.append(pos);
                while (stack.items.len > 0) {
                    const cur = stack.items[stack.items.len - 1];
                    stack.items.len -= 1;

                    const word_idx = cur / 64;
                    const bit_mask = @as(u64, 1) << @truncate(cur % 64);
                    if (bits[word_idx] & bit_mask != 0) continue;
                    bits[word_idx] |= bit_mask;

                    // Get OID and find in pack
                    const oid_bytes = cg.getOidBytes(cur);

                    var found_author = false;
                    for (0..num_packs) |pi| {
                        if (objects.findOffsetInIdx(idx_data_arr[pi], oid_bytes.*)) |offset| {
                            // Fast path: streaming inflate for non-delta commits
                            if (inflateCommitAuthor(
                                pack_data_arr[pi],
                                offset,
                                &decomp_buf,
                                &zstream,
                                inflate_fn,
                                inflate_reset_fn,
                                email,
                            )) |author| {
                                if (author.len > 0) {
                                    if (author_map.getPtr(author)) |cnt| {
                                        cnt.* += 1;
                                    } else {
                                        author_map.put(allocator.dupe(u8, author) catch break, 1) catch {};
                                    }
                                    found_author = true;
                                }
                            } else {
                                // Delta: use readPackCommitHeaderDirect (handles delta chains)
                                if (objects.readPackCommitHeaderDirect(pack_data_arr[pi], idx_data_arr[pi], offset)) |data| {
                                    const author = extractAuthor(data, email);
                                    if (author.len > 0) {
                                        if (author_map.getPtr(author)) |cnt| {
                                            cnt.* += 1;
                                        } else {
                                            author_map.put(allocator.dupe(u8, author) catch break, 1) catch {};
                                        }
                                        found_author = true;
                                    }
                                }
                            }
                            break;
                        }
                    }

                    // Fallback: full object load (loose objects)
                    if (!found_author) {
                        var hash_hex: [40]u8 = undefined;
                        cg.getOidHex(cur, &hash_hex);
                        if (objects.GitObject.load(&hash_hex, git_path, platform_impl, allocator)) |obj| {
                            defer obj.deinit(allocator);
                            const author = extractAuthor(obj.data, email);
                            if (author.len > 0) {
                                if (author_map.getPtr(author)) |cnt| {
                                    cnt.* += 1;
                                } else {
                                    author_map.put(allocator.dupe(u8, author) catch continue, 1) catch {};
                                }
                            }
                        } else |_| {}
                    }

                    // Push parents
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
    try results.ensureTotalCapacity(author_map.count());
    defer results.deinit();
    var map_it = author_map.iterator();
    while (map_it.next()) |entry| {
        results.appendAssumeCapacity(.{ .name = entry.key_ptr.*, .count = entry.value_ptr.* });
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

    // Output with pre-allocated buffer
    var out_buf = std.array_list.Managed(u8).init(allocator);
    try out_buf.ensureTotalCapacity(results.items.len * 40);
    defer out_buf.deinit();
    for (results.items) |entry| {
        if (summary) {
            var buf: [12]u8 = undefined;
            const num_str = std.fmt.bufPrint(&buf, "{d}", .{entry.count}) catch continue;
            var i: usize = 0;
            while (i + num_str.len < 6) : (i += 1) out_buf.appendAssumeCapacity(' ');
            out_buf.appendSliceAssumeCapacity(num_str);
            out_buf.appendAssumeCapacity('\t');
            out_buf.appendSliceAssumeCapacity(entry.name);
            out_buf.appendAssumeCapacity('\n');
        } else {
            out_buf.appendSliceAssumeCapacity(entry.name);
            var buf: [16]u8 = undefined;
            const cnt_str = std.fmt.bufPrint(&buf, " ({d}):\n", .{entry.count}) catch continue;
            out_buf.appendSliceAssumeCapacity(cnt_str);
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
