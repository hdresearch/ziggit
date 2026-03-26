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

/// Test enhanced pack file functionality
fn testPackFileEnhancements(allocator: std.mem.Allocator) !void {
    std.debug.print("Testing enhanced pack file functionality...\n");
    
    const platform = TestPlatform{};
    const tmp_dir = "/tmp/ziggit_enhanced_pack_test";
    
    // Clean up any previous test
    std.process.execv(allocator, &[_][]const u8{ "rm", "-rf", tmp_dir }) catch {};
    
    // Create test repository with complex structure
    try std.fs.cwd().makePath(tmp_dir);
    
    var init_proc = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
    init_proc.cwd = tmp_dir;
    try init_proc.spawn();
    _ = try init_proc.wait();
    
    // Configure git
    var config_name = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Enhanced Test" }, allocator);
    config_name.cwd = tmp_dir;
    try config_name.spawn();
    _ = try config_name.wait();
    
    var config_email = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "enhanced@test.com" }, allocator);
    config_email.cwd = tmp_dir;
    try config_email.spawn();
    _ = try config_email.wait();
    
    // Create multiple branches and complex commit history
    const branches = [_][]const u8{ "feature1", "feature2", "bugfix" };
    
    for (branches, 0..) |branch, i| {
        // Create branch
        var create_branch = std.process.Child.init(&[_][]const u8{ "git", "checkout", "-b", branch }, allocator);
        create_branch.cwd = tmp_dir;
        try create_branch.spawn();
        _ = try create_branch.wait();
        
        // Create files for this branch
        const file_name = try std.fmt.allocPrint(allocator, "branch_{s}_{}.txt", .{ branch, i });
        defer allocator.free(file_name);
        
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, file_name });
        defer allocator.free(file_path);
        
        const file_content = try std.fmt.allocPrint(allocator, "Content for branch {s}\nLine 2\nLine 3 with more content to create larger objects\n", .{branch});
        defer allocator.free(file_content);
        
        try std.fs.cwd().writeFile(file_path, file_content);
        
        var add_proc = std.process.Child.init(&[_][]const u8{ "git", "add", "." }, allocator);
        add_proc.cwd = tmp_dir;
        try add_proc.spawn();
        _ = try add_proc.wait();
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Add {s}", .{file_name});
        defer allocator.free(commit_msg);
        
        var commit_proc = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", commit_msg }, allocator);
        commit_proc.cwd = tmp_dir;
        try commit_proc.spawn();
        _ = try commit_proc.wait();
        
        // Go back to master
        var checkout_master = std.process.Child.init(&[_][]const u8{ "git", "checkout", "master" }, allocator);
        checkout_master.cwd = tmp_dir;
        try checkout_master.spawn();
        _ = try checkout_master.wait();
    }
    
    // Create pack files
    var gc_proc = std.process.Child.init(&[_][]const u8{ "git", "gc", "--aggressive", "--prune=now" }, allocator);
    gc_proc.cwd = tmp_dir;
    try gc_proc.spawn();
    _ = try gc_proc.wait();
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    
    // Test enhanced pack file analysis
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);
    
    var dir = try std.fs.cwd().openDir(pack_dir, .{ .iterate = true });
    defer dir.close();
    
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name });
            defer allocator.free(pack_path);
            
            // Test pack file analysis
            const stats = try objects.analyzePackFile(pack_path, platform, allocator);
            std.debug.print("  Pack file stats: objects={}, version={}, size={}, checksum_valid={}\n", .{
                stats.total_objects, stats.version, stats.file_size, stats.checksum_valid
            });
            
            // Test pack file info (header-only)
            const info = try objects.getPackFileInfo(pack_path, platform, allocator);
            std.debug.print("  Pack file info: objects={}, version={}, size={}\n", .{
                info.total_objects, info.version, info.file_size
            });
        }
    }
    
    // Test loading objects from different branches
    for (branches) |branch| {
        const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
        defer allocator.free(branch_ref);
        
        if (refs.resolveRef(git_dir, branch_ref, platform, allocator)) |commit_hash| {
            defer allocator.free(commit_hash);
            
            const commit_obj = objects.GitObject.load(commit_hash, git_dir, platform, allocator) catch continue;
            defer commit_obj.deinit(allocator);
            
            std.debug.print("  ✓ Loaded commit for branch {s}: {s} bytes\n", .{ branch, @tagName(commit_obj.type) });
        } else |_| {}
    }
    
    std.debug.print("  ✓ Enhanced pack file tests passed\n");
    
    // Cleanup
    std.process.execv(allocator, &[_][]const u8{ "rm", "-rf", tmp_dir }) catch {};
}

