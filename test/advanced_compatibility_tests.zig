const std = @import("std");
const test_harness = @import("test_harness.zig");

pub fn runAdvancedCompatibilityTests() !void {
    std.debug.print("Running advanced compatibility tests...\n", .{});
    
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Test cases for more advanced git compatibility
    var test_count: u32 = 0;
    var passed_count: u32 = 0;
    
    // Test 1: Complex repository initialization with different options
    test_count += 1;
    if (testComplexInit(allocator)) {
        passed_count += 1;
        std.debug.print("  ✅ Complex init test passed\n", .{});
    } else |_| {
        std.debug.print("  ❌ Complex init test failed\n", .{});
    }
    
    // Test 2: Repository status in various states
    test_count += 1;
    if (testRepositoryStatus(allocator)) {
        passed_count += 1;
        std.debug.print("  ✅ Repository status test passed\n", .{});
    } else |_| {
        std.debug.print("  ❌ Repository status test failed\n", .{});
    }
    
    std.debug.print("Advanced compatibility tests: {}/{} passed\n", .{ passed_count, test_count });
    
    if (passed_count < test_count) {
        return error.TestsFailed;
    }
}

fn testComplexInit(allocator: std.mem.Allocator) !void {
    const test_dir = "test-advanced-init";
    test_harness.cleanupTestDir(test_dir);
    defer test_harness.cleanupTestDir(test_dir);
    
    // Create test directory
    try std.fs.cwd().makeDir(test_dir);
    
    // Test bare repository initialization
    const result = try test_harness.runZiggitCommand(allocator, &[_][]const u8{
        "init", "--bare", test_dir
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    if (result.exit_code != 0) {
        std.debug.print("ziggit init --bare failed with code {}: {s}\n", .{ result.exit_code, result.stderr });
        return error.TestFailed;
    }
    
    // Check that it created the right structure for a bare repository
    const config_file = try std.fs.path.join(allocator, &[_][]const u8{ test_dir, "config" });
    defer allocator.free(config_file);
    
    const config_content = std.fs.cwd().readFileAlloc(allocator, config_file, 1024) catch |err| {
        std.debug.print("Failed to read config file: {}\n", .{err});
        return error.TestFailed;
    };
    defer allocator.free(config_content);
    
    // Check that bare = true is set
    if (std.mem.indexOf(u8, config_content, "bare = true") == null) {
        std.debug.print("Config file doesn't contain 'bare = true'\n", .{});
        return error.TestFailed;
    }
}

fn testRepositoryStatus(allocator: std.mem.Allocator) !void {
    const test_dir = "test-advanced-status";
    test_harness.cleanupTestDir(test_dir);
    defer test_harness.cleanupTestDir(test_dir);
    
    // Initialize repository
    const result = try test_harness.runZiggitCommand(allocator, &[_][]const u8{
        "init", test_dir
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    if (result.exit_code != 0) {
        return error.TestFailed;
    }
    
    // Create a test harness instance to run status in the test directory
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    const harness = test_harness.TestHarness.init(gpa.allocator(), "./zig-out/bin/ziggit", "git");
    
    // Test status in empty repository using the test directory as cwd
    var status_result = try harness.runZiggit(&[_][]const u8{"status"}, test_dir);
    defer status_result.deinit();
    
    if (status_result.exit_code != 0) {
        std.debug.print("ziggit status failed: {s}\n", .{status_result.stderr});
        return error.TestFailed;
    }
    
    // Check basic status output format
    if (std.mem.indexOf(u8, status_result.stdout, "On branch master") == null) {
        std.debug.print("Status doesn't show branch info\n", .{});
        return error.TestFailed;
    }
    
    if (std.mem.indexOf(u8, status_result.stdout, "No commits yet") == null) {
        std.debug.print("Status doesn't show 'No commits yet'\n", .{});
        return error.TestFailed;
    }
}

// Zig test integration
test "advanced compatibility tests" {
    try runAdvancedCompatibilityTests();
}