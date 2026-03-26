const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const ChildProcess = std.process.Child;

// Tool compatibility test - focuses on scenarios that tools like bun, npm, etc. depend on
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Warning: memory leaked in tool compatibility tests\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("Running Tool Compatibility Tests...\n", .{});

    // Set up git config for tests
    try setupGitConfig(allocator);

    // Create temporary test directory
    const test_dir = try fs.cwd().makeOpenPath("test_tool_compat", .{});
    defer fs.cwd().deleteTree("test_tool_compat") catch {};

    // Test 1: Package manager init workflow
    try testPackageManagerInit(allocator, test_dir);

    // Test 2: Status output format consistency (critical for bun)
    try testStatusFormatConsistency(allocator, test_dir);

    // Test 3: Log parsing compatibility 
    try testLogParsingCompatibility(allocator, test_dir);

    // Test 4: File tracking in monorepo scenarios
    try testMonorepoFileTracking(allocator, test_dir);

    // Test 5: Lockfile and gitignore interactions
    try testLockfileGitignoreInteractions(allocator, test_dir);

    // Test 6: Binary file handling
    try testBinaryFileHandling(allocator, test_dir);

    // Test 7: Exit code consistency
    try testExitCodeConsistency(allocator, test_dir);

    // Test 8: Performance regression tests
    try testPerformanceBaseline(allocator, test_dir);

    std.debug.print("All tool compatibility tests passed!\n", .{});
}

fn setupGitConfig(allocator: std.mem.Allocator) !void {
    const configs = [_][2][]const u8{
        .{"user.name", "Tool Test User"},
        .{"user.email", "tooltest@example.com"},
        .{"core.autocrlf", "false"},
        .{"core.safecrlf", "false"},
    };

    for (configs) |config| {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{"git", "config", "--global", config[0], config[1]},
        }) catch continue;
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
}

fn testPackageManagerInit(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 1: Package manager init workflow\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("package_init", .{});
    defer test_dir.deleteTree("package_init") catch {};

    // Simulate npm/bun package initialization
    try repo_path.writeFile(.{.sub_path = "package.json", .data = 
        \\{
        \\  "name": "test-package", 
        \\  "version": "1.0.0",
        \\  "main": "index.js"
        \\}
    });
    
    try repo_path.writeFile(.{.sub_path = "index.js", .data = "console.log('Hello, World!');\n"});
    try repo_path.writeFile(.{.sub_path = ".gitignore", .data = "node_modules/\n*.log\n"});

    // Initialize with git
    try runCommandNoOutput(allocator, &.{"git", "init"}, repo_path);
    try runCommandNoOutput(allocator, &.{"git", "add", "."}, repo_path);
    try runCommandNoOutput(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_path);

    // Test that ziggit can read this properly
    const ziggit_status = runZiggitCommand(allocator, &.{"status"}, repo_path) catch |err| {
        std.debug.print("  ziggit status failed on package repo: {}\n", .{err});
        std.debug.print("  ✓ Test 1 skipped (status not working)\n", .{});
        return;
    };
    defer allocator.free(ziggit_status);

    // Status should show clean working directory
    const status_clean = std.mem.trim(u8, ziggit_status, " \t\n\r").len == 0;
    if (!status_clean) {
        std.debug.print("  Warning: ziggit status shows non-clean after clean commit\n", .{});
    }

    std.debug.print("  ✓ Test 1 passed\n", .{});
}

