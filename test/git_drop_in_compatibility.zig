const std = @import("std");
const testing = std.testing;

// Git Drop-in Compatibility Test Suite
// Ensures ziggit can replace git for the most common operations

const TestFramework = struct {
    allocator: std.mem.Allocator,
    temp_dir_counter: u32 = 0,

    fn init(allocator: std.mem.Allocator) TestFramework {
        return TestFramework{ .allocator = allocator };
    }

    fn runCommand(self: *TestFramework, argv: []const []const u8) !std.process.Child.RunResult {
        return try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv,
            .max_output_bytes = 1024 * 1024,
        });
    }

    fn createTempDir(self: *TestFramework, name: []const u8) ![]u8 {
        self.temp_dir_counter += 1;
        const full_name = try std.fmt.allocPrint(self.allocator, "ziggit-drop-in-test-{s}-{d}", .{ name, self.temp_dir_counter });
        
        // Clean up any existing directory
        std.fs.cwd().deleteTree(full_name) catch {};
        try std.fs.cwd().makeDir(full_name);
        
        return full_name;
    }

    fn writeFile(self: *TestFramework, dir: []const u8, filename: []const u8, content: []const u8) !void {
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, filename });
        defer self.allocator.free(full_path);
        
        const file = try std.fs.cwd().createFile(full_path, .{});
        defer file.close();
        try file.writeAll(content);
    }

    fn changeDir(_: *TestFramework, dir: []const u8) !void {
        try std.posix.chdir(dir);
    }

    fn cleanup(_: *TestFramework, dir: []const u8) void {
        std.fs.cwd().deleteTree(dir) catch {};
    }
};

// Test 1: Basic init compatibility - should create same .git structure as git
fn testBasicInit(tf: *TestFramework) !void {
    const test_dir = try tf.createTempDir("init");
    defer tf.cleanup(test_dir);

    try tf.changeDir(test_dir);
    defer std.posix.chdir("..") catch {};

    // Test ziggit init (path relative to project root)
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" });
    
    if (ziggit_result.term.Exited != 0) {
        std.debug.print("ziggit init failed: {s}\n", .{ziggit_result.stderr});
        return error.ZiggitInitFailed;
    }

    // Verify .git directory structure matches what git creates
    var git_dir = std.fs.cwd().openDir(".git", .{}) catch |err| {
        std.debug.print("Failed to open .git directory: {}\n", .{err});
        return error.GitDirNotFound;
    };
    defer git_dir.close();

    // Check essential .git subdirectories
    const essential_dirs = [_][]const u8{ "objects", "refs", "refs/heads", "refs/tags" };
    for (essential_dirs) |dir_name| {
        git_dir.access(dir_name, .{}) catch |err| {
            std.debug.print("Missing essential .git subdirectory: {s} - {}\n", .{ dir_name, err });
            return error.MissingGitDir;
        };
    }

    // Check essential .git files
    const essential_files = [_][]const u8{ "HEAD", "config" };
    for (essential_files) |file_name| {
        git_dir.access(file_name, .{}) catch |err| {
            std.debug.print("Missing essential .git file: {s} - {}\n", .{ file_name, err });
            return error.MissingGitFile;
        };
    }

    std.debug.print("    ✓ Basic init test passed\n", .{});
}

// Test 2: Basic add compatibility - should stage files like git
fn testBasicAdd(tf: *TestFramework) !void {
    const test_dir = try tf.createTempDir("add");
    defer tf.cleanup(test_dir);

    try tf.changeDir(test_dir);
    defer std.posix.chdir("..") catch {};

    // Initialize repository
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" });

    // Create a test file
    try tf.writeFile(".", "test.txt", "Hello, World!\n");

    // Test ziggit add
    const add_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "add", "test.txt" });
    
    if (add_result.term.Exited != 0) {
        std.debug.print("ziggit add failed: {s}\n", .{add_result.stderr});
        return error.ZiggitAddFailed;
    }

    // Check that index file was created (git creates .git/index when files are staged)
    std.fs.cwd().access(".git/index", .{}) catch |err| {
        std.debug.print("No .git/index file created after add: {}\n", .{err});
        return error.NoIndexFile;
    };

    std.debug.print("    ✓ Basic add test passed\n", .{});
}

