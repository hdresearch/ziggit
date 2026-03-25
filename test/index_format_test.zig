const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const ChildProcess = std.process.Child;

// Import git index module for testing
const index_mod = @import("../src/git/index.zig");

// Test binary index format compatibility between git and ziggit
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Running Index Format Compatibility Tests...\n", .{});

    // Create temporary test directory
    const test_dir = try fs.cwd().makeOpenPath("test_tmp_index", .{});
    defer fs.cwd().deleteTree("test_tmp_index") catch {};

    // Test 1: Read git-created index file
    try testReadGitIndex(allocator, test_dir);

    // Test 2: Binary index structure validation
    try testIndexBinaryStructure(allocator, test_dir);

    // Test 3: Index entry parsing
    try testIndexEntryParsing(allocator, test_dir);

    // Test 4: Complex index scenarios
    try testComplexIndexScenarios(allocator, test_dir);

    std.debug.print("All index format tests passed!\n", .{});
}

fn testReadGitIndex(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 1: Reading git-created index file\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("git_index_read", .{});
    defer test_dir.deleteTree("git_index_read") catch {};

    // Initialize repository with git
    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);

    // Create test files with various characteristics
    try repo_path.writeFile(.{.sub_path = "simple.txt", .data = "Simple content\n"});
    try repo_path.writeFile(.{.sub_path = "with-spaces.txt", .data = "File with spaces in name\n"});
    try repo_path.writeFile(.{.sub_path = "special-chars.txt", .data = "Content with special chars: àáâãäåæçèéêë\n"});
    
    // Create subdirectory structure
    const subdir = try repo_path.makeOpenPath("subdir", .{});
    try subdir.writeFile(.{.sub_path = "nested.txt", .data = "Nested file content\n"});

    // Add all files to git index
    _ = try runCommand(allocator, &.{"git", "add", "."}, repo_path);

    // Now try to read the index with ziggit's index module
    const repo_path_str = try getAbsolutePath(allocator, repo_path);
    defer allocator.free(repo_path_str);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/.git/index", .{repo_path_str});
    defer allocator.free(index_path);

    // Test reading the index file
    var index = index_mod.Index.init(allocator);
    defer index.deinit();

    index.read(index_path) catch |err| {
        std.debug.print("  Error reading git-created index: {}\n", .{err});
        return err;
    };

    std.debug.print("  Successfully read git index with {} entries\n", .{index.entries.items.len});
    
    // Verify we got the expected files
    var file_count = std.StringHashMap(void).init(allocator);
    defer file_count.deinit();
    
    for (index.entries.items) |entry| {
        try file_count.put(entry.path, {});
        std.debug.print("    Found entry: {s} (mode: {o}, size: {})\n", .{entry.path, entry.mode, entry.size});
    }

    if (file_count.count() < 4) {
        std.debug.print("  Error: Expected at least 4 files in index, got {}\n", .{file_count.count()});
        return error.TestFailed;
    }

    std.debug.print("  ✓ Test 1 passed\n", .{});
}

fn testIndexBinaryStructure(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 2: Binary index structure validation\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("index_binary", .{});
    defer test_dir.deleteTree("index_binary") catch {};

    // Create git repo with specific structure to test binary format
    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);

    // Create files with specific sizes to test binary parsing
    try repo_path.writeFile(.{.sub_path = "empty.txt", .data = ""});
    try repo_path.writeFile(.{.sub_path = "small.txt", .data = "a"});
    try repo_path.writeFile("medium.txt", "a" ** 100);
    try repo_path.writeFile("large.txt", "a" ** 1000);

    _ = try runCommand(allocator, &.{"git", "add", "."}, repo_path);

    // Read raw index file and validate structure
    const repo_path_str = try getAbsolutePath(allocator, repo_path);
    defer allocator.free(repo_path_str);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/.git/index", .{repo_path_str});
    defer allocator.free(index_path);

    const index_file = try fs.openFileAbsolute(index_path, .{});
    defer index_file.close();

    const file_size = try index_file.getEndPos();
    const raw_data = try allocator.alloc(u8, file_size);
    defer allocator.free(raw_data);
    _ = try index_file.readAll(raw_data);

    // Validate git index header: "DIRC"
    if (!std.mem.eql(u8, raw_data[0..4], "DIRC")) {
        std.debug.print("  Error: Invalid index header, expected 'DIRC', got '{s}'\n", .{raw_data[0..4]});
        return error.TestFailed;
    }

    // Version should be 2 (big-endian uint32)
    const version = std.mem.readIntBig(u32, raw_data[4..8]);
    if (version != 2) {
        std.debug.print("  Error: Expected index version 2, got {}\n", .{version});
        return error.TestFailed;
    }

    // Entry count should be 4 (big-endian uint32)
    const entry_count = std.mem.readIntBig(u32, raw_data[8..12]);
    if (entry_count != 4) {
        std.debug.print("  Error: Expected 4 entries, got {}\n", .{entry_count});
        return error.TestFailed;
    }

    std.debug.print("  Index header validation passed: version={}, entries={}\n", .{version, entry_count});
    std.debug.print("  ✓ Test 2 passed\n", .{});
}

