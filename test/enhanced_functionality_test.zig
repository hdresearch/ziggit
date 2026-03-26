const std = @import("std");
const objects = @import("../src/git/objects.zig");
const index_mod = @import("../src/git/index.zig");

// Platform implementation for testing
const TestPlatform = struct {
    pub const fs = struct {
        pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
        }
        
        pub fn writeFile(path: []const u8, content: []const u8) !void {
            return std.fs.cwd().writeFile(path, content);
        }
        
        pub fn exists(path: []const u8) bool {
            const file = std.fs.cwd().openFile(path, .{}) catch return false;
            defer file.close();
            return true;
        }
    };
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    std.debug.print("Testing enhanced git format functionality...\n", .{});
    
    // Test 1: Pack file access verification
    std.debug.print("\n1. Testing pack file access verification:\n", .{});
    if (objects.verifyPackFileAccess(".git", TestPlatform, allocator)) |has_access| {
        if (has_access) {
            std.debug.print("✅ Pack files are accessible and functional\n", .{});
        } else {
            std.debug.print("⚠️  No functional pack files found\n", .{});
        }
    } else |err| {
        std.debug.print("❌ Error checking pack file access: {}\n", .{err});
    }
    
    // Test 2: Repository pack health check
    std.debug.print("\n2. Testing repository pack health check:\n", .{});
    if (objects.checkRepositoryPackHealth(".git", TestPlatform, allocator)) |health| {
        defer health.deinit();
        health.print();
        
        if (health.isHealthy()) {
            std.debug.print("✅ Repository pack files are healthy\n", .{});
        } else {
            std.debug.print("⚠️  Some pack file issues detected\n", .{});
        }
    } else |err| {
        std.debug.print("❌ Error checking repository health: {}\n", .{err});
    }
    
    // Test 3: Index extension analysis
    std.debug.print("\n3. Testing index extension analysis:\n", .{});
    if (index_mod.analyzeIndexExtensions(".git", TestPlatform, allocator)) |analysis| {
        defer analysis.deinit();
        analysis.print();
        
        if (analysis.hasPerformanceOptimizations()) {
            std.debug.print("✅ Index has performance optimizations enabled\n", .{});
        } else {
            std.debug.print("ℹ️  Index has no performance optimizations\n", .{});
        }
    } else |err| {
        std.debug.print("❌ Error analyzing index extensions: {}\n", .{err});
    }
    
    std.debug.print("\n✅ Enhanced functionality test completed!\n", .{});
}