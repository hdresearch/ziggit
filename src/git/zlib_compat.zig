//! Compatibility shim: provides the old std.compress.zlib API
//! on top of the zig 0.15 std.compress.flate API.

const std = @import("std");
const flate = std.compress.flate;

/// Decompress zlib data from an old-style GenericReader into an old-style GenericWriter.
pub fn decompress(old_reader: anytype, old_writer: anytype) !void {
    var adapter_buf: [65536]u8 = undefined;
    var adapter = old_reader.adaptToNewApi(&adapter_buf);
    var window_buf: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&adapter.new_interface, .zlib, &window_buf);

    // Use the new Writer adapter for output
    var writer_adapter_buf: [65536]u8 = undefined;
    var writer_adapter = old_writer.adaptToNewApi(&writer_adapter_buf);

    // Stream from decompressor reader to output writer
    _ = dec.reader.streamRemaining(&writer_adapter.new_interface) catch return error.InvalidInput;

    // Flush any remaining buffered data in the writer adapter
    writer_adapter.new_interface.flush() catch return error.InvalidInput;
}

/// Compress data from an old-style GenericReader into an old-style GenericWriter.
pub fn compress(old_reader: anytype, old_writer: anytype, options: anytype) !void {
    _ = options;

    // Read all input data first (from the old reader)
    var all_input = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer all_input.deinit();
    {
        var buf: [16384]u8 = undefined;
        while (true) {
            const n = old_reader.read(&buf) catch break;
            if (n == 0) break;
            try all_input.appendSlice(buf[0..n]);
        }
    }

    // Set up new-style writer adapter for output
    var writer_adapter_buf: [65536]u8 = undefined;
    var writer_adapter = old_writer.adaptToNewApi(&writer_adapter_buf);

    // Compress using the new API
    var compress_buf: [65536]u8 = undefined;
    var comp = flate.Compress.init(&writer_adapter.new_interface, &compress_buf, .{
        .container = .zlib,
    });

    // Feed input through compressor
    comp.writer.writeAll(all_input.items) catch return error.CompressionFailed;
    comp.end() catch return error.CompressionFailed;
}

/// Streaming decompressor wrapper compatible with old API.
pub fn Decompressor(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        inner_reader: ReaderType,
        adapter_buf: [65536]u8 = undefined,
        adapter: ?@TypeOf(blk: {
            var d: ReaderType = undefined;
            var b: [1]u8 = undefined;
            break :blk d.adaptToNewApi(&b);
        }) = null,
        window_buf: [flate.max_window_len]u8 = undefined,
        dec: ?flate.Decompress = null,

        fn ensureInit(self: *Self) void {
            if (self.adapter == null) {
                self.adapter = self.inner_reader.adaptToNewApi(&self.adapter_buf);
                self.dec = flate.Decompress.init(&self.adapter.?.new_interface, .zlib, &self.window_buf);
            }
        }

        pub const ReadError = error{ InvalidInput, EndOfStream };

        pub fn read(self: *Self, buf: []u8) ReadError!usize {
            self.ensureInit();
            var bufs = [_][]u8{buf};
            const orig_len = bufs[0].len;
            _ = self.dec.?.reader.readVec(&bufs) catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                error.ReadFailed => return error.InvalidInput,
            };
            return orig_len - bufs[0].len;
        }

        pub fn reader(self: *Self) @This().GenReader {
            return .{ .context = self };
        }

        pub const GenReader = std.io.GenericReader(*Self, ReadError, readAdapter);

        fn readAdapter(self: *Self, buf: []u8) ReadError!usize {
            return self.read(buf);
        }
    };
}

pub fn decompressor(old_reader: anytype) Decompressor(@TypeOf(old_reader)) {
    return .{ .inner_reader = old_reader };
}

/// Streaming compressor wrapper.
pub fn Compressor(comptime WriterType: type) type {
    return struct {
        const Self = @This();

        inner_writer: WriterType,
        writer_adapter_buf: [65536]u8 = undefined,
        writer_adapter: ?@TypeOf(blk: {
            var d: WriterType = undefined;
            var b: [1]u8 = undefined;
            break :blk d.adaptToNewApi(&b);
        }) = null,
        compress_buf: [65536]u8 = undefined,
        comp: ?flate.Compress = null,

        fn ensureInit(self: *Self) void {
            if (self.writer_adapter == null) {
                self.writer_adapter = self.inner_writer.adaptToNewApi(&self.writer_adapter_buf);
                self.comp = flate.Compress.init(&self.writer_adapter.?.new_interface, &self.compress_buf, .{
                    .container = .zlib,
                });
            }
        }

        pub fn write(self: *Self, data: []const u8) !usize {
            self.ensureInit();
            self.comp.?.writer.writeAll(data) catch return error.CompressionFailed;
            return data.len;
        }

        pub fn finish(self: *Self) !void {
            self.ensureInit();
            self.comp.?.end() catch return error.CompressionFailed;
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

pub fn compressorWriter(old_writer: anytype, options: anytype) !Compressor(@TypeOf(old_writer)) {
    _ = options;
    return .{ .inner_writer = old_writer };
}

pub fn compressSlice(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const c = @cImport({ @cInclude("zlib.h"); });
    const bound = c.compressBound(@intCast(input.len));
    const dest = try allocator.alloc(u8, @intCast(bound));
    var dest_len: c.uLongf = @intCast(dest.len);
    const ret = c.compress2(dest.ptr, &dest_len, input.ptr, @intCast(input.len), c.Z_DEFAULT_COMPRESSION);
    if (ret != c.Z_OK) { allocator.free(dest); return error.CompressionFailed; }
    return try allocator.realloc(dest, @intCast(dest_len));
}
pub fn decompressSlice(allocator: std.mem.Allocator, input: []const u8, max_output: usize) ![]u8 {
    const c = @cImport({ @cInclude("zlib.h"); });
    const dest = try allocator.alloc(u8, max_output);
    var dest_len: c.uLongf = @intCast(dest.len);
    const ret = c.uncompress(dest.ptr, &dest_len, input.ptr, @intCast(input.len));
    if (ret != c.Z_OK) { allocator.free(dest); return error.DecompressionFailed; }
    return try allocator.realloc(dest, @intCast(dest_len));
}
pub fn decompressSliceWithConsumed(allocator: std.mem.Allocator, input: []const u8) !struct { data: []u8, consumed: usize } {
    const c = @cImport({ @cInclude("zlib.h"); });
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    stream.next_in = @constCast(input.ptr);
    stream.avail_in = @intCast(input.len);
    var ret = c.inflateInit(&stream);
    if (ret != c.Z_OK) return error.DecompressionFailed;
    defer _ = c.inflateEnd(&stream);
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    var buf: [65536]u8 = undefined;
    while (true) {
        stream.next_out = &buf;
        stream.avail_out = buf.len;
        ret = c.inflate(&stream, c.Z_NO_FLUSH);
        const have = buf.len - @as(usize, @intCast(stream.avail_out));
        if (have > 0) try result.appendSlice(buf[0..have]);
        if (ret == c.Z_STREAM_END) break;
        if (ret != c.Z_OK) { result.deinit(); return error.DecompressionFailed; }
    }
    return .{ .data = try result.toOwnedSlice(), .consumed = input.len - @as(usize, @intCast(stream.avail_in)) };
}
