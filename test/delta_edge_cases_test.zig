const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// Delta edge cases that the git protocol can produce
// These test corner cases in the delta format specification
// ============================================================================

/// Encode a variable-length integer (git varint for delta headers)
fn encodeVarint(buf: []u8, value: usize) usize {
    var v = value;
    var i: usize = 0;
    while (true) {
        buf[i] = @intCast(v & 0x7F);
        v >>= 7;
        if (v == 0) {
            return i + 1;
        }
        buf[i] |= 0x80;
        i += 1;
    }
}

fn appendCopyCommand(delta: *std.ArrayList(u8), offset: usize, size: usize) !void {
    var cmd: u8 = 0x80;
    var params = std.ArrayList(u8).init(delta.allocator);
    defer params.deinit();

    if (offset & 0xFF != 0) { cmd |= 0x01; try params.append(@intCast(offset & 0xFF)); }
    if (offset & 0xFF00 != 0) { cmd |= 0x02; try params.append(@intCast((offset >> 8) & 0xFF)); }
    if (offset & 0xFF0000 != 0) { cmd |= 0x04; try params.append(@intCast((offset >> 16) & 0xFF)); }
    if (offset & 0xFF000000 != 0) { cmd |= 0x08; try params.append(@intCast((offset >> 24) & 0xFF)); }

    const actual_size = if (size == 0x10000) @as(usize, 0) else size;
    if (actual_size != 0) {
        if (actual_size & 0xFF != 0 or (actual_size > 0 and actual_size <= 0xFF)) {
            cmd |= 0x10; try params.append(@intCast(actual_size & 0xFF));
        }
        if (actual_size & 0xFF00 != 0) {
            cmd |= 0x20; try params.append(@intCast((actual_size >> 8) & 0xFF));
        }
        if (actual_size & 0xFF0000 != 0) {
            cmd |= 0x40; try params.append(@intCast((actual_size >> 16) & 0xFF));
        }
    }

    try delta.append(cmd);
    try delta.appendSlice(params.items);
}

// ============================================================================
// Test: Copy with size=0 meaning 0x10000 (65536 bytes)
// This is a real git optimization - when copy size == 65536, no size bytes
// are emitted and the decoder treats size=0 as 0x10000
// ============================================================================
test "delta edge: copy size 0x10000 (no size bytes)" {
    const allocator = testing.allocator;

    // Create base data of exactly 0x10000 bytes
    var base_buf: [0x10000]u8 = undefined;
    for (&base_buf, 0..) |*b, i| {
        b.* = @intCast(i % 251); // Prime to avoid patterns
    }
    const base: []const u8 = &base_buf;

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    // Header
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 0x10000);
    try delta.appendSlice(buf[0..n]);

    // Copy command with size=0x10000 → emit 0x80 (no offset bytes, no size bytes)
    // Actually: cmd = 0x80, offset=0 (no flags), size=0 → interpreted as 0x10000
    try appendCopyCommand(&delta, 0, 0x10000);

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0x10000), result.len);
    try testing.expectEqualSlices(u8, base, result);
}

// ============================================================================
// Test: Copy with offset=0 (all offset bytes omitted)
// ============================================================================
test "delta edge: copy from offset 0" {
    const allocator = testing.allocator;
    const base = "ABCDEFGH";

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 4);
    try delta.appendSlice(buf[0..n]);

    // Copy offset=0, size=4: cmd = 0x80 | 0x10, then size byte = 4
    try delta.append(0x90);
    try delta.append(4);

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("ABCD", result);
}

// ============================================================================
// Test: Multiple interleaved copy and insert commands
// ============================================================================
test "delta edge: interleaved copy-insert-copy-insert" {
    const allocator = testing.allocator;
    const base = "HEADER_DATA_FOOTER_END";
    // Result: "HEADER" + "-X-" + "FOOTER" + "-Y"
    const expected = "HEADER-X-FOOTER-Y";

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, expected.len);
    try delta.appendSlice(buf[0..n]);

    // Copy "HEADER" from offset 0, size 6
    try appendCopyCommand(&delta, 0, 6);
    // Insert "-X-"
    try delta.append(3);
    try delta.appendSlice("-X-");
    // Copy "FOOTER" from offset 12, size 6
    try appendCopyCommand(&delta, 12, 6);
    // Insert "-Y"
    try delta.append(2);
    try delta.appendSlice("-Y");

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

// ============================================================================
// Test: Delta that grows data significantly (small base → large result)
// This tests that the suspicious growth check doesn't reject valid deltas
// ============================================================================
test "delta edge: small base expands to large result via inserts" {
    const allocator = testing.allocator;
    const base = "X";

    // Insert 500 bytes of new data
    var new_data: [500]u8 = undefined;
    for (&new_data, 0..) |*b, i| {
        b.* = @intCast(65 + (i % 26)); // A-Z repeating
    }

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, new_data.len);
    try delta.appendSlice(buf[0..n]);

    // Insert commands (max 127 bytes each)
    var pos: usize = 0;
    while (pos < new_data.len) {
        const chunk = @min(127, new_data.len - pos);
        try delta.append(@intCast(chunk));
        try delta.appendSlice(new_data[pos .. pos + chunk]);
        pos += chunk;
    }

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 500), result.len);
    try testing.expectEqualSlices(u8, &new_data, result);
}

