const std = @import("std");
const stream_utils = @import("stream_utils.zig");
const DeltaCache = @import("delta_cache.zig").DeltaCache;

/// Object entry collected during pack index generation.
const IndexEntry = struct {
    sha1: [20]u8,
    offset: u64,
    crc32: u32,
};

/// Per-object metadata for resolveBase fallback.
const ObjRecord = struct {
    offset: usize,
    comp_start: usize,
    comp_len: usize,
    pack_type: u3,
    size: usize,
    base_offset: usize,
};

/// Deferred REF_DELTA awaiting base resolution.
const DeferredDelta = struct {
    obj_start: usize,
    record_idx: u32,
    crc32: u32,
    base_sha1: [20]u8,
    instr_start: u32,
    instr_len: u32,
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
/// Single-pass architecture:
///   - Base objects: decompressHashAndCapture → SHA-1 + data cached in LRU
///   - OFS_DELTA: resolved immediately from cached base (always earlier in pack)
///   - REF_DELTA: resolved immediately if base known, otherwise deferred
///   - Deferred REF_DELTAs resolved in multi-pass convergence loop
pub fn generateIdxFromData(allocator: std.mem.Allocator, pack_data: []const u8) ![]u8 {
    if (pack_data.len < 32) return error.PackFileTooSmall;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPackSignature;

    const object_count = std.mem.readInt(u32, pack_data[8..12], .big);
    const content_end = pack_data.len - 20;
    const pack_checksum = pack_data[content_end..][0..20];

    var entries = try std.ArrayList(IndexEntry).initCapacity(allocator, object_count);
    defer entries.deinit();

    // SHA-1 → pack offset for REF_DELTA base lookup.
    var sha_to_offset = std.AutoHashMap([20]u8, usize).init(allocator);
    defer sha_to_offset.deinit();
    try sha_to_offset.ensureTotalCapacity(object_count);

    // Bounded LRU cache — single source of decompressed object data.
    var cache = DeltaCache.init(allocator, 128 * 1024 * 1024);
    defer cache.deinit();

    // Per-object metadata for resolveBase fallback (cache miss path).
    var records = try allocator.alloc(ObjRecord, object_count);
    defer allocator.free(records);
    var offset_to_rec = std.AutoHashMap(usize, u32).init(allocator);
    defer offset_to_rec.deinit();
    try offset_to_rec.ensureTotalCapacity(object_count);

    // Deferred REF_DELTAs and their instruction pool.
    var deferred = std.ArrayList(DeferredDelta).init(allocator);
    defer deferred.deinit();
    var delta_pool = std.ArrayList(u8).init(allocator);
    defer delta_pool.deinit();

    // Reusable decompression buffer (shared across all objects).
    var decomp_buf = std.ArrayList(u8).init(allocator);
    defer decomp_buf.deinit();

    // ═══════════════════════════════════════════════════════════════════
    // Single pass — process objects in pack order
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
            // ── Base object: decompress+hash+capture, cache for delta use ──
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
            offset_to_rec.putAssumeCapacity(obj_start, obj_idx);

            const crc32 = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj_start..pos]);
            try entries.append(.{ .sha1 = result.sha1, .offset = @intCast(obj_start), .crc32 = crc32 });
            sha_to_offset.putAssumeCapacity(result.sha1, obj_start);

            // Cache decompressed data — putDupe because decomp_buf is reused.
            try cache.putDupe(obj_start, type_str, decomp_buf.items);
        } else if (pt == 6) {
            // ── OFS_DELTA: resolve immediately using cached base ──
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
            offset_to_rec.putAssumeCapacity(obj_start, obj_idx);

            const crc32 = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj_start..pos]);

            // Resolve: base is always at an earlier offset, should be cached.
            const base = cache.get(base_offset) orelse blk: {
                break :blk resolveBase(
                    allocator,
                    pack_data,
                    content_end,
                    base_offset,
                    &cache,
                    records[0 .. obj_idx + 1],
                    &offset_to_rec,
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

            try entries.append(.{ .sha1 = sha1, .offset = @intCast(obj_start), .crc32 = crc32 });
            sha_to_offset.putAssumeCapacity(sha1, obj_start);
            try cache.put(obj_start, base.type_str, result_data);
        } else if (pt == 7) {
            // ── REF_DELTA: resolve now if base known, otherwise defer ──
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
            offset_to_rec.putAssumeCapacity(obj_start, obj_idx);

            const crc32 = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj_start..pos]);

            // Try to resolve immediately.
            const maybe_base_offset = sha_to_offset.get(base_sha1);
            const resolved = if (maybe_base_offset) |bo| blk: {
                const base = cache.get(bo) orelse resolveBase(
                    allocator,
                    pack_data,
                    content_end,
                    bo,
                    &cache,
                    records[0 .. obj_idx + 1],
                    &offset_to_rec,
                ) catch break :blk false;

                const result_data = applyDelta(allocator, base.data, decomp_buf.items) catch break :blk false;
                const sha1 = stream_utils.hashGitObject(base.type_str, result_data);

                entries.append(.{ .sha1 = sha1, .offset = @intCast(obj_start), .crc32 = crc32 }) catch {
                    allocator.free(result_data);
                    break :blk false;
                };
                sha_to_offset.putAssumeCapacity(sha1, obj_start);
                cache.put(obj_start, base.type_str, result_data) catch {};
                break :blk true;
            } else false;

            if (!resolved) {
                // Defer: stash instructions in pool.
                const pool_start: u32 = @intCast(delta_pool.items.len);
                try delta_pool.appendSlice(decomp_buf.items);
                try deferred.append(.{
                    .obj_start = obj_start,
                    .record_idx = obj_idx,
                    .crc32 = crc32,
                    .base_sha1 = base_sha1,
                    .instr_start = pool_start,
                    .instr_len = @intCast(decomp_buf.items.len),
                });
            }
        } else {
            records[obj_idx] = std.mem.zeroes(ObjRecord);
            obj_idx += 1;
            pos += 1;
            continue;
        }

        obj_idx += 1;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Resolve deferred REF_DELTAs (multi-pass convergence)
    // ═══════════════════════════════════════════════════════════════════
    var unresolved_count: usize = deferred.items.len;
    var max_iters: usize = 50;
    while (unresolved_count > 0 and max_iters > 0) : (max_iters -= 1) {
        var new_unresolved: usize = 0;
        for (deferred.items) |*d| {
            if (d.instr_len == std.math.maxInt(u32)) continue; // already resolved

            const base_offset = sha_to_offset.get(d.base_sha1) orelse {
                new_unresolved += 1;
                continue;
            };

            const instr = delta_pool.items[d.instr_start..][0..d.instr_len];

            const base = cache.get(base_offset) orelse blk: {
                break :blk resolveBase(
                    allocator,
                    pack_data,
                    content_end,
                    base_offset,
                    &cache,
                    records[0..obj_idx],
                    &offset_to_rec,
                ) catch {
                    new_unresolved += 1;
                    continue;
                };
            };

            const result_data = applyDelta(allocator, base.data, instr) catch {
                new_unresolved += 1;
                continue;
            };
            const sha1 = stream_utils.hashGitObject(base.type_str, result_data);

            entries.append(.{ .sha1 = sha1, .offset = @intCast(d.obj_start), .crc32 = d.crc32 }) catch {
                allocator.free(result_data);
                new_unresolved += 1;
                continue;
            };
            cache.put(d.obj_start, base.type_str, result_data) catch {};
            sha_to_offset.put(sha1, d.obj_start) catch {};
            d.instr_len = std.math.maxInt(u32); // mark resolved
        }
        if (new_unresolved == unresolved_count) break; // no progress
        unresolved_count = new_unresolved;
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

    const writer = idx.writer();

    // Magic + version
    try writer.writeInt(u32, 0xff744f63, .big);
    try writer.writeInt(u32, 2, .big);

    // Fanout table
    var fanout: [256]u32 = [_]u32{0} ** 256;
    for (entries.items) |entry| fanout[entry.sha1[0]] += 1;
    var cumulative: u32 = 0;
    for (0..256) |i| {
        cumulative += fanout[i];
        try writer.writeInt(u32, cumulative, .big);
    }

    // SHA-1 table
    for (entries.items) |entry| try idx.appendSlice(&entry.sha1);

    // CRC-32 table
    for (entries.items) |entry| try writer.writeInt(u32, entry.crc32, .big);

    // Offset table (+ large offset overflow)
    var large_offsets = std.ArrayList(u64).init(allocator);
    defer large_offsets.deinit();
    for (entries.items) |entry| {
        if (entry.offset >= 0x80000000) {
            try writer.writeInt(u32, @as(u32, @intCast(large_offsets.items.len)) | 0x80000000, .big);
            try large_offsets.append(entry.offset);
        } else {
            try writer.writeInt(u32, @intCast(entry.offset), .big);
        }
    }
    for (large_offsets.items) |offset| try writer.writeInt(u64, offset, .big);

    // Checksums
    try idx.appendSlice(pack_checksum);
    var idx_hasher = std.crypto.hash.Sha1.init(.{});
    idx_hasher.update(idx.items);
    var idx_checksum: [20]u8 = undefined;
    idx_hasher.final(&idx_checksum);
    try idx.appendSlice(&idx_checksum);

    return try idx.toOwnedSlice();
}

