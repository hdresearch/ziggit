const std = @import("std");
const stream_utils = @import("stream_utils.zig");

/// Object entry collected during pack index generation
const IndexEntry = struct {
    sha1: [20]u8,
    offset: u64,
    crc32: u32,
};

/// Object info from pass 1 scan
const ObjectInfo = struct {
    offset: usize,
    compressed_start: usize,
    compressed_len: usize,
    pack_type: u3,
    size: usize,
    base_offset: usize, // for ofs_delta
    base_sha1: [20]u8, // for ref_delta
    /// SHA-1 computed in pass 1 for base objects (type 1-4)
    sha1: [20]u8,
    crc32: u32,
    /// true if SHA-1 was already computed
    resolved: bool,
};

/// Bounded LRU cache for resolved object data during delta resolution.
/// Simpler inline implementation to avoid delta_cache.zig compile issues.
const ResolveCache = struct {
    const Entry = struct {
        type_str: []const u8, // static, not owned
        data: []u8, // owned
    };
    const Node = struct {
        offset: usize,
        entry: Entry,
        prev: ?*Node,
        next: ?*Node,
    };

    allocator: std.mem.Allocator,
    map: std.AutoHashMap(usize, *Node),
    head: ?*Node, // LRU
    tail: ?*Node, // MRU
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

/// Skip zlib-compressed data, returning number of compressed bytes consumed.
/// Uses streaming decompression with a stack-allocated discard buffer (no heap allocation).
fn skipInflate(compressed_data: []const u8) !usize {
    var fbs = std.io.fixedBufferStream(compressed_data);
    var decompressor = std.compress.zlib.decompressor(fbs.reader());
    var discard: [16384]u8 = undefined;
    while (true) {
        const n = decompressor.read(&discard) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
    }
    return @intCast(fbs.pos);
}

/// Decompress zlib data into an ArrayList (reusable), returning bytes consumed.
fn decompressToList(compressed_data: []const u8, output: *std.ArrayList(u8)) !usize {
    var fbs = std.io.fixedBufferStream(compressed_data);
    var decompressor = std.compress.zlib.decompressor(fbs.reader());
    var chunk_buf: [16384]u8 = undefined;
    while (true) {
        const n = decompressor.read(&chunk_buf) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try output.appendSlice(chunk_buf[0..n]);
    }
    return @intCast(fbs.pos);
}

/// Generate idx data from in-memory pack data. Returns owned slice.
pub fn generateIdxFromData(allocator: std.mem.Allocator, pack_data: []const u8) ![]u8 {
    if (pack_data.len < 32) return error.PackFileTooSmall;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPackSignature;

    const object_count = std.mem.readInt(u32, pack_data[8..12], .big);
    const content_end = pack_data.len - 20;
    const pack_checksum = pack_data[content_end..][0..20];

    // ═══ Pass 1: Scan all objects, hash base objects in-line ═══
    // Base objects (type 1-4): decompressAndHash → SHA-1 with zero heap allocation
    // Delta objects (type 6,7): skip compressed data to find boundaries
    var objects = try allocator.alloc(ObjectInfo, object_count);
    defer allocator.free(objects);

    // Track which offsets are referenced as delta bases
    var delta_base_set = std.AutoHashMap(usize, void).init(allocator);
    defer delta_base_set.deinit();

    {
        var pos: usize = 12;
        var idx: u32 = 0;
        while (idx < object_count and pos < content_end) {
            const obj_start = pos;

            // Parse pack object header
            const hdr = stream_utils.parsePackObjectHeader(pack_data, pos) catch {
                idx += 1;
                pos += 1;
                continue;
            };
            pos += hdr.header_len;
            const pt = hdr.type_num;

            var base_offset: usize = 0;
            var base_sha1: [20]u8 = .{0} ** 20;

            if (pt == 6) {
                const ofs = stream_utils.parseOfsOffset(pack_data, pos) catch {
                    idx += 1;
                    pos += 1;
                    continue;
                };
                pos += ofs.bytes_consumed;
                if (ofs.negative_offset <= obj_start) {
                    base_offset = obj_start - ofs.negative_offset;
                    try delta_base_set.put(base_offset, {});
                }
            } else if (pt == 7) {
                if (pos + 20 <= content_end) {
                    @memcpy(&base_sha1, pack_data[pos .. pos + 20]);
                    pos += 20;
                }
            }

            const comp_start = pos;
            var obj_sha1: [20]u8 = .{0} ** 20;
            var resolved = false;
            var comp_len: usize = 0;

            if (pt >= 1 and pt <= 4) {
                // Base object: stream decompress+hash, zero heap allocation
                const type_str = stream_utils.packTypeToString(pt) orelse "blob";
                const result = stream_utils.decompressAndHash(
                    pack_data[comp_start..content_end],
                    type_str,
                    hdr.size,
                ) catch {
                    idx += 1;
                    pos += 1;
                    continue;
                };
                comp_len = result.bytes_consumed;
                obj_sha1 = result.sha1;
                resolved = true;
            } else {
                // Delta: skip compressed data to find boundary
                comp_len = skipInflate(pack_data[comp_start..content_end]) catch {
                    idx += 1;
                    pos += 1;
                    continue;
                };
            }

            pos = comp_start + comp_len;

            // CRC32 over raw pack bytes (header + compressed data)
            const crc = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj_start..pos]);

            objects[idx] = .{
                .offset = obj_start,
                .compressed_start = comp_start,
                .compressed_len = comp_len,
                .pack_type = pt,
                .size = hdr.size,
                .base_offset = base_offset,
                .base_sha1 = base_sha1,
                .sha1 = obj_sha1,
                .crc32 = crc,
                .resolved = resolved,
            };
            idx += 1;
        }
    }

    // Build offset → object index map
    var offset_map = std.AutoHashMap(usize, u32).init(allocator);
    defer offset_map.deinit();
    try offset_map.ensureTotalCapacity(object_count);
    for (0..object_count) |i| {
        offset_map.putAssumeCapacity(objects[i].offset, @intCast(i));
    }

    // Build SHA-1 → offset map for REF_DELTA resolution
    var sha_to_offset = std.AutoHashMap([20]u8, usize).init(allocator);
    defer sha_to_offset.deinit();
    {
        var count: u32 = 0;
        for (objects[0..object_count]) |obj| {
            if (obj.resolved) count += 1;
        }
        try sha_to_offset.ensureTotalCapacity(count);
        for (objects[0..object_count]) |obj| {
            if (obj.resolved) {
                sha_to_offset.putAssumeCapacity(obj.sha1, obj.offset);
            }
        }
    }

    // ═══ Pass 2: Resolve delta objects ═══
    // Bounded LRU cache (32MB) for resolved object data
    var cache = ResolveCache.init(allocator, 32 * 1024 * 1024);
    defer cache.deinit();

    // Reusable buffer for delta decompression
    var delta_buf = std.ArrayList(u8).init(allocator);
    defer delta_buf.deinit();

    var entries = try std.ArrayList(IndexEntry).initCapacity(allocator, object_count);
    defer entries.deinit();

    // Add already-resolved base objects
    for (objects[0..object_count]) |obj| {
        if (obj.resolved) {
            try entries.append(.{
                .sha1 = obj.sha1,
                .offset = @intCast(obj.offset),
                .crc32 = obj.crc32,
            });
        }
    }

    // Resolve delta objects
    for (objects[0..object_count]) |*obj| {
        if (obj.resolved) continue;
        if (obj.pack_type != 6 and obj.pack_type != 7) continue;

        var bo: usize = 0;
        if (obj.pack_type == 6) {
            if (obj.base_offset == 0) continue;
            bo = obj.base_offset;
        } else {
            bo = sha_to_offset.get(obj.base_sha1) orelse continue;
        }

        const base = resolveObject(
            allocator,
            pack_data,
            objects[0..object_count],
            &offset_map,
            &sha_to_offset,
            &cache,
            bo,
        ) catch continue;

        // Decompress delta instructions (reuse buffer)
        delta_buf.clearRetainingCapacity();
        if (obj.size > 0) {
            try delta_buf.ensureTotalCapacity(obj.size);
        }
        _ = try decompressToList(
            pack_data[obj.compressed_start .. obj.compressed_start + obj.compressed_len],
            &delta_buf,
        );

        // Apply delta
        const result_data = try applyDelta(allocator, base.data, delta_buf.items);

        // Hash the result
        const sha1 = stream_utils.hashGitObject(base.type_str, result_data);

        try entries.append(.{
            .sha1 = sha1,
            .offset = @intCast(obj.offset),
            .crc32 = obj.crc32,
        });

        // Update maps for chained delta resolution
        sha_to_offset.put(sha1, obj.offset) catch {};

        // Cache if this object is a delta base
        if (delta_base_set.contains(obj.offset)) {
            try cache.put(obj.offset, base.type_str, result_data);
        } else {
            allocator.free(result_data);
        }

        obj.resolved = true;
        obj.sha1 = sha1;
    }

    // Sort by SHA-1
    std.sort.block(IndexEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: IndexEntry, b: IndexEntry) bool {
            return std.mem.order(u8, &a.sha1, &b.sha1) == .lt;
        }
    }.lessThan);

    // ═══ Build v2 idx file ═══
    var idx = std.ArrayList(u8).init(allocator);
    defer idx.deinit();
    try idx.ensureTotalCapacity(8 + 256 * 4 + entries.items.len * (20 + 4 + 4) + 40);

    try idx.writer().writeInt(u32, 0xff744f63, .big);
    try idx.writer().writeInt(u32, 2, .big);

    var fanout: [256]u32 = [_]u32{0} ** 256;
    for (entries.items) |entry| fanout[entry.sha1[0]] += 1;
    var cumulative: u32 = 0;
    for (0..256) |i| {
        cumulative += fanout[i];
        try idx.writer().writeInt(u32, cumulative, .big);
    }

    for (entries.items) |entry| try idx.appendSlice(&entry.sha1);
    for (entries.items) |entry| try idx.writer().writeInt(u32, entry.crc32, .big);

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

    try idx.appendSlice(pack_checksum);

    var idx_hasher = std.crypto.hash.Sha1.init(.{});
    idx_hasher.update(idx.items);
    var idx_checksum: [20]u8 = undefined;
    idx_hasher.final(&idx_checksum);
    try idx.appendSlice(&idx_checksum);

    return try idx.toOwnedSlice();
}

