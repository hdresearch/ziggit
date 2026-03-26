const std = @import("std");
const testing = std.testing;
const config = @import("../src/git/config.zig");

test "advanced config parsing with edge cases" {
    const allocator = testing.allocator;
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    const complex_config =
        \\# Complex git configuration with various edge cases
        \\[core]
        \\    repositoryformatversion = 0
        \\    filemode = true
        \\    bare = false
        \\    logallrefupdates = true
        \\    ignorecase = true
        \\    precomposeunicode = true
        \\    
        \\[user]
        \\    name = "Advanced User"
        \\    email = advanced@example.com
        \\    signingkey = ABC123DEF456
        \\    
        \\[remote "origin"]
        \\    url = "https://github.com/user/repo.git"
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\    pushurl = "git@github.com:user/repo.git"
        \\    
        \\[remote "upstream"]
        \\    url = https://github.com/original/repo.git  
        \\    fetch = +refs/heads/*:refs/remotes/upstream/*
        \\    
        \\[branch "main"]
        \\    remote = origin
        \\    merge = refs/heads/main
        \\    rebase = false
        \\    
        \\[branch "develop"]
        \\    remote = origin
        \\    merge = refs/heads/develop  
        \\    rebase = true
        \\    
        \\[push]
        \\    default = simple
        \\    followTags = true
        \\    
        \\[pull]
        \\    rebase = false
        \\    ff = only
        \\    
        \\[merge]
        \\    conflictstyle = diff3
        \\    tool = vimdiff
        \\    
        \\[diff]
        \\    tool = vimdiff
        \\    colorMoved = default
        \\    
        \\[alias]
        \\    co = checkout
        \\    br = branch
        \\    ci = commit
        \\    st = status
        \\    unstage = reset HEAD --
        \\    last = log -1 HEAD
        \\    visual = !gitk
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
        \\    meta = yellow bold
        \\    frag = magenta bold
        \\    old = red bold
        \\    new = green bold
        \\    
        \\[init]
        \\    defaultBranch = main
        \\    
        \\[credential]
        \\    helper = osxkeychain
        \\    
        \\[gpg]
        \\    program = gpg
        \\    
        \\[commit]
        \\    gpgsign = true
        \\    template = ~/.gitmessage
        \\    
        \\[tag]
        \\    gpgsign = true
        \\    
        \\[url "git@github.com:"]
        \\    insteadOf = "https://github.com/"
    ;
    
    try git_config.parseFromString(complex_config);
    
    // Test core settings
    try testing.expect(git_config.getBool("core", null, "filemode", false));
    try testing.expect(!git_config.getBool("core", null, "bare", true));
    try testing.expect(git_config.getBool("core", null, "ignorecase", false));
    
    // Test user configuration
    try testing.expectEqualStrings("Advanced User", git_config.getUserName().?);
    try testing.expectEqualStrings("advanced@example.com", git_config.getUserEmail().?);
    try testing.expectEqualStrings("ABC123DEF456", git_config.get("user", null, "signingkey").?);
    
    // Test multiple remotes
    try testing.expectEqualStrings("https://github.com/user/repo.git", git_config.getRemoteUrl("origin").?);
    try testing.expectEqualStrings("https://github.com/original/repo.git", git_config.getRemoteUrl("upstream").?);
    try testing.expectEqualStrings("git@github.com:user/repo.git", git_config.getRemotePushUrl("origin").?);
    
    // Test branch configurations
    try testing.expectEqualStrings("origin", git_config.getBranchRemote("main").?);
    try testing.expectEqualStrings("refs/heads/main", git_config.getBranchMerge("main").?);
    try testing.expect(!git_config.getBool("branch", "main", "rebase", true));
    try testing.expect(git_config.getBool("branch", "develop", "rebase", false));
    
    // Test push/pull settings
    try testing.expectEqualStrings("simple", git_config.getPushDefault().?);
    try testing.expect(!git_config.getPullRebase());
    
    // Test merge and diff tools
    try testing.expectEqualStrings("diff3", git_config.getMergeConflictStyle().?);
    try testing.expectEqualStrings("vimdiff", git_config.getDiffTool().?);
    try testing.expectEqualStrings("vimdiff", git_config.getMergeTool().?);
    
    // Test init settings
    try testing.expectEqualStrings("main", git_config.getInitDefaultBranch().?);
    
    // Test commit settings
    try testing.expect(git_config.getBool("commit", null, "gpgsign", false));
    try testing.expectEqualStrings("~/.gitmessage", git_config.get("commit", null, "template").?);
    
    std.debug.print("Advanced config parsing test completed successfully\n", .{});
}

test "config validation and error handling" {
    const allocator = testing.allocator;
    
    // Test config validation
    {
        var git_config = config.GitConfig.init(allocator);
        defer git_config.deinit();
        
        const valid_config =
            \\[user]
            \\    name = "Valid User"
            \\    email = valid@example.com
            \\    
            \\[core]
            \\    autocrlf = input
            \\    
            \\[push]  
            \\    default = simple
        ;
        
        try git_config.parseFromString(valid_config);
        
        const issues = try git_config.validateConfig(allocator);
        defer {
            for (issues) |issue| {
                allocator.free(issue);
            }
            allocator.free(issues);
        }
        
        // Should have no validation issues
        try testing.expect(issues.len == 0);
    }
    
    // Test invalid email
    {
        var git_config = config.GitConfig.init(allocator);
        defer git_config.deinit();
        
        const invalid_config =
            \\[user]
            \\    name = "Invalid User"
            \\    email = invalid-email-no-at-sign
        ;
        
        try git_config.parseFromString(invalid_config);
        
        const issues = try git_config.validateConfig(allocator);
        defer {
            for (issues) |issue| {
                allocator.free(issue);
            }
            allocator.free(issues);
        }
        
        // Should have email validation issue
        try testing.expect(issues.len > 0);
        var has_email_error = false;
        for (issues) |issue| {
            if (std.mem.indexOf(u8, issue, "email") != null) {
                has_email_error = true;
                break;
            }
        }
        try testing.expect(has_email_error);
    }
    
    // Test missing required config
    {
        var git_config = config.GitConfig.init(allocator);
        defer git_config.deinit();
        
        const incomplete_config =
            \\[core]
            \\    filemode = true
        ;
        
        try git_config.parseFromString(incomplete_config);
        
        const issues = try git_config.validateConfig(allocator);
        defer {
            for (issues) |issue| {
                allocator.free(issue);
            }
            allocator.free(issues);
        }
        
        // Should have missing user.name and user.email issues  
        try testing.expect(issues.len >= 2);
    }
    
    std.debug.print("Config validation test completed successfully\n", .{});
}

test "config file operations and persistence" {
    const allocator = testing.allocator;
    
    // Test writing and reading config
    const temp_config_path = "/tmp/test-git-config";
    std.fs.cwd().deleteFile(temp_config_path) catch {};
    defer std.fs.cwd().deleteFile(temp_config_path) catch {};
    
    // Create and populate config
    {
        var git_config = config.GitConfig.init(allocator);
        defer git_config.deinit();
        
        try git_config.setValue("user", null, "name", "Test User");
        try git_config.setValue("user", null, "email", "test@example.com");
        try git_config.setValue("remote", "origin", "url", "https://github.com/test/repo.git");
        try git_config.setValue("branch", "main", "remote", "origin");
        try git_config.setValue("branch", "main", "merge", "refs/heads/main");
        
        try git_config.writeToFile(temp_config_path);
    }
    
    // Read back and verify
    {
        var git_config = config.GitConfig.init(allocator);
        defer git_config.deinit();
        
        try git_config.parseFromFile(temp_config_path);
        
        try testing.expectEqualStrings("Test User", git_config.getUserName().?);
        try testing.expectEqualStrings("test@example.com", git_config.getUserEmail().?);
        try testing.expectEqualStrings("https://github.com/test/repo.git", git_config.getRemoteUrl("origin").?);
        try testing.expectEqualStrings("origin", git_config.getBranchRemote("main").?);
        try testing.expectEqualStrings("refs/heads/main", git_config.getBranchMerge("main").?);
    }
    
    std.debug.print("Config persistence test completed successfully\n", .{});
}

test "config branch and remote management" {
    const allocator = testing.allocator;
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    const multi_remote_config =
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\    
        \\[remote "upstream"]  
        \\    url = https://github.com/original/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/upstream/*
        \\    
        \\[remote "fork"]
        \\    url = https://github.com/fork/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/fork/*
        \\    
        \\[branch "main"]
        \\    remote = origin
        \\    merge = refs/heads/main
        \\    
        \\[branch "develop"]
        \\    remote = origin  
        \\    merge = refs/heads/develop
        \\    rebase = true
        \\    
        \\[branch "feature-1"]
        \\    remote = fork
        \\    merge = refs/heads/feature-1
        \\    
        \\[branch "hotfix"]
        \\    remote = upstream
        \\    merge = refs/heads/hotfix
        \\    rebase = false
    ;
    
    try git_config.parseFromString(multi_remote_config);
    
    // Test getting all remotes
    const remotes = try git_config.getAllRemotes(allocator);
    defer {
        for (remotes) |remote| {
            allocator.free(remote);
        }
        allocator.free(remotes);
    }
    
    try testing.expect(remotes.len == 3);
    
    // Verify all expected remotes are present
    var has_origin = false;
    var has_upstream = false;
    var has_fork = false;
    
    for (remotes) |remote| {
        if (std.mem.eql(u8, remote, "origin")) has_origin = true;
        if (std.mem.eql(u8, remote, "upstream")) has_upstream = true;
        if (std.mem.eql(u8, remote, "fork")) has_fork = true;
    }
    
    try testing.expect(has_origin);
    try testing.expect(has_upstream);
    try testing.expect(has_fork);
    
    // Test getting all branches
    const branches = try git_config.getAllBranches(allocator);
    defer {
        for (branches) |branch| {
            branch.deinit(allocator);
        }
        allocator.free(branches);
    }
    
    try testing.expect(branches.len == 4);
    
    // Verify branch configurations
    for (branches) |branch| {
        if (std.mem.eql(u8, branch.name, "main")) {
            try testing.expectEqualStrings("origin", branch.remote.?);
            try testing.expectEqualStrings("refs/heads/main", branch.merge.?);
            try testing.expect(!branch.rebase);
        } else if (std.mem.eql(u8, branch.name, "develop")) {
            try testing.expectEqualStrings("origin", branch.remote.?);
            try testing.expectEqualStrings("refs/heads/develop", branch.merge.?);
            try testing.expect(branch.rebase);
        } else if (std.mem.eql(u8, branch.name, "feature-1")) {
            try testing.expectEqualStrings("fork", branch.remote.?);
            try testing.expectEqualStrings("refs/heads/feature-1", branch.merge.?);
        } else if (std.mem.eql(u8, branch.name, "hotfix")) {
            try testing.expectEqualStrings("upstream", branch.remote.?);
            try testing.expectEqualStrings("refs/heads/hotfix", branch.merge.?);
            try testing.expect(!branch.rebase);
        }
    }
    
    std.debug.print("Config branch and remote management test completed successfully\n", .{});
}

test "config edge cases and malformed input handling" {
    const allocator = testing.allocator;
    
    // Test with malformed config that should be handled gracefully
    {
        var git_config = config.GitConfig.init(allocator);
        defer git_config.deinit();
        
        const malformed_config =
            \\# Config with various edge cases
            \\[user]
            \\    name = Valid User
            \\    email = valid@example.com
            \\    
            \\[invalid section without closing bracket
            \\    this should be ignored
            \\    
            \\[core]
            \\    # This is a comment
            \\    filemode = true
            \\    = value without key (should be ignored)
            \\    key without value
            \\    validkey = validvalue  
            \\    
            \\[] # Empty section name (should be ignored)
            \\    empty = section
            \\    
            \\[remote "origin"]
            \\    url = "https://example.com/repo.git"
            \\    malformed = incomplete quote "missing closing quote
            \\    valid = "properly quoted value"
        ;
        
        // This should not crash, even with malformed input
        try git_config.parseFromString(malformed_config);
        
        // Valid entries should still be parsed correctly
        try testing.expectEqualStrings("Valid User", git_config.getUserName().?);
        try testing.expectEqualStrings("valid@example.com", git_config.getUserEmail().?);
        try testing.expect(git_config.getBool("core", null, "filemode", false));
        try testing.expectEqualStrings("validvalue", git_config.get("core", null, "validkey").?);
        
        // Malformed entries should be ignored gracefully
        try testing.expect(git_config.get("core", null, "") == null);
        try testing.expect(git_config.get("", null, "empty") == null);
    }
    
    // Test with very large config
    {
        var git_config = config.GitConfig.init(allocator);
        defer git_config.deinit();
        
        var large_config = std.ArrayList(u8).init(allocator);
        defer large_config.deinit();
        
        // Generate a large config with many sections and keys
        try large_config.appendSlice("[user]\n    name = Test User\n    email = test@example.com\n");
        
        for (0..100) |i| {
            try large_config.writer().print("[section{}]\n", .{i});
            for (0..50) |j| {
                try large_config.writer().print("    key{} = value{}-{}\n", .{ j, i, j });
            }
        }
        
        // This should handle large configs without issues
        try git_config.parseFromString(large_config.items);
        
        // Verify some entries were parsed correctly
        try testing.expectEqualStrings("Test User", git_config.getUserName().?);
        try testing.expectEqualStrings("value0-0", git_config.get("section0", null, "key0").?);
        try testing.expectEqualStrings("value99-49", git_config.get("section99", null, "key49").?);
        
        std.debug.print("Large config processed: {} entries\n", .{git_config.getEntryCount()});
    }
    
    std.debug.print("Config edge cases test completed successfully\n", .{});
}