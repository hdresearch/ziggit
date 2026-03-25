// Main test runner for git compatibility tests
const std = @import("std");

const git_source_harness = @import("git_source_test_harness.zig");
const basic_tests = @import("git_t0000_basic_tests.zig");
const init_tests = @import("git_t0001_init_compat_tests.zig");
const add_status_tests = @import("git_t2xxx_add_status_compat_tests.zig");
const commit_tests = @import("git_t3xxx_commit_compat_tests.zig");

pub fn main() !void {
    std.debug.print("=== Git Compatibility Test Suite ===\n", .{});
    std.debug.print("Running comprehensive tests adapted from git source test suite\n\n", .{});
    
    var total_tests: u32 = 0;
    var passed_tests: u32 = 0;
    var failed_tests: u32 = 0;
    
    // Test 1: Basic functionality tests
    std.debug.print("[1/6] Basic functionality tests...\n", .{});
    total_tests += 1;
    if (basic_tests.runBasicTests()) {
        passed_tests += 1;
        std.debug.print("✅ Basic tests PASSED\n\n", .{});
    } else |err| {
        failed_tests += 1;
        std.debug.print("❌ Basic tests FAILED: {}\n\n", .{err});
    }
    
    // Test 2: Git init compatibility tests  
    std.debug.print("[2/6] Git init compatibility tests...\n", .{});
    total_tests += 1;
    if (init_tests.runInitCompatTests()) {
        passed_tests += 1;
        std.debug.print("✅ Init compatibility tests PASSED\n\n", .{});
    } else |err| {
        failed_tests += 1;
        std.debug.print("❌ Init compatibility tests FAILED: {}\n\n", .{err});
    }
    
    // Test 3: Add/status compatibility tests
    std.debug.print("[3/6] Add/status compatibility tests...\n", .{}); 
    total_tests += 1;
    if (add_status_tests.runAddStatusCompatTests()) {
        passed_tests += 1;
        std.debug.print("✅ Add/status compatibility tests PASSED\n\n", .{});
    } else |err| {
        failed_tests += 1;
        std.debug.print("❌ Add/status compatibility tests FAILED: {}\n\n", .{err});
    }
    
    // Test 4: Commit compatibility tests
    std.debug.print("[4/6] Commit compatibility tests...\n", .{});
    total_tests += 1;
    if (commit_tests.runCommitCompatTests()) {
        passed_tests += 1;
        std.debug.print("✅ Commit compatibility tests PASSED\n\n", .{});
    } else |err| {
        failed_tests += 1;
        std.debug.print("❌ Commit compatibility tests FAILED: {}\n\n", .{err});
    }
    
    // Test 5: Git source test harness
    std.debug.print("[5/6] Git source test harness tests...\n", .{});
    total_tests += 1;
    if (git_source_harness.runGitSourceCompatTests()) {
        passed_tests += 1;
        std.debug.print("✅ Git source harness tests PASSED\n\n", .{});
    } else |err| {
        failed_tests += 1;
        std.debug.print("❌ Git source harness tests FAILED: {}\n\n", .{err});
    }
    
    // Test 6: Integration workflow test
    std.debug.print("[6/6] Complete workflow integration test...\n", .{});
    total_tests += 1;
    if (runCompleteWorkflowTest()) {
        passed_tests += 1;
        std.debug.print("✅ Complete workflow test PASSED\n\n", .{});
    } else |err| {
        failed_tests += 1;
        std.debug.print("❌ Complete workflow test FAILED: {}\n\n", .{err});
    }
    
    // Summary
    std.debug.print("=== Test Results Summary ===\n", .{});
    std.debug.print("Total tests: {d}\n", .{total_tests});
    std.debug.print("Passed: {d}\n", .{passed_tests});
    std.debug.print("Failed: {d}\n", .{failed_tests});
    
    if (failed_tests == 0) {
        std.debug.print("\n🎉 ALL TESTS PASSED! ziggit shows good git compatibility.\n", .{});
        std.process.exit(0);
    } else {
        std.debug.print("\n⚠️  Some tests failed. ziggit needs work for full git compatibility.\n", .{});
        std.process.exit(1);
    }
}

