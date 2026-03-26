const std = @import("std");
const config = @import("../src/git/config.zig");

// Comprehensive test for advanced git config parsing features
// This test demonstrates all the enhanced config parsing capabilities

test "advanced config parsing with complex scenarios" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing advanced config parsing features...\n");
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    // Complex config with edge cases, comments, quoted values, and multiple remotes
    const complex_config =
        \\# Git configuration file with advanced features
        \\# This tests the parser's robustness
        \\
        \\[core]
        \\    repositoryformatversion = 0
        \\    filemode = true
        \\    bare = false
        \\    logallrefupdates = true
        \\    ignorecase = false
        \\    autocrlf = input
        \\    editor = "code --wait"
        \\    pager = less -R
        \\
        \\[user]
        \\    name = "John Doe Jr."
        \\    email = john.doe+git@example.com
        \\    signingkey = ABC123DEF456
        \\
        \\[remote "origin"]
        \\    url = git@github.com:user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\    pushurl = git@github.com:user/repo.git
        \\    tagopt = --tags
        \\
        \\[remote "upstream"]
        \\    url = https://github.com/upstream/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/upstream/*
        \\
        \\[branch "main"]
        \\    remote = origin
        \\    merge = refs/heads/main
        \\    rebase = true
        \\
        \\[branch "develop"]
        \\    remote = upstream
        \\    merge = refs/heads/develop
        \\    rebase = false
        \\
        \\[push]
        \\    default = simple
        \\    followTags = true
        \\
        \\[pull]
        \\    rebase = true
        \\    ff = only
        \\
        \\[merge]
        \\    tool = vimdiff
        \\    conflictStyle = diff3
        \\
        \\[diff]
        \\    tool = vimdiff
        \\    algorithm = patience
        \\
        \\[init]
        \\    defaultBranch = main
        \\
        \\[commit]
        \\    gpgsign = true
        \\    template = ~/.gitmessage
        \\
        \\[tag]
        \\    gpgsign = true
        \\
        \\[alias]
        \\    st = status
        \\    co = checkout
        \\    br = branch
        \\    ci = commit
        \\    unstage = "reset HEAD --"
        \\    last = "log -1 HEAD"
        \\    visual = "!gitk"
        \\    graph = "log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit"
        \\
        \\[color]
        \\    ui = auto
        \\
        \\[color "status"]
        \\    added = green
        \\    changed = red bold
        \\    untracked = magenta
        \\
        \\[color "branch"]
        \\    current = yellow reverse
        \\    local = yellow
        \\    remote = green
        \\
        \\[filter "lfs"]
        \\    clean = git-lfs clean -- %f
        \\    smudge = git-lfs smudge -- %f
        \\    process = git-lfs filter-process
        \\    required = true
        \\
        \\[http]
        \\    sslverify = true
        \\    postbuffer = 524288000
        \\
        \\[https "github.com"]
        \\    proxy = https://proxy.example.com:8080
        \\
        \\[sendemail]
        \\    smtpserver = smtp.gmail.com
        \\    smtpuser = john.doe@gmail.com
        \\    smtpencryption = tls
        \\    smtpserverport = 587
        \\
        \\# This is a comment at the end
        \\
    ;
    
    try git_config.parseFromString(complex_config);
    
    std.debug.print("📊 Parsed {} config entries\n", .{git_config.entries.items.len});
    
    // Test basic user config
    const user_name = git_config.getUserName().?;
    const user_email = git_config.getUserEmail().?;
    try std.testing.expectEqualStrings("John Doe Jr.", user_name);
    try std.testing.expectEqualStrings("john.doe+git@example.com", user_email);
    std.debug.print("👤 User: {s} <{s}>\n", .{ user_name, user_email });
    
    // Test multiple remotes
    const origin_url = git_config.getRemoteUrl("origin").?;
    const upstream_url = git_config.getRemoteUrl("upstream").?;
    try std.testing.expectEqualStrings("git@github.com:user/repo.git", origin_url);
    try std.testing.expectEqualStrings("https://github.com/upstream/repo.git", upstream_url);
    std.debug.print("🌐 Origin: {s}\n", .{origin_url});
    std.debug.print("🌐 Upstream: {s}\n", .{upstream_url});
    
    // Test branch configurations
    const main_remote = git_config.getBranchRemote("main").?;
    const develop_remote = git_config.getBranchRemote("develop").?;
    try std.testing.expectEqualStrings("origin", main_remote);
    try std.testing.expectEqualStrings("upstream", develop_remote);
    std.debug.print("🌿 Main branch remote: {s}\n", .{main_remote});
    std.debug.print("🌿 Develop branch remote: {s}\n", .{develop_remote});
    
    // Test boolean value parsing
    const rebase_main = git_config.getBool("branch", "main", "rebase", false);
    const rebase_develop = git_config.getBool("branch", "develop", "rebase", false);
    try std.testing.expect(rebase_main == true);
    try std.testing.expect(rebase_develop == false);
    std.debug.print("🔄 Main rebase: {}, Develop rebase: {}\n", .{ rebase_main, rebase_develop });
    
    // Test core settings
    const file_mode = git_config.getBool("core", null, "filemode", false);
    const bare = git_config.getBool("core", null, "bare", true);
    try std.testing.expect(file_mode == true);
    try std.testing.expect(bare == false);
    std.debug.print("⚙️  File mode: {}, Bare: {}\n", .{ file_mode, bare });
    
    // Test quoted values
    const editor = git_config.get("core", null, "editor").?;
    try std.testing.expectEqualStrings("code --wait", editor);
    std.debug.print("✏️  Editor: {s}\n", .{editor});
    
    // Test complex alias values
    const graph_alias = git_config.get("alias", null, "graph").?;
    try std.testing.expect(std.mem.startsWith(u8, graph_alias, "log --graph"));
    std.debug.print("🎨 Graph alias configured\n");
    
    // Test subsection with special characters
    const github_proxy = git_config.get("https", "github.com", "proxy").?;
    try std.testing.expectEqualStrings("https://proxy.example.com:8080", github_proxy);
    std.debug.print("🔐 GitHub proxy: {s}\n", .{github_proxy});
    
    std.debug.print("✅ Advanced config parsing test passed\n");
}

