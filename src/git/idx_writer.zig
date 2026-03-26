const std = @import("std");

/// Object entry collected during pack index generation
const IndexEntry = struct {
    sha1: [20]u8,
    offset: u64,
    crc32: u32,
};

/// Pack object type numbers (from git pack format)
const PackType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,
};

/// Generate a .idx file next to the given .pack file.
/// Reads the pack, walks all objects, resolves deltas, computes SHA-1s,
/// and writes a v2 .idx file.
pub fn generateIdx(allocator: std.mem.Allocator, pack_path: []const u8) !void {
    // Read pack file
    const pack_data = try std.fs.cwd().readFileAlloc(allocator, pack_path, 512 * 1024 * 1024);
    defer allocator.free(pack_data);

    const idx_data = try generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    // Derive .idx path from .pack path
    if (!std.mem.endsWith(u8, pack_path, ".pack")) return error.InvalidPackPath;
    const base = pack_path[0 .. pack_path.len - 5]; // strip ".pack"
    const idx_path = try std.fmt.allocPrint(allocator, "{s}.idx", .{base});
    defer allocator.free(idx_path);

    const file = try std.fs.cwd().createFile(idx_path, .{});
    defer file.close();
    try file.writeAll(idx_data);
}

/// Generate idx data from in-memory pack data. Returns owned slice.
pub fn generateIdxFromData(allocator: std.mem.Allocator, pack_data: []const u8) ![]u8 {
    if (pack_data.len < 32) return error.PackFileTooSmall;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPackSignature;

    const object_count = std.mem.readInt(u32, pack_data[8..12], .big);
    const content_end = pack_data.len - 20;
    const pack_checksum = pack_data[content_end..][0..20];

    var entries = std.ArrayList(IndexEntry).init(allocator);
    defer entries.deinit();

    var pos: usize = 12; // After 12-byte header
    var obj_idx: u32 = 0;

    while (obj_idx < object_count and pos < content_end) {
        const obj_start = pos;

        // Parse object type+size varint header
        const first_byte = pack_data[pos];
        pos += 1;
        const pack_type_num: u3 = @intCast((first_byte >> 4) & 7);
        var size: usize = @intCast(first_byte & 0x0F);
        var shift: u6 = 4;
        var current_byte = first_byte;

        while (current_byte & 0x80 != 0 and pos < content_end) {
            current_byte = pack_data[pos];
            pos += 1;
            size |= @as(usize, @intCast(current_byte & 0x7F)) << shift;
            if (shift < 60) shift += 7 else break;
        }

        // Handle delta-specific headers
        var base_offset: ?usize = null;
        var base_sha1: ?[20]u8 = null;

        if (pack_type_num == 6) {
            // OFS_DELTA: read negative offset varint
            var delta_off: usize = 0;
            var first_delta_byte = true;
            while (pos < content_end) {
                const b = pack_data[pos];
                pos += 1;
                if (first_delta_byte) {
                    delta_off = @intCast(b & 0x7F);
                    first_delta_byte = false;
                } else {
                    delta_off = (delta_off + 1) << 7;
                    delta_off += @intCast(b & 0x7F);
                }
                if (b & 0x80 == 0) break;
            }
            if (delta_off <= obj_start) {
                base_offset = obj_start - delta_off;
            }
        } else if (pack_type_num == 7) {
            // REF_DELTA: read 20-byte base hash
            if (pos + 20 <= content_end) {
                var sha1: [20]u8 = undefined;
                @memcpy(&sha1, pack_data[pos .. pos + 20]);
                base_sha1 = sha1;
                pos += 20;
            }
        }

        // Decompress zlib data
        const compressed_start = pos;
        var decompressed = std.ArrayList(u8).init(allocator);
        defer decompressed.deinit();

        var stream = std.io.fixedBufferStream(pack_data[pos..content_end]);
        std.compress.zlib.decompress(stream.reader(), decompressed.writer()) catch {
            obj_idx += 1;
            continue;
        };
        pos = compressed_start + @as(usize, @intCast(stream.pos));

        // CRC32 of raw pack bytes for this object (header + compressed data)
        const crc = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj_start..pos]);

        // Compute SHA-1 of the resolved git object
        var obj_sha1: [20]u8 = undefined;

        if (pack_type_num >= 1 and pack_type_num <= 4) {
            // Base object types
            const type_str: []const u8 = switch (pack_type_num) {
                1 => "commit",
                2 => "tree",
                3 => "blob",
                4 => "tag",
                else => unreachable,
            };
            const header = try std.fmt.allocPrint(allocator, "{s} {}\x00", .{ type_str, decompressed.items.len });
            defer allocator.free(header);

            var sha_hasher = std.crypto.hash.Sha1.init(.{});
            sha_hasher.update(header);
            sha_hasher.update(decompressed.items);
            sha_hasher.final(&obj_sha1);
        } else if (pack_type_num == 6) {
            // OFS_DELTA
            if (base_offset) |bo| {
                const resolved = resolveObject(allocator, pack_data, bo, content_end) catch {
                    obj_idx += 1;
                    continue;
                };
                defer allocator.free(resolved.data);

                const result_data = applyDelta(allocator, resolved.data, decompressed.items) catch {
                    obj_idx += 1;
                    continue;
                };
                defer allocator.free(result_data);

                const header = try std.fmt.allocPrint(allocator, "{s} {}\x00", .{ resolved.type_str, result_data.len });
                defer allocator.free(header);
                var sha_hasher = std.crypto.hash.Sha1.init(.{});
                sha_hasher.update(header);
                sha_hasher.update(result_data);
                sha_hasher.final(&obj_sha1);
            } else {
                obj_idx += 1;
                continue;
            }
        } else if (pack_type_num == 7) {
            // REF_DELTA
            if (base_sha1) |target_sha| {
                // Find base object by SHA-1 in already-indexed entries
                var found_offset: ?usize = null;
                for (entries.items) |entry| {
                    if (std.mem.eql(u8, &entry.sha1, &target_sha)) {
                        found_offset = @intCast(entry.offset);
                        break;
                    }
                }
                if (found_offset) |bo| {
                    const resolved = resolveObject(allocator, pack_data, bo, content_end) catch {
                        obj_idx += 1;
                        continue;
                    };
                    defer allocator.free(resolved.data);

                    const result_data = applyDelta(allocator, resolved.data, decompressed.items) catch {
                        obj_idx += 1;
                        continue;
                    };
                    defer allocator.free(result_data);

                    const header = try std.fmt.allocPrint(allocator, "{s} {}\x00", .{ resolved.type_str, result_data.len });
                    defer allocator.free(header);
                    var sha_hasher = std.crypto.hash.Sha1.init(.{});
                    sha_hasher.update(header);
                    sha_hasher.update(result_data);
                    sha_hasher.final(&obj_sha1);
                } else {
                    obj_idx += 1;
                    continue;
                }
            } else {
                obj_idx += 1;
                continue;
            }
        } else {
            obj_idx += 1;
            continue;
        }

        try entries.append(.{
            .sha1 = obj_sha1,
            .offset = @intCast(obj_start),
            .crc32 = crc,
        });

        obj_idx += 1;
    }

    // Sort entries by SHA-1
    std.sort.block(IndexEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: IndexEntry, b: IndexEntry) bool {
            return std.mem.order(u8, &a.sha1, &b.sha1) == .lt;
        }
    }.lessThan);

    // Build v2 idx file
    var idx = std.ArrayList(u8).init(allocator);
    defer idx.deinit();

    // Magic + version
    try idx.writer().writeInt(u32, 0xff744f63, .big);
    try idx.writer().writeInt(u32, 2, .big);

    // Fanout table (256 entries)
    for (0..256) |i| {
        var count: u32 = 0;
        for (entries.items) |entry| {
            if (entry.sha1[0] <= @as(u8, @intCast(i))) count += 1;
        }
        try idx.writer().writeInt(u32, count, .big);
    }

    // SHA-1 table
    for (entries.items) |entry| {
        try idx.appendSlice(&entry.sha1);
    }

    // CRC32 table
    for (entries.items) |entry| {
        try idx.writer().writeInt(u32, entry.crc32, .big);
    }

    // Offset table
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

    // 64-bit offset table
    for (large_offsets.items) |offset| {
        try idx.writer().writeInt(u64, offset, .big);
    }

    // Pack checksum
    try idx.appendSlice(pack_checksum);

    // Idx checksum
    var idx_hasher = std.crypto.hash.Sha1.init(.{});
    idx_hasher.update(idx.items);
    var idx_checksum: [20]u8 = undefined;
    idx_hasher.final(&idx_checksum);
    try idx.appendSlice(&idx_checksum);

    return try idx.toOwnedSlice();
}

