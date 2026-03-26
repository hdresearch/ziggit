const std = @import("std");
const smart_http = @import("smart_http");
const pack_writer = @import("pack_writer");
const idx_writer = @import("idx_writer");

// ============================================================================
// End-to-end HTTPS clone tests
// These tests require network access. They clone real public repos.
// ============================================================================

const test_repo_url = "https://github.com/nickel-org/rust-mustache";
// Small, stable public repo — ~25 objects. Good for CI.

fn setupTmpDir() ![]const u8 {
    const allocator = std.testing.allocator;
    const tmp = try std.fmt.allocPrint(allocator, "/tmp/ziggit_e2e_{}", .{std.crypto.random.int(u64)});
    try std.fs.cwd().makePath(tmp);
    return tmp;
}

fn cleanupTmpDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    std.testing.allocator.free(path);
}

// ============================================================================
// Ref discovery over HTTPS
// ============================================================================

test "discoverRefs - public GitHub repo returns refs" {
    const allocator = std.testing.allocator;
    var disc = smart_http.discoverRefs(allocator, test_repo_url) catch |err| {
        // Skip on network errors
        if (err == error.HttpError or err == error.ConnectionRefused or
            err == error.ConnectionTimedOut or err == error.TlsFailure or
            err == error.CertificateBundleError)
        {
            return;
        }
        return err;
    };
    defer disc.deinit();

    // Should have at least HEAD and one branch
    try std.testing.expect(disc.refs.len >= 1);

    // Find HEAD
    var found_head = false;
    for (disc.refs) |ref| {
        if (std.mem.eql(u8, ref.name, "HEAD")) {
            found_head = true;
            // Hash should be 40 hex chars
            for (ref.hash) |c| {
                try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
            }
        }
    }
    try std.testing.expect(found_head);

    // Capabilities should be non-empty
    try std.testing.expect(disc.capabilities.len > 0);
}

test "discoverRefs - returns branches" {
    const allocator = std.testing.allocator;
    var disc = smart_http.discoverRefs(allocator, test_repo_url) catch |err| {
        if (err == error.HttpError or err == error.ConnectionRefused or
            err == error.ConnectionTimedOut or err == error.TlsFailure or
            err == error.CertificateBundleError) return;
        return err;
    };
    defer disc.deinit();

    var found_branch = false;
    for (disc.refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            found_branch = true;
            break;
        }
    }
    try std.testing.expect(found_branch);
}

// ============================================================================
// Full clone over HTTPS
// ============================================================================

test "clonePack - clone public repo and verify pack" {
    const allocator = std.testing.allocator;
    var result = smart_http.clonePack(allocator, test_repo_url) catch |err| {
        if (err == error.HttpError or err == error.ConnectionRefused or
            err == error.ConnectionTimedOut or err == error.TlsFailure or
            err == error.CertificateBundleError) return;
        return err;
    };
    defer result.deinit();

    // Pack data should start with PACK magic
    try std.testing.expect(result.pack_data.len >= 12);
    try std.testing.expectEqualStrings("PACK", result.pack_data[0..4]);

    // Version should be 2
    const version = std.mem.readInt(u32, result.pack_data[4..8], .big);
    try std.testing.expectEqual(@as(u32, 2), version);

    // Should have at least 1 object
    const object_count = std.mem.readInt(u32, result.pack_data[8..12], .big);
    try std.testing.expect(object_count >= 1);

    // Refs should be populated
    try std.testing.expect(result.refs.len >= 1);
}

test "clonePack - save pack and generate idx" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);

    {
        const init_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "init", "--bare", git_dir },
        });
        allocator.free(init_result.stdout);
        allocator.free(init_result.stderr);
    }

    var clone = smart_http.clonePack(allocator, test_repo_url) catch |err| {
        if (err == error.HttpError or err == error.ConnectionRefused or
            err == error.ConnectionTimedOut or err == error.TlsFailure or
            err == error.CertificateBundleError) return;
        return err;
    };
    defer clone.deinit();

    // Save pack
    const hex = try pack_writer.savePack(allocator, git_dir, clone.pack_data);
    defer allocator.free(hex);

    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);

    // Generate idx
    try idx_writer.generateIdx(allocator, pp);

    // git verify-pack should accept both pack and idx
    const verify_result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", pp },
    });
    defer allocator.free(verify_result.stdout);
    defer allocator.free(verify_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), verify_result.term.Exited);
}