/// Test enhanced config parsing
fn testConfigEnhancements(allocator: std.mem.Allocator) !void {
    std.debug.print("Testing enhanced config parsing...\n");
    
    // Test complex config file with edge cases
    const complex_config =
        \\# Complex git configuration with edge cases
        \\[core]
        \\    editor = "vim -n"
        \\    autocrlf = input
        \\    quotepath = false
        \\    # This is a comment within a section
        \\    
        \\[user]
        \\    name = John \"Johnny\" Doe
        \\    email = john.doe+git@example.com
        \\    signingkey = 0x1234567890ABCDEF
        \\
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\    pushurl = git@github.com:user/repo.git
        \\
        \\[remote "upstream"]
        \\    url = https://github.com/upstream/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/upstream/*
        \\
        \\[branch "main"]
        \\    remote = origin
        \\    merge = refs/heads/main
        \\    rebase = true
        \\
        \\[branch "feature/complex-name"]
        \\    remote = upstream
        \\    merge = refs/heads/feature/complex-name
        \\
        \\[alias]
        \\    st = status
        \\    co = checkout
        \\    br = branch
        \\    lg = log --oneline --graph
        \\
        \\[diff]
        \\    tool = vimdiff
        \\    algorithm = patience
        \\
        \\[merge]
        \\    tool = vimdiff
        \\    ff = false
        \\
        \\[push]
        \\    default = simple
        \\    followTags = true
    ;
    
    var git_config = try config.GitConfig.parseConfig(allocator, complex_config);
    defer git_config.deinit();
    
    // Test basic config values
    if (git_config.getUserName()) |name| {
        std.debug.print("  User name: {s}\n", .{name});
        if (!std.mem.eql(u8, name, "John \"Johnny\" Doe")) {
            std.debug.print("  ERROR: Unexpected user name\n");
            return error.TestFailed;
        }
    }
    
    if (git_config.getUserEmail()) |email| {
        std.debug.print("  User email: {s}\n", .{email});
        if (!std.mem.eql(u8, email, "john.doe+git@example.com")) {
            std.debug.print("  ERROR: Unexpected user email\n");
            return error.TestFailed;
        }
    }
    
    // Test remote URLs
    if (git_config.getRemoteUrl("origin")) |url| {
        std.debug.print("  Origin URL: {s}\n", .{url});
        if (!std.mem.eql(u8, url, "https://github.com/user/repo.git")) {
            std.debug.print("  ERROR: Unexpected origin URL\n");
            return error.TestFailed;
        }
    }
    
    if (git_config.getRemoteUrl("upstream")) |url| {
        std.debug.print("  Upstream URL: {s}\n", .{url});
    }
    
    // Test branch configuration
    if (git_config.getBranchRemote("main")) |remote| {
        std.debug.print("  Main branch remote: {s}\n", .{remote});
    }
    
    if (git_config.getBranchRemote("feature/complex-name")) |remote| {
        std.debug.print("  Feature branch remote: {s}\n", .{remote});
    }
    
    // Test complex config queries
    if (git_config.get("core", null, "editor")) |editor| {
        std.debug.print("  Editor: {s}\n", .{editor});
    }
    
    if (git_config.get("alias", null, "lg")) |alias| {
        std.debug.print("  Log alias: {s}\n", .{alias});
    }
    
    std.debug.print("  ✓ Enhanced config parsing tests passed\n");
}

