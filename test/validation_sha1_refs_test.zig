// test/validation_sha1_refs_test.zig - Tests for validation module (SHA-1, refs, objects, paths)
const std = @import("std");
const testing = std.testing;
const validation = @import("validation");

// ============================================================================
// validateSHA1Hash
// ============================================================================

test "validateSHA1Hash: valid 40-char lowercase hex" {
    try validation.validateSHA1Hash("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
}

test "validateSHA1Hash: valid with uppercase hex" {
    try validation.validateSHA1Hash("E69DE29BB2D1D6434B8B29AE775AD8C2E48C5391");
}

test "validateSHA1Hash: all zeros" {
    try validation.validateSHA1Hash("0000000000000000000000000000000000000000");
}

test "validateSHA1Hash: all f's" {
    try validation.validateSHA1Hash("ffffffffffffffffffffffffffffffffffffffff");
}

test "validateSHA1Hash: too short" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Length,
        validation.validateSHA1Hash("e69de29bb2d1d643"),
    );
}

test "validateSHA1Hash: too long" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Length,
        validation.validateSHA1Hash("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391a"),
    );
}

test "validateSHA1Hash: empty string" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Length,
        validation.validateSHA1Hash(""),
    );
}

test "validateSHA1Hash: non-hex characters" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Hash,
        validation.validateSHA1Hash("g69de29bb2d1d6434b8b29ae775ad8c2e48c5391"),
    );
}

test "validateSHA1Hash: spaces" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Hash,
        validation.validateSHA1Hash("e69de29bb2d1d643 b8b29ae775ad8c2e48c5391"),
    );
}

// ============================================================================
// validateSHA1Normalized
// ============================================================================

test "validateSHA1Normalized: lowercase is valid" {
    try validation.validateSHA1Normalized("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
}

test "validateSHA1Normalized: uppercase is rejected" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Hash,
        validation.validateSHA1Normalized("E69DE29BB2D1D6434B8B29AE775AD8C2E48C5391"),
    );
}

test "validateSHA1Normalized: mixed case is rejected" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Hash,
        validation.validateSHA1Normalized("e69de29bB2d1d6434b8b29ae775ad8c2e48c5391"),
    );
}

// ============================================================================
// normalizeSHA1Hash
// ============================================================================

test "normalizeSHA1Hash: lowercase stays lowercase" {
    const result = try validation.normalizeSHA1Hash("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", result);
}

test "normalizeSHA1Hash: uppercase becomes lowercase" {
    const result = try validation.normalizeSHA1Hash("E69DE29BB2D1D6434B8B29AE775AD8C2E48C5391", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", result);
}

test "normalizeSHA1Hash: mixed case becomes lowercase" {
    const result = try validation.normalizeSHA1Hash("aAbBcCdDeEfF00112233445566778899aAbBcCdD", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("aabbccddeeff00112233445566778899aabbccdd", result);
}

test "normalizeSHA1Hash: rejects invalid hash" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Length,
        validation.normalizeSHA1Hash("short", testing.allocator),
    );
}

// ============================================================================
// validateRefName
// ============================================================================

test "validateRefName: valid branch names" {
    try validation.validateRefName("main");
    try validation.validateRefName("feature/new-thing");
    try validation.validateRefName("refs/heads/master");
    try validation.validateRefName("refs/tags/v1.0");
    try validation.validateRefName("a");
}

test "validateRefName: empty name is rejected" {
    try testing.expectError(
        validation.GitValidationError.InvalidConfiguration,
        validation.validateRefName(""),
    );
}

test "validateRefName: leading dot is rejected" {
    try testing.expectError(
        validation.GitValidationError.InvalidConfiguration,
        validation.validateRefName(".hidden"),
    );
}

test "validateRefName: trailing dot is rejected" {
    try testing.expectError(
        validation.GitValidationError.InvalidConfiguration,
        validation.validateRefName("branch."),
    );
}

test "validateRefName: double dot is rejected" {
    try testing.expectError(
        validation.GitValidationError.InvalidConfiguration,
        validation.validateRefName("branch..name"),
    );
}

test "validateRefName: space is rejected" {
    try testing.expectError(
        validation.GitValidationError.InvalidConfiguration,
        validation.validateRefName("branch name"),
    );
}

test "validateRefName: tilde is rejected" {
    try testing.expectError(
        validation.GitValidationError.InvalidConfiguration,
        validation.validateRefName("branch~1"),
    );
}

test "validateRefName: caret is rejected" {
    try testing.expectError(
        validation.GitValidationError.InvalidConfiguration,
        validation.validateRefName("branch^"),
    );
}

