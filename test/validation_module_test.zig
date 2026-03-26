// test/validation_module_test.zig - Tests for git validation utilities
// SHA-1 validation, ref name validation, object validation, path security
const std = @import("std");
const validation = @import("validation");
const testing = std.testing;

const GitValidationError = validation.GitValidationError;

// ============================================================
// SHA-1 hash validation
// ============================================================

test "validateSHA1Hash: valid lowercase hash" {
    try validation.validateSHA1Hash("abcdef1234567890abcdef1234567890abcdef12");
}

test "validateSHA1Hash: valid uppercase hash" {
    try validation.validateSHA1Hash("ABCDEF1234567890ABCDEF1234567890ABCDEF12");
}

test "validateSHA1Hash: valid mixed case hash" {
    try validation.validateSHA1Hash("AbCdEf1234567890AbCdEf1234567890AbCdEf12");
}

test "validateSHA1Hash: all zeros" {
    try validation.validateSHA1Hash("0000000000000000000000000000000000000000");
}

test "validateSHA1Hash: all f's" {
    try validation.validateSHA1Hash("ffffffffffffffffffffffffffffffffffffffff");
}

test "validateSHA1Hash: too short" {
    try testing.expectError(GitValidationError.InvalidSHA1Length, validation.validateSHA1Hash("abc"));
}

test "validateSHA1Hash: too long" {
    try testing.expectError(GitValidationError.InvalidSHA1Length, validation.validateSHA1Hash("a" ** 41));
}

test "validateSHA1Hash: empty" {
    try testing.expectError(GitValidationError.InvalidSHA1Length, validation.validateSHA1Hash(""));
}

test "validateSHA1Hash: 39 chars" {
    try testing.expectError(GitValidationError.InvalidSHA1Length, validation.validateSHA1Hash("a" ** 39));
}

test "validateSHA1Hash: invalid char g" {
    try testing.expectError(GitValidationError.InvalidSHA1Hash, validation.validateSHA1Hash("g" ** 40));
}

test "validateSHA1Hash: invalid char with space" {
    try testing.expectError(GitValidationError.InvalidSHA1Hash, validation.validateSHA1Hash("abcdef1234567890 bcdef1234567890abcdef12"));
}

// ============================================================
// SHA-1 normalized validation
// ============================================================

test "validateSHA1Normalized: valid lowercase" {
    try validation.validateSHA1Normalized("abcdef1234567890abcdef1234567890abcdef12");
}

test "validateSHA1Normalized: rejects uppercase" {
    try testing.expectError(GitValidationError.InvalidSHA1Hash, validation.validateSHA1Normalized("ABCDEF1234567890abcdef1234567890abcdef12"));
}

test "validateSHA1Normalized: all zeros is normalized" {
    try validation.validateSHA1Normalized("0000000000000000000000000000000000000000");
}

// ============================================================
// normalizeSHA1Hash
// ============================================================

