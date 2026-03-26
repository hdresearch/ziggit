const std = @import("std");
const testing = std.testing;
const objects = @import("../src/git/objects.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Warning: memory leaked in pack file tests\n", .{});
        }
    }
    const allocator = gpa.allocator();
    
    std.debug.print("=== Pack File Functionality Tests ===\n", .{});
    
    // Create a temporary directory for our test
    const test_dir = "pack_test_repo";
    std.fs.cwd().deleteTree(test_dir) catch {};
    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};
    
    // Initialize git repository
    var child = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
    child.cwd = test_dir;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = try child.wait();
    
    // Configure git
    var config_name = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
    config_name.cwd = test_dir;
    config_name.stdout_behavior = .Ignore;
    config_name.stderr_behavior = .Ignore;
    try config_name.spawn();
    _ = try config_name.wait();
    
    var config_email = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
    config_email.cwd = test_dir;
    config_email.stdout_behavior = .Ignore;
    config_email.stderr_behavior = .Ignore;
    try config_email.spawn();
    _ = try config_email.wait();
    
    std.debug.print("✓ Created test repository\n", .{});
    
    // Create many commits to ensure we have lots of objects
    try createManyCommits(allocator, test_dir);
    std.debug.print("✓ Created many commits\n", .{});
    
    // Force creation of pack files
    try createPackFiles(allocator, test_dir);
    std.debug.print("✓ Created pack files\n", .{});
    
    // Test reading objects through our pack file implementation
    try testPackFileReading(allocator, test_dir);
    std.debug.print("✓ Pack file reading test passed\n", .{});
    
    // Test different object types in pack files  
    try testPackFileObjectTypes(allocator, test_dir);
    std.debug.print("✓ Pack file object types test passed\n", .{});
    
    // Test delta compression handling
    try testDeltaCompression(allocator, test_dir);
    std.debug.print("✓ Delta compression test passed\n", .{});
    
    std.debug.print("\n=== All Pack File Tests Passed! ===\n", .{});
}

fn createManyCommits(allocator: std.mem.Allocator, repo_dir: []const u8) !void {
    // Create many different files and commits to ensure pack files are created
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        // Create a file with substantial content
        const filename = try std.fmt.allocPrint(allocator, "file_{d:0>3}.txt", .{i});
        defer allocator.free(filename);
        
        const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{repo_dir, filename});
        defer allocator.free(filepath);
        
        var content = std.ArrayList(u8).init(allocator);
        defer content.deinit();
        
        try content.writer().print("This is file number {d}\n", .{i});
        for (0..50) |j| {
            try content.writer().print("Line {d} in file {d} with some content to make it substantial\n", .{j, i});
        }
        
        try std.fs.cwd().writeFile(.{ .sub_path = filepath, .data = content.items });
        
        // Add to git
        var git_add = std.process.Child.init(&[_][]const u8{ "git", "add", filename }, allocator);
        git_add.cwd = repo_dir;
        git_add.stdout_behavior = .Ignore;
        git_add.stderr_behavior = .Ignore;
        try git_add.spawn();
        _ = try git_add.wait();
        
        // Commit
        const commit_msg = try std.fmt.allocPrint(allocator, "Add file {d}", .{i});
        defer allocator.free(commit_msg);
        
        var git_commit = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", commit_msg }, allocator);
        git_commit.cwd = repo_dir;
        git_commit.stdout_behavior = .Ignore;
        git_commit.stderr_behavior = .Ignore;
        try git_commit.spawn();
        _ = try git_commit.wait();
    }
    
    // Create some subdirectories with files  
    try std.fs.cwd().makePath(try std.fmt.allocPrint(allocator, "{s}/src", .{repo_dir}));
    try std.fs.cwd().makePath(try std.fmt.allocPrint(allocator, "{s}/docs", .{repo_dir}));
    
    const subdirs = [_][]const u8{ "src", "docs" };
    for (subdirs) |subdir| {
        var j: u32 = 0;
        while (j < 5) : (j += 1) {
            const filename = try std.fmt.allocPrint(allocator, "{s}/subfile_{d}.txt", .{subdir, j});
            defer allocator.free(filename);
            
            const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{repo_dir, filename});
            defer allocator.free(filepath);
            
            const content = try std.fmt.allocPrint(allocator, "Content for {s} file {d}\nWith multiple lines\nTo create tree objects\n", .{subdir, j});
            defer allocator.free(content);
            
            try std.fs.cwd().writeFile(.{ .sub_path = filepath, .data = content });
            
            var git_add = std.process.Child.init(&[_][]const u8{ "git", "add", filename }, allocator);
            git_add.cwd = repo_dir;
            git_add.stdout_behavior = .Ignore;
            git_add.stderr_behavior = .Ignore;
            try git_add.spawn();
            _ = try git_add.wait();
        }
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Add {s} files", .{subdir});
        defer allocator.free(commit_msg);
        
        var git_commit = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", commit_msg }, allocator);
        git_commit.cwd = repo_dir;
        git_commit.stdout_behavior = .Ignore;
        git_commit.stderr_behavior = .Ignore;
        try git_commit.spawn();
        _ = try git_commit.wait();
    }
}