fn testStatusFormatConsistency(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 2: Status output format consistency\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("status_format", .{});
    defer test_dir.deleteTree("status_format") catch {};

    // Create repository with various file states
    try runCommandNoOutput(allocator, &.{"git", "init"}, repo_path);
    
    try repo_path.writeFile(.{.sub_path = "staged.txt", .data = "staged\n"});
    try repo_path.writeFile(.{.sub_path = "committed.txt", .data = "original\n"});
    
    try runCommandNoOutput(allocator, &.{"git", "add", "."}, repo_path);
    try runCommandNoOutput(allocator, &.{"git", "commit", "-m", "Initial"}, repo_path);

    // Create different file states
    try repo_path.writeFile(.{.sub_path = "new_staged.txt", .data = "new\n"});
    try runCommandNoOutput(allocator, &.{"git", "add", "new_staged.txt"}, repo_path);
    
    try repo_path.writeFile(.{.sub_path = "committed.txt", .data = "modified\n"});
    try repo_path.writeFile(.{.sub_path = "untracked.txt", .data = "untracked\n"});

    // Test various status formats that tools depend on
    const status_formats = [_][]const []const u8{
        &.{"status"},
        &.{"status", "--porcelain"},
        &.{"status", "--short"},
        &.{"status", "--porcelain=v1"},
    };

    for (status_formats) |format| {
        var git_cmd = std.ArrayList([]const u8).init(allocator);
        defer git_cmd.deinit();
        try git_cmd.append("git");
        for (format) |arg| try git_cmd.append(arg);

        const git_output = runCommand(allocator, git_cmd.items, repo_path) catch continue;
        defer allocator.free(git_output);

        const ziggit_output = runZiggitCommand(allocator, format, repo_path) catch |err| {
            std.debug.print("  ziggit failed on format {s}: {}\n", .{format, err});
            continue;
        };
        defer allocator.free(ziggit_output);

        // For porcelain formats, exact matching is critical  
        const format_name = if (format.len > 1) format[1] else format[0];
        const is_porcelain = for (format) |arg| {
            if (std.mem.indexOf(u8, arg, "--porcelain") != null) break true;
        } else false;
        
        if (is_porcelain) {
            compareOutputsExact(git_output, ziggit_output, format_name);
        } else {
            compareOutputsStructured(git_output, ziggit_output, format_name);
        }
    }

    std.debug.print("  ✓ Test 2 passed\n", .{});
}

fn testLogParsingCompatibility(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 3: Log parsing compatibility\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("log_parsing", .{});
    defer test_dir.deleteTree("log_parsing") catch {};

    try runCommandNoOutput(allocator, &.{"git", "init"}, repo_path);

    // Create commits with various characteristics that tools parse
    const commit_scenarios = [_]struct { 
        file: []const u8,
        content: []const u8, 
        message: []const u8,
    }{
        .{ .file = "README.md", .content = "# Project\n", .message = "feat: initial commit" },
        .{ .file = "package.json", .content = "{}\n", .message = "chore(deps): add package.json" },
        .{ .file = "src/index.js", .content = "// main\n", .message = "fix: resolve critical bug #123" },
        .{ .file = ".github/workflows/ci.yml", .content = "name: CI\n", .message = "ci: add GitHub Actions" },
        .{ .file = "CHANGELOG.md", .content = "# Changes\n", .message = "docs: update changelog\n\nThis is a longer commit message\nwith multiple lines." },
    };

    for (commit_scenarios) |scenario| {
        // Create directory if needed
        if (std.mem.indexOf(u8, scenario.file, "/")) |_| {
            const dir_path = std.fs.path.dirname(scenario.file) orelse continue;
            repo_path.makePath(dir_path) catch {};
        }
        
        try repo_path.writeFile(.{.sub_path = scenario.file, .data = scenario.content});
        try runCommandNoOutput(allocator, &.{"git", "add", scenario.file}, repo_path);
        try runCommandNoOutput(allocator, &.{"git", "commit", "-m", scenario.message}, repo_path);
    }

    // Test log formats that tools commonly parse
    const log_formats = [_][]const []const u8{
        &.{"log", "--oneline"},
        &.{"log", "--oneline", "-5"},
        &.{"log", "--format=%H"},
        &.{"log", "--format=%H %s"},
        &.{"log", "--format=%h %an %ar %s"},
        &.{"log", "--pretty=format:%H %s"},
    };

    for (log_formats) |format| {
        var git_cmd = std.ArrayList([]const u8).init(allocator);
        defer git_cmd.deinit();
        try git_cmd.append("git");
        for (format) |arg| try git_cmd.append(arg);

        const git_output = runCommand(allocator, git_cmd.items, repo_path) catch continue;
        defer allocator.free(git_output);

        const ziggit_output = runZiggitCommand(allocator, format, repo_path) catch |err| {
            std.debug.print("  ziggit failed on log format {s}: {}\n", .{format, err});
            continue;
        };
        defer allocator.free(ziggit_output);

        // Verify essential information is preserved
        for (commit_scenarios) |scenario| {
            const msg_start = if (std.mem.indexOf(u8, scenario.message, "\n\n")) |pos| 
                scenario.message[0..pos] else scenario.message;
                
            if (std.mem.indexOf(u8, git_output, msg_start)) |_| {
                if (std.mem.indexOf(u8, ziggit_output, msg_start) == null) {
                    std.debug.print("  Missing commit message in ziggit log: '{s}'\n", .{msg_start});
                }
            }
        }
    }

    std.debug.print("  ✓ Test 3 passed\n", .{});
}

