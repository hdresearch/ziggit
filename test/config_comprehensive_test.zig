const std = @import("std");
const testing = std.testing;
const config = @import("../src/git/config.zig");

test "git config comprehensive parsing" {
    const allocator = testing.allocator;
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    const complex_config =
        \\# Git configuration file
        \\[core]
        \\    repositoryformatversion = 0
        \\    filemode = true
        \\    bare = false
        \\    logallrefupdates = true
        \\    ignorecase = true
        \\    editor = "vim"
        \\
        \\[user]
        \\    name = "John Doe"
        \\    email = john.doe@example.com
        \\    signingkey = ABCD1234
        \\
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\    pushurl = git@github.com:user/repo.git
        \\
        \\[remote "upstream"]
        \\    url = https://github.com/original/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/upstream/*
        \\
        \\[branch "master"]
        \\    remote = origin
        \\    merge = refs/heads/master
        \\    rebase = true
        \\
        \\[branch "develop"]
        \\    remote = upstream
        \\    merge = refs/heads/develop
        \\
        \\[alias]
        \\    co = checkout
        \\    br = branch
        \\    ci = commit
        \\    st = status
        \\    unstage = "reset HEAD --"
        \\    last = "log -1 HEAD"
        \\
        \\[push]
        \\    default = simple
        \\    followTags = true
        \\
        \\[pull]
        \\    rebase = false
        \\
        \\[diff]
        \\    tool = vimdiff
        \\
        \\[merge]
        \\    tool = vimdiff
        \\
        \\[color]
        \\    ui = auto
        \\
        \\[color "branch"]
        \\    current = yellow reverse
        \\    local = yellow
        \\    remote = green
        \\
        \\[color "diff"]
        \\    meta = "yellow bold"
        \\    frag = "magenta bold"
        \\    old = "red bold"
        \\    new = "green bold"
        \\
        \\[url "https://github.com/"]
        \\    insteadOf = gh:
        \\
        \\[credential]
        \\    helper = store
    ;
    
    try git_config.parseFromString(complex_config);
    
    // Test core configuration
    try testing.expectEqualStrings("0", git_config.get("core", null, "repositoryformatversion").?);
    try testing.expectEqualStrings("true", git_config.get("core", null, "filemode").?);
    try testing.expectEqualStrings("false", git_config.get("core", null, "bare").?);
    try testing.expectEqualStrings("vim", git_config.get("core", null, "editor").?);
    
    // Test user configuration
    try testing.expectEqualStrings("John Doe", git_config.getUserName().?);
    try testing.expectEqualStrings("john.doe@example.com", git_config.getUserEmail().?);
    try testing.expectEqualStrings("ABCD1234", git_config.get("user", null, "signingkey").?);
    
    // Test remote configuration
    try testing.expectEqualStrings("https://github.com/user/repo.git", git_config.getRemoteUrl("origin").?);
    try testing.expectEqualStrings("https://github.com/original/repo.git", git_config.getRemoteUrl("upstream").?);
    try testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", git_config.get("remote", "origin", "fetch").?);
    try testing.expectEqualStrings("git@github.com:user/repo.git", git_config.get("remote", "origin", "pushurl").?);
    
    // Test branch configuration
    try testing.expectEqualStrings("origin", git_config.getBranchRemote("master").?);
    try testing.expectEqualStrings("refs/heads/master", git_config.getBranchMerge("master").?);
    try testing.expectEqualStrings("upstream", git_config.getBranchRemote("develop").?);
    try testing.expectEqualStrings("refs/heads/develop", git_config.getBranchMerge("develop").?);
    try testing.expectEqualStrings("true", git_config.get("branch", "master", "rebase").?);
    
    // Test aliases
    try testing.expectEqualStrings("checkout", git_config.get("alias", null, "co").?);
    try testing.expectEqualStrings("branch", git_config.get("alias", null, "br").?);
    try testing.expectEqualStrings("commit", git_config.get("alias", null, "ci").?);
    try testing.expectEqualStrings("status", git_config.get("alias", null, "st").?);
    try testing.expectEqualStrings("reset HEAD --", git_config.get("alias", null, "unstage").?);
    try testing.expectEqualStrings("log -1 HEAD", git_config.get("alias", null, "last").?);
    
    // Test other configuration sections
    try testing.expectEqualStrings("simple", git_config.get("push", null, "default").?);
    try testing.expectEqualStrings("true", git_config.get("push", null, "followTags").?);
    try testing.expectEqualStrings("false", git_config.get("pull", null, "rebase").?);
    try testing.expectEqualStrings("vimdiff", git_config.get("diff", null, "tool").?);
    try testing.expectEqualStrings("vimdiff", git_config.get("merge", null, "tool").?);
    try testing.expectEqualStrings("auto", git_config.get("color", null, "ui").?);
    try testing.expectEqualStrings("store", git_config.get("credential", null, "helper").?);
    
    // Test color subsections
    try testing.expectEqualStrings("yellow reverse", git_config.get("color", "branch", "current").?);
    try testing.expectEqualStrings("yellow", git_config.get("color", "branch", "local").?);
    try testing.expectEqualStrings("green", git_config.get("color", "branch", "remote").?);
    try testing.expectEqualStrings("yellow bold", git_config.get("color", "diff", "meta").?);
    try testing.expectEqualStrings("magenta bold", git_config.get("color", "diff", "frag").?);
    try testing.expectEqualStrings("red bold", git_config.get("color", "diff", "old").?);
    try testing.expectEqualStrings("green bold", git_config.get("color", "diff", "new").?);
    
    // Test URL rewriting
    try testing.expectEqualStrings("gh:", git_config.get("url", "https://github.com/", "insteadOf").?);
    
    // Test case-insensitive access
    try testing.expectEqualStrings("John Doe", git_config.get("USER", null, "NAME").?);
    try testing.expectEqualStrings("https://github.com/user/repo.git", git_config.get("REMOTE", "ORIGIN", "URL").?);
    try testing.expectEqualStrings("origin", git_config.get("BRANCH", "MASTER", "REMOTE").?);
}

