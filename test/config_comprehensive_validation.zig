const std = @import("std");
const config = @import("../src/git/config.zig");
const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("🧪 Testing comprehensive git config functionality...\n");
    
    // Test basic config parsing
    print("📝 Testing basic config parsing...\n");
    try testBasicConfig(allocator);
    
    // Test complex config scenarios
    print("⚙️  Testing complex config scenarios...\n");
    try testComplexConfig(allocator);
    
    // Test config file I/O
    print("💾 Testing config file I/O...\n"); 
    try testConfigFileIO(allocator);
    
    // Test remote URL extraction (the specific library requirement)
    print("🌐 Testing remote URL extraction...\n");
    try testRemoteUrlExtraction(allocator);
    
    print("✅ All config tests completed successfully!\n");
}

fn testBasicConfig(allocator: std.mem.Allocator) !void {
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    const config_content =
        \\[user]
        \\    name = John Doe
        \\    email = john@example.com
        \\
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\
        \\[branch "main"]
        \\    remote = origin
        \\    merge = refs/heads/main
    ;
    
    try git_config.parseFromString(config_content);
    
    // Test user config
    const user_name = git_config.getUserName().?;
    const user_email = git_config.getUserEmail().?;
    
    if (!std.mem.eql(u8, user_name, "John Doe")) return error.UserNameMismatch;
    if (!std.mem.eql(u8, user_email, "john@example.com")) return error.UserEmailMismatch;
    
    // Test remote config
    const remote_url = git_config.getRemoteUrl("origin").?;
    if (!std.mem.eql(u8, remote_url, "https://github.com/user/repo.git")) return error.RemoteUrlMismatch;
    
    // Test branch config
    const branch_remote = git_config.getBranchRemote("main").?;
    const branch_merge = git_config.getBranchMerge("main").?;
    
    if (!std.mem.eql(u8, branch_remote, "origin")) return error.BranchRemoteMismatch;
    if (!std.mem.eql(u8, branch_merge, "refs/heads/main")) return error.BranchMergeMismatch;
    
    print("✅ Basic config parsing successful\n");
}

