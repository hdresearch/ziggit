const std = @import("std");
const stream_utils = @import("stream_utils.zig");

/// Bounded LRU cache for resolved object data during delta resolution.
const ResolveCache = struct {
    const Entry = struct {
        type_str: []const u8, // static string, not owned
        data: []u8, // owned by the cache
    };
    const Node = struct {
        offset: usize,
        entry: Entry,
        prev: ?*Node,
        next: ?*Node,
    };

    allocator: std.mem.Allocator,
    map: std.AutoHashMap(usize, *Node),
    head: ?*Node,
    tail: ?*Node,
    total_bytes: usize,
    max_bytes: usize,

    fn init(allocator: std.mem.Allocator, max_bytes: usize) ResolveCache {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(usize, *Node).init(allocator),
            .head = null,
            .tail = null,
            .total_bytes = 0,
            .max_bytes = max_bytes,
        };
    }

    fn deinit(self: *ResolveCache) void {
        var node = self.head;
        while (node) |n| {
            const next = n.next;
            self.allocator.free(n.entry.data);
            self.allocator.destroy(n);
            node = next;
        }
        self.map.deinit();
    }

    fn get(self: *ResolveCache, offset: usize) ?Entry {
        if (self.map.get(offset)) |node| {
            self.moveToTail(node);
            return node.entry;
        }
        return null;
    }

    /// Insert entry. Cache takes ownership of `data`.
    fn put(self: *ResolveCache, offset: usize, type_str: []const u8, data: []u8) !void {
        if (self.map.get(offset)) |existing| {
            self.total_bytes -= existing.entry.data.len;
            self.allocator.free(existing.entry.data);
            existing.entry = .{ .type_str = type_str, .data = data };
            self.total_bytes += data.len;
            self.moveToTail(existing);
            return;
        }
        while (self.total_bytes + data.len > self.max_bytes and self.head != null) {
            self.evictHead();
        }
        const node = try self.allocator.create(Node);
        node.* = .{ .offset = offset, .entry = .{ .type_str = type_str, .data = data }, .prev = null, .next = null };
        try self.map.put(offset, node);
        self.appendToTail(node);
        self.total_bytes += data.len;
    }

    /// Insert by duping the data (caller retains ownership of original).
    fn putDupe(self: *ResolveCache, offset: usize, type_str: []const u8, data: []const u8) !void {
        const owned = try self.allocator.dupe(u8, data);
        self.put(offset, type_str, owned) catch |err| {
            self.allocator.free(owned);
            return err;
        };
    }

    fn evictHead(self: *ResolveCache) void {
        const node = self.head orelse return;
        self.removeNode(node);
        _ = self.map.remove(node.offset);
        self.total_bytes -= node.entry.data.len;
        self.allocator.free(node.entry.data);
        self.allocator.destroy(node);
    }

    fn removeNode(self: *ResolveCache, node: *Node) void {
        if (node.prev) |p| p.next = node.next else self.head = node.next;
        if (node.next) |n| n.prev = node.prev else self.tail = node.prev;
        node.prev = null;
        node.next = null;
    }

    fn appendToTail(self: *ResolveCache, node: *Node) void {
        node.prev = self.tail;
        node.next = null;
        if (self.tail) |t| t.next = node else self.head = node;
        self.tail = node;
    }

    fn moveToTail(self: *ResolveCache, node: *Node) void {
        if (self.tail == node) return;
        self.removeNode(node);
        self.appendToTail(node);
    }
};

/// Object entry collected during pack index generation
const IndexEntry = struct {
    sha1: [20]u8,
    offset: u64,
    crc32: u32,
};

/// Minimal per-object record for fallback re-resolution on cache miss.
const ObjRecord = struct {
    offset: usize,
    comp_start: usize,
    comp_len: usize,
    pack_type: u3,
    size: usize,
    base_offset: usize, // absolute offset, for ofs_delta only
};

/// Generate a .idx file next to the given .pack file.
pub fn generateIdx(allocator: std.mem.Allocator, pack_path: []const u8) !void {
    const pack_data = try std.fs.cwd().readFileAlloc(allocator, pack_path, 512 * 1024 * 1024);
    defer allocator.free(pack_data);

    const idx_data = try generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    if (!std.mem.endsWith(u8, pack_path, ".pack")) return error.InvalidPackPath;
    const base = pack_path[0 .. pack_path.len - 5];
    const idx_path = try std.fmt.allocPrint(allocator, "{s}.idx", .{base});
    defer allocator.free(idx_path);

    const file = try std.fs.cwd().createFile(idx_path, .{});
    defer file.close();
    try file.writeAll(idx_data);
}