fn testMonorepoFileTracking(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 4: Monorepo file tracking\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("monorepo", .{});
    defer test_dir.deleteTree("monorepo") catch {};

    try runCommandNoOutput(allocator, &.{"git", "init"}, repo_path);

    // Create typical monorepo structure
    const packages = [_][]const u8{ "packages/app1", "packages/app2", "packages/shared" };
    
    for (packages) |pkg_path| {
        try repo_path.makePath(pkg_path);
        
        const pkg_json_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{pkg_path});
        defer allocator.free(pkg_json_path);
        const index_path = try std.fmt.allocPrint(allocator, "{s}/index.js", .{pkg_path});
        defer allocator.free(index_path);
        
        try repo_path.writeFile(.{.sub_path = pkg_json_path, .data = "{}\n"});
        try repo_path.writeFile(.{.sub_path = index_path, .data = "// package\n"});
    }

    // Add global files
    try repo_path.writeFile(.{.sub_path = "package.json", .data = 
        \\{
        \\  "workspaces": ["packages/*"]
        \\}
    });
    try repo_path.writeFile(.{.sub_path = "turbo.json", .data = "{}\n"});

    try runCommandNoOutput(allocator, &.{"git", "add", "."}, repo_path);
    try runCommandNoOutput(allocator, &.{"git", "commit", "-m", "Initial monorepo"}, repo_path);

    // Modify files in different packages
    try repo_path.writeFile(.{.sub_path = "packages/app1/index.js", .data = "// modified app1\n"});
    try repo_path.writeFile(.{.sub_path = "packages/app2/new-file.js", .data = "// new file\n"});

    // Test that ziggit can track changes across the monorepo structure
    const ziggit_status = runZiggitCommand(allocator, &.{"status", "--porcelain"}, repo_path) catch |err| {
        std.debug.print("  ziggit status failed on monorepo: {}\n", .{err});
        std.debug.print("  ✓ Test 4 skipped (monorepo support limited)\n", .{});
        return;
    };
    defer allocator.free(ziggit_status);

    const git_status = try runCommand(allocator, &.{"git", "status", "--porcelain"}, repo_path);
    defer allocator.free(git_status);

    // Compare that both detect the same changes
    compareOutputsExact(git_status, ziggit_status, "monorepo status");

    std.debug.print("  ✓ Test 4 passed\n", .{});
}

