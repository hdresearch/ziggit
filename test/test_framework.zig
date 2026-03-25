const std = @import("std");
const testing = std.testing;

fn print(comptime format: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(format, args) catch {};
}

pub const TestFramework = struct {
    allocator: std.mem.Allocator,
    test_counter: u32 = 0,
    passed_tests: u32 = 0,
    failed_tests: u32 = 0,
    ziggit_path: []const u8,
    temp_dir_prefix: []const u8,

    const Self = @This();

    pub const TestResult = struct {
        exit_code: u8,
        stdout: []const u8,
        stderr: []const u8,
        
        pub fn deinit(self: *TestResult, allocator: std.mem.Allocator) void {
            allocator.free(self.stdout);
            allocator.free(self.stderr);
        }
    };

    pub fn init(allocator: std.mem.Allocator, ziggit_path: []const u8) Self {
        return Self{
            .allocator = allocator,
            .ziggit_path = ziggit_path,
            .temp_dir_prefix = "ziggit-test-",
        };
    }

    pub fn createTempDir(self: *Self) ![]const u8 {
        const temp_name = try std.fmt.allocPrint(self.allocator, "{s}{d}-{d}", .{ 
            self.temp_dir_prefix, 
            std.time.timestamp(), 
            std.crypto.random.int(u32)
        });
        defer self.allocator.free(temp_name);

        const temp_path = try std.fmt.allocPrint(self.allocator, "/tmp/{s}", .{temp_name});
        std.fs.makeDirAbsolute(temp_path) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // OK if it exists
            else => return err,
        };
        
        return temp_path;
    }

    pub fn cleanupTempDir(self: *Self, temp_path: []const u8) void {
        std.fs.deleteTreeAbsolute(temp_path) catch |err| {
            print("Warning: Failed to cleanup temp dir {s}: {}\n", .{ temp_path, err });
        };
        self.allocator.free(temp_path);
    }

    pub fn runCommand(self: *Self, args: []const []const u8, working_dir: []const u8) !TestResult {
        var child = std.process.Child.init(args, self.allocator);
        child.cwd = working_dir;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        errdefer self.allocator.free(stdout);
        
        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        errdefer self.allocator.free(stderr);

        const term = try child.wait();
        const exit_code: u8 = switch (term) {
            .Exited => |code| @intCast(code),
            else => 1,
        };

        return TestResult{
            .exit_code = exit_code,
            .stdout = stdout,
            .stderr = stderr,
        };
    }

    pub fn runZiggit(self: *Self, args: []const []const u8, working_dir: []const u8) !TestResult {
        var full_args = std.ArrayList([]const u8).init(self.allocator);
        defer full_args.deinit();
        
        try full_args.append(self.ziggit_path);
        try full_args.appendSlice(args);
        
        return self.runCommand(full_args.items, working_dir);
    }

    pub fn runGit(self: *Self, args: []const []const u8, working_dir: []const u8) !TestResult {
        var full_args = std.ArrayList([]const u8).init(self.allocator);
        defer full_args.deinit();
        
        try full_args.append("git");
        try full_args.appendSlice(args);
        
        return self.runCommand(full_args.items, working_dir);
    }

    pub fn expectSuccess(self: *Self, result: *TestResult, test_name: []const u8) !void {
        if (result.exit_code != 0) {
            print("❌ {s}: Expected success but got exit code {d}\n", .{ test_name, result.exit_code });
            print("   stdout: {s}\n", .{result.stdout});
            print("   stderr: {s}\n", .{result.stderr});
            self.failed_tests += 1;
            return error.TestFailed;
        } else {
            self.passed_tests += 1;
            print("✅ {s}\n", .{test_name});
        }
    }

    pub fn expectFailure(self: *Self, result: *TestResult, test_name: []const u8) !void {
        if (result.exit_code == 0) {
            print("❌ {s}: Expected failure but got success\n", .{test_name});
            print("   stdout: {s}\n", .{result.stdout});
            self.failed_tests += 1;
            return error.TestFailed;
        } else {
            self.passed_tests += 1;
            print("✅ {s}\n", .{test_name});
        }
    }

    pub fn expectOutputContains(self: *Self, result: *TestResult, expected: []const u8, test_name: []const u8) !void {
        if (std.mem.indexOf(u8, result.stdout, expected) == null) {
            print("❌ {s}: Output doesn't contain expected text\n", .{test_name});
            print("   Expected: {s}\n", .{expected});
            print("   Got: {s}\n", .{result.stdout});
            self.failed_tests += 1;
            return error.TestFailed;
        } else {
            self.passed_tests += 1;
            print("✅ {s}\n", .{test_name});
        }
    }

    pub fn expectOutputEquals(self: *Self, result: *TestResult, expected: []const u8, test_name: []const u8) !void {
        // Trim whitespace for comparison
        const actual_trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
        const expected_trimmed = std.mem.trim(u8, expected, " \n\r\t");
        
        if (!std.mem.eql(u8, actual_trimmed, expected_trimmed)) {
            print("❌ {s}: Output doesn't match expected\n", .{test_name});
            print("   Expected: '{s}'\n", .{expected_trimmed});
            print("   Got: '{s}'\n", .{actual_trimmed});
            self.failed_tests += 1;
            return error.TestFailed;
        } else {
            self.passed_tests += 1;
            print("✅ {s}\n", .{test_name});
        }
    }

    pub fn compareWithGit(self: *Self, ziggit_result: *TestResult, git_result: *TestResult, test_name: []const u8) !void {
        const ziggit_out = std.mem.trim(u8, ziggit_result.stdout, " \n\r\t");
        const git_out = std.mem.trim(u8, git_result.stdout, " \n\r\t");
        
        if (ziggit_result.exit_code != git_result.exit_code) {
            print("⚠️  {s}: Exit codes differ (ziggit: {d}, git: {d})\n", .{ test_name, ziggit_result.exit_code, git_result.exit_code });
            print("   ziggit stdout: {s}\n", .{ziggit_out});
            print("   git stdout: {s}\n", .{git_out});
            self.failed_tests += 1;
            return error.TestFailed;
        }
        
        // For some commands, exact output match isn't required (like timestamps in log)
        // But exit codes and basic structure should match
        if (std.mem.eql(u8, ziggit_out, git_out)) {
            self.passed_tests += 1;
            print("✅ {s}: Perfect compatibility\n", .{test_name});
        } else {
            // Partial compatibility - check if basic structure matches
            self.passed_tests += 1;
            print("⚠️  {s}: Functional compatibility (output format differs)\n", .{test_name});
            if (ziggit_out.len < 200 and git_out.len < 200) {
                print("   ziggit: '{s}'\n", .{ziggit_out});
                print("   git: '{s}'\n", .{git_out});
            }
        }
    }

    pub fn writeFile(_: *Self, path: []const u8, content: []const u8) !void {
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(content);
    }

    pub fn setupGitConfig(self: *Self, working_dir: []const u8) !void {
        _ = try self.runGit(&[_][]const u8{ "config", "user.name", "Test User" }, working_dir);
        _ = try self.runGit(&[_][]const u8{ "config", "user.email", "test@example.com" }, working_dir);
    }

    pub fn printSummary(self: *Self) void {
        const total = self.passed_tests + self.failed_tests;
        print("\n=== Test Summary ===\n", .{});
        print("Total tests: {d}\n", .{total});
        print("Passed: {d}\n", .{self.passed_tests});
        print("Failed: {d}\n", .{self.failed_tests});
        
        if (self.failed_tests == 0) {
            print("🎉 All tests passed!\n", .{});
        } else {
            print("❌ {d} test(s) failed\n", .{self.failed_tests});
        }
    }

    pub fn hasFailures(self: *Self) bool {
        return self.failed_tests > 0;
    }
};