/// Test enhanced refs functionality
fn testRefsEnhancements(allocator: std.mem.Allocator) !void {
    std.debug.print("Testing enhanced refs functionality...\n");
    
    const platform = TestPlatform{};
    const tmp_dir = "/tmp/ziggit_enhanced_refs_test";
    
    // Create test repository
    std.process.execv(allocator, &[_][]const u8{ "rm", "-rf", tmp_dir }) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    
    var init_proc = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
    init_proc.cwd = tmp_dir;
    try init_proc.spawn();
    _ = try init_proc.wait();
    
    var config_name = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Refs Test" }, allocator);
    config_name.cwd = tmp_dir;
    try config_name.spawn();
    _ = try config_name.wait();
    
    var config_email = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "refs@test.com" }, allocator);
    config_email.cwd = tmp_dir;
    try config_email.spawn();
    _ = try config_email.wait();
    
    // Create initial commit
    const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{tmp_dir});
    defer allocator.free(test_file);
    try std.fs.cwd().writeFile(test_file, "Initial content");
    
    var add_proc = std.process.Child.init(&[_][]const u8{ "git", "add", "." }, allocator);
    add_proc.cwd = tmp_dir;
    try add_proc.spawn();
    _ = try add_proc.wait();
    
    var commit_proc = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Initial commit" }, allocator);
    commit_proc.cwd = tmp_dir;
    try commit_proc.spawn();
    _ = try commit_proc.wait();
    
    // Create multiple branches
    const test_branches = [_][]const u8{ "feature/test", "bugfix/issue-123", "develop" };
    
    for (test_branches) |branch| {
        var create_branch = std.process.Child.init(&[_][]const u8{ "git", "branch", branch }, allocator);
        create_branch.cwd = tmp_dir;
        try create_branch.spawn();
        _ = try create_branch.wait();
    }
    
    // Create tags
    var create_tag = std.process.Child.init(&[_][]const u8{ "git", "tag", "v1.0.0" }, allocator);
    create_tag.cwd = tmp_dir;
    try create_tag.spawn();
    _ = try create_tag.wait();
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    
    // Test batch ref resolution
    std.debug.print("  Testing batch ref resolution...\n");
    const ref_names = [_][]const u8{ "HEAD", "master", "feature/test", "v1.0.0", "nonexistent" };
    const results = try refs.resolveRefs(git_dir, &ref_names, platform, allocator);
    defer {
        for (results) |result| {
            if (result) |hash| allocator.free(hash);
        }
        allocator.free(results);
    }
    
    var resolved_count: u32 = 0;
    for (results, 0..) |result, i| {
        if (result) |hash| {
            std.debug.print("    {s} -> {s}\n", .{ ref_names[i], hash });
            resolved_count += 1;
        } else {
            std.debug.print("    {s} -> (not found)\n", .{ref_names[i]});
        }
    }
    
    if (resolved_count < 3) {
        std.debug.print("  ERROR: Too few refs resolved\n");
        return error.TestFailed;
    }
    
    // Test ref name validation
    std.debug.print("  Testing ref name validation...\n");
    
    // Valid ref names should pass
    refs.validateRefName("refs/heads/master") catch {
        std.debug.print("  ERROR: Valid ref name rejected\n");
        return error.TestFailed;
    };
    
    refs.validateRefName("refs/tags/v1.0.0") catch {
        std.debug.print("  ERROR: Valid tag ref rejected\n");
        return error.TestFailed;
    };
    
    // Invalid ref names should fail
    if (refs.validateRefName("refs/heads/../invalid")) {
        std.debug.print("  ERROR: Invalid ref name accepted\n");
        return error.TestFailed;
    } else |_| {}
    
    if (refs.validateRefName("refs/heads/has space")) {
        std.debug.print("  ERROR: Ref name with space accepted\n");
        return error.TestFailed;
    } else |_| {}
    
    // Test ref suggestions
    std.debug.print("  Testing ref suggestions...\n");
    const suggestions = try refs.suggestSimilarRefs(git_dir, "feat", platform, allocator);
    defer {
        for (suggestions) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(suggestions);
    }
    
    for (suggestions) |suggestion| {
        std.debug.print("    Suggestion: {s}\n", .{suggestion});
    }
    
    std.debug.print("  ✓ Enhanced refs tests passed\n");
    
    // Clear cache and cleanup
    refs.clearPackedRefsCache();
    std.process.execv(allocator, &[_][]const u8{ "rm", "-rf", tmp_dir }) catch {};
}