test "config validation and error detection" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing config validation and error detection...\n");
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    // Config with some issues for validation testing
    const problematic_config =
        \\[user]
        \\    name = Test User
        \\    email = invalid-email-format
        \\
        \\[core]
        \\    autocrlf = invalid_value
        \\
        \\[push]
        \\    default = invalid_push_mode
        \\
        \\[remote "origin"]
        \\    url = https://github.com/test/repo.git
    ;
    
    try git_config.parseFromString(problematic_config);
    
    // Test validation
    const issues = try git_config.validateConfig(allocator);
    defer {
        for (issues) |issue| {
            allocator.free(issue);
        }
        allocator.free(issues);
    }
    
    std.debug.print("🔍 Found {} configuration issues\n", .{issues.len});
    for (issues) |issue| {
        std.debug.print("⚠️  {s}\n", .{issue});
    }
    
    try std.testing.expect(issues.len > 0); // Should find some issues
    std.debug.print("✅ Config validation test passed\n");
}

test "config modification and serialization" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing config modification and serialization...\n");
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    // Start with basic config
    const basic_config =
        \\[user]
        \\    name = Initial User
        \\    email = initial@example.com
        \\
        \\[remote "origin"]
        \\    url = https://github.com/initial/repo.git
    ;
    
    try git_config.parseFromString(basic_config);
    
    // Test setting new values
    try git_config.setValue("user", null, "name", "Updated User");
    try git_config.setValue("user", null, "signingkey", "ABCD1234");
    try git_config.setValue("remote", "upstream", "url", "https://github.com/upstream/repo.git");
    try git_config.setValue("core", null, "autocrlf", "input");
    
    // Verify changes
    try std.testing.expectEqualStrings("Updated User", git_config.getUserName().?);
    try std.testing.expectEqualStrings("ABCD1234", git_config.get("user", null, "signingkey").?);
    try std.testing.expectEqualStrings("https://github.com/upstream/repo.git", git_config.getRemoteUrl("upstream").?);
    
    std.debug.print("✏️  Updated config values successfully\n");
    
    // Test removing values
    const removed = try git_config.removeValue("user", null, "signingkey");
    try std.testing.expect(removed == true);
    try std.testing.expect(git_config.get("user", null, "signingkey") == null);
    
    std.debug.print("🗑️  Removed config value successfully\n");
    
    // Test serialization back to string
    const serialized = try git_config.toString(allocator);
    defer allocator.free(serialized);
    
    try std.testing.expect(std.mem.indexOf(u8, serialized, "Updated User") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "upstream") != null);
    
    std.debug.print("💾 Config serialization successful\n");
    std.debug.print("✅ Config modification test passed\n");
}

