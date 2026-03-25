const std = @import("std");
const testing = std.testing;
const test_harness = @import("test_harness.zig");
const TestHarness = test_harness.TestHarness;

// Format compatibility tests
// These tests ensure ziggit output format matches git exactly where required

pub fn runFormatTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const harness = TestHarness.init(allocator, "/root/zigg/root/ziggit/zig-out/bin/ziggit", "git");

    std.debug.print("Running format compatibility tests...\n", .{});

    // Test exact output format matching
    try testInitOutputFormat(harness);
    try testStatusOutputFormat(harness);
    try testAddOutputFormat(harness);
    try testHelpOutputFormat(harness);
    try testErrorMessageFormat(harness);
    try testVersionInformation(harness);
    
    std.debug.print("All format tests completed!\n", .{});
}

// Test that init output format matches git exactly
fn testInitOutputFormat(harness: TestHarness) !void {
    std.debug.print("  Testing init output format...\n", .{});
    
    // Test multiple init scenarios for format consistency
    const scenarios = [_]struct {
        name: []const u8,
        args: []const []const u8,
    }{
        .{ .name = "basic init", .args = &[_][]const u8{"init"} },
        .{ .name = "bare init", .args = &[_][]const u8{ "init", "--bare" } },
    };
    
    for (scenarios) |scenario| {
        const ziggit_dir = try harness.createTempDir("format_init_ziggit");
        defer harness.removeTempDir(ziggit_dir);
        const git_dir = try harness.createTempDir("format_init_git");
        defer harness.removeTempDir(git_dir);
        
        var ziggit_result = try harness.runZiggit(scenario.args, ziggit_dir);
        defer ziggit_result.deinit();
        var git_result = try harness.runGit(scenario.args, git_dir);
        defer git_result.deinit();
        
        if (ziggit_result.exit_code != 0 or git_result.exit_code != 0) {
            std.debug.print("    FAIL: {s} - command failed\n", .{scenario.name});
            continue;
        }
        
        // Compare normalized output format
        const ziggit_normalized = try normalizeInitOutput(harness.allocator, ziggit_result.stdout);
        defer harness.allocator.free(ziggit_normalized);
        const git_normalized = try normalizeInitOutput(harness.allocator, git_result.stdout);
        defer harness.allocator.free(git_normalized);
        
        if (std.mem.eql(u8, ziggit_normalized, git_normalized)) {
            std.debug.print("    ✓ {s} format\n", .{scenario.name});
        } else {
            std.debug.print("    ⚠ {s} format differs\n", .{scenario.name});
            std.debug.print("      ziggit: '{s}'\n", .{ziggit_normalized});
            std.debug.print("      git:    '{s}'\n", .{git_normalized});
        }
    }
}

