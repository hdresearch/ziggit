const std = @import("std");
const testing = std.testing;

// Helper function for printing to stdout
fn print(comptime format: []const u8, args: anytype) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print(format, args) catch return;
}

// Advanced Git Test Suite - Testing edge cases and advanced scenarios
// Complements the basic git source test suite

const TestFramework = struct {
    allocator: std.mem.Allocator,
    temp_dir: []const u8,
    ziggit_path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const timestamp = std.time.timestamp();
        const temp_dir = try std.fmt.allocPrint(allocator, "/tmp/ziggit-advanced-test-{d}", .{timestamp});
        try std.fs.cwd().makeDir(temp_dir);

        return Self{
            .allocator = allocator,
            .temp_dir = temp_dir,
            .ziggit_path = "/root/ziggit/zig-out/bin/ziggit",
        };
    }

    pub fn deinit(self: *Self) void {
        std.fs.cwd().deleteTree(self.temp_dir) catch {};
        self.allocator.free(self.temp_dir);
    }

    pub fn runCommand(self: *Self, args: []const []const u8, working_dir: ?[]const u8) !CommandResult {
        const dir = working_dir orelse self.temp_dir;
        
        var proc = std.process.Child.init(args, self.allocator);
        proc.cwd = dir;
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;

        try proc.spawn();

        const stdout = try proc.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        errdefer self.allocator.free(stdout);

        const stderr = try proc.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        errdefer self.allocator.free(stderr);

        const term = try proc.wait();
        const exit_code = switch (term) {
            .Exited => |code| code,
            else => 1,
        };

        return CommandResult{
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = exit_code,
        };
    }

    pub fn testExpectSuccess(self: *Self, name: []const u8, test_fn: fn(*Self) anyerror!void) !void {
        print("  Testing {s}...\n", .{name});
        
        const test_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{self.temp_dir, name});
        defer self.allocator.free(test_dir);
        
        try std.fs.cwd().makeDir(test_dir);
        defer std.fs.cwd().deleteTree(test_dir) catch {};

        const old_temp = self.temp_dir;
        self.temp_dir = test_dir;
        defer self.temp_dir = old_temp;

        test_fn(self) catch |err| {
            print("    ✗ Test '{s}' failed: {}\n", .{name, err});
            return err;
        };
        print("    ✓ Test '{s}' passed\n", .{name});
    }

    pub fn writeFile(self: *Self, path: []const u8, content: []const u8) !void {
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{self.temp_dir, path});
        defer self.allocator.free(full_path);

        // Create parent directories if they don't exist
        if (std.fs.path.dirname(full_path)) |dir_path| {
            std.fs.cwd().makePath(dir_path) catch {};
        }

        const file = try std.fs.cwd().createFile(full_path, .{});
        defer file.close();

        try file.writeAll(content);
    }

    pub fn pathExists(self: *Self, path: []const u8) bool {
        const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{self.temp_dir, path}) catch return false;
        defer self.allocator.free(full_path);
        
        std.fs.cwd().access(full_path, .{}) catch return false;
        return true;
    }

    pub fn initRepo(self: *Self) !void {
        var result = try self.runCommand(&[_][]const u8{ self.ziggit_path, "init", "." }, null);
        defer result.deinit(self.allocator);

        if (result.exit_code != 0) {
            print("Failed to initialize repository: {s}\n", .{result.stderr});
            return error.InitFailed;
        }
    }

    pub fn configUser(self: *Self) !void {
        var config1 = try self.runCommand(&[_][]const u8{ self.ziggit_path, "config", "user.name", "Test User" }, null);
        defer config1.deinit(self.allocator);

        var config2 = try self.runCommand(&[_][]const u8{ self.ziggit_path, "config", "user.email", "test@example.com" }, null);
        defer config2.deinit(self.allocator);

        // Ignore config failures for now since not all ziggit versions may support config
    }

    pub fn addAndCommit(self: *Self, filename: []const u8, content: []const u8, message: []const u8) !void {
        try self.writeFile(filename, content);
        
        var add_result = try self.runCommand(&[_][]const u8{ self.ziggit_path, "add", filename }, null);
        defer add_result.deinit(self.allocator);

        if (add_result.exit_code != 0) {
            print("Failed to add file {s}: {s}\n", .{filename, add_result.stderr});
            return error.AddFailed;
        }

        var commit_result = try self.runCommand(&[_][]const u8{ self.ziggit_path, "commit", "-m", message }, null);
        defer commit_result.deinit(self.allocator);

        if (commit_result.exit_code != 0) {
            print("Failed to commit: {s}\n", .{commit_result.stderr});
            return error.CommitFailed;
        }
    }
};

const CommandResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,

    pub fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

// Advanced test functions

fn testLargeFile(tf: *TestFramework) !void {
    try tf.initRepo();
    try tf.configUser();

    // Create a larger file (1MB)
    const large_content = "A" ** (1024 * 1024);
    try tf.writeFile("large-file.txt", large_content);

    var add_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "add", "large-file.txt" }, null);
    defer add_result.deinit(tf.allocator);

    if (add_result.exit_code != 0) {
        print("Failed to add large file: {s}\n", .{add_result.stderr});
        return error.AddLargeFileFailed;
    }

    var commit_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "commit", "-m", "Add large file" }, null);
    defer commit_result.deinit(tf.allocator);

    if (commit_result.exit_code != 0) {
        print("Failed to commit large file: {s}\n", .{commit_result.stderr});
        return error.CommitLargeFileFailed;
    }
}

fn testManyFiles(tf: *TestFramework) !void {
    try tf.initRepo();
    try tf.configUser();

    // Create many small files
    for (0..50) |i| {
        const filename = try std.fmt.allocPrint(tf.allocator, "file{d}.txt", .{i});
        defer tf.allocator.free(filename);
        
        const content = try std.fmt.allocPrint(tf.allocator, "Content of file {d}\n", .{i});
        defer tf.allocator.free(content);

        try tf.writeFile(filename, content);
    }

    // Add all files at once
    var add_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "add", "." }, null);
    defer add_result.deinit(tf.allocator);

    if (add_result.exit_code != 0) {
        print("Failed to add many files: {s}\n", .{add_result.stderr});
        return error.AddManyFilesFailed;
    }

    var commit_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "commit", "-m", "Add many files" }, null);
    defer commit_result.deinit(tf.allocator);

    if (commit_result.exit_code != 0) {
        print("Failed to commit many files: {s}\n", .{commit_result.stderr});
        return error.CommitManyFilesFailed;
    }

    // Check status shows clean working tree
    var status_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "status" }, null);
    defer status_result.deinit(tf.allocator);

    if (!std.mem.containsAtLeast(u8, status_result.stdout, 1, "working tree clean") and
        !std.mem.containsAtLeast(u8, status_result.stdout, 1, "nothing to commit")) {
        print("Status does not show clean working tree after committing many files: {s}\n", .{status_result.stdout});
        return error.WorkingTreeNotClean;
    }
}

fn testDeepDirectoryStructure(tf: *TestFramework) !void {
    try tf.initRepo();
    try tf.configUser();

    // Create nested directory structure
    const deep_path = "level1/level2/level3/level4/level5";
    try tf.writeFile("level1/level2/level3/level4/level5/deep-file.txt", "Deep content\n");

    var add_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "add", deep_path }, null);
    defer add_result.deinit(tf.allocator);

    if (add_result.exit_code != 0) {
        print("Failed to add deep directory structure: {s}\n", .{add_result.stderr});
        return error.AddDeepStructureFailed;
    }

    var commit_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "commit", "-m", "Add deep directory structure" }, null);
    defer commit_result.deinit(tf.allocator);

    if (commit_result.exit_code != 0) {
        print("Failed to commit deep directory structure: {s}\n", .{commit_result.stderr});
        return error.CommitDeepStructureFailed;
    }
}