// ============================================================================
// Test: Copy with all 4 offset bytes set (large offset)
// ============================================================================
test "delta edge: copy with 4-byte offset" {
    const allocator = testing.allocator;

    // Need a base large enough for offset 0x0100 + 4 = 260
    var base_buf: [300]u8 = undefined;
    @memset(&base_buf, 0);
    // Put recognizable data at offset 256
    base_buf[256] = 'T';
    base_buf[257] = 'E';
    base_buf[258] = 'S';
    base_buf[259] = 'T';

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, 300);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 4);
    try delta.appendSlice(buf[0..n]);

    // Copy offset=256, size=4
    // offset 256 = 0x00 0x01 → needs byte 0 (0x00) and byte 1 (0x01)
    // cmd = 0x80 | 0x02 (second offset byte) | 0x10 (first size byte)
    try delta.append(0x80 | 0x02 | 0x10);
    try delta.append(0x01); // offset byte 1 = 0x01 → offset = 0x0100 = 256
    try delta.append(4); // size = 4

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(&base_buf, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("TEST", result);
}

// ============================================================================
// Test: Delta with exactly 127-byte insert (max single insert cmd)
// ============================================================================
test "delta edge: insert exactly 127 bytes" {
    const allocator = testing.allocator;
    const base = "B";

    var insert_data: [127]u8 = undefined;
    @memset(&insert_data, 'Z');

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 127);
    try delta.appendSlice(buf[0..n]);

    try delta.append(127); // insert 127 bytes
    try delta.appendSlice(&insert_data);

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 127), result.len);
    for (result) |c| try testing.expectEqual(@as(u8, 'Z'), c);
}

// ============================================================================
// Test: Copy with 2-byte size (size > 255)
// ============================================================================
test "delta edge: copy with 2-byte size" {
    const allocator = testing.allocator;

    // Base with 400 bytes
    var base_buf: [400]u8 = undefined;
    for (&base_buf, 0..) |*b, i| b.* = @intCast(i % 256);

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, 400);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 300);
    try delta.appendSlice(buf[0..n]);

    // Copy offset=0, size=300 (0x012C)
    // size needs two bytes: 0x2C (low), 0x01 (high)
    try delta.append(0x80 | 0x10 | 0x20); // size byte 0 and size byte 1
    try delta.append(0x2C); // size low byte
    try delta.append(0x01); // size high byte

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(&base_buf, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 300), result.len);
    try testing.expectEqualSlices(u8, base_buf[0..300], result);
}

// ============================================================================
// Test: Verify delta with git - apply delta created by us, compare with git
// ============================================================================
test "delta edge: git-created delta matches our application" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitCmdNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    runGitCmdNoOutput(allocator, tmp_path, &.{ "config", "user.email", "t@t.com" }) catch return;
    runGitCmdNoOutput(allocator, tmp_path, &.{ "config", "user.name", "T" }) catch return;

    // Create base file (v1)
    const v1 = "line 1: common\nline 2: original\nline 3: common\nline 4: common\nline 5: original\n";
    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = v1 });
    runGitCmdNoOutput(allocator, tmp_path, &.{ "add", "f.txt" }) catch return;
    runGitCmdNoOutput(allocator, tmp_path, &.{ "commit", "-m", "v1" }) catch return;

    // Modified file (v2)
    const v2 = "line 1: common\nline 2: MODIFIED\nline 3: common\nline 4: common\nline 5: MODIFIED\n";
    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = v2 });
    runGitCmdNoOutput(allocator, tmp_path, &.{ "add", "f.txt" }) catch return;
    runGitCmdNoOutput(allocator, tmp_path, &.{ "commit", "-m", "v2" }) catch return;

    // Repack to create deltas
    runGitCmdNoOutput(allocator, tmp_path, &.{ "repack", "-a", "-d", "-f" }) catch return;
    runGitCmdNoOutput(allocator, tmp_path, &.{ "prune-packed" }) catch {};

    // Get hash of v2 blob
    const hash_raw = runGitCmd(allocator, tmp_path, &.{ "rev-parse", "HEAD:f.txt" }) catch return;
    defer allocator.free(hash_raw);
    const hash = std.mem.trim(u8, hash_raw, " \t\n\r");

    // Read with ziggit
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    const RealFsPlatform = struct {
        fs: struct {
            pub fn readFile(_: @This(), alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 50 * 1024 * 1024);
            }
            pub fn writeFile(_: @This(), path: []const u8, data: []const u8) !void {
                const file = try std.fs.cwd().createFile(path, .{});
                defer file.close();
                try file.writeAll(data);
            }
            pub fn makeDir(_: @This(), path: []const u8) anyerror!void {
                std.fs.cwd().makeDir(path) catch |err| switch (err) {
                    error.PathAlreadyExists => return error.AlreadyExists,
                    else => return err,
                };
            }
        } = .{},
    };
    const platform = RealFsPlatform{};

    const loaded = objects.GitObject.load(hash, git_dir, &platform, allocator) catch |err| {
        std.debug.print("Load failed: {}\n", .{err});
        return;
    };
    defer loaded.deinit(allocator);

    try testing.expectEqualStrings(v2, loaded.data);
}

fn runGitCmd(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.appendSlice(args);
    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    const result = try child.wait();
    if (result.Exited != 0) {
        allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn runGitCmdNoOutput(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try runGitCmd(allocator, cwd, args);
    allocator.free(out);
}