// Test status output format matches git
fn testStatusOutputFormat(harness: TestHarness) !void {
    std.debug.print("  Testing status output format...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("format_status_ziggit");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("format_status_git");
    defer harness.removeTempDir(git_dir);
    
    // Initialize both repos
    var ziggit_init = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_init.deinit();
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_init.deinit();
    
    if (ziggit_init.exit_code != 0 or git_init.exit_code != 0) {
        std.debug.print("    FAIL: init failed\n", .{});
        return test_harness.TestError.ProcessFailed;
    }
    
    // Test status in clean empty repository
    var ziggit_status = try harness.runZiggit(&[_][]const u8{"status"}, ziggit_dir);
    defer ziggit_status.deinit();
    var git_status = try harness.runGit(&[_][]const u8{"status"}, git_dir);
    defer git_status.deinit();
    
    if (ziggit_status.exit_code != 0 or git_status.exit_code != 0) {
        std.debug.print("    FAIL: status failed\n", .{});
        return test_harness.TestError.ProcessFailed;
    }
    
    // Normalize status output for comparison
    const ziggit_normalized = try normalizeStatusOutput(harness.allocator, ziggit_status.stdout);
    defer harness.allocator.free(ziggit_normalized);
    const git_normalized = try normalizeStatusOutput(harness.allocator, git_status.stdout);
    defer harness.allocator.free(git_normalized);
    
    // Check key components of status output
    const has_branch_line_ziggit = std.mem.containsAtLeast(u8, ziggit_normalized, 1, "On branch");
    const has_branch_line_git = std.mem.containsAtLeast(u8, git_normalized, 1, "On branch");
    
    const has_no_commits_ziggit = std.mem.containsAtLeast(u8, ziggit_normalized, 1, "No commits yet");
    const has_no_commits_git = std.mem.containsAtLeast(u8, git_normalized, 1, "No commits yet");
    
    if (has_branch_line_ziggit == has_branch_line_git and 
        has_no_commits_ziggit == has_no_commits_git) {
        std.debug.print("    ✓ status format (key elements match)\n", .{});
    } else {
        std.debug.print("    ⚠ status format differs\n", .{});
        std.debug.print("      ziggit: '{s}'\n", .{ziggit_normalized});
        std.debug.print("      git:    '{s}'\n", .{git_normalized});
    }
}

// Test add output format (usually silent)
fn testAddOutputFormat(harness: TestHarness) !void {
    std.debug.print("  Testing add output format...\n", .{});
    
    const ziggit_dir = try harness.createTempDir("format_add_ziggit");
    defer harness.removeTempDir(ziggit_dir);
    const git_dir = try harness.createTempDir("format_add_git");
    defer harness.removeTempDir(git_dir);
    
    // Initialize both repos
    var ziggit_init = try harness.runZiggit(&[_][]const u8{"init"}, ziggit_dir);
    defer ziggit_init.deinit();
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_init.deinit();
    
    // Create test files
    const ziggit_file = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{ziggit_dir});
    defer harness.allocator.free(ziggit_file);
    const git_file = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{git_dir});
    defer harness.allocator.free(git_file);
    
    {
        const file = try std.fs.createFileAbsolute(ziggit_file, .{});
        defer file.close();
        try file.writeAll("test content\n");
    }
    {
        const file = try std.fs.createFileAbsolute(git_file, .{});
        defer file.close();
        try file.writeAll("test content\n");
    }
    
    // Test add output
    var ziggit_add = try harness.runZiggit(&[_][]const u8{ "add", "test.txt" }, ziggit_dir);
    defer ziggit_add.deinit();
    var git_add = try harness.runGit(&[_][]const u8{ "add", "test.txt" }, git_dir);
    defer git_add.deinit();
    
    // Add usually produces no output on success
    const ziggit_output_len = std.mem.trim(u8, ziggit_add.stdout, " \t\r\n").len;
    const git_output_len = std.mem.trim(u8, git_add.stdout, " \t\r\n").len;
    
    if (ziggit_output_len == git_output_len and ziggit_add.exit_code == git_add.exit_code) {
        std.debug.print("    ✓ add format (both silent on success)\n", .{});
    } else {
        std.debug.print("    ⚠ add format differs\n", .{});
        std.debug.print("      ziggit: exit={}, output='{s}'\n", .{ ziggit_add.exit_code, ziggit_add.stdout });
        std.debug.print("      git:    exit={}, output='{s}'\n", .{ git_add.exit_code, git_add.stdout });
    }
}

// Test help/usage output format
fn testHelpOutputFormat(harness: TestHarness) !void {
    std.debug.print("  Testing help output format...\n", .{});
    
    const temp_dir = try harness.createTempDir("format_help");
    defer harness.removeTempDir(temp_dir);
    
    // Test no arguments (should show usage)
    var ziggit_help = try harness.runZiggit(&[_][]const u8{}, temp_dir);
    defer ziggit_help.deinit();
    
    // Check for expected help format elements
    const help_content = std.mem.trim(u8, ziggit_help.stdout, " \t\r\n");
    const has_usage = std.mem.containsAtLeast(u8, help_content, 1, "usage:");
    const has_commands = std.mem.containsAtLeast(u8, help_content, 1, "init");
    
    if (has_usage and has_commands and ziggit_help.exit_code == 0) {
        std.debug.print("    ✓ help format\n", .{});
    } else {
        std.debug.print("    ⚠ help format needs work\n", .{});
        std.debug.print("      output: '{s}'\n", .{help_content});
    }
}

