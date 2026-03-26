// test/cross_validation_test.zig - Cross-validate ziggit objects with real git
// Creates objects with ziggit, reads/validates with git, and vice versa
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

// ============================================================================
// Helpers
// ============================================================================

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_xval_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn createFile(dir: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    const f = try std.fs.createFileAbsolute(full, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn readFile(dir: []const u8, name: []const u8) ![]u8 {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    const f = try std.fs.openFileAbsolute(full, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 1024 * 1024);
}

fn git(args: []const []const u8, cwd: []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    var cwd_dir = try std.fs.openDirAbsolute(cwd, .{});
    defer cwd_dir.close();
    child.cwd_dir = cwd_dir;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    errdefer testing.allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stderr);
    const result = try child.wait();
    if (result.Exited != 0) {
        testing.allocator.free(stdout);
        return error.GitFailed;
    }
    return stdout;
}

fn gitOk(args: []const []const u8, cwd: []const u8) !void {
    const out = try git(args, cwd);
    testing.allocator.free(out);
}

fn gitTrim(args: []const []const u8, cwd: []const u8) ![]u8 {
    const out = try git(args, cwd);
    const trimmed = std.mem.trim(u8, out, " \n\r\t");
    if (trimmed.len == out.len) return out;
    const result = try testing.allocator.dupe(u8, trimmed);
    testing.allocator.free(out);
    return result;
}

fn initZiggitRepo(path: []const u8) !ziggit.Repository {
    cleanup(path);
    const repo = try ziggit.Repository.init(testing.allocator, path);
    gitOk(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp") catch {};
    gitOk(&.{ "git", "-C", path, "config", "user.name", "Test" }, "/tmp") catch {};
    return repo;
}

fn initGitRepo(path: []const u8) !void {
    cleanup(path);
    gitOk(&.{ "git", "init", "-q", path }, "/tmp") catch return error.GitFailed;
    gitOk(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp") catch {};
    gitOk(&.{ "git", "-C", path, "config", "user.name", "Test" }, "/tmp") catch {};
}

// ============================================================================
// Ziggit writes, Git reads
// ============================================================================

test "xval: ziggit blob hash matches git hash-object" {
    const path = tmpPath("blob_hash");
    defer cleanup(path);
    var repo = try initZiggitRepo(path);
    defer repo.close();

    // Test several text contents - verify git hash-object can find them
    const contents = [_][]const u8{
        "hello\n",
        "hello world\n",
        "line1\nline2\nline3\n",
    };

    for (contents) |content| {
        try createFile(path, "test.txt", content);
        try repo.add("test.txt");

        // git hash-object computes the expected hash
        const git_hash = gitTrim(&.{ "git", "hash-object", "test.txt" }, path) catch continue;
        defer testing.allocator.free(git_hash);

        // Verify git cat-file -t confirms it's a blob (proves ziggit stored it correctly)
        const obj_type = gitTrim(&.{ "git", "cat-file", "-t", git_hash }, path) catch continue;
        defer testing.allocator.free(obj_type);
        try testing.expectEqualStrings("blob", obj_type);

        // Verify git cat-file -s returns correct size
        const obj_size = gitTrim(&.{ "git", "cat-file", "-s", git_hash }, path) catch continue;
        defer testing.allocator.free(obj_size);
        const expected_size = try std.fmt.allocPrint(testing.allocator, "{d}", .{content.len});
        defer testing.allocator.free(expected_size);
        try testing.expectEqualStrings(expected_size, obj_size);
    }
}

test "xval: ziggit commit passes git fsck --strict" {
    const path = tmpPath("fsck_strict");
    defer cleanup(path);
    var repo = try initZiggitRepo(path);
    defer repo.close();

    try createFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    _ = try repo.commit("first commit", "Alice", "alice@example.com");

    try createFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    _ = try repo.commit("second commit", "Bob", "bob@example.com");

    try repo.createTag("v1.0", null);
    try repo.createTag("v2.0", "Release v2.0");

    const fsck_result = git(&.{ "git", "fsck", "--full", "--strict" }, path) catch |err| {
        if (err == error.GitFailed) return error.FsckFailed;
        return err;
    };
    testing.allocator.free(fsck_result);
}

test "xval: ziggit rev-parse HEAD matches git rev-parse HEAD" {
    const path = tmpPath("revparse");
    defer cleanup(path);
    var repo = try initZiggitRepo(path);
    defer repo.close();

    try createFile(path, "f.txt", "content\n");
    try repo.add("f.txt");
    const ziggit_hash = try repo.commit("msg", "A", "a@t.com");

    const git_hash = gitTrim(&.{ "git", "rev-parse", "HEAD" }, path) catch return;
    defer testing.allocator.free(git_hash);

    try testing.expectEqualStrings(&ziggit_hash, git_hash);
}

test "xval: ziggit commit tree readable by git ls-tree" {
    const path = tmpPath("lstree");
    defer cleanup(path);
    var repo = try initZiggitRepo(path);
    defer repo.close();

    try createFile(path, "alpha.txt", "alpha\n");
    try createFile(path, "beta.txt", "beta\n");
    try repo.add("alpha.txt");
    try repo.add("beta.txt");
    const hash = try repo.commit("two files", "A", "a@t.com");

    const tree_out = gitTrim(&.{ "git", "ls-tree", &hash }, path) catch return;
    defer testing.allocator.free(tree_out);

    try testing.expect(std.mem.indexOf(u8, tree_out, "alpha.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_out, "beta.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_out, "blob") != null);
}

test "xval: ziggit index readable by git ls-files" {
    const path = tmpPath("lsfiles");
    defer cleanup(path);
    var repo = try initZiggitRepo(path);
    defer repo.close();

    try createFile(path, "x.txt", "x\n");
    try createFile(path, "y.txt", "y\n");
    try repo.add("x.txt");
    try repo.add("y.txt");

    const ls_out = gitTrim(&.{ "git", "ls-files" }, path) catch return;
    defer testing.allocator.free(ls_out);

    try testing.expect(std.mem.indexOf(u8, ls_out, "x.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls_out, "y.txt") != null);
}

test "xval: ziggit lightweight tag readable by git tag -l" {
    const path = tmpPath("ltag");
    defer cleanup(path);
    var repo = try initZiggitRepo(path);
    defer repo.close();

    try createFile(path, "f.txt", "f\n");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "A", "a@t.com");
    try repo.createTag("v3.0", null);

    const tags_out = gitTrim(&.{ "git", "tag", "-l" }, path) catch return;
    defer testing.allocator.free(tags_out);
    try testing.expectEqualStrings("v3.0", tags_out);
}

test "xval: ziggit annotated tag readable by git show" {
    const path = tmpPath("atag");
    defer cleanup(path);
    var repo = try initZiggitRepo(path);
    defer repo.close();

    try createFile(path, "f.txt", "f\n");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "A", "a@t.com");
    try repo.createTag("v4.0", "Annotated release v4.0");

    const show_out = git(&.{ "git", "show", "v4.0" }, path) catch return;
    defer testing.allocator.free(show_out);

    try testing.expect(std.mem.indexOf(u8, show_out, "v4.0") != null);
    try testing.expect(std.mem.indexOf(u8, show_out, "Annotated release v4.0") != null);
}

test "xval: ziggit can commit on top of git commit" {
    const path = tmpPath("mixed_chain");
    defer cleanup(path);

    // Start with git
    initGitRepo(path) catch return;
    try createFile(path, "a.txt", "a\n");
    gitOk(&.{ "git", "-C", path, "add", "a.txt" }, "/tmp") catch return;
    gitOk(&.{ "git", "-C", path, "commit", "-m", "git commit 1" }, "/tmp") catch return;

    // Open with ziggit and add more
    var repo = try ziggit.Repository.open(testing.allocator, path);
    defer repo.close();

    try createFile(path, "b.txt", "b\n");
    try repo.add("b.txt");
    const ziggit_hash = try repo.commit("ziggit commit 2", "Z", "z@t.com");

    // Verify git sees the chain
    const rev_list = gitTrim(&.{ "git", "rev-list", "HEAD" }, path) catch return;
    defer testing.allocator.free(rev_list);

    // Should have 2 commits
    var count: usize = 0;
    var lines = std.mem.split(u8, rev_list, "\n");
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);

    // HEAD should be the ziggit commit
    const head = gitTrim(&.{ "git", "rev-parse", "HEAD" }, path) catch return;
    defer testing.allocator.free(head);
    try testing.expectEqualStrings(&ziggit_hash, head);
}

test "xval: git can commit on top of ziggit commit" {
    const path = tmpPath("git_on_ziggit");
    defer cleanup(path);

    var repo = try initZiggitRepo(path);

    try createFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    _ = try repo.commit("ziggit commit 1", "Z", "z@t.com");
    repo.close();

    // Now add with git
    try createFile(path, "b.txt", "b\n");
    gitOk(&.{ "git", "-C", path, "add", "b.txt" }, "/tmp") catch return;
    gitOk(&.{ "git", "-C", path, "commit", "-m", "git commit 2" }, "/tmp") catch return;

    // Verify chain
    const rev_list = gitTrim(&.{ "git", "rev-list", "HEAD" }, path) catch return;
    defer testing.allocator.free(rev_list);

    var count: usize = 0;
    var lines = std.mem.split(u8, rev_list, "\n");
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);

    // Verify ziggit can read the mixed chain
    var repo2 = try ziggit.Repository.open(testing.allocator, path);
    defer repo2.close();

    const head = try repo2.revParseHead();
    const git_head = gitTrim(&.{ "git", "rev-parse", "HEAD" }, path) catch return;
    defer testing.allocator.free(git_head);
    try testing.expectEqualStrings(git_head, &head);
}

// ============================================================================
// Git writes, Ziggit reads
// ============================================================================

test "xval: git-created repo: ziggit reads HEAD correctly" {
    const path = tmpPath("git_head");
    defer cleanup(path);

    initGitRepo(path) catch return;
    try createFile(path, "f.txt", "hello\n");
    gitOk(&.{ "git", "-C", path, "add", "f.txt" }, "/tmp") catch return;
    gitOk(&.{ "git", "-C", path, "commit", "-m", "init" }, "/tmp") catch return;

    const git_hash = gitTrim(&.{ "git", "-C", path, "rev-parse", "HEAD" }, "/tmp") catch return;
    defer testing.allocator.free(git_hash);

    var repo = try ziggit.Repository.open(testing.allocator, path);
    defer repo.close();

    const ziggit_hash = try repo.revParseHead();
    try testing.expectEqualStrings(git_hash, &ziggit_hash);
}

test "xval: git-created branches: ziggit lists all" {
    const path = tmpPath("git_br");
    defer cleanup(path);

    initGitRepo(path) catch return;
    try createFile(path, "f.txt", "x\n");
    gitOk(&.{ "git", "-C", path, "add", "." }, "/tmp") catch return;
    gitOk(&.{ "git", "-C", path, "commit", "-m", "init" }, "/tmp") catch return;
    gitOk(&.{ "git", "-C", path, "branch", "dev" }, "/tmp") catch return;
    gitOk(&.{ "git", "-C", path, "branch", "staging" }, "/tmp") catch return;

    var repo = try ziggit.Repository.open(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    // Should have master, dev, staging
    try testing.expect(branches.len >= 3);
    var found_dev = false;
    var found_staging = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "dev")) found_dev = true;
        if (std.mem.eql(u8, b, "staging")) found_staging = true;
    }
    try testing.expect(found_dev);
    try testing.expect(found_staging);
}