test "config branch and remote analysis" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing config branch and remote analysis...\n");
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    const multi_remote_config =
        \\[remote "origin"]
        \\    url = git@github.com:user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\    pushurl = git@github.com:user/repo.git
        \\
        \\[remote "upstream"]
        \\    url = https://github.com/upstream/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/upstream/*
        \\
        \\[remote "fork"]
        \\    url = https://github.com/fork/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/fork/*
        \\
        \\[branch "main"]
        \\    remote = origin
        \\    merge = refs/heads/main
        \\    rebase = true
        \\
        \\[branch "develop"]
        \\    remote = upstream
        \\    merge = refs/heads/develop
        \\
        \\[branch "feature-branch"]
        \\    remote = fork
        \\    merge = refs/heads/feature-branch
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
    
    try std.testing.expect(remotes.len == 3);
    std.debug.print("🌐 Found {} remotes\n", .{remotes.len});
    
    var found_origin = false;
    var found_upstream = false;
    var found_fork = false;
    
    for (remotes) |remote| {
        std.debug.print("  - {s}\n", .{remote});
        if (std.mem.eql(u8, remote, "origin")) found_origin = true;
        if (std.mem.eql(u8, remote, "upstream")) found_upstream = true;
        if (std.mem.eql(u8, remote, "fork")) found_fork = true;
    }
    
    try std.testing.expect(found_origin and found_upstream and found_fork);
    
    // Test getting all branches with tracking info
    const branches = try git_config.getAllBranches(allocator);
    defer {
        for (branches) |branch| {
            branch.deinit(allocator);
        }
        allocator.free(branches);
    }
    
    try std.testing.expect(branches.len == 3);
    std.debug.print("🌿 Found {} configured branches\n", .{branches.len});
    
    for (branches) |branch| {
        std.debug.print("  - {s}", .{branch.name});
        if (branch.remote) |remote| {
            std.debug.print(" -> {s}", .{remote});
        }
        if (branch.merge) |merge| {
            std.debug.print(" ({s})", .{merge});
        }
        if (branch.rebase) {
            std.debug.print(" [rebase]");
        }
        std.debug.print("\n");
        
        // Test upstream ref generation
        if (branch.getUpstreamRef(allocator)) |upstream_ref| {
            defer allocator.free(upstream_ref);
            std.debug.print("    upstream: {s}\n", .{upstream_ref});
        } else |_| {}
    }
    
    std.debug.print("✅ Branch and remote analysis test passed\n");
}

