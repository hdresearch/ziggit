// Debug if there's index corruption with multiple files
const std = @import("std");
const Repository = @import("ziggit").Repository;
const index_parser = @import("../src/lib/index_parser.zig");

const TEST_REPO_PATH = "/tmp/ziggit_debug_index";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("=== DEBUG INDEX CORRUPTION ===\n", .{});
    
    // Clean up any existing repo
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    // Create new repo
    std.fs.makeDirAbsolute(TEST_REPO_PATH) catch {};
    var repo = try Repository.init(allocator, TEST_REPO_PATH);
    defer repo.close();
    
    const index_path = try std.fmt.allocPrint(allocator, "{s}/.git/index", .{TEST_REPO_PATH});
    defer allocator.free(index_path);
    
    // Add files one by one and check index after each addition
    std.debug.print("Adding files one by one and checking index...\n", .{});
    
    const test_counts = [_]u32{1, 5, 10, 20, 50, 100};
    
    for (test_counts) |count| {
        // Reset repo
        std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
        std.fs.makeDirAbsolute(TEST_REPO_PATH) catch {};
        repo = try Repository.init(allocator, TEST_REPO_PATH);
        
        std.debug.print("\n--- Testing with {} files ---\n", .{count});
        
        // Add files
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const filename = try std.fmt.allocPrint(allocator, "file{d}.txt", .{i});
            defer allocator.free(filename);
            
            const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{TEST_REPO_PATH, filename});
            defer allocator.free(filepath);
            
            const file = try std.fs.createFileAbsolute(filepath, .{ .truncate = true });
            defer file.close();
            
            const content = try std.fmt.allocPrint(allocator, "Content {d}\n", .{i});
            defer allocator.free(content);
            
            try file.writeAll(content);
            try repo.add(filename);
        }
        
        // Check index file
        if (std.fs.openFileAbsolute(index_path, .{})) |index_file| {
            defer index_file.close();
            const index_stat = try index_file.stat();
            std.debug.print("Index file size: {} bytes\n", .{index_stat.size});
        } else |err| {
            std.debug.print("Error opening index file: {}\n", .{err});
            continue;
        }
        
        // Try to read and parse the index
        var git_index = index_parser.GitIndex.readFromFile(allocator, index_path) catch |err| {
            std.debug.print("ERROR: Failed to parse index: {}\n", .{err});
            continue;
        };
        defer git_index.deinit();
        
        std.debug.print("Index parsed successfully, entries: {}\n", .{git_index.entries.items.len});
        
        if (git_index.entries.items.len != count) {
            std.debug.print("ERROR: Expected {} entries, got {}\n", .{count, git_index.entries.items.len});
        } else {
            std.debug.print("SUCCESS: All {} entries found in index\n", .{count});
        }
        
        // Check first and last entries
        if (git_index.entries.items.len > 0) {
            const first_entry = git_index.entries.items[0];
            std.debug.print("First entry: {s}\n", .{first_entry.path});
            
            if (git_index.entries.items.len > 1) {
                const last_entry = git_index.entries.items[git_index.entries.items.len - 1];
                std.debug.print("Last entry: {s}\n", .{last_entry.path});
            }
        }
        
        // Test status  
        const status = repo.statusPorcelain(allocator) catch |err| {
            std.debug.print("ERROR: Status failed: {}\n", .{err});
            continue;
        };
        defer allocator.free(status);
        
        std.debug.print("Status length: {} bytes\n", .{status.len});
        if (status.len > 0) {
            std.debug.print("Status not clean - files still untracked!\n", .{});
        } else {
            std.debug.print("Status clean - all files tracked!\n", .{});
        }
    }
    
    // Cleanup
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    std.debug.print("\nDebug completed!\n", .{});
}