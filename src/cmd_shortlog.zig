const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const objects = helpers.objects;
const refs = helpers.refs;
const commit_graph_mod = @import("git/commit_graph.zig");
const builtin = @import("builtin");

const NUM_WORKER_THREADS = 3; // + main thread = 4 total

const PackOffset = struct { pack_idx: u8, offset: u32 };

/// Per-thread work context for parallel author extraction
const WorkerCtx = struct {
    // Input
    offsets: []const PackOffset,
    pack_data_arr: *const [8][]const u8,
    idx_data_arr: *const [8][]const u8,
    num_packs: usize,
    include_email: bool,

    // Output: flat buffer of author strings separated by \x00
    result_buf: []u8,
    result_len: usize,
    author_count: usize,
};

fn workerFn(ctx: *WorkerCtx) void {
    processChunk(ctx);
}

fn processChunk(ctx: *WorkerCtx) void {
    var decomp_buf: [2048]u8 = undefined;
    var result_pos: usize = 0;
    var count: usize = 0;

    // Get zlib streaming inflate functions for partial decompression
    objects.initCZlib();
    const inflate_init2_fn = objects.getInflateInit2Fn() orelse return;
    const inflate_fn = objects.getInflateFn() orelse return;
    const inflate_end_fn = objects.getInflateEndFn() orelse return;
    const inflate_reset_fn = objects.getInflateResetFn() orelse return;

    // Initialize a persistent zlib stream for this thread
    var stream: objects.ZStream = std.mem.zeroes(objects.ZStream);
    if (inflate_init2_fn(&stream, 15, "1.2.13", @sizeOf(objects.ZStream)) != 0) return;
    defer _ = inflate_end_fn(&stream);

    for (ctx.offsets) |po| {
        if (po.offset == 0) continue;
        const pi = po.pack_idx;
        const pack_data = ctx.pack_data_arr[pi];

        const data = decompressCommitStreaming(pack_data, po.offset, &decomp_buf, &stream, inflate_fn, inflate_reset_fn) orelse continue;

        const author = extractAuthor(data, ctx.include_email);
        if (author.len > 0 and result_pos + author.len + 1 <= ctx.result_buf.len) {
            @memcpy(ctx.result_buf[result_pos .. result_pos + author.len], author);
            ctx.result_buf[result_pos + author.len] = 0;
            result_pos += author.len + 1;
            count += 1;
        }
    }

    ctx.result_len = result_pos;
    ctx.author_count = count;
}