// Test 3: Basic commit compatibility - should create commits like git
fn testBasicCommit(tf: *TestFramework) !void {
    const test_dir = try tf.createTempDir("commit");
    defer tf.cleanup(test_dir);

    try tf.changeDir(test_dir);
    defer std.posix.chdir("..") catch {};

    // Initialize and add a file
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" });
    try tf.writeFile(".", "test.txt", "Hello, World!\n");
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "add", "test.txt" });

    // Test ziggit commit
    const commit_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "commit", "-m", "Initial commit" });
    
    if (commit_result.term.Exited != 0) {
        std.debug.print("ziggit commit failed: {s}\n", .{commit_result.stderr});
        return error.ZiggitCommitFailed;
    }

    // Verify commit was created - check refs/heads/master (or main)
    const has_master = blk: {
        std.fs.cwd().access(".git/refs/heads/master", .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    const has_main = blk: {
        std.fs.cwd().access(".git/refs/heads/main", .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!has_master and !has_main) {
        std.debug.print("No master or main branch ref created after commit\n", .{});
        return error.NoBranchRef;
    }

    std.debug.print("    ✓ Basic commit test passed\n", .{});
}

// Test 4: Basic status compatibility - should show repository state like git
fn testBasicStatus(tf: *TestFramework) !void {
    const test_dir = try tf.createTempDir("status");
    defer tf.cleanup(test_dir);

    try tf.changeDir(test_dir);
    defer std.posix.chdir("..") catch {};

    // Initialize repository
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" });

    // Test status in empty repository
    const empty_status_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "status" });
    
    if (empty_status_result.term.Exited != 0) {
        std.debug.print("ziggit status failed on empty repo: {s}\n", .{empty_status_result.stderr});
        return error.ZiggitStatusFailed;
    }

    // Create and test untracked file
    try tf.writeFile(".", "untracked.txt", "Untracked content\n");
    
    const untracked_status_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "status" });
    
    if (untracked_status_result.term.Exited != 0) {
        std.debug.print("ziggit status failed with untracked file: {s}\n", .{untracked_status_result.stderr});
        return error.ZiggitStatusFailed;
    }

    // The output should mention the untracked file
    if (std.mem.indexOf(u8, untracked_status_result.stdout, "untracked.txt") == null) {
        std.debug.print("Status output should mention untracked file\n", .{});
        return error.StatusOutputIncorrect;
    }

    std.debug.print("    ✓ Basic status test passed\n", .{});
}

// Test 5: Basic log compatibility - should show commit history like git  
fn testBasicLog(tf: *TestFramework) !void {
    const test_dir = try tf.createTempDir("log");
    defer tf.cleanup(test_dir);

    try tf.changeDir(test_dir);
    defer std.posix.chdir("..") catch {};

    // Setup repository with a commit
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" });
    try tf.writeFile(".", "test.txt", "Hello, World!\n");
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "add", "test.txt" });
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "commit", "-m", "Initial commit" });

    // Test ziggit log
    const log_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "log" });
    
    if (log_result.term.Exited != 0) {
        std.debug.print("ziggit log failed: {s}\n", .{log_result.stderr});
        return error.ZiggitLogFailed;
    }

    // The log output should contain commit information
    if (std.mem.indexOf(u8, log_result.stdout, "Initial commit") == null) {
        std.debug.print("Log output should contain commit message\n", .{});
        return error.LogOutputIncorrect;
    }

    std.debug.print("    ✓ Basic log test passed\n", .{});
}

// Test 6: Command-line argument compatibility
fn testCommandLineArgs(tf: *TestFramework) !void {
    const test_dir = try tf.createTempDir("args");
    defer tf.cleanup(test_dir);

    try tf.changeDir(test_dir);
    defer std.posix.chdir("..") catch {};

    // Test version command (should work like git --version)
    const version_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "--version" });
    
    if (version_result.term.Exited != 0) {
        std.debug.print("ziggit --version failed: {s}\n", .{version_result.stderr});
        return error.ZiggitVersionFailed;
    }

    // Test help command (should work like git --help)
    const help_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "--help" });
    
    if (help_result.term.Exited != 0) {
        std.debug.print("ziggit --help failed: {s}\n", .{help_result.stderr});
        return error.ZiggitHelpFailed;
    }

    // Test init with options (should work like git init --bare)
    const bare_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init", "--bare" });
    
    if (bare_result.term.Exited != 0) {
        std.debug.print("ziggit init --bare failed: {s}\n", .{bare_result.stderr});
        return error.ZiggitBareInitFailed;
    }

    std.debug.print("    ✓ Command-line args test passed\n", .{});
}

