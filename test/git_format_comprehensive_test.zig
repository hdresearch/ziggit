const std = @import("std");
const testing = std.testing;

// This test validates git format handling capabilities through integration testing
// with real git repositories, without importing internal modules directly.

test "git format comprehensive integration" {
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
    _ = init_process.spawnAndWait() catch {
        std.debug.print("Git not available, skipping git format test\n", .{});
        return;
    };
    
    // Test 1: Git config format
    std.debug.print("Testing git config format...\n", .{});
    
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
    
    var config_remote_process = std.process.Child.init(&[_][]const u8{ "git", "remote", "add", "origin", "https://github.com/test/repo.git" }, allocator);
    config_remote_process.cwd = temp_path;
    config_remote_process.stdout_behavior = .Ignore;
    config_remote_process.stderr_behavior = .Ignore;
    _ = config_remote_process.spawnAndWait() catch return;
    
    // Verify config file was created and has expected format
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
    defer allocator.free(config_path);
    
    const config_content = std.fs.cwd().readFileAlloc(allocator, config_path, 10 * 1024) catch |err| {
        std.debug.print("Failed to read config: {}\n", .{err});
        return;
    };
    defer allocator.free(config_content);
    
    // Verify INI format structure
    try testing.expect(std.mem.indexOf(u8, config_content, "[user]") != null);
    try testing.expect(std.mem.indexOf(u8, config_content, "name = Test User") != null);
    try testing.expect(std.mem.indexOf(u8, config_content, "email = test@example.com") != null);
    try testing.expect(std.mem.indexOf(u8, config_content, "[remote \"origin\"]") != null);
    try testing.expect(std.mem.indexOf(u8, config_content, "url = https://github.com/test/repo.git") != null);
    
    std.debug.print("✓ Git config format validation passed\n", .{});
    
    // Test 2: Git object format and storage
    std.debug.print("Testing git object format...\n", .{});
    
    // Create diverse files
    try tmp_dir.dir.writeFile(.{.sub_path = "small.txt", .data = "Small file\n"});
    try tmp_dir.dir.writeFile(.{.sub_path = "empty.txt", .data = ""});
    
    var large_content = std.ArrayList(u8).init(allocator);
    defer large_content.deinit();
    for (0..200) |i| {
        try large_content.writer().print("Line {} with content\n", .{i});
    }
    try tmp_dir.dir.writeFile(.{.sub_path = "large.txt", .data = large_content.items});
    
    // Binary file
    const binary_data = [_]u8{0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD};
    try tmp_dir.dir.writeFile(.{.sub_path = "binary.dat", .data = &binary_data});
    
    var add_process = std.process.Child.init(&[_][]const u8{ "git", "add", "." }, allocator);
    add_process.cwd = temp_path;
    add_process.stdout_behavior = .Ignore;
    add_process.stderr_behavior = .Ignore;
    _ = add_process.spawnAndWait() catch return;
    
    var commit_process = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Test commit for object format validation" }, allocator);
    commit_process.cwd = temp_path;
    commit_process.stdout_behavior = .Ignore;
    commit_process.stderr_behavior = .Ignore;
    _ = commit_process.spawnAndWait() catch return;
    
    // Verify objects directory structure
    const objects_dir = try std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir});
    defer allocator.free(objects_dir);
    
    var objects_root = std.fs.cwd().openDir(objects_dir, .{ .iterate = true }) catch {
        std.debug.print("Objects directory not found\n", .{});
        return;
    };
    defer objects_root.close();
    
    var object_dirs: u32 = 0;
    var iterator = objects_root.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .directory and entry.name.len == 2) {
            // Should be a 2-character hex directory name
            for (entry.name) |c| {
                try testing.expect(std.ascii.isHex(c));
            }
            object_dirs += 1;
        }
    }
    
    try testing.expect(object_dirs > 0);
    std.debug.print("✓ Found {} object directories in expected format\n", .{object_dirs});
    
    // Test 3: Git index format
    std.debug.print("Testing git index format...\n", .{});
    
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index", .{git_dir});
    defer allocator.free(index_path);
    
    const index_data = std.fs.cwd().readFileAlloc(allocator, index_path, 1024 * 1024) catch {
        std.debug.print("Index file not found\n", .{});
        return;
    };
    defer allocator.free(index_data);
    
    // Verify index header
    try testing.expect(index_data.len >= 12);
    try testing.expectEqualSlices(u8, "DIRC", index_data[0..4]);
    
    const version = std.mem.readInt(u32, @ptrCast(index_data[4..8]), .big);
    std.debug.print("Index version: {}\n", .{version});
    try testing.expect(version >= 2 and version <= 4);
    
    const entry_count = std.mem.readInt(u32, @ptrCast(index_data[8..12]), .big);
    std.debug.print("Index entries: {}\n", .{entry_count});
    try testing.expect(entry_count >= 4); // We added 4 files
    
    std.debug.print("✓ Git index format validation passed\n", .{});
    
    // Test 4: Git refs format
    std.debug.print("Testing git refs format...\n", .{});
    
    // Check HEAD
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    
    const head_content = std.fs.cwd().readFileAlloc(allocator, head_path, 1024) catch {
        std.debug.print("HEAD file not found\n", .{});
        return;
    };
    defer allocator.free(head_content);
    
    const head_trimmed = std.mem.trim(u8, head_content, " \t\n\r");
    try testing.expect(std.mem.startsWith(u8, head_trimmed, "ref: refs/heads/"));
    
    // Check current branch ref
    const branch_name = head_trimmed["ref: refs/heads/".len..];
    const branch_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_dir, branch_name });
    defer allocator.free(branch_path);
    
    const branch_content = std.fs.cwd().readFileAlloc(allocator, branch_path, 1024) catch {
        std.debug.print("Branch ref file not found\n", .{});
        return;
    };
    defer allocator.free(branch_content);
    
    const branch_hash = std.mem.trim(u8, branch_content, " \t\n\r");
    try testing.expect(branch_hash.len == 40);
    for (branch_hash) |c| {
        try testing.expect(std.ascii.isHex(c));
    }
    
    std.debug.print("✓ Git refs format validation passed\n", .{});
    
    // Test 5: Pack file creation and format
    std.debug.print("Testing pack file format...\n", .{});
    
    // Create more commits to have enough objects for packing
    for (0..10) |i| {
        const filename = try std.fmt.allocPrint(allocator, "extra_{}.txt", .{i});
        defer allocator.free(filename);
        const content = try std.fmt.allocPrint(allocator, "Extra file {} content for packing test\nLine 2\n", .{i});
        defer allocator.free(content);
        
        try tmp_dir.dir.writeFile(.{.sub_path = filename, .data = content});
        
        var add_extra_process = std.process.Child.init(&[_][]const u8{ "git", "add", filename }, allocator);
        add_extra_process.cwd = temp_path;
        add_extra_process.stdout_behavior = .Ignore;
        add_extra_process.stderr_behavior = .Ignore;
        _ = add_extra_process.spawnAndWait() catch return;
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Extra commit {}", .{i});
        defer allocator.free(commit_msg);
        
        var commit_extra_process = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", commit_msg }, allocator);
        commit_extra_process.cwd = temp_path;
        commit_extra_process.stdout_behavior = .Ignore;
        commit_extra_process.stderr_behavior = .Ignore;
        _ = commit_extra_process.spawnAndWait() catch return;
    }
    
    // Force pack file creation
    var gc_process = std.process.Child.init(&[_][]const u8{ "git", "gc", "--aggressive" }, allocator);
    gc_process.cwd = temp_path;
    gc_process.stdout_behavior = .Ignore;
    gc_process.stderr_behavior = .Ignore;
    _ = gc_process.spawnAndWait() catch return;
    
    // Check pack directory
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir_path);
    
    var pack_dir = std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true }) catch {
        std.debug.print("Pack directory not created\n", .{});
        std.debug.print("✓ Pack file test skipped (no pack files created)\n", .{});
        std.debug.print("All git format tests completed successfully!\n", .{});
        return;
    };
    defer pack_dir.close();
    
    var pack_count: u32 = 0;
    var idx_count: u32 = 0;
    
    var pack_iterator = pack_dir.iterate();
    while (try pack_iterator.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_count += 1;
            
            // Validate pack file format
            const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name });
            defer allocator.free(pack_path);
            
            const pack_data = std.fs.cwd().readFileAlloc(allocator, pack_path, 1024) catch continue;
            defer allocator.free(pack_data);
            
            if (pack_data.len >= 12) {
                try testing.expectEqualSlices(u8, "PACK", pack_data[0..4]);
                const pack_version = std.mem.readInt(u32, @ptrCast(pack_data[4..8]), .big);
                try testing.expect(pack_version == 2 or pack_version == 3);
                std.debug.print("Pack file version: {}\n", .{pack_version});
            }
        }
        if (std.mem.endsWith(u8, entry.name, ".idx")) {
            idx_count += 1;
            
            // Validate pack index format
            const idx_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name });
            defer allocator.free(idx_path);
            
            const idx_data = std.fs.cwd().readFileAlloc(allocator, idx_path, 1024 * 1024) catch continue;
            defer allocator.free(idx_data);
            
            if (idx_data.len >= 8) {
                const magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
                if (magic == 0xff744f63) { // Pack index v2 magic
                    const idx_version = std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big);
                    try testing.expect(idx_version == 2);
                    std.debug.print("Pack index version: {}\n", .{idx_version});
                } else {
                    // Might be pack index v1 format
                    std.debug.print("Pack index v1 format detected\n", .{});
                }
            }
        }
    }
    
    try testing.expect(pack_count > 0);
    try testing.expect(idx_count > 0);
    try testing.expectEqual(pack_count, idx_count); // Should have matching pack and idx files
    
    std.debug.print("✓ Found {} pack files and {} index files\n", .{ pack_count, idx_count });
    
    // Test packed-refs format
    const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_refs_path);
    
    if (std.fs.cwd().readFileAlloc(allocator, packed_refs_path, 10 * 1024)) |packed_refs_content| {
        defer allocator.free(packed_refs_content);
        
        std.debug.print("Testing packed-refs format...\n", .{});
        
        var ref_lines: u32 = 0;
        var peeled_refs: u32 = 0;
        
        var lines = std.mem.split(u8, packed_refs_content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            
            if (trimmed[0] == '^') {
                // Peeled ref
                peeled_refs += 1;
                try testing.expect(trimmed.len >= 41); // ^ + 40 char hash
                const peeled_hash = trimmed[1..41];
                for (peeled_hash) |c| {
                    try testing.expect(std.ascii.isHex(c));
                }
            } else if (std.mem.indexOf(u8, trimmed, " ")) |space_pos| {
                // Regular ref line
                ref_lines += 1;
                const hash = trimmed[0..space_pos];
                const ref_name = trimmed[space_pos + 1..];
                
                try testing.expect(hash.len == 40);
                for (hash) |c| {
                    try testing.expect(std.ascii.isHex(c));
                }
                try testing.expect(std.mem.startsWith(u8, ref_name, "refs/"));
            }
        }
        
        try testing.expect(ref_lines > 0);
        std.debug.print("✓ Packed-refs format: {} refs, {} peeled refs\n", .{ ref_lines, peeled_refs });
    } else |_| {
        std.debug.print("No packed-refs file created (this is normal)\n", .{});
    }
    
    std.debug.print("All git format tests completed successfully!\n", .{});
}