const std = @import("std");
const objects = @import("src/git/objects.zig");

// Simple platform implementation for testing
const TestPlatform = struct {
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

        fn readDir(allocator: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
            var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
            defer dir.close();
            
            var entries = std.ArrayList([]u8).init(allocator);
            var iterator = dir.iterate();
            
            while (try iterator.next()) |entry| {
                try entries.append(try allocator.dupe(u8, entry.name));
            }
            
            return try entries.toOwnedSlice();
        }
    };

    const fs = TestFs{};
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const platform = TestPlatform{};
    
    std.debug.print("=== Testing Pack File Reading ===\n");
    
    const git_dir = "/tmp/test_pack_repo/.git";
    
    // Get the current commit hash from HEAD
    const head_path = "/tmp/test_pack_repo/.git/refs/heads/master";
    const head_content = std.fs.cwd().readFileAlloc(allocator, head_path, 1024) catch |err| {
        std.debug.print("Error reading HEAD: {}\n", .{err});
        std.debug.print("Make sure you created the test repo first with:\n");
        std.debug.print("cd /tmp && rm -rf test_pack_repo && git init test_pack_repo\n");
        std.debug.print("cd test_pack_repo && echo 'Hello pack test' > README.md\n");
        std.debug.print("git add README.md && git -c user.name='Test' -c user.email='test@example.com' commit -m 'Initial commit'\n");
        std.debug.print("git gc --aggressive\n");
        return;
    };
    defer allocator.free(head_content);
    
    const head_hash = std.mem.trim(u8, head_content, " \t\n\r");
    std.debug.print("HEAD commit hash: {s}\n", .{head_hash});
    
    // First verify if the object exists as loose object
    const loose_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}/{s}", .{ git_dir, head_hash[0..2], head_hash[2..] });
    defer allocator.free(loose_path);
    
    const has_loose = std.fs.cwd().access(loose_path, .{}) catch |_| false;
    std.debug.print("Has loose object: {}\n", .{has_loose});
    
    // List pack files
    const pack_dir = "/tmp/test_pack_repo/.git/objects/pack";
    var pack_dir_handle = std.fs.cwd().openDir(pack_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("Error opening pack dir: {}\n", .{err});
        return;
    };
    defer pack_dir_handle.close();
    
    std.debug.print("Pack files:\n");
    var iterator = pack_dir_handle.iterate();
    var pack_found = false;
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        std.debug.print("  {s}\n", .{entry.name});
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_found = true;
        }
    }
    
    if (!pack_found) {
        std.debug.print("No pack files found!\n");
        return;
    }
    
    // Try to load the commit object (should go through pack files if it's not loose)
    std.debug.print("\nLoading commit object...\n");
    const commit_obj = objects.GitObject.load(head_hash, git_dir, platform, allocator) catch |err| {
        std.debug.print("Error loading commit object: {}\n", .{err});
        return;
    };
    defer commit_obj.deinit(allocator);
    
    std.debug.print("✓ Successfully loaded commit object from packs!\n");
    std.debug.print("  Type: {s}\n", .{commit_obj.type.toString()});
    std.debug.print("  Data length: {} bytes\n", .{commit_obj.data.len});
    
    // Parse the commit to get the tree hash
    const commit_content = commit_obj.data;
    std.debug.print("  Commit content preview: {s}\n", .{commit_content[0..@min(100, commit_content.len)]});
    
    if (std.mem.indexOf(u8, commit_content, "\n")) |first_newline| {
        const first_line = commit_content[0..first_newline];
        if (std.mem.startsWith(u8, first_line, "tree ")) {
            const tree_hash = first_line["tree ".len..];
            std.debug.print("  Tree hash: {s}\n", .{tree_hash});
            
            // Try to load the tree object
            std.debug.print("\nLoading tree object...\n");
            const tree_obj = objects.GitObject.load(tree_hash, git_dir, platform, allocator) catch |err| {
                std.debug.print("Error loading tree object: {}\n", .{err});
                return;
            };
            defer tree_obj.deinit(allocator);
            
            std.debug.print("✓ Successfully loaded tree object from packs!\n");
            std.debug.print("  Type: {s}\n", .{tree_obj.type.toString()});
            std.debug.print("  Data length: {} bytes\n", .{tree_obj.data.len});
            
            // Try to parse a tree entry to get blob hash
            const tree_data = tree_obj.data;
            if (tree_data.len > 0) {
                // Tree format: "<mode> <filename>\0<20-byte hash>"
                var pos: usize = 0;
                while (pos < tree_data.len) {
                    // Find the null terminator
                    const null_pos = std.mem.indexOfPos(u8, tree_data, pos, "\x00");
                    if (null_pos == null) break;
                    
                    const entry_text = tree_data[pos..null_pos.?];
                    if (std.mem.indexOf(u8, entry_text, " ")) |space_pos| {
                        const mode = entry_text[0..space_pos];
                        const filename = entry_text[space_pos + 1..];
                        
                        // Get the 20-byte hash
                        if (null_pos.? + 21 <= tree_data.len) {
                            const hash_bytes = tree_data[null_pos.? + 1..null_pos.? + 21];
                            
                            // Convert to hex string
                            var hash_str = try allocator.alloc(u8, 40);
                            defer allocator.free(hash_str);
                            _ = try std.fmt.bufPrint(hash_str, "{}", .{std.fmt.fmtSliceHexLower(hash_bytes)});
                            
                            std.debug.print("  Tree entry: mode={s}, filename={s}, hash={s}\n", .{ mode, filename, hash_str });
                            
                            // Try to load this blob object
                            std.debug.print("\nLoading blob object...\n");
                            const blob_obj = objects.GitObject.load(hash_str, git_dir, platform, allocator) catch |err| {
                                std.debug.print("Error loading blob object: {}\n", .{err});
                                break;
                            };
                            defer blob_obj.deinit(allocator);
                            
                            std.debug.print("✓ Successfully loaded blob object from packs!\n");
                            std.debug.print("  Type: {s}\n", .{blob_obj.type.toString()});
                            std.debug.print("  Data length: {} bytes\n", .{blob_obj.data.len});
                            std.debug.print("  Content: {s}\n", .{blob_obj.data});
                            
                            break; // Just test one blob
                        }
                    }
                    
                    pos = null_pos.? + 21; // Skip to next entry
                }
            }
        }
    }
    
    std.debug.print("\n=== Pack File Reading Test PASSED! ===\n");
}