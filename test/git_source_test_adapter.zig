const std = @import("std");


// Git Source Test Suite Adapter
// Adapted from git/git.git/t/ test directory
// Creates a Zig-native test harness that follows git's test patterns

const ZIGGIT_PATH = "/root/ziggit/zig-out/bin/ziggit";
const GIT_PATH = "git";

pub const TestResult = enum {
    pass,
    fail,
    skip,
};

pub const TestCase = struct {
    name: []const u8,
    description: []const u8,
    setup_fn: ?*const fn(*TestRunner) anyerror!void = null,
    test_fn: *const fn(*TestRunner) anyerror!TestResult,
    cleanup_fn: ?*const fn(*TestRunner) anyerror!void = null,
};

pub const CommandResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    
    pub fn deinit(self: CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const TestRunner = struct {
    allocator: std.mem.Allocator,
    test_dir: []const u8,
    cleanup_list: std.ArrayList([]const u8),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, test_name: []const u8) !Self {
        // Create unique test directory
        var buf: [256]u8 = undefined;
        const timestamp = std.time.timestamp();
        const test_dir = try std.fmt.bufPrint(&buf, "/tmp/ziggit-test-{s}-{d}", .{ test_name, timestamp });
        
        // Clean up any existing directory
        std.fs.cwd().deleteTree(test_dir[1..]) catch {};
        try std.fs.cwd().makePath(test_dir[1..]);
        
        const owned_test_dir = try allocator.dupe(u8, test_dir);
        
        return Self{
            .allocator = allocator,
            .test_dir = owned_test_dir,
            .cleanup_list = std.ArrayList([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        // Clean up temporary directories
        for (self.cleanup_list.items) |dir| {
            std.fs.cwd().deleteTree(dir[1..]) catch {};
            self.allocator.free(dir);
        }
        self.cleanup_list.deinit();
        
        // Clean up main test directory
        std.fs.cwd().deleteTree(self.test_dir[1..]) catch {};
        self.allocator.free(self.test_dir);
    }
    
    pub fn runZiggit(self: *Self, args: []const []const u8) !CommandResult {
        const ziggit_args = try self.allocator.alloc([]const u8, args.len + 1);
        defer self.allocator.free(ziggit_args);
        ziggit_args[0] = ZIGGIT_PATH;
        for (args, 0..) |arg, i| {
            ziggit_args[i + 1] = arg;
        }
        return try self.runCommand(ziggit_args);
    }
    
    pub fn runGit(self: *Self, args: []const []const u8) !CommandResult {
        const git_args = try self.allocator.alloc([]const u8, args.len + 1);
        defer self.allocator.free(git_args);
        git_args[0] = GIT_PATH;
        for (args, 0..) |arg, i| {
            git_args[i + 1] = arg;
        }
        return try self.runCommand(git_args);
    }
    
    pub fn runCommand(self: *Self, args: []const []const u8) !CommandResult {
        var proc = std.process.Child.init(args, self.allocator);
        proc.cwd = self.test_dir;
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;
        
        try proc.spawn();
        
        const stdout = try proc.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        const stderr = try proc.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        const exit_code = try proc.wait();
        
        return CommandResult{
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = switch (exit_code) {
                .Exited => |code| code,
                else => 255,
            },
        };
    }
    
    pub fn createFile(self: *Self, path: []const u8, content: []const u8) !void {
        var buf: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.test_dir, path });
        
        // Ensure parent directory exists
        if (std.fs.path.dirname(full_path)) |dir| {
            try std.fs.cwd().makePath(dir[1..]);
        }
        
        try std.fs.cwd().writeFile(.{ .sub_path = full_path[1..], .data = content });
    }
    
    pub fn fileExists(self: *Self, path: []const u8) bool {
        var buf: [512]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.test_dir, path }) catch return false;
        
        std.fs.cwd().access(full_path[1..], .{}) catch return false;
        return true;
    }
    
    pub fn dirExists(self: *Self, path: []const u8) bool {
        var buf: [512]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.test_dir, path }) catch return false;
        
        const stat = std.fs.cwd().statFile(full_path[1..]) catch return false;
        return stat.kind == .directory;
    }
    
    pub fn expectExitCode(self: *Self, expected: u8, actual: u8, test_name: []const u8) TestResult {
        _ = self; // unused
        if (expected == actual) {
            std.debug.print("    ✓ {s}: exit code {d}\n", .{ test_name, actual });
            return .pass;
        } else {
            std.debug.print("    ✗ {s}: expected exit code {d}, got {d}\n", .{ test_name, expected, actual });
            return .fail;
        }
    }
    
    pub fn expectContains(self: *Self, haystack: []const u8, needle: []const u8, test_name: []const u8) TestResult {
        _ = self; // unused
        if (std.mem.indexOf(u8, haystack, needle) != null) {
            std.debug.print("    ✓ {s}: output contains '{s}'\n", .{ test_name, needle });
            return .pass;
        } else {
            std.debug.print("    ✗ {s}: output does not contain '{s}'\n", .{ test_name, needle });
            std.debug.print("      actual output: {s}\n", .{haystack});
            return .fail;
        }
    }
    
    pub fn expectFileExists(self: *Self, path: []const u8, test_name: []const u8) TestResult {
        if (self.fileExists(path)) {
            std.debug.print("    ✓ {s}: file {s} exists\n", .{ test_name, path });
            return .pass;
        } else {
            std.debug.print("    ✗ {s}: file {s} does not exist\n", .{ test_name, path });
            return .fail;
        }
    }
    
    pub fn expectDirExists(self: *Self, path: []const u8, test_name: []const u8) TestResult {
        if (self.dirExists(path)) {
            std.debug.print("    ✓ {s}: directory {s} exists\n", .{ test_name, path });
            return .pass;
        } else {
            std.debug.print("    ✗ {s}: directory {s} does not exist\n", .{ test_name, path });
            return .fail;
        }
    }
};

