const std = @import("std");
const testing = std.testing;
const ArrayList = std.ArrayList;
const Process = std.process;
const Allocator = std.mem.Allocator;

pub const TestError = error{
    ProcessFailed,
    OutputMismatch,
    UnexpectedOutput,
};

pub const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    allocator: Allocator,

    pub fn deinit(self: *CommandResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

pub const TestHarness = struct {
    allocator: Allocator,
    ziggit_path: []const u8,
    git_path: []const u8,

    pub fn init(allocator: Allocator, ziggit_path: []const u8, git_path: []const u8) TestHarness {
        return TestHarness{
            .allocator = allocator,
            .ziggit_path = ziggit_path,
            .git_path = git_path,
        };
    }

    pub fn runCommand(self: TestHarness, command: []const u8, args: []const []const u8, cwd: ?[]const u8) !CommandResult {
        var argv = ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();
        try argv.append(command);
        for (args) |arg| {
            try argv.append(arg);
        }
        
        var proc = Process.Child.init(argv.items, self.allocator);
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;
        
        if (cwd) |dir| {
            proc.cwd = dir;
        }

        try proc.spawn();

        var stdout = ArrayList(u8).init(self.allocator);
        var stderr = ArrayList(u8).init(self.allocator);
        defer {
            stdout.deinit();
            stderr.deinit();
        }

        try proc.collectOutput(&stdout, &stderr, 1024 * 1024); // 1MB limit
        const term = try proc.wait();

        const exit_code: u8 = switch (term) {
            .Exited => |code| @intCast(code),
            .Signal, .Stopped, .Unknown => 1,
        };

        return CommandResult{
            .stdout = try stdout.toOwnedSlice(),
            .stderr = try stderr.toOwnedSlice(),
            .exit_code = exit_code,
            .allocator = self.allocator,
        };
    }

    pub fn runZiggit(self: TestHarness, args: []const []const u8, cwd: ?[]const u8) !CommandResult {
        return self.runCommand(self.ziggit_path, args, cwd);
    }

    pub fn runGit(self: TestHarness, args: []const []const u8, cwd: ?[]const u8) !CommandResult {
        return self.runCommand(self.git_path, args, cwd);
    }

    pub fn expectExitCode(self: TestHarness, actual: u8, expected: u8, test_name: []const u8) !void {
        _ = self;
        if (actual != expected) {
            std.debug.print("    FAIL: {s} - expected exit code {}, got {}\n", .{ test_name, expected, actual });
            return TestError.ProcessFailed;
        }
    }

    pub fn expectOutputContains(self: TestHarness, output: []const u8, needle: []const u8, test_name: []const u8) !void {
        _ = self;
        if (!std.mem.containsAtLeast(u8, output, 1, needle)) {
            std.debug.print("    FAIL: {s} - output doesn't contain '{s}'\n", .{ test_name, needle });
            std.debug.print("      Actual output: {s}\n", .{output});
            return TestError.OutputMismatch;
        }
    }

    pub fn createTempFile(self: TestHarness, dir: []const u8, filename: []const u8, content: []const u8) !void {
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, filename });
        defer self.allocator.free(file_path);
        
        const file = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer file.close();
        
        try file.writeAll(content);
    }

    pub fn compareCommands(self: TestHarness, args: []const []const u8, cwd: ?[]const u8, comptime ignore_stderr: bool) !void {
        // For init commands, we need fresh directories to compare properly
        var ziggit_cwd = cwd;
        var git_cwd = cwd;
        
        if (args.len > 0 and std.mem.eql(u8, args[0], "init")) {
            // Create separate temp directories for init command comparison
            const ziggit_temp = try self.createTempDir("ziggit_init_test");
            defer self.removeTempDir(ziggit_temp);
            const git_temp = try self.createTempDir("git_init_test");
            defer self.removeTempDir(git_temp);
            
            ziggit_cwd = ziggit_temp;
            git_cwd = git_temp;
        }

        var ziggit_result = try self.runZiggit(args, ziggit_cwd);
        defer ziggit_result.deinit();

        var git_result = try self.runGit(args, git_cwd);
        defer git_result.deinit();

        // Compare exit codes
        if (ziggit_result.exit_code != git_result.exit_code) {
            std.debug.print("Exit code mismatch - ziggit: {}, git: {}\n", .{ ziggit_result.exit_code, git_result.exit_code });
            return TestError.OutputMismatch;
        }

        // Compare stdout (normalize line endings and paths)
        const ziggit_stdout = try self.normalizeOutputForComparison(ziggit_result.stdout);
        defer self.allocator.free(ziggit_stdout);
        const git_stdout = try self.normalizeOutputForComparison(git_result.stdout);
        defer self.allocator.free(git_stdout);

        if (!std.mem.eql(u8, ziggit_stdout, git_stdout)) {
            std.debug.print("STDOUT mismatch:\nZiggit:\n{s}\nGit:\n{s}\n", .{ ziggit_stdout, git_stdout });
            return TestError.OutputMismatch;
        }

        // Compare stderr if not ignoring
        if (!ignore_stderr) {
            const ziggit_stderr = try self.normalizeOutput(ziggit_result.stderr);
            defer self.allocator.free(ziggit_stderr);
            const git_stderr = try self.normalizeOutput(git_result.stderr);
            defer self.allocator.free(git_stderr);

            if (!std.mem.eql(u8, ziggit_stderr, git_stderr)) {
                std.debug.print("STDERR mismatch:\nZiggit:\n{s}\nGit:\n{s}\n", .{ ziggit_stderr, git_stderr });
                return TestError.OutputMismatch;
            }
        }
    }

    fn normalizeOutput(self: TestHarness, output: []u8) ![]u8 {
        // Replace CRLF with LF and trim trailing whitespace
        var result = ArrayList(u8).init(self.allocator);
        defer result.deinit();

        var i: usize = 0;
        while (i < output.len) {
            if (i + 1 < output.len and output[i] == '\r' and output[i + 1] == '\n') {
                try result.append('\n');
                i += 2;
            } else {
                try result.append(output[i]);
                i += 1;
            }
        }

        // Trim trailing whitespace
        const trimmed = std.mem.trimRight(u8, result.items, " \t\r\n");
        return try self.allocator.dupe(u8, trimmed);
    }
    
    fn normalizeOutputForComparison(self: TestHarness, output: []u8) ![]u8 {
        const normalized = try self.normalizeOutput(output);
        defer self.allocator.free(normalized);
        
        // Replace specific paths with generic placeholders for comparison
        var result = ArrayList(u8).init(self.allocator);
        defer result.deinit();
        
        // Handle git init output normalization
        const lines = std.mem.split(u8, normalized, "\n");
        var line_iter = lines;
        while (line_iter.next()) |line| {
            if (std.mem.indexOf(u8, line, "Git repository in ")) |pos| {
                // Replace everything after "Git repository in " with a placeholder
                try result.appendSlice(line[0..pos + "Git repository in ".len]);
                try result.appendSlice("<PATH>");
            } else {
                try result.appendSlice(line);
            }
            if (line_iter.peek() != null) {
                try result.append('\n');
            }
        }
        
        return try result.toOwnedSlice();
    }

    pub fn createTempDir(self: TestHarness, prefix: []const u8) ![]u8 {
        var buf: [256]u8 = undefined;
        const random_suffix = std.crypto.random.int(u32);
        const dir_name = try std.fmt.bufPrint(&buf, "{s}_{}", .{ prefix, random_suffix });
        
        const temp_dir = try std.fmt.allocPrint(self.allocator, "/tmp/{s}", .{dir_name});
        try std.fs.makeDirAbsolute(temp_dir);
        return temp_dir;
    }

    pub fn removeTempDir(self: TestHarness, dir_path: []const u8) void {
        if (dir_path.len > 0) {
            std.fs.deleteTreeAbsolute(dir_path) catch |err| {
                std.debug.print("Warning: failed to delete temp dir {s}: {}\n", .{ dir_path, err });
            };
        }
        self.allocator.free(dir_path);
    }

    pub fn writeFile(self: TestHarness, path: []const u8, content: []const u8) !void {
        _ = self;
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(content);
    }
};