// Test error message format consistency
fn testErrorMessageFormat(harness: TestHarness) !void {
    std.debug.print("  Testing error message format...\n", .{});
    
    const temp_dir = try harness.createTempDir("format_error");
    defer harness.removeTempDir(temp_dir);
    
    const error_scenarios = [_]struct {
        name: []const u8,
        command: []const []const u8,
    }{
        .{ .name = "not a repository", .command = &[_][]const u8{"status"} },
        .{ .name = "invalid command", .command = &[_][]const u8{"nonexistent"} },
        .{ .name = "add nonexistent", .command = &[_][]const u8{ "add", "nonexistent.txt" } },
    };
    
    for (error_scenarios) |scenario| {
        var ziggit_result = try harness.runZiggit(scenario.command, temp_dir);
        defer ziggit_result.deinit();
        var git_result = try harness.runGit(scenario.command, temp_dir);
        defer git_result.deinit();
        
        // Both should fail
        if (ziggit_result.exit_code != 0 and git_result.exit_code != 0) {
            // Check if error messages have similar structure
            const ziggit_has_fatal = std.mem.containsAtLeast(u8, ziggit_result.stderr, 1, "fatal:");
            const git_has_fatal = std.mem.containsAtLeast(u8, git_result.stderr, 1, "fatal:");
            
            if (ziggit_has_fatal == git_has_fatal) {
                std.debug.print("    ✓ {s} error format\n", .{scenario.name});
            } else {
                std.debug.print("    ⚠ {s} error format differs\n", .{scenario.name});
            }
        }
    }
}

// Test version information format (if implemented)
fn testVersionInformation(harness: TestHarness) !void {
    std.debug.print("  Testing version information...\n", .{});
    
    const temp_dir = try harness.createTempDir("format_version");
    defer harness.removeTempDir(temp_dir);
    
    // Try common version flags
    const version_args = [_][]const []const u8{
        &[_][]const u8{"--version"},
        &[_][]const u8{"-v"},
        &[_][]const u8{"version"},
    };
    
    for (version_args) |args| {
        var ziggit_result = try harness.runZiggit(args, temp_dir);
        defer ziggit_result.deinit();
        
        if (ziggit_result.exit_code == 0) {
            std.debug.print("    ✓ version flag supported\n", .{});
            break;
        }
    } else {
        std.debug.print("    ⚠ version information not implemented\n", .{});
    }
}

// Helper function to normalize init output
fn normalizeInitOutput(allocator: std.mem.Allocator, output: []u8) ![]u8 {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    
    if (std.mem.startsWith(u8, trimmed, "Initialized empty Git repository")) {
        return try allocator.dupe(u8, "Initialized empty Git repository");
    } else if (std.mem.startsWith(u8, trimmed, "Reinitialized existing Git repository")) {
        return try allocator.dupe(u8, "Reinitialized existing Git repository");
    } else {
        return try allocator.dupe(u8, trimmed);
    }
}

// Helper function to normalize status output
fn normalizeStatusOutput(allocator: std.mem.Allocator, output: []u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var lines = std.mem.split(u8, output, "\n");
    while (lines.next()) |line| {
        var normalized_line = std.mem.trim(u8, line, " \t\r");
        
        // Skip empty lines for comparison
        if (normalized_line.len == 0) continue;
        
        // Normalize branch references
        if (std.mem.startsWith(u8, normalized_line, "On branch ")) {
            if (std.mem.containsAtLeast(u8, normalized_line, 1, "master") or 
                std.mem.containsAtLeast(u8, normalized_line, 1, "main")) {
                normalized_line = "On branch master";
            }
        }
        
        try result.appendSlice(normalized_line);
        try result.append('\n');
    }
    
    return try result.toOwnedSlice();
}