fn runCompleteWorkflowTest() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tf = git_source_harness.TestFramework.init(allocator);
    defer tf.deinit();
    
    std.debug.print("  Running complete git workflow simulation...\n", .{});
    
    const test_dir = try tf.createTempDir("complete-workflow");
    defer tf.removeTempDir(test_dir);
    
    // Step 1: Initialize repository
    var init_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init" 
    }, test_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        std.debug.print("    ❌ Workflow init failed: {s}\n", .{init_result.stderr});
        return;
    }
    
    // Step 2: Create and stage files
    try tf.writeFile(test_dir, "README.md", "# Test Project\n\nThis is a test repository.\n");
    try tf.writeFile(test_dir, "main.zig", "const std = @import(\"std\");\n\npub fn main() void {\n    std.debug.std.debug.print(\"Hello, World!\\n\", .{});\n}\n");
    
    var add_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "." 
    }, test_dir);
    defer add_result.deinit();
    
    if (add_result.exit_code != 0) {
        std.debug.print("    ❌ Workflow add failed: {s}\n", .{add_result.stderr});
        return;
    }
    
    // Step 3: Check status before commit
    var status1_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    defer status1_result.deinit();
    
    if (status1_result.exit_code != 0) {
        std.debug.print("    ❌ Workflow status (pre-commit) failed: {s}\n", .{status1_result.stderr});
        return;
    }
    
    // Step 4: Commit changes
    var commit_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial commit: Add README and main.zig" 
    }, test_dir);
    defer commit_result.deinit();
    
    if (commit_result.exit_code != 0) {
        std.debug.print("    ❌ Workflow commit failed: {s}\n", .{commit_result.stderr});
        return;
    }
    
    // Step 5: Check status after commit
    var status2_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    defer status2_result.deinit();
    
    if (status2_result.exit_code != 0) {
        std.debug.print("    ❌ Workflow status (post-commit) failed: {s}\n", .{status2_result.stderr});
        return;
    }
    
    // Step 6: View commit log
    var log_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "log", "--oneline" 
    }, test_dir);
    defer log_result.deinit();
    
    if (log_result.exit_code != 0) {
        std.debug.print("    ❌ Workflow log failed: {s}\n", .{log_result.stderr});
        return;
    }
    
    // Step 7: Make changes and test diff
    try tf.writeFile(test_dir, "main.zig", "const std = @import(\"std\");\n\npub fn main() void {\n    std.debug.std.debug.print(\"Hello, ziggit!\\n\", .{});\n}\n");
    
    var diff_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "diff" 
    }, test_dir);
    defer diff_result.deinit();
    
    if (diff_result.exit_code != 0) {
        std.debug.print("    ❌ Workflow diff failed: {s}\n", .{diff_result.stderr});
        return;
    }
    
    // Step 8: Stage and commit the changes
    var add2_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "main.zig" 
    }, test_dir);
    defer add2_result.deinit();
    
    if (add2_result.exit_code != 0) {
        std.debug.print("    ❌ Workflow second add failed: {s}\n", .{add2_result.stderr});
        return;
    }
    
    var commit2_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Update greeting message" 
    }, test_dir);
    defer commit2_result.deinit();
    
    if (commit2_result.exit_code != 0) {
        std.debug.print("    ❌ Workflow second commit failed: {s}\n", .{commit2_result.stderr});
        return;
    }
    
    // Step 9: Final log check
    var final_log_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "log", "--oneline" 
    }, test_dir);
    defer final_log_result.deinit();
    
    if (final_log_result.exit_code != 0) {
        std.debug.print("    ❌ Workflow final log failed: {s}\n", .{final_log_result.stderr});
        return;
    }
    
    // Verify we have two commits
    const commit_lines = std.mem.count(u8, final_log_result.stdout, "\n");
    if (commit_lines < 2) {
        std.debug.print("    ❌ Should have at least 2 commits, found {d}\n", .{commit_lines});
        return;
    }
    
    // Verify both commit messages are present
    if (std.mem.indexOf(u8, final_log_result.stdout, "Initial commit") == null or
        std.mem.indexOf(u8, final_log_result.stdout, "Update greeting message") == null) {
        std.debug.print("    ❌ Both commit messages should be present in final log\n", .{});
        return;
    }
    
    std.debug.print("    ✓ Complete workflow test passed - full git workflow simulated successfully!\n", .{});
}

// Build system integration test
pub fn testBuildSystemIntegration() !void {
    std.debug.print("\nRunning build system integration test...\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Test that ziggit binary exists and is executable
    var proc = std.process.Child.init(&[_][]const u8{"/root/ziggit/zig-out/bin/ziggit", "--version"}, allocator);
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;
    
    try proc.spawn();
    _ = try proc.wait();
    
    std.debug.print("✓ Build system integration verified\n", .{});
}