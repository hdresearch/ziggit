const std = @import("std");
const c = @cImport(@cInclude("zlib.h"));

/// Object entry collected during pack index generation
const IndexEntry = struct {
    sha1: [20]u8,
    offset: u64,
    crc32: u32,
};

/// Cached resolved object
const CachedObject = struct {
    type_str: []const u8,
    data: []u8,
};

/// Inflate using C zlib. Returns consumed input bytes and decompressed data.
fn zlibInflate(allocator: std.mem.Allocator, input: []const u8, size_hint: usize) !struct { consumed: usize, data: []u8 } {
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    stream.next_in = @constCast(@ptrCast(input.ptr));
    const in_len: c_uint = @intCast(@min(input.len, std.math.maxInt(c_uint)));
    stream.avail_in = in_len;

    if (c.inflateInit(&stream) != c.Z_OK) return error.ZlibInitFailed;
    errdefer _ = c.inflateEnd(&stream);

    var buf_size = if (size_hint > 0) size_hint else 4096;
    var output = try allocator.alloc(u8, buf_size);
    errdefer allocator.free(output);

    stream.next_out = @ptrCast(output.ptr);
    stream.avail_out = @intCast(@min(output.len, std.math.maxInt(c_uint)));

    while (true) {
        const ret = c.inflate(&stream, c.Z_FINISH);
        if (ret == c.Z_STREAM_END) break;
        if (ret == c.Z_BUF_ERROR or (ret == c.Z_OK and stream.avail_out == 0)) {
            const written = buf_size - @as(usize, @intCast(stream.avail_out));
            buf_size = if (buf_size < 65536) buf_size * 4 else buf_size * 2;
            output = try allocator.realloc(output, buf_size);
            stream.next_out = @ptrCast(output.ptr + written);
            stream.avail_out = @intCast(@min(buf_size - written, std.math.maxInt(c_uint)));
            continue;
        }
        _ = c.inflateEnd(&stream);
        return error.InflateFailed;
    }

    const total_out: usize = @intCast(stream.total_out);
    const consumed: usize = in_len - @as(usize, @intCast(stream.avail_in));
    _ = c.inflateEnd(&stream);

    return .{ .consumed = consumed, .data = output[0..total_out] };
}

/// Skip-inflate: just find compressed data boundary without keeping data
fn zlibSkipInflate(input: []const u8) !usize {
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    stream.next_in = @constCast(@ptrCast(input.ptr));
    const in_len: c_uint = @intCast(@min(input.len, std.math.maxInt(c_uint)));
    stream.avail_in = in_len;

    if (c.inflateInit(&stream) != c.Z_OK) return error.ZlibInitFailed;
    defer _ = c.inflateEnd(&stream);

    var discard: [16384]u8 = undefined;
    while (true) {
        stream.next_out = @ptrCast(&discard);
        stream.avail_out = discard.len;
        const ret = c.inflate(&stream, c.Z_NO_FLUSH);
        if (ret == c.Z_STREAM_END) break;
        if (ret != c.Z_OK and ret != c.Z_BUF_ERROR) return error.InflateFailed;
    }

    return in_len - @as(usize, @intCast(stream.avail_in));
}

fn typeStr(t: u3) []const u8 {
    return switch (t) { 1 => "commit", 2 => "tree", 3 => "blob", 4 => "tag", else => "unknown" };
}

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

/// Object info from pass 1 scan
const ObjectInfo = struct {
    offset: usize,
    compressed_start: usize,
    compressed_len: usize,
    pack_type: u3,
    size: usize,
    base_offset: usize, // for ofs_delta
    base_sha1: [20]u8, // for ref_delta
};

