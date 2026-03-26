const std = @import("std");
const testing = std.testing;
const config = @import("../src/git/config.zig");

test "git config parsing with realistic .git/config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const config_content =
        \\[core]
        \\	repositoryformatversion = 0
        \\	filemode = true
        \\	bare = false
        \\	logallrefupdates = true
        \\[remote "origin"]
        \\	url = https://github.com/user/repo.git
        \\	fetch = +refs/heads/*:refs/remotes/origin/*
        \\[branch "main"]
        \\	remote = origin
        \\	merge = refs/heads/main
        \\[user]
        \\	name = Test User
        \\	email = test@example.com
        \\[push]
        \\	default = simple
        \\[pull]
        \\	rebase = false
    ;
    
    var git_config = try config.GitConfig.parseConfig(allocator, config_content);
    defer git_config.deinit();
    
    // Test core settings
    try testing.expectEqualStrings("0", git_config.get("core", null, "repositoryformatversion").?);
    try testing.expectEqualStrings("true", git_config.get("core", null, "filemode").?);
    try testing.expectEqualStrings("false", git_config.get("core", null, "bare").?);
    
    // Test remote settings
    try testing.expectEqualStrings("https://github.com/user/repo.git", git_config.get("remote", "origin", "url").?);
    try testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", git_config.get("remote", "origin", "fetch").?);
    
    // Test branch settings
    try testing.expectEqualStrings("origin", git_config.get("branch", "main", "remote").?);
    try testing.expectEqualStrings("refs/heads/main", git_config.get("branch", "main", "merge").?);
    
    // Test user settings
    try testing.expectEqualStrings("Test User", git_config.get("user", null, "name").?);
    try testing.expectEqualStrings("test@example.com", git_config.get("user", null, "email").?);
    
    // Test non-existent keys
    try testing.expect(git_config.get("nonexistent", null, "key") == null);
    try testing.expect(git_config.get("user", null, "nonexistent") == null);
}

test "git config parsing with quoted values and escapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const config_content =
        \\[user]
        \\	name = "John Doe"
        \\	email = john@example.com
        \\[alias]
        \\	st = status
        \\	co = checkout
        \\	br = branch
        \\	unstage = "reset HEAD --"
        \\[core]
        \\	editor = "code --wait"
        \\	pager = less -R
    ;
    
    var git_config = try config.GitConfig.parseConfig(allocator, config_content);
    defer git_config.deinit();
    
    // Test quoted values (quotes should be removed)
    try testing.expectEqualStrings("John Doe", git_config.get("user", null, "name").?);
    try testing.expectEqualStrings("john@example.com", git_config.get("user", null, "email").?);
    try testing.expectEqualStrings("reset HEAD --", git_config.get("alias", null, "unstage").?);
    try testing.expectEqualStrings("code --wait", git_config.get("core", null, "editor").?);
    
    // Test unquoted values
    try testing.expectEqualStrings("status", git_config.get("alias", null, "st").?);
    try testing.expectEqualStrings("less -R", git_config.get("core", null, "pager").?);
}

test "git config with multiple remotes and branches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const config_content =
        \\[remote "origin"]
        \\	url = https://github.com/user/repo.git
        \\	fetch = +refs/heads/*:refs/remotes/origin/*
        \\[remote "upstream"]
        \\	url = https://github.com/upstream/repo.git
        \\	fetch = +refs/heads/*:refs/remotes/upstream/*
        \\[branch "main"]
        \\	remote = origin
        \\	merge = refs/heads/main
        \\[branch "development"]
        \\	remote = origin
        \\	merge = refs/heads/development
        \\[branch "feature/test"]
        \\	remote = upstream
        \\	merge = refs/heads/feature/test
    ;
    
    var git_config = try config.GitConfig.parseConfig(allocator, config_content);
    defer git_config.deinit();
    
    // Test multiple remotes
    try testing.expectEqualStrings("https://github.com/user/repo.git", git_config.get("remote", "origin", "url").?);
    try testing.expectEqualStrings("https://github.com/upstream/repo.git", git_config.get("remote", "upstream", "url").?);
    
    // Test multiple branches
    try testing.expectEqualStrings("origin", git_config.get("branch", "main", "remote").?);
    try testing.expectEqualStrings("origin", git_config.get("branch", "development", "remote").?);
    try testing.expectEqualStrings("upstream", git_config.get("branch", "feature/test", "remote").?);
    
    // Test branch merge refs
    try testing.expectEqualStrings("refs/heads/main", git_config.get("branch", "main", "merge").?);
    try testing.expectEqualStrings("refs/heads/development", git_config.get("branch", "development", "merge").?);
    try testing.expectEqualStrings("refs/heads/feature/test", git_config.get("branch", "feature/test", "merge").?);
}

test "git config error handling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Test malformed config (missing closing bracket)
    const malformed_config =
        \\[core
        \\	filemode = true
        \\[user]
        \\	name = Test User
    ;
    
    var git_config = try config.GitConfig.parseConfig(allocator, malformed_config);
    defer git_config.deinit();
    
    // Should still parse the valid parts
    try testing.expect(git_config.get("core", null, "filemode") == null); // Section header was malformed
    try testing.expectEqualStrings("Test User", git_config.get("user", null, "name").?);
    
    // Test empty config
    var empty_config = try config.GitConfig.parseConfig(allocator, "");
    defer empty_config.deinit();
    try testing.expect(empty_config.get("any", null, "key") == null);
    
    // Test config with only comments
    const comments_only =
        \\# This is a comment
        \\; This is also a comment
        \\    # Indented comment
        \\
        \\# Another comment
    ;
    
    var comments_config = try config.GitConfig.parseConfig(allocator, comments_only);
    defer comments_config.deinit();
    try testing.expect(comments_config.get("any", null, "key") == null);
}

test "git config case sensitivity and whitespace handling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const config_content =
        \\[Core]
        \\	FileMode = true
        \\   RepositoryFormatVersion   =   0   
        \\[REMOTE "Origin"]
        \\	URL = https://github.com/user/repo.git
        \\[branch "MAIN"]
        \\	Remote = Origin
    ;
    
    var git_config = try config.GitConfig.parseConfig(allocator, config_content);
    defer git_config.deinit();
    
    // Git is case-insensitive for section and key names
    try testing.expectEqualStrings("true", git_config.get("core", null, "filemode").?);
    try testing.expectEqualStrings("true", git_config.get("Core", null, "FileMode").?);
    try testing.expectEqualStrings("0", git_config.get("core", null, "repositoryformatversion").?);
    
    // Subsection names are case-sensitive
    try testing.expectEqualStrings("https://github.com/user/repo.git", git_config.get("remote", "Origin", "url").?);
    try testing.expect(git_config.get("remote", "origin", "url") == null); // Different case
    
    try testing.expectEqualStrings("Origin", git_config.get("branch", "MAIN", "remote").?);
}

test "git config with boolean values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const config_content =
        \\[core]
        \\	bare = true
        \\	filemode = false
        \\	logallrefupdates = yes
        \\	symlinks = no
        \\	ignorecase = 1
        \\	autocrlf = 0
        \\	safecrlf = on
        \\	trustctime = off
    ;
    
    var git_config = try config.GitConfig.parseConfig(allocator, config_content);
    defer git_config.deinit();
    
    // Test various boolean representations
    try testing.expectEqualStrings("true", git_config.get("core", null, "bare").?);
    try testing.expectEqualStrings("false", git_config.get("core", null, "filemode").?);
    try testing.expectEqualStrings("yes", git_config.get("core", null, "logallrefupdates").?);
    try testing.expectEqualStrings("no", git_config.get("core", null, "symlinks").?);
    try testing.expectEqualStrings("1", git_config.get("core", null, "ignorecase").?);
    try testing.expectEqualStrings("0", git_config.get("core", null, "autocrlf").?);
    try testing.expectEqualStrings("on", git_config.get("core", null, "safecrlf").?);
    try testing.expectEqualStrings("off", git_config.get("core", null, "trustctime").?);
}

test "git config with include directives" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const config_content =
        \\[core]
        \\	repositoryformatversion = 0
        \\[include]
        \\	path = ~/.gitconfig
        \\[includeIf "gitdir:~/work/"]
        \\	path = ~/work/.gitconfig
        \\[user]
        \\	name = Test User
    ;
    
    var git_config = try config.GitConfig.parseConfig(allocator, config_content);
    defer git_config.deinit();
    
    // Include directives should be parsed as regular config entries
    // (actual include processing would be done at a higher level)
    try testing.expectEqualStrings("~/.gitconfig", git_config.get("include", null, "path").?);
    try testing.expectEqualStrings("~/work/.gitconfig", git_config.get("includeIf", "gitdir:~/work/", "path").?);
    try testing.expectEqualStrings("Test User", git_config.get("user", null, "name").?);
}

test "git config helper functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const config_content =
        \\[remote "origin"]
        \\	url = https://github.com/user/repo.git
        \\[branch "main"]
        \\	remote = origin
        \\[user]
        \\	name = Test User
        \\	email = test@example.com
    ;
    
    var git_config = try config.GitConfig.parseConfig(allocator, config_content);
    defer git_config.deinit();
    
    // Test helper functions
    const remote_url = try git_config.getRemoteUrl(allocator, "origin");
    defer if (remote_url) |url| allocator.free(url);
    try testing.expectEqualStrings("https://github.com/user/repo.git", remote_url.?);
    
    const branch_remote = try git_config.getBranchRemote(allocator, "main");
    defer if (branch_remote) |remote| allocator.free(remote);
    try testing.expectEqualStrings("origin", branch_remote.?);
    
    const user_name = try git_config.getUserName(allocator);
    defer if (user_name) |name| allocator.free(name);
    try testing.expectEqualStrings("Test User", user_name.?);
    
    const user_email = try git_config.getUserEmail(allocator);
    defer if (user_email) |email| allocator.free(email);
    try testing.expectEqualStrings("test@example.com", user_email.?);
}