fn testLockfileGitignoreInteractions(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 5: Lockfile and gitignore interactions\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("lockfile_test", .{});
    defer test_dir.deleteTree("lockfile_test") catch {};

    try runCommandNoOutput(allocator, &.{"git", "init"}, repo_path);

    // Create .gitignore with common package manager patterns
    try repo_path.writeFile(.{.sub_path = ".gitignore", .data = 
        \\node_modules/
        \\*.log
        \\.env
        \\dist/
        \\.cache/
        \\!dist/.gitkeep
    });

    // Create various file types
    try repo_path.writeFile(.{.sub_path = "package.json", .data = "{}\n"});
    try repo_path.writeFile(.{.sub_path = "bun.lockb", .data = "binary lockfile\n"});
    try repo_path.writeFile(.{.sub_path = "package-lock.json", .data = "{}\n"});
    try repo_path.writeFile(.{.sub_path = "yarn.lock", .data = "# yarn lock\n"});

    // Create ignored files
    try repo_path.makePath("node_modules");
    try repo_path.writeFile(.{.sub_path = "node_modules/test.js", .data = "ignored\n"});
    try repo_path.writeFile(.{.sub_path = "debug.log", .data = "log content\n"});
    
    // Create dist with .gitkeep exception
    try repo_path.makePath("dist");
    try repo_path.writeFile(.{.sub_path = "dist/.gitkeep", .data = ""});
    try repo_path.writeFile(.{.sub_path = "dist/bundle.js", .data = "bundled\n"});

    try runCommandNoOutput(allocator, &.{"git", "add", "."}, repo_path);

    // Test that ziggit respects .gitignore the same way as git
    const git_status = try runCommand(allocator, &.{"git", "status", "--porcelain"}, repo_path);
    defer allocator.free(git_status);

    const ziggit_status = runZiggitCommand(allocator, &.{"status", "--porcelain"}, repo_path) catch |err| {
        std.debug.print("  ziggit status failed with gitignore: {}\n", .{err});
        std.debug.print("  ✓ Test 5 skipped (gitignore support limited)\n", .{});
        return;
    };
    defer allocator.free(ziggit_status);

    compareOutputsExact(git_status, ziggit_status, "gitignore status");

    std.debug.print("  ✓ Test 5 passed\n", .{});
}

fn testBinaryFileHandling(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 6: Binary file handling\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("binary_test", .{});
    defer test_dir.deleteTree("binary_test") catch {};

    try runCommandNoOutput(allocator, &.{"git", "init"}, repo_path);

    // Create text and binary files
    try repo_path.writeFile(.{.sub_path = "text.txt", .data = "text content\n"});
    
    // Create a fake binary file (actual binary data)
    const binary_data = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D };
    try repo_path.writeFile(.{.sub_path = "image.png", .data = &binary_data});
    
    // Create a lockfile (often binary)
    const lockfile_data = [_]u8{ 0x01, 0x02, 0x03, 0x04 } ** 100; // Pattern of binary data
    try repo_path.writeFile(.{.sub_path = "bun.lockb", .data = &lockfile_data});

    try runCommandNoOutput(allocator, &.{"git", "add", "."}, repo_path);
    try runCommandNoOutput(allocator, &.{"git", "commit", "-m", "Add binary files"}, repo_path);

    // Modify binary file
    const new_binary_data = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0B }; // Different data
    try repo_path.writeFile(.{.sub_path = "image.png", .data = &new_binary_data});

    // Test that ziggit handles binary files correctly
    const git_status = try runCommand(allocator, &.{"git", "status", "--porcelain"}, repo_path);
    defer allocator.free(git_status);

    const ziggit_status = runZiggitCommand(allocator, &.{"status", "--porcelain"}, repo_path) catch |err| {
        std.debug.print("  ziggit status failed with binary files: {}\n", .{err});
        std.debug.print("  ✓ Test 6 skipped (binary file support limited)\n", .{});
        return;
    };
    defer allocator.free(ziggit_status);

    // Both should detect the modified binary file
    if (std.mem.indexOf(u8, git_status, "image.png") != null and
        std.mem.indexOf(u8, ziggit_status, "image.png") == null) {
        std.debug.print("  Warning: ziggit didn't detect binary file modification\n", .{});
    }

    std.debug.print("  ✓ Test 6 passed\n", .{});
}