test "git config edge cases and error handling" {
    const allocator = testing.allocator;
    
    // Test empty configuration
    {
        var git_config = config.GitConfig.init(allocator);
        defer git_config.deinit();
        
        try git_config.parseFromString("");
        try testing.expect(git_config.get("user", null, "name") == null);
    }
    
    // Test configuration with only comments
    {
        var git_config = config.GitConfig.init(allocator);
        defer git_config.deinit();
        
        const comment_only = 
            \\# This is a comment
            \\; This is also a comment
            \\  # Indented comment
            \\
            \\    ; Another comment
        ;
        
        try git_config.parseFromString(comment_only);
        try testing.expect(git_config.get("user", null, "name") == null);
    }
    
    // Test malformed sections (should be skipped)
    {
        var git_config = config.GitConfig.init(allocator);
        defer git_config.deinit();
        
        const malformed =
            \\[user]
            \\    name = John Doe
            \\[invalid section without closing bracket
            \\    ignored = value
            \\[core]
            \\    editor = vim
        ;
        
        try git_config.parseFromString(malformed);
        try testing.expectEqualStrings("John Doe", git_config.get("user", null, "name").?);
        try testing.expectEqualStrings("vim", git_config.get("core", null, "editor").?);
        try testing.expect(git_config.get("invalid", null, "ignored") == null);
    }
    
    // Test values without sections (should be ignored)
    {
        var git_config = config.GitConfig.init(allocator);
        defer git_config.deinit();
        
        const orphaned_values =
            \\orphaned = value
            \\[user]
            \\    name = John Doe
            \\another_orphan = another_value
        ;
        
        try git_config.parseFromString(orphaned_values);
        try testing.expectEqualStrings("John Doe", git_config.get("user", null, "name").?);
        try testing.expect(git_config.get("", null, "orphaned") == null);
    }
    
    // Test quoted values with special characters
    {
        var git_config = config.GitConfig.init(allocator);
        defer git_config.deinit();
        
        const quoted_values =
            \\[user]
            \\    name = "John \"Johnny\" Doe"
            \\    email = "john@example.com"
            \\[core]
            \\    editor = "code --wait"
            \\    excludesfile = "~/.gitignore_global"
        ;
        
        try git_config.parseFromString(quoted_values);
        try testing.expectEqualStrings("John \"Johnny\" Doe", git_config.get("user", null, "name").?);
        try testing.expectEqualStrings("john@example.com", git_config.get("user", null, "email").?);
        try testing.expectEqualStrings("code --wait", git_config.get("core", null, "editor").?);
        try testing.expectEqualStrings("~/.gitignore_global", git_config.get("core", null, "excludesfile").?);
    }
    
    // Test subsections with spaces and special characters
    {
        var git_config = config.GitConfig.init(allocator);
        defer git_config.deinit();
        
        const special_subsections =
            \\[remote "origin with spaces"]
            \\    url = https://github.com/user/repo.git
            \\[branch "feature/branch-name"]
            \\    remote = origin
            \\[url "https://github.com/"]
            \\    insteadOf = github:
        ;
        
        try git_config.parseFromString(special_subsections);
        try testing.expectEqualStrings("https://github.com/user/repo.git", git_config.get("remote", "origin with spaces", "url").?);
        try testing.expectEqualStrings("origin", git_config.get("branch", "feature/branch-name", "remote").?);
        try testing.expectEqualStrings("github:", git_config.get("url", "https://github.com/", "insteadOf").?);
    }
}

test "git config multi-value support" {
    const allocator = testing.allocator;
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    const multi_value_config =
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\    fetch = +refs/pull/*/head:refs/remotes/origin/pr/*
        \\    fetch = +refs/tags/*:refs/tags/*
        \\
        \\[receive]
        \\    denyNonFastforwards = true
        \\    denyNonFastforwards = false
    ;
    
    try git_config.parseFromString(multi_value_config);
    
    // Test getting all values for a multi-value key
    const fetch_values = try git_config.getAll("remote", "origin", "fetch", allocator);
    defer allocator.free(fetch_values);
    
    try testing.expectEqual(@as(usize, 3), fetch_values.len);
    try testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", fetch_values[0]);
    try testing.expectEqualStrings("+refs/pull/*/head:refs/remotes/origin/pr/*", fetch_values[1]);
    try testing.expectEqualStrings("+refs/tags/*:refs/tags/*", fetch_values[2]);
    
    // Test that get() returns the last value for multi-value keys
    try testing.expectEqualStrings("+refs/tags/*:refs/tags/*", git_config.get("remote", "origin", "fetch").?);
    try testing.expectEqualStrings("false", git_config.get("receive", null, "denyNonFastforwards").?);
}

test "config utility functions" {
    const allocator = testing.allocator;
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    const test_config =
        \\[user]
        \\    name = Jane Doe
        \\    email = jane@example.com
        \\
        \\[remote "origin"]
        \\    url = https://github.com/jane/repo.git
        \\
        \\[remote "upstream"]
        \\    url = https://github.com/original/repo.git
        \\
        \\[branch "main"]
        \\    remote = origin
        \\    merge = refs/heads/main
        \\
        \\[branch "feature"]
        \\    remote = upstream
        \\    merge = refs/heads/feature
    ;
    
    try git_config.parseFromString(test_config);
    
    // Test convenience methods
    try testing.expectEqualStrings("Jane Doe", git_config.getUserName().?);
    try testing.expectEqualStrings("jane@example.com", git_config.getUserEmail().?);
    
    // Test remote URL methods
    try testing.expectEqualStrings("https://github.com/jane/repo.git", git_config.getRemoteUrl("origin").?);
    try testing.expectEqualStrings("https://github.com/original/repo.git", git_config.getRemoteUrl("upstream").?);
    try testing.expect(git_config.getRemoteUrl("nonexistent") == null);
    
    // Test branch methods
    try testing.expectEqualStrings("origin", git_config.getBranchRemote("main").?);
    try testing.expectEqualStrings("upstream", git_config.getBranchRemote("feature").?);
    try testing.expect(git_config.getBranchRemote("nonexistent") == null);
    
    try testing.expectEqualStrings("refs/heads/main", git_config.getBranchMerge("main").?);
    try testing.expectEqualStrings("refs/heads/feature", git_config.getBranchMerge("feature").?);
    try testing.expect(git_config.getBranchMerge("nonexistent") == null);
    
    // Test allocator variants (they should return the same results but accept allocator parameter)
    try testing.expectEqualStrings("https://github.com/jane/repo.git", git_config.getRemoteUrlAlloc(allocator, "origin").?);
    try testing.expectEqualStrings("origin", git_config.getBranchRemoteAlloc(allocator, "main").?);
    try testing.expectEqualStrings("refs/heads/main", git_config.getBranchMergeAlloc(allocator, "main").?);
}

test "parseConfig convenience function" {
    const allocator = testing.allocator;
    
    const simple_config =
        \\[user]
        \\    name = Test User
        \\    email = test@example.com
        \\
        \\[core]
        \\    editor = nano
    ;
    
    var git_config = try config.GitConfig.parseConfig(allocator, simple_config);
    defer git_config.deinit();
    
    try testing.expectEqualStrings("Test User", git_config.getUserName().?);
    try testing.expectEqualStrings("test@example.com", git_config.getUserEmail().?);
    try testing.expectEqualStrings("nano", git_config.get("core", null, "editor").?);
}