/// Generate idx data from in-memory pack data. Returns owned slice.
///
/// Uses a single forward pass over the pack: each object is inflated exactly
/// once.  Base objects are decompressed+hashed+captured in one shot; their
/// data is placed in a bounded LRU cache so that subsequent OFS_DELTA
/// objects can apply their deltas without re-inflating the base.
/// REF_DELTA objects whose base hasn't been seen yet are deferred and
/// resolved in follow-up iterations.
pub fn generateIdxFromData(allocator: std.mem.Allocator, pack_data: []const u8) ![]u8 {
    if (pack_data.len < 32) return error.PackFileTooSmall;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPackSignature;

    const object_count = std.mem.readInt(u32, pack_data[8..12], .big);
    const content_end = pack_data.len - 20;
    const pack_checksum = pack_data[content_end..][0..20];

    var entries = try std.ArrayList(IndexEntry).initCapacity(allocator, object_count);
    defer entries.deinit();

    // Bounded LRU cache (64 MB) for resolved object data.
    var cache = ResolveCache.init(allocator, 64 * 1024 * 1024);
    defer cache.deinit();

    // Reusable buffer for decompression (avoids per-object allocation).
    var decomp_buf = std.ArrayList(u8).init(allocator);
    defer decomp_buf.deinit();

    // SHA-1 → pack offset for REF_DELTA resolution.
    var sha_to_offset = std.AutoHashMap([20]u8, usize).init(allocator);
    defer sha_to_offset.deinit();

    // Per-object records for fallback re-resolution on cache eviction.
    var records = try allocator.alloc(ObjRecord, object_count);
    defer allocator.free(records);

    // offset → record-index for cache-miss fallback.
    var offset_to_idx = std.AutoHashMap(usize, u32).init(allocator);
    defer offset_to_idx.deinit();
    try offset_to_idx.ensureTotalCapacity(object_count);

    // Deferred REF_DELTAs whose base is not yet resolved.
    const DeferredDelta = struct {
        obj_start: usize,
        crc32: u32,
        base_sha1: [20]u8,
        delta_instructions: []u8, // owned
        resolved: bool,
    };
    var deferred = std.ArrayList(DeferredDelta).init(allocator);
    defer {
        for (deferred.items) |d| {
            if (!d.resolved) allocator.free(d.delta_instructions);
        }
        deferred.deinit();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Single forward pass – parse, decompress, resolve
    // ═══════════════════════════════════════════════════════════════════
    var pos: usize = 12;
    var obj_idx: u32 = 0;
    while (obj_idx < object_count and pos < content_end) {
        const obj_start = pos;

        const hdr = stream_utils.parsePackObjectHeader(pack_data, pos) catch {
            records[obj_idx] = std.mem.zeroes(ObjRecord);
            obj_idx += 1;
            pos += 1;
            continue;
        };
        pos += hdr.header_len;
        const pt = hdr.type_num;

        if (pt >= 1 and pt <= 4) {
            // ── Base object: decompress + hash + capture in one inflation ──
            const type_str = stream_utils.packTypeToString(pt) orelse "blob";
            const comp_start = pos;

            decomp_buf.clearRetainingCapacity();
            const result = stream_utils.decompressHashAndCapture(
                pack_data[comp_start..content_end],
                type_str,
                hdr.size,
                &decomp_buf,
            ) catch {
                records[obj_idx] = std.mem.zeroes(ObjRecord);
                obj_idx += 1;
                pos += 1;
                continue;
            };
            pos = comp_start + result.bytes_consumed;

            records[obj_idx] = .{
                .offset = obj_start,
                .comp_start = comp_start,
                .comp_len = result.bytes_consumed,
                .pack_type = pt,
                .size = hdr.size,
                .base_offset = 0,
            };
            offset_to_idx.putAssumeCapacity(obj_start, obj_idx);

            try entries.append(.{
                .sha1 = result.sha1,
                .offset = @intCast(obj_start),
                .crc32 = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj_start..pos]),
            });

            // Cache data for potential delta dependents.
            try cache.putDupe(obj_start, type_str, decomp_buf.items);
            try sha_to_offset.put(result.sha1, obj_start);
        } else if (pt == 6) {
            // ── OFS_DELTA ──
            const ofs = stream_utils.parseOfsOffset(pack_data, pos) catch {
                records[obj_idx] = std.mem.zeroes(ObjRecord);
                obj_idx += 1;
                pos += 1;
                continue;
            };
            pos += ofs.bytes_consumed;

            if (ofs.negative_offset > obj_start) {
                records[obj_idx] = std.mem.zeroes(ObjRecord);
                obj_idx += 1;
                pos += 1;
                continue;
            }
            const base_offset = obj_start - ofs.negative_offset;

            const comp_start = pos;

            // Decompress delta instructions (single inflation).
            decomp_buf.clearRetainingCapacity();
            if (hdr.size > 0) try decomp_buf.ensureTotalCapacity(hdr.size);
            const decomp_info = stream_utils.decompressInto(
                pack_data[comp_start..content_end],
                &decomp_buf,
            ) catch {
                records[obj_idx] = std.mem.zeroes(ObjRecord);
                obj_idx += 1;
                pos += 1;
                continue;
            };
            pos = comp_start + decomp_info.bytes_consumed;

            records[obj_idx] = .{
                .offset = obj_start,
                .comp_start = comp_start,
                .comp_len = decomp_info.bytes_consumed,
                .pack_type = pt,
                .size = hdr.size,
                .base_offset = base_offset,
            };
            offset_to_idx.putAssumeCapacity(obj_start, obj_idx);

            const crc = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj_start..pos]);

            // Resolve: get base from cache (or fallback re-resolve).
            const base = cache.get(base_offset) orelse blk: {
                break :blk resolveFromPack(
                    allocator,
                    pack_data,
                    content_end,
                    base_offset,
                    &cache,
                    records[0 .. obj_idx + 1],
                    &offset_to_idx,
                ) catch {
                    obj_idx += 1;
                    continue;
                };
            };

            const result_data = applyDelta(allocator, base.data, decomp_buf.items) catch {
                obj_idx += 1;
                continue;
            };
            const sha1 = stream_utils.hashGitObject(base.type_str, result_data);

            try entries.append(.{ .sha1 = sha1, .offset = @intCast(obj_start), .crc32 = crc });
            try cache.put(obj_start, base.type_str, result_data); // transfers ownership
            sha_to_offset.put(sha1, obj_start) catch {};
        } else if (pt == 7) {
            // ── REF_DELTA ──
            if (pos + 20 > content_end) {
                records[obj_idx] = std.mem.zeroes(ObjRecord);
                obj_idx += 1;
                pos += 1;
                continue;
            }
            var base_sha1: [20]u8 = undefined;
            @memcpy(&base_sha1, pack_data[pos .. pos + 20]);
            pos += 20;

            const comp_start = pos;

            decomp_buf.clearRetainingCapacity();
            if (hdr.size > 0) try decomp_buf.ensureTotalCapacity(hdr.size);
            const decomp_info = stream_utils.decompressInto(
                pack_data[comp_start..content_end],
                &decomp_buf,
            ) catch {
                records[obj_idx] = std.mem.zeroes(ObjRecord);
                obj_idx += 1;
                pos += 1;
                continue;
            };
            pos = comp_start + decomp_info.bytes_consumed;

            records[obj_idx] = .{
                .offset = obj_start,
                .comp_start = comp_start,
                .comp_len = decomp_info.bytes_consumed,
                .pack_type = pt,
                .size = hdr.size,
                .base_offset = 0,
            };
            offset_to_idx.putAssumeCapacity(obj_start, obj_idx);

            const crc = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj_start..pos]);

            // Try to resolve immediately.
            const resolved = blk: {
                const bo = sha_to_offset.get(base_sha1) orelse break :blk false;
                const base_entry = cache.get(bo) orelse break :blk false;
                const result_data = applyDelta(allocator, base_entry.data, decomp_buf.items) catch break :blk false;
                const sha1 = stream_utils.hashGitObject(base_entry.type_str, result_data);
                entries.append(.{ .sha1 = sha1, .offset = @intCast(obj_start), .crc32 = crc }) catch {
                    allocator.free(result_data);
                    break :blk false;
                };
                cache.put(obj_start, base_entry.type_str, result_data) catch {};
                sha_to_offset.put(sha1, obj_start) catch {};
                break :blk true;
            };

            if (!resolved) {
                // Defer: keep delta instructions for later resolution.
                const instr_copy = try allocator.dupe(u8, decomp_buf.items);
                try deferred.append(.{
                    .obj_start = obj_start,
                    .crc32 = crc,
                    .base_sha1 = base_sha1,
                    .delta_instructions = instr_copy,
                    .resolved = false,
                });
            }
        } else {
            // Unknown type — skip byte.
            records[obj_idx] = std.mem.zeroes(ObjRecord);
            obj_idx += 1;
            pos += 1;
            continue;
        }

        obj_idx += 1;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Resolve deferred REF_DELTAs (multi-pass until convergence)
    // ═══════════════════════════════════════════════════════════════════
    {
        var remaining: usize = 0;
        for (deferred.items) |d| {
            if (!d.resolved) remaining += 1;
        }

        var max_iters: usize = 50;
        while (remaining > 0 and max_iters > 0) : (max_iters -= 1) {
            var new_remaining: usize = 0;
            for (deferred.items) |*d| {
                if (d.resolved) continue;
                const bo = sha_to_offset.get(d.base_sha1) orelse {
                    new_remaining += 1;
                    continue;
                };
                const base_entry = cache.get(bo) orelse {
                    new_remaining += 1;
                    continue;
                };
                const result_data = applyDelta(allocator, base_entry.data, d.delta_instructions) catch {
                    new_remaining += 1;
                    continue;
                };
                const sha1 = stream_utils.hashGitObject(base_entry.type_str, result_data);
                entries.append(.{ .sha1 = sha1, .offset = @intCast(d.obj_start), .crc32 = d.crc32 }) catch {
                    allocator.free(result_data);
                    new_remaining += 1;
                    continue;
                };
                cache.put(d.obj_start, base_entry.type_str, result_data) catch {};
                sha_to_offset.put(sha1, d.obj_start) catch {};
                allocator.free(d.delta_instructions);
                d.resolved = true;
            }
            if (new_remaining == remaining) break; // no progress
            remaining = new_remaining;
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Sort entries by SHA-1 (required for idx v2 format)
    // ═══════════════════════════════════════════════════════════════════
    std.sort.block(IndexEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: IndexEntry, b: IndexEntry) bool {
            return std.mem.order(u8, &a.sha1, &b.sha1) == .lt;
        }
    }.lessThan);

    // ═══════════════════════════════════════════════════════════════════
    // Build v2 .idx file
    // ═══════════════════════════════════════════════════════════════════
    var idx = std.ArrayList(u8).init(allocator);
    defer idx.deinit();
    try idx.ensureTotalCapacity(8 + 256 * 4 + entries.items.len * (20 + 4 + 4) + 40);

    // Magic + version
    try idx.writer().writeInt(u32, 0xff744f63, .big);
    try idx.writer().writeInt(u32, 2, .big);

    // Fanout table
    var fanout: [256]u32 = [_]u32{0} ** 256;
    for (entries.items) |entry| fanout[entry.sha1[0]] += 1;
    var cumulative: u32 = 0;
    for (0..256) |i| {
        cumulative += fanout[i];
        try idx.writer().writeInt(u32, cumulative, .big);
    }

    // SHA-1 table
    for (entries.items) |entry| try idx.appendSlice(&entry.sha1);

    // CRC-32 table
    for (entries.items) |entry| try idx.writer().writeInt(u32, entry.crc32, .big);

    // Offset table (+ large offset overflow)
    var large_offsets = std.ArrayList(u64).init(allocator);
    defer large_offsets.deinit();
    for (entries.items) |entry| {
        if (entry.offset >= 0x80000000) {
            try idx.writer().writeInt(u32, @as(u32, @intCast(large_offsets.items.len)) | 0x80000000, .big);
            try large_offsets.append(entry.offset);
        } else {
            try idx.writer().writeInt(u32, @intCast(entry.offset), .big);
        }
    }
    for (large_offsets.items) |offset| try idx.writer().writeInt(u64, offset, .big);

    // Checksums
    try idx.appendSlice(pack_checksum);
    var idx_hasher = std.crypto.hash.Sha1.init(.{});
    idx_hasher.update(idx.items);
    var idx_checksum: [20]u8 = undefined;
    idx_hasher.final(&idx_checksum);
    try idx.appendSlice(&idx_checksum);

    return try idx.toOwnedSlice();
}

