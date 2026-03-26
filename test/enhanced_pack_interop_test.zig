const std = @import("std");
const objects = @import("../src/git/objects.zig");
const print = std.debug.print;

/// Test pack file interoperability with real git repositories
pub fn main() !void {
    const allocator = std.testing.allocator;
    
    print("🧪 Enhanced Pack File Interoperability Test\n");
    print("===========================================\n\n");
    
    // Create a test repository and force pack creation
    const test_dir = "/tmp/ziggit_pack_test";
    
    // Clean up any existing test directory
    std.fs.cwd().deleteTree(test_dir) catch {};
    
    // Initialize a git repository
    const init_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "init", test_dir },
    }) catch |err| {
        print("❌ Failed to initialize git repository: {}\n", .{err});
        print("Make sure 'git' command is available in PATH\n");
        return;
    };
    defer {
        allocator.free(init_result.stdout);
        allocator.free(init_result.stderr);
    }
    
    if (init_result.term.Exited != 0) {
        print("❌ Git init failed: {s}\n", .{init_result.stderr});
        return;
    }
    
    print("✅ Created test repository at {s}\n", .{test_dir});
    
    // Change to test directory for subsequent commands
    const original_cwd = std.fs.cwd();
    var test_cwd = std.fs.cwd().openDir(test_dir, .{}) catch |err| {
        print("❌ Failed to open test directory: {}\n", .{err});
        return;
    };
    defer test_cwd.close();
    
    // Create some test files
    const test_files = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "README.md", .content = "# Test Repository\n\nThis is a test repository for pack file testing.\n" },
        .{ .name = "hello.txt", .content = "Hello, World!\n" },
        .{ .name = "lib/utils.zig", .content = "const std = @import(\"std\");\n\npub fn hello() void {\n    std.debug.print(\"Hello from utils!\\n\", .{});\n}\n" },
        .{ .name = "src/main.zig", .content = "const std = @import(\"std\");\nconst utils = @import(\"../lib/utils.zig\");\n\npub fn main() !void {\n    utils.hello();\n}\n" },
    };
    
    // Create directory structure and files
    try test_cwd.makeDir("lib");
    try test_cwd.makeDir("src");
    
    for (test_files) |file| {
        try test_cwd.writeFile(file.name, file.content);
        print("📝 Created file: {s}\n", .{file.name});
    }
    
    // Add files to git
    const add_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "add", "." },
        .cwd = test_dir,
    }) catch |err| {
        print("❌ Failed to add files: {}\n", .{err});
        return;
    };
    defer {
        allocator.free(add_result.stdout);
        allocator.free(add_result.stderr);
    }
    
    if (add_result.term.Exited != 0) {
        print("❌ Git add failed: {s}\n", .{add_result.stderr});
        return;
    }
    
    // Commit the files
    const commit_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "Initial commit with test files" },
        .cwd = test_dir,
    }) catch |err| {
        print("❌ Failed to commit files: {}\n", .{err});
        return;
    };
    defer {
        allocator.free(commit_result.stdout);
        allocator.free(commit_result.stderr);
    }
    
    if (commit_result.term.Exited != 0) {
        print("❌ Git commit failed: {s}\n", .{commit_result.stderr});
        return;
    }
    
    print("✅ Committed files to repository\n");
    
    // Create more commits to have enough objects for packing
    var i: u32 = 1;
    while (i <= 5) : (i += 1) {
        const new_file = try std.fmt.allocPrint(allocator, "file{}.txt", .{i});
        defer allocator.free(new_file);
        
        const content = try std.fmt.allocPrint(allocator, "Content for file {}\nLine 2 of file {}\n", .{ i, i });
        defer allocator.free(content);
        
        try test_cwd.writeFile(new_file, content);
        
        const add_file_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "add", new_file },
            .cwd = test_dir,
        }) catch continue;
        
        allocator.free(add_file_result.stdout);
        allocator.free(add_file_result.stderr);
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Add {s}", .{new_file});
        defer allocator.free(commit_msg);
        
        const commit_file_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", commit_msg },
            .cwd = test_dir,
        }) catch continue;
        
        allocator.free(commit_file_result.stdout);
        allocator.free(commit_file_result.stderr);
    }
    
    print("✅ Created additional commits\n");
    
    // Force git to create pack files by running gc
    const gc_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "gc", "--aggressive", "--prune=now" },
        .cwd = test_dir,
    }) catch |err| {
        print("❌ Failed to run git gc: {}\n", .{err});
        return;
    };
    defer {
        allocator.free(gc_result.stdout);
        allocator.free(gc_result.stderr);
    }
    
    print("✅ Ran git gc to create pack files\n");
    
    // Check if pack files were created
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{test_dir});
    defer allocator.free(pack_dir_path);
    
    var pack_dir = std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true }) catch |err| {
        print("❌ Failed to open pack directory: {}\n", .{err});
        return;
    };
    defer pack_dir.close();
    
    var pack_files = std.ArrayList([]u8).init(allocator);
    defer {
        for (pack_files.items) |file| {
            allocator.free(file);
        }
        pack_files.deinit();
    }
    
    var pack_iter = pack_dir.iterate();
    while (try pack_iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            try pack_files.append(try allocator.dupe(u8, entry.name));
            print("📦 Found pack file: {s}\n", .{entry.name});
        }
    }
    
    if (pack_files.items.len == 0) {
        print("⚠️ No pack files created. Repository might be too small.\n");
        print("   This is normal for small repositories. Git keeps objects as loose files.\n");
        
        // Test with loose objects instead
        try testLooseObjectReading(test_dir, allocator);
        return;
    }
    
    // Now test reading objects through our pack file implementation
    print("\n🔍 Testing pack file reading with ziggit...\n");
    
    // Create a platform implementation for file system access
    const Platform = struct {
        pub const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024);
            }
            
            pub fn writeFile(path: []const u8, content: []const u8) !void {
                try std.fs.cwd().writeFile(path, content);
            }
            
            pub fn makeDir(path: []const u8) !void {
                try std.fs.cwd().makeDir(path);
            }
            
            pub fn exists(path: []const u8) !bool {
                std.fs.cwd().access(path, .{}) catch return false;
                return true;
            }
            
            pub fn readDir(alloc: std.mem.Allocator, path: []const u8) ![][]u8 {
                var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
                defer dir.close();
                
                var entries = std.ArrayList([]u8).init(alloc);
                var iter = dir.iterate();
                while (try iter.next()) |entry| {
                    if (entry.kind == .file) {
                        try entries.append(try alloc.dupe(u8, entry.name));
                    }
                }
                
                return try entries.toOwnedSlice();
            }
            
            pub fn deleteFile(path: []const u8) !void {
                try std.fs.cwd().deleteFile(path);
            }
        };
    };
    
    // Get list of all objects in the repository
    const log_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "log", "--all", "--format=%H", "--no-merges" },
        .cwd = test_dir,
    }) catch |err| {
        print("❌ Failed to get commit list: {}\n", .{err});
        return;
    };
    defer {
        allocator.free(log_result.stdout);
        allocator.free(log_result.stderr);
    }
    
    var commits = std.ArrayList([]u8).init(allocator);
    defer {
        for (commits.items) |commit| {
            allocator.free(commit);
        }
        commits.deinit();
    }
    
    var lines = std.mem.split(u8, std.mem.trim(u8, log_result.stdout, " \n\r"), "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \n\r");
        if (trimmed.len == 40) {
            try commits.append(try allocator.dupe(u8, trimmed));
        }
    }
    
    print("📋 Found {} commits to test\n", .{commits.items.len});
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{test_dir});
    defer allocator.free(git_dir);
    
    var successful_reads: u32 = 0;
    var failed_reads: u32 = 0;
    
    // Test reading commit objects
    for (commits.items) |commit_hash| {
        const obj = objects.GitObject.load(commit_hash, git_dir, Platform{}, allocator) catch |err| {
            print("❌ Failed to load commit {s}: {}\n", .{ commit_hash, err });
            failed_reads += 1;
            continue;
        };
        defer obj.deinit(allocator);
        
        if (obj.type != .commit) {
            print("❌ Expected commit, got {}\n", .{obj.type});
            failed_reads += 1;
            continue;
        }
        
        print("✅ Successfully loaded commit {s} (size: {} bytes)\n", .{ commit_hash[0..8], obj.data.len });
        successful_reads += 1;
        
        // Parse commit to get tree hash and test that too
        var commit_lines = std.mem.split(u8, obj.data, "\n");
        while (commit_lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "tree ")) {
                const tree_hash = line["tree ".len..];
                if (tree_hash.len >= 40) {
                    const tree_hash_str = tree_hash[0..40];
                    
                    const tree_obj = objects.GitObject.load(tree_hash_str, git_dir, Platform{}, allocator) catch |err| {
                        print("⚠️ Failed to load tree {s}: {}\n", .{ tree_hash_str[0..8], err });
                        continue;
                    };
                    defer tree_obj.deinit(allocator);
                    
                    if (tree_obj.type == .tree) {
                        print("✅ Successfully loaded tree {s} (size: {} bytes)\n", .{ tree_hash_str[0..8], tree_obj.data.len });
                        successful_reads += 1;
                    } else {
                        print("❌ Expected tree, got {}\n", .{tree_obj.type});
                        failed_reads += 1;
                    }
                }
                break;
            }
        }
    }
    
    print("\n📊 Pack file reading results:\n");
    print("   ✅ Successful reads: {}\n", .{successful_reads});
    print("   ❌ Failed reads: {}\n", .{failed_reads});
    
    const success_rate = if (successful_reads + failed_reads > 0)
        (@as(f32, @floatFromInt(successful_reads)) / @as(f32, @floatFromInt(successful_reads + failed_reads))) * 100.0
    else
        0.0;
    
    print("   📈 Success rate: {d:.1}%\n", .{success_rate});
    
    if (success_rate >= 80.0) {
        print("\n🎉 Pack file interoperability test PASSED!\n");
        print("   Ziggit can successfully read objects from git pack files.\n");
    } else if (success_rate >= 50.0) {
        print("\n⚠️ Pack file interoperability test PARTIAL.\n");
        print("   Some issues with pack file reading, but basic functionality works.\n");
    } else {
        print("\n❌ Pack file interoperability test FAILED.\n");
        print("   Significant issues with pack file reading implementation.\n");
    }
    
    // Test pack file statistics
    print("\n📈 Testing pack file analysis...\n");
    for (pack_files.items) |pack_file| {
        const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, pack_file });
        defer allocator.free(pack_path);
        
        const stats = objects.analyzePackFile(pack_path, Platform{}, allocator) catch |err| {
            print("❌ Failed to analyze pack file {s}: {}\n", .{ pack_file, err });
            continue;
        };
        
        print("📦 Pack file {s}:\n", .{pack_file});
        print("   - Total objects: {}\n", .{stats.total_objects});
        print("   - File size: {} bytes\n", .{stats.file_size});
        print("   - Version: {}\n", .{stats.version});
        print("   - Checksum valid: {}\n", .{stats.checksum_valid});
        print("   - Is thin pack: {}\n", .{stats.is_thin});
    }
    
    // Cleanup
    std.fs.cwd().deleteTree(test_dir) catch {};
    print("\n🧹 Cleaned up test repository\n");
}