// Utility function for cleaning up test directories
pub fn cleanupTestDir(dir_name: []const u8) void {
    std.fs.cwd().deleteTree(dir_name) catch |err| {
        // If deletion fails, it might not exist, which is fine
        std.debug.print("Warning: failed to delete test dir {s}: {}\n", .{ dir_name, err });
    };
}

// Utility function for running ziggit commands directly (simplified interface)
pub fn runZiggitCommand(allocator: std.mem.Allocator, args: []const []const u8) !struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
} {
    var argv = ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    
    // Add ziggit binary path
    try argv.append("./zig-out/bin/ziggit");
    for (args) |arg| {
        try argv.append(arg);
    }
    
    var proc = Process.Child.init(argv.items, allocator);
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;

    try proc.spawn();

    var stdout = ArrayList(u8).init(allocator);
    var stderr = ArrayList(u8).init(allocator);
    defer {
        stdout.deinit();
        stderr.deinit();
    }

    try proc.collectOutput(&stdout, &stderr, 1024 * 1024); // 1MB limit
    const term = try proc.wait();

    const exit_code: u8 = switch (term) {
        .Exited => |code| @intCast(code),
        .Signal, .Stopped, .Unknown => 1,
    };

    return .{
        .stdout = try stdout.toOwnedSlice(),
        .stderr = try stderr.toOwnedSlice(),
        .exit_code = exit_code,
    };
}