/// Resolve a base object on demand (cache miss fallback).
/// Decompresses from pack data and populates cache.
fn resolveBase(
    allocator: std.mem.Allocator,
    pack_data: []const u8,
    content_end: usize,
    offset: usize,
    cache: *DeltaCache,
    records: []const ObjRecord,
    offset_to_rec: *std.AutoHashMap(usize, u32),
) !DeltaCache.Entry {
    if (cache.get(offset)) |e| return e;

    const ri = offset_to_rec.get(offset) orelse return error.InvalidOffset;
    const rec = records[ri];
    const compressed = pack_data[rec.comp_start .. rec.comp_start + rec.comp_len];

    if (rec.pack_type >= 1 and rec.pack_type <= 4) {
        const type_str = stream_utils.packTypeToString(rec.pack_type) orelse return error.UnsupportedPackType;
        var output = try std.ArrayList(u8).initCapacity(allocator, if (rec.size > 0) rec.size else 256);
        errdefer output.deinit();
        _ = try stream_utils.decompressInto(compressed, &output);
        const data = try output.toOwnedSlice();
        try cache.put(offset, type_str, data);
        return cache.get(offset).?;
    } else if (rec.pack_type == 6) {
        if (rec.base_offset == 0) return error.InvalidDeltaOffset;
        const base = try resolveBase(allocator, pack_data, content_end, rec.base_offset, cache, records, offset_to_rec);

        var delta_list = try std.ArrayList(u8).initCapacity(allocator, if (rec.size > 0) rec.size else 256);
        defer delta_list.deinit();
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