fn testIndexEntryParsing(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 3: Index entry parsing\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("index_entry", .{});
    defer test_dir.deleteTree("index_entry") catch {};

    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);

    // Create a test file with known content
    const test_content = "Hello, World! This is a test file.\n";
    try repo_path.writeFile("test.txt", test_content);

    _ = try runCommand(allocator, &.{"git", "add", "test.txt"}, repo_path);

    // Get the expected SHA-1 hash from git
    const git_hash_result = try runCommand(allocator, &.{"git", "rev-parse", ":test.txt"}, repo_path);
    defer allocator.free(git_hash_result);
    const expected_hash = std.mem.trim(u8, git_hash_result, " \t\n\r");

    // Read and parse the index
    const repo_path_str = try getAbsolutePath(allocator, repo_path);
    defer allocator.free(repo_path_str);

    var index = index_mod.Index.init(allocator);
    defer index.deinit();

    const index_path = try std.fmt.allocPrint(allocator, "{s}/.git/index", .{repo_path_str});
    defer allocator.free(index_path);

    try index.read(index_path);

    if (index.entries.items.len != 1) {
        std.debug.print("  Error: Expected 1 entry, got {}\n", .{index.entries.items.len});
        return error.TestFailed;
    }

    const entry = &index.entries.items[0];
    
    // Validate path
    if (!std.mem.eql(u8, entry.path, "test.txt")) {
        std.debug.print("  Error: Expected path 'test.txt', got '{s}'\n", .{entry.path});
        return error.TestFailed;
    }

    // Validate size
    if (entry.size != test_content.len) {
        std.debug.print("  Error: Expected size {}, got {}\n", .{test_content.len, entry.size});
        return error.TestFailed;
    }

    // Validate SHA-1 hash
    var hash_str = try allocator.alloc(u8, 40);
    defer allocator.free(hash_str);
    _ = try std.fmt.bufPrint(hash_str, "{x:0>40}", .{std.fmt.fmtSliceHexLower(&entry.sha1)});
    
    if (!std.mem.eql(u8, hash_str, expected_hash)) {
        std.debug.print("  Error: Hash mismatch. Expected {s}, got {s}\n", .{expected_hash, hash_str});
        return error.TestFailed;
    }

    std.debug.print("  Entry parsed correctly: path={s}, size={}, hash={s}\n", .{entry.path, entry.size, hash_str});
    std.debug.print("  ✓ Test 3 passed\n", .{});
}

fn testComplexIndexScenarios(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 4: Complex index scenarios\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("complex_index", .{});
    defer test_dir.deleteTree("complex_index") catch {};

    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);

    // Create complex directory structure
    try repo_path.writeFile(.{.sub_path = "root.txt", .data = "root file\n"});
    
    const dir1 = try repo_path.makeOpenPath("dir1", .{});
    try dir1.writeFile(.{.sub_path = "file1.txt", .data = "file in dir1\n"});
    
    const dir2 = try repo_path.makeOpenPath("dir2", .{});
    try dir2.writeFile(.{.sub_path = "file2.txt", .data = "file in dir2\n"});
    
    const nested = try dir1.makeOpenPath("nested", .{});
    try nested.writeFile(.{.sub_path = "deep.txt", .data = "deep nested file\n"});

    // Files with various permissions and characteristics
    try repo_path.writeFile(.{.sub_path = "executable.sh", .data = "#!/bin/bash\necho 'hello'\n"});
    _ = try runCommand(allocator, &.{"chmod", "+x", "executable.sh"}, repo_path);

    // Add all files
    _ = try runCommand(allocator, &.{"git", "add", "."}, repo_path);

    // Test reading the complex index
    const repo_path_str = try getAbsolutePath(allocator, repo_path);
    defer allocator.free(repo_path_str);

    var index = index_mod.Index.init(allocator);
    defer index.deinit();

    const index_path = try std.fmt.allocPrint(allocator, "{s}/.git/index", .{repo_path_str});
    defer allocator.free(index_path);

    try index.read(index_path);

    std.debug.print("  Successfully read complex index with {} entries:\n", .{index.entries.items.len});
    
    var has_executable = false;
    var has_nested = false;
    
    for (index.entries.items) |entry| {
        std.debug.print("    {s} (mode: {o:0>6})\n", .{entry.path, entry.mode});
        
        if (std.mem.eql(u8, entry.path, "executable.sh")) {
            has_executable = true;
            // Check executable bit (should be 100755)
            if (entry.mode & 0o111 == 0) {
                std.debug.print("  Warning: executable file doesn't have execute bit set\n", .{});
            }
        }
        
        if (std.mem.indexOf(u8, entry.path, "nested/") != null) {
            has_nested = true;
        }
    }

    if (!has_executable) {
        std.debug.print("  Error: Missing executable file in index\n", .{});
        return error.TestFailed;
    }

    if (!has_nested) {
        std.debug.print("  Error: Missing nested directory files in index\n", .{});
        return error.TestFailed;
    }

    std.debug.print("  ✓ Test 4 passed\n", .{});
}

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    var child = ChildProcess.init(args, allocator);
    child.cwd_dir = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 8192);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 8192);
    defer allocator.free(stderr);
    
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("Command failed: {s}\n", .{stderr});
        allocator.free(stdout);
        return error.CommandFailed;
    }
    
    return stdout;
}

fn getAbsolutePath(allocator: std.mem.Allocator, dir: fs.Dir) ![]u8 {
    // Get the real path of the directory
    const fd = dir.fd;
    var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const path = try std.os.getFdPath(fd, &path_buffer);
    return allocator.dupe(u8, path);
}

test "index format compatibility" {
    try main();
}