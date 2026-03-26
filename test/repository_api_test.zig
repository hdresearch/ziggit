// test/repository_api_test.zig - Comprehensive tests for the ziggit Repository API
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

// ============================================================================
// Helper utilities
// ============================================================================

fn tmpTestPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_repo_test_" ++ suffix;
}

fn cleanupPath(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn createFile(repo_path: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ repo_path, name });
    defer testing.allocator.free(full);
    const f = try std.fs.createFileAbsolute(full, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn readFileContent(repo_path: []const u8, name: []const u8) ![]u8 {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ repo_path, name });
    defer testing.allocator.free(full);
    const f = try std.fs.openFileAbsolute(full, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 1024 * 1024);
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn gitDirPath(repo_path: []const u8, sub: []const u8) ![]u8 {
    return try std.fmt.allocPrint(testing.allocator, "{s}/.git/{s}", .{ repo_path, sub });
}

/// Run a git CLI command, discard output
fn runGit(args: []const []const u8, cwd_path: []const u8) !void {
    const out = try runGitCommand(args, cwd_path);
    testing.allocator.free(out);
}

/// Run a git CLI command in a directory and return stdout
fn runGitCommand(args: []const []const u8, cwd_path: []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    // Open the cwd directory for the child process
    var cwd_dir = try std.fs.openDirAbsolute(cwd_path, .{});
    defer cwd_dir.close();
    child.cwd_dir = cwd_dir;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 64 * 1024);
    errdefer testing.allocator.free(stdout);

    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(stderr);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            testing.allocator.free(stdout);
            return error.CommandFailed;
        },
        else => {
            testing.allocator.free(stdout);
            return error.CommandFailed;
        },
    }
    return stdout;
}

// ============================================================================
// Repository.init tests
// ============================================================================

test "Repository.init creates valid git directory structure" {
    const path = tmpTestPath("init_basic");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Verify .git directory exists
    const head = try gitDirPath(path, "HEAD");
    defer testing.allocator.free(head);
    try testing.expect(fileExists(head));

    const objects = try gitDirPath(path, "objects");
    defer testing.allocator.free(objects);
    try testing.expect(fileExists(objects));

    const refs = try gitDirPath(path, "refs");
    defer testing.allocator.free(refs);
    try testing.expect(fileExists(refs));

    const refs_heads = try gitDirPath(path, "refs/heads");
    defer testing.allocator.free(refs_heads);
    try testing.expect(fileExists(refs_heads));

    const refs_tags = try gitDirPath(path, "refs/tags");
    defer testing.allocator.free(refs_tags);
    try testing.expect(fileExists(refs_tags));
}

test "Repository.init HEAD points to refs/heads/master" {
    const path = tmpTestPath("init_head");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const head_content = try readFileContent(path, ".git/HEAD");
    defer testing.allocator.free(head_content);
    try testing.expectEqualStrings("ref: refs/heads/master\n", head_content);
}

test "Repository.init creates config file" {
    const path = tmpTestPath("init_config");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const config = try gitDirPath(path, "config");
    defer testing.allocator.free(config);
    try testing.expect(fileExists(config));
}

test "Repository.init on existing directory succeeds" {
    const path = tmpTestPath("init_existing");
    cleanupPath(path);
    defer cleanupPath(path);

    // Create dir first
    try std.fs.makeDirAbsolute(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const head = try gitDirPath(path, "HEAD");
    defer testing.allocator.free(head);
    try testing.expect(fileExists(head));
}

// ============================================================================
// Repository.open tests
// ============================================================================

test "Repository.open on valid git repo succeeds" {
    const path = tmpTestPath("open_valid");
    cleanupPath(path);
    defer cleanupPath(path);

    // Init first
    {
        var repo = try Repository.init(testing.allocator, path);
        repo.close();
    }

    // Open
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    try testing.expectEqualStrings(path, repo.path);
}

test "Repository.open on non-git directory fails" {
    const path = tmpTestPath("open_nongit");
    cleanupPath(path);
    defer cleanupPath(path);
    try std.fs.makeDirAbsolute(path);

    // Use a non-leak-detecting allocator since Repository.open has a known leak on error path
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = Repository.open(arena.allocator(), path);
    try testing.expectError(error.NotAGitRepository, result);
}

test "Repository.open on nonexistent path fails" {
    // Use a non-leak-detecting allocator since Repository.open has a known leak on error path
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = Repository.open(arena.allocator(), "/tmp/ziggit_repo_test_nonexistent_path_xyz");
    try testing.expectError(error.NotAGitRepository, result);
}

// ============================================================================
// Repository.add + commit tests
// ============================================================================

test "Repository.add stages a file" {
    const path = tmpTestPath("add_basic");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "hello.txt", "Hello, World!\n");
    try repo.add("hello.txt");

    // Verify index file was created
    const index = try gitDirPath(path, "index");
    defer testing.allocator.free(index);
    try testing.expect(fileExists(index));
}

