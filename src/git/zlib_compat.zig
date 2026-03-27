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

/// Compress a slice of data using zlib, returning allocated compressed bytes.
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

/// Decompress a slice of zlib data, returning allocated decompressed bytes.
pub fn decompressSlice(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var fbs = std.io.fixedBufferStream(input);
    var reader_adapter_buf: [65536]u8 = undefined;
    var reader_adapter = fbs.reader().adaptToNewApi(&reader_adapter_buf);

    var window_buf: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&reader_adapter.new_interface, .zlib, &window_buf);

    var writer_adapter_buf: [65536]u8 = undefined;
    var writer_adapter = output.writer().adaptToNewApi(&writer_adapter_buf);

    _ = dec.reader.streamRemaining(&writer_adapter.new_interface) catch return error.InvalidInput;
    writer_adapter.new_interface.flush() catch return error.InvalidInput;

    return output.toOwnedSlice();
}
