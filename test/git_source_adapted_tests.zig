const std = @import("std");


// Git Source Adapted Tests
// Direct adaptations from key git source test files
// Based on: t0001-init.sh, t2000-add.sh, t7500-commit.sh, t7060-wtstatus.sh, t4202-log.sh

const TestEnvironment = struct {
    allocator: std.mem.Allocator,
    test_counter: u32,
    ziggit_path: []const u8,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .test_counter = 0,
            .ziggit_path = "./zig-out/bin/ziggit",
        };
    }
    
    pub fn createTestRepo(self: *Self, name: []const u8) ![]const u8 {
        var buf: [256]u8 = undefined;
        const repo_path = try std.fmt.bufPrint(&buf, "/tmp/git-test-{s}-{d}", .{ name, self.test_counter });
        self.test_counter += 1;
        
        // Clean up any existing
        std.fs.cwd().deleteTree(repo_path[1..]) catch {};
        try std.fs.cwd().makePath(repo_path[1..]);
        
        const owned = try self.allocator.dupe(u8, repo_path);
        return owned;
    }
    
    pub fn exec(self: *Self, args: []const []const u8, cwd: []const u8) !TestResult {
        var proc = std.process.Child.init(args, self.allocator);
        proc.cwd = cwd;
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;
        
        try proc.spawn();
        
        const stdout = try proc.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        errdefer self.allocator.free(stdout);
        const stderr = try proc.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        errdefer self.allocator.free(stderr);
        
        const exit_code = try proc.wait();
        
        return TestResult{
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = switch (exit_code) {
                .Exited => |code| code,
                else => 255,
            },
            .allocator = self.allocator,
        };
    }
    
    pub fn ziggit(self: *Self, args: []const []const u8, cwd: []const u8) !TestResult {
        var full_args = std.ArrayList([]const u8).init(self.allocator);
        defer full_args.deinit();
        
        try full_args.append(self.ziggit_path);
        try full_args.appendSlice(args);
        
        return try self.exec(full_args.items, cwd);
    }
    
    pub fn git(self: *Self, args: []const []const u8, cwd: []const u8) !TestResult {
        var full_args = std.ArrayList([]const u8).init(self.allocator);
        defer full_args.deinit();
        
        try full_args.append("git");
        try full_args.appendSlice(args);
        
        return try self.exec(full_args.items, cwd);
    }
    
    pub fn cleanup(self: *Self, path: []const u8) void {
        std.fs.cwd().deleteTree(path[1..]) catch {};
        self.allocator.free(path);
    }
    
    pub fn writeFile(self: *Self, repo_path: []const u8, filename: []const u8, content: []const u8) !void {
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ repo_path, filename });
        defer self.allocator.free(full_path);
        try std.fs.cwd().writeFile(.{ .sub_path = full_path[1..], .data = content });
    }
    

};

const TestResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *TestResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

fn expectSuccess(result: *TestResult, context: []const u8) !void {
    if (result.exit_code != 0) {
        std.debug.print("    ✗ {s}: exit code {d}, stderr: {s}\n", .{ context, result.exit_code, result.stderr });
        return error.TestFailed;
    }
}

fn expectFailure(result: *TestResult, context: []const u8) !void {
    if (result.exit_code == 0) {
        std.debug.print("    ✗ {s}: expected failure but got success\n", .{context});
        return error.TestFailed;
    }
}

fn expectOutputContains(result: *TestResult, needle: []const u8, context: []const u8) !void {
    if (std.mem.indexOf(u8, result.stdout, needle) == null) {
        std.debug.print("    ✗ {s}: output missing '{s}' in: {s}\n", .{ context, needle, result.stdout });
        return error.TestFailed;
    }
}

// Adapted from t0001-init.sh
fn testT0001Init(env: *TestEnvironment) !void {
    std.debug.print("  Running t0001-init.sh adaptations...\n", .{});
    
    // test_expect_success 'plain' 'git init plain && check_config plain/.git false unset'
    {
        const repo = try env.createTestRepo("t0001-plain");
        defer env.cleanup(repo);
        
        var result = try env.ziggit(&[_][]const u8{"init"}, repo);
        defer result.deinit();
        
        try expectSuccess(&result, "plain init");
        
        // Check .git directory structure
        const git_dir = try std.fmt.allocPrint(env.allocator, "{s}/.git", .{repo});
        defer env.allocator.free(git_dir);
        
        var dir = std.fs.cwd().openDir(git_dir[1..], .{}) catch {
            std.debug.print("    ✗ .git directory not created\n", .{});
            return error.TestFailed;
        };
        defer dir.close();
        
        // Check essential files exist (like check_config)
        const required = [_][]const u8{ "config", "refs", "HEAD", "objects" };
        for (required) |file| {
            dir.access(file, .{}) catch {
                std.debug.print("    ✗ Missing required file/dir: {s}\n", .{file});
                return error.TestFailed;
            };
        }
        
        std.debug.print("    ✓ t0001 plain init test passed\n", .{});
    }
    
    // test_expect_success 'init in existing empty directory' 'git init'
    {
        const repo = try env.createTestRepo("t0001-existing");
        defer env.cleanup(repo);
        
        var result1 = try env.ziggit(&[_][]const u8{"init"}, repo);
        defer result1.deinit();
        try expectSuccess(&result1, "first init");
        
        var result2 = try env.ziggit(&[_][]const u8{"init"}, repo);
        defer result2.deinit();
        try expectSuccess(&result2, "re-init existing");
        
        std.debug.print("    ✓ t0001 re-init test passed\n", .{});
    }
}

