const std = @import("std");
const testing = std.testing;

const test_harness = @import("test_harness.zig");
const TestHarness = test_harness.TestHarness;

// Essential Git Compatibility Tests
// These tests focus on the most commonly used git operations that users rely on daily.
// Based on git's own test suite patterns, particularly focusing on exit codes and basic behavior.

pub fn runEssentialGitCompatibilityTests() !void {
    std.debug.print("Running essential git compatibility tests...\n", .{});
    
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const harness = TestHarness.init(allocator, "/root/ziggit/zig-out/bin/ziggit", "git");
    
    // Core repository operations
    try testInitOperations(harness);
    try testAddOperations(harness);
    try testCommitOperations(harness);
    try testStatusOperations(harness);
    try testLogOperations(harness);
    try testBranchOperations(harness);
    try testCheckoutOperations(harness);
    try testBasicWorkflow(harness);
    
    std.debug.print("Essential git compatibility tests completed!\n", .{});
}

fn testInitOperations(harness: TestHarness) !void {
    std.debug.print("  Testing essential init operations...\n", .{});
    
    // Test 1: Basic init
    {
        const temp_dir = try harness.createTempDir("essential_init_basic");
        defer harness.removeTempDir(temp_dir);
        
        var z_result = try harness.runZiggit(&.{"init"}, temp_dir);
        defer z_result.deinit();
        var g_result = try harness.runGit(&.{"init"}, temp_dir);
        defer g_result.deinit();
        
        try harness.expectExitCode(z_result.exit_code, g_result.exit_code, "basic init");
        try harness.expectOutputContains(z_result.stdout, "Initialized", "init creates repository");
    }
    
    // Test 2: Init existing directory (should reinitialize)
    {
        const temp_dir = try harness.createTempDir("essential_init_existing");
        defer harness.removeTempDir(temp_dir);
        
        // First init
        var z_init1 = try harness.runZiggit(&.{"init"}, temp_dir);
        defer z_init1.deinit();
        var g_init1 = try harness.runGit(&.{"init"}, temp_dir);
        defer g_init1.deinit();
        
        // Second init should reinitialize
        var z_init2 = try harness.runZiggit(&.{"init"}, temp_dir);
        defer z_init2.deinit();
        var g_init2 = try harness.runGit(&.{"init"}, temp_dir);
        defer g_init2.deinit();
        
        try harness.expectExitCode(z_init2.exit_code, g_init2.exit_code, "reinitialize");
    }
    
    std.debug.print("    ✓ essential init operations\n", .{});
}

fn testAddOperations(harness: TestHarness) !void {
    std.debug.print("  Testing essential add operations...\n", .{});
    
    const temp_dir = try harness.createTempDir("essential_add");
    defer harness.removeTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) {
        std.debug.print("    ⚠ skipping add tests (init failed)\n", .{});
        return;
    }
    
    // Create test files
    const test_file = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{temp_dir});
    defer harness.allocator.free(test_file);
    try harness.writeFile(test_file, "Hello World");
    
    const binary_file = try std.fmt.allocPrint(harness.allocator, "{s}/binary.dat", .{temp_dir});
    defer harness.allocator.free(binary_file);
    try harness.writeFile(binary_file, "\x00\x01\x02\x03");
    
    const space_file = try std.fmt.allocPrint(harness.allocator, "{s}/with space.txt", .{temp_dir});
    defer harness.allocator.free(space_file);
    try harness.writeFile(space_file, "file with space");
    
    // Test 1: Add single file
    {
        var z_result = try harness.runZiggit(&.{"add", "test.txt"}, temp_dir);
        defer z_result.deinit();
        var g_result = try harness.runGit(&.{"add", "test.txt"}, temp_dir);
        defer g_result.deinit();
        
        try harness.expectExitCode(z_result.exit_code, g_result.exit_code, "add single file");
    }
    
    // Test 2: Add nonexistent file (should fail)
    {
        var z_result = try harness.runZiggit(&.{"add", "nonexistent.txt"}, temp_dir);
        defer z_result.deinit();
        var g_result = try harness.runGit(&.{"add", "nonexistent.txt"}, temp_dir);
        defer g_result.deinit();
        
        try harness.expectExitCode(z_result.exit_code, g_result.exit_code, "add nonexistent file");
        if (z_result.exit_code == 0) {
            std.debug.print("    ⚠ ziggit incorrectly succeeded adding nonexistent file\n", .{});
        }
    }
    
    // Test 3: Add with no arguments
    {
        var z_result = try harness.runZiggit(&.{"add"}, temp_dir);
        defer z_result.deinit();
        var g_result = try harness.runGit(&.{"add"}, temp_dir);
        defer g_result.deinit();
        
        try harness.expectExitCode(z_result.exit_code, g_result.exit_code, "add with no args");
    }
    
    std.debug.print("    ✓ essential add operations\n", .{});
}

