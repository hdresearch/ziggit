const std = @import("std");
const config = @import("../src/git/config.zig");
const testing = std.testing;

test "parse basic git config" {
    const allocator = testing.allocator;
    
    const config_content =
        \\[user]
        \\    name = John Doe
        \\    email = john@example.com
        \\[core]
        \\    editor = vim
        \\    autocrlf = true
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\[branch "main"]
        \\    remote = origin
        \\    merge = refs/heads/main
    ;

    var git_config = try config.GitConfig.parseConfig(allocator, config_content);
    defer git_config.deinit(allocator);

    // Test user configuration
    try testing.expectEqualStrings("John Doe", git_config.getUserName().?);
    try testing.expectEqualStrings("john@example.com", git_config.getUserEmail().?);

    // Test core configuration
    try testing.expectEqualStrings("vim", git_config.getValue("core", "editor").?);
    try testing.expectEqualStrings("true", git_config.getValue("core", "autocrlf").?);

    // Test remote configuration
    const origin_url = git_config.getRemoteUrl(allocator, "origin");
    try testing.expect(origin_url != null);
    try testing.expectEqualStrings("https://github.com/user/repo.git", origin_url.?);

    // Test branch configuration
    const branch_remote = git_config.getBranchRemote(allocator, "main");
    try testing.expect(branch_remote != null);
    try testing.expectEqualStrings("origin", branch_remote.?);

    const branch_merge = git_config.getBranchMerge(allocator, "main");
    try testing.expect(branch_merge != null);
    try testing.expectEqualStrings("refs/heads/main", branch_merge.?);
}

test "parse config with quoted values and comments" {
    const allocator = testing.allocator;
    
    const config_content =
        \\# Git configuration file
        \\[user]
        \\    name = "User With Spaces"
        \\    email = user@domain.com  # user email
        \\; Alternative comment style
        \\[alias]
        \\    st = status
        \\    co = checkout
        \\    br = branch
        \\    ci = commit
        \\
        \\[push]
        \\    default = simple
    ;

    var git_config = try config.GitConfig.parseConfig(allocator, config_content);
    defer git_config.deinit(allocator);

    // Test quotes are properly handled
    try testing.expectEqualStrings("User With Spaces", git_config.getUserName().?);
    
    // Test aliases
    try testing.expectEqualStrings("status", git_config.getValue("alias", "st").?);
    try testing.expectEqualStrings("checkout", git_config.getValue("alias", "co").?);
    try testing.expectEqualStrings("branch", git_config.getValue("alias", "br").?);
    try testing.expectEqualStrings("commit", git_config.getValue("alias", "ci").?);

    // Test push config
    try testing.expectEqualStrings("simple", git_config.getValue("push", "default").?);
}

test "handle empty and malformed config" {
    const allocator = testing.allocator;
    
    // Test empty config
    var empty_config = try config.GitConfig.parseConfig(allocator, "");
    defer empty_config.deinit(allocator);
    
    try testing.expect(empty_config.getUserName() == null);
    try testing.expect(empty_config.getUserEmail() == null);
    
    // Test config with only comments
    const comment_only_config = 
        \\# This is just a comment
        \\; Another comment
        \\# No actual configuration
    ;
    
    var comment_config = try config.GitConfig.parseConfig(allocator, comment_only_config);
    defer comment_config.deinit(allocator);
    
    try testing.expect(comment_config.getUserName() == null);
}

test "complex remote and branch configurations" {
    const allocator = testing.allocator;
    
    const config_content =
        \\[remote "upstream"]
        \\    url = https://github.com/original/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/upstream/*
        \\[remote "fork"]
        \\    url = git@github.com:user/fork.git  
        \\    fetch = +refs/heads/*:refs/remotes/fork/*
        \\[branch "feature-branch"]
        \\    remote = upstream
        \\    merge = refs/heads/develop
        \\[branch "hotfix"]
        \\    remote = fork
        \\    merge = refs/heads/main
    ;

    var git_config = try config.GitConfig.parseConfig(allocator, config_content);
    defer git_config.deinit(allocator);

    // Test multiple remotes
    const upstream_url = git_config.getRemoteUrl(allocator, "upstream");
    try testing.expect(upstream_url != null);
    try testing.expectEqualStrings("https://github.com/original/repo.git", upstream_url.?);

    const fork_url = git_config.getRemoteUrl(allocator, "fork");
    try testing.expect(fork_url != null);
    try testing.expectEqualStrings("git@github.com:user/fork.git", fork_url.?);

    // Test branch configurations
    const feature_remote = git_config.getBranchRemote(allocator, "feature-branch");
    try testing.expect(feature_remote != null);
    try testing.expectEqualStrings("upstream", feature_remote.?);

    const feature_merge = git_config.getBranchMerge(allocator, "feature-branch");
    try testing.expect(feature_merge != null);
    try testing.expectEqualStrings("refs/heads/develop", feature_merge.?);

    const hotfix_remote = git_config.getBranchRemote(allocator, "hotfix");
    try testing.expect(hotfix_remote != null);
    try testing.expectEqualStrings("fork", hotfix_remote.?);
}