/// Resolve an object at the given offset, returning its type and data.
/// Uses the ResolveCache for memoization. Recursively resolves delta chains.
fn resolveObject(
    allocator: std.mem.Allocator,
    pack_data: []const u8,
    objects: []const ObjectInfo,
    offset_map: *std.AutoHashMap(usize, u32),
    sha_to_offset: *std.AutoHashMap([20]u8, usize),
    cache: *ResolveCache,
    offset: usize,
) !ResolveCache.Entry {
    if (cache.get(offset)) |entry| return entry;

    const idx = offset_map.get(offset) orelse return error.InvalidOffset;
    const obj = objects[idx];
    const compressed = pack_data[obj.compressed_start .. obj.compressed_start + obj.compressed_len];

    if (obj.pack_type >= 1 and obj.pack_type <= 4) {
        const type_str = stream_utils.packTypeToString(obj.pack_type) orelse return error.UnsupportedPackType;
        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();
        if (obj.size > 0) try output.ensureTotalCapacity(obj.size);
        _ = try decompressToList(compressed, &output);
        const data = try output.toOwnedSlice();
        try cache.put(offset, type_str, data);
        return cache.get(offset).?;
    } else if (obj.pack_type == 6) {
        if (obj.base_offset == 0) return error.InvalidDeltaOffset;
        const base = try resolveObject(allocator, pack_data, objects, offset_map, sha_to_offset, cache, obj.base_offset);
        var delta_list = std.ArrayList(u8).init(allocator);
        defer delta_list.deinit();
        if (obj.size > 0) try delta_list.ensureTotalCapacity(obj.size);
        _ = try decompressToList(compressed, &delta_list);
        const result = try applyDelta(allocator, base.data, delta_list.items);
        try cache.put(offset, base.type_str, result);
        return cache.get(offset).?;
    } else if (obj.pack_type == 7) {
        const bo = sha_to_offset.get(obj.base_sha1) orelse return error.InvalidDeltaBase;
        const base = try resolveObject(allocator, pack_data, objects, offset_map, sha_to_offset, cache, bo);
        var delta_list = std.ArrayList(u8).init(allocator);
        defer delta_list.deinit();
        if (obj.size > 0) try delta_list.ensureTotalCapacity(obj.size);
        _ = try decompressToList(compressed, &delta_list);
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
            if (cmd & 0x01 != 0) { copy_offset |= @as(usize, delta[dpos]); dpos += 1; }
            if (cmd & 0x02 != 0) { copy_offset |= @as(usize, delta[dpos]) << 8; dpos += 1; }
            if (cmd & 0x04 != 0) { copy_offset |= @as(usize, delta[dpos]) << 16; dpos += 1; }
            if (cmd & 0x08 != 0) { copy_offset |= @as(usize, delta[dpos]) << 24; dpos += 1; }
            if (cmd & 0x10 != 0) { copy_size |= @as(usize, delta[dpos]); dpos += 1; }
            if (cmd & 0x20 != 0) { copy_size |= @as(usize, delta[dpos]) << 8; dpos += 1; }
            if (cmd & 0x40 != 0) { copy_size |= @as(usize, delta[dpos]) << 16; dpos += 1; }
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
