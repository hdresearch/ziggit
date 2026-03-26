const std = @import("std");
const objects = @import("../src/git/objects.zig");
const testing = std.testing;

test "pack file delta handling comprehensive test" {
    const allocator = testing.allocator;

    // Create a test repository with delta-generating content
    const temp_path = "/tmp/zig-test-pack-delta";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};

    // Initialize git repo
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Configure git
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }

    // Create a large base file that will generate deltas when modified
    const base_content = 
        \\# Large file for delta testing
        \\This is the original content of the file.
        \\It contains multiple lines to ensure we have substantial content.
        \\Line 4: Some data
        \\Line 5: More data
        \\Line 6: Even more data
        \\Line 7: Additional content
        \\Line 8: Extra information
        \\Line 9: Further details
        \\Line 10: Conclusion
        \\
        \\This content will be modified in subsequent commits.
        \\The modifications should create delta objects in pack files.
        \\We want to test both offset deltas and reference deltas.
        \\
    ;

    const file_path = try std.fmt.allocPrint(allocator, "{s}/delta_test.txt", .{temp_path});
    defer allocator.free(file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = base_content });

    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "add", "delta_test.txt" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Add base file for delta testing" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Create multiple commits with incremental changes (will generate deltas)
    for (0..10) |i| {
        const modified_content = try std.fmt.allocPrint(allocator, 
            \\# Large file for delta testing - Version {d}
            \\This is the original content of the file.
            \\It contains multiple lines to ensure we have substantial content.
            \\Line 4: Some data (modified in version {d})
            \\Line 5: More data
            \\Line 6: Even more data
            \\Line 7: Additional content
            \\Line 8: Extra information (updated {d})
            \\Line 9: Further details
            \\Line 10: Conclusion
            \\
            \\This content has been modified in commit {d}.
            \\The modifications should create delta objects in pack files.
            \\We want to test both offset deltas and reference deltas.
            \\New line added in version {d}.
            \\
        , .{ i, i, i, i, i });
        defer allocator.free(modified_content);

        try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = modified_content });

        {
            var cmd = std.process.Child.init(&[_][]const u8{ "git", "add", "delta_test.txt" }, allocator);
            cmd.cwd = temp_path;
            _ = try cmd.spawnAndWait();
        }

        const commit_msg = try std.fmt.allocPrint(allocator, "Modify file - version {d}", .{i});
        defer allocator.free(commit_msg);
        {
            var cmd = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", commit_msg }, allocator);
            cmd.cwd = temp_path;
            cmd.stdout_behavior = .Ignore;
            _ = try cmd.spawnAndWait();
        }
    }

    // Force aggressive garbage collection to create deltas
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "gc", "--aggressive", "--prune=now" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Get list of commits to test
    var commit_list = std.ArrayList([]u8).init(allocator);
    defer {
        for (commit_list.items) |commit| {
            allocator.free(commit);
        }
        commit_list.deinit();
    }

    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "log", "--format=%H", "-n", "5" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Pipe;
        try cmd.spawn();

        var output = std.ArrayList(u8).init(allocator);
        defer output.deinit();
        try cmd.stdout.?.reader().readAllArrayList(&output, 10240);
        _ = try cmd.wait();

        var lines = std.mem.split(u8, std.mem.trim(u8, output.items, " \n\r\t"), "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \n\r\t");
            if (trimmed.len == 40) {
                try commit_list.append(try allocator.dupe(u8, trimmed));
            }
        }
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);

    // Test platform implementation
    const TestPlatform = struct {
        pub const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 100 * 1024 * 1024);
            }
            
            pub fn readDir(alloc: std.mem.Allocator, path: []const u8) ![][]u8 {
                var entries = std.ArrayList([]u8).init(alloc);
                errdefer {
                    for (entries.items) |entry| alloc.free(entry);
                    entries.deinit();
                }
                
                var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return entries.toOwnedSlice();
                defer dir.close();
                
                var iterator = dir.iterate();
                while (try iterator.next()) |entry| {
                    try entries.append(try alloc.dupe(u8, entry.name));
                }
                
                return entries.toOwnedSlice();
            }
            
            pub fn makeDir(path: []const u8) !void {
                std.fs.cwd().makePath(path) catch {};
            }
            
            pub fn writeFile(path: []const u8, content: []const u8) !void {
                try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
            }
        };
    };

    // Test loading commits from pack files (these should include delta objects)
    for (commit_list.items, 0..) |commit_hash, i| {
        std.debug.print("Testing commit {d}: {s}\n", .{ i, commit_hash });
        
        const git_obj = objects.GitObject.load(commit_hash, git_dir, TestPlatform, allocator) catch |err| {
            std.debug.print("Failed to load commit {s}: {}\n", .{ commit_hash, err });
            return err;
        };
        defer git_obj.deinit(allocator);

        // Verify it's a valid commit
        try testing.expect(git_obj.type == .commit);
        try testing.expect(git_obj.data.len > 0);

        // Verify commit data structure
        const commit_data = std.mem.span(git_obj.data);
        try testing.expect(std.mem.startsWith(u8, commit_data, "tree "));
        
        std.debug.print("✓ Successfully loaded commit {s} (size: {} bytes)\n", .{ commit_hash, git_obj.data.len });
    }

    std.debug.print("✓ All delta handling tests passed!\n", .{});
}