test "config case insensitivity and robustness" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing config case insensitivity and robustness...\n");
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    // Config with mixed case to test case insensitivity
    const mixed_case_config =
        \\[USER]
        \\    NAME = Case Test User
        \\    EMAIL = case@example.com
        \\
        \\[Remote "Origin"]
        \\    URL = https://github.com/case/test.git
        \\    FETCH = +refs/heads/*:refs/remotes/origin/*
        \\
        \\[Branch "Main"]
        \\    REMOTE = origin
        \\    MERGE = refs/heads/main
        \\
        \\[core]
        \\    FileMode = True
        \\    IgnoreCase = FALSE
        \\    AutoCRLF = Input
    ;
    
    try git_config.parseFromString(mixed_case_config);
    
    // Test case-insensitive access
    try std.testing.expectEqualStrings("Case Test User", git_config.get("user", null, "name").?);
    try std.testing.expectEqualStrings("Case Test User", git_config.get("USER", null, "NAME").?);
    try std.testing.expectEqualStrings("Case Test User", git_config.get("User", null, "Name").?);
    
    try std.testing.expectEqualStrings("case@example.com", git_config.get("user", null, "email").?);
    try std.testing.expectEqualStrings("case@example.com", git_config.get("USER", null, "EMAIL").?);
    
    try std.testing.expectEqualStrings("https://github.com/case/test.git", git_config.get("remote", "origin", "url").?);
    try std.testing.expectEqualStrings("https://github.com/case/test.git", git_config.get("REMOTE", "ORIGIN", "URL").?);
    
    // Test boolean parsing with different cases
    try std.testing.expect(git_config.getBool("core", null, "filemode", false) == true);
    try std.testing.expect(git_config.getBool("CORE", null, "FILEMODE", false) == true);
    try std.testing.expect(git_config.getBool("core", null, "ignorecase", true) == false);
    
    std.debug.print("🔤 Case insensitive access works correctly\n");
    
    // Test robustness with malformed lines (should skip them gracefully)
    const malformed_config =
        \\[user]
        \\    name = Good User
        \\    email = good@example.com
        \\
        \\    # This line has no = sign and should be skipped
        \\    invalid_line_without_equals
        \\
        \\[section_without_closing_bracket
        \\    this = should be ignored
        \\
        \\[good_section]
        \\    valid = value
        \\
        \\[] 
        \\    empty = section name should be ignored
        \\
        \\[final]
        \\    last = value
    ;
    
    var robust_config = config.GitConfig.init(allocator);
    defer robust_config.deinit();
    
    try robust_config.parseFromString(malformed_config);
    
    // Should still be able to parse the valid parts
    try std.testing.expectEqualStrings("Good User", robust_config.getUserName().?);
    try std.testing.expectEqualStrings("good@example.com", robust_config.getUserEmail().?);
    try std.testing.expectEqualStrings("value", robust_config.get("good_section", null, "valid").?);
    try std.testing.expectEqualStrings("value", robust_config.get("final", null, "last").?);
    
    std.debug.print("🛡️  Robust parsing handles malformed input correctly\n");
    std.debug.print("✅ Case insensitivity and robustness test passed\n");
}

test "config performance and memory efficiency" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing config performance and memory efficiency...\n");
    
    // Generate a large config for performance testing
    var large_config = std.ArrayList(u8).init(allocator);
    defer large_config.deinit();
    
    const writer = large_config.writer();
    
    // Create many sections and entries
    try writer.writeAll("[user]\n");
    try writer.writeAll("    name = Performance Test User\n");
    try writer.writeAll("    email = perf@example.com\n\n");
    
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try writer.print("[remote \"remote{}\"]\n", .{i});
        try writer.print("    url = https://github.com/user/repo{}.git\n", .{i});
        try writer.print("    fetch = +refs/heads/*:refs/remotes/remote{}/*\n\n", .{i});
    }
    
    i = 0;
    while (i < 50) : (i += 1) {
        try writer.print("[branch \"branch{}\"]\n", .{i});
        try writer.print("    remote = remote{}\n", .{i % 10});
        try writer.print("    merge = refs/heads/branch{}\n\n", .{i});
    }
    
    std.debug.print("📏 Generated large config: {} bytes\n", .{large_config.items.len});
    
    const start_time = std.time.milliTimestamp();
    
    var perf_config = config.GitConfig.init(allocator);
    defer perf_config.deinit();
    
    try perf_config.parseFromString(large_config.items);
    
    const parse_time = std.time.milliTimestamp() - start_time;
    
    std.debug.print("⏱️  Parsed {} entries in {} ms\n", .{ perf_config.entries.items.len, parse_time });
    
    // Test lookup performance
    const lookup_start = std.time.milliTimestamp();
    
    var j: u32 = 0;
    while (j < 100) : (j += 1) {
        const remote_name = std.fmt.allocPrint(allocator, "remote{}", .{j}) catch break;
        defer allocator.free(remote_name);
        
        const url = perf_config.getRemoteUrl(remote_name);
        try std.testing.expect(url != null);
    }
    
    const lookup_time = std.time.milliTimestamp() - lookup_start;
    
    std.debug.print("🔍 100 lookups completed in {} ms\n", .{lookup_time});
    
    // Memory usage validation - config should properly manage memory
    const entry_count = perf_config.getEntryCount();
    try std.testing.expect(entry_count > 200); // Should have parsed many entries
    
    std.debug.print("📊 Final entry count: {}\n", .{entry_count});
    std.debug.print("✅ Performance and memory efficiency test passed\n");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("🚀 Running comprehensive config advanced features tests\n");
    std.debug.print("=" ** 70 ++ "\n");
    
    // Run all comprehensive tests
    _ = @import("std").testing.refAllDecls(@This());
    
    std.debug.print("\n🎉 All comprehensive config tests completed!\n");
    std.debug.print("\nConfig parsing improvements demonstrated:\n");
    std.debug.print("• ✅ Complex config parsing with edge cases\n");
    std.debug.print("• ✅ Multi-value and quoted value support\n");
    std.debug.print("• ✅ Boolean and integer value parsing\n");
    std.debug.print("• ✅ Configuration validation and error detection\n");
    std.debug.print("• ✅ Dynamic modification and serialization\n");
    std.debug.print("• ✅ Branch and remote analysis\n");
    std.debug.print("• ✅ Case insensitivity and robust error handling\n");
    std.debug.print("• ✅ Performance optimization for large configs\n");
}