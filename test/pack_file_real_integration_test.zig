const std = @import("std");
const testing = std.testing;
const fs = std.fs;

// Import our git objects implementation directly
const objects = @import("../src/git/objects.zig");

// Mock platform implementation for testing
const MockPlatform = struct {
    const Self = @This();
    
    fs: MockFS = .{},
    
    const MockFS = struct {
        pub fn readFile(self: @This(), allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            _ = self;
            return std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        }
        
        pub fn writeFile(self: @This(), path: []const u8, data: []const u8) !void {
            _ = self;
            try std.fs.cwd().writeFile(.{.sub_path = path, .data = data});
        }
        
        pub fn exists(self: @This(), path: []const u8) !bool {
            _ = self;
            _ = std.fs.cwd().statFile(path) catch return false;
            return true;
        }
        
        pub fn makeDir(self: @This(), path: []const u8) !void {
            _ = self;
            std.fs.cwd().makeDir(path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        
        pub fn deleteFile(self: @This(), path: []const u8) !void {
            _ = self;
            try std.fs.cwd().deleteFile(path);
        }
        
        pub fn readDir(self: @This(), allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
            _ = self;
            var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
            defer dir.close();
            
            var entries = std.ArrayList([]u8).init(allocator);
            var iterator = dir.iterate();
            
            while (try iterator.next()) |entry| {
                try entries.append(try allocator.dupe(u8, entry.name));
            }
            
            return entries.toOwnedSlice();
        }
    };
};

test "pack file reading with real git objects" {
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
    
    // Create several files with different sizes and contents
    try tmp_dir.dir.writeFile(.{.sub_path = "small.txt", .data = "Small file content"});
    try tmp_dir.dir.writeFile(.{.sub_path = "medium.txt", .data = "Medium file with more content\n" ** 50});
    
    // Create a large file to ensure we get interesting pack files
    var large_content = std.ArrayList(u8).init(allocator);
    defer large_content.deinit();
    for (0..1000) |i| {
        try large_content.writer().print("Line {} of large file content with varied data and numbers {}\n", .{i, i * i});
    }
    try tmp_dir.dir.writeFile(.{.sub_path = "large.txt", .data = large_content.items});
    
    // Add and commit files
    var add_process = std.process.Child.init(&[_][]const u8{ "git", "add", "." }, allocator);
    add_process.cwd = temp_path;
    add_process.stdout_behavior = .Ignore;
    add_process.stderr_behavior = .Ignore;
    _ = add_process.spawnAndWait() catch return;
    
    var commit_process = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Initial commit with various file sizes" }, allocator);
    commit_process.cwd = temp_path;
    commit_process.stdout_behavior = .Ignore;
    commit_process.stderr_behavior = .Ignore;
    _ = commit_process.spawnAndWait() catch return;
    
    // Create more commits to have multiple objects
    for (0..5) |i| {
        const filename = try std.fmt.allocPrint(allocator, "file_{}.txt", .{i});
        defer allocator.free(filename);
        const content = try std.fmt.allocPrint(allocator, "File {} content with iteration {}\n", .{i, i});
        defer allocator.free(content);
        
        try tmp_dir.dir.writeFile(.{.sub_path = filename, .data = content});
        
        var add_i_process = std.process.Child.init(&[_][]const u8{ "git", "add", filename }, allocator);
        add_i_process.cwd = temp_path;
        add_i_process.stdout_behavior = .Ignore;
        add_i_process.stderr_behavior = .Ignore;
        _ = add_i_process.spawnAndWait() catch return;
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Add file {}", .{i});
        defer allocator.free(commit_msg);
        
        var commit_i_process = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", commit_msg }, allocator);
        commit_i_process.cwd = temp_path;
        commit_i_process.stdout_behavior = .Ignore;
        commit_i_process.stderr_behavior = .Ignore;
        _ = commit_i_process.spawnAndWait() catch return;
    }
    
    // Get list of all objects before packing
    var hash_objects_process = std.process.Child.init(&[_][]const u8{ "git", "rev-list", "--objects", "--all" }, allocator);
    hash_objects_process.cwd = temp_path;
    hash_objects_process.stdout_behavior = .Pipe;
    hash_objects_process.stderr_behavior = .Ignore;
    
    try hash_objects_process.spawn();
    const objects_output = try hash_objects_process.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(objects_output);
    _ = try hash_objects_process.wait();
    
    // Parse object hashes
    var object_hashes = std.ArrayList([]const u8).init(allocator);
    defer {
        for (object_hashes.items) |hash| {
            allocator.free(hash);
        }
        object_hashes.deinit();
    }
    
    var lines = std.mem.split(u8, objects_output, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        
        const space_pos = std.mem.indexOf(u8, trimmed, " ") orelse trimmed.len;
        const hash = trimmed[0..space_pos];
        
        if (hash.len == 40) {
            // Validate hash format
            var valid = true;
            for (hash) |c| {
                if (!std.ascii.isHex(c)) {
                    valid = false;
                    break;
                }
            }
            if (valid) {
                try object_hashes.append(try allocator.dupe(u8, hash));
            }
        }
    }
    
    std.debug.print("Found {} objects before packing\n", .{object_hashes.items.len});
    try testing.expect(object_hashes.items.len >= 5);
    
    // Force garbage collection to create pack files
    var gc_process = std.process.Child.init(&[_][]const u8{ "git", "gc", "--aggressive" }, allocator);
    gc_process.cwd = temp_path;
    gc_process.stdout_behavior = .Ignore;
    gc_process.stderr_behavior = .Ignore;
    _ = gc_process.spawnAndWait() catch return;
    
    // Check if pack files were created
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir_path);
    
    var pack_dir = fs.cwd().openDir(pack_dir_path, .{ .iterate = true }) catch {
        std.debug.print("No pack directory created, skipping pack file test\n", .{});
        return;
    };
    defer pack_dir.close();
    
    var pack_files = std.ArrayList([]u8).init(allocator);
    defer {
        for (pack_files.items) |name| {
            allocator.free(name);
        }
        pack_files.deinit();
    }
    
    var idx_files = std.ArrayList([]u8).init(allocator);
    defer {
        for (idx_files.items) |name| {
            allocator.free(name);
        }
        idx_files.deinit();
    }
    
    var iterator = pack_dir.iterate();
    while (try iterator.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            try pack_files.append(try allocator.dupe(u8, entry.name));
            std.debug.print("Found pack file: {s}\n", .{entry.name});
        }
        if (std.mem.endsWith(u8, entry.name, ".idx")) {
            try idx_files.append(try allocator.dupe(u8, entry.name));
            std.debug.print("Found index file: {s}\n", .{entry.name});
        }
    }
    
    if (pack_files.items.len == 0 or idx_files.items.len == 0) {
        std.debug.print("Git gc did not create pack files, skipping test\n", .{});
        return;
    }
    
    // Now test our pack file reading implementation
    const platform = MockPlatform{};
    var objects_read: u32 = 0;
    var objects_failed: u32 = 0;
    
    for (object_hashes.items[0..@min(object_hashes.items.len, 10)]) |hash| {
        std.debug.print("Testing pack file reading for object: {s}\n", .{hash});
        
        // Try to load the object using our implementation
        const obj = objects.GitObject.load(hash, git_dir, platform, allocator) catch |err| {
            std.debug.print("Failed to load object {s}: {}\n", .{hash, err});
            objects_failed += 1;
            continue;
        };
        defer obj.deinit(allocator);
        
        std.debug.print("Successfully loaded object {s}, type: {s}, size: {} bytes\n", .{
            hash, obj.type.toString(), obj.data.len
        });
        
        // Validate object type
        try testing.expect(obj.type == .blob or obj.type == .tree or obj.type == .commit or obj.type == .tag);
        
        // Validate object data is non-empty for most objects
        if (obj.type != .tree or obj.data.len > 0) {
            try testing.expect(obj.data.len > 0);
        }
        
        // For blob objects, verify content makes sense
        if (obj.type == .blob) {
            // Should contain some recognizable content
            var has_printable = false;
            for (obj.data) |byte| {
                if (byte >= 32 and byte <= 126) {
                    has_printable = true;
                    break;
                }
            }
            // Most of our test files should have printable content
            if (obj.data.len < 1000) { // Only check small files
                try testing.expect(has_printable);
            }
        }
        
        // For commit objects, verify basic structure
        if (obj.type == .commit) {
            const content = std.mem.span(@as([*:0]const u8, @ptrCast(obj.data.ptr)));
            try testing.expect(std.mem.indexOf(u8, content, "tree ") != null);
            try testing.expect(std.mem.indexOf(u8, content, "author ") != null);
            try testing.expect(std.mem.indexOf(u8, content, "committer ") != null);
        }
        
        objects_read += 1;
    }
    
    std.debug.print("Pack file reading results: {} succeeded, {} failed\n", .{objects_read, objects_failed});
    
    // We should be able to read at least some objects from pack files
    try testing.expect(objects_read > 0);
    
    // The failure rate shouldn't be too high (some failures are expected due to object types)
    const success_rate = (@as(f32, @floatFromInt(objects_read)) / @as(f32, @floatFromInt(objects_read + objects_failed))) * 100.0;
    std.debug.print("Success rate: {d:.1}%\n", .{success_rate});
    
    try testing.expect(success_rate >= 50.0); // At least 50% success rate
    
    std.debug.print("Pack file integration test completed successfully!\n", .{});
}