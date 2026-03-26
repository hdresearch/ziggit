const std = @import("std");
const testing = std.testing;
const config = @import("../src/git/config.zig");

test "config parsing with edge cases" {
    const allocator = testing.allocator;
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    // Test config with various edge cases
    const config_content =
        \\# This is a comment
        \\[core]
        \\    repositoryformatversion = 0
        \\    filemode = true
        \\    bare = false
        \\    logallrefupdates = true
        \\# Another comment
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\    pushurl = git@github.com:user/repo.git
        \\
        \\[branch "master"]
        \\    remote = origin
        \\    merge = refs/heads/master
        \\
        \\[branch "feature/complex-name"]
        \\    remote = origin
        \\    merge = refs/heads/feature/complex-name
        \\
        \\[user]
        \\    name = "John Doe"
        \\    email = john.doe@example.com
        \\
        \\[alias]
        \\    st = status
        \\    co = checkout
        \\    br = branch
        \\    unstage = reset HEAD --
        \\
        \\[credential "https://github.com"]
        \\    helper = store
    ;
    
    try git_config.parseFromString(config_content);
    
    // Test basic config values
    try testing.expectEqualStrings("0", git_config.get("core", null, "repositoryformatversion").?);
    try testing.expectEqualStrings("true", git_config.get("core", null, "filemode").?);
    try testing.expectEqualStrings("false", git_config.get("core", null, "bare").?);
    
    // Test remote configuration
    try testing.expectEqualStrings("https://github.com/user/repo.git", git_config.getRemoteUrl("origin").?);
    try testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", git_config.get("remote", "origin", "fetch").?);
    try testing.expectEqualStrings("git@github.com:user/repo.git", git_config.get("remote", "origin", "pushurl").?);
    
    // Test branch configuration
    try testing.expectEqualStrings("origin", git_config.getBranchRemote("master").?);
    try testing.expectEqualStrings("refs/heads/master", git_config.getBranchMerge("master").?);
    
    // Test complex branch name
    try testing.expectEqualStrings("origin", git_config.getBranchRemote("feature/complex-name").?);
    try testing.expectEqualStrings("refs/heads/feature/complex-name", git_config.getBranchMerge("feature/complex-name").?);
    
    // Test user configuration
    try testing.expectEqualStrings("John Doe", git_config.getUserName().?);
    try testing.expectEqualStrings("john.doe@example.com", git_config.getUserEmail().?);
    
    // Test aliases
    try testing.expectEqualStrings("status", git_config.get("alias", null, "st").?);
    try testing.expectEqualStrings("checkout", git_config.get("alias", null, "co").?);
    try testing.expectEqualStrings("reset HEAD --", git_config.get("alias", null, "unstage").?);
    
    // Test credential configuration
    try testing.expectEqualStrings("store", git_config.get("credential", "https://github.com", "helper").?);
    
    // Test case insensitive matching
    try testing.expectEqualStrings("true", git_config.get("CORE", null, "FILEMODE").?);
    try testing.expectEqualStrings("origin", git_config.get("BRANCH", "master", "REMOTE").?);
}