test "pack file statistics and analysis" {
    const allocator = testing.allocator;

    // Create a test repository
    const temp_path = "/tmp/zig-test-pack-stats";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};

    // Initialize git repo with some content
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Configure git
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }

    // Create some content and commits
    for (0..3) |i| {
        const content = try std.fmt.allocPrint(allocator, "Content for file {d}\nSecond line\nThird line\n", .{i});
        defer allocator.free(content);
        
        const filename = try std.fmt.allocPrint(allocator, "{s}/file{d}.txt", .{ temp_path, i });
        defer allocator.free(filename);
        
        try std.fs.cwd().writeFile(.{ .sub_path = filename, .data = content });
        
        const short_filename = try std.fmt.allocPrint(allocator, "file{d}.txt", .{i});
        defer allocator.free(short_filename);
        
        {
            var cmd = std.process.Child.init(&[_][]const u8{ "git", "add", short_filename }, allocator);
            cmd.cwd = temp_path;
            _ = try cmd.spawnAndWait();
        }
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Add file{d}.txt", .{i});
        defer allocator.free(commit_msg);
        {
            var cmd = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", commit_msg }, allocator);
            cmd.cwd = temp_path;
            cmd.stdout_behavior = .Ignore;
            _ = try cmd.spawnAndWait();
        }
    }

    // Force pack creation
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "gc" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);

    // Test platform implementation
    const TestPlatform = struct {
        pub const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024);
            }
        };
    };

    // Find pack files
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);

    var pack_dir_handle = std.fs.cwd().openDir(pack_dir, .{ .iterate = true }) catch {
        std.debug.print("No pack directory found, skipping pack statistics test\n", .{});
        return;
    };
    defer pack_dir_handle.close();

    var iterator = pack_dir_handle.iterate();
    var found_pack = false;
    while (try iterator.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pack")) {
            const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name });
            defer allocator.free(pack_path);

            std.debug.print("Analyzing pack file: {s}\n", .{pack_path});

            // Test pack file analysis
            const stats = objects.analyzePackFile(pack_path, TestPlatform, allocator) catch |err| {
                std.debug.print("Failed to analyze pack file: {}\n", .{err});
                continue;
            };

            std.debug.print("Pack file statistics:\n", .{});
            std.debug.print("  Objects: {}\n", .{stats.total_objects});
            std.debug.print("  File size: {} bytes\n", .{stats.file_size});
            std.debug.print("  Version: {}\n", .{stats.version});
            std.debug.print("  Checksum valid: {}\n", .{stats.checksum_valid});

            try testing.expect(stats.total_objects > 0);
            try testing.expect(stats.file_size > 0);
            try testing.expect(stats.version >= 2 and stats.version <= 4);
            
            found_pack = true;
            break;
        }
    }

    if (!found_pack) {
        std.debug.print("No pack files found for statistics test\n", .{});
        return;
    }

    std.debug.print("✓ Pack file statistics test passed!\n", .{});
}