/// Thread-safe streaming decompression: parse pack header and inflate into provided buffer.
/// Uses streaming inflate so we only need to decompress the first N bytes (for author line).
fn decompressCommitStreaming(
    pack_data: []const u8,
    offset: usize,
    out_buf: *[2048]u8,
    stream: *objects.ZStream,
    inflate_fn: *const fn (*objects.ZStream, c_int) callconv(.c) c_int,
    inflate_reset_fn: *const fn (*objects.ZStream) callconv(.c) c_int,
) ?[]const u8 {
    const content_end = if (pack_data.len > 20) pack_data.len - 20 else return null;
    var pos = offset;
    if (pos >= content_end) return null;

    const first_byte = pack_data[pos];
    pos += 1;
    const pack_type_num: u3 = @truncate((first_byte >> 4) & 7);

    // Read variable-length size
    var cur = first_byte;
    while (cur & 0x80 != 0 and pos < content_end) {
        cur = pack_data[pos];
        pos += 1;
    }

    if (pos >= content_end) return null;

    // Only handle non-delta commits
    if (pack_type_num != 1) return null;

    // Streaming inflate: decompress only what fits in our buffer
    _ = inflate_reset_fn(stream);
    stream.next_in = pack_data[pos..].ptr;
    stream.avail_in = @intCast(@min(pack_data.len - pos, std.math.maxInt(c_uint)));
    stream.next_out = out_buf;
    stream.avail_out = out_buf.len;

    const Z_NO_FLUSH = 0;
    const Z_STREAM_END = 1;
    const Z_OK = 0;
    const ret = inflate_fn(stream, Z_NO_FLUSH);
    const produced = @as(usize, @intCast(stream.total_out));

    if (ret == Z_OK or ret == Z_STREAM_END) {
        return out_buf[0..produced];
    }
    return null;
}

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

        // Phase 1: Walk commit-graph, collect all reachable positions
        const num_commits = cg.num_commits;
        const bitset_words = (num_commits + 63) / 64;
        const visited_bits = allocator.alloc(u64, bitset_words) catch null;
        defer if (visited_bits) |b| allocator.free(b);

        if (visited_bits) |bits| {
            @memset(bits, 0);

            var positions = std.array_list.Managed(u32).init(allocator);
            defer positions.deinit();
            positions.ensureTotalCapacity(num_commits) catch {};

            var stack = std.array_list.Managed(u32).init(allocator);
            defer stack.deinit();
            stack.ensureTotalCapacity(4096) catch {};

            if (cg.findCommit(start_commit)) |pos| {
                stack.append(pos) catch {};
                while (stack.items.len > 0) {
                    const cur = stack.items[stack.items.len - 1];
                    stack.items.len -= 1;

                    const word_idx = cur / 64;
                    const bit_mask = @as(u64, 1) << @truncate(cur % 64);
                    if (bits[word_idx] & bit_mask != 0) continue;
                    bits[word_idx] |= bit_mask;

                    positions.append(cur) catch {};

                    const cd = cg.getCommitData(cur);
                    if (cd.parent1 != commit_graph_mod.CommitGraph.GRAPH_NO_PARENT) {
                        stack.append(cd.parent1) catch {};
                    }
                    if (cd.parent2 != commit_graph_mod.CommitGraph.GRAPH_NO_PARENT and cd.parent2 & commit_graph_mod.CommitGraph.GRAPH_EXTRA_EDGES == 0) {
                        stack.append(cd.parent2) catch {};
                    }
                }
            }

            // Phase 2: Resolve pack offsets
            const pack_offsets = allocator.alloc(PackOffset, positions.items.len) catch null;
            defer if (pack_offsets) |po| allocator.free(po);

            if (pack_offsets) |offsets| {
                for (positions.items, 0..) |pos, i| {
                    const oid_bytes = cg.getOidBytes(pos);
                    offsets[i] = .{ .pack_idx = 0, .offset = 0 };
                    for (0..num_packs) |pi| {
                        if (objects.findOffsetInIdx(idx_data_arr[pi], oid_bytes.*)) |off| {
                            offsets[i] = .{ .pack_idx = @intCast(pi), .offset = @intCast(off) };
                            break;
                        }
                    }
                }

                // Phase 3: Parallel decompression + author extraction
                const total = offsets.len;
                const total_threads = NUM_WORKER_THREADS + 1;
                const chunk_size = (total + total_threads - 1) / total_threads;

                // Allocate result buffers for worker threads
                var worker_ctxs: [NUM_WORKER_THREADS]WorkerCtx = undefined;
                var worker_bufs: [NUM_WORKER_THREADS][]u8 = undefined;
                var threads: [NUM_WORKER_THREADS]std.Thread = undefined;
                var spawned: usize = 0;

                for (0..NUM_WORKER_THREADS) |t| {
                    const start = (t + 1) * chunk_size;
                    if (start >= total) break;
                    const end = @min(start + chunk_size, total);
                    const buf = allocator.alloc(u8, (end - start) * 128) catch break;
                    worker_bufs[t] = buf;
                    worker_ctxs[t] = .{
                        .offsets = offsets[start..end],
                        .pack_data_arr = &pack_data_arr,
                        .idx_data_arr = &idx_data_arr,
                        .num_packs = num_packs,
                        .include_email = email,
                        .result_buf = buf,
                        .result_len = 0,
                        .author_count = 0,
                    };
                    threads[t] = std.Thread.spawn(.{}, workerFn, .{&worker_ctxs[t]}) catch break;
                    spawned += 1;
                }

                // Main thread processes first chunk
                var main_ctx = WorkerCtx{
                    .offsets = offsets[0..@min(chunk_size, total)],
                    .pack_data_arr = &pack_data_arr,
                    .idx_data_arr = &idx_data_arr,
                    .num_packs = num_packs,
                    .include_email = email,
                    .result_buf = undefined,
                    .result_len = 0,
                    .author_count = 0,
                };
                const main_buf = allocator.alloc(u8, @min(chunk_size, total) * 128) catch null;
                defer if (main_buf) |b| allocator.free(b);
                if (main_buf) |b| {
                    main_ctx.result_buf = b;
                    processChunk(&main_ctx);
                    // Merge main thread results
                    mergeResults(&author_map, main_ctx.result_buf[0..main_ctx.result_len], allocator);
                }

                // Wait for workers and merge their results
                var total_found: usize = main_ctx.author_count;
                for (0..spawned) |t| {
                    threads[t].join();
                    mergeResults(&author_map, worker_ctxs[t].result_buf[0..worker_ctxs[t].result_len], allocator);
                    total_found += worker_ctxs[t].author_count;
                    allocator.free(worker_bufs[t]);
                }

                // Phase 4: Handle any missed commits (deltas, large objects)
                // The parallel workers only handle non-delta commits.
                if (total_found < positions.items.len) {
                    // Check each commit's pack type and use global decompressor for deltas
                    for (positions.items, offsets) |pos_val, po| {
                        if (po.offset == 0) continue;
                        // Quick check: is this a delta?
                        const pack_data = pack_data_arr[po.pack_idx];
                        if (po.offset >= pack_data.len) continue;
                        const first_byte = pack_data[po.offset];
                        const pack_type_num: u3 = @truncate((first_byte >> 4) & 7);
                        if (pack_type_num == 1) continue; // Already handled by worker

                        // Delta commit: use global decompressor
                        const data = objects.readPackCommitHeaderDirect(
                            pack_data,
                            idx_data_arr[po.pack_idx],
                            po.offset,
                        ) orelse blk: {
                            // Final fallback: full object load
                            var hash_hex: [40]u8 = undefined;
                            cg.getOidHex(pos_val, &hash_hex);
                            if (objects.GitObject.load(&hash_hex, git_path, platform_impl, allocator)) |obj| {
                                defer obj.deinit(allocator);
                                const author2 = extractAuthor(obj.data, email);
                                if (author2.len > 0) {
                                    if (author_map.getPtr(author2)) |cnt| {
                                        cnt.* += 1;
                                    } else {
                                        author_map.put(allocator.dupe(u8, author2) catch continue, 1) catch {};
                                    }
                                }
                            } else |_| {}
                            break :blk null;
                        };
                        if (data) |d| {
                            const author = extractAuthor(d, email);
                            if (author.len > 0) {
                                if (author_map.getPtr(author)) |cnt| {
                                    cnt.* += 1;
                                } else {
                                    author_map.put(allocator.dupe(u8, author) catch continue, 1) catch {};
                                }
                            }
                        }
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
    try out_buf.ensureTotalCapacity(results.items.len * 40);
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
        }
    }
    if (out_buf.items.len > 0) {
        try platform_impl.writeStdout(out_buf.items);
    }
}

/// Merge null-separated author names from result buffer into author_map
fn mergeResults(author_map: *std.StringHashMap(u32), data: []const u8, allocator: std.mem.Allocator) void {
    var pos: usize = 0;
    while (pos < data.len) {
        var end = pos;
        while (end < data.len and data[end] != 0) : (end += 1) {}
        if (end > pos) {
            const author = data[pos..end];
            if (author_map.getPtr(author)) |cnt| {
                cnt.* += 1;
            } else {
                author_map.put(allocator.dupe(u8, author) catch {
                    pos = end + 1;
                    continue;
                }, 1) catch {};
            }
        }
        pos = end + 1;
    }
}

fn extractAuthor(data: []const u8, include_email: bool) []const u8 {
    var pos: usize = 0;
    while (pos + 7 < data.len) {
        if (data[pos] == 'a' and pos + 7 <= data.len and std.mem.eql(u8, data[pos .. pos + 7], "author ")) {
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
        while (pos < data.len and data[pos] != '\n') : (pos += 1) {}
        pos += 1;
        if (pos < data.len and data[pos] == '\n') break;
    }
    return "";
}