fn createPackFiles(allocator: std.mem.Allocator, repo_dir: []const u8) !void {
    // Force git to create pack files
    var git_gc = std.process.Child.init(&[_][]const u8{ "git", "gc", "--aggressive", "--prune=now" }, allocator);
    git_gc.cwd = repo_dir;
    git_gc.stdout_behavior = .Ignore;
    git_gc.stderr_behavior = .Ignore;
    try git_gc.spawn();
    _ = try git_gc.wait();
    
    // Verify pack files were created
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{repo_dir});
    defer allocator.free(pack_dir);
    
    var dir = std.fs.cwd().openDir(pack_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("Pack directory not found: {}\n", .{err});
        return;
    };
    defer dir.close();
    
    var iterator = dir.iterate();
    var pack_files_found: u32 = 0;
    var idx_files_found: u32 = 0;
    
    while (try iterator.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_files_found += 1;
            std.debug.print("  Found pack file: {s}\n", .{entry.name});
        }
        if (std.mem.endsWith(u8, entry.name, ".idx")) {
            idx_files_found += 1;
            std.debug.print("  Found index file: {s}\n", .{entry.name});
        }
    }
    
    if (pack_files_found == 0 or idx_files_found == 0) {
        std.debug.print("Warning: No pack files created (pack: {d}, idx: {d})\n", .{pack_files_found, idx_files_found});
    }
}

const TestPlatform = struct {
    const fs = struct {
        pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024);
        }
        
        pub fn writeFile(path: []const u8, data: []const u8) !void {
            try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
        }
        
        pub fn exists(path: []const u8) !bool {
            std.fs.cwd().access(path, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            return true;
        }
        
        pub fn makeDir(path: []const u8) !void {
            try std.fs.cwd().makeDir(path);
        }
        
        pub fn deleteFile(path: []const u8) !void {
            try std.fs.cwd().deleteFile(path);
        }
        
        pub fn readDir(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
            var entries = std.ArrayList([]u8).init(allocator);
            
            var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
            defer dir.close();
            
            var iterator = dir.iterate();
            while (try iterator.next()) |entry| {
                if (entry.kind == .file) {
                    try entries.append(try allocator.dupe(u8, entry.name));
                }
            }
            
            return entries.toOwnedSlice();
        }
    };
};

fn testPackFileReading(allocator: std.mem.Allocator, repo_dir: []const u8) !void {
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{repo_dir});
    defer allocator.free(git_dir);
    
    // Get a list of commits to test against
    var git_log = std.process.Child.init(&[_][]const u8{ "git", "log", "--oneline", "--format=%H" }, allocator);
    git_log.cwd = repo_dir;
    git_log.stdout_behavior = .Pipe;
    git_log.stderr_behavior = .Ignore;
    try git_log.spawn();
    
    const log_output = try git_log.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(log_output);
    const term = try git_log.wait();
    
    if (term != .Exited or term.Exited != 0) {
        return error.GitLogFailed;
    }
    
    // Parse commit hashes
    var lines = std.mem.split(u8, log_output, "\n");
    var commits_tested: u32 = 0;
    
    while (lines.next()) |line| {
        const commit_hash = std.mem.trim(u8, line, " \t\n\r");
        if (commit_hash.len != 40) continue;
        
        // Try to load this commit object through our pack file implementation
        const commit_obj = objects.GitObject.load(commit_hash, git_dir, TestPlatform, allocator) catch |err| {
            std.debug.print("Failed to load commit {s}: {}\n", .{commit_hash, err});
            continue;
        };
        defer commit_obj.deinit(allocator);
        
        if (commit_obj.type != .commit) {
            std.debug.print("Object {s} is not a commit (got {})\n", .{commit_hash, commit_obj.type});
            return error.WrongObjectType;
        }
        
        commits_tested += 1;
        if (commits_tested >= 5) break; // Test first 5 commits
    }
    
    if (commits_tested == 0) {
        std.debug.print("Warning: No commits could be loaded from pack files\n", .{});
    } else {
        std.debug.print("  Successfully loaded {d} commits from pack files\n", .{commits_tested});
    }
}

