const std = @import("std");
pub fn decompress(rdr: anytype, wtr: anytype) !void {
    std.compress.zlib.decompress(rdr, wtr) catch return error.InvalidInput;
}
pub fn compress(rdr: anytype, wtr: anytype, options: anytype) !void {
    _ = options;
    std.compress.zlib.compress(rdr, wtr, .{}) catch return error.CompressionFailed;
}
pub fn Decompressor(comptime ReaderType: type) type {
    return std.compress.zlib.Decompressor(ReaderType);
}
pub fn decompressor(rdr: anytype) Decompressor(@TypeOf(rdr)) {
    return std.compress.zlib.decompressor(rdr);
}
pub fn Compressor(comptime WriterType: type) type {
    return std.compress.zlib.Compressor(WriterType);
}
pub fn compressorWriter(wtr: anytype, options: anytype) !Compressor(@TypeOf(wtr)) {
    _ = options;
    return std.compress.zlib.compressor(wtr, .{});
}
const c = @cImport({ @cInclude("zlib.h"); });
pub fn compressSlice(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const bound = c.compressBound(@intCast(input.len));
    const output = try allocator.alloc(u8, @intCast(bound));
    errdefer allocator.free(output);
    var dest_len: c.uLongf = @intCast(output.len);
    const ret = c.compress2(output.ptr, &dest_len, input.ptr, @intCast(input.len), 6);
    if (ret != c.Z_OK) return error.CompressionFailed;
    const result = try allocator.dupe(u8, output[0..@intCast(dest_len)]);
    allocator.free(output);
    return result;
}
pub fn decompressSlice(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    var fbs = std.io.fixedBufferStream(input);
    std.compress.zlib.decompress(fbs.reader(), output.writer()) catch return error.InvalidInput;
    return output.toOwnedSlice();
}
pub fn decompressSliceWithConsumed(allocator: std.mem.Allocator, input: []const u8) !struct { data: []u8, consumed: usize } {
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    stream.next_in = @constCast(input.ptr);
    stream.avail_in = @intCast(input.len);
    var ret = c.inflateInit(&stream);
    if (ret != c.Z_OK) return error.InvalidInput;
    defer _ = c.inflateEnd(&stream);
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    var buf: [16384]u8 = undefined;
    while (true) {
        stream.next_out = &buf;
        stream.avail_out = buf.len;
        ret = c.inflate(&stream, c.Z_NO_FLUSH);
        const have = buf.len - @as(usize, @intCast(stream.avail_out));
        if (have > 0) try output.appendSlice(buf[0..have]);
        if (ret == c.Z_STREAM_END) break;
        if (ret != c.Z_OK) return error.InvalidInput;
    }
    const consumed = @as(usize, @intCast(stream.total_in));
    return .{ .data = try output.toOwnedSlice(), .consumed = consumed };
}
