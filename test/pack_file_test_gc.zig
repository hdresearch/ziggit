const std = @import("std");
const objects = @import("../src/git/objects.zig");
const print = std.debug.print;

test "pack file reading after git gc" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a test repository and run git gc to create pack files
    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();
    
    const temp_path_buf = try allocator.alloc(u8, 256);
    defer allocator.free(temp_path_buf);
    const temp_path = try std.fmt.bufPrint(temp_path_buf, "/tmp/zig-test-{d}", .{std.time.timestamp()});
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);

    // Create temp directory
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};

    // Initialize git repo
    var init_cmd = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
    init_cmd.cwd = temp_path;
    init_cmd.stdout_behavior = .Ignore;
    init_cmd.stderr_behavior = .Ignore;
    _ = try init_cmd.spawnAndWait();

    // Configure git for testing
    var config_name_cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
    config_name_cmd.cwd = temp_path;
    config_name_cmd.stdout_behavior = .Ignore;
    _ = try config_name_cmd.spawnAndWait();

    var config_email_cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
    config_email_cmd.cwd = temp_path;
    config_email_cmd.stdout_behavior = .Ignore;
    _ = try config_email_cmd.spawnAndWait();

    // Create some test files and commits
    const test_content = "Hello, world!\nThis is test content.";
    
    const test_file_path = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{temp_path});
    defer allocator.free(test_file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = test_file_path, .data = test_content });
    
    var add_cmd = std.process.Child.init(&[_][]const u8{ "git", "add", "test.txt" }, allocator);
    add_cmd.cwd = temp_path;
    add_cmd.stdout_behavior = .Ignore;
    _ = try add_cmd.spawnAndWait();

    var commit_cmd = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Initial commit" }, allocator);
    commit_cmd.cwd = temp_path;
    commit_cmd.stdout_behavior = .Ignore;
    _ = try commit_cmd.spawnAndWait();

    // Create more commits to make gc worthwhile
    for (0..5) |i| {
        const filename = try std.fmt.allocPrint(allocator, "file{}.txt", .{i});
        defer allocator.free(filename);
        const content = try std.fmt.allocPrint(allocator, "Content for file {}", .{i});
        defer allocator.free(content);
        
        const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ temp_path, filename });
        defer allocator.free(filepath);
        try std.fs.cwd().writeFile(.{ .sub_path = filepath, .data = content });
        
        var add_cmd2 = std.process.Child.init(&[_][]const u8{ "git", "add", filename }, allocator);
        add_cmd2.cwd = temp_path;
        add_cmd2.stdout_behavior = .Ignore;
        _ = try add_cmd2.spawnAndWait();

        const commit_msg = try std.fmt.allocPrint(allocator, "Add {s}", .{filename});
        defer allocator.free(commit_msg);
        
        var commit_cmd2 = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", commit_msg }, allocator);
        commit_cmd2.cwd = temp_path;
        commit_cmd2.stdout_behavior = .Ignore;
        _ = try commit_cmd2.spawnAndWait();
    }

    // Get the current HEAD commit hash before gc
    var rev_parse = std.process.Child.init(&[_][]const u8{ "git", "rev-parse", "HEAD" }, allocator);
    rev_parse.cwd = temp_path;
    rev_parse.stdout_behavior = .Pipe;
    try rev_parse.spawn();
    
    var stdout_data = std.ArrayList(u8).init(allocator);
    defer stdout_data.deinit();
    try rev_parse.stdout.?.reader().readAllArrayList(&stdout_data, 1024);
    _ = try rev_parse.wait();
    
    const head_hash = std.mem.trim(u8, stdout_data.items, " \n\r\t");
    print("HEAD hash before gc: {s}\n", .{head_hash});

    // Force git gc to create pack files
    var gc_cmd = std.process.Child.init(&[_][]const u8{ "git", "gc", "--aggressive" }, allocator);
    gc_cmd.cwd = temp_path;
    gc_cmd.stdout_behavior = .Ignore;
    gc_cmd.stderr_behavior = .Ignore;
    _ = try gc_cmd.spawnAndWait();

    // Check if pack files were created
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);

    var pack_dir_handle = std.fs.cwd().openDir(pack_dir, .{ .iterate = true }) catch {
        print("Pack directory not found, gc might not have created pack files\n", .{});
        return; // Skip test if no pack files
    };
    defer pack_dir_handle.close();

    var has_pack_files = false;
    var iterator = pack_dir_handle.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pack")) {
            print("Found pack file: {s}\n", .{entry.name});
            has_pack_files = true;
        }
    }

    if (!has_pack_files) {
        print("No pack files found after gc, test inconclusive\n", .{});
        return;
    }

    // Test platform implementation for pack file reading
    const TestPlatform = struct {
        pub const fs = struct {
            pub fn readFile(allocator2: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(allocator2, path, 10 * 1024 * 1024);
            }
            
            pub fn writeFile(path: []const u8, content: []const u8) !void {
                try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
            }
        };
    };

    // Now try to load the HEAD commit using our pack file implementation
    const git_obj = objects.GitObject.load(head_hash, git_dir, TestPlatform, allocator) catch |err| {
        print("Failed to load object {s} from pack files: {}\n", .{ head_hash, err });
        return err;
    };
    defer git_obj.deinit(allocator);

    print("Successfully loaded object from pack file!\n", .{});
    print("Object type: {s}\n", .{git_obj.type.toString()});
    print("Object size: {} bytes\n", .{git_obj.data.len});

    // Verify it's a commit object
    try testing.expect(git_obj.type == .commit);
    try testing.expect(git_obj.data.len > 0);

    // Parse commit data to verify it's valid
    const commit_data = std.mem.span(git_obj.data);
    try testing.expect(std.mem.startsWith(u8, commit_data, "tree "));
    
    print("Pack file test passed!\n", .{});
}