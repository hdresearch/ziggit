const std = @import("std");
const objects = @import("../src/git/objects.zig");
const config = @import("../src/git/config.zig");
const index = @import("../src/git/index.zig");
const refs = @import("../src/git/refs.zig");

// Test platform implementation
const TestPlatform = struct {
    const fs = struct {
        fn readFile(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(allocator, file_path, 50 * 1024 * 1024);
        }
        fn writeFile(file_path: []const u8, content: []const u8) !void {
            try std.fs.cwd().writeFile(file_path, content);
        }
        fn makeDir(dir_path: []const u8) !void {
            try std.fs.cwd().makePath(dir_path);
        }
        fn exists(file_path: []const u8) !bool {
            std.fs.cwd().access(file_path, .{}) catch return false;
            return true;
        }
        fn deleteFile(file_path: []const u8) !void {
            try std.fs.cwd().deleteFile(file_path);
        }
        fn readDir(allocator: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
            var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
            defer dir.close();
            
            var entries = std.ArrayList([]u8).init(allocator);
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const platform = TestPlatform{};
    
    std.debug.print("=== Core Git Format Validation ===\n");
    
    // Test 1: Create a test repository with pack files
    std.debug.print("Test 1: Creating repository with pack files...\n");
    
    const tmp_dir = "/tmp/ziggit_validation_test";
    std.process.execv(allocator, &[_][]const u8{ "rm", "-rf", tmp_dir }) catch {};
    
    try std.fs.cwd().makePath(tmp_dir);
    
    // Initialize git repository
    var init_proc = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
    init_proc.cwd = tmp_dir;
    try init_proc.spawn();
    _ = try init_proc.wait();
    
    // Configure git identity
    var config_name = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
    config_name.cwd = tmp_dir;
    try config_name.spawn();
    _ = try config_name.wait();
    
    var config_email = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
    config_email.cwd = tmp_dir;
    try config_email.spawn();
    _ = try config_email.wait();
    
    // Add a remote
    var add_remote = std.process.Child.init(&[_][]const u8{ "git", "remote", "add", "origin", "https://github.com/test/repo.git" }, allocator);
    add_remote.cwd = tmp_dir;
    try add_remote.spawn();
    _ = try add_remote.wait();
    
    // Create multiple files and commits
    const test_files = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "README.md", .content = "# Test Repository\n\nThis is a test repo for ziggit validation.\n" },
        .{ .name = "src/main.zig", .content = "const std = @import(\"std\");\n\npub fn main() !void {\n    std.debug.print(\"Hello, World!\\n\", .{});\n}\n" },
        .{ .name = "build.zig", .content = "const std = @import(\"std\");\n\npub fn build(b: *std.Build) void {\n    // Build configuration\n}\n" },
        .{ .name = "docs/usage.md", .content = "# Usage\n\nHow to use this project.\n" },
        .{ .name = ".gitignore", .content = "zig-cache/\nzig-out/\n*.o\n*.so\n" },
    };
    
    for (test_files, 0..) |file, i| {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, file.name });
        defer allocator.free(file_path);
        
        if (std.fs.path.dirname(file_path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }
        try std.fs.cwd().writeFile(file_path, file.content);
        
        // Add and commit each file
        var add_proc = std.process.Child.init(&[_][]const u8{ "git", "add", "." }, allocator);
        add_proc.cwd = tmp_dir;
        try add_proc.spawn();
        _ = try add_proc.wait();
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Add {s}", .{file.name});
        defer allocator.free(commit_msg);
        
        var commit_proc = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", commit_msg }, allocator);
        commit_proc.cwd = tmp_dir;
        try commit_proc.spawn();
        _ = try commit_proc.wait();
        
        std.debug.print("  Created commit {} with {s}\n", .{ i + 1, file.name });
    }
    
    // Force pack files creation with aggressive garbage collection
    std.debug.print("  Running git gc to create pack files...\n");
    var gc_proc = std.process.Child.init(&[_][]const u8{ "git", "gc", "--aggressive", "--prune=now" }, allocator);
    gc_proc.cwd = tmp_dir;
    try gc_proc.spawn();
    _ = try gc_proc.wait();
    
    // Test 2: Validate pack files exist
    std.debug.print("\nTest 2: Validating pack files exist...\n");
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);
    
    var pack_found = false;
    var idx_found = false;
    
    var dir = std.fs.cwd().openDir(pack_dir, .{ .iterate = true }) catch {
        std.debug.print("  ERROR: Pack directory not found\n");
        return;
    };
    defer dir.close();
    
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_found = true;
            std.debug.print("  ✓ Found pack file: {s}\n", .{entry.name});
            
            // Test pack file analysis
            const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name });
            defer allocator.free(pack_path);
            
            const stats = objects.analyzePackFile(pack_path, platform, allocator) catch |err| {
                std.debug.print("  ERROR analyzing pack file: {}\n", .{err});
                continue;
            };
            
            std.debug.print("    Objects: {}, Version: {}, Size: {} bytes, Checksum valid: {}\n", .{
                stats.total_objects, stats.version, stats.file_size, stats.checksum_valid
            });
        }
        if (std.mem.endsWith(u8, entry.name, ".idx")) {
            idx_found = true;
            std.debug.print("  ✓ Found index file: {s}\n", .{entry.name});
        }
    }
    
    if (!pack_found or !idx_found) {
        std.debug.print("  ERROR: Pack files not created properly\n");
        return;
    }
    
    // Test 3: Load objects from pack files
    std.debug.print("\nTest 3: Loading objects from pack files...\n");
    
    const head_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/master", .{git_dir});
    defer allocator.free(head_ref_path);
    
    const head_content = try std.fs.cwd().readFileAlloc(allocator, head_ref_path, 1024);
    defer allocator.free(head_content);
    
    const head_hash = std.mem.trim(u8, head_content, " \t\n\r");
    std.debug.print("  HEAD commit: {s}\n", .{head_hash});
    
    // Load commit object
    const commit_obj = objects.GitObject.load(head_hash, git_dir, platform, allocator) catch |err| {
        std.debug.print("  ERROR loading commit: {}\n", .{err});
        return;
    };
    defer commit_obj.deinit(allocator);
    
    std.debug.print("  ✓ Loaded commit object: type={s}, size={} bytes\n", .{
        commit_obj.type.toString(), commit_obj.data.len
    });
    
    // Extract and load tree object
    if (std.mem.indexOf(u8, commit_obj.data, "\n")) |first_newline| {
        const first_line = commit_obj.data[0..first_newline];
        if (std.mem.startsWith(u8, first_line, "tree ")) {
            const tree_hash = first_line["tree ".len..];
            std.debug.print("  Tree hash: {s}\n", .{tree_hash});
            
            const tree_obj = objects.GitObject.load(tree_hash, git_dir, platform, allocator) catch |err| {
                std.debug.print("  ERROR loading tree: {}\n", .{err});
                return;
            };
            defer tree_obj.deinit(allocator);
            
            std.debug.print("  ✓ Loaded tree object: type={s}, size={} bytes\n", .{
                tree_obj.type.toString(), tree_obj.data.len
            });
        }
    }
    
    // Test 4: Config parsing
    std.debug.print("\nTest 4: Testing config parsing...\n");
    
    var git_config = config.loadGitConfig(git_dir, allocator) catch |err| {
        std.debug.print("  ERROR loading config: {}\n", .{err});
        return;
    };
    defer git_config.deinit();
    
    if (git_config.getUserName()) |name| {
        std.debug.print("  ✓ User name: {s}\n", .{name});
    }
    
    if (git_config.getUserEmail()) |email| {
        std.debug.print("  ✓ User email: {s}\n", .{email});
    }
    
    if (git_config.getRemoteUrl("origin")) |url| {
        std.debug.print("  ✓ Origin URL: {s}\n", .{url});
    }
    
    // Test 5: Index reading
    std.debug.print("\nTest 5: Testing index reading...\n");
    
    var git_index = index.Index.load(git_dir, platform, allocator) catch |err| {
        std.debug.print("  ERROR loading index: {}\n", .{err});
        return;
    };
    defer git_index.deinit();
    
    std.debug.print("  ✓ Loaded index with {} entries\n", .{git_index.entries.items.len});
    
    for (git_index.entries.items) |entry| {
        std.debug.print("    - {s} (mode: {}, size: {})\n", .{ entry.path, entry.mode, entry.size });
    }
    
    // Test 6: Refs resolution
    std.debug.print("\nTest 6: Testing refs resolution...\n");
    
    const resolved_head = refs.resolveRef(git_dir, "HEAD", platform, allocator) catch |err| {
        std.debug.print("  ERROR resolving HEAD: {}\n", .{err});
        return;
    };
    defer if (resolved_head) |h| allocator.free(h);
    
    if (resolved_head) |hash| {
        std.debug.print("  ✓ HEAD resolves to: {s}\n", .{hash});
    }
    
    const current_branch = refs.getCurrentBranch(git_dir, platform, allocator) catch |err| {
        std.debug.print("  ERROR getting current branch: {}\n", .{err});
        return;
    };
    defer allocator.free(current_branch);
    
    std.debug.print("  ✓ Current branch: {s}\n", .{current_branch});
    
    // Test 7: Ref validation
    std.debug.print("\nTest 7: Testing ref validation...\n");
    
    refs.validateRefName("refs/heads/master") catch |err| {
        std.debug.print("  ERROR: Valid ref name rejected: {}\n", .{err});
        return;
    };
    std.debug.print("  ✓ Valid ref name accepted\n");
    
    if (refs.validateRefName("refs/heads/..invalid")) {
        std.debug.print("  ERROR: Invalid ref name accepted\n");
        return;
    } else |_| {
        std.debug.print("  ✓ Invalid ref name rejected\n");
    }
    
    std.debug.print("\n=== All Tests Passed! ===\n");
    
    // Cleanup
    std.debug.print("Cleaning up test repository...\n");
    std.process.execv(allocator, &[_][]const u8{ "rm", "-rf", tmp_dir }) catch {};
    
    // Clear any caches
    refs.clearPackedRefsCache();
}