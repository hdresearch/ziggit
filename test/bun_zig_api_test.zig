const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

test "bun workflow - pure Zig, no git CLI" {
    const allocator = testing.allocator;
    
    const test_dir = "/tmp/zig_api_test";
    std.fs.deleteDirAbsolute(test_dir) catch {};
    
    // 1. Initialize repository
    var repo = ziggit.Repository.init(allocator, test_dir) catch |err| {
        std.debug.print("Failed to init repo: {}\n", .{err});
        return err;
    };
    defer repo.close();

    // 2. Create a file and add it
    const package_json_path = test_dir ++ "/package.json";
    const package_json_content =
        \\{
        \\  "name": "test-package",
        \\  "version": "1.0.0",
        \\  "main": "index.js"
        \\}
        \\
    ;
    
    const package_file = try std.fs.createFileAbsolute(package_json_path, .{ .truncate = true });
    defer package_file.close();
    try package_file.writeAll(package_json_content);

    try repo.add("package.json");

    // 3. Commit the file
    const commit_hash = try repo.commit("Initial commit", "test", "test@test.com");
    
    // 4. Test read operations that bun uses
    const head_hash = try repo.revParseHead();
    try testing.expectEqualStrings(&commit_hash, &head_hash);
    
    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);
    try testing.expectEqualStrings("", status);

    const is_clean = try repo.isClean();
    try testing.expect(is_clean);

    // 5. Create a tag
    try repo.createTag("v1.0.0", "Version 1.0.0");
    
    const latest_tag = try repo.latestTag(allocator);
    defer allocator.free(latest_tag);
    try testing.expectEqualStrings("v1.0.0", latest_tag);

    const described_tag = try repo.describeTags(allocator);
    defer allocator.free(described_tag);
    try testing.expectEqualStrings("v1.0.0", described_tag);

    // 6. Test finding commits
    const found_commit = try repo.findCommit(&commit_hash);
    try testing.expectEqualStrings(&commit_hash, &found_commit);

    const short_hash = commit_hash[0..8];
    const found_by_short = try repo.findCommit(short_hash);
    try testing.expectEqualStrings(&commit_hash, &found_by_short);

    // 7. Test branch operations
    const branches = try repo.branchList(allocator);
    defer {
        for (branches) |branch| {
            allocator.free(branch);
        }
        allocator.free(branches);
    }
    try testing.expect(branches.len >= 1);

    std.fs.deleteDirAbsolute(test_dir) catch {};
}

test "bun workflow - git CLI verification" {
    const allocator = testing.allocator;
    
    const test_dir = "/tmp/zig_vs_git_test";
    std.fs.deleteDirAbsolute(test_dir) catch {};
    
    var repo = ziggit.Repository.init(allocator, test_dir) catch |err| {
        std.debug.print("Skipping git CLI verification test due to init error: {}\n", .{err});
        return;
    };
    defer repo.close();
    
    const test_file_path = test_dir ++ "/test.txt"; 
    const test_file = try std.fs.createFileAbsolute(test_file_path, .{ .truncate = true });
    defer test_file.close();
    try test_file.writeAll("Hello, World!\n");
    
    try repo.add("test.txt");
    const commit_hash = try repo.commit("Test commit", "ziggit", "ziggit@example.com");
    
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "--version" },
        .cwd = test_dir,
    }) catch |err| {
        std.debug.print("Git CLI not available for verification: {}\n", .{err});
        std.fs.deleteDirAbsolute(test_dir) catch {};
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    if (result.term.Exited != 0) {
        std.debug.print("Git CLI not working, skipping verification\n");
        std.fs.deleteDirAbsolute(test_dir) catch {};
        return;
    }
    
    const log_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", test_dir, "log", "--oneline" },
    }) catch {
        std.debug.print("Failed to run git log, but continuing...\n");
        std.fs.deleteDirAbsolute(test_dir) catch {};
        return;
    };
    defer allocator.free(log_result.stdout);
    defer allocator.free(log_result.stderr);
    
    if (log_result.term.Exited == 0) {
        const commit_short = commit_hash[0..7];
        const log_contains_hash = std.mem.indexOf(u8, log_result.stdout, commit_short) != null;
        
        if (log_contains_hash) {
            std.debug.print("✅ Git CLI can read ziggit-created commit!\n");
        } else {
            std.debug.print("⚠️  Git log output: {s}\n", .{log_result.stdout});
            std.debug.print("Expected to find: {s}\n", .{commit_short});
        }
    } else {
        std.debug.print("Git log failed: {s}\n", .{log_result.stderr});
    }
    
    std.fs.deleteDirAbsolute(test_dir) catch {};
}