const std = @import("std");
const stream_utils = @import("stream_utils.zig");
const DeltaCache = @import("delta_cache.zig").DeltaCache;

/// Object entry collected during pack index generation.
const IndexEntry = struct {
    sha1: [20]u8,
    offset: u64,
    crc32: u32,
};

/// Per-object metadata recorded during pack scan (pass 1).
const ObjRecord = struct {
    offset: usize, // absolute offset in pack
    comp_start: usize, // start of compressed data
    comp_len: usize, // bytes of compressed data consumed
    pack_type: u3,
    size: usize, // uncompressed size from header
    base_offset: usize, // for OFS_DELTA: absolute base offset; for REF_DELTA: 0
};

/// Delta to be resolved in pass 2.
const PendingDelta = struct {
    record_idx: u32, // index into records[]
    obj_start: usize,
    crc32: u32,
    base_offset: usize, // absolute offset of base (0 if REF_DELTA not yet mapped)
    base_sha1: [20]u8, // for REF_DELTA only
    is_ref: bool,
    instr_start: u32, // offset into delta_pool
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
/// Two-pass architecture:
///   Pass 1 — Scan all objects. Base objects are hashed via streaming
///            decompressAndHash (zero allocation for data). Delta objects
///            have their instructions decompressed into a shared pool.
///   Pass 2 — Resolve deltas in pack order. Base data is decompressed
///            on demand into a bounded LRU DeltaCache only when actually
///            referenced by a delta.
pub fn generateIdxFromData(allocator: std.mem.Allocator, pack_data: []const u8) ![]u8 {
    if (pack_data.len < 32) return error.PackFileTooSmall;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPackSignature;

    const object_count = std.mem.readInt(u32, pack_data[8..12], .big);
    const content_end = pack_data.len - 20;
    const pack_checksum = pack_data[content_end..][0..20];

    var entries = try std.ArrayList(IndexEntry).initCapacity(allocator, object_count);
    defer entries.deinit();

    // Per-object records (indexed by sequential object number).
    var records = try allocator.alloc(ObjRecord, object_count);
    defer allocator.free(records);

    // SHA-1 → pack offset for REF_DELTA base lookup.
    var sha_to_offset = std.AutoHashMap([20]u8, usize).init(allocator);
    defer sha_to_offset.deinit();
    try sha_to_offset.ensureTotalCapacity(object_count);

    // offset → record index for on-demand base resolution.
    var offset_to_rec = std.AutoHashMap(usize, u32).init(allocator);
    defer offset_to_rec.deinit();
    try offset_to_rec.ensureTotalCapacity(object_count);

    // Pending deltas to resolve in pass 2.
    var deltas = std.ArrayList(PendingDelta).init(allocator);
    defer deltas.deinit();

    // Contiguous pool for all delta instructions (avoids per-delta allocations).
    var delta_pool = std.ArrayList(u8).init(allocator);
    defer delta_pool.deinit();

    // Reusable buffer for delta instruction decompression.
    var decomp_buf = std.ArrayList(u8).init(allocator);
    defer decomp_buf.deinit();

    // ═══════════════════════════════════════════════════════════════════
    // Pass 1 — Scan all objects, hash bases, collect delta info
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
            // ── Base object: streaming hash, no data materialisation ──
            const type_str = stream_utils.packTypeToString(pt) orelse "blob";
            const comp_start = pos;

            const result = stream_utils.decompressAndHash(
                pack_data[comp_start..content_end],
                type_str,
                hdr.size,
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

            try entries.append(.{
                .sha1 = result.sha1,
                .offset = @intCast(obj_start),
                .crc32 = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj_start..pos]),
            });
            sha_to_offset.putAssumeCapacity(result.sha1, obj_start);
        } else if (pt == 6) {
            // ── OFS_DELTA: record base offset, stash instructions ──
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

            const pool_start: u32 = @intCast(delta_pool.items.len);
            try delta_pool.appendSlice(decomp_buf.items);

            try deltas.append(.{
                .record_idx = obj_idx,
                .obj_start = obj_start,
                .crc32 = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj_start..pos]),
                .base_offset = base_offset,
                .base_sha1 = undefined,
                .is_ref = false,
                .instr_start = pool_start,
                .instr_len = @intCast(decomp_buf.items.len),
            });
        } else if (pt == 7) {
            // ── REF_DELTA: record base SHA-1, stash instructions ──
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

            const pool_start: u32 = @intCast(delta_pool.items.len);
            try delta_pool.appendSlice(decomp_buf.items);

            try deltas.append(.{
                .record_idx = obj_idx,
                .obj_start = obj_start,
                .crc32 = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj_start..pos]),
                .base_offset = 0,
                .base_sha1 = base_sha1,
                .is_ref = true,
                .instr_start = pool_start,
                .instr_len = @intCast(decomp_buf.items.len),
            });
        } else {
            records[obj_idx] = std.mem.zeroes(ObjRecord);
            obj_idx += 1;
            pos += 1;
            continue;
        }

        obj_idx += 1;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Pass 2 — Resolve deltas (in pack order = dependency order for OFS)
    // ═══════════════════════════════════════════════════════════════════
    var cache = DeltaCache.init(allocator, 128 * 1024 * 1024);
    defer cache.deinit();

    // Track unresolved REF_DELTAs for multi-pass convergence.
    var unresolved_count: usize = 0;

    for (deltas.items) |*d| {
        var base_offset = d.base_offset;
        if (d.is_ref) {
            base_offset = sha_to_offset.get(d.base_sha1) orelse {
                unresolved_count += 1;
                continue;
            };
            d.base_offset = base_offset;
        }

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
                unresolved_count += 1;
                continue;
            };
        };

        const result_data = applyDelta(allocator, base.data, instr) catch {
            unresolved_count += 1;
            continue;
        };
        const sha1 = stream_utils.hashGitObject(base.type_str, result_data);

        try entries.append(.{ .sha1 = sha1, .offset = @intCast(d.obj_start), .crc32 = d.crc32 });
        try cache.put(d.obj_start, base.type_str, result_data);
        sha_to_offset.putAssumeCapacity(sha1, d.obj_start);
        d.base_offset = std.math.maxInt(usize); // mark resolved
    }

    // ── Multi-pass for deferred REF_DELTAs whose base wasn't available ──
    var max_iters: usize = 50;
    while (unresolved_count > 0 and max_iters > 0) : (max_iters -= 1) {
        var new_unresolved: usize = 0;
        for (deltas.items) |*d| {
            if (d.base_offset == std.math.maxInt(usize)) continue; // already resolved

            var base_offset = d.base_offset;
            if (d.is_ref and base_offset == 0) {
                base_offset = sha_to_offset.get(d.base_sha1) orelse {
                    new_unresolved += 1;
                    continue;
                };
                d.base_offset = base_offset;
            }

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
            d.base_offset = std.math.maxInt(usize); // mark resolved
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

/// Resolve a base object on demand: decompress from pack, cache the result.
/// Handles delta chains recursively (rare — only when cache has evicted a
/// needed intermediate result).
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
        // Base object: decompress + capture (need data for delta application).
        const type_str = stream_utils.packTypeToString(rec.pack_type) orelse return error.UnsupportedPackType;
        var output = try std.ArrayList(u8).initCapacity(allocator, if (rec.size > 0) rec.size else 256);
        errdefer output.deinit();
        _ = try stream_utils.decompressInto(compressed, &output);
        const data = try output.toOwnedSlice();
        try cache.put(offset, type_str, data);
        return cache.get(offset).?;
    } else if (rec.pack_type == 6) {
        // OFS_DELTA chain: recursively resolve base first.
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
            // Copy from base
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
            // Insert from delta
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
