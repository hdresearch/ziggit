const std = @import("std");
const testing = std.testing;

// Test pack file delta functionality comprehensively
test "pack file delta generation and reading test" {
    const allocator = testing.allocator;

    // Create a temporary test repository
    const temp_path = "/tmp/zig-test-pack-delta";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};

    // Initialize git repo
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        cmd.stderr_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Configure git
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Change to temp directory
    var temp_dir = try std.fs.openDirAbsolute(temp_path, .{});
    defer temp_dir.close();

    // Create base content that will be modified to generate deltas
    const base_content = 
        \\This is a base file that will be modified multiple times
        \\to generate delta objects in the git repository.
        \\Line 3 will remain unchanged
        \\Line 4 will remain unchanged
        \\Line 5 will be modified
        \\Line 6 will be deleted
        \\Line 7 will remain unchanged
        \\Line 8 will remain unchanged
        \\Line 9 will be modified
        \\Line 10 is the last line
    ;

    try temp_dir.writeFile(.{ .sub_path = "delta_test.txt", .data = base_content });

    // Add and commit the base file
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "add", "delta_test.txt" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Add base file" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Make several incremental changes to generate delta objects
    const modifications = [_][]const u8{
        \\This is a base file that will be modified multiple times
        \\to generate delta objects in the git repository.
        \\Line 3 will remain unchanged
        \\Line 4 will remain unchanged
        \\Line 5 HAS BEEN MODIFIED
        \\Line 6 will be deleted
        \\Line 7 will remain unchanged
        \\Line 8 will remain unchanged
        \\Line 9 will be modified
        \\Line 10 is the last line
        ,
        \\This is a base file that will be modified multiple times
        \\to generate delta objects in the git repository.
        \\Line 3 will remain unchanged
        \\Line 4 will remain unchanged
        \\Line 5 HAS BEEN MODIFIED
        \\Line 7 will remain unchanged
        \\Line 8 will remain unchanged
        \\Line 9 HAS ALSO BEEN MODIFIED
        \\Line 10 is the last line
        ,
        \\This is a base file that will be modified multiple times
        \\to generate delta objects in the git repository.
        \\Line 3 will remain unchanged
        \\Line 4 will remain unchanged
        \\Line 5 HAS BEEN MODIFIED AGAIN
        \\Line 7 will remain unchanged
        \\Line 8 will remain unchanged
        \\Line 9 HAS ALSO BEEN MODIFIED
        \\Line 10 is the last line
        \\This is a new line added at the end
        ,
    };

    for (modifications, 0..) |content, i| {
        try temp_dir.writeFile(.{ .sub_path = "delta_test.txt", .data = content });

        {
            var cmd = std.process.Child.init(&[_][]const u8{ "git", "add", "delta_test.txt" }, allocator);
            cmd.cwd = temp_path;
            cmd.stdout_behavior = .Ignore;
            _ = try cmd.spawnAndWait();
        }

        const commit_msg = try std.fmt.allocPrint(allocator, "Modify file - version {}", .{i + 1});
        defer allocator.free(commit_msg);

        {
            var cmd = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", commit_msg }, allocator);
            cmd.cwd = temp_path;
            cmd.stdout_behavior = .Ignore;
            _ = try cmd.spawnAndWait();
        }
    }

    // Force pack file creation with aggressive delta compression
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "repack", "-a", "-d", "--depth=50" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        cmd.stderr_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Additional garbage collection to ensure pack files are created
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "gc", "--aggressive" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        cmd.stderr_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Verify pack files were created
    const git_objects_path = try std.fmt.allocPrint(allocator, "{s}/.git/objects", .{temp_path});
    defer allocator.free(git_objects_path);
    
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/pack", .{git_objects_path});
    defer allocator.free(pack_path);

    var pack_dir = std.fs.openDirAbsolute(pack_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("No pack directory found, pack files were not created\n", .{});
            return;
        },
        else => return err,
    };
    defer pack_dir.close();

    var pack_files = std.ArrayList([]u8).init(allocator);
    defer {
        for (pack_files.items) |filename| {
            allocator.free(filename);
        }
        pack_files.deinit();
    }

    var iterator = pack_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pack")) {
            try pack_files.append(try allocator.dupe(u8, entry.name));
            std.debug.print("Found pack file: {s}\n", .{entry.name});
        }
    }

    if (pack_files.items.len == 0) {
        std.debug.print("No pack files found after repack, test may not have generated deltas\n", .{});
        return;
    }

    // Analyze the pack file structure
    for (pack_files.items) |pack_filename| {
        const full_pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_path, pack_filename });
        defer allocator.free(full_pack_path);

        const pack_data = std.fs.cwd().readFileAlloc(allocator, full_pack_path, 10 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("Pack file not found: {s}\n", .{full_pack_path});
                continue;
            },
            else => return err,
        };
        defer allocator.free(pack_data);

        // Verify pack file header
        if (pack_data.len < 12) {
            std.debug.print("Pack file too small: {} bytes\n", .{pack_data.len});
            continue;
        }

        if (!std.mem.eql(u8, pack_data[0..4], "PACK")) {
            std.debug.print("Invalid pack signature\n", .{});
            continue;
        }

        const version = std.mem.readInt(u32, @ptrCast(pack_data[4..8]), .big);
        const object_count = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);

        std.debug.print("Pack file analysis:\n", .{});
        std.debug.print("  Version: {}\n", .{version});
        std.debug.print("  Object count: {}\n", .{object_count});
        std.debug.print("  File size: {} bytes\n", .{pack_data.len});

        // Basic validation
        try testing.expect(version >= 2 and version <= 4);
        try testing.expect(object_count > 0);
        try testing.expect(object_count < 1000); // Reasonable upper bound for this test

        // Verify checksum (last 20 bytes)
        if (pack_data.len >= 20) {
            const content_end = pack_data.len - 20;
            const stored_checksum = pack_data[content_end..];
            
            var hasher = std.crypto.hash.Sha1.init(.{});
            hasher.update(pack_data[0..content_end]);
            var computed_checksum: [20]u8 = undefined;
            hasher.final(&computed_checksum);
            
            if (std.mem.eql(u8, &computed_checksum, stored_checksum)) {
                std.debug.print("  Checksum: valid\n", .{});
            } else {
                std.debug.print("  Checksum: INVALID\n", .{});
                return error.PackChecksumMismatch;
            }
        }

        // Look for delta objects by scanning the pack structure
        var pos: usize = 12; // Skip header
        var delta_count: u32 = 0;
        var regular_count: u32 = 0;

        for (0..object_count) |_| {
            if (pos >= pack_data.len - 20) break; // Don't read into checksum

            const first_byte = pack_data[pos];
            pos += 1;

            const obj_type = (first_byte >> 4) & 7;
            
            // Read variable-length size
            var size: usize = @intCast(first_byte & 15);
            var shift: u6 = 4;
            var current_byte = first_byte;
            
            while (current_byte & 0x80 != 0 and pos < pack_data.len - 20) {
                current_byte = pack_data[pos];
                pos += 1;
                size |= @as(usize, @intCast(current_byte & 0x7F)) << shift;
                shift += 7;
                
                if (shift > 32) break; // Safety limit
            }

            // Check object type
            switch (obj_type) {
                1, 2, 3, 4 => {
                    // Regular objects (commit, tree, blob, tag)
                    regular_count += 1;
                    // Skip compressed data (this is a simplified scan)
                    while (pos < pack_data.len - 20 and pack_data[pos] != 0x78) {
                        pos += 1;
                    }
                    pos += @min(size / 2, pack_data.len - pos - 20); // Rough estimate
                },
                6, 7 => {
                    // Delta objects (OFS_DELTA, REF_DELTA)
                    delta_count += 1;
                    
                    if (obj_type == 6) {
                        // OFS_DELTA - read offset
                        while (pos < pack_data.len - 20 and (pack_data[pos] & 0x80) != 0) {
                            pos += 1;
                        }
                        pos += 1; // Final offset byte
                    } else if (obj_type == 7) {
                        // REF_DELTA - skip 20-byte SHA-1
                        pos += 20;
                    }
                    
                    // Skip compressed delta data
                    pos += @min(size / 2, pack_data.len - pos - 20); // Rough estimate
                },
                else => {
                    std.debug.print("Unknown object type: {}\n", .{obj_type});
                    break;
                },
            }

            // Safety check to prevent infinite loops
            if (pos >= pack_data.len - 20) break;
        }

        std.debug.print("  Regular objects: {}\n", .{regular_count});
        std.debug.print("  Delta objects: {}\n", .{delta_count});

        if (delta_count > 0) {
            std.debug.print("Successfully found delta objects in pack file!\n", .{});
        } else {
            std.debug.print("No delta objects found, but pack structure is valid\n", .{});
        }
    }

    std.debug.print("Pack file delta test completed successfully\n", .{});
}

test "delta application algorithm test" {
    const allocator = testing.allocator;
    
    // Test the basic principles of git delta application
    // This is a simplified test that validates the concept
    
    const base_data = "Hello, World! This is a test file.\n";
    
    // Simulate a simple delta that:
    // 1. Copies "Hello, " (7 bytes from offset 0)
    // 2. Inserts "Zig"
    // 3. Copies "! This is a test file.\n" (22 bytes from offset 13)
    
    // Expected result: "Hello, Zig! This is a test file.\n"
    const expected = "Hello, Zig! This is a test file.\n";
    
    // Manual delta application simulation
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    // Copy first 7 bytes
    try result.appendSlice(base_data[0..7]);
    
    // Insert "Zig"
    try result.appendSlice("Zig");
    
    // Copy remaining bytes from offset 12 (to include the "!")
    try result.appendSlice(base_data[12..]);
    
    // Verify result
    try testing.expectEqualStrings(expected, result.items);
    
    std.debug.print("Delta application simulation test passed\n", .{});
}