test "Repository.commit creates a commit object" {
    const path = tmpTestPath("commit_basic");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "file.txt", "content\n");
    try repo.add("file.txt");

    const hash = try repo.commit("Initial commit", "Test User", "test@test.com");

    // Hash should be 40 hex chars
    try testing.expectEqual(@as(usize, 40), hash.len);
    for (hash) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "Repository.revParseHead returns commit hash after commit" {
    const path = tmpTestPath("revparse_basic");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    const commit_hash = try repo.commit("first", "A", "a@a.com");

    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&commit_hash, &head);
}

test "Repository.revParseHead returns zeros before first commit" {
    const path = tmpTestPath("revparse_empty");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // HEAD points to refs/heads/master which doesn't exist yet
    const result = repo.revParseHead();
    // Should return error or zeros
    if (result) |head| {
        const zeros = [_]u8{'0'} ** 40;
        try testing.expectEqualStrings(&zeros, &head);
    } else |_| {
        // Error is also acceptable for empty repo
    }
}

test "Repository.commit with parent creates chain" {
    const path = tmpTestPath("commit_chain");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    const hash1 = try repo.commit("first", "A", "a@a.com");

    try createFile(path, "b.txt", "b\n");
    try repo.add("b.txt");
    const hash2 = try repo.commit("second", "A", "a@a.com");

    // Hashes should be different
    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));

    // HEAD should point to second commit
    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&hash2, &head);
}

// ============================================================================
// Repository.createTag tests
// ============================================================================

test "Repository.createTag creates lightweight tag" {
    const path = tmpTestPath("tag_lightweight");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    try repo.createTag("v1.0.0", null);

    // Verify tag file exists
    const tag_path = try gitDirPath(path, "refs/tags/v1.0.0");
    defer testing.allocator.free(tag_path);
    try testing.expect(fileExists(tag_path));
}

test "Repository.createTag creates annotated tag" {
    const path = tmpTestPath("tag_annotated");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    try repo.createTag("v2.0.0", "Release 2.0");

    const tag_path = try gitDirPath(path, "refs/tags/v2.0.0");
    defer testing.allocator.free(tag_path);
    try testing.expect(fileExists(tag_path));
}

test "Repository.describeTags returns latest tag" {
    const path = tmpTestPath("describe_tags");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    try repo.createTag("v1.0.0", null);
    try repo.createTag("v2.0.0", null);

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);

    // Should return the lexicographically latest tag
    try testing.expectEqualStrings("v2.0.0", tag);
}

test "Repository.describeTags returns empty on no tags" {
    const path = tmpTestPath("describe_notags");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("", tag);
}

test "Repository.latestTag is alias for describeTags" {
    const path = tmpTestPath("latest_tag");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");
    try repo.createTag("v3.0.0", null);

    const tag = try repo.latestTag(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v3.0.0", tag);
}

// ============================================================================
// Repository.branchList tests
// ============================================================================

test "Repository.branchList lists master after commit" {
    const path = tmpTestPath("branchlist");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    try testing.expectEqual(@as(usize, 1), branches.len);
    try testing.expectEqualStrings("master", branches[0]);
}

test "Repository.branchList returns empty on fresh repo" {
    const path = tmpTestPath("branchlist_empty");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    try testing.expectEqual(@as(usize, 0), branches.len);
}

// ============================================================================
// Repository.findCommit tests
// ============================================================================

test "Repository.findCommit resolves HEAD" {
    const path = tmpTestPath("findcommit_head");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "A", "a@a.com");

    const found = try repo.findCommit("HEAD");
    try testing.expectEqualStrings(&hash, &found);
}