test "validateRefName: colon is rejected" {
    try testing.expectError(
        validation.GitValidationError.InvalidConfiguration,
        validation.validateRefName("branch:name"),
    );
}

test "validateRefName: question mark is rejected" {
    try testing.expectError(
        validation.GitValidationError.InvalidConfiguration,
        validation.validateRefName("branch?"),
    );
}

test "validateRefName: asterisk is rejected" {
    try testing.expectError(
        validation.GitValidationError.InvalidConfiguration,
        validation.validateRefName("branch*"),
    );
}

test "validateRefName: bracket is rejected" {
    try testing.expectError(
        validation.GitValidationError.InvalidConfiguration,
        validation.validateRefName("branch[0]"),
    );
}

test "validateRefName: control characters rejected" {
    try testing.expectError(
        validation.GitValidationError.InvalidConfiguration,
        validation.validateRefName("branch\x01name"),
    );
}

// ============================================================================
// validateGitObject
// ============================================================================

test "validateGitObject: blob accepts any data" {
    try validation.validateGitObject("blob", "any content here");
    try validation.validateGitObject("blob", "");
    try validation.validateGitObject("blob", "binary\x00data");
}

test "validateGitObject: invalid type rejected" {
    try testing.expectError(
        validation.GitValidationError.InvalidObjectData,
        validation.validateGitObject("invalid", "data"),
    );
}

test "validateGitObject: commit requires tree/author/committer" {
    const valid_commit =
        "tree e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\n" ++
        "author Test <test@test.com> 1234567890 +0000\n" ++
        "committer Test <test@test.com> 1234567890 +0000\n" ++
        "\n" ++
        "commit message\n";
    try validation.validateGitObject("commit", valid_commit);
}

test "validateGitObject: commit with parent" {
    const commit_with_parent =
        "tree e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\n" ++
        "parent b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0\n" ++
        "author Test <test@test.com> 1234567890 +0000\n" ++
        "committer Test <test@test.com> 1234567890 +0000\n" ++
        "\n" ++
        "second commit\n";
    try validation.validateGitObject("commit", commit_with_parent);
}

test "validateGitObject: commit missing tree is rejected" {
    const bad_commit =
        "author Test <test@test.com> 1234567890 +0000\n" ++
        "committer Test <test@test.com> 1234567890 +0000\n" ++
        "\n" ++
        "no tree\n";
    try testing.expectError(
        validation.GitValidationError.MalformedGitObject,
        validation.validateGitObject("commit", bad_commit),
    );
}

test "validateGitObject: commit with invalid tree hash" {
    const bad_commit =
        "tree INVALID_HASH\n" ++
        "author Test <test@test.com> 1234567890 +0000\n" ++
        "committer Test <test@test.com> 1234567890 +0000\n" ++
        "\n" ++
        "bad tree\n";
    try testing.expectError(
        validation.GitValidationError.MalformedGitObject,
        validation.validateGitObject("commit", bad_commit),
    );
}

test "validateGitObject: tag requires object/type/tag" {
    const valid_tag =
        "object e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\n" ++
        "type commit\n" ++
        "tag v1.0\n" ++
        "tagger Test <test@test.com> 1234567890 +0000\n" ++
        "\n" ++
        "Release v1.0\n";
    try validation.validateGitObject("tag", valid_tag);
}

test "validateGitObject: tag missing object is rejected" {
    const bad_tag =
        "type commit\n" ++
        "tag v1.0\n" ++
        "\n" ++
        "bad tag\n";
    try testing.expectError(
        validation.GitValidationError.MalformedGitObject,
        validation.validateGitObject("tag", bad_tag),
    );
}

// ============================================================================
// validatePathSecurity
// ============================================================================

test "validatePathSecurity: normal paths accepted" {
    try validation.validatePathSecurity("file.txt");
    try validation.validatePathSecurity("dir/file.txt");
    try validation.validatePathSecurity("a/b/c/d.zig");
}

test "validatePathSecurity: dot-dot rejected" {
    try testing.expectError(
        validation.GitValidationError.SecurityViolation,
        validation.validatePathSecurity("../etc/passwd"),
    );
}

test "validatePathSecurity: embedded dot-dot rejected" {
    try testing.expectError(
        validation.GitValidationError.SecurityViolation,
        validation.validatePathSecurity("foo/../../etc/passwd"),
    );
}

test "validatePathSecurity: absolute path rejected" {
    try testing.expectError(
        validation.GitValidationError.SecurityViolation,
        validation.validatePathSecurity("/etc/passwd"),
    );
}
