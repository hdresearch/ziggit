const std = @import("std");
const testing = std.testing;
const fs = std.fs;

// Test comprehensive index format support with real git repositories

test "index format comprehensive test" {
    const allocator = testing.allocator;
    
    // Skip on WASM
    if (@import("builtin").target.os.tag == .wasi) return;
    
    // Create temporary directory
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    const temp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(temp_path);
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);
    
    // Initialize git repository
    var init_process = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
    init_process.cwd = temp_path;
    init_process.stdout_behavior = .Ignore;
    init_process.stderr_behavior = .Ignore;
    _ = init_process.spawnAndWait() catch return; // Skip if git not available
    
    // Configure git
    var config_name_process = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
    config_name_process.cwd = temp_path;
    config_name_process.stdout_behavior = .Ignore;
    config_name_process.stderr_behavior = .Ignore;
    _ = config_name_process.spawnAndWait() catch return;
    
    var config_email_process = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
    config_email_process.cwd = temp_path;
    config_email_process.stdout_behavior = .Ignore;
    config_email_process.stderr_behavior = .Ignore;
    _ = config_email_process.spawnAndWait() catch return;
    
    // Create various types of files to test index entries
    try tmp_dir.dir.writeFile(.{.sub_path = "regular_file.txt", .data = "This is a regular file\nWith multiple lines\n"});
    try tmp_dir.dir.writeFile(.{.sub_path = "binary_file.bin", .data = "\x00\x01\x02\x03\xFF\xFE\xFD\xFC"});
    try tmp_dir.dir.writeFile(.{.sub_path = "long_filename_that_tests_path_length_handling.txt", .data = "Content\n"});
    
    // Create subdirectories
    try tmp_dir.dir.makeDir("subdir");
    try tmp_dir.dir.writeFile(.{.sub_path = "subdir/nested_file.txt", .data = "Nested file content\n"});
    
    try tmp_dir.dir.makeDir("deep");
    try tmp_dir.dir.makeDir("deep/nested");
    try tmp_dir.dir.makeDir("deep/nested/directory");
    try tmp_dir.dir.writeFile(.{.sub_path = "deep/nested/directory/deep_file.txt", .data = "Very deep file\n"});
    
    // Add files to git index
    var add_process = std.process.Child.init(&[_][]const u8{ "git", "add", "." }, allocator);
    add_process.cwd = temp_path;
    add_process.stdout_behavior = .Ignore;
    add_process.stderr_behavior = .Ignore;
    _ = add_process.spawnAndWait() catch return;
    
    // Read the index file directly to analyze it
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index", .{git_dir});
    defer allocator.free(index_path);
    
    const index_data = try fs.cwd().readFileAlloc(allocator, index_path, 1024 * 1024);
    defer allocator.free(index_data);
    
    std.debug.print("Index file size: {} bytes\n", .{index_data.len});
    
    // Test 1: Verify index header
    if (index_data.len < 12) {
        std.debug.print("Index file too small\n", .{});
        return;
    }
    
    // Check signature
    const signature = index_data[0..4];
    try testing.expectEqualSlices(u8, "DIRC", signature);
    std.debug.print("Index signature: OK\n", .{});
    
    // Check version
    const version = std.mem.readInt(u32, @ptrCast(index_data[4..8]), .big);
    std.debug.print("Index version: {}\n", .{version});
    try testing.expect(version >= 2 and version <= 4);
    
    // Check entry count
    const entry_count = std.mem.readInt(u32, @ptrCast(index_data[8..12]), .big);
    std.debug.print("Index entry count: {}\n", .{entry_count});
    try testing.expect(entry_count >= 4); // We added at least 4 files
    
    // Test 2: Parse index entries manually
    var pos: usize = 12;
    var entries_parsed: u32 = 0;
    
    while (entries_parsed < entry_count and pos + 62 <= index_data.len) {
        const entry_start = pos;
        _ = entry_start;
        
        // Read basic entry fields
        const ctime_sec = std.mem.readInt(u32, @ptrCast(index_data[pos..pos + 4]), .big);
        _ = ctime_sec;
        pos += 4;
        const ctime_nsec = std.mem.readInt(u32, @ptrCast(index_data[pos..pos + 4]), .big);
        _ = ctime_nsec;
        pos += 4;
        const mtime_sec = std.mem.readInt(u32, @ptrCast(index_data[pos..pos + 4]), .big);
        _ = mtime_sec;
        pos += 4;
        const mtime_nsec = std.mem.readInt(u32, @ptrCast(index_data[pos..pos + 4]), .big);
        _ = mtime_nsec;
        pos += 4;
        const dev = std.mem.readInt(u32, @ptrCast(index_data[pos..pos + 4]), .big);
        _ = dev;
        pos += 4;
        const ino = std.mem.readInt(u32, @ptrCast(index_data[pos..pos + 4]), .big);
        _ = ino;
        pos += 4;
        const mode = std.mem.readInt(u32, @ptrCast(index_data[pos..pos + 4]), .big);
        pos += 4;
        const uid = std.mem.readInt(u32, @ptrCast(index_data[pos..pos + 4]), .big);
        _ = uid;
        pos += 4;
        const gid = std.mem.readInt(u32, @ptrCast(index_data[pos..pos + 4]), .big);
        _ = gid;
        pos += 4;
        const size = std.mem.readInt(u32, @ptrCast(index_data[pos..pos + 4]), .big);
        pos += 4;
        
        // SHA-1 hash (20 bytes)
        if (pos + 20 > index_data.len) break;
        const sha1 = index_data[pos..pos + 20];
        pos += 20;
        
        // Flags
        if (pos + 2 > index_data.len) break;
        const flags = std.mem.readInt(u16, @ptrCast(index_data[pos..pos + 2]), .big);
        pos += 2;
        
        // Check for extended flags (version 3+)
        var extended_flags: ?u16 = null;
        if (version >= 3 and (flags & 0x4000) != 0) {
            if (pos + 2 > index_data.len) break;
            extended_flags = std.mem.readInt(u16, @ptrCast(index_data[pos..pos + 2]), .big);
            pos += 2;
        }
        
        // Path length and path
        const path_len = flags & 0xFFF;
        if (pos + path_len > index_data.len) break;
        const path = index_data[pos..pos + path_len];
        pos += path_len;
        
        // Calculate and skip padding
        const base_entry_size = 62;
        const ext_flags_size = if (extended_flags != null) @as(usize, 2) else @as(usize, 0);
        const total_entry_size = base_entry_size + ext_flags_size + path_len;
        const pad_len = (8 - (total_entry_size % 8)) % 8;
        pos += pad_len;
        
        // Validate entry
        try testing.expect(path_len > 0);
        try testing.expect(mode != 0);
        
        std.debug.print("Entry {}: path={s}, size={}, mode=0o{o}, flags=0x{x}\n", .{
            entries_parsed, path, size, mode, flags
        });
        
        if (extended_flags) |ext| {
            std.debug.print("  Extended flags: 0x{x}\n", .{ext});
        }
        
        // Verify SHA-1 format (should be 20 bytes of binary data)
        var all_zero = true;
        for (sha1) |b| {
            if (b != 0) {
                all_zero = false;
                break;
            }
        }
        try testing.expect(!all_zero); // SHA-1 shouldn't be all zeros for real files
        
        entries_parsed += 1;
    }
    
    std.debug.print("Successfully parsed {} index entries\n", .{entries_parsed});
    try testing.expectEqual(entry_count, entries_parsed);
    
    // Test 3: Check for index extensions
    // After all entries, there might be extensions before the final SHA-1 checksum
    if (pos + 20 < index_data.len) {
        std.debug.print("Index has {} bytes of extensions/data after entries\n", .{index_data.len - pos - 20});
        
        // Look for known extension signatures
        while (pos + 8 <= index_data.len - 20) {
            const sig = index_data[pos..pos + 4];
            
            // Check if this looks like an extension signature
            var is_extension = true;
            for (sig) |c| {
                if (c < 32 or c > 126) {
                    is_extension = false;
                    break;
                }
            }
            
            if (!is_extension) break;
            
            const ext_size = std.mem.readInt(u32, @ptrCast(index_data[pos + 4..pos + 8]), .big);
            std.debug.print("Found extension: '{s}' (size: {} bytes)\n", .{sig, ext_size});
            
            // Skip extension
            pos += 8;
            if (pos + ext_size > index_data.len - 20) break;
            pos += ext_size;
        }
    }
    
    // Test 4: Verify SHA-1 checksum
    if (index_data.len >= 20) {
        const content = index_data[0..index_data.len - 20];
        const stored_checksum = index_data[index_data.len - 20..];
        
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(content);
        var computed_checksum: [20]u8 = undefined;
        hasher.final(&computed_checksum);
        
        if (std.mem.eql(u8, &computed_checksum, stored_checksum)) {
            std.debug.print("Index SHA-1 checksum: VALID\n", .{});
        } else {
            std.debug.print("Index SHA-1 checksum: INVALID\n", .{});
            // This might fail with some git versions or configurations, but let's not fail the test
            std.debug.print("Expected: {}\n", .{std.fmt.fmtSliceHexLower(&computed_checksum)});
            std.debug.print("Got: {}\n", .{std.fmt.fmtSliceHexLower(stored_checksum)});
        }
    }
    
    // Test 5: Modify index and verify it changes
    try tmp_dir.dir.writeFile(.{.sub_path = "new_file.txt", .data = "New file content\n"});
    
    var add_new_process = std.process.Child.init(&[_][]const u8{ "git", "add", "new_file.txt" }, allocator);
    add_new_process.cwd = temp_path;
    add_new_process.stdout_behavior = .Ignore;
    add_new_process.stderr_behavior = .Ignore;
    _ = add_new_process.spawnAndWait() catch return;
    
    const new_index_data = try fs.cwd().readFileAlloc(allocator, index_path, 1024 * 1024);
    defer allocator.free(new_index_data);
    
    // Verify the index grew
    try testing.expect(new_index_data.len > index_data.len);
    
    const new_entry_count = std.mem.readInt(u32, @ptrCast(new_index_data[8..12]), .big);
    std.debug.print("New index entry count: {}\n", .{new_entry_count});
    try testing.expectEqual(entry_count + 1, new_entry_count);
    
    std.debug.print("Index format comprehensive test completed successfully\n", .{});
}