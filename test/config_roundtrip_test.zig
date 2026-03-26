// test/config_roundtrip_test.zig
// Tests for config parsing via the git module, with edge cases
const std = @import("std");
const testing = std.testing;
const git = @import("git");

// ============================================================================
// GitConfig.parseConfig - basic functionality
// ============================================================================

test "config: empty string produces empty config" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, "");
    defer cfg.deinit();
    try testing.expect(cfg.get("core", null, "bare") == null);
}

test "config: single section with one key" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	bare = false
    );
    defer cfg.deinit();
    const val = cfg.get("core", null, "bare");
    try testing.expect(val != null);
    try testing.expectEqualStrings("false", val.?);
}

test "config: multiple keys in one section" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	bare = false
        \\	repositoryformatversion = 0
        \\	filemode = true
    );
    defer cfg.deinit();
    try testing.expectEqualStrings("false", cfg.get("core", null, "bare").?);
    try testing.expectEqualStrings("0", cfg.get("core", null, "repositoryformatversion").?);
    try testing.expectEqualStrings("true", cfg.get("core", null, "filemode").?);
}

test "config: multiple sections" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	bare = false
        \\[user]
        \\	name = Test User
        \\	email = test@example.com
    );
    defer cfg.deinit();
    try testing.expectEqualStrings("false", cfg.get("core", null, "bare").?);
    try testing.expectEqualStrings("Test User", cfg.get("user", null, "name").?);
    try testing.expectEqualStrings("test@example.com", cfg.get("user", null, "email").?);
}

test "config: getUserName and getUserEmail" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[user]
        \\	name = Alice
        \\	email = alice@dev.com
    );
    defer cfg.deinit();
    try testing.expectEqualStrings("Alice", cfg.getUserName().?);
    try testing.expectEqualStrings("alice@dev.com", cfg.getUserEmail().?);
}

// ============================================================================
// Subsections (remotes, branches)
// ============================================================================