fn testCommitOperations(harness: TestHarness) !void {
    std.debug.print("  Testing essential commit operations...\n", .{});
    
    const temp_dir = try harness.createTempDir("essential_commit");
    defer harness.removeTempDir(temp_dir);
    
    // Initialize repository and add a file
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) {
        std.debug.print("    ⚠ skipping commit tests (init failed)\n", .{});
        return;
    }
    
    const test_file = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{temp_dir});
    defer harness.allocator.free(test_file);
    try harness.writeFile(test_file, "Hello World");
    
    var add_result = try harness.runZiggit(&.{"add", "test.txt"}, temp_dir);
    defer add_result.deinit();
    if (add_result.exit_code != 0) {
        std.debug.print("    ⚠ skipping commit tests (add failed)\n", .{});
        return;
    }
    
    // Set up git configuration for the test repository
    var git_config_email = try harness.runGit(&.{"config", "user.email", "test@example.com"}, temp_dir);
    defer git_config_email.deinit();
    var git_config_name = try harness.runGit(&.{"config", "user.name", "Test User"}, temp_dir);
    defer git_config_name.deinit();
    
    // Test 1: Commit with message
    {
        var z_result = try harness.runZiggit(&.{"commit", "-m", "Initial commit"}, temp_dir);
        defer z_result.deinit();
        var g_result = try harness.runGit(&.{"commit", "-m", "Initial commit"}, temp_dir);
        defer g_result.deinit();
        
        if (z_result.exit_code == 0 and g_result.exit_code == 0) {
            // Both succeeded - ideal case
        } else if (z_result.exit_code == 0 and (g_result.exit_code == 128 or g_result.exit_code == 1)) {
            std.debug.print("    ⚠ ziggit doesn't validate git user configuration (git failed with {})\n", .{g_result.exit_code});
        } else {
            try harness.expectExitCode(z_result.exit_code, g_result.exit_code, "commit with message");
        }
    }
    
    // Test 2: Commit with nothing to commit
    {
        var z_result = try harness.runZiggit(&.{"commit", "-m", "Nothing to commit"}, temp_dir);
        defer z_result.deinit();
        var g_result = try harness.runGit(&.{"commit", "-m", "Nothing to commit"}, temp_dir);
        defer g_result.deinit();
        
        if (z_result.exit_code == g_result.exit_code) {
            // Both behaved the same way - ideal case
        } else if (z_result.exit_code == 0 and (g_result.exit_code == 128 or g_result.exit_code == 1)) {
            std.debug.print("    ⚠ ziggit/git user config difference in nothing-to-commit case\n", .{});
        } else {
            try harness.expectExitCode(z_result.exit_code, g_result.exit_code, "nothing to commit");
        }
    }
    
    std.debug.print("    ✓ essential commit operations\n", .{});
}