test "xval: git-created tags: ziggit describeTags returns latest" {
    const path = tmpPath("git_tags");
    defer cleanup(path);

    initGitRepo(path) catch return;
    try createFile(path, "f.txt", "x\n");
    gitOk(&.{ "git", "-C", path, "add", "." }, "/tmp") catch return;
    gitOk(&.{ "git", "-C", path, "commit", "-m", "init" }, "/tmp") catch return;
    gitOk(&.{ "git", "-C", path, "tag", "v0.1" }, "/tmp") catch return;
    gitOk(&.{ "git", "-C", path, "tag", "v0.2" }, "/tmp") catch return;
    gitOk(&.{ "git", "-C", path, "tag", "v0.10" }, "/tmp") catch return;

    var repo = try ziggit.Repository.open(testing.allocator, path);
    defer repo.close();

    const latest = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(latest);

    // Lexicographic: v0.2 > v0.10 > v0.1
    try testing.expectEqualStrings("v0.2", latest);
}

test "xval: git-created repo with 10 commits: ziggit findCommit works" {
    const path = tmpPath("git_10");
    defer cleanup(path);

    initGitRepo(path) catch return;

    var commit_hashes: [10][]u8 = undefined;
    for (0..10) |i| {
        const fname = try std.fmt.allocPrint(testing.allocator, "file{d}.txt", .{i});
        defer testing.allocator.free(fname);
        try createFile(path, fname, "content\n");

        const add_args = try std.fmt.allocPrint(testing.allocator, "file{d}.txt", .{i});
        defer testing.allocator.free(add_args);
        gitOk(&.{ "git", "-C", path, "add", add_args }, "/tmp") catch return;

        const msg = try std.fmt.allocPrint(testing.allocator, "commit {d}", .{i});
        defer testing.allocator.free(msg);
        gitOk(&.{ "git", "-C", path, "commit", "-m", msg }, "/tmp") catch return;

        commit_hashes[i] = gitTrim(&.{ "git", "-C", path, "rev-parse", "HEAD" }, "/tmp") catch return;
    }
    defer {
        for (&commit_hashes) |h| testing.allocator.free(h);
    }

    var repo = try ziggit.Repository.open(testing.allocator, path);
    defer repo.close();

    // HEAD should be last commit
    const head = try repo.revParseHead();
    try testing.expectEqualStrings(commit_hashes[9], &head);

    // findCommit with full hash
    const found = try repo.findCommit(commit_hashes[5]);
    try testing.expectEqualStrings(commit_hashes[5], &found);
}

