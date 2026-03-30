const zlib_compat = @import("zlib_compat.zig");
const std = @import("std");
const stream_utils = @import("stream_utils.zig");
const DeltaCache = @import("delta_cache.zig").DeltaCache;

const DecompResult = struct { decompressed_size: usize, consumed: usize };

/// Object entry for idx file generation.
const IndexEntry = struct {
    sha1: [20]u8,
    offset: u64,
    crc32: u32,
};

/// Per-object metadata collected in pass 1 (scan).
const ObjRecord = struct {
    offset: usize, // object start in pack (header start)
    comp_start: usize, // compressed data start
    comp_len: usize, // compressed data length (bytes consumed by zlib)
    obj_type: u3, // pack type (1-4 = base, 6 = ofs_delta, 7 = ref_delta)
    size: usize, // uncompressed size from header
    base_offset: usize, // for OFS_DELTA: absolute base offset; 0 otherwise
    base_sha1: [20]u8, // for REF_DELTA: base SHA-1
    sha1: [20]u8, // SHA-1 of resolved object
    crc32: u32, // CRC32 of pack entry (header + compressed data)
    resolved: bool, // true when SHA-1 is known
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

/// Decompress zlib data from a slice, returning decompressed data and number of
/// compressed bytes consumed.
fn decompressWithConsumed(input: []const u8, out_buf: []u8) !DecompResult {
    const result = zlib_compat.decompressSliceWithConsumed(std.heap.page_allocator, input) catch return error.ZlibDecompressError;
    defer std.heap.page_allocator.free(result.data);
    const n = @min(result.data.len, out_buf.len);
    @memcpy(out_buf[0..n], result.data[0..n]);
    return .{ .decompressed_size = n, .consumed = result.consumed };
}

/// Decompress zlib data, returning only the number of compressed bytes consumed (skip the output).
fn skipZlibPure(compressed: []const u8) !usize {
    const result = zlib_compat.decompressSliceWithConsumed(std.heap.page_allocator, compressed) catch return error.ZlibDecompressError;
    std.heap.page_allocator.free(result.data);
    return result.consumed;
}

/// Decompress zlib data into an ArrayList, returning consumed bytes.
fn decompressToList(input: []const u8, output: *std.array_list.Managed(u8)) !usize {
    const result = zlib_compat.decompressSliceWithConsumed(std.heap.page_allocator, input) catch return error.ZlibDecompressError;
    defer std.heap.page_allocator.free(result.data);
    try output.appendSlice(result.data);
    return result.consumed;
}

/// Generate idx data from in-memory pack data. Returns owned slice.
pub fn generateIdxFromData(allocator: std.mem.Allocator, pack_data: []const u8) ![]u8 {
    const trace_timing = std.posix.getenv("ZIGGIT_TRACE_TIMING") != null;
    var phase_timer = std.time.Timer.start() catch null;

    if (pack_data.len < 32) return error.PackFileTooSmall;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPackSignature;

    const object_count = std.mem.readInt(u32, pack_data[8..12], .big);
    const content_end = pack_data.len - 20;
    const pack_checksum = pack_data[content_end..][0..20];

    var records = try allocator.alloc(ObjRecord, object_count);
    defer allocator.free(records);

    var sha_to_offset = std.AutoHashMap([20]u8, usize).init(allocator);
    defer sha_to_offset.deinit();
    try sha_to_offset.ensureTotalCapacity(object_count);

    var offset_to_idx = std.AutoHashMap(usize, u32).init(allocator);
    defer offset_to_idx.deinit();
    try offset_to_idx.ensureTotalCapacity(object_count);

    // Reusable decompression buffer for base objects.
    var decomp_buf_cap: usize = 262144;
    var decomp_buf_ptr = try allocator.alloc(u8, decomp_buf_cap);
    defer allocator.free(decomp_buf_ptr);

    var pos: usize = 12;
    var obj_idx: u32 = 0;
    var pass1_unresolved: usize = 0;
    while (obj_idx < object_count and pos < content_end) {
        const obj_start = pos;

        const hdr = stream_utils.parsePackObjectHeader(pack_data, pos) catch {
            records[obj_idx] = emptyRecord(obj_start);
            obj_idx += 1;
            pos += 1;
            continue;
        };
        pos += hdr.header_len;
        const pt = hdr.type_num;

        if (pt >= 1 and pt <= 4) {
            // Base object: decompress + hash
            const type_str = stream_utils.packTypeToString(pt) orelse "blob";
            const comp_start = pos;

            // Ensure decomp buffer is large enough
            const needed_cap = if (hdr.size > 0) hdr.size else 256;
            if (needed_cap > decomp_buf_cap) {
                allocator.free(decomp_buf_ptr);
                decomp_buf_cap = needed_cap;
                decomp_buf_ptr = try allocator.alloc(u8, decomp_buf_cap);
            }

            const info = decompressWithConsumed(
                pack_data[comp_start..content_end],
                decomp_buf_ptr[0..decomp_buf_cap],
            ) catch {
                records[obj_idx] = emptyRecord(obj_start);
                obj_idx += 1;
                pos += 1;
                continue;
            };

            pos = comp_start + info.consumed;

            // Hash decompressed data
            var sha_hasher = std.crypto.hash.Sha1.init(.{});
            var hdr_buf2: [64]u8 = undefined;
            const header = std.fmt.bufPrint(&hdr_buf2, "{s} {}\x00", .{ type_str, hdr.size }) catch unreachable;
            sha_hasher.update(header);
            sha_hasher.update(decomp_buf_ptr[0..info.decompressed_size]);
            var result_sha1: [20]u8 = undefined;
            sha_hasher.final(&result_sha1);

            records[obj_idx] = .{
                .offset = obj_start,
                .comp_start = comp_start,
                .comp_len = info.consumed,
                .obj_type = pt,
                .size = hdr.size,
                .base_offset = 0,
                .base_sha1 = std.mem.zeroes([20]u8),
                .sha1 = result_sha1,
                .crc32 = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj_start..pos]),
                .resolved = true,
            };
            offset_to_idx.putAssumeCapacity(obj_start, obj_idx);
            sha_to_offset.putAssumeCapacity(result_sha1, obj_start);
        } else if (pt == 6) {
            // OFS_DELTA
            const ofs = stream_utils.parseOfsOffset(pack_data, pos) catch {
                records[obj_idx] = emptyRecord(obj_start);
                obj_idx += 1;
                pos += 1;
                continue;
            };
            pos += ofs.bytes_consumed;

            if (ofs.negative_offset > obj_start) {
                records[obj_idx] = emptyRecord(obj_start);
                obj_idx += 1;
                pos += 1;
                continue;
            }
            const base_offset = obj_start - ofs.negative_offset;
            const comp_start = pos;

            const consumed = skipZlibPure(pack_data[comp_start..content_end]) catch {
                records[obj_idx] = emptyRecord(obj_start);
                obj_idx += 1;
                pos += 1;
                continue;
            };

            pos = comp_start + consumed;

            records[obj_idx] = .{
                .offset = obj_start,
                .comp_start = comp_start,
                .comp_len = consumed,
                .obj_type = pt,
                .size = hdr.size,
                .base_offset = base_offset,
                .base_sha1 = std.mem.zeroes([20]u8),
                .sha1 = std.mem.zeroes([20]u8),
                .crc32 = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj_start..pos]),
                .resolved = false,
            };
            offset_to_idx.putAssumeCapacity(obj_start, obj_idx);
            pass1_unresolved += 1;
        } else if (pt == 7) {
            // REF_DELTA
            if (pos + 20 > content_end) {
                records[obj_idx] = emptyRecord(obj_start);
                obj_idx += 1;
                pos += 1;
                continue;
            }
            var base_sha1: [20]u8 = undefined;
            @memcpy(&base_sha1, pack_data[pos .. pos + 20]);
            pos += 20;

            const comp_start = pos;

            const consumed = skipZlibPure(pack_data[comp_start..content_end]) catch {
                records[obj_idx] = emptyRecord(obj_start);
                obj_idx += 1;
                pos += 1;
                continue;
            };

            pos = comp_start + consumed;

            records[obj_idx] = .{
                .offset = obj_start,
                .comp_start = comp_start,
                .comp_len = consumed,
                .obj_type = pt,
                .size = hdr.size,
                .base_offset = 0,
                .base_sha1 = base_sha1,
                .sha1 = std.mem.zeroes([20]u8),
                .crc32 = std.hash.crc.Crc32IsoHdlc.hash(pack_data[obj_start..pos]),
                .resolved = false,
            };
            offset_to_idx.putAssumeCapacity(obj_start, obj_idx);
            pass1_unresolved += 1;
        } else {
            records[obj_idx] = emptyRecord(obj_start);
            obj_idx += 1;
            pos += 1;
            continue;
        }

        obj_idx += 1;
    }
    const total_objects = obj_idx;

    if (trace_timing) {
        if (phase_timer) |*t| {
            std.debug.print("[timing]   idx pass1 (scan+hash): {}ms, objects={}\n", .{ t.read() / std.time.ns_per_ms, total_objects });
            t.reset();
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Pass 2: Resolve deltas using bounded LRU cache
    // ═══════════════════════════════════════════════════════════════════
    var unresolved_count: usize = pass1_unresolved;

    if (unresolved_count > 0) {
        var cache = DeltaCache.init(allocator, 128 * 1024 * 1024);
        defer cache.deinit();

        var decomp_buf = std.array_list.Managed(u8).init(allocator);
        defer decomp_buf.deinit();

        // --- Resolve OFS_DELTAs in pack order ---
        var i: u32 = 0;
        while (i < total_objects) : (i += 1) {
            const rec = &records[i];
            if (rec.resolved or rec.obj_type != 6) continue;

            resolveOfsDelta(
                allocator,
                pack_data,
                content_end,
                rec,
                records[0..total_objects],
                &offset_to_idx,
                &cache,
                &decomp_buf,
                &sha_to_offset,
            ) catch continue;
        }

        // --- Resolve REF_DELTAs with multi-pass convergence ---
        unresolved_count = countUnresolved(records[0..total_objects]);
        var max_iters: usize = 50;
        while (unresolved_count > 0 and max_iters > 0) : (max_iters -= 1) {
            var new_unresolved: usize = 0;
            for (records[0..total_objects]) |*rec| {
                if (rec.resolved or rec.obj_type != 7) continue;

                const base_offset = sha_to_offset.get(rec.base_sha1) orelse {
                    new_unresolved += 1;
                    continue;
                };

                resolveDelta(
                    allocator,
                    pack_data,
                    content_end,
                    rec,
                    base_offset,
                    records[0..total_objects],
                    &offset_to_idx,
                    &cache,
                    &decomp_buf,
                    &sha_to_offset,
                ) catch {
                    new_unresolved += 1;
                    continue;
                };
            }
            if (new_unresolved == unresolved_count) break;
            unresolved_count = new_unresolved;
        }
    }

    if (trace_timing) {
        if (phase_timer) |*t| {
            std.debug.print("[timing]   idx pass2 (resolve deltas): {}ms, unresolved_remaining={}\n", .{ t.read() / std.time.ns_per_ms, countUnresolved(records[0..total_objects]) });
            t.reset();
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Build sorted entries from resolved records
    // ═══════════════════════════════════════════════════════════════════
    var entries = try std.array_list.Managed(IndexEntry).initCapacity(allocator, total_objects);
    defer entries.deinit();

    for (records[0..total_objects]) |rec| {
        if (!rec.resolved) continue;
        entries.appendAssumeCapacity(.{
            .sha1 = rec.sha1,
            .offset = @intCast(rec.offset),
            .crc32 = rec.crc32,
        });
    }

    std.sort.block(IndexEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: IndexEntry, b: IndexEntry) bool {
            return std.mem.order(u8, &a.sha1, &b.sha1) == .lt;
        }
    }.lessThan);

    if (trace_timing) {
        if (phase_timer) |*t| {
            std.debug.print("[timing]   idx sort entries: {}ms, count={}\n", .{ t.read() / std.time.ns_per_ms, entries.items.len });
            t.reset();
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Build v2 .idx file
    // ═══════════════════════════════════════════════════════════════════
    if (trace_timing) {
        if (phase_timer) |*t| {
            std.debug.print("[timing]   idx build file: {}ms\n", .{t.read() / std.time.ns_per_ms});
            t.reset();
        }
    }

    return buildIdxFile(allocator, entries.items, pack_checksum);
}

// ─── Delta resolution helpers ──────────────────────────────────────────

fn resolveOfsDelta(
    allocator: std.mem.Allocator,
    pack_data: []const u8,
    content_end: usize,
    rec: *ObjRecord,
    records: []ObjRecord,
    offset_to_idx: *std.AutoHashMap(usize, u32),
    cache: *DeltaCache,
    decomp_buf: *std.array_list.Managed(u8),
    sha_to_offset: *std.AutoHashMap([20]u8, usize),
) !void {
    return resolveDelta(allocator, pack_data, content_end, rec, rec.base_offset, records, offset_to_idx, cache, decomp_buf, sha_to_offset);
}

fn resolveDelta(
    allocator: std.mem.Allocator,
    pack_data: []const u8,
    content_end: usize,
    rec: *ObjRecord,
    base_offset: usize,
    records: []ObjRecord,
    offset_to_idx: *std.AutoHashMap(usize, u32),
    cache: *DeltaCache,
    decomp_buf: *std.array_list.Managed(u8),
    sha_to_offset: *std.AutoHashMap([20]u8, usize),
) !void {
    const base = try getBaseData(allocator, pack_data, content_end, base_offset, records, offset_to_idx, cache, decomp_buf);

    decomp_buf.clearRetainingCapacity();
    if (rec.size > 0) try decomp_buf.ensureTotalCapacity(rec.size);
    _ = try stream_utils.decompressInto(
        pack_data[rec.comp_start .. rec.comp_start + rec.comp_len],
        decomp_buf,
    );

    const result_data = try applyDelta(allocator, base.data, decomp_buf.items);
    const sha1 = stream_utils.hashGitObject(base.type_str, result_data);

    rec.sha1 = sha1;
    rec.resolved = true;

    sha_to_offset.put(sha1, rec.offset) catch {};
    try cache.put(rec.offset, base.type_str, result_data);
}

fn getBaseData(
    allocator: std.mem.Allocator,
    pack_data: []const u8,
    content_end: usize,
    offset: usize,
    records: []ObjRecord,
    offset_to_idx: *std.AutoHashMap(usize, u32),
    cache: *DeltaCache,
    decomp_buf: *std.array_list.Managed(u8),
) !DeltaCache.Entry {
    if (cache.get(offset)) |e| return e;

    const ri = offset_to_idx.get(offset) orelse return error.InvalidOffset;
    const rec = &records[ri];

    if (rec.obj_type >= 1 and rec.obj_type <= 4) {
        const type_str = stream_utils.packTypeToString(rec.obj_type) orelse return error.UnsupportedPackType;
        const data = try allocator.alloc(u8, rec.size);
        errdefer allocator.free(data);
        const info = try stream_utils.decompressIntoBuf(
            pack_data[rec.comp_start .. rec.comp_start + rec.comp_len],
            data,
        );
        if (info.decompressed_size != data.len) {
            const trimmed = try allocator.realloc(data, info.decompressed_size);
            try cache.put(offset, type_str, trimmed);
        } else {
            try cache.put(offset, type_str, data);
        }
        return cache.get(offset).?;
    } else if (rec.obj_type == 6) {
        if (rec.base_offset == 0) return error.InvalidDeltaOffset;

        const base = try getBaseData(allocator, pack_data, content_end, rec.base_offset, records, offset_to_idx, cache, decomp_buf);

        var tmp = try std.array_list.Managed(u8).initCapacity(allocator, if (rec.size > 0) rec.size else 256);
        defer tmp.deinit();
        _ = try stream_utils.decompressInto(
            pack_data[rec.comp_start .. rec.comp_start + rec.comp_len],
            &tmp,
        );

        const result = try applyDelta(allocator, base.data, tmp.items);
        const sha1 = stream_utils.hashGitObject(base.type_str, result);

        rec.sha1 = sha1;
        rec.resolved = true;

        try cache.put(offset, base.type_str, result);
        return cache.get(offset).?;
    } else if (rec.obj_type == 7) {
        return error.UnresolvedRefDelta;
    }

    return error.UnsupportedPackType;
}

// ─── Utility functions ─────────────────────────────────────────────────

fn countUnresolved(records: []const ObjRecord) usize {
    var count: usize = 0;
    for (records) |rec| {
        if (!rec.resolved) count += 1;
    }
    return count;
}

fn emptyRecord(offset: usize) ObjRecord {
    return .{
        .offset = offset,
        .comp_start = 0,
        .comp_len = 0,
        .obj_type = 0,
        .size = 0,
        .base_offset = 0,
        .base_sha1 = std.mem.zeroes([20]u8),
        .sha1 = std.mem.zeroes([20]u8),
        .crc32 = 0,
        .resolved = false,
    };
}

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

fn readDeltaVarint(data: []const u8, pos_ptr: *usize) usize {
    var value: usize = 0;
    var shift: u6 = 0;
    while (pos_ptr.* < data.len) {
        const b = data[pos_ptr.*];
        pos_ptr.* += 1;
        value |= @as(usize, b & 0x7F) << shift;
        if (b & 0x80 == 0) break;
        if (shift < 60) shift += 7 else break;
    }
    return value;
}

fn buildIdxFile(allocator: std.mem.Allocator, entries: []const IndexEntry, pack_checksum: *const [20]u8) ![]u8 {
    var idx = std.array_list.Managed(u8).init(allocator);
    defer idx.deinit();
    try idx.ensureTotalCapacity(8 + 256 * 4 + entries.len * (20 + 4 + 4) + 40);

    const writer = idx.writer();

    // Magic + version
    try writer.writeInt(u32, 0xff744f63, .big);
    try writer.writeInt(u32, 2, .big);

    // Fanout table
    var fanout: [256]u32 = [_]u32{0} ** 256;
    for (entries) |entry| fanout[entry.sha1[0]] += 1;
    var cumulative: u32 = 0;
    for (0..256) |fi| {
        cumulative += fanout[fi];
        try writer.writeInt(u32, cumulative, .big);
    }

    // SHA-1 table
    for (entries) |entry| try idx.appendSlice(&entry.sha1);

    // CRC-32 table
    for (entries) |entry| try writer.writeInt(u32, entry.crc32, .big);

    // Offset table (+ large offset overflow)
    var large_offsets = std.array_list.Managed(u64).init(allocator);
    defer large_offsets.deinit();
    for (entries) |entry| {
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