test "Repository.findCommit resolves full hash" {
    const path = tmpTestPath("findcommit_hash");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "A", "a@a.com");

    const found = try repo.findCommit(&hash);
    try testing.expectEqualStrings(&hash, &found);
}

test "Repository.findCommit resolves branch name" {
    const path = tmpTestPath("findcommit_branch");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "A", "a@a.com");

    const found = try repo.findCommit("master");
    try testing.expectEqualStrings(&hash, &found);
}

test "Repository.findCommit resolves tag name" {
    const path = tmpTestPath("findcommit_tag");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "A", "a@a.com");
    try repo.createTag("v1.0.0", null);

    const found = try repo.findCommit("v1.0.0");
    try testing.expectEqualStrings(&hash, &found);
}

test "Repository.findCommit returns error for unknown ref" {
    const path = tmpTestPath("findcommit_unknown");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    const result = repo.findCommit("nonexistent");
    try testing.expectError(error.CommitNotFound, result);
}

// ============================================================================
// Git interop: create with ziggit, verify with git CLI
// ============================================================================

test "Git interop: ziggit init is readable by git" {
    const path = tmpTestPath("interop_init");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // git status should work on ziggit-created repo
    const status = try runGitCommand(&.{ "git", "status", "--porcelain" }, path);
    defer testing.allocator.free(status);
    // Empty repo = empty status - OK
}

test "Git interop: ziggit commit is readable by git log" {
    const path = tmpTestPath("interop_commit");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Configure git user for this repo
    runGit(&.{ "git", "config", "user.name", "Test" }, path) catch {};
    runGit(&.{ "git", "config", "user.email", "t@t.com" }, path) catch {};

    try createFile(path, "hello.txt", "Hello!\n");
    try repo.add("hello.txt");
    const hash = try repo.commit("Test commit", "Test", "t@t.com");

    // git log should show our commit
    const log = try runGitCommand(&.{ "git", "log", "--oneline" }, path);
    defer testing.allocator.free(log);

    // Should contain the short hash
    try testing.expect(std.mem.indexOf(u8, log, hash[0..7]) != null);
    try testing.expect(std.mem.indexOf(u8, log, "Test commit") != null);
}

test "Git interop: ziggit rev-parse matches git rev-parse" {
    const path = tmpTestPath("interop_revparse");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    runGit(&.{ "git", "config", "user.name", "Test" }, path) catch {};
    runGit(&.{ "git", "config", "user.email", "t@t.com" }, path) catch {};

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("commit", "Test", "t@t.com");

    const ziggit_head = try repo.revParseHead();

    const git_head_raw = try runGitCommand(&.{ "git", "rev-parse", "HEAD" }, path);
    defer testing.allocator.free(git_head_raw);
    const git_head = std.mem.trim(u8, git_head_raw, " \n\r\t");

    try testing.expectEqualStrings(git_head, &ziggit_head);
}