/// Generate idx data from in-memory pack data. Returns owned slice.
pub fn generateIdxFromData(allocator: std.mem.Allocator, pack_data: []const u8) ![]u8 {
    if (pack_data.len < 32) return error.PackFileTooSmall;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPackSignature;

    const object_count = std.mem.readInt(u32, pack_data[8..12], .big);
    const content_end = pack_data.len - 20;
    const pack_checksum = pack_data[content_end..][0..20];

    // === Pass 1: Scan all objects to find boundaries and identify delta bases ===
    var objects = try allocator.alloc(ObjectInfo, object_count);
    defer allocator.free(objects);

    var delta_base_set = std.AutoHashMap(usize, void).init(allocator);
    defer delta_base_set.deinit();

    {
        var pos: usize = 12;
        var idx: u32 = 0;
        while (idx < object_count and pos < content_end) {
            const obj_start = pos;

            // Parse header
            const first_byte = pack_data[pos];
            pos += 1;
            const pt: u3 = @intCast((first_byte >> 4) & 7);
            var size: usize = @intCast(first_byte & 0x0F);
            var shift: u6 = 4;
            var cb = first_byte;
            while (cb & 0x80 != 0 and pos < content_end) {
                cb = pack_data[pos];
                pos += 1;
                size |= @as(usize, @intCast(cb & 0x7F)) << shift;
                if (shift < 60) shift += 7 else break;
            }

            var base_offset: usize = 0;
            var base_sha1: [20]u8 = .{0} ** 20;

            if (pt == 6) {
                var delta_off: usize = 0;
                var first_db = true;
                while (pos < content_end) {
                    const b = pack_data[pos];
                    pos += 1;
                    if (first_db) { delta_off = @intCast(b & 0x7F); first_db = false; } else { delta_off = (delta_off + 1) << 7; delta_off += @intCast(b & 0x7F); }
                    if (b & 0x80 == 0) break;
                }
                if (delta_off <= obj_start) {
                    base_offset = obj_start - delta_off;
                    try delta_base_set.put(base_offset, {});
                }
            } else if (pt == 7) {
                if (pos + 20 <= content_end) {
                    @memcpy(&base_sha1, pack_data[pos .. pos + 20]);
                    pos += 20;
                }
            }

            const comp_start = pos;
            const comp_len = zlibSkipInflate(pack_data[pos..content_end]) catch {
                idx += 1;
                pos += 1;
                continue;
            };
            pos = comp_start + comp_len;

            objects[idx] = .{
                .offset = obj_start,
                .compressed_start = comp_start,
                .compressed_len = comp_len,
                .pack_type = pt,
                .size = size,
                .base_offset = base_offset,
                .base_sha1 = base_sha1,
            };
            idx += 1;
        }
    }

    // Build offset -> object index map for fast lookups
    var offset_map = std.AutoHashMap(usize, u32).init(allocator);
    defer offset_map.deinit();
    try offset_map.ensureTotalCapacity(object_count);
    for (0..object_count) |i| {
        offset_map.putAssumeCapacity(objects[i].offset, @intCast(i));
    }

    // Also identify transitive delta bases (delta objects that are themselves bases)
    {
        var changed = true;
        while (changed) {
            changed = false;
            for (objects[0..object_count]) |obj| {
                if (obj.pack_type == 6 and delta_base_set.contains(obj.offset)) {
                    if (!delta_base_set.contains(obj.base_offset)) {
                        // base_offset should already be in the set if it's a direct base,
                        // but this handles chains
                    }
                }
            }
            break; // delta bases are identified by who references them, not by type
        }
    }

    // === Pass 2: Compute SHA-1 and CRC32 for all objects ===
    var entries = try std.ArrayList(IndexEntry).initCapacity(allocator, object_count);
    defer entries.deinit();

    // Cache for delta base resolution (only stores objects that ARE delta bases)
    var resolve_cache = std.AutoHashMap(usize, CachedObject).init(allocator);
    defer {
        var it = resolve_cache.valueIterator();
        while (it.next()) |v| allocator.free(v.data);
        resolve_cache.deinit();
    }

    for (objects[0..object_count]) |obj| {
        const crc = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj.offset .. obj.compressed_start + obj.compressed_len]);
        var obj_sha1: [20]u8 = undefined;

        if (obj.pack_type >= 1 and obj.pack_type <= 4) {
            const ts = typeStr(obj.pack_type);
            const is_base = delta_base_set.contains(obj.offset);

            if (is_base) {
                // Decompress and keep data for delta resolution
                const result = try zlibInflate(allocator, pack_data[obj.compressed_start .. obj.compressed_start + obj.compressed_len], obj.size);
                // Transfer ownership to cache
                try resolve_cache.put(obj.offset, .{ .type_str = ts, .data = result.data });

                var hdr_buf: [64]u8 = undefined;
                const header = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ ts, result.data.len }) catch unreachable;
                var sha_hasher = std.crypto.hash.Sha1.init(.{});
                sha_hasher.update(header);
                sha_hasher.update(result.data);
                sha_hasher.final(&obj_sha1);
            } else {
                // Streaming: decompress → SHA-1, no allocation needed
                const result = try zlibInflate(allocator, pack_data[obj.compressed_start .. obj.compressed_start + obj.compressed_len], obj.size);
                defer allocator.free(result.data);

                var hdr_buf: [64]u8 = undefined;
                const header = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ ts, result.data.len }) catch unreachable;
                var sha_hasher = std.crypto.hash.Sha1.init(.{});
                sha_hasher.update(header);
                sha_hasher.update(result.data);
                sha_hasher.final(&obj_sha1);
            }
        } else if (obj.pack_type == 6) {
            if (obj.base_offset == 0) continue;

            const resolved = try resolveCachedFromInfo(allocator, pack_data, objects[0..object_count], &offset_map, obj.base_offset, &resolve_cache);

            const delta_data = try zlibInflate(allocator, pack_data[obj.compressed_start .. obj.compressed_start + obj.compressed_len], obj.size);
            defer allocator.free(delta_data.data);

            const result_data = try applyDelta(allocator, resolved.data, delta_data.data);

            var hdr_buf: [64]u8 = undefined;
            const header = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ resolved.type_str, result_data.len }) catch unreachable;
            var sha_hasher = std.crypto.hash.Sha1.init(.{});
            sha_hasher.update(header);
            sha_hasher.update(result_data);
            sha_hasher.final(&obj_sha1);

            if (delta_base_set.contains(obj.offset)) {
                try resolve_cache.put(obj.offset, .{ .type_str = resolved.type_str, .data = result_data });
            } else {
                allocator.free(result_data);
            }
        } else if (obj.pack_type == 7) {
            // REF_DELTA - find base by SHA-1
            var found_offset: ?usize = null;
            for (entries.items) |entry| {
                if (std.mem.eql(u8, &entry.sha1, &obj.base_sha1)) {
                    found_offset = @intCast(entry.offset);
                    break;
                }
            }
            const bo = found_offset orelse continue;

            const resolved = try resolveCachedFromInfo(allocator, pack_data, objects[0..object_count], &offset_map, bo, &resolve_cache);

            const delta_data = try zlibInflate(allocator, pack_data[obj.compressed_start .. obj.compressed_start + obj.compressed_len], obj.size);
            defer allocator.free(delta_data.data);

            const result_data = try applyDelta(allocator, resolved.data, delta_data.data);

            var hdr_buf: [64]u8 = undefined;
            const header = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ resolved.type_str, result_data.len }) catch unreachable;
            var sha_hasher = std.crypto.hash.Sha1.init(.{});
            sha_hasher.update(header);
            sha_hasher.update(result_data);
            sha_hasher.final(&obj_sha1);

            if (delta_base_set.contains(obj.offset)) {
                try resolve_cache.put(obj.offset, .{ .type_str = resolved.type_str, .data = result_data });
            } else {
                allocator.free(result_data);
            }
        } else continue;

        try entries.append(.{ .sha1 = obj_sha1, .offset = @intCast(obj.offset), .crc32 = crc });
    }

    // Sort by SHA-1
    std.sort.block(IndexEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: IndexEntry, b: IndexEntry) bool {
            return std.mem.order(u8, &a.sha1, &b.sha1) == .lt;
        }
    }.lessThan);

    // Build v2 idx
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