test "config: remote subsection" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[remote "origin"]
        \\	url = https://github.com/user/repo.git
        \\	fetch = +refs/heads/*:refs/remotes/origin/*
    );
    defer cfg.deinit();
    const url = cfg.get("remote", "origin", "url");
    try testing.expect(url != null);
    try testing.expectEqualStrings("https://github.com/user/repo.git", url.?);
}

test "config: getRemoteUrl convenience" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[remote "origin"]
        \\	url = git@github.com:user/repo.git
    );
    defer cfg.deinit();
    try testing.expectEqualStrings("git@github.com:user/repo.git", cfg.getRemoteUrl("origin").?);
}

test "config: branch subsection" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[branch "main"]
        \\	remote = origin
        \\	merge = refs/heads/main
    );
    defer cfg.deinit();
    try testing.expectEqualStrings("origin", cfg.getBranchRemote("main").?);
    try testing.expectEqualStrings("refs/heads/main", cfg.getBranchMerge("main").?);
}

test "config: multiple remotes" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[remote "origin"]
        \\	url = https://github.com/user/repo.git
        \\[remote "upstream"]
        \\	url = https://github.com/upstream/repo.git
    );
    defer cfg.deinit();
    try testing.expectEqualStrings("https://github.com/user/repo.git", cfg.getRemoteUrl("origin").?);
    try testing.expectEqualStrings("https://github.com/upstream/repo.git", cfg.getRemoteUrl("upstream").?);
}

// ============================================================================
// Edge cases
// ============================================================================

test "config: comments are ignored" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\# This is a comment
        \\[core]
        \\	bare = false
        \\; Another comment
        \\	filemode = true
    );
    defer cfg.deinit();
    try testing.expectEqualStrings("false", cfg.get("core", null, "bare").?);
    try testing.expectEqualStrings("true", cfg.get("core", null, "filemode").?);
}

test "config: blank lines are ignored" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\
        \\	bare = false
        \\
        \\
        \\	filemode = true
    );
    defer cfg.deinit();
    try testing.expectEqualStrings("false", cfg.get("core", null, "bare").?);
    try testing.expectEqualStrings("true", cfg.get("core", null, "filemode").?);
}

test "config: nonexistent key returns null" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	bare = false
    );
    defer cfg.deinit();
    try testing.expect(cfg.get("core", null, "nonexistent") == null);
    try testing.expect(cfg.get("nosection", null, "bare") == null);
}

test "config: nonexistent remote returns null" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[remote "origin"]
        \\	url = https://example.com
    );
    defer cfg.deinit();
    try testing.expect(cfg.getRemoteUrl("upstream") == null);
}

test "config: value with equals sign" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[filter "lfs"]
        \\	clean = git-lfs clean -- %f
    );
    defer cfg.deinit();
    const val = cfg.get("filter", "lfs", "clean");
    try testing.expect(val != null);
    try testing.expectEqualStrings("git-lfs clean -- %f", val.?);
}

test "config: value with spaces" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[user]
        \\	name = John Doe III
    );
    defer cfg.deinit();
    try testing.expectEqualStrings("John Doe III", cfg.getUserName().?);
}

// ============================================================================
// setValue / removeValue
// ============================================================================

test "config: setValue adds new entry" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, "");
    defer cfg.deinit();

    try cfg.setValue("core", null, "bare", "true");
    try testing.expectEqualStrings("true", cfg.get("core", null, "bare").?);
}

test "config: setValue overwrites existing" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	bare = false
    );
    defer cfg.deinit();

    try cfg.setValue("core", null, "bare", "true");
    try testing.expectEqualStrings("true", cfg.get("core", null, "bare").?);
}

test "config: removeValue removes entry" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	bare = false
        \\	filemode = true
    );
    defer cfg.deinit();

    const removed = try cfg.removeValue("core", null, "bare");
    try testing.expect(removed);
    try testing.expect(cfg.get("core", null, "bare") == null);
    // Other key still exists
    try testing.expectEqualStrings("true", cfg.get("core", null, "filemode").?);
}

test "config: removeValue returns false for missing key" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	bare = false
    );
    defer cfg.deinit();

    const removed = try cfg.removeValue("core", null, "nonexistent");
    try testing.expect(!removed);
}

// ============================================================================
// Realistic git config
// ============================================================================

test "config: full realistic config" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\	repositoryformatversion = 0
        \\	filemode = true
        \\	bare = false
        \\	logallrefupdates = true
        \\[user]
        \\	name = Developer
        \\	email = dev@company.com
        \\[remote "origin"]
        \\	url = git@github.com:org/repo.git
        \\	fetch = +refs/heads/*:refs/remotes/origin/*
        \\[branch "main"]
        \\	remote = origin
        \\	merge = refs/heads/main
        \\[branch "develop"]
        \\	remote = origin
        \\	merge = refs/heads/develop
    );
    defer cfg.deinit();

    try testing.expectEqualStrings("0", cfg.get("core", null, "repositoryformatversion").?);
    try testing.expectEqualStrings("true", cfg.get("core", null, "filemode").?);
    try testing.expectEqualStrings("false", cfg.get("core", null, "bare").?);
    try testing.expectEqualStrings("Developer", cfg.getUserName().?);
    try testing.expectEqualStrings("dev@company.com", cfg.getUserEmail().?);
    try testing.expectEqualStrings("git@github.com:org/repo.git", cfg.getRemoteUrl("origin").?);
    try testing.expectEqualStrings("origin", cfg.getBranchRemote("main").?);
    try testing.expectEqualStrings("refs/heads/main", cfg.getBranchMerge("main").?);
    try testing.expectEqualStrings("origin", cfg.getBranchRemote("develop").?);
    try testing.expectEqualStrings("refs/heads/develop", cfg.getBranchMerge("develop").?);
}
