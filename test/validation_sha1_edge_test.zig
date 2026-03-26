// test/validation_sha1_edge_test.zig
// Exhaustive tests for SHA-1 validation and normalization edge cases.

const std = @import("std");
const validation = @import("validation");
const testing = std.testing;

// ============================================================================
// validateSHA1Hash
// ============================================================================

test "valid lowercase SHA-1 passes" {
    try validation.validateSHA1Hash("da39a3ee5e6b4b0d3255bfef95601890afd80709");
}

test "valid uppercase SHA-1 passes" {
    try validation.validateSHA1Hash("DA39A3EE5E6B4B0D3255BFEF95601890AFD80709");
}

test "valid mixed-case SHA-1 passes" {
    try validation.validateSHA1Hash("Da39a3Ee5e6b4b0D3255bfEF95601890afd80709");
}

test "all zeros SHA-1 passes" {
    try validation.validateSHA1Hash("0000000000000000000000000000000000000000");
}

test "all f's SHA-1 passes" {
    try validation.validateSHA1Hash("ffffffffffffffffffffffffffffffffffffffff");
}

test "too short hash fails" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Length,
        validation.validateSHA1Hash("da39a3ee5e6b4b0d"),
    );
}

test "too long hash fails" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Length,
        validation.validateSHA1Hash("da39a3ee5e6b4b0d3255bfef95601890afd807090"),
    );
}

test "empty string fails" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Length,
        validation.validateSHA1Hash(""),
    );
}

test "39 chars fails" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Length,
        validation.validateSHA1Hash("da39a3ee5e6b4b0d3255bfef95601890afd8070"),
    );
}

test "non-hex char g fails" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Hash,
        validation.validateSHA1Hash("ga39a3ee5e6b4b0d3255bfef95601890afd80709"),
    );
}

test "non-hex char space fails" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Hash,
        validation.validateSHA1Hash("da39a3ee5e6b4b0d3255bfef9560189 afd80709"),
    );
}

test "non-hex char z in middle fails" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Hash,
        validation.validateSHA1Hash("da39a3ee5e6b4b0d3255bfef95z01890afd80709"),
    );
}

// ============================================================================
// validateSHA1Normalized
// ============================================================================

test "normalized lowercase SHA-1 passes" {
    try validation.validateSHA1Normalized("da39a3ee5e6b4b0d3255bfef95601890afd80709");
}

test "normalized all zeros passes" {
    try validation.validateSHA1Normalized("0000000000000000000000000000000000000000");
}

test "normalized rejects uppercase" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Hash,
        validation.validateSHA1Normalized("DA39A3EE5E6B4B0D3255BFEF95601890AFD80709"),
    );
}

test "normalized rejects mixed case" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Hash,
        validation.validateSHA1Normalized("Da39a3ee5e6b4b0d3255bfef95601890afd80709"),
    );
}

test "normalized rejects wrong length" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Length,
        validation.validateSHA1Normalized("abc"),
    );
}

// ============================================================================
// normalizeSHA1Hash
// ============================================================================

test "normalize lowercase is identity" {
    const result = try validation.normalizeSHA1Hash("da39a3ee5e6b4b0d3255bfef95601890afd80709", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("da39a3ee5e6b4b0d3255bfef95601890afd80709", result);
}

test "normalize uppercase to lowercase" {
    const result = try validation.normalizeSHA1Hash("DA39A3EE5E6B4B0D3255BFEF95601890AFD80709", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("da39a3ee5e6b4b0d3255bfef95601890afd80709", result);
}

test "normalize mixed case to lowercase" {
    const result = try validation.normalizeSHA1Hash("Da39A3eE5E6b4B0D3255BfEf95601890AfD80709", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("da39a3ee5e6b4b0d3255bfef95601890afd80709", result);
}

test "normalize rejects invalid input" {
    try testing.expectError(
        validation.GitValidationError.InvalidSHA1Length,
        validation.normalizeSHA1Hash("not-a-hash", testing.allocator),
    );
}