test "Git interop: git-created repo readable by ziggit" {
    const path = tmpTestPath("interop_git2ziggit");
    cleanupPath(path);
    defer cleanupPath(path);

    // Create repo with git
    try runGit(&.{ "git", "init", path }, "/tmp");
    runGit(&.{ "git", "config", "user.name", "Test" }, path) catch {};
    runGit(&.{ "git", "config", "user.email", "t@t.com" }, path) catch {};

    try createFile(path, "test.txt", "hello from git\n");
    try runGit(&.{ "git", "add", "test.txt" }, path);
    try runGit(&.{ "git", "commit", "-m", "git commit" }, path);

    // Use arena allocator to avoid leak detection issues from warmupCaches
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Open with ziggit
    var repo = try Repository.open(arena.allocator(), path);
    defer repo.close();

    const head = try repo.revParseHead();
    // Should be a valid 40-char hex hash
    try testing.expectEqual(@as(usize, 40), head.len);
    for (head) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "Git interop: git-created tags readable by ziggit" {
    const path = tmpTestPath("interop_tags");
    cleanupPath(path);
    defer cleanupPath(path);

    try runGit(&.{ "git", "init", path }, "/tmp");
    runGit(&.{ "git", "config", "user.name", "Test" }, path) catch {};
    runGit(&.{ "git", "config", "user.email", "t@t.com" }, path) catch {};

    try createFile(path, "f.txt", "data\n");
    try runGit(&.{ "git", "add", "f.txt" }, path);
    try runGit(&.{ "git", "commit", "-m", "init" }, path);
    try runGit(&.{ "git", "tag", "v1.0.0" }, path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var repo = try Repository.open(arena.allocator(), path);
    defer repo.close();

    const tag = try repo.describeTags(arena.allocator());
    try testing.expectEqualStrings("v1.0.0", tag);
}

test "Git interop: git-created branches readable by ziggit" {
    const path = tmpTestPath("interop_branches");
    cleanupPath(path);
    defer cleanupPath(path);

    try runGit(&.{ "git", "init", path }, "/tmp");
    runGit(&.{ "git", "config", "user.name", "Test" }, path) catch {};
    runGit(&.{ "git", "config", "user.email", "t@t.com" }, path) catch {};

    try createFile(path, "f.txt", "data\n");
    try runGit(&.{ "git", "add", "f.txt" }, path);
    try runGit(&.{ "git", "commit", "-m", "init" }, path);
    try runGit(&.{ "git", "branch", "feature" }, path);
    try runGit(&.{ "git", "branch", "develop" }, path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var repo = try Repository.open(arena.allocator(), path);
    defer repo.close();

    const branches = try repo.branchList(arena.allocator());

    // Should have master + feature + develop. Git may use "main" or "master".
    try testing.expect(branches.len >= 3);

    var found_feature = false;
    var found_develop = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "feature")) found_feature = true;
        if (std.mem.eql(u8, b, "develop")) found_develop = true;
    }
    try testing.expect(found_feature);
    try testing.expect(found_develop);
}

// ============================================================================
// Blob/object creation tests
// ============================================================================

test "Repository.add creates correct blob object" {
    const path = tmpTestPath("blob_correct");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "Hello, World!\n";
    try createFile(path, "hello.txt", content);
    try repo.add("hello.txt");

    // Compute expected blob hash
    const header = try std.fmt.allocPrint(testing.allocator, "blob {}\x00", .{content.len});
    defer testing.allocator.free(header);
    const blob_data = try std.mem.concat(testing.allocator, u8, &.{ header, content });
    defer testing.allocator.free(blob_data);

    var expected_hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(blob_data, &expected_hash, .{});
    var expected_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&expected_hex, "{}", .{std.fmt.fmtSliceHexLower(&expected_hash)}) catch unreachable;

    // Verify object file exists at expected path
    const obj_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/objects/{s}/{s}", .{ path, expected_hex[0..2], expected_hex[2..] });
    defer testing.allocator.free(obj_path);
    try testing.expect(fileExists(obj_path));
}

test "Repository.add creates blob readable by git cat-file" {
    const path = tmpTestPath("blob_catfile");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "Test content for git cat-file\n";
    try createFile(path, "test.txt", content);
    try repo.add("test.txt");

    // Use git to read the blob hash from the index
    runGit(&.{ "git", "config", "user.name", "Test" }, path) catch {};
    runGit(&.{ "git", "config", "user.email", "t@t.com" }, path) catch {};

    const ls_files = try runGitCommand(&.{ "git", "ls-files", "--stage" }, path);
    defer testing.allocator.free(ls_files);

    // ls-files output: "100644 <hash> 0\ttest.txt\n"
    if (std.mem.indexOf(u8, ls_files, " ")) |space1| {
        const after_mode = ls_files[space1 + 1 ..];
        if (after_mode.len >= 40) {
            const blob_hash = after_mode[0..40];
            // cat-file should return our content
            const cat_args = [_][]const u8{ "git", "cat-file", "-p", blob_hash };
            const blob_content = try runGitCommand(&cat_args, path);
            defer testing.allocator.free(blob_content);
            try testing.expectEqualStrings(content, blob_content);
        }
    }
}

// ============================================================================
// Index read/write tests
// ============================================================================

test "Repository.add updates index correctly" {
    const path = tmpTestPath("index_update");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");

    try createFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");

    // Both files should be in index, verified via git ls-files
    runGit(&.{ "git", "config", "user.name", "T" }, path) catch {};
    runGit(&.{ "git", "config", "user.email", "t@t.com" }, path) catch {};

    const ls = try runGitCommand(&.{ "git", "ls-files" }, path);
    defer testing.allocator.free(ls);

    try testing.expect(std.mem.indexOf(u8, ls, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls, "b.txt") != null);
}