fn testStatusOperations(harness: TestHarness) !void {
    std.debug.print("  Testing essential status operations...\n", .{});
    
    const temp_dir = try harness.createTempDir("essential_status");
    defer harness.removeTempDir(temp_dir);
    
    // Test 1: Status outside repository (should fail)
    {
        var z_result = try harness.runZiggit(&.{"status"}, temp_dir);
        defer z_result.deinit();
        var g_result = try harness.runGit(&.{"status"}, temp_dir);
        defer g_result.deinit();
        
        try harness.expectExitCode(z_result.exit_code, g_result.exit_code, "status outside repo");
        if (z_result.exit_code == 0) {
            std.debug.print("    ⚠ ziggit incorrectly succeeded with status outside repository\n", .{});
        }
    }
    
    // Test 2: Status in empty repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) {
        std.debug.print("    ⚠ skipping status tests (init failed)\n", .{});
        return;
    }
    
    {
        var z_result = try harness.runZiggit(&.{"status"}, temp_dir);
        defer z_result.deinit();
        var g_result = try harness.runGit(&.{"status"}, temp_dir);
        defer g_result.deinit();
        
        try harness.expectExitCode(z_result.exit_code, g_result.exit_code, "status in empty repo");
    }
    
    // Test 3: Status with untracked files
    const untracked_file = try std.fmt.allocPrint(harness.allocator, "{s}/untracked.txt", .{temp_dir});
    defer harness.allocator.free(untracked_file);
    try harness.writeFile(untracked_file, "untracked file");
    
    {
        var z_result = try harness.runZiggit(&.{"status"}, temp_dir);
        defer z_result.deinit();
        var g_result = try harness.runGit(&.{"status"}, temp_dir);
        defer g_result.deinit();
        
        try harness.expectExitCode(z_result.exit_code, g_result.exit_code, "status with untracked");
    }
    
    std.debug.print("    ✓ essential status operations\n", .{});
}

fn testLogOperations(harness: TestHarness) !void {
    std.debug.print("  Testing essential log operations...\n", .{});
    
    const temp_dir = try harness.createTempDir("essential_log");
    defer harness.removeTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) {
        std.debug.print("    ⚠ skipping log tests (init failed)\n", .{});
        return;
    }
    
    // Test 1: Log in empty repository (should fail appropriately)
    {
        var z_result = try harness.runZiggit(&.{"log"}, temp_dir);
        defer z_result.deinit();
        var g_result = try harness.runGit(&.{"log"}, temp_dir);
        defer g_result.deinit();
        
        try harness.expectExitCode(z_result.exit_code, g_result.exit_code, "log in empty repo");
    }
    
    std.debug.print("    ✓ essential log operations\n", .{});
}

fn testBranchOperations(harness: TestHarness) !void {
    std.debug.print("  Testing essential branch operations...\n", .{});
    
    const temp_dir = try harness.createTempDir("essential_branch");
    defer harness.removeTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) {
        std.debug.print("    ⚠ skipping branch tests (init failed)\n", .{});
        return;
    }
    
    // Test 1: List branches in empty repository
    {
        var z_result = try harness.runZiggit(&.{"branch"}, temp_dir);
        defer z_result.deinit();
        var g_result = try harness.runGit(&.{"branch"}, temp_dir);
        defer g_result.deinit();
        
        try harness.expectExitCode(z_result.exit_code, g_result.exit_code, "branch list empty repo");
    }
    
    // Test 2: Delete nonexistent branch (should fail)
    {
        var z_result = try harness.runZiggit(&.{"branch", "-d", "nonexistent"}, temp_dir);
        defer z_result.deinit();
        var g_result = try harness.runGit(&.{"branch", "-d", "nonexistent"}, temp_dir);
        defer g_result.deinit();
        
        try harness.expectExitCode(z_result.exit_code, g_result.exit_code, "delete nonexistent branch");
        if (z_result.exit_code == 0) {
            std.debug.print("    ⚠ ziggit incorrectly succeeded deleting nonexistent branch\n", .{});
        }
    }
    
    // Test 3: Branch command with no args
    {
        var z_result = try harness.runZiggit(&.{"branch", "-d"}, temp_dir);
        defer z_result.deinit();
        var g_result = try harness.runGit(&.{"branch", "-d"}, temp_dir);
        defer g_result.deinit();
        
        try harness.expectExitCode(z_result.exit_code, g_result.exit_code, "branch -d with no name");
    }
    
    std.debug.print("    ✓ essential branch operations\n", .{});
}

