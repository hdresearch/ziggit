const std = @import("std");
const testing = std.testing;
const objects = @import("../src/git/objects.zig");
const performance = @import("../src/git/performance.zig");
const streaming = @import("../src/git/streaming.zig");
const diagnostics = @import("../src/git/diagnostics.zig");

/// Comprehensive pack file validation test
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Warning: memory leaked in pack validation tests\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("=== Pack File Validation Test Suite ===\n", .{});
    
    // Test 1: Object hash computation with performance monitoring
    try testObjectHashPerformance(allocator);
    
    // Test 2: Pack file format validation
    try testPackFileFormatValidation(allocator);
    
    // Test 3: Delta application validation
    try testDeltaApplicationValidation(allocator);
    
    // Test 4: Cache performance
    try testCachePerformance(allocator);
    
    // Test 5: Streaming interface
    try testStreamingInterface(allocator);
    
    std.debug.print("\n=== All Pack Validation Tests Completed ===\n", .{});
}

fn testObjectHashPerformance(allocator: std.mem.Allocator) !void {
    std.debug.print("\n1. Testing object hash computation performance...\n", .{});
    
    performance.global_stats.reset();
    
    const test_data = "This is a test blob for hash performance measurement.";
    
    // Test small object (stack allocation path)
    const start_time = performance.startTiming();
    const hash1 = try performance.computeObjectHash("blob", test_data, allocator);
    defer allocator.free(hash1);
    performance.endTiming(start_time);
    
    std.debug.print("  Small object hash: {s}\n", .{hash1[0..8]});
    
    // Test large object (heap allocation path)
    const large_data = try allocator.alloc(u8, 16384); // 16KB
    defer allocator.free(large_data);
    std.mem.set(u8, large_data, 'A');
    
    const start_time2 = performance.startTiming();
    const hash2 = try performance.computeObjectHash("blob", large_data, allocator);
    defer allocator.free(hash2);
    performance.endTiming(start_time2);
    
    std.debug.print("  Large object hash: {s}\n", .{hash2[0..8]});
    
    // Verify hashes are different
    if (std.mem.eql(u8, hash1, hash2)) {
        std.debug.print("  ❌ ERROR: Different objects produced same hash!\n", .{});
        return error.HashCollision;
    }
    
    performance.global_stats.print();
    std.debug.print("  ✅ Hash performance test passed\n", .{});
}

fn testPackFileFormatValidation(allocator: std.mem.Allocator) !void {
    std.debug.print("\n2. Testing pack file format validation...\n", .{});
    
    // Create a minimal valid pack file header
    const valid_pack_header = "PACK" ++ 
        [_]u8{0, 0, 0, 2} ++    // Version 2
        [_]u8{0, 0, 0, 0};      // 0 objects
    
    // Test valid pack file
    var stream = streaming.PackFileStream.init(valid_pack_header, allocator) catch |err| {
        std.debug.print("  ❌ ERROR: Failed to create pack stream: {}\n", .{err});
        return err;
    };
    
    std.debug.print("  ✅ Valid pack file header accepted\n", .{});
    std.debug.print("  Pack stream position: {}\n", .{stream.getPosition()});
    
    // Test invalid pack file (wrong magic)
    const invalid_pack_header = "PAKC" ++ [_]u8{0, 0, 0, 2} ++ [_]u8{0, 0, 0, 0};
    const invalid_result = streaming.PackFileStream.init(invalid_pack_header, allocator);
    
    if (invalid_result) |_| {
        std.debug.print("  ❌ ERROR: Invalid pack file was accepted!\n", .{});
        return error.ValidationFailed;
    } else |err| {
        if (err == error.InvalidPackFile) {
            std.debug.print("  ✅ Invalid pack file properly rejected\n", .{});
        } else {
            std.debug.print("  ❌ ERROR: Unexpected error for invalid pack: {}\n", .{err});
            return err;
        }
    }
    
    // Test pack file too small
    const tiny_pack = "PAC";
    const tiny_result = streaming.PackFileStream.init(tiny_pack, allocator);
    
    if (tiny_result) |_| {
        std.debug.print("  ❌ ERROR: Tiny pack file was accepted!\n", .{});
        return error.ValidationFailed;
    } else |err| {
        if (err == error.InvalidPackFile) {
            std.debug.print("  ✅ Tiny pack file properly rejected\n", .{});
        } else {
            std.debug.print("  ❌ ERROR: Unexpected error for tiny pack: {}\n", .{err});
            return err;
        }
    }
    
    std.debug.print("  ✅ Pack file format validation test passed\n", .{});
}

