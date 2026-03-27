//! Compatibility shim for zlib operations using Zig 0.13 APIs + C zlib.

const std = @import("std");
const zlib = std.compress.zlib;

/// Decompress zlib data from a reader into a writer.
pub fn decompress(reader: anytype, writer: anytype) !void {
    zlib.decompress(reader, writer) catch return error.InvalidInput;
}

/// Compress data from a reader into a writer.
pub fn compress(reader: anytype, writer: anytype, options: anytype) !void {
    _ = options;
    // Read all input
    var all_input = std.ArrayList(u8).init(std.heap.page_allocator);
    defer all_input.deinit();
    {
        var buf: [16384]u8 = undefined;
        while (true) {
            const n = reader.read(&buf) catch break;
            if (n == 0) break;
            try all_input.appendSlice(buf[0..n]);
        }
    }
    // Use C zlib for compression
    const compressed = try compressSlice(std.heap.page_allocator, all_input.items);
    defer std.heap.page_allocator.free(compressed);
    writer.writeAll(compressed) catch return error.CompressionFailed;
}

/// Streaming decompressor wrapper.
pub fn Decompressor(comptime ReaderType: type) type {
    return zlib.Decompressor(ReaderType);
}

pub fn decompressor(reader: anytype) zlib.Decompressor(@TypeOf(reader)) {
    return zlib.decompressor(reader);
}

/// Streaming compressor wrapper - wraps buffered data and compresses on finish.
pub fn Compressor(comptime WriterType: type) type {
    return struct {
        const Self = @This();
        inner_writer: WriterType,
        buffer: std.ArrayList(u8),

        pub fn write(self: *Self, data: []const u8) !usize {
            self.buffer.appendSlice(data) catch return error.CompressionFailed;
            return data.len;
        }

        pub fn finish(self: *Self) !void {
            const compressed = compressSlice(self.buffer.allocator, self.buffer.items) catch return error.CompressionFailed;
            defer self.buffer.allocator.free(compressed);
            self.inner_writer.writeAll(compressed) catch return error.CompressionFailed;
        }

        pub fn writer(self: *Self) GenWriter {
            return .{ .context = self };
        }

        pub const GenWriter = std.io.GenericWriter(*Self, error{CompressionFailed}, writeAdapter);

        fn writeAdapter(self: *Self, data: []const u8) error{CompressionFailed}!usize {
            return self.write(data) catch return error.CompressionFailed;
        }
    };
}

pub fn compressorWriter(writer: anytype, options: anytype) !Compressor(@TypeOf(writer)) {
    _ = options;
    return .{ .inner_writer = writer, .buffer = std.ArrayList(u8).init(std.heap.page_allocator) };
}

/// Compress a slice of data using C zlib.
const c = @cImport({
    @cInclude("zlib.h");
});

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

/// Decompress a slice of zlib data.
pub fn decompressSlice(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    var fbs = std.io.fixedBufferStream(input);
    var dec = zlib.decompressor(fbs.reader());
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = dec.read(&buf) catch return error.InvalidInput;
        if (n == 0) break;
        try output.appendSlice(buf[0..n]);
    }

    return output.toOwnedSlice();
}

/// Decompress zlib data from a slice, returning decompressed content and
/// the number of compressed bytes consumed from input.
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
        if (have > 0) {
            try output.appendSlice(buf[0..have]);
        }
        if (ret == c.Z_STREAM_END) break;
        if (ret != c.Z_OK) return error.InvalidInput;
    }

    const consumed = @as(usize, @intCast(stream.total_in));
    return .{ .data = try output.toOwnedSlice(), .consumed = consumed };
}
