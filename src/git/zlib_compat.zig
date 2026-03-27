const std = @import("std");
const c = @cImport({ @cInclude("zlib.h"); });
pub fn decompress(reader: anytype, writer: anytype) !void {
    var buf = std.array_list.Managed(u8).init(std.heap.page_allocator); defer buf.deinit();
    while (true) { var b: [4096]u8 = undefined; const n = reader.read(&b) catch break; if (n == 0) break; try buf.appendSlice(b[0..n]); }
    var strm: c.z_stream = std.mem.zeroes(c.z_stream); strm.next_in = buf.items.ptr; strm.avail_in = @intCast(buf.items.len);
    if (c.inflateInit(&strm) != c.Z_OK) return error.InvalidInput; defer _ = c.inflateEnd(&strm);
    var ob: [8192]u8 = undefined;
    while (true) { strm.next_out = &ob; strm.avail_out = ob.len; const ret = c.inflate(&strm, c.Z_NO_FLUSH); const have = ob.len - strm.avail_out;
        if (have > 0) writer.writeAll(ob[0..have]) catch return error.InvalidInput; if (ret == c.Z_STREAM_END) break; if (ret != c.Z_OK) return error.InvalidInput; }
}
pub fn compress2(dest: [*]u8, dest_len: *c_ulong, source: [*]const u8, source_len: c_ulong, level: c_int) c_int { return c.compress2(dest, dest_len, source, source_len, level); }
pub fn compressSlice(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const bound = c.compressBound(@intCast(data.len)); var dest = try allocator.alloc(u8, @intCast(bound)); var dl: c_ulong = @intCast(dest.len);
    if (c.compress2(dest.ptr, &dl, data.ptr, @intCast(data.len), c.Z_DEFAULT_COMPRESSION) != c.Z_OK) { allocator.free(dest); return error.CompressionFailed; }
    if (@as(usize, @intCast(dl)) < dest.len) dest = allocator.realloc(dest, @intCast(dl)) catch dest; return dest[0..@intCast(dl)];
}
pub fn decompressSlice(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var strm: c.z_stream = std.mem.zeroes(c.z_stream); strm.next_in = @constCast(data.ptr); strm.avail_in = @intCast(data.len);
    if (c.inflateInit(&strm) != c.Z_OK) return error.InvalidInput; defer _ = c.inflateEnd(&strm);
    var r = std.array_list.Managed(u8).init(allocator); errdefer r.deinit(); var ob: [8192]u8 = undefined;
    while (true) { strm.next_out = &ob; strm.avail_out = ob.len; const ret = c.inflate(&strm, c.Z_NO_FLUSH); const have = ob.len - strm.avail_out;
        if (have > 0) try r.appendSlice(ob[0..have]); if (ret == c.Z_STREAM_END) break; if (ret != c.Z_OK) return error.InvalidInput; }
    return r.toOwnedSlice();
}
pub fn decompressSliceWithConsumed(allocator: std.mem.Allocator, data: []const u8) !struct { data: []u8, consumed: usize } {
    var strm: c.z_stream = std.mem.zeroes(c.z_stream); strm.next_in = @constCast(data.ptr); strm.avail_in = @intCast(data.len);
    if (c.inflateInit(&strm) != c.Z_OK) return error.InvalidInput; defer _ = c.inflateEnd(&strm);
    var r = std.array_list.Managed(u8).init(allocator); errdefer r.deinit(); var ob: [8192]u8 = undefined;
    while (true) { strm.next_out = &ob; strm.avail_out = ob.len; const ret = c.inflate(&strm, c.Z_NO_FLUSH); const have = ob.len - strm.avail_out;
        if (have > 0) try r.appendSlice(ob[0..have]); if (ret == c.Z_STREAM_END) break; if (ret != c.Z_OK) return error.InvalidInput; }
    return .{ .data = try r.toOwnedSlice(), .consumed = data.len - strm.avail_in };
}