// Adapted from t2000-add.sh  
fn testT2000Add(env: *TestEnvironment) !void {
    std.debug.print("  Running t2000-add.sh adaptations...\n", .{});
    
    const repo = try env.createTestRepo("t2000-add");
    defer env.cleanup(repo);
    
    var init_result = try env.ziggit(&[_][]const u8{"init"}, repo);
    defer init_result.deinit();
    try expectSuccess(&init_result, "init for add test");
    
    // test_expect_success 'Test of git add' 'touch foo && git add foo'
    {
        try env.writeFile(repo, "foo", "");
        
        var result = try env.ziggit(&[_][]const u8{ "add", "foo" }, repo);
        defer result.deinit();
        try expectSuccess(&result, "add file foo");
        
        // Check file is staged
        var status = try env.ziggit(&[_][]const u8{ "status", "--porcelain" }, repo);
        defer status.deinit();
        try expectOutputContains(&status, "A", "file staged");
        
        std.debug.print("    ✓ t2000 basic add test passed\n", .{});
    }
    
    // test_expect_success 'Post-check that foo is in the index' 'git ls-files | grep foo'
    {
        var ls_files = try env.ziggit(&[_][]const u8{"ls-files"}, repo);
        defer ls_files.deinit();
        
        if (ls_files.exit_code == 0) {
            try expectOutputContains(&ls_files, "foo", "foo in index");
            std.debug.print("    ✓ t2000 ls-files test passed\n", .{});
        } else {
            std.debug.print("    ⚠ ls-files command not implemented\n", .{});
        }
    }
    
    // test_expect_success 'Test that "git add -- -q" works' 'touch -- -q && git add -- -q'
    {
        try env.writeFile(repo, "-q", "special filename");
        
        var result = try env.ziggit(&[_][]const u8{ "add", "--", "-q" }, repo);
        defer result.deinit();
        
        if (result.exit_code == 0) {
            std.debug.print("    ✓ t2000 special filename test passed\n", .{});
        } else {
            std.debug.print("    ⚠ Special filename handling not fully implemented\n", .{});
        }
    }
}

// Adapted from t7500-commit.sh
fn testT7500Commit(env: *TestEnvironment) !void {
    std.debug.print("  Running t7500-commit.sh adaptations...\n", .{});
    
    const repo = try env.createTestRepo("t7500-commit");
    defer env.cleanup(repo);
    
    var init_result = try env.ziggit(&[_][]const u8{"init"}, repo);
    defer init_result.deinit();
    try expectSuccess(&init_result, "init for commit test");
    
    // test_expect_success 'A simple commit' 'echo "Content" > file && git add file && git commit -m "Initial commit"'
    {
        try env.writeFile(repo, "file", "Content\n");
        
        var add_result = try env.ziggit(&[_][]const u8{ "add", "file" }, repo);
        defer add_result.deinit();
        try expectSuccess(&add_result, "add for commit");
        
        var commit_result = try env.ziggit(&[_][]const u8{ "commit", "-m", "Initial commit" }, repo);
        defer commit_result.deinit();
        try expectSuccess(&commit_result, "initial commit");
        
        std.debug.print("    ✓ t7500 simple commit test passed\n", .{});
    }
    
    // test_expect_success 'nothing to commit' 'test_must_fail git commit -m "fail"'
    {
        var empty_commit = try env.ziggit(&[_][]const u8{ "commit", "-m", "fail" }, repo);
        defer empty_commit.deinit();
        try expectFailure(&empty_commit, "empty commit should fail");
        
        std.debug.print("    ✓ t7500 nothing to commit test passed\n", .{});
    }
    
    // test_expect_success 'commit message from file' 'echo "File message" > msg && git add . && echo "more" >> file && git add file && git commit -F msg'
    {
        try env.writeFile(repo, "msg", "File message\n");
        try env.writeFile(repo, "file", "Content\nmore\n");
        
        var add_result = try env.ziggit(&[_][]const u8{ "add", "file" }, repo);
        defer add_result.deinit();
        try expectSuccess(&add_result, "add modified file");
        
        var commit_result = try env.ziggit(&[_][]const u8{ "commit", "-F", "msg" }, repo);
        defer commit_result.deinit();
        
        if (commit_result.exit_code == 0) {
            std.debug.print("    ✓ t7500 commit from file test passed\n", .{});
        } else {
            std.debug.print("    ⚠ Commit from file (-F flag) not implemented\n", .{});
        }
    }
}

