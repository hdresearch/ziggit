const zlib_compat = @import("zlib_compat.zig");
const std = @import("std");
const stream_utils = @import("stream_utils.zig");
const DeltaCache = @import("delta_cache.zig").DeltaCache;

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

/// Generate idx data from in-memory pack data. Returns owned slice.
///
/// NOTE: Only resolves delta bases within the same pack file. For thin packs
/// (where REF_DELTA bases live in other packs/loose objects), unresolvable
/// deltas are silently skipped. Callers handling thin packs from fetch should
/// fix the pack (prepend missing bases) BEFORE generating the idx.
///
/// Single-pass architecture with deferred REF_DELTA resolution:
///   - Base objects: decompress+hash+cache in a single streaming pass
///   - OFS_DELTA: resolved immediately (base always earlier in pack)
///   - REF_DELTA: resolved if base known, otherwise deferred
///   - Deferred REF_DELTAs resolved in multi-pass convergence loop
pub fn generateIdxFromData(allocator: std.mem.Allocator, pack_data: []const u8) ![]u8 {
    const trace_timing = std.posix.getenv("ZIGGIT_TRACE_TIMING") != null;
    var phase_timer = std.time.Timer.start() catch null;

    if (pack_data.len < 32) return error.PackFileTooSmall;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPackSignature;

    const object_count = std.mem.readInt(u32, pack_data[8..12], .big);
    const content_end = pack_data.len - 20;
    const pack_checksum = pack_data[content_end..][0..20];

    // Per-object metadata, indexed by object number in pack order.
    var records = try allocator.alloc(ObjRecord, object_count);
    defer allocator.free(records);

    // SHA-1 → pack offset for REF_DELTA base lookup.
    var sha_to_offset = std.AutoHashMap([20]u8, usize).init(allocator);
    defer sha_to_offset.deinit();
    try sha_to_offset.ensureTotalCapacity(object_count);

    // Pack offset → record index for resolveBase.
    var offset_to_idx = std.AutoHashMap(usize, u32).init(allocator);
    defer offset_to_idx.deinit();
    try offset_to_idx.ensureTotalCapacity(object_count);

    // ═══════════════════════════════════════════════════════════════════
    // Pass 1: Scan pack, hash base objects, record metadata.
    // Uses libdeflate for one-shot decompression (2-4x faster than zlib
    // streaming) with zlib fallback for edge cases.
    // ═══════════════════════════════════════════════════════════════════
    const ld = @cImport({
        @cInclude("libdeflate.h");
    });
    const zc = @cImport({
        @cInclude("zlib.h");
    });

    const decompressor = ld.libdeflate_alloc_decompressor();
    defer if (decompressor) |d| ld.libdeflate_free_decompressor(d);

    // Reusable decompression buffer for base objects.
    // Starts at 64KB and grows as needed. Avoids per-object allocation.
    var decomp_buf_cap: usize = 65536;
    var decomp_buf_ptr = try allocator.alloc(u8, decomp_buf_cap);
    defer allocator.free(decomp_buf_ptr);

    // Fallback zlib stream for cases where libdeflate fails
    var zstream: zc.z_stream = std.mem.zeroes(zc.z_stream);
    if (zc.inflateInit(&zstream) != zc.Z_OK) return error.ZlibInitFailed;
    defer _ = zc.inflateEnd(&zstream);
    var chunk_buf: [65536]u8 = undefined;

    var pos: usize = 12;
    var obj_idx: u32 = 0;
    var pass1_unresolved: usize = 0; // Track unresolved count during scan
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
            // Base object: one-shot decompress + hash using libdeflate.
            const type_str = stream_utils.packTypeToString(pt) orelse "blob";
            const comp_start = pos;
            const in_avail = content_end - comp_start;

            // Ensure decomp buffer is large enough
            if (hdr.size > decomp_buf_cap) {
                allocator.free(decomp_buf_ptr);
                decomp_buf_cap = hdr.size;
                decomp_buf_ptr = try allocator.alloc(u8, decomp_buf_cap);
            }

            var actual_in: usize = 0;
            var actual_out: usize = 0;
            var decomp_ok = false;

            if (decompressor) |d| {
                const ret = ld.libdeflate_zlib_decompress_ex(
                    d,
                    @ptrCast(pack_data[comp_start..].ptr),
                    in_avail,
                    @ptrCast(decomp_buf_ptr.ptr),
                    hdr.size,
                    &actual_in,
                    &actual_out,
                );
                if (ret == ld.LIBDEFLATE_SUCCESS and actual_out == hdr.size) {
                    decomp_ok = true;
                }
            }

            if (decomp_ok) {
                pos = comp_start + actual_in;

                // Hash decompressed data
                var sha_hasher = std.crypto.hash.Sha1.init(.{});
                var hdr_buf2: [64]u8 = undefined;
                const header = std.fmt.bufPrint(&hdr_buf2, "{s} {}\x00", .{ type_str, hdr.size }) catch unreachable;
                sha_hasher.update(header);
                sha_hasher.update(decomp_buf_ptr[0..actual_out]);
                var result_sha1: [20]u8 = undefined;
                sha_hasher.final(&result_sha1);

                records[obj_idx] = .{
                    .offset = obj_start,
                    .comp_start = comp_start,
                    .comp_len = actual_in,
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
            } else {
                // Fallback to zlib streaming for this object
                if (zc.inflateReset(&zstream) != zc.Z_OK) {
                    records[obj_idx] = emptyRecord(obj_start);
                    obj_idx += 1;
                    pos += 1;
                    continue;
                }

                var sha_hasher = std.crypto.hash.Sha1.init(.{});
                var hdr_buf2: [64]u8 = undefined;
                const header = std.fmt.bufPrint(&hdr_buf2, "{s} {}\x00", .{ type_str, hdr.size }) catch unreachable;
                sha_hasher.update(header);

                zstream.next_in = @constCast(pack_data[comp_start..content_end].ptr);
                zstream.avail_in = @intCast(@min(in_avail, std.math.maxInt(c_uint)));

                var zlib_ok = true;
                while (true) {
                    zstream.next_out = &chunk_buf;
                    zstream.avail_out = chunk_buf.len;
                    const ret = zc.inflate(&zstream, zc.Z_NO_FLUSH);
                    const produced = chunk_buf.len - zstream.avail_out;
                    if (produced > 0) sha_hasher.update(chunk_buf[0..produced]);
                    if (ret == zc.Z_STREAM_END) break;
                    if (ret != zc.Z_OK) { zlib_ok = false; break; }
                }

                if (!zlib_ok) {
                    records[obj_idx] = emptyRecord(obj_start);
                    obj_idx += 1;
                    pos += 1;
                    continue;
                }

                const bytes_consumed: usize = @intCast(zstream.total_in);
                pos = comp_start + bytes_consumed;

                var result_sha1: [20]u8 = undefined;
                sha_hasher.final(&result_sha1);

                records[obj_idx] = .{
                    .offset = obj_start,
                    .comp_start = comp_start,
                    .comp_len = bytes_consumed,
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
            }
        } else if (pt == 6) {
            // OFS_DELTA: parse offset, decompress to find compressed length.
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
            const in_avail = content_end - comp_start;

            // Try libdeflate first for delta skip
            var actual_in: usize = 0;
            var skip_ok = false;

            if (decompressor) |d| {
                // Ensure decomp buffer is large enough
                if (hdr.size > decomp_buf_cap) {
                    allocator.free(decomp_buf_ptr);
                    decomp_buf_cap = hdr.size;
                    decomp_buf_ptr = try allocator.alloc(u8, decomp_buf_cap);
                }
                var actual_out: usize = 0;
                const ret = ld.libdeflate_zlib_decompress_ex(
                    d,
                    @ptrCast(pack_data[comp_start..].ptr),
                    in_avail,
                    @ptrCast(decomp_buf_ptr.ptr),
                    hdr.size,
                    &actual_in,
                    &actual_out,
                );
                if (ret == ld.LIBDEFLATE_SUCCESS) {
                    skip_ok = true;
                }
            }

            if (skip_ok) {
                pos = comp_start + actual_in;
            } else {
                // Fallback to zlib
                if (zc.inflateReset(&zstream) != zc.Z_OK) {
                    records[obj_idx] = emptyRecord(obj_start);
                    obj_idx += 1;
                    pos += 1;
                    continue;
                }
                zstream.next_in = @constCast(pack_data[comp_start..content_end].ptr);
                zstream.avail_in = @intCast(@min(in_avail, std.math.maxInt(c_uint)));
                var zlib_ok = true;
                while (true) {
                    zstream.next_out = &chunk_buf;
                    zstream.avail_out = chunk_buf.len;
                    const ret = zc.inflate(&zstream, zc.Z_NO_FLUSH);
                    if (ret == zc.Z_STREAM_END) break;
                    if (ret != zc.Z_OK) { zlib_ok = false; break; }
                }
                if (!zlib_ok) {
                    records[obj_idx] = emptyRecord(obj_start);
                    obj_idx += 1;
                    pos += 1;
                    continue;
                }
                actual_in = @intCast(zstream.total_in);
                pos = comp_start + actual_in;
            }

            records[obj_idx] = .{
                .offset = obj_start,
                .comp_start = comp_start,
                .comp_len = actual_in,
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
            // REF_DELTA: read base SHA-1, decompress to find compressed length.
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
            const in_avail = content_end - comp_start;

            // Try libdeflate first
            var actual_in: usize = 0;
            var skip_ok = false;

            if (decompressor) |d| {
                if (hdr.size > decomp_buf_cap) {
                    allocator.free(decomp_buf_ptr);
                    decomp_buf_cap = hdr.size;
                    decomp_buf_ptr = try allocator.alloc(u8, decomp_buf_cap);
                }
                var actual_out: usize = 0;
                const ret = ld.libdeflate_zlib_decompress_ex(
                    d,
                    @ptrCast(pack_data[comp_start..].ptr),
                    in_avail,
                    @ptrCast(decomp_buf_ptr.ptr),
                    hdr.size,
                    &actual_in,
                    &actual_out,
                );
                if (ret == ld.LIBDEFLATE_SUCCESS) {
                    skip_ok = true;
                }
            }

            if (skip_ok) {
                pos = comp_start + actual_in;
            } else {
                // Fallback to zlib
                if (zc.inflateReset(&zstream) != zc.Z_OK) {
                    records[obj_idx] = emptyRecord(obj_start);
                    obj_idx += 1;
                    pos += 1;
                    continue;
                }
                zstream.next_in = @constCast(pack_data[comp_start..content_end].ptr);
                zstream.avail_in = @intCast(@min(in_avail, std.math.maxInt(c_uint)));
                var zlib_ok = true;
                while (true) {
                    zstream.next_out = &chunk_buf;
                    zstream.avail_out = chunk_buf.len;
                    const ret = zc.inflate(&zstream, zc.Z_NO_FLUSH);
                    if (ret == zc.Z_STREAM_END) break;
                    if (ret != zc.Z_OK) { zlib_ok = false; break; }
                }
                if (!zlib_ok) {
                    records[obj_idx] = emptyRecord(obj_start);
                    obj_idx += 1;
                    pos += 1;
                    continue;
                }
                actual_in = @intCast(zstream.total_in);
                pos = comp_start + actual_in;
            }

            records[obj_idx] = .{
                .offset = obj_start,
                .comp_start = comp_start,
                .comp_len = actual_in,
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
    // OFS_DELTAs are processed in pack order (base always at smaller offset).
    // REF_DELTAs use multi-pass convergence.
    // Skip entirely if there are no unresolved objects (common for shallow packs).

    var unresolved_count: usize = pass1_unresolved;

    if (unresolved_count > 0) {
        var cache = DeltaCache.init(allocator, 128 * 1024 * 1024);
        defer cache.deinit();

        // Reusable buffer for delta instruction decompression.
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

/// Resolve an OFS_DELTA record. The base is at a known pack offset.
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

/// Resolve a delta record given the absolute base offset.
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
    // Get base data (from cache or by decompressing/resolving).
    const base = try getBaseData(allocator, pack_data, content_end, base_offset, records, offset_to_idx, cache, decomp_buf);

    // Decompress delta instructions.
    decomp_buf.clearRetainingCapacity();
    if (rec.size > 0) try decomp_buf.ensureTotalCapacity(rec.size);
    _ = try stream_utils.decompressInto(
        pack_data[rec.comp_start .. rec.comp_start + rec.comp_len],
        decomp_buf,
    );

    // Apply delta → result.
    const result_data = try applyDelta(allocator, base.data, decomp_buf.items);

    // Hash the result.
    const sha1 = stream_utils.hashGitObject(base.type_str, result_data);

    // Update record.
    rec.sha1 = sha1;
    rec.resolved = true;

    // Register in maps and cache.
    sha_to_offset.put(sha1, rec.offset) catch {};
    try cache.put(rec.offset, base.type_str, result_data);
}

/// Get base object data, resolving recursively if needed.
/// Returns borrowed reference from cache (valid until next cache mutation).
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
    // Fast path: already in cache.
    if (cache.get(offset)) |e| return e;

    const ri = offset_to_idx.get(offset) orelse return error.InvalidOffset;
    const rec = &records[ri];

    if (rec.obj_type >= 1 and rec.obj_type <= 4) {
        // Base object: decompress and cache.
        const type_str = stream_utils.packTypeToString(rec.obj_type) orelse return error.UnsupportedPackType;
        const data = try allocator.alloc(u8, rec.size);
        errdefer allocator.free(data);
        const info = try stream_utils.decompressIntoBuf(
            pack_data[rec.comp_start .. rec.comp_start + rec.comp_len],
            data,
        );
        // If size mismatch, realloc (shouldn't happen normally).
        if (info.decompressed_size != data.len) {
            const trimmed = try allocator.realloc(data, info.decompressed_size);
            try cache.put(offset, type_str, trimmed);
        } else {
            try cache.put(offset, type_str, data);
        }
        return cache.get(offset).?;
    } else if (rec.obj_type == 6) {
        // OFS_DELTA: need to resolve recursively.
        if (rec.base_offset == 0) return error.InvalidDeltaOffset;

        const base = try getBaseData(allocator, pack_data, content_end, rec.base_offset, records, offset_to_idx, cache, decomp_buf);

        // Decompress delta instructions into a temporary buffer.
        // We can't use decomp_buf because the caller might be using it.
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
        // REF_DELTA: should have been resolved already; if not, we can't resolve here
        // without knowing the base offset.
        return error.UnresolvedRefDelta;
    }

    return error.UnsupportedPackType;
}

// ─── Utility functions ─────────────────────────────────────────────────

/// Skip a zlib stream, returning the number of compressed bytes consumed.
/// Uses C zlib for fast decompression. No heap allocation.
fn skipZlib(compressed: []const u8) !usize {
    const c = @cImport({
        @cInclude("zlib.h");
    });

    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    stream.next_in = @constCast(compressed.ptr);
    stream.avail_in = @intCast(@min(compressed.len, std.math.maxInt(c_uint)));

    if (c.inflateInit(&stream) != c.Z_OK) return error.ZlibInitFailed;
    defer _ = c.inflateEnd(&stream);
    var buf: [16384]u8 = undefined;
    while (true) {
        stream.next_out = &buf;
        stream.avail_out = buf.len;
        const ret = c.inflate(&stream, c.Z_NO_FLUSH);
        if (ret == c.Z_STREAM_END) break;
        if (ret != c.Z_OK) return error.ZlibDecompressError;
    }
    return @intCast(stream.total_in);
}

/// Count unresolved records.
fn countUnresolved(records: []const ObjRecord) usize {
    var count: usize = 0;
    for (records) |rec| {
        if (!rec.resolved) count += 1;
    }
    return count;
}

/// Create a zeroed record for error/skip cases.
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

/// Build a v2 .idx file from sorted entries.
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
