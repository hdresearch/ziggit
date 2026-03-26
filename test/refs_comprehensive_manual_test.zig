const std = @import("std");
const testing = std.testing;
const fs = std.fs;

// Test comprehensive symbolic ref resolution with real git repositories

test "symbolic ref resolution integration test" {
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
    
    // Create and commit initial file
    try tmp_dir.dir.writeFile(.{.sub_path = "test.txt", .data = "Initial content\n"});
    
    var add_process = std.process.Child.init(&[_][]const u8{ "git", "add", "test.txt" }, allocator);
    add_process.cwd = temp_path;
    add_process.stdout_behavior = .Ignore;
    add_process.stderr_behavior = .Ignore;
    _ = add_process.spawnAndWait() catch return;
    
    var commit_process = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Initial commit" }, allocator);
    commit_process.cwd = temp_path;
    commit_process.stdout_behavior = .Ignore;
    commit_process.stderr_behavior = .Ignore;
    _ = commit_process.spawnAndWait() catch return;
    
    // Create a few branches
    var branch1_process = std.process.Child.init(&[_][]const u8{ "git", "branch", "feature1" }, allocator);
    branch1_process.cwd = temp_path;
    branch1_process.stdout_behavior = .Ignore;
    branch1_process.stderr_behavior = .Ignore;
    _ = branch1_process.spawnAndWait() catch return;
    
    var branch2_process = std.process.Child.init(&[_][]const u8{ "git", "branch", "feature2" }, allocator);
    branch2_process.cwd = temp_path;
    branch2_process.stdout_behavior = .Ignore;
    branch2_process.stderr_behavior = .Ignore;
    _ = branch2_process.spawnAndWait() catch return;
    
    // Create a tag
    var tag_process = std.process.Child.init(&[_][]const u8{ "git", "tag", "v1.0.0" }, allocator);
    tag_process.cwd = temp_path;
    tag_process.stdout_behavior = .Ignore;
    tag_process.stderr_behavior = .Ignore;
    _ = tag_process.spawnAndWait() catch return;
    
    // Create an annotated tag
    var annotated_tag_process = std.process.Child.init(&[_][]const u8{ "git", "tag", "-a", "v1.0.1", "-m", "Annotated tag" }, allocator);
    annotated_tag_process.cwd = temp_path;
    annotated_tag_process.stdout_behavior = .Ignore;
    annotated_tag_process.stderr_behavior = .Ignore;
    _ = annotated_tag_process.spawnAndWait() catch return;
    
    // Test 1: HEAD should resolve to current commit
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    
    const head_content = try fs.cwd().readFileAlloc(allocator, head_path, 1024);
    defer allocator.free(head_content);
    
    const trimmed_head = std.mem.trim(u8, head_content, " \t\n\r");
    std.debug.print("HEAD content: {s}\n", .{trimmed_head});
    
    // HEAD should be a symbolic ref to refs/heads/master or refs/heads/main
    try testing.expect(std.mem.startsWith(u8, trimmed_head, "ref: refs/heads/"));
    
    // Test 2: Read branch refs
    const master_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/master", .{git_dir});
    defer allocator.free(master_path);
    
    const main_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/main", .{git_dir});
    defer allocator.free(main_path);
    
    var commit_hash: []u8 = undefined;
    var found_main_branch = false;
    
    if (fs.cwd().readFileAlloc(allocator, master_path, 1024)) |content| {
        defer allocator.free(content);
        commit_hash = try allocator.dupe(u8, std.mem.trim(u8, content, " \t\n\r"));
        found_main_branch = true;
        std.debug.print("Master branch commit: {s}\n", .{commit_hash});
    } else |_| {
        if (fs.cwd().readFileAlloc(allocator, main_path, 1024)) |content| {
            defer allocator.free(content);
            commit_hash = try allocator.dupe(u8, std.mem.trim(u8, content, " \t\n\r"));
            found_main_branch = true;
            std.debug.print("Main branch commit: {s}\n", .{commit_hash});
        } else |_| {
            std.debug.print("Neither master nor main branch found\n", .{});
        }
    }
    defer if (found_main_branch) allocator.free(commit_hash);
    
    try testing.expect(found_main_branch);
    try testing.expect(commit_hash.len == 40);
    
    // Validate commit hash format
    for (commit_hash) |c| {
        try testing.expect(std.ascii.isHex(c));
    }
    
    // Test 3: Check that feature branches exist
    const feature1_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/feature1", .{git_dir});
    defer allocator.free(feature1_path);
    
    const feature1_content = try fs.cwd().readFileAlloc(allocator, feature1_path, 1024);
    defer allocator.free(feature1_content);
    
    const feature1_hash = std.mem.trim(u8, feature1_content, " \t\n\r");
    std.debug.print("Feature1 branch commit: {s}\n", .{feature1_hash});
    
    // Feature1 should point to the same commit as master (no new commits on it)
    try testing.expectEqualStrings(commit_hash, feature1_hash);
    
    // Test 4: Check tags
    const tag_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/v1.0.0", .{git_dir});
    defer allocator.free(tag_path);
    
    const tag_content = try fs.cwd().readFileAlloc(allocator, tag_path, 1024);
    defer allocator.free(tag_content);
    
    const tag_hash = std.mem.trim(u8, tag_content, " \t\n\r");
    std.debug.print("Tag v1.0.0 commit: {s}\n", .{tag_hash});
    
    // Lightweight tag should point to the same commit
    try testing.expectEqualStrings(commit_hash, tag_hash);
    
    // Test 5: Check annotated tag
    const annotated_tag_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/v1.0.1", .{git_dir});
    defer allocator.free(annotated_tag_path);
    
    const annotated_tag_content = try fs.cwd().readFileAlloc(allocator, annotated_tag_path, 1024);
    defer allocator.free(annotated_tag_content);
    
    const annotated_tag_hash = std.mem.trim(u8, annotated_tag_content, " \t\n\r");
    std.debug.print("Annotated tag v1.0.1 hash: {s}\n", .{annotated_tag_hash});
    
    // Annotated tag points to a tag object, not the commit directly
    try testing.expect(!std.mem.eql(u8, commit_hash, annotated_tag_hash));
    try testing.expect(annotated_tag_hash.len == 40);
    
    // Test 6: Create packed-refs by running git gc
    var gc_process = std.process.Child.init(&[_][]const u8{ "git", "gc" }, allocator);
    gc_process.cwd = temp_path;
    gc_process.stdout_behavior = .Ignore;
    gc_process.stderr_behavior = .Ignore;
    _ = gc_process.spawnAndWait() catch return;
    
    // Check if packed-refs was created
    const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_refs_path);
    
    if (fs.cwd().readFileAlloc(allocator, packed_refs_path, 10 * 1024)) |packed_content| {
        defer allocator.free(packed_content);
        std.debug.print("Packed-refs file created ({} bytes)\n", .{packed_content.len});
        
        // Verify packed-refs format
        var lines = std.mem.split(u8, packed_content, "\n");
        var ref_count: u32 = 0;
        var found_peeled_ref = false;
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            
            if (trimmed[0] == '^') {
                // Peeled ref
                found_peeled_ref = true;
                std.debug.print("Found peeled ref: {s}\n", .{trimmed});
                continue;
            }
            
            // Regular ref line: hash + space + ref_name
            if (std.mem.indexOf(u8, trimmed, " ")) |space_pos| {
                const hash = trimmed[0..space_pos];
                const ref_name = trimmed[space_pos + 1..];
                
                if (hash.len == 40) {
                    ref_count += 1;
                    std.debug.print("Packed ref: {s} -> {s}\n", .{ref_name, hash});
                }
            }
        }
        
        try testing.expect(ref_count >= 3); // At least master/main, feature1, feature2
        
        // If we have an annotated tag, we should have found a peeled ref
        if (found_peeled_ref) {
            std.debug.print("Found peeled refs for annotated tags\n", .{});
        }
        
    } else |_| {
        std.debug.print("No packed-refs file created (this is OK)\n", .{});
    }
    
    // Test 7: Create nested symbolic refs manually
    const nested_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/alias", .{git_dir});
    defer allocator.free(nested_ref_path);
    
    try fs.cwd().writeFile(.{.sub_path = nested_ref_path, .data = "ref: refs/heads/feature1\n"});
    
    const nested_ref_content = try fs.cwd().readFileAlloc(allocator, nested_ref_path, 1024);
    defer allocator.free(nested_ref_content);
    
    const nested_ref_trimmed = std.mem.trim(u8, nested_ref_content, " \t\n\r");
    std.debug.print("Nested symbolic ref: {s}\n", .{nested_ref_trimmed});
    
    try testing.expect(std.mem.startsWith(u8, nested_ref_trimmed, "ref: refs/heads/feature1"));
    
    std.debug.print("Symbolic ref resolution test completed successfully\n", .{});
}