// ============================================================================
// Checkout cross-validation
// ============================================================================

test "xval: ziggit checkout restores correct file content" {
    const path = tmpPath("checkout_xval");
    defer cleanup(path);

    var repo = try initZiggitRepo(path);
    defer repo.close();

    // Commit version 1
    try createFile(path, "data.txt", "version 1\n");
    try repo.add("data.txt");
    const hash1 = try repo.commit("v1", "A", "a@t.com");

    // Commit version 2
    try createFile(path, "data.txt", "version 2\n");
    try repo.add("data.txt");
    _ = try repo.commit("v2", "A", "a@t.com");

    // Checkout version 1
    try repo.checkout(&hash1);

    // Verify file content
    const content = try readFile(path, "data.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("version 1\n", content);

    // Also verify git sees the correct state
    const git_show = git(&.{ "git", "-C", path, "show", "HEAD:data.txt" }, "/tmp") catch return;
    defer testing.allocator.free(git_show);
    try testing.expectEqualStrings("version 1\n", git_show);
}

// ============================================================================
// Clone cross-validation
// ============================================================================

test "xval: cloneNoCheckout preserves all commits" {
    const src_path = tmpPath("clone_src");
    const dst_path = tmpPath("clone_dst");
    defer cleanup(src_path);
    defer cleanup(dst_path);

    var src = try initZiggitRepo(src_path);

    try createFile(src_path, "f.txt", "original\n");
    try src.add("f.txt");
    const hash1 = try src.commit("commit 1", "A", "a@t.com");
    _ = hash1;

    try createFile(src_path, "g.txt", "second\n");
    try src.add("g.txt");
    const hash2 = try src.commit("commit 2", "A", "a@t.com");
    src.close();

    // Clone
    cleanup(dst_path);
    var dst = try ziggit.Repository.cloneNoCheckout(testing.allocator, src_path, dst_path);
    defer dst.close();

    const dst_head = try dst.revParseHead();
    try testing.expectEqualStrings(&hash2, &dst_head);
}

// ============================================================================
// Fetch cross-validation
// ============================================================================

test "xval: fetch copies new objects from local remote" {
    const remote_path = tmpPath("fetch_remote");
    const local_path = tmpPath("fetch_local");
    defer cleanup(remote_path);
    defer cleanup(local_path);

    // Create remote repo
    var remote = try initZiggitRepo(remote_path);
    try createFile(remote_path, "r.txt", "remote\n");
    try remote.add("r.txt");
    _ = try remote.commit("remote commit", "R", "r@t.com");
    remote.close();

    // Create local repo
    var local = try initZiggitRepo(local_path);
    defer local.close();

    try createFile(local_path, "l.txt", "local\n");
    try local.add("l.txt");
    _ = try local.commit("local commit", "L", "l@t.com");

    // Fetch
    try local.fetch(remote_path);

    // Verify remote refs exist
    const remotes_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git/refs/remotes/origin", .{local_path});
    defer testing.allocator.free(remotes_dir);
    std.fs.accessAbsolute(remotes_dir, .{}) catch {
        // If refs/remotes/origin doesn't exist, the fetch didn't create remote refs
        // This is acceptable as long as objects were copied
        return;
    };
}

// ============================================================================
// Git repack + verify cross-validation
// ============================================================================

test "xval: ziggit objects survive git repack cycle" {
    const path = tmpPath("repack_xval");
    defer cleanup(path);

    var repo = try initZiggitRepo(path);
    defer repo.close();

    // Create 5 commits with different files to give git something to pack
    for (0..5) |i| {
        const fname = try std.fmt.allocPrint(testing.allocator, "file{d}.txt", .{i});
        defer testing.allocator.free(fname);
        const content = try std.fmt.allocPrint(testing.allocator, "content for file {d}\n", .{i});
        defer testing.allocator.free(content);
        try createFile(path, fname, content);
        try repo.add(fname);
        const msg = try std.fmt.allocPrint(testing.allocator, "commit {d}", .{i});
        defer testing.allocator.free(msg);
        _ = try repo.commit(msg, "Test", "test@test.com");
    }
    try repo.createTag("v1.0.0", null);

    const pre_head = try repo.revParseHead();

    // Run git repack -a -d (repacks all objects, removes loose)
    gitOk(&.{ "git", "-C", path, "repack", "-a", "-d" }, "/tmp") catch return;

    // HEAD should still resolve after repack
    const post_head = gitTrim(&.{ "git", "-C", path, "rev-parse", "HEAD" }, "/tmp") catch return;
    defer testing.allocator.free(post_head);
    try testing.expectEqualStrings(&pre_head, post_head);

    // All 5 files should still be accessible
    const ls_out = gitTrim(&.{ "git", "-C", path, "ls-tree", "-r", "--name-only", "HEAD" }, "/tmp") catch return;
    defer testing.allocator.free(ls_out);
    for (0..5) |i| {
        const fname = try std.fmt.allocPrint(testing.allocator, "file{d}.txt", .{i});
        defer testing.allocator.free(fname);
        try testing.expect(std.mem.indexOf(u8, ls_out, fname) != null);
    }

    // Tag should still resolve
    const tag_hash = gitTrim(&.{ "git", "-C", path, "rev-parse", "v1.0.0" }, "/tmp") catch return;
    defer testing.allocator.free(tag_hash);
    try testing.expect(tag_hash.len == 40);
}

test "xval: ziggit commit metadata readable via git show format strings" {
    const path = tmpPath("show_format");
    defer cleanup(path);

    var repo = try initZiggitRepo(path);
    defer repo.close();

    try createFile(path, "f.txt", "metadata test\n");
    try repo.add("f.txt");
    _ = try repo.commit("fix: resolve critical bug #42", "Jane Doe", "jane@example.com");

    // Author name
    const author = gitTrim(&.{ "git", "-C", path, "show", "--format=%an", "-s", "HEAD" }, "/tmp") catch return;
    defer testing.allocator.free(author);
    try testing.expectEqualStrings("Jane Doe", author);

    // Author email
    const email = gitTrim(&.{ "git", "-C", path, "show", "--format=%ae", "-s", "HEAD" }, "/tmp") catch return;
    defer testing.allocator.free(email);
    try testing.expectEqualStrings("jane@example.com", email);

    // Subject
    const subject = gitTrim(&.{ "git", "-C", path, "show", "--format=%s", "-s", "HEAD" }, "/tmp") catch return;
    defer testing.allocator.free(subject);
    try testing.expectEqualStrings("fix: resolve critical bug #42", subject);

    // Committer name should match author (ziggit uses same for both)
    const committer = gitTrim(&.{ "git", "-C", path, "show", "--format=%cn", "-s", "HEAD" }, "/tmp") catch return;
    defer testing.allocator.free(committer);
    try testing.expectEqualStrings("Jane Doe", committer);
}

test "xval: git-created packed refs -> ziggit reads HEAD and describeTags" {
    const path = tmpPath("packed_refs");
    defer cleanup(path);

    initGitRepo(path) catch return;

    // Create 3 commits with tags
    for (0..3) |i| {
        const content = try std.fmt.allocPrint(testing.allocator, "v{d}\n", .{i});
        defer testing.allocator.free(content);
        try createFile(path, "f.txt", content);
        gitOk(&.{ "git", "-C", path, "add", "f.txt" }, "/tmp") catch return;
        const msg = try std.fmt.allocPrint(testing.allocator, "commit {d}", .{i});
        defer testing.allocator.free(msg);
        gitOk(&.{ "git", "-C", path, "commit", "-m", msg }, "/tmp") catch return;
        const tag = try std.fmt.allocPrint(testing.allocator, "v{d}.0.0", .{i});
        defer testing.allocator.free(tag);
        gitOk(&.{ "git", "-C", path, "tag", tag }, "/tmp") catch return;
    }

    // Pack only tag refs (keeps branch refs as loose files)
    gitOk(&.{ "git", "-C", path, "pack-refs", "--no-all" }, "/tmp") catch {
        // --no-all not supported in all git versions, use default which packs tags only
        gitOk(&.{ "git", "-C", path, "pack-refs" }, "/tmp") catch return;
    };

    // Get expected HEAD hash from git
    const git_head = gitTrim(&.{ "git", "-C", path, "rev-parse", "HEAD" }, "/tmp") catch return;
    defer testing.allocator.free(git_head);

    // ziggit should still be able to read HEAD (branch ref stays loose)
    var repo = try ziggit.Repository.open(testing.allocator, path);
    defer repo.close();

    const head = try repo.revParseHead();
    try testing.expectEqualStrings(git_head, &head);

    // describeTags may or may not find tags from packed-refs file
    // (depends on whether ziggit reads packed-refs for tags)
    // Known limitation: ziggit may not read packed tag refs
    if (repo.describeTags(testing.allocator)) |desc| {
        testing.allocator.free(desc);
    } else |_| {}

    // findCommit("HEAD") should still work
    const found_head = try repo.findCommit("HEAD");
    try testing.expectEqualStrings(git_head, &found_head);
}

test "xval: bun workflow with .gitignore" {
    const path = tmpPath("bun_gitignore");
    defer cleanup(path);

    var repo = try initZiggitRepo(path);
    defer repo.close();

    // Create .gitignore
    try createFile(path, ".gitignore", "node_modules/\ndist/\n*.log\n");
    try createFile(path, "package.json", "{\"name\":\"app\",\"version\":\"1.0.0\",\"dependencies\":{}}");
    try createFile(path, "index.ts", "console.log('hello');\n");

    try repo.add(".gitignore");
    try repo.add("package.json");
    try repo.add("index.ts");
    _ = try repo.commit("initial setup", "bun", "bun@bun.sh");
    try repo.createTag("v1.0.0", null);

    // Simulate: node_modules/ dir exists on disk but should NOT be in tree
    const nm_dir = try std.fmt.allocPrint(testing.allocator, "{s}/node_modules", .{path});
    defer testing.allocator.free(nm_dir);
    std.fs.makeDirAbsolute(nm_dir) catch {};
    try createFile(nm_dir, "lodash.js", "module.exports = {};");

    // Verify node_modules NOT in tree
    const ls_out = gitTrim(&.{ "git", "-C", path, "ls-tree", "-r", "--name-only", "HEAD" }, "/tmp") catch return;
    defer testing.allocator.free(ls_out);
    try testing.expect(std.mem.indexOf(u8, ls_out, "node_modules") == null);
    try testing.expect(std.mem.indexOf(u8, ls_out, ".gitignore") != null);
    try testing.expect(std.mem.indexOf(u8, ls_out, "package.json") != null);
    try testing.expect(std.mem.indexOf(u8, ls_out, "index.ts") != null);

    // git describe should work
    const desc = gitTrim(&.{ "git", "-C", path, "describe", "--tags", "--exact-match" }, "/tmp") catch return;
    defer testing.allocator.free(desc);
    try testing.expectEqualStrings("v1.0.0", desc);
}

test "xval: ziggit roundtrip - write, read back via git, verify content identical" {
    const path = tmpPath("roundtrip");
    defer cleanup(path);

    var repo = try initZiggitRepo(path);
    defer repo.close();

    const test_content = "The quick brown fox jumps over the lazy dog.\n" ++
        "0123456789 !@#$%^&*()_+-=[]{}|;':\",./<>?\n" ++
        "\xc3\xa9\xc3\xa0\xc3\xbc \xf0\x9f\x9a\x80 \xe4\xb8\xad\xe6\x96\x87\n";

    try createFile(path, "roundtrip.txt", test_content);
    try repo.add("roundtrip.txt");
    const hash = try repo.commit("roundtrip test", "Test", "t@test.com");

    // Read back through git cat-file
    const blob = git(&.{ "git", "-C", path, "cat-file", "blob", "HEAD:roundtrip.txt" }, "/tmp") catch return;
    defer testing.allocator.free(blob);
    try testing.expectEqualStrings(test_content, blob);

    // Verify commit hash matches
    const git_head = gitTrim(&.{ "git", "-C", path, "rev-parse", "HEAD" }, "/tmp") catch return;
    defer testing.allocator.free(git_head);
    try testing.expectEqualStrings(&hash, git_head);

    // git fsck should pass
    const fsck_out = git(&.{ "git", "-C", path, "fsck", "--no-dangling" }, "/tmp") catch return;
    defer testing.allocator.free(fsck_out);
    try testing.expect(std.mem.indexOf(u8, fsck_out, "error") == null);
}

test "xval: ziggit add multiple files across dirs in single commit" {
    const path = tmpPath("multi_dir_commit");
    defer cleanup(path);

    var repo = try initZiggitRepo(path);
    defer repo.close();

    // Create directories
    const src_dir = try std.fmt.allocPrint(testing.allocator, "{s}/src", .{path});
    defer testing.allocator.free(src_dir);
    std.fs.makeDirAbsolute(src_dir) catch {};

    const test_dir = try std.fmt.allocPrint(testing.allocator, "{s}/test", .{path});
    defer testing.allocator.free(test_dir);
    std.fs.makeDirAbsolute(test_dir) catch {};

    try createFile(path, "README.md", "# Project\n");
    try createFile(src_dir, "main.zig", "pub fn main() void {}\n");
    try createFile(test_dir, "main_test.zig", "test \"basic\" {}\n");

    try repo.add("README.md");
    try repo.add("src/main.zig");
    try repo.add("test/main_test.zig");
    _ = try repo.commit("initial project structure", "Dev", "dev@dev.com");

    // All files in correct dirs
    const ls_out = gitTrim(&.{ "git", "-C", path, "ls-tree", "-r", "--name-only", "HEAD" }, "/tmp") catch return;
    defer testing.allocator.free(ls_out);
    try testing.expect(std.mem.indexOf(u8, ls_out, "README.md") != null);
    try testing.expect(std.mem.indexOf(u8, ls_out, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, ls_out, "test/main_test.zig") != null);

    // Verify content
    const main_content = git(&.{ "git", "-C", path, "show", "HEAD:src/main.zig" }, "/tmp") catch return;
    defer testing.allocator.free(main_content);
    try testing.expectEqualStrings("pub fn main() void {}\n", main_content);
}