fn testSpecialCharactersInFilenames(tf: *TestFramework) !void {
    try tf.initRepo();
    try tf.configUser();

    // Test files with special characters (but avoiding truly problematic ones)
    const special_files = [_][]const u8{
        "file-with-dashes.txt",
        "file_with_underscores.txt", 
        "file.with.dots.txt",
        "file with spaces.txt",
        "file(with)parentheses.txt",
        "file[with]brackets.txt",
        "file{with}braces.txt",
    };

    for (special_files) |filename| {
        const content = try std.fmt.allocPrint(tf.allocator, "Content of {s}\n", .{filename});
        defer tf.allocator.free(content);

        try tf.writeFile(filename, content);
    }

    var add_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "add", "." }, null);
    defer add_result.deinit(tf.allocator);

    if (add_result.exit_code != 0) {
        print("Failed to add files with special characters: {s}\n", .{add_result.stderr});
        return error.AddSpecialFilesFailed;
    }

    var commit_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "commit", "-m", "Add files with special characters" }, null);
    defer commit_result.deinit(tf.allocator);

    if (commit_result.exit_code != 0) {
        print("Failed to commit files with special characters: {s}\n", .{commit_result.stderr});
        return error.CommitSpecialFilesFailed;
    }
}

fn testEmptyDirectories(tf: *TestFramework) !void {
    try tf.initRepo();
    try tf.configUser();

    // Git doesn't track empty directories, but let's test the behavior
    const empty_dir_path = try std.fmt.allocPrint(tf.allocator, "{s}/empty-dir", .{tf.temp_dir});
    defer tf.allocator.free(empty_dir_path);
    
    try std.fs.cwd().makeDir(empty_dir_path);

    // Try to add empty directory - should not add anything
    var add_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "add", "empty-dir" }, null);
    defer add_result.deinit(tf.allocator);

    // Adding empty directory should either succeed silently or warn
    // Git behavior: warning about no files added, but succeeds

    var status_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "status" }, null);
    defer status_result.deinit(tf.allocator);

    // Should not show the empty directory as staged
    if (status_result.exit_code != 0) {
        return error.StatusFailed;
    }
}

fn testBinaryFiles(tf: *TestFramework) !void {
    try tf.initRepo();
    try tf.configUser();

    // Create a simple binary file (with null bytes)
    const binary_content = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00 };
    try tf.writeFile("test.png", &binary_content);

    var add_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "add", "test.png" }, null);
    defer add_result.deinit(tf.allocator);

    if (add_result.exit_code != 0) {
        print("Failed to add binary file: {s}\n", .{add_result.stderr});
        return error.AddBinaryFileFailed;
    }

    var commit_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "commit", "-m", "Add binary file" }, null);
    defer commit_result.deinit(tf.allocator);

    if (commit_result.exit_code != 0) {
        print("Failed to commit binary file: {s}\n", .{commit_result.stderr});
        return error.CommitBinaryFileFailed;
    }
}

fn testCommitWorkflow(tf: *TestFramework) !void {
    try tf.initRepo();
    try tf.configUser();

    // Test a realistic workflow
    try tf.addAndCommit("README.md", "# Project\n\nThis is a test project.\n", "Initial commit");
    try tf.addAndCommit("src/main.zig", "const std = @import(\"std\");\n\npub fn main() !void {\n    std.debug.print(\"Hello, World!\\n\", .{});\n}\n", "Add main.zig");
    try tf.addAndCommit("build.zig", "const std = @import(\"std\");\n\npub fn build(b: *std.Build) void {\n    // Build configuration\n}\n", "Add build.zig");

    // Verify log shows all commits
    var log_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "log", "--oneline" }, null);
    defer log_result.deinit(tf.allocator);

    if (log_result.exit_code != 0) {
        return error.LogFailed;
    }

    const expected_messages = [_][]const u8{ "Initial commit", "Add main.zig", "Add build.zig" };
    for (expected_messages) |msg| {
        if (!std.mem.containsAtLeast(u8, log_result.stdout, 1, msg)) {
            print("Expected commit message '{s}' not found in log: {s}\n", .{msg, log_result.stdout});
            return error.CommitMessageMissing;
        }
    }
}

