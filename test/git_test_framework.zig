const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

pub const GitTestFramework = struct {
    allocator: std.mem.Allocator,
    test_counter: u32,
    failed_counter: u32,
    temp_base_dir: []u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const timestamp = std.time.timestamp();
        const temp_base = try std.fmt.allocPrint(allocator, "/tmp/ziggit-test-{d}", .{timestamp});
        try std.fs.cwd().makeDir(temp_base);
        
        return Self{
            .allocator = allocator,
            .test_counter = 0,
            .failed_counter = 0,
            .temp_base_dir = temp_base,
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up test directories
        std.fs.cwd().deleteTree(self.temp_base_dir) catch {};
        self.allocator.free(self.temp_base_dir);
    }

    pub fn createTestRepo(self: *Self, test_name: []const u8) ![]u8 {
        const test_dir = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}-{d}",
            .{ self.temp_base_dir, test_name, self.test_counter }
        );
        
        try std.fs.cwd().makeDir(test_dir);
        return test_dir;
    }

    pub fn runGitCommand(self: *Self, working_dir: []const u8, args: []const []const u8) !TestResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var cmd_args = std.ArrayList([]const u8).init(arena_alloc);
        try cmd_args.append("git");
        for (args) |arg| {
            try cmd_args.append(arg);
        }

        const result = try std.process.Child.run(.{
            .allocator = arena_alloc,
            .argv = cmd_args.items,
            .cwd = working_dir,
        });

        return TestResult{
            .stdout = try self.allocator.dupe(u8, result.stdout),
            .stderr = try self.allocator.dupe(u8, result.stderr),
            .exit_code = result.term.Exited,
        };
    }

    pub fn runZiggitCommand(self: *Self, working_dir: []const u8, args: []const []const u8) !TestResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var cmd_args = std.ArrayList([]const u8).init(arena_alloc);
        try cmd_args.append("/root/ziggit/zig-out/bin/ziggit");
        for (args) |arg| {
            try cmd_args.append(arg);
        }

        const result = try std.process.Child.run(.{
            .allocator = arena_alloc,
            .argv = cmd_args.items,
            .cwd = working_dir,
        });

        return TestResult{
            .stdout = try self.allocator.dupe(u8, result.stdout),
            .stderr = try self.allocator.dupe(u8, result.stderr),
            .exit_code = result.term.Exited,
        };
    }

    pub fn testExpectSuccess(self: *Self, description: []const u8, test_func: TestFunction) !void {
        self.test_counter += 1;
        print("  test {d}: {s} ... ", .{ self.test_counter, description });

        test_func(self) catch |err| {
            self.failed_counter += 1;
            print("❌ FAILED: {}\n", .{err});
            return;
        };

        print("✅ ok\n", .{});
    }

    pub fn writeFile(self: *Self, dir_path: []const u8, filename: []const u8, content: []const u8) !void {
        const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, filename });
        defer self.allocator.free(full_path);
        
        try std.fs.cwd().writeFile(.{ .sub_path = full_path, .data = content });
    }

    pub fn expectStringsEqual(self: *Self, expected: []const u8, actual: []const u8) !void {
        _ = self;
        if (!std.mem.eql(u8, expected, actual)) {
            print("\nExpected: {s}\n", .{expected});
            print("Actual:   {s}\n", .{actual});
            return error.StringsNotEqual;
        }
    }

    pub fn expectExitCode(self: *Self, expected_code: u8, result: TestResult) !void {
        _ = self;
        if (result.exit_code != expected_code) {
            print("\nExpected exit code: {d}\n", .{expected_code});
            print("Actual exit code: {d}\n", .{result.exit_code});
            print("Stdout: {s}\n", .{result.stdout});
            print("Stderr: {s}\n", .{result.stderr});
            return error.UnexpectedExitCode;
        }
    }

    pub fn summary(self: *Self) void {
        const total = self.test_counter;
        const passed = total - self.failed_counter;
        
        print("\nTest Summary:\n", .{});
        print("  Total:  {d}\n", .{total});
        print("  Passed: {d}\n", .{passed});
        print("  Failed: {d}\n", .{self.failed_counter});

        if (self.failed_counter == 0) {
            print("🎉 All tests passed!\n", .{});
        } else {
            print("❌ {d} test(s) failed.\n", .{self.failed_counter});
        }
    }
};

pub const TestResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: *TestResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const TestFunction = *const fn (*GitTestFramework) anyerror!void;

// Helper function to compare git and ziggit outputs
pub fn compareGitZiggitOutput(
    framework: *GitTestFramework,
    test_dir: []const u8,
    command_args: []const []const u8,
    description: []const u8,
) !void {
    const git_result = try framework.runGitCommand(test_dir, command_args);
    defer git_result.deinit(framework.allocator);
    
    const ziggit_result = try framework.runZiggitCommand(test_dir, command_args);
    defer ziggit_result.deinit(framework.allocator);

    // Compare exit codes
    if (git_result.exit_code != ziggit_result.exit_code) {
        print("\n{s}: Exit code mismatch\n", .{description});
        print("Git exit code: {d}\n", .{git_result.exit_code});
        print("Ziggit exit code: {d}\n", .{ziggit_result.exit_code});
        return error.ExitCodeMismatch;
    }

    // For successful commands, we can compare some aspects of output
    if (git_result.exit_code == 0) {
        // TODO: Add more sophisticated output comparison based on command type
        // For now, just check that both succeed
    }
}