/// Test enhanced index functionality
fn testIndexEnhancements(allocator: std.mem.Allocator) !void {
    std.debug.print("Testing enhanced index functionality...\n");
    
    const platform = TestPlatform{};
    const tmp_dir = "/tmp/ziggit_enhanced_index_test";
    
    // Create test repository with complex index
    std.process.execv(allocator, &[_][]const u8{ "rm", "-rf", tmp_dir }) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    
    var init_proc = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
    init_proc.cwd = tmp_dir;
    try init_proc.spawn();
    _ = try init_proc.wait();
    
    var config_name = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Index Test" }, allocator);
    config_name.cwd = tmp_dir;
    try config_name.spawn();
    _ = try config_name.wait();
    
    var config_email = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "index@test.com" }, allocator);
    config_email.cwd = tmp_dir;
    try config_email.spawn();
    _ = try config_email.wait();
    
    // Create complex directory structure with various file types
    const test_dirs = [_][]const u8{ "src", "tests", "docs", "examples/basic", "examples/advanced" };
    
    for (test_dirs) |dir| {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, dir });
        defer allocator.free(dir_path);
        try std.fs.cwd().makePath(dir_path);
    }
    
    // Create files with various sizes and types
    const test_files = [_]struct { path: []const u8, content: []const u8 }{
        .{ .path = "README.md", .content = "# Test Repository\n\nLong content here to test index handling with different file sizes.\n" },
        .{ .path = "src/main.zig", .content = "const std = @import(\"std\");\npub fn main() !void {}\n" },
        .{ .path = "src/lib.zig", .content = "pub const VERSION = \"1.0.0\";\n" },
        .{ .path = "tests/test_basic.zig", .content = "const testing = @import(\"std\").testing;\n\ntest \"basic\" {\n    try testing.expect(true);\n}\n" },
        .{ .path = "docs/api.md", .content = "# API Documentation\n\nDetailed API docs...\n" },
        .{ .path = "examples/basic/hello.zig", .content = "const std = @import(\"std\");\nconst print = std.debug.print;\n\npub fn main() void {\n    print(\"Hello!\\n\", .{});\n}\n" },
        .{ .path = "examples/advanced/complex.zig", .content = "// Complex example with longer content to test index with larger files\nconst std = @import(\"std\");\n\npub fn complexFunction() void {\n    // Implementation details...\n}\n" },
        .{ .path = ".gitignore", .content = "zig-cache/\nzig-out/\n*.o\n*.so\n.DS_Store\n" },
    };
    
    for (test_files) |file| {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, file.path });
        defer allocator.free(file_path);
        
        try std.fs.cwd().writeFile(file_path, file.content);
    }
    
    // Add all files to index
    var add_proc = std.process.Child.init(&[_][]const u8{ "git", "add", "." }, allocator);
    add_proc.cwd = tmp_dir;
    try add_proc.spawn();
    _ = try add_proc.wait();
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    
    // Test loading the complex index
    std.debug.print("  Loading complex index...\n");
    var git_index = try index.Index.load(git_dir, platform, allocator);
    defer git_index.deinit();
    
    std.debug.print("    Index has {} entries\n", .{git_index.entries.items.len});
    
    if (git_index.entries.items.len != test_files.len) {
        std.debug.print("  ERROR: Expected {} index entries, got {}\n", .{ test_files.len, git_index.entries.items.len });
        return error.TestFailed;
    }
    
    // Verify index entries are properly sorted
    for (git_index.entries.items[1..], 1..) |entry, i| {
        const prev_entry = git_index.entries.items[i - 1];
        if (std.mem.order(u8, prev_entry.path, entry.path) != .lt) {
            std.debug.print("  ERROR: Index entries are not properly sorted\n");
            return error.TestFailed;
        }
    }
    
    // Test specific file lookups
    for (test_files) |test_file| {
        if (git_index.getEntry(test_file.path)) |entry| {
            std.debug.print("    Found entry: {s} (mode: {}, size: {})\n", .{ entry.path, entry.mode, entry.size });
        } else {
            std.debug.print("  ERROR: Entry not found: {s}\n", .{test_file.path});
            return error.TestFailed;
        }
    }
    
    std.debug.print("  ✓ Enhanced index tests passed\n");
    
    // Cleanup
    std.process.execv(allocator, &[_][]const u8{ "rm", "-rf", tmp_dir }) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("=== Enhanced Core Git Formats Test ===\n\n");
    
    try testPackFileEnhancements(allocator);
    std.debug.print("\n");
    
    try testConfigEnhancements(allocator);
    std.debug.print("\n");
    
    try testRefsEnhancements(allocator);
    std.debug.print("\n");
    
    try testIndexEnhancements(allocator);
    std.debug.print("\n");
    
    std.debug.print("=== All Enhanced Tests Passed! ===\n");
}