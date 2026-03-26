const std = @import("std");

/// Git-specific validation utilities and error handling
pub const GitValidationError = error{
    InvalidSHA1Hash,
    InvalidSHA1Length,
    InvalidGitDirectory,
    RepositoryNotFound,
    CorruptedRepository,
    UnsupportedGitFeature,
    InvalidObjectData,
    MalformedGitObject,
    CircularReference,
    DeepReference,
    InvalidConfiguration,
    SecurityViolation,
};

/// Validate a SHA-1 hash string
pub fn validateSHA1Hash(hash: []const u8) GitValidationError!void {
    if (hash.len != 40) {
        return GitValidationError.InvalidSHA1Length;
    }
    
    for (hash) |c| {
        if (!std.ascii.isHex(c)) {
            return GitValidationError.InvalidSHA1Hash;
        }
    }
}

/// Validate a SHA-1 hash is properly normalized (lowercase)
pub fn validateSHA1Normalized(hash: []const u8) GitValidationError!void {
    try validateSHA1Hash(hash);
    
    for (hash) |c| {
        if (std.ascii.isUpper(c)) {
            return GitValidationError.InvalidSHA1Hash;
        }
    }
}

/// Normalize a SHA-1 hash to lowercase
pub fn normalizeSHA1Hash(hash: []const u8, allocator: std.mem.Allocator) ![]u8 {
    try validateSHA1Hash(hash);
    
    var normalized = try allocator.alloc(u8, 40);
    for (hash, 0..) |c, i| {
        normalized[i] = std.ascii.toLower(c);
    }
    
    return normalized;
}

/// Validate git directory structure exists
pub fn validateGitDirectory(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) GitValidationError!void {
    _ = allocator; // May be used for future features
    
    // Check if HEAD exists
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    
    if (!platform_impl.fs.exists(head_path) catch false) {
        return GitValidationError.RepositoryNotFound;
    }
    
    // Check if objects directory exists
    const objects_path = try std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir});
    defer allocator.free(objects_path);
    
    if (!platform_impl.fs.exists(objects_path) catch false) {
        return GitValidationError.RepositoryNotFound;
    }
    
    // Check if refs directory exists
    const refs_path = try std.fmt.allocPrint(allocator, "{s}/refs", .{git_dir});
    defer allocator.free(refs_path);
    
    if (!platform_impl.fs.exists(refs_path) catch false) {
        return GitValidationError.RepositoryNotFound;
    }
}

/// Validate ref name according to git rules
pub fn validateRefName(ref_name: []const u8) GitValidationError!void {
    if (ref_name.len == 0) {
        return GitValidationError.InvalidConfiguration;
    }
    
    if (ref_name.len > 1024) { // Reasonable limit
        return GitValidationError.InvalidConfiguration;
    }
    
    // Basic validation - more comprehensive rules can be added
    if (std.mem.startsWith(u8, ref_name, ".") or std.mem.endsWith(u8, ref_name, ".")) {
        return GitValidationError.InvalidConfiguration;
    }
    
    if (std.mem.indexOf(u8, ref_name, "..") != null) {
        return GitValidationError.InvalidConfiguration;
    }
    
    // Check for invalid characters
    for (ref_name) |c| {
        if (c < 32 or c > 126 or c == ' ' or c == '~' or c == '^' or c == ':' or c == '?' or c == '*' or c == '[') {
            return GitValidationError.InvalidConfiguration;
        }
    }
}

/// Validate git object type and basic structure
pub fn validateGitObject(obj_type: []const u8, data: []const u8) GitValidationError!void {
    // Validate object type
    const valid_types = [_][]const u8{ "blob", "tree", "commit", "tag" };
    var type_valid = false;
    for (valid_types) |valid_type| {
        if (std.mem.eql(u8, obj_type, valid_type)) {
            type_valid = true;
            break;
        }
    }
    
    if (!type_valid) {
        return GitValidationError.InvalidObjectData;
    }
    
    // Basic size validation
    if (data.len > 1024 * 1024 * 1024) { // 1GB limit for single objects
        return GitValidationError.InvalidObjectData;
    }
    
    // Type-specific validation
    if (std.mem.eql(u8, obj_type, "commit")) {
        try validateCommitObject(data);
    } else if (std.mem.eql(u8, obj_type, "tree")) {
        try validateTreeObject(data);
    } else if (std.mem.eql(u8, obj_type, "tag")) {
        try validateTagObject(data);
    }
    // blob objects don't need structure validation
}

/// Validate commit object structure
fn validateCommitObject(data: []const u8) GitValidationError!void {
    var lines = std.mem.split(u8, data, "\n");
    var found_tree = false;
    var found_author = false;
    var found_committer = false;
    var found_blank_line = false;
    
    while (lines.next()) |line| {
        if (line.len == 0) {
            found_blank_line = true;
            break;
        }
        
        if (std.mem.startsWith(u8, line, "tree ")) {
            found_tree = true;
            const hash = line["tree ".len..];
            validateSHA1Hash(hash) catch return GitValidationError.MalformedGitObject;
        } else if (std.mem.startsWith(u8, line, "author ")) {
            found_author = true;
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            found_committer = true;
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            const hash = line["parent ".len..];
            validateSHA1Hash(hash) catch return GitValidationError.MalformedGitObject;
        }
    }
    
    if (!found_tree or !found_author or !found_committer or !found_blank_line) {
        return GitValidationError.MalformedGitObject;
    }
}