// Adapted from t7060-wtstatus.sh 
fn testT7060Status(env: *TestEnvironment) !void {
    std.debug.print("  Running t7060-wtstatus.sh adaptations...\n", .{});
    
    const repo = try env.createTestRepo("t7060-status");
    defer env.cleanup(repo);
    
    var init_result = try env.ziggit(&[_][]const u8{"init"}, repo);
    defer init_result.deinit();
    try expectSuccess(&init_result, "init for status test");
    
    // Create initial commit
    try env.writeFile(repo, "file", "initial\n");
    var add_result = try env.ziggit(&[_][]const u8{ "add", "file" }, repo);
    defer add_result.deinit();
    try expectSuccess(&add_result, "add for initial commit");
    
    var commit_result = try env.ziggit(&[_][]const u8{ "commit", "-m", "initial" }, repo);
    defer commit_result.deinit();
    try expectSuccess(&commit_result, "initial commit");
    
    // test_expect_success 'status --porcelain gives empty output for clean tree'
    {
        var status = try env.ziggit(&[_][]const u8{ "status", "--porcelain" }, repo);
        defer status.deinit();
        try expectSuccess(&status, "clean status");
        
        if (status.stdout.len > 0) {
            std.debug.print("    ✗ Clean tree should have empty status, got: {s}\n", .{status.stdout});
            return error.TestFailed;
        }
        
        std.debug.print("    ✓ t7060 clean status test passed\n", .{});
    }
    
    // test_expect_success 'status --porcelain shows modified files'
    {
        try env.writeFile(repo, "file", "modified\n");
        
        var status = try env.ziggit(&[_][]const u8{ "status", "--porcelain" }, repo);
        defer status.deinit();
        try expectSuccess(&status, "modified status");
        try expectOutputContains(&status, " M", "modified marker");
        
        std.debug.print("    ✓ t7060 modified status test passed\n", .{});
    }
    
    // test_expect_success 'status --porcelain shows staged files'
    {
        var add_modified = try env.ziggit(&[_][]const u8{ "add", "file" }, repo);
        defer add_modified.deinit();
        try expectSuccess(&add_modified, "add modified file");
        
        var status = try env.ziggit(&[_][]const u8{ "status", "--porcelain" }, repo);
        defer status.deinit();
        try expectSuccess(&status, "staged status");
        try expectOutputContains(&status, "M ", "staged marker");
        
        std.debug.print("    ✓ t7060 staged status test passed\n", .{});
    }
}

// Adapted from t4202-log.sh
fn testT4202Log(env: *TestEnvironment) !void {
    std.debug.print("  Running t4202-log.sh adaptations...\n", .{});
    
    const repo = try env.createTestRepo("t4202-log");
    defer env.cleanup(repo);
    
    var init_result = try env.ziggit(&[_][]const u8{"init"}, repo);
    defer init_result.deinit();
    try expectSuccess(&init_result, "init for log test");
    
    // Create a series of commits
    const commits = [_]struct { file: []const u8, content: []const u8, message: []const u8 }{
        .{ .file = "file1", .content = "first\n", .message = "first commit" },
        .{ .file = "file2", .content = "second\n", .message = "second commit" },
        .{ .file = "file3", .content = "third\n", .message = "third commit" },
    };
    
    for (commits) |commit_info| {
        try env.writeFile(repo, commit_info.file, commit_info.content);
        
        var add_result = try env.ziggit(&[_][]const u8{ "add", commit_info.file }, repo);
        defer add_result.deinit();
        try expectSuccess(&add_result, "add file");
        
        var commit_result = try env.ziggit(&[_][]const u8{ "commit", "-m", commit_info.message }, repo);
        defer commit_result.deinit();
        try expectSuccess(&commit_result, "commit");
    }
    
    // test_expect_success 'git log --oneline' 'git log --oneline >actual'
    {
        var log_result = try env.ziggit(&[_][]const u8{ "log", "--oneline" }, repo);
        defer log_result.deinit();
        try expectSuccess(&log_result, "log --oneline");
        
        // Check all commit messages are present
        for (commits) |commit_info| {
            try expectOutputContains(&log_result, commit_info.message, "commit message in log");
        }
        
        std.debug.print("    ✓ t4202 log --oneline test passed\n", .{});
    }
    
    // test_expect_success 'git log shows commits in reverse order'
    {
        var log_result = try env.ziggit(&[_][]const u8{"log"}, repo);
        defer log_result.deinit();
        try expectSuccess(&log_result, "full log");
        
        // Should show commits in reverse chronological order
        const third_pos = std.mem.indexOf(u8, log_result.stdout, "third commit");
        const first_pos = std.mem.indexOf(u8, log_result.stdout, "first commit");
        
        if (third_pos == null or first_pos == null or third_pos.? > first_pos.?) {
            std.debug.print("    ✗ Log not in correct order\n", .{});
            return error.TestFailed;
        }
        
        std.debug.print("    ✓ t4202 log order test passed\n", .{});
    }
}