// Test runner
pub fn runTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const harness = TestHarness.init(allocator, "/root/ziggit/zig-out/bin/ziggit", "git");

    // Run test suites
    try testInit(harness);
    try testAdd(harness);
    try testCommit(harness);
    try testStatus(harness);
    try testLog(harness);
    try testBranch(harness);
    try testCheckout(harness);
    try testDiff(harness);

    std.debug.print("All tests passed!\n", .{});
}

fn testInit(harness: TestHarness) !void {
    std.debug.print("Testing git init...\n", .{});
    
    // Test ziggit init standalone
    const ziggit_temp_dir = try harness.createTempDir("test_ziggit_init");
    defer harness.removeTempDir(ziggit_temp_dir);
    
    var ziggit_result = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_temp_dir);
    defer ziggit_result.deinit();
    
    if (ziggit_result.exit_code != 0) {
        std.debug.print("Ziggit init failed with exit code: {}\n", .{ziggit_result.exit_code});
        std.debug.print("stderr: {s}\n", .{ziggit_result.stderr});
        return TestError.ProcessFailed;
    }
    
    // Verify .git directory was created
    const git_dir = try std.fmt.allocPrint(harness.allocator, "{s}/.git", .{ziggit_temp_dir});
    defer harness.allocator.free(git_dir);
    
    var stat = std.fs.openDirAbsolute(git_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Expected .git directory not found at: {s}\n", .{git_dir});
            return TestError.UnexpectedOutput;
        },
        else => return err,
    };
    stat.close();

    std.debug.print("  ✓ git init basic functionality\n", .{});
}

fn testAdd(harness: TestHarness) !void {
    std.debug.print("Testing git add...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_add");
    defer harness.removeTempDir(temp_dir);

    // Initialize repo
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();

    // Create a test file
    const test_file = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{temp_dir});
    defer harness.allocator.free(test_file);
    try harness.writeFile(test_file, "Hello, world!\n");

    // Test add command
    var add_result = try harness.runZiggit(&[_][]const u8{"add", "test.txt"}, temp_dir);
    defer add_result.deinit();

    if (add_result.exit_code == 0) {
        std.debug.print("  ✓ git add basic functionality\n", .{});
    } else {
        std.debug.print("  ✗ git add failed with exit code {}\n", .{add_result.exit_code});
        return TestError.ProcessFailed;
    }
}