test "malformed config handling" {
    const allocator = testing.allocator;
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    // Config with malformed sections that should be gracefully ignored
    const malformed_config =
        \\[core]
        \\    filemode = true
        \\
        \\[broken section without closing bracket
        \\    this should be ignored
        \\
        \\[another-section]
        \\    valid = option
        \\
        \\malformed line without equals
        \\another malformed line
        \\
        \\[user]
        \\    name = Valid User
        \\    = value without key should be ignored
        \\    key without value
        \\    another_key = valid_value
    ;
    
    try git_config.parseFromString(malformed_config);
    
    // Should still parse valid sections
    try testing.expectEqualStrings("true", git_config.get("core", null, "filemode").?);
    try testing.expectEqualStrings("option", git_config.get("another-section", null, "valid").?);
    try testing.expectEqualStrings("Valid User", git_config.getUserName().?);
    try testing.expectEqualStrings("valid_value", git_config.get("user", null, "another_key").?);
    
    // Invalid entries should not exist
    try testing.expect(git_config.get("broken", null, "section") == null);
}

test "config with quoted values and escapes" {
    const allocator = testing.allocator;
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    const quoted_config =
        \\[user]
        \\    name = "John \"The Coder\" Doe"
        \\    email = "john.doe@example.com"
        \\    description = "A developer who likes to code"
        \\
        \\[core]
        \\    editor = "code --wait"
        \\    excludesfile = "~/.gitignore_global"
        \\
        \\[alias]
        \\    msg = "commit -m"
        \\    logline = "log --oneline --graph --all"
    ;
    
    try git_config.parseFromString(quoted_config);
    
    // Test quoted values are properly parsed (quotes removed)
    try testing.expectEqualStrings("John \"The Coder\" Doe", git_config.getUserName().?);
    try testing.expectEqualStrings("john.doe@example.com", git_config.getUserEmail().?);
    try testing.expectEqualStrings("A developer who likes to code", git_config.get("user", null, "description").?);
    try testing.expectEqualStrings("code --wait", git_config.get("core", null, "editor").?);
    try testing.expectEqualStrings("~/.gitignore_global", git_config.get("core", null, "excludesfile").?);
    try testing.expectEqualStrings("commit -m", git_config.get("alias", null, "msg").?);
    try testing.expectEqualStrings("log --oneline --graph --all", git_config.get("alias", null, "logline").?);
}

test "config with multiple remotes and branches" {
    const allocator = testing.allocator;
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    const multi_remote_config =
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\
        \\[remote "upstream"]
        \\    url = https://github.com/upstream/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/upstream/*
        \\
        \\[remote "fork"]
        \\    url = git@github.com:user/fork.git
        \\    fetch = +refs/heads/*:refs/remotes/fork/*
        \\
        \\[branch "master"]
        \\    remote = origin
        \\    merge = refs/heads/master
        \\
        \\[branch "develop"]
        \\    remote = upstream
        \\    merge = refs/heads/develop
        \\
        \\[branch "feature-xyz"]
        \\    remote = fork
        \\    merge = refs/heads/feature-xyz
    ;
    
    try git_config.parseFromString(multi_remote_config);
    
    // Test multiple remotes
    try testing.expectEqualStrings("https://github.com/user/repo.git", git_config.getRemoteUrl("origin").?);
    try testing.expectEqualStrings("https://github.com/upstream/repo.git", git_config.getRemoteUrl("upstream").?);
    try testing.expectEqualStrings("git@github.com:user/fork.git", git_config.getRemoteUrl("fork").?);
    
    // Test branch configurations with different remotes
    try testing.expectEqualStrings("origin", git_config.getBranchRemote("master").?);
    try testing.expectEqualStrings("upstream", git_config.getBranchRemote("develop").?);
    try testing.expectEqualStrings("fork", git_config.getBranchRemote("feature-xyz").?);
    
    try testing.expectEqualStrings("refs/heads/master", git_config.getBranchMerge("master").?);
    try testing.expectEqualStrings("refs/heads/develop", git_config.getBranchMerge("develop").?);
    try testing.expectEqualStrings("refs/heads/feature-xyz", git_config.getBranchMerge("feature-xyz").?);
    
    // Test non-existent remotes/branches
    try testing.expect(git_config.getRemoteUrl("nonexistent") == null);
    try testing.expect(git_config.getBranchRemote("nonexistent") == null);
}

test "config size and line limits" {
    const allocator = testing.allocator;
    
    // Test that we handle large config files appropriately
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    // Create a config with many sections to test limits
    var large_config = std.ArrayList(u8).init(allocator);
    defer large_config.deinit();
    
    // Add many sections (but stay within reasonable limits)
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try large_config.writer().print("[section{}]\n", .{i});
        try large_config.writer().print("    key = value{}\n", .{i});
        try large_config.writer().print("    another_key = another_value{}\n", .{i});
    }
    
    // This should parse successfully
    try git_config.parseFromString(large_config.items);
    
    // Verify some of the parsed values
    try testing.expectEqualStrings("value0", git_config.get("section0", null, "key").?);
    try testing.expectEqualStrings("value50", git_config.get("section50", null, "key").?);
    try testing.expectEqualStrings("another_value99", git_config.get("section99", null, "another_key").?);
}

test "config with whitespace variations" {
    const allocator = testing.allocator;
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    const whitespace_config =
        \\[core]
        \\filemode=true
        \\	bare = false
        \\  logallrefupdates  =  true  
        \\    editor    =    vim    
        \\
        \\  [user]  
        \\	name	=	John Doe	
        \\   email   =   john@example.com   
        \\
        \\	[remote "origin"]	
        \\		url		=		https://example.com/repo.git		
        \\	fetch	=	+refs/heads/*:refs/remotes/origin/*	
    ;
    
    try git_config.parseFromString(whitespace_config);
    
    // Test that whitespace is properly trimmed
    try testing.expectEqualStrings("true", git_config.get("core", null, "filemode").?);
    try testing.expectEqualStrings("false", git_config.get("core", null, "bare").?);
    try testing.expectEqualStrings("true", git_config.get("core", null, "logallrefupdates").?);
    try testing.expectEqualStrings("vim", git_config.get("core", null, "editor").?);
    try testing.expectEqualStrings("John Doe", git_config.getUserName().?);
    try testing.expectEqualStrings("john@example.com", git_config.getUserEmail().?);
    try testing.expectEqualStrings("https://example.com/repo.git", git_config.getRemoteUrl("origin").?);
    try testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", git_config.get("remote", "origin", "fetch").?);
}