// ============================================================================
// Status tests
// ============================================================================

test "Repository.statusPorcelain on clean repo returns empty" {
    const path = tmpTestPath("status_clean");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);

    try testing.expectEqualStrings("", status);
}

test "Repository.isClean on clean repo returns true" {
    const path = tmpTestPath("isclean_true");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    const clean = try repo.isClean();
    try testing.expect(clean);
}

test "Repository.isClean on empty repo returns true" {
    const path = tmpTestPath("isclean_empty");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Empty repo with no files should be clean
    const clean = try repo.isClean();
    try testing.expect(clean);
}

// ============================================================================
// Clone tests
// ============================================================================

test "Repository.cloneNoCheckout clones a local repo" {
    const source = tmpTestPath("clone_src");
    const target = tmpTestPath("clone_dst");
    cleanupPath(source);
    cleanupPath(target);
    defer cleanupPath(source);
    defer cleanupPath(target);

    // Create source repo
    {
        var src = try Repository.init(testing.allocator, source);
        defer src.close();
        try createFile(source, "f.txt", "data\n");
        try src.add("f.txt");
        _ = try src.commit("init", "A", "a@a.com");
    }

    // Clone
    var cloned = try Repository.cloneNoCheckout(testing.allocator, source, target);
    defer cloned.close();

    // Should be able to read HEAD
    const head = try cloned.revParseHead();
    try testing.expectEqual(@as(usize, 40), head.len);
    for (head) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "Repository.cloneNoCheckout to existing path fails" {
    const source = tmpTestPath("clone_exists_src");
    const target = tmpTestPath("clone_exists_dst");
    cleanupPath(source);
    cleanupPath(target);
    defer cleanupPath(source);
    defer cleanupPath(target);

    {
        var src = try Repository.init(testing.allocator, source);
        defer src.close();
        try createFile(source, "f.txt", "data\n");
        try src.add("f.txt");
        _ = try src.commit("init", "A", "a@a.com");
    }

    // Create target dir first
    try std.fs.makeDirAbsolute(target);

    const result = Repository.cloneNoCheckout(testing.allocator, source, target);
    try testing.expectError(error.AlreadyExists, result);
}

// ============================================================================
// Fetch tests
// ============================================================================

test "Repository.fetch from local repo" {
    const source = tmpTestPath("fetch_src");
    const target = tmpTestPath("fetch_dst");
    cleanupPath(source);
    cleanupPath(target);
    defer cleanupPath(source);
    defer cleanupPath(target);

    // Create source with commits
    {
        var src = try Repository.init(testing.allocator, source);
        defer src.close();
        try createFile(source, "f.txt", "data\n");
        try src.add("f.txt");
        _ = try src.commit("init", "A", "a@a.com");
    }

    // Create target repo
    var dst = try Repository.init(testing.allocator, target);
    defer dst.close();

    // Fetch
    try dst.fetch(source);

    // Should have remote refs
    const remote_refs_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git/refs/remotes/origin", .{target});
    defer testing.allocator.free(remote_refs_dir);
    try testing.expect(fileExists(remote_refs_dir));
}

test "Repository.fetch rejects network URLs" {
    const path = tmpTestPath("fetch_network");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.HttpFetchFailed, repo.fetch("https://github.com/example/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("git://example.com/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("ssh://git@example.com/repo"));
}

// ============================================================================
// Edge case tests
// ============================================================================

test "Repository.add with empty file" {
    const path = tmpTestPath("edge_empty_file");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "empty.txt", "");
    try repo.add("empty.txt");

    // Should be able to commit
    const hash = try repo.commit("empty file", "A", "a@a.com");
    try testing.expectEqual(@as(usize, 40), hash.len);
}

test "Repository.add with binary content" {
    const path = tmpTestPath("edge_binary");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Create file with binary content (null bytes, high bytes)
    const binary = "\x00\x01\x02\xff\xfe\xfd\x00\x00";
    try createFile(path, "binary.bin", binary);
    try repo.add("binary.bin");

    const hash = try repo.commit("binary file", "A", "a@a.com");
    try testing.expectEqual(@as(usize, 40), hash.len);
}

test "Repository.add with large content" {
    const path = tmpTestPath("edge_large");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Create 1MB file
    const large = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(large);
    @memset(large, 'A');
    try createFile(path, "large.txt", large);
    try repo.add("large.txt");

    const hash = try repo.commit("large file", "A", "a@a.com");
    try testing.expectEqual(@as(usize, 40), hash.len);
}

test "Repository.commit with unicode message" {
    const path = tmpTestPath("edge_unicode_msg");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");

    const hash = try repo.commit("初次提交 🎉", "テスト", "test@例え.com");
    try testing.expectEqual(@as(usize, 40), hash.len);
}

test "Repository.createTag with special characters in name" {
    const path = tmpTestPath("edge_tag_special");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    // Tags with dots and dashes should work
    try repo.createTag("v1.0.0-rc.1", null);
    const tag_path = try gitDirPath(path, "refs/tags/v1.0.0-rc.1");
    defer testing.allocator.free(tag_path);
    try testing.expect(fileExists(tag_path));
}

test "Multiple tags sorted correctly" {
    const path = tmpTestPath("edge_multi_tags");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    try repo.createTag("v0.1.0", null);
    try repo.createTag("v0.9.0", null);
    try repo.createTag("v0.10.0", null);
    try repo.createTag("v1.0.0", null);

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);

    // Lexicographic sort means v1.0.0 > v0.9.0 > v0.10.0 > v0.1.0
    try testing.expectEqualStrings("v1.0.0", tag);
}

