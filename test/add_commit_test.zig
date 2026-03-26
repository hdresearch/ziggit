// test/add_commit_test.zig — Verify pure-Zig add+commit with no git CLI fallback
const std = @import("std");
const testing = std.testing;
const ziggit = @import("ziggit");
const Repository = ziggit.Repository;

const test_base = "/tmp/ziggit_add_commit_test_";

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn writeFile(dir: []const u8, name: []const u8, content: []const u8) !void {
    const allocator = testing.allocator;
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(full);
    // Ensure parent directories exist
    if (std.fs.path.dirname(full)) |parent| {
        std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                // Try creating parent of parent
                if (std.fs.path.dirname(parent)) |grandparent| {
                    std.fs.makeDirAbsolute(grandparent) catch {};
                }
                std.fs.makeDirAbsolute(parent) catch {};
            },
        };
    }
    const file = try std.fs.createFileAbsolute(full, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn deleteFile(dir: []const u8, name: []const u8) !void {
    const allocator = testing.allocator;
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(full);
    try std.fs.deleteFileAbsolute(full);
}

/// Run a git command and return stdout
fn gitCmd(repo_path: []const u8, args: []const []const u8) ![]u8 {
    const allocator = testing.allocator;
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.append("-C");
    try argv.append(repo_path);
    for (args) |a| try argv.append(a);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    const result = try child.wait();
    if (result.Exited != 0) {
        allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

// ============================================================================
// Test 1: Create repo, add file, commit — git can read the commit
// ============================================================================
test "basic add and commit produces git-readable objects" {
    const path = test_base ++ "basic";
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "hello.txt", "Hello, world!\n");
    try repo.add("hello.txt");
    const hash = try repo.commit("initial commit", "Test User", "test@example.com");

    // Verify git can read the commit
    const git_out = try gitCmd(path, &.{ "cat-file", "-p", &hash });
    defer testing.allocator.free(git_out);
    try testing.expect(std.mem.indexOf(u8, git_out, "initial commit") != null);
    try testing.expect(std.mem.indexOf(u8, git_out, "tree ") != null);
    try testing.expect(std.mem.indexOf(u8, git_out, "Test User") != null);
    try testing.expect(std.mem.indexOf(u8, git_out, "test@example.com") != null);

    // Verify the tree contains hello.txt
    var lines = std.mem.splitScalar(u8, git_out, '\n');
    const first_line = lines.first();
    try testing.expect(std.mem.startsWith(u8, first_line, "tree "));
    const tree_hash = first_line["tree ".len..];

    const tree_out = try gitCmd(path, &.{ "cat-file", "-p", tree_hash });
    defer testing.allocator.free(tree_out);
    try testing.expect(std.mem.indexOf(u8, tree_out, "hello.txt") != null);
}

// ============================================================================
// Test 2: commitAll — modify file, commit without explicit add
// ============================================================================
test "commitAll stages modified files and commits" {
    const path = test_base ++ "commitall";
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "file.txt", "version 1\n");
    try repo.add("file.txt");
    _ = try repo.commit("first", "A", "a@b.com");

    // Modify the file without calling add
    try writeFile(path, "file.txt", "version 2\n");

    // commitAll should detect the change and stage it
    const hash2 = try repo.commitAll("second", "A", "a@b.com");

    // git should show the new content
    const show = try gitCmd(path, &.{ "show", &hash2 ++ ":file.txt" });
    defer testing.allocator.free(show);
    try testing.expectEqualStrings("version 2\n", show);
}

// ============================================================================
// Test 3: Author name/email in commit object
// ============================================================================
test "author info appears in commit object" {
    const path = test_base ++ "author";
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "readme.md", "# Hello\n");
    try repo.add("readme.md");
    const hash = try repo.commit("from config", "Config Author", "config@author.org");

    const out = try gitCmd(path, &.{ "cat-file", "-p", &hash });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Config Author") != null);
    try testing.expect(std.mem.indexOf(u8, out, "config@author.org") != null);
}