fn testComplexConfig(allocator: std.mem.Allocator) !void {
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
        \\
        \\[remote "origin"]
        \\    url = git@github.com:ziggit/ziggit.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\
        \\[remote "upstream"]
        \\    url = "https://github.com/original/repo.git"
        \\    fetch = +refs/heads/*:refs/remotes/upstream/*
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
        \\[user]
        \\    name = "Test User"
        \\    email = test@example.com
        \\
        \\[push]
        \\    default = simple
        \\
        \\[pull]
        \\    rebase = false
        \\
        \\; This is also a comment
        \\[alias]
        \\    st = status
        \\    co = checkout
        \\    br = branch
    ;
    
    try git_config.parseFromString(complex_config);
    
    // Test core settings
    if (!git_config.getFileMode()) return error.FileModeMismatch;
    if (git_config.getBare()) return error.BareMismatch;
    if (!git_config.getIgnoreCase()) return error.IgnoreCaseMismatch;
    
    // Test multiple remotes
    const origin_url = git_config.getRemoteUrl("origin").?;
    const upstream_url = git_config.getRemoteUrl("upstream").?;
    
    if (!std.mem.eql(u8, origin_url, "git@github.com:ziggit/ziggit.git")) return error.OriginUrlMismatch;
    if (!std.mem.eql(u8, upstream_url, "https://github.com/original/repo.git")) return error.UpstreamUrlMismatch;
    
    // Test quoted values
    const user_name = git_config.getUserName().?;
    if (!std.mem.eql(u8, user_name, "Test User")) return error.QuotedNameMismatch;
    
    // Test boolean values
    const develop_rebase = git_config.getBool("branch", "develop", "rebase", false);
    const pull_rebase = git_config.getPullRebase();
    
    if (!develop_rebase) return error.DevelopRebaseMismatch;
    if (pull_rebase) return error.PullRebaseMismatch;
    
    // Test push default
    const push_default = git_config.getPushDefault().?;
    if (!std.mem.eql(u8, push_default, "simple")) return error.PushDefaultMismatch;
    
    print("✅ Complex config parsing successful\n");
}

fn testConfigFileIO(allocator: std.mem.Allocator) !void {
    // Create a temporary config file
    const temp_config_path = "test_config.tmp";
    
    // Clean up any existing temp file
    std.fs.cwd().deleteFile(temp_config_path) catch {};
    defer std.fs.cwd().deleteFile(temp_config_path) catch {};
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    // Set some values
    try git_config.setValue("user", null, "name", "Test Writer");
    try git_config.setValue("user", null, "email", "writer@test.com");
    try git_config.setValue("remote", "origin", "url", "https://example.com/repo.git");
    try git_config.setValue("core", null, "filemode", "true");
    
    // Write to file
    try git_config.writeToFile(temp_config_path);
    
    // Read back from file
    var read_config = config.GitConfig.init(allocator);
    defer read_config.deinit();
    try read_config.parseFromFile(temp_config_path);
    
    // Verify values
    const name = read_config.getUserName().?;
    const email = read_config.getUserEmail().?;
    const url = read_config.getRemoteUrl("origin").?;
    const filemode = read_config.getBool("core", null, "filemode", false);
    
    if (!std.mem.eql(u8, name, "Test Writer")) return error.FileIONameMismatch;
    if (!std.mem.eql(u8, email, "writer@test.com")) return error.FileIOEmailMismatch;
    if (!std.mem.eql(u8, url, "https://example.com/repo.git")) return error.FileIOUrlMismatch;
    if (!filemode) return error.FileIOFilemodeMismatch;
    
    print("✅ Config file I/O successful\n");
}

fn testRemoteUrlExtraction(allocator: std.mem.Allocator) !void {
    // This is the specific functionality mentioned in the task:
    // "ziggit_remote_get_url() currently returns a placeholder"
    
    // Create test git directory structure
    try std.fs.cwd().makePath("test_git_config/.git");
    defer std.fs.cwd().deleteTree("test_git_config") catch {};
    
    const test_config =
        \\[remote "origin"]
        \\    url = https://github.com/hdresearch/ziggit.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\
        \\[remote "fork"]
        \\    url = git@github.com:user/ziggit.git
        \\    fetch = +refs/heads/*:refs/remotes/fork/*
        \\
        \\[branch "master"]
        \\    remote = origin
        \\    merge = refs/heads/master
    ;
    
    try std.fs.cwd().writeFile("test_git_config/.git/config", test_config);
    
    // Load config from git directory
    var git_config = config.loadGitConfig("test_git_config/.git", allocator) catch |err| {
        print("Failed to load git config: {}\n", .{err});
        return err;
    };
    defer git_config.deinit();
    
    // Test remote URL extraction (the core library function)
    const origin_url = git_config.getRemoteUrl("origin").?;
    const fork_url = git_config.getRemoteUrl("fork").?;
    
    if (!std.mem.eql(u8, origin_url, "https://github.com/hdresearch/ziggit.git")) {
        return error.OriginRemoteUrlMismatch;
    }
    
    if (!std.mem.eql(u8, fork_url, "git@github.com:user/ziggit.git")) {
        return error.ForkRemoteUrlMismatch;
    }
    
    // Test the convenience function that would replace the placeholder
    const extracted_origin_url = config.getRemoteUrl("test_git_config/.git", "origin", allocator) catch |err| {
        print("Failed to extract remote URL: {}\n", .{err});
        return err;
    };
    defer if (extracted_origin_url) |url| allocator.free(url);
    
    if (extracted_origin_url) |url| {
        if (!std.mem.eql(u8, url, "https://github.com/hdresearch/ziggit.git")) {
            return error.ExtractedUrlMismatch;
        }
    } else {
        return error.NoUrlExtracted;
    }
    
    // Test nonexistent remote
    const nonexistent_url = config.getRemoteUrl("test_git_config/.git", "nonexistent", allocator) catch null;
    if (nonexistent_url != null) {
        allocator.free(nonexistent_url.?);
        return error.NonexistentRemoteShouldBeNull;
    }
    
    print("✅ Remote URL extraction successful\n");
    print("   Origin URL: {s}\n", .{origin_url});
    print("   Fork URL: {s}\n", .{fork_url});
}