const std = @import("std");
const zlib = std.compress.zlib;

const c = @cImport({
    @cInclude("zlib.h");
});

pub fn decompress(reader: anytype, writer: anytype) !void {
    var all_input = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer all_input.deinit();
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = reader.read(&buf) catch break;
        if (n == 0) break;
        try all_input.appendSlice(buf[0..n]);
    }
    const result = try decompressSlice(std.heap.page_allocator, all_input.items);
    defer std.heap.page_allocator.free(result);
    writer.writeAll(result) catch return error.InvalidInput;
}

pub fn compress(reader: anytype, writer: anytype, options: anytype) !void {
    _ = options;
    var all_input = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer all_input.deinit();
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = reader.read(&buf) catch break;
        if (n == 0) break;
        try all_input.appendSlice(buf[0..n]);
    }
    const compressed = try compressSlice(std.heap.page_allocator, all_input.items);
    defer std.heap.page_allocator.free(compressed);
    writer.writeAll(compressed) catch return error.CompressionFailed;
}

pub fn Decompressor(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        source: ReaderType,
        stream: c.z_stream,
        input_buf: [16384]u8,
        initialized: bool,
        done: bool,

        pub fn read(self: *Self, out_buf: []u8) !usize {
            if (self.done) return 0;
            if (!self.initialized) {
                self.stream = std.mem.zeroes(c.z_stream);
                const ret = c.inflateInit(&self.stream);
                if (ret != c.Z_OK) return error.InvalidInput;
                self.initialized = true;
            }
            self.stream.next_out = out_buf.ptr;
            self.stream.avail_out = @intCast(out_buf.len);
            while (self.stream.avail_out > 0) {
                if (self.stream.avail_in == 0) {
                    const n = self.source.read(&self.input_buf) catch return error.InvalidInput;
                    if (n == 0) {
                        self.done = true;
                        break;
                    }
                    self.stream.next_in = &self.input_buf;
                    self.stream.avail_in = @intCast(n);
                }
                const ret = c.inflate(&self.stream, c.Z_NO_FLUSH);
                if (ret == c.Z_STREAM_END) {
                    self.done = true;
                    break;
                }
                if (ret != c.Z_OK) return error.InvalidInput;
            }
            return out_buf.len - @as(usize, @intCast(self.stream.avail_out));
        }

        pub fn deinit(self: *Self) void {
            if (self.initialized) {
                _ = c.inflateEnd(&self.stream);
                self.initialized = false;
            }
        }
    };
}

pub fn decompressor(reader: anytype) Decompressor(@TypeOf(reader)) {
    return .{ .source = reader, .stream = std.mem.zeroes(c.z_stream), .input_buf = undefined, .initialized = false, .done = false };
}

pub fn Compressor(comptime WriterType: type) type {
    return struct {
        const Self = @This();
        inner_writer: WriterType,
        buffer: std.array_list.Managed(u8),
        pub fn write(self: *Self, data: []const u8) !usize {
            self.buffer.appendSlice(data) catch return error.CompressionFailed;
            return data.len;
        }
        pub fn finish(self: *Self) !void {
            const cmp = compressSlice(self.buffer.allocator, self.buffer.items) catch return error.CompressionFailed;
            defer self.buffer.allocator.free(cmp);
            self.inner_writer.writeAll(cmp) catch return error.CompressionFailed;
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
    return .{ .inner_writer = writer, .buffer = std.array_list.Managed(u8).init(std.heap.page_allocator) };
}

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
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    stream.next_in = @constCast(input.ptr);
    stream.avail_in = @intCast(input.len);
    var ret = c.inflateInit(&stream);
    if (ret != c.Z_OK) return error.InvalidInput;
    defer _ = c.inflateEnd(&stream);
    var output = std.array_list.Managed(u8).init(allocator);
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
    return output.toOwnedSlice();
}

pub fn decompressSliceWithConsumed(allocator: std.mem.Allocator, input: []const u8) !struct { data: []u8, consumed: usize } {
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    stream.next_in = @constCast(input.ptr);
    stream.avail_in = @intCast(input.len);
    var ret = c.inflateInit(&stream);
    if (ret != c.Z_OK) return error.InvalidInput;
    defer _ = c.inflateEnd(&stream);
    var output = std.array_list.Managed(u8).init(allocator);
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
    return .{ .data = try output.toOwnedSlice(), .consumed = @intCast(stream.total_in) };
}