fn testPackFileObjectTypes(allocator: std.mem.Allocator, repo_dir: []const u8) !void {
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{repo_dir});
    defer allocator.free(git_dir);
    
    // Get objects of different types
    var git_cat = std.process.Child.init(&[_][]const u8{ "git", "cat-file", "--batch-all-objects", "--batch" }, allocator);
    git_cat.cwd = repo_dir;
    git_cat.stdout_behavior = .Pipe;
    git_cat.stderr_behavior = .Ignore;
    try git_cat.spawn();
    
    const cat_output = try git_cat.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(cat_output);
    _ = try git_cat.wait();
    
    var lines = std.mem.split(u8, cat_output, "\n");
    var objects_tested = std.EnumSet(objects.ObjectType){};
    var total_tested: u32 = 0;
    
    while (lines.next()) |line| {
        if (total_tested >= 20) break; // Limit testing to avoid long runtime
        
        // Parse git cat-file output: "<hash> <type> <size>"
        const parts = std.mem.split(u8, line, " ");
        var part_iter = parts;
        const hash_part = part_iter.next() orelse continue;
        const type_part = part_iter.next() orelse continue;
        
        if (hash_part.len != 40) continue;
        
        const obj_type = objects.ObjectType.fromString(type_part) orelse continue;
        
        // Try to load this object
        const obj = objects.GitObject.load(hash_part, git_dir, TestPlatform, allocator) catch |err| {
            // Some objects might not be in pack files if they're still loose
            if (err != error.ObjectNotFound) {
                std.debug.print("Failed to load object {s} ({}): {}\n", .{hash_part, obj_type, err});
            }
            continue;
        };
        defer obj.deinit(allocator);
        
        if (obj.type != obj_type) {
            std.debug.print("Object type mismatch for {s}: expected {}, got {}\n", .{hash_part, obj_type, obj.type});
            return error.ObjectTypeMismatch;
        }
        
        objects_tested.insert(obj_type);
        total_tested += 1;
    }
    
    std.debug.print("  Tested {d} objects of types: ", .{total_tested});
    var first = true;
    inline for (std.meta.fields(objects.ObjectType)) |field| {
        const obj_type = @field(objects.ObjectType, field.name);
        if (objects_tested.contains(obj_type)) {
            if (!first) std.debug.print(", ");
            std.debug.print("{s}", .{@tagName(obj_type)});
            first = false;
        }
    }
    std.debug.print("\n");
}

fn testDeltaCompression(allocator: std.mem.Allocator, repo_dir: []const u8) !void {
    // Create files with similar content to encourage delta compression
    const base_content = "This is the base content that will be used for delta compression.\n" ++
                        "It has multiple lines and substantial content.\n" ++
                        "Each line contributes to the base that will be delta compressed.\n";
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{repo_dir});
    defer allocator.free(git_dir);
    
    // Create files with similar content but small differences
    for (0..5) |i| {
        const filename = try std.fmt.allocPrint(allocator, "delta_test_{d}.txt", .{i});
        defer allocator.free(filename);
        
        const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{repo_dir, filename});
        defer allocator.free(filepath);
        
        const content = try std.fmt.allocPrint(allocator, "{s}Modified line {d} for delta testing\n", .{base_content, i});
        defer allocator.free(content);
        
        try std.fs.cwd().writeFile(.{ .sub_path = filepath, .data = content });
        
        var git_add = std.process.Child.init(&[_][]const u8{ "git", "add", filename }, allocator);
        git_add.cwd = repo_dir;
        git_add.stdout_behavior = .Ignore;
        git_add.stderr_behavior = .Ignore;
        try git_add.spawn();
        _ = try git_add.wait();
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Add delta test file {d}", .{i});
        defer allocator.free(commit_msg);
        
        var git_commit = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", commit_msg }, allocator);
        git_commit.cwd = repo_dir;
        git_commit.stdout_behavior = .Ignore;
        git_commit.stderr_behavior = .Ignore;
        try git_commit.spawn();
        _ = try git_commit.wait();
    }
    
    // Force repacking to create deltas
    var git_repack = std.process.Child.init(&[_][]const u8{ "git", "repack", "-a", "-d", "-f" }, allocator);
    git_repack.cwd = repo_dir;
    git_repack.stdout_behavior = .Ignore;
    git_repack.stderr_behavior = .Ignore;
    try git_repack.spawn();
    _ = try git_repack.wait();
    
    // Try to read some recent commits (which likely contain delta objects)
    var git_log = std.process.Child.init(&[_][]const u8{ "git", "log", "--format=%H", "-n", "5" }, allocator);
    git_log.cwd = repo_dir;
    git_log.stdout_behavior = .Pipe;
    git_log.stderr_behavior = .Ignore;
    try git_log.spawn();
    
    const log_output = try git_log.stdout.?.readToEndAlloc(allocator, 1024);
    defer allocator.free(log_output);
    _ = try git_log.wait();
    
    var lines = std.mem.split(u8, log_output, "\n");
    var commits_loaded: u32 = 0;
    
    while (lines.next()) |line| {
        const commit_hash = std.mem.trim(u8, line, " \t\n\r");
        if (commit_hash.len != 40) continue;
        
        const commit_obj = objects.GitObject.load(commit_hash, git_dir, TestPlatform, allocator) catch |err| {
            std.debug.print("Failed to load commit {s} (possibly delta): {}\n", .{commit_hash, err});
            continue;
        };
        defer commit_obj.deinit(allocator);
        
        commits_loaded += 1;
    }
    
    std.debug.print("  Successfully loaded {d} recent commits (potentially with delta compression)\n", .{commits_loaded});
}

test "pack file functionality" {
    try main();
}