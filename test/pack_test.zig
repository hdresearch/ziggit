const std = @import("std");
const objects = @import("../src/git/objects.zig");

// Simple platform implementation for testing
const TestPlatform = struct {
    const Self = @This();

    const TestFs = struct {
        fn readFile(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024);
        }

        fn writeFile(file_path: []const u8, content: []const u8) !void {
            try std.fs.cwd().writeFile(file_path, content);
        }

        fn makeDir(dir_path: []const u8) !void {
            try std.fs.cwd().makePath(dir_path);
        }

        fn exists(file_path: []const u8) !bool {
            std.fs.cwd().access(file_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            return true;
        }
    };

    const fs = TestFs{};
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const platform = TestPlatform{};
    
    // Test pack file reading
    std.debug.print("Testing pack file reading...\n");
    
    // First, let's see what objects exist in the test repo
    const git_dir = "/tmp/test_repo/.git";
    
    // Try to list pack files
    const pack_dir = "/tmp/test_repo/.git/objects/pack";
    var pack_dir_handle = std.fs.cwd().openDir(pack_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("Error opening pack dir: {}\n", .{err});
        return;
    };
    defer pack_dir_handle.close();
    
    var iterator = pack_dir_handle.iterate();
    var pack_found = false;
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            std.debug.print("Found pack file: {s}\n", .{entry.name});
            pack_found = true;
        }
        if (std.mem.endsWith(u8, entry.name, ".idx")) {
            std.debug.print("Found index file: {s}\n", .{entry.name});
        }
    }
    
    if (!pack_found) {
        std.debug.print("No pack files found. Creating a test repository first...\n");
        return;
    }
    
    // Try to get the HEAD commit
    std.debug.print("Getting HEAD commit...\n");
    const head_path = "/tmp/test_repo/.git/refs/heads/master";
    const head_content = std.fs.cwd().readFileAlloc(allocator, head_path, 1024) catch |err| {
        std.debug.print("Error reading HEAD: {}\n", .{err});
        return;
    };
    defer allocator.free(head_content);
    
    const head_hash = std.mem.trim(u8, head_content, " \t\n\r");
    std.debug.print("HEAD commit hash: {s}\n", .{head_hash});
    
    // Try to load this commit object
    std.debug.print("Loading commit object from pack files...\n");
    const commit_obj = objects.GitObject.load(head_hash, git_dir, platform, allocator) catch |err| {
        std.debug.print("Error loading commit object: {}\n", .{err});
        return;
    };
    defer commit_obj.deinit(allocator);
    
    std.debug.print("Successfully loaded commit object!\n");
    std.debug.print("Type: {s}\n", .{commit_obj.type.toString()});
    std.debug.print("Data length: {}\n", .{commit_obj.data.len});
    
    // Parse the commit to get the tree hash
    const commit_content = commit_obj.data;
    if (std.mem.indexOf(u8, commit_content, "\n")) |first_newline| {
        const first_line = commit_content[0..first_newline];
        if (std.mem.startsWith(u8, first_line, "tree ")) {
            const tree_hash = first_line["tree ".len..];
            std.debug.print("Tree hash: {s}\n", .{tree_hash});
            
            // Try to load the tree object
            std.debug.print("Loading tree object from pack files...\n");
            const tree_obj = objects.GitObject.load(tree_hash, git_dir, platform, allocator) catch |err| {
                std.debug.print("Error loading tree object: {}\n", .{err});
                return;
            };
            defer tree_obj.deinit(allocator);
            
            std.debug.print("Successfully loaded tree object!\n");
            std.debug.print("Type: {s}\n", .{tree_obj.type.toString()});
            std.debug.print("Data length: {}\n", .{tree_obj.data.len});
        }
    }
    
    std.debug.print("Pack file reading test completed successfully!\n");
}