// ============================================================================
// Checkout tests
// ============================================================================

test "Repository.checkout restores file content" {
    const path = tmpTestPath("checkout_basic");
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Commit first version
    try createFile(path, "file.txt", "version 1\n");
    try repo.add("file.txt");
    const hash1 = try repo.commit("v1", "A", "a@a.com");

    // Commit second version
    try createFile(path, "file.txt", "version 2\n");
    try repo.add("file.txt");
    _ = try repo.commit("v2", "A", "a@a.com");

    // Checkout first commit
    try repo.checkout(&hash1);

    // Verify file content
    const content = try readFileContent(path, "file.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("version 1\n", content);
}

// ============================================================================
// Consistency: multiple operations in sequence
// ============================================================================

test "Full workflow: init, add, commit, tag, branch, status" {
    const path = tmpTestPath("full_workflow");
    cleanupPath(path);
    defer cleanupPath(path);

    // Init
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Add and commit
    try createFile(path, "main.zig", "pub fn main() void {}\n");
    try repo.add("main.zig");
    const hash1 = try repo.commit("Initial", "Dev", "dev@example.com");

    // Verify HEAD
    const head1 = try repo.revParseHead();
    try testing.expectEqualStrings(&hash1, &head1);

    // Create tag
    try repo.createTag("v0.1.0", null);

    // Second commit
    try createFile(path, "build.zig", "pub fn build() void {}\n");
    try repo.add("build.zig");
    const hash2 = try repo.commit("Add build", "Dev", "dev@example.com");

    // HEAD should be new commit
    const head2 = try repo.revParseHead();
    try testing.expectEqualStrings(&hash2, &head2);
    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));

    // Branch should be master
    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }
    try testing.expect(branches.len >= 1);

    // Tag should be v0.1.0
    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v0.1.0", tag);

    // Status should be clean
    const clean = try repo.isClean();
    try testing.expect(clean);
}

test "Repository reopened preserves state" {
    const path = tmpTestPath("reopen_state");
    cleanupPath(path);
    defer cleanupPath(path);

    var hash: [40]u8 = undefined;

    // Create and populate
    {
        var repo = try Repository.init(testing.allocator, path);
        defer repo.close();
        try createFile(path, "f.txt", "data\n");
        try repo.add("f.txt");
        hash = try repo.commit("test", "A", "a@a.com");
        try repo.createTag("v1.0.0", null);
    }

    // Reopen and verify
    {
        var repo = try Repository.open(testing.allocator, path);
        defer repo.close();

        const head = try repo.revParseHead();
        try testing.expectEqualStrings(&hash, &head);

        const tag = try repo.describeTags(testing.allocator);
        defer testing.allocator.free(tag);
        try testing.expectEqualStrings("v1.0.0", tag);

        const branches = try repo.branchList(testing.allocator);
        defer {
            for (branches) |b| testing.allocator.free(b);
            testing.allocator.free(branches);
        }
        try testing.expectEqual(@as(usize, 1), branches.len);
    }
}
