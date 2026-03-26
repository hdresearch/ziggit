// test/config_git_interop_test.zig
// Tests for git config parsing using the internal git.config module.
// Validates parsing correctness against known git config formats.

const std = @import("std");
const git = @import("git");
const testing = std.testing;

const GitConfig = git.config.GitConfig;

// ============================================================================
// Basic Parsing
// ============================================================================

test "parse empty config" {
    var config = try GitConfig.parseConfig(testing.allocator, "");
    defer config.deinit();
    try testing.expectEqual(@as(usize, 0), config.entries.items.len);
}

test "parse simple section with key-value" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	repositoryformatversion = 0
    );
    defer config.deinit();
    const val = config.get("core", null, "repositoryformatversion");
    try testing.expect(val != null);
    try testing.expectEqualStrings("0", val.?);
}

test "parse multiple sections" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	bare = false
        \\[user]
        \\	name = Test User
        \\	email = test@example.com
    );
    defer config.deinit();

    try testing.expectEqualStrings("false", config.get("core", null, "bare").?);
    try testing.expectEqualStrings("Test User", config.get("user", null, "name").?);
    try testing.expectEqualStrings("test@example.com", config.get("user", null, "email").?);
}

test "parse subsection (remote origin)" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[remote "origin"]
        \\	url = https://github.com/example/repo.git
        \\	fetch = +refs/heads/*:refs/remotes/origin/*
    );
    defer config.deinit();

    const url = config.get("remote", "origin", "url");
    try testing.expect(url != null);
    try testing.expectEqualStrings("https://github.com/example/repo.git", url.?);

    const fetch = config.get("remote", "origin", "fetch");
    try testing.expect(fetch != null);
    try testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", fetch.?);
}

test "parse branch tracking config" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[branch "main"]
        \\	remote = origin
        \\	merge = refs/heads/main
    );
    defer config.deinit();

    try testing.expectEqualStrings("origin", config.get("branch", "main", "remote").?);
    try testing.expectEqualStrings("refs/heads/main", config.get("branch", "main", "merge").?);
}

// ============================================================================
// Comments and Whitespace
// ============================================================================

test "comments are ignored" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\# This is a comment
        \\[core]
        \\; Another comment
        \\	bare = false
        \\# Inline comment line
    );
    defer config.deinit();

    try testing.expectEqual(@as(usize, 1), config.entries.items.len);
    try testing.expectEqualStrings("false", config.get("core", null, "bare").?);
}

test "blank lines are ignored" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\
        \\[core]
        \\
        \\	bare = false
        \\
    );
    defer config.deinit();

    try testing.expectEqualStrings("false", config.get("core", null, "bare").?);
}

test "values with surrounding whitespace are trimmed" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	key =   value with spaces   
    );
    defer config.deinit();

    // The implementation trims the value
    try testing.expectEqualStrings("value with spaces", config.get("core", null, "key").?);
}

// ============================================================================
// Quoted Values
// ============================================================================

test "quoted values have quotes stripped" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[user]
        \\	name = "Quoted Name"
    );
    defer config.deinit();

    try testing.expectEqualStrings("Quoted Name", config.get("user", null, "name").?);
}

// ============================================================================
// Convenience Methods
// ============================================================================

test "getRemoteUrl returns URL for named remote" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[remote "origin"]
        \\	url = git@github.com:user/repo.git
    );
    defer config.deinit();

    const url = config.getRemoteUrl("origin");
    try testing.expect(url != null);
    try testing.expectEqualStrings("git@github.com:user/repo.git", url.?);
}

test "getRemoteUrl returns null for nonexistent remote" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[remote "origin"]
        \\	url = https://example.com/repo.git
    );
    defer config.deinit();

    try testing.expect(config.getRemoteUrl("upstream") == null);
}

test "getUserName and getUserEmail" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[user]
        \\	name = Alice
        \\	email = alice@example.com
    );
    defer config.deinit();

    try testing.expectEqualStrings("Alice", config.getUserName().?);
    try testing.expectEqualStrings("alice@example.com", config.getUserEmail().?);
}

test "getBranchRemote and getBranchMerge" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[branch "feature"]
        \\	remote = upstream
        \\	merge = refs/heads/feature
    );
    defer config.deinit();

    try testing.expectEqualStrings("upstream", config.getBranchRemote("feature").?);
    try testing.expectEqualStrings("refs/heads/feature", config.getBranchMerge("feature").?);
}

// ============================================================================
// setValue and removeValue
// ============================================================================

test "setValue adds new entry" {
    var config = GitConfig.init(testing.allocator);
    defer config.deinit();

    try config.setValue("core", null, "bare", "true");
    try testing.expectEqualStrings("true", config.get("core", null, "bare").?);
}

test "setValue overwrites existing entry" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	bare = false
    );
    defer config.deinit();

    try config.setValue("core", null, "bare", "true");
    try testing.expectEqualStrings("true", config.get("core", null, "bare").?);
}

test "removeValue removes entry" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	bare = false
        \\	filemode = true
    );
    defer config.deinit();

    const removed = try config.removeValue("core", null, "bare");
    try testing.expect(removed);
    try testing.expect(config.get("core", null, "bare") == null);
    // filemode should still be there
    try testing.expectEqualStrings("true", config.get("core", null, "filemode").?);
}

test "removeValue returns false for nonexistent key" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	bare = false
    );
    defer config.deinit();

    const removed = try config.removeValue("core", null, "nonexistent");
    try testing.expect(!removed);
}

// ============================================================================
// Realistic Git Config
// ============================================================================

test "parse realistic git config" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	repositoryformatversion = 0
        \\	filemode = true
        \\	bare = false
        \\	logallrefupdates = true
        \\[remote "origin"]
        \\	url = https://github.com/user/project.git
        \\	fetch = +refs/heads/*:refs/remotes/origin/*
        \\[branch "main"]
        \\	remote = origin
        \\	merge = refs/heads/main
        \\[user]
        \\	name = Developer
        \\	email = dev@company.com
    );
    defer config.deinit();

    // Verify all values
    try testing.expectEqualStrings("0", config.get("core", null, "repositoryformatversion").?);
    try testing.expectEqualStrings("true", config.get("core", null, "filemode").?);
    try testing.expectEqualStrings("false", config.get("core", null, "bare").?);
    try testing.expectEqualStrings("https://github.com/user/project.git", config.getRemoteUrl("origin").?);
    try testing.expectEqualStrings("origin", config.getBranchRemote("main").?);
    try testing.expectEqualStrings("Developer", config.getUserName().?);
    try testing.expectEqualStrings("dev@company.com", config.getUserEmail().?);
}

// ============================================================================
// Cross-validation with real git config file
// ============================================================================

test "parse config from ziggit-initialized repo matches expected structure" {
    const path = "/tmp/ziggit_configtest_init";
    std.fs.deleteTreeAbsolute(path) catch {};
    defer std.fs.deleteTreeAbsolute(path) catch {};

    // Create directory and initialize with ziggit's init
    try std.fs.makeDirAbsolute(path);
    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    // Use git init to create a known config
    var child = std.process.Child.init(&.{ "git", "init", "-q", path }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    _ = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024);
    _ = try child.stderr.?.reader().readAllAlloc(testing.allocator, 1024);
    _ = try child.wait();

    // Parse the config
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config", .{git_dir});
    defer testing.allocator.free(config_path);

    var config = GitConfig.init(testing.allocator);
    defer config.deinit();
    try config.parseFromFile(config_path);

    // Git-initialized repos always have repositoryformatversion
    const version = config.get("core", null, "repositoryformatversion");
    try testing.expect(version != null);
    try testing.expectEqualStrings("0", version.?);
}

// ============================================================================
// getAll (multi-value)
// ============================================================================

test "getAll returns multiple values for repeated key" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[remote "origin"]
        \\	url = https://github.com/user/repo.git
        \\	fetch = +refs/heads/*:refs/remotes/origin/*
        \\[remote "upstream"]
        \\	url = https://github.com/upstream/repo.git
    );
    defer config.deinit();

    // Get all url values for remote sections
    // Note: getAll matches section+subsection+name, so we get specific remote
    const urls = try config.getAll("remote", "origin", "url", testing.allocator);
    defer testing.allocator.free(urls);
    try testing.expectEqual(@as(usize, 1), urls.len);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "key-value without section is ignored" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\bare = false
        \\[core]
        \\	filemode = true
    );
    defer config.deinit();

    // "bare = false" without a section should be ignored
    try testing.expect(config.get("", null, "bare") == null);
    // But [core] section entry should work
    try testing.expectEqualStrings("true", config.get("core", null, "filemode").?);
}

test "nonexistent key returns null" {
    var config = try GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	bare = false
    );
    defer config.deinit();

    try testing.expect(config.get("core", null, "nonexistent") == null);
    try testing.expect(config.get("nonexistent", null, "bare") == null);
}