pub fn runTestSuite(test_name: []const u8, test_cases: []const TestCase) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("=== Running {s} ===\n", .{test_name});
    
    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;
    
    for (test_cases) |test_case| {
        std.debug.print("\n{s}: {s}\n", .{ test_case.name, test_case.description });
        
        var runner = TestRunner.init(allocator, test_case.name) catch |err| {
            std.debug.print("  ✗ Failed to initialize test runner: {}\n", .{err});
            failed += 1;
            continue;
        };
        defer runner.deinit();
        
        // Setup
        if (test_case.setup_fn) |setup| {
            setup(&runner) catch |err| {
                std.debug.print("  ✗ Setup failed: {}\n", .{err});
                failed += 1;
                continue;
            };
        }
        
        // Run test
        const result = test_case.test_fn(&runner) catch |err| {
            std.debug.print("  ✗ Test failed with error: {}\n", .{err});
            failed += 1;
            continue;
        };
        
        // Cleanup
        if (test_case.cleanup_fn) |cleanup| {
            cleanup(&runner) catch |err| {
                std.debug.print("  ⚠ Cleanup failed: {}\n", .{err});
            };
        }
        
        switch (result) {
            .pass => {
                passed += 1;
            },
            .fail => {
                failed += 1;
            },
            .skip => {
                skipped += 1;
                std.debug.print("  ⚠ {s} skipped\n", .{test_case.name});
            },
        }
    }
    
    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Passed: {d}\n", .{passed});
    std.debug.print("Failed: {d}\n", .{failed});
    std.debug.print("Skipped: {d}\n", .{skipped});
    std.debug.print("Total: {d}\n", .{passed + failed + skipped});
    
    if (failed > 0) {
        std.debug.print("\nSome tests failed. Ziggit may not be fully compatible with git.\n", .{});
    } else {
        std.debug.print("\nAll tests passed! Ziggit is compatible with git for these operations.\n", .{});
    }
}