/// Resolve object using cached info from pass 1
fn resolveCachedFromInfo(
    allocator: std.mem.Allocator,
    pack_data: []const u8,
    objects: []const ObjectInfo,
    offset_map: *std.AutoHashMap(usize, u32),
    offset: usize,
    cache: *std.AutoHashMap(usize, CachedObject),
) !CachedObject {
    if (cache.get(offset)) |cached| return cached;

    // Look up object info by offset
    const idx = offset_map.get(offset) orelse return error.InvalidOffset;
    const obj = objects[idx];

    const compressed = pack_data[obj.compressed_start .. obj.compressed_start + obj.compressed_len];

    if (obj.pack_type >= 1 and obj.pack_type <= 4) {
        const result = try zlibInflate(allocator, compressed, obj.size);
        const ts = typeStr(obj.pack_type);
        try cache.put(offset, .{ .type_str = ts, .data = result.data });
        return .{ .type_str = ts, .data = result.data };
    } else if (obj.pack_type == 6) {
        if (obj.base_offset == 0) return error.InvalidDeltaOffset;
        const base = try resolveCachedFromInfo(allocator, pack_data, objects, offset_map, obj.base_offset, cache);

        const delta_result = try zlibInflate(allocator, compressed, obj.size);
        defer allocator.free(delta_result.data);

        const applied = try applyDelta(allocator, base.data, delta_result.data);
        try cache.put(offset, .{ .type_str = base.type_str, .data = applied });
        return .{ .type_str = base.type_str, .data = applied };
    }

    return error.UnsupportedPackType;
}

/// Apply a git delta to a base object
fn applyDelta(allocator: std.mem.Allocator, base: []const u8, delta: []const u8) ![]u8 {
    var dpos: usize = 0;
    _ = readDeltaVarint(delta, &dpos);
    const result_size = readDeltaVarint(delta, &dpos);

    var result = try std.ArrayList(u8).initCapacity(allocator, result_size);
    errdefer result.deinit();

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
            try result.appendSlice(base[copy_offset .. copy_offset + copy_size]);
        } else if (cmd > 0) {
            const n: usize = @intCast(cmd);
            if (dpos + n > delta.len) return error.DeltaInsertOutOfBounds;
            try result.appendSlice(delta[dpos .. dpos + n]);
            dpos += n;
        } else {
            return error.DeltaReservedCommand;
        }
    }

    return try result.toOwnedSlice();
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
