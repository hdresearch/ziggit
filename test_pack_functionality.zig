const std = @import("std");
const objects = @import("src/git/objects.zig");

const TestPlatform = struct {
    const fs = struct {
        fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
        }
        
        fn exists(path: []const u8) !bool {
            std.fs.cwd().access(path, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            return true;
        }
        
        fn writeFile(path: []const u8, content: []const u8) !void {
            return std.fs.cwd().writeFile(.{
                .sub_path = path,
                .data = content,
            });
        }
        
        fn makeDir(path: []const u8) !void {
            return std.fs.cwd().makePath(path);
        }
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const git_dir = "/tmp/test_ziggit/.git";
    const platform_impl = TestPlatform{};
    
    // Get the current commit hash
    const head_content = std.fs.cwd().readFileAlloc(allocator, "/tmp/test_ziggit/.git/HEAD", 1024) catch {
        std.debug.print("Failed to read HEAD\n");
        return;
    };
    defer allocator.free(head_content);
    
    const trimmed_head = std.mem.trim(u8, head_content, " \t\n\r");
    std.debug.print("HEAD content: {s}\n", .{trimmed_head});
    
    if (std.mem.startsWith(u8, trimmed_head, "ref: ")) {
        const ref_path = trimmed_head["ref: ".len..];
        const ref_file_path = try std.fmt.allocPrint(allocator, "/tmp/test_ziggit/.git/{s}", .{ref_path});
        defer allocator.free(ref_file_path);
        
        const ref_content = std.fs.cwd().readFileAlloc(allocator, ref_file_path, 1024) catch {
            std.debug.print("Failed to read ref: {s}\n", .{ref_file_path});
            return;
        };
        defer allocator.free(ref_content);
        
        const commit_hash = std.mem.trim(u8, ref_content, " \t\n\r");
        std.debug.print("Current commit hash: {s}\n", .{commit_hash});
        
        // Now try to load this object using the pack file functionality
        std.debug.print("Attempting to load object from pack files...\n");
        
        const obj = objects.GitObject.load(commit_hash, git_dir, platform_impl, allocator) catch |err| {
            std.debug.print("Failed to load object {s}: {}\n", .{ commit_hash, err });
            return;
        };
        defer obj.deinit(allocator);
        
        std.debug.print("Successfully loaded object!\n");
        std.debug.print("Object type: {s}\n", .{obj.type.toString()});
        std.debug.print("Object data length: {d}\n", .{obj.data.len});
        
        if (obj.type == .commit) {
            std.debug.print("Commit data preview: {s}\n", .{obj.data[0..@min(200, obj.data.len)]});
        }
    }
    
    std.debug.print("Test completed successfully!\n");
}