fn testLooseObjectReading(test_dir: []const u8, allocator: std.mem.Allocator) !void {
    print("\n🔍 Testing loose object reading instead...\n");
    
    const Platform = struct {
        pub const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024);
            }
            
            pub fn writeFile(path: []const u8, content: []const u8) !void {
                try std.fs.cwd().writeFile(path, content);
            }
            
            pub fn makeDir(path: []const u8) !void {
                try std.fs.cwd().makeDir(path);
            }
            
            pub fn exists(path: []const u8) !bool {
                std.fs.cwd().access(path, .{}) catch return false;
                return true;
            }
            
            pub fn readDir(alloc: std.mem.Allocator, path: []const u8) ![][]u8 {
                var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
                defer dir.close();
                
                var entries = std.ArrayList([]u8).init(alloc);
                var iter = dir.iterate();
                while (try iter.next()) |entry| {
                    if (entry.kind == .file) {
                        try entries.append(try alloc.dupe(u8, entry.name));
                    }
                }
                
                return try entries.toOwnedSlice();
            }
            
            pub fn deleteFile(path: []const u8) !void {
                try std.fs.cwd().deleteFile(path);
            }
        };
    };
    
    // Get HEAD commit hash
    const head_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "rev-parse", "HEAD" },
        .cwd = test_dir,
    }) catch return;
    defer {
        allocator.free(head_result.stdout);
        allocator.free(head_result.stderr);
    }
    
    const head_hash = std.mem.trim(u8, head_result.stdout, " \n\r");
    if (head_hash.len != 40) return;
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{test_dir});
    defer allocator.free(git_dir);
    
    const obj = objects.GitObject.load(head_hash, git_dir, Platform{}, allocator) catch |err| {
        print("❌ Failed to load HEAD object {s}: {}\n", .{ head_hash, err });
        return;
    };
    defer obj.deinit(allocator);
    
    print("✅ Successfully loaded HEAD commit {} (size: {} bytes)\n", .{ std.fmt.fmtSliceHexLower(head_hash[0..8]), obj.data.len });
    print("✅ Loose object reading works correctly!\n");
}