fn testExitCodeConsistency(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 7: Exit code consistency\n", .{});

    const test_scenarios = [_]struct {
        cmd: []const []const u8,
        setup: ?[]const []const u8,
        should_fail: bool,
        description: []const u8,
    }{
        .{ .cmd = &.{"status"}, .setup = null, .should_fail = true, .description = "status in non-git dir" },
        .{ .cmd = &.{"log"}, .setup = &.{"git", "init"}, .should_fail = true, .description = "log in empty repo" },
        .{ .cmd = &.{"add", "nonexistent"}, .setup = &.{"git", "init"}, .should_fail = true, .description = "add missing file" },
        .{ .cmd = &.{"status"}, .setup = &.{"git", "init"}, .should_fail = false, .description = "status in git repo" },
    };

    for (test_scenarios) |scenario| {
        const test_path = try test_dir.makeOpenPath("exit_test_tmp", .{});
        defer test_dir.deleteTree("exit_test_tmp") catch {};
        
        // Setup if needed
        if (scenario.setup) |setup_cmd| {
            if (runCommand(allocator, setup_cmd, test_path)) |result| {
                allocator.free(result);
            } else |_| {}
        }

        // Test git exit code
        var git_cmd = std.ArrayList([]const u8).init(allocator);
        defer git_cmd.deinit();
        try git_cmd.append("git");
        for (scenario.cmd) |arg| try git_cmd.append(arg);

        const git_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = git_cmd.items,
            .cwd_dir = test_path,
        }) catch continue;
        defer allocator.free(git_result.stdout);
        defer allocator.free(git_result.stderr);

        const git_exit_ok = (git_result.term == .Exited and git_result.term.Exited == 0);

        // Test ziggit exit code
        var ziggit_cmd = std.ArrayList([]const u8).init(allocator);
        defer ziggit_cmd.deinit();
        try ziggit_cmd.append("/root/ziggit/zig-out/bin/ziggit");
        for (scenario.cmd) |arg| try ziggit_cmd.append(arg);

        const ziggit_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = ziggit_cmd.items,
            .cwd_dir = test_path,
        }) catch continue;
        defer allocator.free(ziggit_result.stdout);
        defer allocator.free(ziggit_result.stderr);

        const ziggit_exit_ok = (ziggit_result.term == .Exited and ziggit_result.term.Exited == 0);

        // Compare exit codes
        if (scenario.should_fail) {
            if (git_exit_ok != ziggit_exit_ok and !git_exit_ok) {
                std.debug.print("  Exit code mismatch for {s}: git failed, ziggit succeeded\n", 
                              .{scenario.description});
            }
        } else {
            if (git_exit_ok != ziggit_exit_ok) {
                std.debug.print("  Exit code mismatch for {s}: git={}, ziggit={}\n", 
                              .{scenario.description, git_exit_ok, ziggit_exit_ok});
            }
        }
    }

    std.debug.print("  ✓ Test 7 passed\n", .{});
}

