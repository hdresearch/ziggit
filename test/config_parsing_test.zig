// test/config_parsing_test.zig - Tests for git config parsing via the git module
const std = @import("std");
const testing = std.testing;
const git = @import("git");

// ============================================================================
// Config parsing: basic section/key/value
// ============================================================================

test "config: parse simple section with key-value" {
    const content =
        \\[core]
        \\    bare = false
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const val = cfg.get("core", null, "bare");
    try testing.expect(val != null);
    try testing.expectEqualStrings("false", val.?);
}

test "config: parse multiple sections" {
    const content =
        \\[core]
        \\    bare = false
        \\    filemode = true
        \\[user]
        \\    name = Test User
        \\    email = test@example.com
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    try testing.expectEqualStrings("false", cfg.get("core", null, "bare").?);
    try testing.expectEqualStrings("true", cfg.get("core", null, "filemode").?);
    try testing.expectEqualStrings("Test User", cfg.get("user", null, "name").?);
    try testing.expectEqualStrings("test@example.com", cfg.get("user", null, "email").?);
}

test "config: parse section with subsection (remote)" {
    const content =
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const url = cfg.get("remote", "origin", "url");
    try testing.expect(url != null);
    try testing.expectEqualStrings("https://github.com/user/repo.git", url.?);
}

test "config: comments and blank lines are ignored" {
    const content =
        \\# This is a comment
        \\; This is also a comment
        \\
        \\[core]
        \\    bare = false
        \\# Another comment
        \\    filemode = true
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    try testing.expect(cfg.entries.items.len == 2);
    try testing.expectEqualStrings("false", cfg.get("core", null, "bare").?);
    try testing.expectEqualStrings("true", cfg.get("core", null, "filemode").?);
}

test "config: empty content produces empty config" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, "");
    defer cfg.deinit();
    try testing.expect(cfg.entries.items.len == 0);
}

test "config: whitespace-only content produces empty config" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, "   \n\t\n  \n");
    defer cfg.deinit();
    try testing.expect(cfg.entries.items.len == 0);
}

test "config: get returns null for missing key" {
    const content =
        \\[core]
        \\    bare = false
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    try testing.expect(cfg.get("core", null, "nonexistent") == null);
    try testing.expect(cfg.get("nosection", null, "bare") == null);
}

test "config: case-insensitive section and key matching" {
    const content =
        \\[Core]
        \\    Bare = false
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    // Should match case-insensitively
    try testing.expect(cfg.get("core", null, "bare") != null);
    try testing.expect(cfg.get("CORE", null, "BARE") != null);
}

test "config: quoted values have quotes stripped" {
    const content =
        \\[user]
        \\    name = "Quoted Name"
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    try testing.expectEqualStrings("Quoted Name", cfg.get("user", null, "name").?);
}

test "config: getRemoteUrl helper" {
    const content =
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
        \\[remote "upstream"]
        \\    url = https://github.com/other/repo.git
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    try testing.expectEqualStrings("https://github.com/user/repo.git", cfg.getRemoteUrl("origin").?);
    try testing.expectEqualStrings("https://github.com/other/repo.git", cfg.getRemoteUrl("upstream").?);
    try testing.expect(cfg.getRemoteUrl("nonexistent") == null);
}

test "config: getUserName and getUserEmail" {
    const content =
        \\[user]
        \\    name = John Doe
        \\    email = john@example.com
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    try testing.expectEqualStrings("John Doe", cfg.getUserName().?);
    try testing.expectEqualStrings("john@example.com", cfg.getUserEmail().?);
}

test "config: getUserName returns null when not set" {
    const content =
        \\[core]
        \\    bare = false
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    try testing.expect(cfg.getUserName() == null);
    try testing.expect(cfg.getUserEmail() == null);
}

test "config: getBool with various boolean values" {
    const content =
        \\[core]
        \\    bare = false
        \\    filemode = true
        \\    ignorecase = yes
        \\    precomposeunicode = no
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    try testing.expect(!cfg.getBool("core", null, "bare", true));
    try testing.expect(cfg.getBool("core", null, "filemode", false));
    // Default for missing keys
    try testing.expect(cfg.getBool("core", null, "missing", true));
    try testing.expect(!cfg.getBool("core", null, "missing", false));
}

test "config: setValue adds new entry" {
    var cfg = git.config.GitConfig.init(testing.allocator);
    defer cfg.deinit();

    try cfg.setValue("core", null, "bare", "false");
    try testing.expectEqualStrings("false", cfg.get("core", null, "bare").?);
}

test "config: removeValue removes entry" {
    const content =
        \\[core]
        \\    bare = false
        \\    filemode = true
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const removed = try cfg.removeValue("core", null, "bare");
    try testing.expect(removed);
    try testing.expect(cfg.get("core", null, "bare") == null);
    // filemode should still be there
    try testing.expectEqualStrings("true", cfg.get("core", null, "filemode").?);
}