/// Validate tree object structure
fn validateTreeObject(data: []const u8) GitValidationError!void {
    var pos: usize = 0;
    
    while (pos < data.len) {
        // Find space (separates mode from name)
        const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse {
            return GitValidationError.MalformedGitObject;
        };
        
        const mode = data[pos..space_pos];
        pos = space_pos + 1;
        
        // Validate mode
        if (mode.len == 0 or mode.len > 6) {
            return GitValidationError.MalformedGitObject;
        }
        
        for (mode) |c| {
            if (!std.ascii.isDigit(c)) {
                return GitValidationError.MalformedGitObject;
            }
        }
        
        // Find null terminator (separates name from hash)
        const null_pos = std.mem.indexOfScalarPos(u8, data, pos, 0) orelse {
            return GitValidationError.MalformedGitObject;
        };
        
        const name = data[pos..null_pos];
        pos = null_pos + 1;
        
        // Validate name is not empty
        if (name.len == 0) {
            return GitValidationError.MalformedGitObject;
        }
        
        // Hash should be 20 bytes
        if (pos + 20 > data.len) {
            return GitValidationError.MalformedGitObject;
        }
        
        pos += 20;
    }
}

/// Validate tag object structure
fn validateTagObject(data: []const u8) GitValidationError!void {
    var lines = std.mem.split(u8, data, "\n");
    var found_object = false;
    var found_type = false;
    var found_tag = false;
    var found_tagger = false;
    
    while (lines.next()) |line| {
        if (line.len == 0) {
            break; // End of headers
        }
        
        if (std.mem.startsWith(u8, line, "object ")) {
            found_object = true;
            const hash = line["object ".len..];
            validateSHA1Hash(hash) catch return GitValidationError.MalformedGitObject;
        } else if (std.mem.startsWith(u8, line, "type ")) {
            found_type = true;
        } else if (std.mem.startsWith(u8, line, "tag ")) {
            found_tag = true;
        } else if (std.mem.startsWith(u8, line, "tagger ")) {
            found_tagger = true;
        }
    }
    
    if (!found_object or !found_type or !found_tag) {
        return GitValidationError.MalformedGitObject;
    }
    
    // tagger is optional for some tag objects
    _ = found_tagger;
}

/// Security check for path traversal attacks in git operations
pub fn validatePathSecurity(path: []const u8) GitValidationError!void {
    if (std.mem.indexOf(u8, path, "..") != null) {
        return GitValidationError.SecurityViolation;
    }
    
    if (std.mem.startsWith(u8, path, "/")) {
        return GitValidationError.SecurityViolation;
    }
    
    // Check for null bytes
    if (std.mem.indexOf(u8, path, "\x00") != null) {
        return GitValidationError.SecurityViolation;
    }
}

test "SHA-1 validation" {
    const testing = std.testing;
    
    // Valid hashes
    try validateSHA1Hash("abcdef1234567890abcdef1234567890abcdef12");
    try validateSHA1Hash("0123456789abcdef0123456789abcdef01234567");
    
    // Invalid hashes
    try testing.expectError(GitValidationError.InvalidSHA1Length, validateSHA1Hash("too_short"));
    try testing.expectError(GitValidationError.InvalidSHA1Length, validateSHA1Hash("way_too_long_to_be_a_valid_hash_string"));
    try testing.expectError(GitValidationError.InvalidSHA1Hash, validateSHA1Hash("xyz1234567890abcdef1234567890abcdef12345"));
}

test "ref name validation" {
    const testing = std.testing;
    
    // Valid ref names
    try validateRefName("refs/heads/master");
    try validateRefName("refs/tags/v1.0.0");
    try validateRefName("refs/remotes/origin/main");
    
    // Invalid ref names
    try testing.expectError(GitValidationError.InvalidConfiguration, validateRefName(""));
    try testing.expectError(GitValidationError.InvalidConfiguration, validateRefName(".hidden"));
    try testing.expectError(GitValidationError.InvalidConfiguration, validateRefName("bad..name"));
    try testing.expectError(GitValidationError.InvalidConfiguration, validateRefName("has space"));
}

test "security validation" {
    const testing = std.testing;
    
    // Safe paths
    try validatePathSecurity("file.txt");
    try validatePathSecurity("dir/file.txt");
    
    // Unsafe paths
    try testing.expectError(GitValidationError.SecurityViolation, validatePathSecurity("../etc/passwd"));
    try testing.expectError(GitValidationError.SecurityViolation, validatePathSecurity("/etc/passwd"));
    try testing.expectError(GitValidationError.SecurityViolation, validatePathSecurity("file\x00.txt"));
}