fn testDeltaApplicationValidation(allocator: std.mem.Allocator) !void {
    std.debug.print("\n3. Testing delta application validation...\n", .{});
    
    const base_data = "Hello, world!";
    
    // Create a simple insert delta
    var delta_data = std.ArrayList(u8).init(allocator);
    defer delta_data.deinit();
    
    // Delta format: base_size, result_size, then commands
    // Base size (13)
    try delta_data.append(13);
    // Result size (21 = 13 + 8 for " Ziggit!")
    try delta_data.append(21);
    
    // Copy command: copy all of base (offset=0, size=13)
    try delta_data.append(0x80 | 0x10); // Copy command with size bit set
    try delta_data.append(13); // Size to copy
    
    // Insert command: insert " Ziggit!"
    const insert_text = " Ziggit!";
    try delta_data.append(@intCast(insert_text.len)); // Insert 8 bytes
    try delta_data.appendSlice(insert_text);
    
    // Apply the delta (using the private function - this is a simplified test)
    const result = objects.applyDelta(base_data, delta_data.items, allocator) catch |err| {
        std.debug.print("  Delta application failed: {}\n", .{err});
        return err;
    };
    defer allocator.free(result);
    
    const expected = "Hello, world! Ziggit!";
    if (!std.mem.eql(u8, result, expected)) {
        std.debug.print("  ❌ ERROR: Delta result mismatch\n", .{});
        std.debug.print("  Expected: {s}\n", .{expected});
        std.debug.print("  Got:      {s}\n", .{result});
        return error.DeltaFailed;
    }
    
    std.debug.print("  ✅ Delta application: '{s}' -> '{s}'\n", .{base_data, result});
    
    // Test malformed delta
    const bad_delta = [_]u8{255, 255, 255}; // Invalid delta
    const bad_result = objects.applyDelta(base_data, &bad_delta, allocator);
    
    if (bad_result) |_| {
        std.debug.print("  ❌ ERROR: Malformed delta was accepted!\n", .{});
        return error.ValidationFailed;
    } else |err| {
        std.debug.print("  ✅ Malformed delta properly rejected: {}\n", .{err});
    }
    
    std.debug.print("  ✅ Delta application validation test passed\n", .{});
}

fn testCachePerformance(allocator: std.mem.Allocator) !void {
    std.debug.print("\n4. Testing cache performance...\n", .{});
    
    var cache = performance.ObjectCache([]const u8).init(allocator, 5);
    defer cache.deinit();
    
    performance.global_stats.reset();
    
    // Fill cache
    const test_values = [_][]const u8{
        "value1", "value2", "value3", "value4", "value5"
    };
    
    for (test_values, 0..) |value, i| {
        const key = try std.fmt.allocPrint(allocator, "key{}", .{i});
        defer allocator.free(key);
        try cache.put(key, value);
    }
    
    std.debug.print("  Cache filled with {} items\n", .{cache.size()});
    
    // Test cache hits
    for (test_values, 0..) |expected_value, i| {
        const key = try std.fmt.allocPrint(allocator, "key{}", .{i});
        defer allocator.free(key);
        
        if (cache.get(key)) |value| {
            if (!std.mem.eql(u8, value, expected_value)) {
                std.debug.print("  ❌ ERROR: Cache returned wrong value for {s}\n", .{key});
                return error.CacheFailed;
            }
        } else {
            std.debug.print("  ❌ ERROR: Cache miss for key that should exist: {s}\n", .{key});
            return error.CacheFailed;
        }
    }
    
    // Test cache eviction
    try cache.put("key_new", "value_new");
    
    // First key should be evicted (LRU)
    if (cache.get("key0") != null) {
        std.debug.print("  ❌ ERROR: LRU eviction didn't work\n", .{});
        return error.CacheFailed;
    }
    
    if (cache.get("key_new") == null) {
        std.debug.print("  ❌ ERROR: New key not found after insertion\n", .{});
        return error.CacheFailed;
    }
    
    std.debug.print("  ✅ Cache hits: {}, Cache misses: {}\n", .{
        performance.global_stats.cache_hits,
        performance.global_stats.cache_misses
    });
    
    std.debug.print("  ✅ Cache performance test passed\n", .{});
}

fn testStreamingInterface(allocator: std.mem.Allocator) !void {
    std.debug.print("\n5. Testing streaming interface...\n", .{});
    
    const test_data = "This is a test stream for the streaming interface validation.";
    
    // Create a stream
    var buffer_stream = std.io.fixedBufferStream(test_data);
    var obj_stream = streaming.ObjectStream.init(
        buffer_stream.reader().any(),
        objects.ObjectType.blob,
        test_data.len,
        allocator
    );
    
    std.debug.print("  Created stream for {} bytes\n", .{obj_stream.bytesRemaining()});
    std.debug.print("  Object type: {s}\n", .{obj_stream.getObjectType().toString()});
    
    // Test partial read
    var read_buffer: [20]u8 = undefined;
    const bytes_read = try obj_stream.read(&read_buffer);
    
    std.debug.print("  Read {} bytes: '{s}'\n", .{bytes_read, read_buffer[0..bytes_read]});
    
    if (bytes_read != 20) {
        std.debug.print("  ❌ ERROR: Expected to read 20 bytes, got {}\n", .{bytes_read});
        return error.StreamFailed;
    }
    
    if (!std.mem.eql(u8, read_buffer[0..bytes_read], test_data[0..20])) {
        std.debug.print("  ❌ ERROR: Stream data mismatch\n", .{});
        return error.StreamFailed;
    }
    
    std.debug.print("  Remaining bytes: {}\n", .{obj_stream.bytesRemaining()});
    
    // Test read all remaining
    const remaining_data = try obj_stream.readAll();
    defer allocator.free(remaining_data);
    
    const expected_remaining = test_data[20..];
    if (!std.mem.eql(u8, remaining_data, expected_remaining)) {
        std.debug.print("  ❌ ERROR: Remaining data mismatch\n", .{});
        std.debug.print("  Expected: '{s}'\n", .{expected_remaining});
        std.debug.print("  Got:      '{s}'\n", .{remaining_data});
        return error.StreamFailed;
    }
    
    std.debug.print("  Remaining data: '{s}'\n", .{remaining_data});
    std.debug.print("  Final remaining bytes: {}\n", .{obj_stream.bytesRemaining()});
    
    if (obj_stream.bytesRemaining() != 0) {
        std.debug.print("  ❌ ERROR: Stream should be empty\n", .{});
        return error.StreamFailed;
    }
    
    std.debug.print("  ✅ Streaming interface test passed\n", .{});
}

/// Test function that can be called from zig build test
test "pack validation comprehensive test" {
    try main();
}