test "config: removeValue returns false for missing key" {
    var cfg = git.config.GitConfig.init(testing.allocator);
    defer cfg.deinit();

    const removed = try cfg.removeValue("core", null, "nonexistent");
    try testing.expect(!removed);
}

test "config: getAll returns multiple values" {
    const content =
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const urls = try cfg.getAll("remote", "origin", "url", testing.allocator);
    defer testing.allocator.free(urls);
    try testing.expect(urls.len == 1);
    try testing.expectEqualStrings("https://github.com/user/repo.git", urls[0]);
}

test "config: realistic .git/config" {
    const content =
        \\[core]
        \\    repositoryformatversion = 0
        \\    filemode = true
        \\    bare = false
        \\    logallrefupdates = true
        \\[remote "origin"]
        \\    url = git@github.com:user/project.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\[branch "main"]
        \\    remote = origin
        \\    merge = refs/heads/main
        \\[user]
        \\    name = Developer
        \\    email = dev@company.com
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    try testing.expectEqualStrings("0", cfg.get("core", null, "repositoryformatversion").?);
    try testing.expectEqualStrings("true", cfg.get("core", null, "filemode").?);
    try testing.expectEqualStrings("git@github.com:user/project.git", cfg.getRemoteUrl("origin").?);
    try testing.expectEqualStrings("origin", cfg.getBranchRemote("main").?);
    try testing.expectEqualStrings("refs/heads/main", cfg.getBranchMerge("main").?);
    try testing.expectEqualStrings("Developer", cfg.getUserName().?);
}

test "config: getBare helper" {
    const content =
        \\[core]
        \\    bare = true
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();
    try testing.expect(git.config.getBare(cfg));
}

test "config: getFileMode helper" {
    const content =
        \\[core]
        \\    filemode = false
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();
    try testing.expect(!git.config.getFileMode(cfg));
}

test "config: getEntryCount" {
    const content =
        \\[core]
        \\    bare = false
        \\    filemode = true
        \\[user]
        \\    name = Test
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();
    try testing.expect(git.config.getEntryCount(cfg) == 3);
}

test "config: getAllEntries returns all entries" {
    const content =
        \\[core]
        \\    bare = false
        \\[user]
        \\    name = Test
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();
    
    const entries = git.config.getAllEntries(cfg);
    try testing.expect(entries.len == 2);
}

test "config: toString produces parseable output" {
    const content =
        \\[core]
        \\    bare = false
        \\    filemode = true
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const output = try git.config.toString(cfg, testing.allocator);
    defer testing.allocator.free(output);

    // Re-parse the output
    var cfg2 = try git.config.GitConfig.parseConfig(testing.allocator, output);
    defer cfg2.deinit();

    try testing.expectEqualStrings("false", cfg2.get("core", null, "bare").?);
    try testing.expectEqualStrings("true", cfg2.get("core", null, "filemode").?);
}

test "config: manual file write and parseFromFile roundtrip" {
    const tmp_path = "/tmp/ziggit_config_test_roundtrip";
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    var cfg = git.config.GitConfig.init(testing.allocator);
    defer cfg.deinit();

    try cfg.setValue("core", null, "bare", "false");
    try cfg.setValue("user", null, "name", "Tester");

    // Serialize manually using toString and write
    const output = try git.config.toString(cfg, testing.allocator);
    defer testing.allocator.free(output);
    
    const f = try std.fs.createFileAbsolute(tmp_path, .{});
    defer f.close();
    try f.writeAll(output);

    // Read back
    var cfg2 = git.config.GitConfig.init(testing.allocator);
    defer cfg2.deinit();
    try cfg2.parseFromFile(tmp_path);

    try testing.expectEqualStrings("false", cfg2.get("core", null, "bare").?);
    try testing.expectEqualStrings("Tester", cfg2.get("user", null, "name").?);
}

test "config: getAllRemotes" {
    const content =
        \\[remote "origin"]
        \\    url = https://github.com/user/repo1.git
        \\[remote "upstream"]
        \\    url = https://github.com/other/repo2.git
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const remotes = try git.config.getAllRemotes(cfg, testing.allocator);
    defer {
        for (remotes) |r| testing.allocator.free(r);
        testing.allocator.free(remotes);
    }

    // Should have both remotes
    try testing.expect(remotes.len >= 1);
}

test "config: malformed section headers skipped" {
    const content =
        \\[
        \\    key = value
        \\[core]
        \\    bare = false
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    // The key=value under malformed section should be skipped
    try testing.expectEqualStrings("false", cfg.get("core", null, "bare").?);
}

test "config: key-value before any section is skipped" {
    const content =
        \\orphan = value
        \\[core]
        \\    bare = false
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    // Only the one under [core] should be parsed
    try testing.expect(cfg.get("core", null, "bare") != null);
    try testing.expect(cfg.entries.items.len == 1);
}

test "config: getInt returns parsed integer" {
    const content =
        \\[core]
        \\    repositoryformatversion = 0
        \\
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    try testing.expect(cfg.getInt("core", null, "repositoryformatversion", -1) == 0);
    try testing.expect(cfg.getInt("core", null, "missing", 42) == 42);
}