/// Resolved object: type string + decompressed data
const ResolvedObject = struct {
    type_str: []const u8, // static string, no free needed
    data: []u8, // owned, caller must free
};

/// Recursively resolve an object at the given offset in pack data.
/// Handles base types and OFS_DELTA chains.
fn resolveObject(allocator: std.mem.Allocator, pack_data: []const u8, offset: usize, content_end: usize) !ResolvedObject {
    if (offset >= content_end) return error.InvalidOffset;

    var pos = offset;
    const first_byte = pack_data[pos];
    pos += 1;
    const pack_type_num: u3 = @intCast((first_byte >> 4) & 7);
    var size: usize = @intCast(first_byte & 0x0F);
    var shift: u6 = 4;
    var current_byte = first_byte;

    while (current_byte & 0x80 != 0 and pos < content_end) {
        current_byte = pack_data[pos];
        pos += 1;
        size |= @as(usize, @intCast(current_byte & 0x7F)) << shift;
        if (shift < 60) shift += 7 else break;
    }

    if (pack_type_num >= 1 and pack_type_num <= 4) {
        // Base type
        var decompressed = std.ArrayList(u8).init(allocator);
        defer decompressed.deinit();
        var stream = std.io.fixedBufferStream(pack_data[pos..content_end]);
        try std.compress.zlib.decompress(stream.reader(), decompressed.writer());

        const type_str: []const u8 = switch (pack_type_num) {
            1 => "commit",
            2 => "tree",
            3 => "blob",
            4 => "tag",
            else => unreachable,
        };

        return .{
            .type_str = type_str,
            .data = try decompressed.toOwnedSlice(),
        };
    } else if (pack_type_num == 6) {
        // OFS_DELTA
        var delta_off: usize = 0;
        var first_delta_byte = true;
        while (pos < content_end) {
            const b = pack_data[pos];
            pos += 1;
            if (first_delta_byte) {
                delta_off = @intCast(b & 0x7F);
                first_delta_byte = false;
            } else {
                delta_off = (delta_off + 1) << 7;
                delta_off += @intCast(b & 0x7F);
            }
            if (b & 0x80 == 0) break;
        }

        const base_offset = if (delta_off <= offset) offset - delta_off else return error.InvalidDeltaOffset;
        const base = try resolveObject(allocator, pack_data, base_offset, content_end);
        defer allocator.free(base.data);

        var decompressed = std.ArrayList(u8).init(allocator);
        defer decompressed.deinit();
        var stream = std.io.fixedBufferStream(pack_data[pos..content_end]);
        try std.compress.zlib.decompress(stream.reader(), decompressed.writer());

        const result = try applyDelta(allocator, base.data, decompressed.items);
        return .{
            .type_str = base.type_str,
            .data = result,
        };
    }

    return error.UnsupportedPackType;
}

/// Apply a git delta to a base object, producing the result object.
fn applyDelta(allocator: std.mem.Allocator, base: []const u8, delta: []const u8) ![]u8 {
    var dpos: usize = 0;

    // Read base size varint
    const base_size = readDeltaVarint(delta, &dpos);
    _ = base_size; // We trust the actual base data length

    // Read result size varint
    const result_size = readDeltaVarint(delta, &dpos);

    var result = try std.ArrayList(u8).initCapacity(allocator, result_size);
    errdefer result.deinit();

    while (dpos < delta.len) {
        const cmd = delta[dpos];
        dpos += 1;

        if (cmd & 0x80 != 0) {
            // COPY from base
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
            try result.appendSlice(base[copy_offset .. copy_offset + copy_size]);
        } else if (cmd > 0) {
            // INSERT literal bytes
            const n: usize = @intCast(cmd);
            if (dpos + n > delta.len) return error.DeltaInsertOutOfBounds;
            try result.appendSlice(delta[dpos .. dpos + n]);
            dpos += n;
        } else {
            // cmd == 0 is reserved
            return error.DeltaReservedCommand;
        }
    }

    return try result.toOwnedSlice();
}

/// Read a variable-length integer from delta data (7 bits per byte, MSB = more)
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