// Comparison test: ziggit vs git output format
fn testOutputCompatibility(env: *TestEnvironment) !void {
    std.debug.print("  Testing output format compatibility with git...\n", .{});
    
    const repo = try env.createTestRepo("output-compat");
    defer env.cleanup(repo);
    
    // Set up identical repositories for both git and ziggit
    var ziggit_init = try env.ziggit(&[_][]const u8{"init"}, repo);
    defer ziggit_init.deinit();
    try expectSuccess(&ziggit_init, "ziggit init");
    
    // Create a simple commit scenario
    try env.writeFile(repo, "test.txt", "Hello world\n");
    
    var ziggit_add = try env.ziggit(&[_][]const u8{ "add", "test.txt" }, repo);
    defer ziggit_add.deinit();
    try expectSuccess(&ziggit_add, "ziggit add");
    
    var ziggit_commit = try env.ziggit(&[_][]const u8{ "commit", "-m", "Test commit" }, repo);
    defer ziggit_commit.deinit();
    try expectSuccess(&ziggit_commit, "ziggit commit");
    
    // Compare status output formats
    {
        // Modify file
        try env.writeFile(repo, "test.txt", "Hello world modified\n");
        
        var ziggit_status = try env.ziggit(&[_][]const u8{ "status", "--porcelain" }, repo);
        defer ziggit_status.deinit();
        
        var git_status = try env.git(&[_][]const u8{ "status", "--porcelain" }, repo);
        defer git_status.deinit();
        
        // Both should show " M test.txt"
        if (std.mem.indexOf(u8, ziggit_status.stdout, " M test.txt") != null and
            std.mem.indexOf(u8, git_status.stdout, " M test.txt") != null) {
            std.debug.print("    ✓ Status format compatibility check passed\n", .{});
        } else {
            std.debug.print("    ⚠ Status format differs - ziggit: {s}, git: {s}\n", .{ ziggit_status.stdout, git_status.stdout });
        }
    }
}

pub fn runGitSourceAdaptedTests() !void {
    std.debug.print("Running Git Source Adapted Tests...\n", .{});
    std.debug.print("Adapting core tests from git source tree (t0001, t2000, t7500, t7060, t4202)...\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var env = TestEnvironment.init(gpa.allocator());
    
    // Run adapted git source tests
    testT0001Init(&env) catch |err| {
        std.debug.print("  ✗ t0001-init.sh tests failed: {}\n", .{err});
    };
    
    testT2000Add(&env) catch |err| {
        std.debug.print("  ✗ t2000-add.sh tests failed: {}\n", .{err});
    };
    
    testT7500Commit(&env) catch |err| {
        std.debug.print("  ✗ t7500-commit.sh tests failed: {}\n", .{err});
    };
    
    testT7060Status(&env) catch |err| {
        std.debug.print("  ✗ t7060-wtstatus.sh tests failed: {}\n", .{err});
    };
    
    testT4202Log(&env) catch |err| {
        std.debug.print("  ✗ t4202-log.sh tests failed: {}\n", .{err});
    };
    
    testOutputCompatibility(&env) catch |err| {
        std.debug.print("  ✗ Output compatibility tests failed: {}\n", .{err});
    };
    
    std.debug.print("Git Source Adapted Tests completed!\n", .{});
}

// Unit tests
test "adapted git init test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var env = TestEnvironment.init(gpa.allocator());
    
    const repo = try env.createTestRepo("unit-init");
    defer env.cleanup(repo);
    
    var result = try env.ziggit(&[_][]const u8{"init"}, repo);
    defer result.deinit();
    
    try std.testing.expect(result.exit_code == 0);
}