const std = @import("std");
const print = std.log.info;

const Timer = std.time.Timer;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

// Helper function to run shell commands
fn runCommand(argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const term = try child.wait();

    switch (term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

// Test initialization performance
fn benchmark_init() !void {
    print("=== Repository Initialization Benchmark ===\n", .{});
    
    const iterations = 10;
    var git_total: u64 = 0;
    var ziggit_total: u64 = 0;
    var git_success: u32 = 0;
    var ziggit_success: u32 = 0;
    
    // Git CLI benchmark
    for (0..iterations) |i| {
        const dir_name = try std.fmt.allocPrint(allocator, "test-git-{d}", .{i});
        defer allocator.free(dir_name);
        
        std.fs.cwd().deleteTree(dir_name) catch {};
        
        var timer = Timer.start() catch continue;
        
        runCommand(&[_][]const u8{ "git", "init", dir_name }) catch {
            git_total += timer.read();
            std.fs.cwd().deleteTree(dir_name) catch {};
            continue;
        };
        
        git_total += timer.read();
        git_success += 1;
        
        std.fs.cwd().deleteTree(dir_name) catch {};
    }
    
    // ziggit CLI benchmark  
    for (0..iterations) |i| {
        const dir_name = try std.fmt.allocPrint(allocator, "test-ziggit-{d}", .{i});
        defer allocator.free(dir_name);
        
        std.fs.cwd().deleteTree(dir_name) catch {};
        
        var timer = Timer.start() catch continue;
        
        runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "init", dir_name }) catch {
            ziggit_total += timer.read();
            std.fs.cwd().deleteTree(dir_name) catch {};
            continue;
        };
        
        ziggit_total += timer.read();
        ziggit_success += 1;
        
        std.fs.cwd().deleteTree(dir_name) catch {};
    }
    
    print("Results ({d} iterations):\n", .{iterations});
    
    if (git_success > 0) {
        print("Git CLI:    Avg {d:.2}ms (success: {d}/{d})\n", .{ 
            @as(f64, @floatFromInt(git_total)) / @as(f64, @floatFromInt(git_success)) / 1_000_000.0,
            git_success, 
            iterations 
        });
    }
    
    if (ziggit_success > 0) {
        print("ziggit CLI: Avg {d:.2}ms (success: {d}/{d})\n", .{ 
            @as(f64, @floatFromInt(ziggit_total)) / @as(f64, @floatFromInt(ziggit_success)) / 1_000_000.0,
            ziggit_success, 
            iterations 
        });
        
        if (git_success > 0) {
            const git_avg = @as(f64, @floatFromInt(git_total)) / @as(f64, @floatFromInt(git_success));
            const ziggit_avg = @as(f64, @floatFromInt(ziggit_total)) / @as(f64, @floatFromInt(ziggit_success));
            const speedup = git_avg / ziggit_avg;
            print("Speedup: {d:.1}x\n", .{speedup});
        }
    }
    print("\n", .{});
}

// Test status performance
fn benchmark_status() !void {
    print("=== Repository Status Benchmark ===\n", .{});
    
    // Setup test repository
    std.fs.cwd().deleteTree("status-test") catch {};
    try runCommand(&[_][]const u8{ "git", "init", "status-test" });
    defer std.fs.cwd().deleteTree("status-test") catch {};
    
    // Create a test file
    {
        var file = try std.fs.cwd().createFile("status-test/test.txt", .{});
        defer file.close();
        _ = try file.writeAll("test content");
    }
    
    const iterations = 50;
    var git_total: u64 = 0;
    var ziggit_total: u64 = 0;
    var git_success: u32 = 0;
    var ziggit_success: u32 = 0;
    
    // Git CLI benchmark
    for (0..iterations) |_| {
        var timer = Timer.start() catch continue;
        
        runCommand(&[_][]const u8{ "git", "-C", "status-test", "status", "--porcelain" }) catch {
            git_total += timer.read();
            continue;
        };
        
        git_total += timer.read();
        git_success += 1;
    }
    
    // ziggit CLI benchmark
    for (0..iterations) |_| {
        var timer = Timer.start() catch continue;
        
        runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "-C", "status-test", "status" }) catch {
            ziggit_total += timer.read();
            continue;
        };
        
        ziggit_total += timer.read();
        ziggit_success += 1;
    }
    
    print("Results ({d} iterations):\n", .{iterations});
    
    if (git_success > 0) {
        print("Git CLI:    Avg {d:.2}ms (success: {d}/{d})\n", .{ 
            @as(f64, @floatFromInt(git_total)) / @as(f64, @floatFromInt(git_success)) / 1_000_000.0,
            git_success, 
            iterations 
        });
    }
    
    if (ziggit_success > 0) {
        print("ziggit CLI: Avg {d:.2}ms (success: {d}/{d})\n", .{ 
            @as(f64, @floatFromInt(ziggit_total)) / @as(f64, @floatFromInt(ziggit_success)) / 1_000_000.0,
            ziggit_success, 
            iterations 
        });
        
        if (git_success > 0) {
            const git_avg = @as(f64, @floatFromInt(git_total)) / @as(f64, @floatFromInt(git_success));
            const ziggit_avg = @as(f64, @floatFromInt(ziggit_total)) / @as(f64, @floatFromInt(ziggit_success));
            const speedup = git_avg / ziggit_avg;
            print("Speedup: {d:.1}x\n", .{speedup});
        }
    }
    print("\n", .{});
}

pub fn main() !void {
    defer _ = gpa.deinit();
    
    print("=== Simple ziggit vs Git CLI Benchmark ===", .{});
    
    // Build ziggit first
    print("Building ziggit...\n", .{});
    runCommand(&[_][]const u8{ "zig", "build" }) catch {
        print("Failed to build ziggit. Make sure you're running from ziggit root directory.\n", .{});
        return;
    };
    print("Build complete.\n\n", .{});
    
    try benchmark_init();
    try benchmark_status();
    
    print("=== Summary ===\n", .{});
    print("This benchmark compares ziggit CLI vs git CLI performance.\n", .{});
    print("For library integration, ziggit would show even better performance\n", .{});
    print("by eliminating subprocess overhead entirely.\n", .{});
}