/// Fallback: re-resolve an object from pack data on cache miss.
/// Recursively resolves delta chains. Used when the LRU cache has
/// evicted a needed base (rare with sufficient budget).
fn resolveFromPack(
    allocator: std.mem.Allocator,
    pack_data: []const u8,
    content_end: usize,
    offset: usize,
    cache: *ResolveCache,
    records: []const ObjRecord,
    offset_to_idx: *std.AutoHashMap(usize, u32),
) !ResolveCache.Entry {
    // Check cache first.
    if (cache.get(offset)) |e| return e;

    const ri = offset_to_idx.get(offset) orelse return error.InvalidOffset;
    const rec = records[ri];
    const compressed = pack_data[rec.comp_start .. rec.comp_start + rec.comp_len];

    if (rec.pack_type >= 1 and rec.pack_type <= 4) {
        const type_str = stream_utils.packTypeToString(rec.pack_type) orelse return error.UnsupportedPackType;
        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();
        if (rec.size > 0) try output.ensureTotalCapacity(rec.size);
        _ = try stream_utils.decompressInto(compressed, &output);
        const data = try output.toOwnedSlice();
        try cache.put(offset, type_str, data);
        return cache.get(offset).?;
    } else if (rec.pack_type == 6) {
        if (rec.base_offset == 0) return error.InvalidDeltaOffset;
        const base = try resolveFromPack(allocator, pack_data, content_end, rec.base_offset, cache, records, offset_to_idx);

        var delta_list = std.ArrayList(u8).init(allocator);
        defer delta_list.deinit();
        if (rec.size > 0) try delta_list.ensureTotalCapacity(rec.size);
        _ = try stream_utils.decompressInto(compressed, &delta_list);
        const result = try applyDelta(allocator, base.data, delta_list.items);
        try cache.put(offset, base.type_str, result);
        return cache.get(offset).?;
    }

    return error.UnsupportedPackType;
}