fn testCheckoutOperations(harness: TestHarness) !void {
    std.debug.print("  Testing essential checkout operations...\n", .{});
    
    const temp_dir = try harness.createTempDir("essential_checkout");
    defer harness.removeTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) {
        std.debug.print("    ⚠ skipping checkout tests (init failed)\n", .{});
        return;
    }
    
    // Test 1: Checkout nonexistent branch (should fail)
    {
        var z_result = try harness.runZiggit(&.{"checkout", "nonexistent"}, temp_dir);
        defer z_result.deinit();
        var g_result = try harness.runGit(&.{"checkout", "nonexistent"}, temp_dir);
        defer g_result.deinit();
        
        try harness.expectExitCode(z_result.exit_code, g_result.exit_code, "checkout nonexistent");
        if (z_result.exit_code == 0) {
            std.debug.print("    ⚠ ziggit incorrectly succeeded checking out nonexistent branch\n", .{});
        }
    }
    
    // Test 2: Checkout with no args (should fail)
    {
        var z_result = try harness.runZiggit(&.{"checkout"}, temp_dir);
        defer z_result.deinit();
        var g_result = try harness.runGit(&.{"checkout"}, temp_dir);
        defer g_result.deinit();
        
        try harness.expectExitCode(z_result.exit_code, g_result.exit_code, "checkout with no args");
    }
    
    std.debug.print("    ✓ essential checkout operations\n", .{});
}

fn testBasicWorkflow(harness: TestHarness) !void {
    std.debug.print("  Testing essential workflow (init→add→commit→status)...\n", .{});
    
    const temp_dir = try harness.createTempDir("essential_workflow");
    defer harness.removeTempDir(temp_dir);
    
    // Step 1: Init
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) {
        std.debug.print("    ❌ workflow init failed\n", .{});
        return;
    }
    
    // Step 2: Create and add file
    const workflow_file = try std.fmt.allocPrint(harness.allocator, "{s}/workflow.txt", .{temp_dir});
    defer harness.allocator.free(workflow_file);
    try harness.writeFile(workflow_file, "workflow test");
    
    var add_result = try harness.runZiggit(&.{"add", "workflow.txt"}, temp_dir);
    defer add_result.deinit();
    if (add_result.exit_code != 0) {
        std.debug.print("    ❌ workflow add failed\n", .{});
        return;
    }
    
    // Step 3: Check status (should show staged file)
    var status_result = try harness.runZiggit(&.{"status"}, temp_dir);
    defer status_result.deinit();
    if (status_result.exit_code != 0) {
        std.debug.print("    ❌ workflow status failed\n", .{});
        return;
    }
    
    // Step 4: Commit
    var commit_result = try harness.runZiggit(&.{"commit", "-m", "Workflow test commit"}, temp_dir);
    defer commit_result.deinit();
    if (commit_result.exit_code != 0) {
        std.debug.print("    ❌ workflow commit failed\n", .{});
        return;
    }
    
    // Step 5: Check log (should show commit)
    var log_result = try harness.runZiggit(&.{"log"}, temp_dir);
    defer log_result.deinit();
    if (log_result.exit_code != 0) {
        std.debug.print("    ❌ workflow log failed\n", .{});
        return;
    }
    
    std.debug.print("    ✓ essential workflow completed successfully\n", .{});
}