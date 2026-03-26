// test/validation_internal_test.zig - Tests for git validation functions
const std = @import("std");
const validation = @import("validation");
const testing = std.testing;

// ============================================================================
// SHA-1 hash validation
// ============================================================================

test "validateSHA1Hash: valid 40-char lowercase hex" {
    try validation.validateSHA1Hash("abcdef0123456789abcdef0123456789abcdef01");
}

test "validateSHA1Hash: valid all-zeros" {
    try validation.validateSHA1Hash("0000000000000000000000000000000000000000");
}

test "validateSHA1Hash: valid uppercase accepted by validateSHA1Hash" {
    try validation.validateSHA1Hash("ABCDEF0123456789ABCDEF0123456789ABCDEF01");
}

test "validateSHA1Normalized: uppercase rejected" {
    try testing.expectError(error.InvalidSHA1Hash, validation.validateSHA1Normalized("ABCDEF0123456789ABCDEF0123456789ABCDEF01"));
}

test "validateSHA1Hash: too short rejected" {
    try testing.expectError(error.InvalidSHA1Length, validation.validateSHA1Hash("abcdef"));
}

test "validateSHA1Hash: too long rejected" {
    try testing.expectError(error.InvalidSHA1Length, validation.validateSHA1Hash("abcdef0123456789abcdef0123456789abcdef0123"));
}

test "validateSHA1Hash: empty rejected" {
    try testing.expectError(error.InvalidSHA1Length, validation.validateSHA1Hash(""));
}

test "validateSHA1Hash: non-hex chars rejected" {
    try testing.expectError(error.InvalidSHA1Hash, validation.validateSHA1Hash("gggggggggggggggggggggggggggggggggggggggg"));
}

// ============================================================================
// normalizeSHA1Hash
// ============================================================================

test "normalizeSHA1Hash: lowercase passes through" {
    const result = try validation.normalizeSHA1Hash("abcdef0123456789abcdef0123456789abcdef01", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef01", result);
}

test "normalizeSHA1Hash: uppercase converted to lowercase" {
    const result = try validation.normalizeSHA1Hash("ABCDEF0123456789ABCDEF0123456789ABCDEF01", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef01", result);
}

test "normalizeSHA1Hash: mixed case normalized" {
    const result = try validation.normalizeSHA1Hash("AbCdEf0123456789aBcDeF0123456789AbCdEf01", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef01", result);
}

// ============================================================================
// Ref name validation
// ============================================================================

test "validateRefName: simple valid name" {
    try validation.validateRefName("main");
}

test "validateRefName: slashed valid name" {
    try validation.validateRefName("feature/my-branch");
}

test "validateRefName: empty rejected" {
    try testing.expectError(error.InvalidConfiguration, validation.validateRefName(""));
}

test "validateRefName: double dots rejected" {
    try testing.expectError(error.InvalidConfiguration, validation.validateRefName("a..b"));
}

test "validateRefName: space rejected" {
    try testing.expectError(error.InvalidConfiguration, validation.validateRefName("a b"));
}

test "validateRefName: tilde rejected" {
    try testing.expectError(error.InvalidConfiguration, validation.validateRefName("a~b"));
}

test "validateRefName: caret rejected" {
    try testing.expectError(error.InvalidConfiguration, validation.validateRefName("a^b"));
}

test "validateRefName: colon rejected" {
    try testing.expectError(error.InvalidConfiguration, validation.validateRefName("a:b"));
}

test "validateRefName: question mark rejected" {
    try testing.expectError(error.InvalidConfiguration, validation.validateRefName("a?b"));
}

test "validateRefName: asterisk rejected" {
    try testing.expectError(error.InvalidConfiguration, validation.validateRefName("a*b"));
}

test "validateRefName: bracket rejected" {
    try testing.expectError(error.InvalidConfiguration, validation.validateRefName("a[b"));
}

test "validateRefName: leading dot rejected" {
    try testing.expectError(error.InvalidConfiguration, validation.validateRefName(".hidden"));
}

test "validateRefName: trailing dot rejected" {
    try testing.expectError(error.InvalidConfiguration, validation.validateRefName("name."));
}

test "validateRefName: control char rejected" {
    try testing.expectError(error.InvalidConfiguration, validation.validateRefName("a\x01b"));
}

test "validateRefName: too long rejected" {
    const long_name = "a" ** 1025;
    try testing.expectError(error.InvalidConfiguration, validation.validateRefName(long_name));
}

test "validateRefName: max length accepted" {
    const max_name = "a" ** 1024;
    try validation.validateRefName(max_name);
}

// ============================================================================
// Git object validation
// ============================================================================

test "validateGitObject: valid blob" {
    try validation.validateGitObject("blob", "some content");
}

test "validateGitObject: valid commit with required fields" {
    const commit_data = "tree 0000000000000000000000000000000000000000\nauthor T <t@t> 1234567890 +0000\ncommitter T <t@t> 1234567890 +0000\n\nmessage\n";
    try validation.validateGitObject("commit", commit_data);
}

test "validateGitObject: invalid type rejected" {
    try testing.expectError(error.InvalidObjectData, validation.validateGitObject("invalid", "data"));
}

test "validateGitObject: empty type rejected" {
    try testing.expectError(error.InvalidObjectData, validation.validateGitObject("", "data"));
}

// ============================================================================
// Path security validation
// ============================================================================

test "validatePathSecurity: normal path OK" {
    try validation.validatePathSecurity("src/main.zig");
}

test "validatePathSecurity: simple filename OK" {
    try validation.validatePathSecurity("file.txt");
}

test "validatePathSecurity: dotdot rejected" {
    try testing.expectError(error.SecurityViolation, validation.validatePathSecurity("../etc/passwd"));
}

test "validatePathSecurity: absolute path rejected" {
    try testing.expectError(error.SecurityViolation, validation.validatePathSecurity("/etc/passwd"));
}

test "validatePathSecurity: null byte rejected" {
    try testing.expectError(error.SecurityViolation, validation.validatePathSecurity("file\x00.txt"));
}

test "validatePathSecurity: embedded dotdot rejected" {
    try testing.expectError(error.SecurityViolation, validation.validatePathSecurity("foo/../bar"));
}