/// Apply a git delta to a base object. Returns owned slice.
fn applyDelta(allocator: std.mem.Allocator, base: []const u8, delta: []const u8) ![]u8 {
    var dpos: usize = 0;
    _ = readDeltaVarint(delta, &dpos);
    const result_size = readDeltaVarint(delta, &dpos);

    var result = try allocator.alloc(u8, result_size);
    errdefer allocator.free(result);
    var rpos: usize = 0;

    while (dpos < delta.len) {
        const cmd = delta[dpos];
        dpos += 1;

        if (cmd & 0x80 != 0) {
            var copy_offset: usize = 0;
            var copy_size: usize = 0;
            if (cmd & 0x01 != 0) {
                copy_offset |= @as(usize, delta[dpos]);
                dpos += 1;
            }
            if (cmd & 0x02 != 0) {
                copy_offset |= @as(usize, delta[dpos]) << 8;
                dpos += 1;
            }
            if (cmd & 0x04 != 0) {
                copy_offset |= @as(usize, delta[dpos]) << 16;
                dpos += 1;
            }
            if (cmd & 0x08 != 0) {
                copy_offset |= @as(usize, delta[dpos]) << 24;
                dpos += 1;
            }
            if (cmd & 0x10 != 0) {
                copy_size |= @as(usize, delta[dpos]);
                dpos += 1;
            }
            if (cmd & 0x20 != 0) {
                copy_size |= @as(usize, delta[dpos]) << 8;
                dpos += 1;
            }
            if (cmd & 0x40 != 0) {
                copy_size |= @as(usize, delta[dpos]) << 16;
                dpos += 1;
            }
            if (copy_size == 0) copy_size = 0x10000;
            if (copy_offset + copy_size > base.len) return error.DeltaCopyOutOfBounds;
            @memcpy(result[rpos..][0..copy_size], base[copy_offset..][0..copy_size]);
            rpos += copy_size;
        } else if (cmd > 0) {
            const n: usize = @intCast(cmd);
            if (dpos + n > delta.len) return error.DeltaInsertOutOfBounds;
            @memcpy(result[rpos..][0..n], delta[dpos..][0..n]);
            rpos += n;
            dpos += n;
        } else {
            return error.DeltaReservedCommand;
        }
    }

    return result;
}

fn readDeltaVarint(data: []const u8, pos: *usize) usize {
    var value: usize = 0;
    var shift: u6 = 0;
    while (pos.* < data.len) {
        const b = data[pos.*];
        pos.* += 1;
        value |= @as(usize, b & 0x7F) << shift;
        if (b & 0x80 == 0) break;
        if (shift < 60) shift += 7 else break;
    }
    return value;
}
