const std = @import("std");
const zlib = std.compress.zlib;

pub fn decompress(reader: anytype, writer: anytype) !void {
    zlib.decompress(reader, writer) catch return error.InvalidInput;
}

pub fn compress(reader: anytype, writer: anytype, options: anytype) !void {
    _ = options;
    zlib.compress(reader, writer, .{}) catch return error.CompressionFailed;
}

pub fn Decompressor(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        inner: zlib.Decompressor(ReaderType),

        pub fn read(self: *Self, out_buf: []u8) !usize {
            return self.inner.reader().readAll(out_buf) catch return error.InvalidInput;
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }
    };
}

pub fn decompressor(reader: anytype) Decompressor(@TypeOf(reader)) {
    return .{ .inner = zlib.decompressor(reader) };
}

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
            var fbs = std.io.fixedBufferStream(self.buffer.items);
            zlib.compress(fbs.reader(), self.inner_writer, .{}) catch return error.CompressionFailed;
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

pub fn compressSlice(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    var fbs = std.io.fixedBufferStream(input);
    zlib.compress(fbs.reader(), output.writer(), .{}) catch return error.CompressionFailed;
    return output.toOwnedSlice();
}

pub fn decompressSlice(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    var fbs = std.io.fixedBufferStream(input);
    zlib.decompress(fbs.reader(), output.writer()) catch return error.InvalidInput;
    return output.toOwnedSlice();
}

/// Fast decompression when the output size is known (e.g., from pack object headers).
pub fn decompressSliceKnownSize(allocator: std.mem.Allocator, input: []const u8, expected_size: usize) ![]u8 {
    const dest = try allocator.alloc(u8, expected_size);
    errdefer allocator.free(dest);
    var fbs = std.io.fixedBufferStream(input);
    var dcp = zlib.decompressor(fbs.reader());
    const n = dcp.reader().readAll(dest) catch {
        allocator.free(dest);
        return decompressSlice(allocator, input);
    };
    if (n == expected_size) {
        return dest;
    }
    // Size mismatch, fall back
    allocator.free(dest);
    return decompressSlice(allocator, input);
}

pub fn decompressSliceWithConsumed(allocator: std.mem.Allocator, input: []const u8) !struct { data: []u8, consumed: usize } {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    var fbs = std.io.fixedBufferStream(input);
    var dcp = zlib.decompressor(fbs.reader());
    // Read all decompressed data
    while (true) {
        var buf: [16384]u8 = undefined;
        const n = dcp.reader().read(&buf) catch return error.InvalidInput;
        if (n == 0) break;
        try output.appendSlice(buf[0..n]);
    }
    // Calculate consumed bytes: position in stream minus unread buffered bytes
    const consumed = fbs.pos - dcp.unreadBytes();
    return .{ .data = try output.toOwnedSlice(), .consumed = consumed };
}