// ============================================================================
// Test 4: Deleted file with commitAll removes from tree
// ============================================================================
test "commitAll removes deleted files from tree" {
    const path = test_base ++ "delete";
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "keep.txt", "keep\n");
    try writeFile(path, "remove.txt", "gone\n");
    try repo.add("keep.txt");
    try repo.add("remove.txt");
    _ = try repo.commit("both files", "A", "a@b.com");

    // Delete file on disk, then use commitAll (which calls stageTrackedChanges)
    try deleteFile(path, "remove.txt");
    const hash2 = try repo.commitAll("after delete", "A", "a@b.com");

    // The tree for commit 2 should NOT contain remove.txt
    const tree_list = try gitCmd(path, &.{ "ls-tree", "-r", &hash2 });
    defer testing.allocator.free(tree_list);
    try testing.expect(std.mem.indexOf(u8, tree_list, "keep.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_list, "remove.txt") == null);
}

// ============================================================================
// Test 5: Nested directories produce correct recursive tree objects
// ============================================================================
test "nested directories produce correct tree objects" {
    const path = test_base ++ "nested";
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "root.txt", "root\n");
    try writeFile(path, "src/main.zig", "pub fn main() void {}\n");
    try writeFile(path, "src/lib/utils.zig", "// utils\n");

    try repo.add("root.txt");
    try repo.add("src/main.zig");
    try repo.add("src/lib/utils.zig");
    const hash = try repo.commit("nested", "A", "a@b.com");

    // Verify git can traverse the tree
    const tree_list = try gitCmd(path, &.{ "ls-tree", "-r", &hash });
    defer testing.allocator.free(tree_list);

    // Should contain all three files
    try testing.expect(std.mem.indexOf(u8, tree_list, "root.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_list, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, tree_list, "src/lib/utils.zig") != null);

    // Verify the top-level tree has a subtree entry for "src"
    const top_tree = try gitCmd(path, &.{ "ls-tree", &hash });
    defer testing.allocator.free(top_tree);
    try testing.expect(std.mem.indexOf(u8, top_tree, "tree") != null);
    try testing.expect(std.mem.indexOf(u8, top_tree, "src") != null);
}

// ============================================================================
// Test 6: Multiple commits form a valid chain
// ============================================================================
test "commit chain is valid" {
    const path = test_base ++ "chain";
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    const h1 = try repo.commit("first", "A", "a@b.com");

    try writeFile(path, "b.txt", "b\n");
    try repo.add("b.txt");
    const h2 = try repo.commit("second", "A", "a@b.com");

    // Second commit should have first as parent
    const out = try gitCmd(path, &.{ "cat-file", "-p", &h2 });
    defer testing.allocator.free(out);
    const parent_needle = try std.fmt.allocPrint(testing.allocator, "parent {s}", .{h1});
    defer testing.allocator.free(parent_needle);
    try testing.expect(std.mem.indexOf(u8, out, parent_needle) != null);
}

// ============================================================================
// Test 7: stageTrackedChanges detects modifications without explicit add
// ============================================================================
test "stageTrackedChanges updates modified files in index" {
    const path = test_base ++ "stage";
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "a.txt", "original\n");
    try writeFile(path, "b.txt", "also original\n");
    try repo.add("a.txt");
    try repo.add("b.txt");
    _ = try repo.commit("initial", "A", "a@b.com");

    // Modify a.txt, leave b.txt alone
    try writeFile(path, "a.txt", "modified\n");

    // Stage tracked changes
    try repo.stageTrackedChanges();

    // Commit and verify
    const hash = try repo.commit("after stage", "A", "a@b.com");
    const show_a = try gitCmd(path, &.{ "show", &hash ++ ":a.txt" });
    defer testing.allocator.free(show_a);
    try testing.expectEqualStrings("modified\n", show_a);

    const show_b = try gitCmd(path, &.{ "show", &hash ++ ":b.txt" });
    defer testing.allocator.free(show_b);
    try testing.expectEqualStrings("also original\n", show_b);
}