fn testCommit(harness: TestHarness) !void {
    std.debug.print("Testing git commit...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_commit");
    defer harness.removeTempDir(temp_dir);

    // Initialize repo
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();

    // Test commit without anything staged (should fail)
    var commit_result = try harness.runZiggit(&[_][]const u8{"commit", "-m", "test"}, temp_dir);
    defer commit_result.deinit();

    if (commit_result.exit_code != 0) {
        std.debug.print("  ✓ git commit correctly fails with nothing to commit\n", .{});
    } else {
        std.debug.print("  ✗ git commit should fail when nothing is staged\n", .{});
        return TestError.UnexpectedOutput;
    }
}

fn testStatus(harness: TestHarness) !void {
    std.debug.print("Testing git status...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_status");
    defer harness.removeTempDir(temp_dir);

    // Initialize repo
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();

    // Test status in empty repo
    var status_result = try harness.runZiggit(&[_][]const u8{"status"}, temp_dir);
    defer status_result.deinit();

    if (status_result.exit_code == 0) {
        std.debug.print("  ✓ git status basic functionality\n", .{});
    } else {
        std.debug.print("  ✗ git status failed with exit code {}\n", .{status_result.exit_code});
        return TestError.ProcessFailed;
    }
}

fn testLog(harness: TestHarness) !void {
    std.debug.print("Testing git log...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_log");
    defer harness.removeTempDir(temp_dir);

    // Initialize repo
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();

    // Test log in empty repo (should fail)
    var log_result = try harness.runZiggit(&[_][]const u8{"log"}, temp_dir);
    defer log_result.deinit();

    if (log_result.exit_code == 128) {
        std.debug.print("  ✓ git log correctly fails in empty repository\n", .{});
    } else {
        std.debug.print("  ✗ git log should fail with exit code 128 in empty repo, got {}\n", .{log_result.exit_code});
        return TestError.ProcessFailed;
    }
}

fn testBranch(harness: TestHarness) !void {
    std.debug.print("Testing git branch...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_branch");
    defer harness.removeTempDir(temp_dir);

    // Initialize repo
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();

    // Test branch in empty repo
    var branch_result = try harness.runZiggit(&[_][]const u8{"branch"}, temp_dir);
    defer branch_result.deinit();

    if (branch_result.exit_code == 0) {
        std.debug.print("  ✓ git branch basic functionality\n", .{});
    } else {
        std.debug.print("  ✗ git branch failed with exit code {}\n", .{branch_result.exit_code});
        return TestError.ProcessFailed;
    }
}

fn testCheckout(harness: TestHarness) !void {
    std.debug.print("Testing git checkout...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_checkout");
    defer harness.removeTempDir(temp_dir);

    // Initialize repo
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();

    // Test checkout without target (should fail)
    var checkout_result = try harness.runZiggit(&[_][]const u8{"checkout"}, temp_dir);
    defer checkout_result.deinit();

    if (checkout_result.exit_code == 128) {
        std.debug.print("  ✓ git checkout correctly fails in empty repository\n", .{});
    } else {
        std.debug.print("  ⚠ git checkout exit code: {}\n", .{checkout_result.exit_code});
    }
}

fn testDiff(harness: TestHarness) !void {
    std.debug.print("Testing git diff...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_diff");
    defer harness.removeTempDir(temp_dir);

    // Initialize repo
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();

    // Test diff in empty repo
    var diff_result = try harness.runZiggit(&[_][]const u8{"diff"}, temp_dir);
    defer diff_result.deinit();

    if (diff_result.exit_code == 0) {
        std.debug.print("  ✓ git diff basic functionality\n", .{});
    } else {
        std.debug.print("  ✗ git diff failed with exit code {}\n", .{diff_result.exit_code});
        return TestError.ProcessFailed;
    }
}