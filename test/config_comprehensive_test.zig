const std = @import("std");
const config = @import("../src/git/config.zig");
const testing = std.testing;

test "git config comprehensive parsing test" {
    const allocator = testing.allocator;

    const test_config = 
        \\[core]
        \\	repositoryformatversion = 0
        \\	filemode = true
        \\	bare = false
        \\	logallrefupdates = true
        \\[remote "origin"]
        \\	url = https://github.com/user/repo.git
        \\	fetch = +refs/heads/*:refs/remotes/origin/*
        \\[branch "master"]
        \\	remote = origin
        \\	merge = refs/heads/master
        \\[branch "develop"]
        \\	remote = origin
        \\	merge = refs/heads/develop
        \\[user]
        \\	name = Test User
        \\	email = test@example.com
        \\[push]
        \\	default = simple
        \\[remote "upstream"]
        \\	url = https://github.com/original/repo.git
        \\	fetch = +refs/heads/*:refs/remotes/upstream/*
        \\[alias]
        \\	st = status
        \\	co = checkout
        \\	br = branch
        \\	ci = commit
        \\# This is a comment
        \\[color]
        \\	ui = auto
        \\[color "branch"]
        \\	current = yellow reverse
        \\	local = yellow
        \\	remote = green
        \\[url "https://github.com/"]
        \\	insteadOf = gh:
        \\
    ;

    var git_config = try config.GitConfig.parseConfig(allocator, test_config);
    defer git_config.deinit();

    // Test core values
    const filemode = git_config.get("core", null, "filemode");
    try testing.expect(filemode != null);
    try testing.expect(std.mem.eql(u8, filemode.?, "true"));

    const repo_format_version = git_config.get("core", null, "repositoryformatversion");
    try testing.expect(repo_format_version != null);
    try testing.expect(std.mem.eql(u8, repo_format_version.?, "0"));

    // Test remote URLs
    const origin_url = git_config.getRemoteUrl("origin");
    try testing.expect(origin_url != null);
    try testing.expect(std.mem.eql(u8, origin_url.?, "https://github.com/user/repo.git"));

    const upstream_url = git_config.getRemoteUrl("upstream");
    try testing.expect(upstream_url != null);
    try testing.expect(std.mem.eql(u8, upstream_url.?, "https://github.com/original/repo.git"));

    // Test non-existent remote
    const nonexistent_url = git_config.getRemoteUrl("nonexistent");
    try testing.expect(nonexistent_url == null);

    // Test branch remotes
    const master_remote = git_config.getBranchRemote("master");
    try testing.expect(master_remote != null);
    try testing.expect(std.mem.eql(u8, master_remote.?, "origin"));

    const develop_remote = git_config.getBranchRemote("develop");
    try testing.expect(develop_remote != null);
    try testing.expect(std.mem.eql(u8, develop_remote.?, "origin"));

    const nonexistent_branch_remote = git_config.getBranchRemote("nonexistent");
    try testing.expect(nonexistent_branch_remote == null);

    // Test user information
    const user_name = git_config.getUserName();
    try testing.expect(user_name != null);
    try testing.expect(std.mem.eql(u8, user_name.?, "Test User"));

    const user_email = git_config.getUserEmail();
    try testing.expect(user_email != null);
    try testing.expect(std.mem.eql(u8, user_email.?, "test@example.com"));

    // Test case insensitive section names
    const push_default = git_config.get("PUSH", null, "default");
    try testing.expect(push_default != null);
    try testing.expect(std.mem.eql(u8, push_default.?, "simple"));

    // Test color subsections
    const color_current = git_config.get("color", "branch", "current");
    try testing.expect(color_current != null);
    try testing.expect(std.mem.eql(u8, color_current.?, "yellow reverse"));

    std.debug.print("✓ All config parsing tests passed!\n", .{});
}

test "git config edge cases and malformed input" {
    const allocator = testing.allocator;

    // Test empty config
    {
        var empty_config = try config.GitConfig.parseConfig(allocator, "");
        defer empty_config.deinit();
        
        const value = empty_config.get("core", null, "filemode");
        try testing.expect(value == null);
    }

    // Test config with only comments
    {
        const comment_only = "# This is a comment\n; Another comment\n\n";
        var comment_config = try config.GitConfig.parseConfig(allocator, comment_only);
        defer comment_config.deinit();
        
        const value = comment_config.get("any", null, "value");
        try testing.expect(value == null);
    }

    // Test malformed sections (should be skipped)
    {
        const malformed_config = 
            \\[unclosed section
            \\key = value
            \\[core]
            \\valid = true
            \\[section with spaces]
            \\invalid = should_be_skipped
            \\[valid]
            \\good = value
        ;

        var malformed = try config.GitConfig.parseConfig(allocator, malformed_config);
        defer malformed.deinit();
        
        // Should have skipped malformed sections but parsed valid ones
        const core_valid = malformed.get("core", null, "valid");
        try testing.expect(core_valid != null);
        try testing.expect(std.mem.eql(u8, core_valid.?, "true"));

        const valid_good = malformed.get("valid", null, "good");
        try testing.expect(valid_good != null);
        try testing.expect(std.mem.eql(u8, valid_good.?, "value"));

        // Malformed entries should not exist
        const invalid = malformed.get("section with spaces", null, "invalid");
        try testing.expect(invalid == null);
    }

    // Test quoted values with special characters
    {
        const quoted_config = 
            \\[user]
            \\name = "User With Spaces"
            \\email = "user@domain.com"
            \\description = "A \"quoted\" description"
            \\[remote "my origin"]
            \\url = "https://example.com/path with spaces.git"
        ;

        var quoted = try config.GitConfig.parseConfig(allocator, quoted_config);
        defer quoted.deinit();

        const name = quoted.get("user", null, "name");
        try testing.expect(name != null);
        try testing.expect(std.mem.eql(u8, name.?, "User With Spaces"));

        const description = quoted.get("user", null, "description");
        try testing.expect(description != null);
        try testing.expect(std.mem.eql(u8, description.?, "A \"quoted\" description"));

        const url = quoted.get("remote", "my origin", "url");
        try testing.expect(url != null);
        try testing.expect(std.mem.eql(u8, url.?, "https://example.com/path with spaces.git"));
    }

    // Test keys without values
    {
        const no_value_config = 
            \\[core]
            \\bare
            \\filemode = true
            \\another_bare_key
        ;

        var no_value = try config.GitConfig.parseConfig(allocator, no_value_config);
        defer no_value.deinit();

        const filemode = no_value.get("core", null, "filemode");
        try testing.expect(filemode != null);
        try testing.expect(std.mem.eql(u8, filemode.?, "true"));

        // Keys without values should be treated as having empty values or be ignored
        // This depends on implementation - bare keys are less common in git config
    }

    // Test very long lines (should handle gracefully)
    {
        const long_value = try allocator.alloc(u8, 1000);
        defer allocator.free(long_value);
        @memset(long_value, 'a');

        const long_config = try std.fmt.allocPrint(allocator, 
            \\[test]
            \\longvalue = {s}
            \\normal = value
        , .{long_value});
        defer allocator.free(long_config);

        var long_conf = try config.GitConfig.parseConfig(allocator, long_config);
        defer long_conf.deinit();

        // Should handle the normal value even if long value causes issues
        const normal = long_conf.get("test", null, "normal");
        try testing.expect(normal != null);
        try testing.expect(std.mem.eql(u8, normal.?, "value"));
    }

    std.debug.print("✓ All config edge case tests passed!\n", .{});
}

test "git config file loading" {
    const allocator = testing.allocator;

    // Create a temporary git config file
    const temp_path = "/tmp/test_git_config";
    const config_content = 
        \\[core]
        \\repositoryformatversion = 0
        \\filemode = true
        \\[remote "origin"]
        \\url = https://github.com/test/repo.git
        \\fetch = +refs/heads/*:refs/remotes/origin/*
        \\[user]
        \\name = Test User
        \\email = test@example.com
    ;

    try std.fs.cwd().writeFile(.{ .sub_path = temp_path, .data = config_content });
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    // Test loading config from file
    const file_config = try config.GitConfig.loadFromFile(allocator, temp_path);
    defer file_config.deinit();

    const origin_url = file_config.getRemoteUrl("origin");
    try testing.expect(origin_url != null);
    try testing.expect(std.mem.eql(u8, origin_url.?, "https://github.com/test/repo.git"));

    const user_name = file_config.getUserName();
    try testing.expect(user_name != null);
    try testing.expect(std.mem.eql(u8, user_name.?, "Test User"));

    std.debug.print("✓ Config file loading test passed!\n", .{});
}

test "git config case sensitivity and whitespace handling" {
    const allocator = testing.allocator;

    const whitespace_config = 
        \\	[core]   
        \\		repositoryformatversion=0
        \\	filemode = true   
        \\		  bare=false
        \\  [REMOTE "origin"]  
        \\	url=https://github.com/user/repo.git
        \\      fetch = +refs/heads/*:refs/remotes/origin/*  
        \\[User]
        \\	name =   Test User   
        \\  	email	= test@example.com 
        \\[Branch "Master"]
        \\	remote = origin
    ;

    var ws_config = try config.GitConfig.parseConfig(allocator, whitespace_config);
    defer ws_config.deinit();

    // Test case insensitive section names
    const repo_version = ws_config.get("CORE", null, "repositoryformatversion");
    try testing.expect(repo_version != null);
    try testing.expect(std.mem.eql(u8, repo_version.?, "0"));

    const filemode = ws_config.get("core", null, "FILEMODE");
    try testing.expect(filemode != null);
    try testing.expect(std.mem.eql(u8, filemode.?, "true"));

    // Test subsection case sensitivity (should be case sensitive)
    const origin_url = ws_config.get("remote", "origin", "url");
    try testing.expect(origin_url != null);
    try testing.expect(std.mem.eql(u8, origin_url.?, "https://github.com/user/repo.git"));

    // Test whitespace trimming
    const user_name = ws_config.get("user", null, "name");
    try testing.expect(user_name != null);
    try testing.expect(std.mem.eql(u8, user_name.?, "Test User"));

    const user_email = ws_config.get("user", null, "email");
    try testing.expect(user_email != null);
    try testing.expect(std.mem.eql(u8, user_email.?, "test@example.com"));

    // Test branch with different case
    const master_remote = ws_config.get("branch", "Master", "remote");
    try testing.expect(master_remote != null);
    try testing.expect(std.mem.eql(u8, master_remote.?, "origin"));

    std.debug.print("✓ Case sensitivity and whitespace tests passed!\n", .{});
}