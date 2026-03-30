const std = @import("std");
const flate = std.compress.flate;
const Decompress = flate.Decompress;
const Compress = flate.Compress;
const Container = flate.Container;
const Io = std.Io;

pub fn decompress(reader: anytype, writer: anytype) !void {
    // Read all input from the generic reader into a buffer
    var input_buf = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer input_buf.deinit();
    while (true) {
        var tmp: [16384]u8 = undefined;
        const n = reader.read(&tmp) catch return error.InvalidInput;
        if (n == 0) break;
        input_buf.appendSlice(tmp[0..n]) catch return error.InvalidInput;
    }

    // Decompress using slice-based API and write result
    const decompressed = decompressSlice(std.heap.page_allocator, input_buf.items) catch return error.InvalidInput;
    defer std.heap.page_allocator.free(decompressed);
    writer.writeAll(decompressed) catch return error.InvalidInput;
}

pub fn compress(reader: anytype, writer: anytype, options: anytype) !void {
    _ = options;
    // Read all input
    var input_buf = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer input_buf.deinit();
    while (true) {
        var tmp: [16384]u8 = undefined;
        const n = reader.read(&tmp) catch return error.CompressionFailed;
        if (n == 0) break;
        input_buf.appendSlice(tmp[0..n]) catch return error.CompressionFailed;
    }

    // Use allocating writer for compressed output
    var aw: Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer aw.deinit();

    // Compress with zlib container
    if (comptime @import("builtin").os.tag == .freestanding) {
        // Compression has known issues on wasm32-freestanding (infinite loop in flate).
        return error.CompressionFailed;
    }
    const comp_buf_size_local = flate.max_window_len * 2 + 512 * 1024;
    var comp_buf: [comp_buf_size_local]u8 = undefined;
    var comp: Compress = .init(&aw.writer, &comp_buf, .{ .container = .zlib });
    _ = comp.writer.writeAll(input_buf.items) catch return error.CompressionFailed;
    comp.end() catch return error.CompressionFailed;

    // Write compressed output to the generic writer
    writer.writeAll(aw.written()) catch return error.CompressionFailed;
}

pub fn Decompressor(comptime ReaderType: type) type {
    _ = ReaderType;
    return struct {
        const Self = @This();
        // Store the compressed data for decompression
        compressed_data: []const u8,
        decompressed: []u8,
        pos: usize,

        pub fn read(self: *Self, out_buf: []u8) !usize {
            if (self.pos >= self.decompressed.len) return 0;
            const remaining = self.decompressed.len - self.pos;
            const to_copy = @min(out_buf.len, remaining);
            @memcpy(out_buf[0..to_copy], self.decompressed[self.pos..][0..to_copy]);
            self.pos += to_copy;
            return to_copy;
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }
    };
}

pub fn decompressor(reader: anytype) Decompressor(@TypeOf(reader)) {
    // Read all data from the reader first
    var input_buf = std.array_list.Managed(u8).init(std.heap.page_allocator);
    while (true) {
        var tmp: [16384]u8 = undefined;
        const n = reader.read(&tmp) catch break;
        if (n == 0) break;
        input_buf.appendSlice(tmp[0..n]) catch break;
    }

    // Decompress
    var in: Io.Reader = .fixed(input_buf.items);
    var decomp_buf: [flate.max_window_len]u8 = undefined;
    _ = &decomp_buf;
    var dec: Decompress = .init(&in, .zlib, &.{});

    var output = std.array_list.Managed(u8).init(std.heap.page_allocator);
    while (true) {
        var buf: [16384]u8 = undefined;
        const n = dec.reader.read(&buf) catch break;
        if (n == 0) break;
        output.appendSlice(buf[0..n]) catch break;
    }
    input_buf.deinit();

    return .{
        .compressed_data = &.{},
        .decompressed = output.items,
        .pos = 0,
    };
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
            if (comptime @import("builtin").os.tag == .freestanding) {
                // Compression has known issues on wasm32-freestanding (infinite loop in flate).
                // Store uncompressed as a fallback.
                return error.CompressionFailed;
            }
            var aw: Io.Writer.Allocating = .init(std.heap.page_allocator);
            defer aw.deinit();

            const comp_buf_size = flate.max_window_len * 2 + 512 * 1024;
            var comp_buf: [comp_buf_size]u8 = undefined;
            var comp: Compress = .init(&aw.writer, &comp_buf, .{ .container = .zlib });
            _ = comp.writer.writeAll(self.buffer.items) catch return error.CompressionFailed;
            comp.end() catch return error.CompressionFailed;

            self.inner_writer.writeAll(aw.written()) catch return error.CompressionFailed;
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
    if (comptime @import("builtin").os.tag == .freestanding) {
        // Compression has known issues on wasm32-freestanding (infinite loop in flate).
        return error.CompressionFailed;
    }
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    const comp_buf_size = flate.max_window_len * 2 + 512 * 1024;
    var comp_buf: [comp_buf_size]u8 = undefined;
    var comp: Compress = .init(&aw.writer, &comp_buf, .{ .container = .zlib });
    _ = comp.writer.writeAll(input) catch return error.CompressionFailed;
    comp.end() catch return error.CompressionFailed;

    return aw.toOwnedSlice();
}

pub fn decompressSlice(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var in: Io.Reader = .fixed(input);
    var dec: Decompress = .init(&in, .zlib, &.{});

    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    _ = dec.reader.streamRemaining(&aw.writer) catch return error.InvalidInput;

    return aw.toOwnedSlice();
}

/// Fast decompression when the output size is known (e.g., from pack object headers).
pub fn decompressSliceKnownSize(allocator: std.mem.Allocator, input: []const u8, expected_size: usize) ![]u8 {
    _ = expected_size;
    // Just use the general decompressSlice - the new API is efficient enough
    return decompressSlice(allocator, input);
}

pub fn decompressSliceWithConsumed(allocator: std.mem.Allocator, input: []const u8) !struct { data: []u8, consumed: usize } {
    var in: Io.Reader = .fixed(input);
    var dec: Decompress = .init(&in, .zlib, &.{});

    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    _ = dec.reader.streamRemaining(&aw.writer) catch return error.InvalidInput;

    // Calculate consumed: total input minus what's still buffered in the reader
    const buffered_remaining = in.end - in.seek;
    const consumed = input.len - buffered_remaining;

    return .{ .data = try aw.toOwnedSlice(), .consumed = consumed };
}