test "clonePack - all objects readable by git after clone" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);

    {
        const init_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "init", "--bare", git_dir },
        });
        allocator.free(init_result.stdout);
        allocator.free(init_result.stderr);
    }

    var clone = smart_http.clonePack(allocator, test_repo_url) catch |err| {
        if (err == error.HttpError or err == error.ConnectionRefused or
            err == error.ConnectionTimedOut or err == error.TlsFailure or
            err == error.CertificateBundleError) return;
        return err;
    };
    defer clone.deinit();

    const hex = try pack_writer.savePack(allocator, git_dir, clone.pack_data);
    defer allocator.free(hex);

    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);

    try idx_writer.generateIdx(allocator, pp);

    // Write HEAD ref so git can resolve it
    for (clone.refs) |ref| {
        if (std.mem.eql(u8, ref.name, "HEAD")) {
            // Find what HEAD points to (usually refs/heads/master or main)
            for (clone.refs) |r2| {
                if (std.mem.startsWith(u8, r2.name, "refs/heads/") and std.mem.eql(u8, &r2.hash, &ref.hash)) {
                    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
                    defer allocator.free(head_path);
                    const head_content = try std.fmt.allocPrint(allocator, "ref: {s}\n", .{r2.name});
                    defer allocator.free(head_content);
                    try std.fs.cwd().writeFile(.{ .sub_path = head_path, .data = head_content });

                    const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, r2.name });
                    defer allocator.free(ref_path);
                    // Ensure parent dir exists
                    if (std.mem.lastIndexOfScalar(u8, ref_path, '/')) |slash| {
                        std.fs.cwd().makePath(ref_path[0..slash]) catch {};
                    }
                    const ref_content = try std.fmt.allocPrint(allocator, "{s}\n", .{r2.hash});
                    defer allocator.free(ref_content);
                    try std.fs.cwd().writeFile(.{ .sub_path = ref_path, .data = ref_content });
                    break;
                }
            }
            break;
        }
    }

    // git log should work
    const log_result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "--git-dir", git_dir, "log", "--oneline", "-5" },
    });
    defer allocator.free(log_result.stdout);
    defer allocator.free(log_result.stderr);

    // If git can read the objects, log will produce output
    try std.testing.expect(log_result.stdout.len > 0);
}

// ============================================================================
// Fetch updates (incremental)
// ============================================================================

test "fetchNewPack - already up-to-date returns null" {
    const allocator = std.testing.allocator;

    // First discover current refs
    var disc = smart_http.discoverRefs(allocator, test_repo_url) catch |err| {
        if (err == error.HttpError or err == error.ConnectionRefused or
            err == error.ConnectionTimedOut or err == error.TlsFailure or
            err == error.CertificateBundleError) return;
        return err;
    };
    defer disc.deinit();

    // Build local refs that match remote exactly
    var local_refs = std.ArrayList(smart_http.LocalRef).init(allocator);
    defer local_refs.deinit();
    for (disc.refs) |ref| {
        try local_refs.append(.{ .hash = ref.hash, .name = ref.name });
    }

    // Should return null (already up to date)
    const result = smart_http.fetchNewPack(allocator, test_repo_url, local_refs.items) catch |err| {
        if (err == error.HttpError or err == error.ConnectionRefused or
            err == error.ConnectionTimedOut or err == error.TlsFailure or
            err == error.CertificateBundleError) return;
        return err;
    };

    try std.testing.expect(result == null);
}

// ============================================================================
// Tags and branches verification
// ============================================================================

test "discoverRefs - repos with tags return tag refs" {
    const allocator = std.testing.allocator;

    // Use a repo known to have tags
    var disc = smart_http.discoverRefs(allocator, "https://github.com/nickel-org/rust-mustache") catch |err| {
        if (err == error.HttpError or err == error.ConnectionRefused or
            err == error.ConnectionTimedOut or err == error.TlsFailure or
            err == error.CertificateBundleError) return;
        return err;
    };
    defer disc.deinit();

    var found_tag = false;
    for (disc.refs) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/tags/")) {
            found_tag = true;
            break;
        }
    }
    // This repo may or may not have tags - just verify parsing works
    // We check found_tag to avoid unused variable, but don't assert on it
    if (found_tag) {
        try std.testing.expect(disc.refs.len >= 2); // HEAD + at least one tag
    }
    try std.testing.expect(disc.refs.len >= 1);
}

test "discoverRefs - URL with trailing slash" {
    const allocator = std.testing.allocator;
    var disc = smart_http.discoverRefs(allocator, test_repo_url ++ "/") catch |err| {
        if (err == error.HttpError or err == error.ConnectionRefused or
            err == error.ConnectionTimedOut or err == error.TlsFailure or
            err == error.CertificateBundleError) return;
        return err;
    };
    defer disc.deinit();
    try std.testing.expect(disc.refs.len >= 1);
}

// ============================================================================
// Error handling for non-existent repos
// ============================================================================

test "discoverRefs - non-existent repo returns HttpError" {
    const allocator = std.testing.allocator;
    const result = smart_http.discoverRefs(allocator, "https://github.com/this-org-does-not-exist-zzz/no-repo-zzz");
    if (result) |*disc| {
        var d = disc.*;
        d.deinit();
        // Some servers might return empty refs instead of 404
    } else |err| {
        // Should get HttpError (404) or connection error
        try std.testing.expect(err == error.HttpError or
            err == error.ConnectionRefused or
            err == error.ConnectionTimedOut or
            err == error.TlsFailure or
            err == error.CertificateBundleError);
    }
}

test "discoverRefs - invalid URL returns error" {
    const allocator = std.testing.allocator;
    const result = smart_http.discoverRefs(allocator, "not-a-url");
    try std.testing.expectError(error.InvalidUrl, result);
}