test "normalizeSHA1Hash: lowercase stays same" {
    const result = try validation.normalizeSHA1Hash("abcdef1234567890abcdef1234567890abcdef12", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("abcdef1234567890abcdef1234567890abcdef12", result);
}

test "normalizeSHA1Hash: uppercase is lowered" {
    const result = try validation.normalizeSHA1Hash("ABCDEF1234567890ABCDEF1234567890ABCDEF12", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("abcdef1234567890abcdef1234567890abcdef12", result);
}

test "normalizeSHA1Hash: mixed case is normalized" {
    const result = try validation.normalizeSHA1Hash("AbCdEf1234567890AbCdEf1234567890AbCdEf12", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("abcdef1234567890abcdef1234567890abcdef12", result);
}

test "normalizeSHA1Hash: invalid input returns error" {
    try testing.expectError(GitValidationError.InvalidSHA1Length, validation.normalizeSHA1Hash("short", testing.allocator));
}

// ============================================================
// Ref name validation
// ============================================================

test "validateRefName: valid branch ref" {
    try validation.validateRefName("refs/heads/master");
}

test "validateRefName: valid tag ref" {
    try validation.validateRefName("refs/tags/v1.0.0");
}

test "validateRefName: valid remote ref" {
    try validation.validateRefName("refs/remotes/origin/main");
}

test "validateRefName: simple name" {
    try validation.validateRefName("master");
}

test "validateRefName: name with slash" {
    try validation.validateRefName("feature/my-feature");
}

test "validateRefName: empty name" {
    try testing.expectError(GitValidationError.InvalidConfiguration, validation.validateRefName(""));
}

test "validateRefName: starts with dot" {
    try testing.expectError(GitValidationError.InvalidConfiguration, validation.validateRefName(".hidden"));
}

test "validateRefName: ends with dot" {
    try testing.expectError(GitValidationError.InvalidConfiguration, validation.validateRefName("bad."));
}

test "validateRefName: double dot" {
    try testing.expectError(GitValidationError.InvalidConfiguration, validation.validateRefName("bad..name"));
}

test "validateRefName: contains space" {
    try testing.expectError(GitValidationError.InvalidConfiguration, validation.validateRefName("has space"));
}

test "validateRefName: contains tilde" {
    try testing.expectError(GitValidationError.InvalidConfiguration, validation.validateRefName("bad~name"));
}

test "validateRefName: contains caret" {
    try testing.expectError(GitValidationError.InvalidConfiguration, validation.validateRefName("bad^name"));
}

test "validateRefName: contains colon" {
    try testing.expectError(GitValidationError.InvalidConfiguration, validation.validateRefName("bad:name"));
}

test "validateRefName: contains question mark" {
    try testing.expectError(GitValidationError.InvalidConfiguration, validation.validateRefName("bad?name"));
}

test "validateRefName: contains asterisk" {
    try testing.expectError(GitValidationError.InvalidConfiguration, validation.validateRefName("bad*name"));
}

test "validateRefName: contains bracket" {
    try testing.expectError(GitValidationError.InvalidConfiguration, validation.validateRefName("bad[name"));
}

test "validateRefName: contains control character" {
    try testing.expectError(GitValidationError.InvalidConfiguration, validation.validateRefName("bad\x01name"));
}

test "validateRefName: too long" {
    try testing.expectError(GitValidationError.InvalidConfiguration, validation.validateRefName("a" ** 1025));
}

test "validateRefName: max length is ok" {
    try validation.validateRefName("a" ** 1024);
}

// ============================================================
// Object validation
// ============================================================

test "validateGitObject: valid blob (any data)" {
    try validation.validateGitObject("blob", "hello world");
}

test "validateGitObject: empty blob" {
    try validation.validateGitObject("blob", "");
}

test "validateGitObject: invalid type" {
    try testing.expectError(GitValidationError.InvalidObjectData, validation.validateGitObject("invalid", "data"));
}

test "validateGitObject: valid commit" {
    const commit_data =
        "tree 0123456789abcdef0123456789abcdef01234567\n" ++
        "author Test <test@test.com> 1234567890 +0000\n" ++
        "committer Test <test@test.com> 1234567890 +0000\n" ++
        "\n" ++
        "Initial commit\n";
    try validation.validateGitObject("commit", commit_data);
}

test "validateGitObject: commit with parent" {
    const commit_data =
        "tree 0123456789abcdef0123456789abcdef01234567\n" ++
        "parent abcdef0123456789abcdef0123456789abcdef01\n" ++
        "author Test <test@test.com> 1234567890 +0000\n" ++
        "committer Test <test@test.com> 1234567890 +0000\n" ++
        "\n" ++
        "Second commit\n";
    try validation.validateGitObject("commit", commit_data);
}

test "validateGitObject: commit missing tree" {
    const commit_data =
        "author Test <test@test.com> 1234567890 +0000\n" ++
        "committer Test <test@test.com> 1234567890 +0000\n" ++
        "\n" ++
        "No tree\n";
    try testing.expectError(GitValidationError.MalformedGitObject, validation.validateGitObject("commit", commit_data));
}

test "validateGitObject: commit missing author" {
    const commit_data =
        "tree 0123456789abcdef0123456789abcdef01234567\n" ++
        "committer Test <test@test.com> 1234567890 +0000\n" ++
        "\n" ++
        "No author\n";
    try testing.expectError(GitValidationError.MalformedGitObject, validation.validateGitObject("commit", commit_data));
}

test "validateGitObject: commit with invalid tree hash" {
    const commit_data =
        "tree xyz\n" ++
        "author Test <test@test.com> 1234567890 +0000\n" ++
        "committer Test <test@test.com> 1234567890 +0000\n" ++
        "\n" ++
        "Bad tree hash\n";
    try testing.expectError(GitValidationError.MalformedGitObject, validation.validateGitObject("commit", commit_data));
}

test "validateGitObject: valid tag" {
    const tag_data =
        "object 0123456789abcdef0123456789abcdef01234567\n" ++
        "type commit\n" ++
        "tag v1.0\n" ++
        "tagger Test <test@test.com> 1234567890 +0000\n" ++
        "\n" ++
        "Release v1.0\n";
    try validation.validateGitObject("tag", tag_data);
}

test "validateGitObject: tag without tagger is valid" {
    const tag_data =
        "object 0123456789abcdef0123456789abcdef01234567\n" ++
        "type commit\n" ++
        "tag v1.0\n" ++
        "\n" ++
        "Release v1.0\n";
    try validation.validateGitObject("tag", tag_data);
}

test "validateGitObject: tag missing object" {
    const tag_data =
        "type commit\n" ++
        "tag v1.0\n" ++
        "\n" ++
        "No object\n";
    try testing.expectError(GitValidationError.MalformedGitObject, validation.validateGitObject("tag", tag_data));
}

test "validateGitObject: valid tree data" {
    // Construct valid tree entry: "100644 file.txt\0" + 20 bytes SHA-1
    var tree_data: [256]u8 = undefined;
    const prefix = "100644 file.txt\x00";
    @memcpy(tree_data[0..prefix.len], prefix);
    @memcpy(tree_data[prefix.len .. prefix.len + 20], &([_]u8{0xaa} ** 20));
    try validation.validateGitObject("tree", tree_data[0 .. prefix.len + 20]);
}

// ============================================================
// Path security validation
// ============================================================

test "validatePathSecurity: normal file" {
    try validation.validatePathSecurity("file.txt");
}

test "validatePathSecurity: subdirectory" {
    try validation.validatePathSecurity("src/main.zig");
}

test "validatePathSecurity: deep path" {
    try validation.validatePathSecurity("a/b/c/d/e/f.txt");
}

test "validatePathSecurity: dot-dot traversal" {
    try testing.expectError(GitValidationError.SecurityViolation, validation.validatePathSecurity("../etc/passwd"));
}

test "validatePathSecurity: dot-dot in middle" {
    try testing.expectError(GitValidationError.SecurityViolation, validation.validatePathSecurity("src/../../../etc/passwd"));
}

test "validatePathSecurity: absolute path" {
    try testing.expectError(GitValidationError.SecurityViolation, validation.validatePathSecurity("/etc/passwd"));
}

test "validatePathSecurity: null byte" {
    try testing.expectError(GitValidationError.SecurityViolation, validation.validatePathSecurity("file\x00.txt"));
}

test "validatePathSecurity: empty path is ok" {
    try validation.validatePathSecurity("");
}

test "validatePathSecurity: single dot is ok" {
    try validation.validatePathSecurity(".");
}

test "validatePathSecurity: hidden file is ok" {
    try validation.validatePathSecurity(".gitignore");
}