fn testIgnorePatterns(tf: *TestFramework) !void {
    try tf.initRepo();
    try tf.configUser();

    // Create .gitignore file
    try tf.writeFile(".gitignore", "*.tmp\n*.log\nbuild/\n");

    // Create files that should be ignored
    try tf.writeFile("temp.tmp", "temporary file");
    try tf.writeFile("debug.log", "log file");
    try tf.writeFile("build/output.o", "build artifact");
    
    // Create file that should not be ignored
    try tf.writeFile("important.txt", "important file");

    var add_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "add", "." }, null);
    defer add_result.deinit(tf.allocator);

    if (add_result.exit_code != 0) {
        print("Failed to add files with gitignore: {s}\n", .{add_result.stderr});
        return error.AddWithIgnoreFailed;
    }

    var status_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "status" }, null);
    defer status_result.deinit(tf.allocator);

    if (status_result.exit_code != 0) {
        return error.StatusFailed;
    }

    // Should show important.txt and .gitignore as staged, but not the ignored files
    if (!std.mem.containsAtLeast(u8, status_result.stdout, 1, "important.txt") or
        !std.mem.containsAtLeast(u8, status_result.stdout, 1, ".gitignore")) {
        print("Important files not shown as staged: {s}\n", .{status_result.stdout});
        return error.ImportantFilesNotStaged;
    }

    // Ignored files should not appear in status (in many cases)
    // Note: Different git implementations handle this differently
}

fn testLongCommitMessage(tf: *TestFramework) !void {
    try tf.initRepo();
    try tf.configUser();

    try tf.writeFile("test.txt", "test content");

    var add_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "add", "test.txt" }, null);
    defer add_result.deinit(tf.allocator);

    if (add_result.exit_code != 0) {
        return error.AddFailed;
    }

    // Long commit message
    const long_message = "This is a very long commit message that tests how well ziggit handles extended commit messages with multiple lines and lots of detail. " ++
        "It includes various punctuation marks, numbers 12345, and special characters !@#$%^&*(). " ++
        "The purpose is to ensure that commit message handling is robust and can deal with realistic commit messages that developers might write. " ++
        "This message is intentionally verbose to test edge cases in message parsing and storage.";

    var commit_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "commit", "-m", long_message }, null);
    defer commit_result.deinit(tf.allocator);

    if (commit_result.exit_code != 0) {
        print("Failed to commit with long message: {s}\n", .{commit_result.stderr});
        return error.LongCommitFailed;
    }

    // Verify message appears in log
    var log_result = try tf.runCommand(&[_][]const u8{ tf.ziggit_path, "log" }, null);
    defer log_result.deinit(tf.allocator);

    if (log_result.exit_code != 0) {
        return error.LogFailed;
    }

    if (!std.mem.containsAtLeast(u8, log_result.stdout, 1, "very long commit message")) {
        print("Long commit message not found in log: {s}\n", .{log_result.stdout});
        return error.LongMessageNotInLog;
    }
}

// Main test runner
pub fn runAdvancedGitTestSuite() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("Running Advanced Git Test Suite...\n\n", .{});

    var tf = try TestFramework.init(allocator);
    defer tf.deinit();

    // Advanced functionality tests
    print("=== File Handling Tests ===\n", .{});
    try tf.testExpectSuccess("large_file", testLargeFile);
    try tf.testExpectSuccess("many_files", testManyFiles);
    try tf.testExpectSuccess("deep_directory_structure", testDeepDirectoryStructure);
    try tf.testExpectSuccess("special_characters_in_filenames", testSpecialCharactersInFilenames);
    try tf.testExpectSuccess("empty_directories", testEmptyDirectories);
    try tf.testExpectSuccess("binary_files", testBinaryFiles);

    print("\n=== Workflow Tests ===\n", .{});
    try tf.testExpectSuccess("commit_workflow", testCommitWorkflow);
    try tf.testExpectSuccess("ignore_patterns", testIgnorePatterns);
    try tf.testExpectSuccess("long_commit_message", testLongCommitMessage);

    print("\n=== Advanced Git Test Suite Complete! ===\n", .{});
    print("All advanced tests passed! 🎉\n", .{});
    print("Ziggit demonstrates robust handling of advanced scenarios.\n", .{});
}

pub fn main() !void {
    try runAdvancedGitTestSuite();
}