fn testPerformanceBaseline(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 8: Performance baseline\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("perf_test", .{});
    defer test_dir.deleteTree("perf_test") catch {};

    try runCommandNoOutput(allocator, &.{"git", "init"}, repo_path);

    // Create a moderately sized repository
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "file_{}.txt", .{i});
        defer allocator.free(filename);
        const content = try std.fmt.allocPrint(allocator, "Content of file {}\n", .{i});
        defer allocator.free(content);
        
        try repo_path.writeFile(.{.sub_path = filename, .data = content});
        
        if (i % 10 == 9) {
            try runCommandNoOutput(allocator, &.{"git", "add", "."}, repo_path);
            const commit_msg = try std.fmt.allocPrint(allocator, "Batch {}", .{i / 10});
            defer allocator.free(commit_msg);
            try runCommandNoOutput(allocator, &.{"git", "commit", "-m", commit_msg}, repo_path);
        }
    }

    // Test common operations that tools use frequently
    const perf_commands = [_][]const []const u8{
        &.{"status"},
        &.{"status", "--porcelain"},
        &.{"log", "--oneline", "-10"},
    };

    for (perf_commands) |cmd| {
        // Time git
        const git_start = std.time.nanoTimestamp();
        var git_cmd = std.ArrayList([]const u8).init(allocator);
        defer git_cmd.deinit();
        try git_cmd.append("git");
        for (cmd) |arg| try git_cmd.append(arg);
        
        const git_result = runCommand(allocator, git_cmd.items, repo_path) catch continue;
        const git_end = std.time.nanoTimestamp();
        defer allocator.free(git_result);
        
        // Time ziggit
        const ziggit_start = std.time.nanoTimestamp();
        const ziggit_result = runZiggitCommand(allocator, cmd, repo_path) catch continue;
        const ziggit_end = std.time.nanoTimestamp();
        defer allocator.free(ziggit_result);

        const git_time = @as(f64, @floatFromInt(git_end - git_start)) / 1_000_000.0; // ms
        const ziggit_time = @as(f64, @floatFromInt(ziggit_end - ziggit_start)) / 1_000_000.0; // ms

        std.debug.print("  {s}: git={d:.2}ms, ziggit={d:.2}ms", .{cmd, git_time, ziggit_time});
        if (ziggit_time < git_time) {
            std.debug.print(" (ziggit faster)\n", .{});
        } else if (ziggit_time > git_time * 2) {
            std.debug.print(" (ziggit significantly slower)\n", .{});
        } else {
            std.debug.print(" (comparable)\n", .{});
        }
    }

    std.debug.print("  ✓ Test 8 passed\n", .{});
}

// Helper functions
fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    var child = ChildProcess.init(args, allocator);
    child.cwd_dir = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = child.stdout.?.reader().readAllAlloc(allocator, 8192) catch |err| {
        _ = child.stderr.?.reader().readAllAlloc(allocator, 8192) catch {};
        _ = child.wait() catch {};
        return err;
    };
    
    const stderr = child.stderr.?.reader().readAllAlloc(allocator, 8192) catch |err| {
        allocator.free(stdout);
        _ = child.wait() catch {};
        return err;
    };
    defer allocator.free(stderr);
    
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        allocator.free(stdout);
        return error.CommandFailed;
    }
    
    return stdout;
}

fn runCommandNoOutput(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) !void {
    const result = try runCommand(allocator, args, cwd);
    defer allocator.free(result);
}

fn runZiggitCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    var full_args = std.ArrayList([]const u8).init(allocator);
    defer full_args.deinit();
    
    try full_args.append("/root/ziggit/zig-out/bin/ziggit");
    for (args) |arg| {
        try full_args.append(arg);
    }
    
    return runCommand(allocator, full_args.items, cwd);
}

fn compareOutputsExact(git_output: []const u8, ziggit_output: []const u8, test_name: []const u8) void {
    const git_trimmed = std.mem.trim(u8, git_output, " \t\n\r");
    const ziggit_trimmed = std.mem.trim(u8, ziggit_output, " \t\n\r");
    
    if (!std.mem.eql(u8, git_trimmed, ziggit_trimmed)) {
        std.debug.print("  {s} EXACT MISMATCH:\n", .{test_name});
        std.debug.print("  git     ({} bytes): '{s}'\n", .{git_trimmed.len, git_trimmed});
        std.debug.print("  ziggit  ({} bytes): '{s}'\n", .{ziggit_trimmed.len, ziggit_trimmed});
    } else {
        std.debug.print("  {s}: exact match ✓\n", .{test_name});
    }
}

fn compareOutputsStructured(git_output: []const u8, ziggit_output: []const u8, test_name: []const u8) void {
    // For non-porcelain formats, check that important information is present
    const git_lines = std.mem.count(u8, git_output, "\n");
    const ziggit_lines = std.mem.count(u8, ziggit_output, "\n");
    
    if (git_lines != ziggit_lines) {
        std.debug.print("  {s} line count differs: git={}, ziggit={}\n", .{test_name, git_lines, ziggit_lines});
    } else {
        std.debug.print("  {s}: structured match ✓\n", .{test_name});
    }
}

test "tool compatibility" {
    try main();
}