// Test 7: Output format compatibility - should match git output format
fn testOutputFormat(tf: *TestFramework) !void {
    const test_dir = try tf.createTempDir("output");
    defer tf.cleanup(test_dir);

    try tf.changeDir(test_dir);
    defer std.posix.chdir("..") catch {};

    // Initialize and make a commit
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" });
    try tf.writeFile(".", "format.txt", "Format test content\n");
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "add", "format.txt" });
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "commit", "-m", "Format test commit" });

    // Test log --oneline (should match git log --oneline format)
    const oneline_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "log", "--oneline" });
    
    if (oneline_result.term.Exited != 0) {
        std.debug.print("ziggit log --oneline failed: {s}\n", .{oneline_result.stderr});
        return error.ZiggitOnelineFailed;
    }

    // Check that oneline format contains commit hash and message on same line
    var lines = std.mem.split(u8, std.mem.trim(u8, oneline_result.stdout, " \n\r\t"), "\n");
    var line_count: u32 = 0;
    var found_commit = false;
    
    while (lines.next()) |line| {
        line_count += 1;
        if (std.mem.indexOf(u8, line, "Format test commit") != null) {
            found_commit = true;
            // Should have hash prefix (7+ chars) followed by space and message
            if (line.len < 10) { // minimum: 7-char hash + space + some message
                std.debug.print("Oneline format too short: '{s}'\n", .{line});
                return error.OnelineFormatIncorrect;
            }
        }
    }

    if (!found_commit) {
        std.debug.print("Commit message not found in oneline output\n", .{});
        return error.CommitNotFoundInOneline;
    }

    std.debug.print("    ✓ Output format test passed\n", .{});
}

// Test 8: Error handling compatibility - should handle errors like git
fn testErrorHandling(tf: *TestFramework) !void {
    const test_dir = try tf.createTempDir("error");
    defer tf.cleanup(test_dir);

    try tf.changeDir(test_dir);
    defer std.posix.chdir("..") catch {};

    // Test command outside git repository (should fail like git)
    const outside_repo_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "status" });
    
    if (outside_repo_result.term.Exited == 0) {
        std.debug.print("ziggit status should fail outside repository\n", .{});
        return error.ShouldFailOutsideRepo;
    }

    // Initialize repo for other tests
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" });

    // Test adding non-existent file (should fail like git add)
    const nonexistent_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "add", "nonexistent.txt" });
    
    if (nonexistent_result.term.Exited == 0) {
        std.debug.print("ziggit add should fail on non-existent file\n", .{});
        return error.ShouldFailOnNonExistent;
    }

    // Test commit with nothing staged (should fail like git commit)
    const empty_commit_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "commit", "-m", "Empty commit" });
    
    if (empty_commit_result.term.Exited == 0) {
        std.debug.print("ziggit commit should fail with nothing staged\n", .{});
        return error.ShouldFailOnEmptyCommit;
    }

    std.debug.print("    ✓ Error handling test passed\n", .{});
}

pub fn runDropInCompatibilityTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tf = TestFramework.init(allocator);

    std.debug.print("Running ziggit drop-in compatibility test suite...\n", .{});
    
    std.debug.print("  Testing basic git init compatibility...\n", .{});
    try testBasicInit(&tf);
    
    std.debug.print("  Testing basic git add compatibility...\n", .{});  
    try testBasicAdd(&tf);
    
    std.debug.print("  Testing basic git commit compatibility...\n", .{});
    try testBasicCommit(&tf);
    
    std.debug.print("  Testing basic git status compatibility...\n", .{});
    try testBasicStatus(&tf);
    
    std.debug.print("  Testing basic git log compatibility...\n", .{});
    try testBasicLog(&tf);
    
    std.debug.print("  Testing command-line argument compatibility...\n", .{});
    try testCommandLineArgs(&tf);
    
    std.debug.print("  Testing output format compatibility...\n", .{});
    try testOutputFormat(&tf);
    
    std.debug.print("  Testing error handling compatibility...\n", .{});
    try testErrorHandling(&tf);
    
    std.debug.print("✓ All drop-in compatibility tests passed!\n", .{});
}

pub fn main() !void {
    try runDropInCompatibilityTests();
}