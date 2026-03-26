const std = @import("std");

/// Validate a git ref name according to git ref naming rules
fn isValidRefName(name: []const u8) bool {
    // Basic validation - reject empty names, names starting with dot, etc.
    if (name.len == 0) return false;
    if (name[0] == '.') return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOf(u8, name, " ") != null) return false;
    if (std.mem.indexOf(u8, name, "~") != null) return false;
    if (std.mem.indexOf(u8, name, "^") != null) return false;
    if (std.mem.indexOf(u8, name, ":") != null) return false;
    if (std.mem.indexOf(u8, name, "?") != null) return false;
    if (std.mem.indexOf(u8, name, "*") != null) return false;
    if (std.mem.indexOf(u8, name, "[") != null) return false;
    if (std.mem.indexOf(u8, name, "\\") != null) return false;
    if (std.mem.endsWith(u8, name, "/")) return false;
    if (std.mem.endsWith(u8, name, ".lock")) return false;
    return true;
}

pub const Ref = struct {
    name: []const u8,
    hash: []const u8,

    pub fn init(name: []const u8, hash: []const u8) Ref {
        return Ref{
            .name = name,
            .hash = hash,
        };
    }

    pub fn deinit(self: Ref, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.hash);
    }
};

pub fn getCurrentBranch(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) ![]u8 {
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);

    const content = try platform_impl.fs.readFile(allocator, head_path);
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    
    if (std.mem.startsWith(u8, trimmed, "ref: refs/heads/")) {
        return try allocator.dupe(u8, trimmed["ref: refs/heads/".len..]);
    } else if (trimmed.len == 40 and isValidHash(trimmed)) {
        // Detached HEAD
        return try allocator.dupe(u8, "HEAD");
    } else {
        return error.InvalidHEAD;
    }
}

pub fn getCurrentCommit(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !?[]u8 {
    return resolveRef(git_dir, "HEAD", platform_impl, allocator);
}

/// Resolve a reference with support for nested symbolic refs and annotated tags
pub fn resolveRef(git_dir: []const u8, ref_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !?[]u8 {
    // Validate input
    if (ref_name.len == 0) return error.EmptyRefName;
    if (ref_name.len > 1024) return error.RefNameTooLong; // Reasonable limit
    
    // Check for invalid characters in ref name (git ref naming rules)
    for (ref_name) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x7F) {
            return error.InvalidRefNameChar;
        }
        // Control characters and some special chars are not allowed
        if (c < 0x20 or c == '~' or c == '^' or c == ':' or c == '?' or c == '*' or c == '[') {
            return error.InvalidRefNameChar;
        }
    }
    
    var current_ref = try allocator.dupe(u8, ref_name);
    defer allocator.free(current_ref);
    
    var depth: u32 = 0;
    const max_depth = 20; // Increased from 10 to handle complex setups
    var seen_refs = std.ArrayList([]const u8).init(allocator);
    defer {
        for (seen_refs.items) |seen_ref| {
            allocator.free(seen_ref);
        }
        seen_refs.deinit();
    }
    
    while (depth < max_depth) {
        defer depth += 1;
        
        // Check for circular references
        for (seen_refs.items) |seen_ref| {
            if (std.mem.eql(u8, seen_ref, current_ref)) {
                return error.CircularRef;
            }
        }
        
        // Track this ref to detect cycles
        try seen_refs.append(try allocator.dupe(u8, current_ref));
        
        const resolved = resolveRefOnce(git_dir, current_ref, platform_impl, allocator) catch |err| {
            // Enhanced fallback logic for different ref name formats
            if (std.mem.eql(u8, current_ref, "HEAD")) {
                return err; // HEAD should always exist in a valid repo
            }
            
            // Try different ref namespace patterns
            if (!std.mem.startsWith(u8, current_ref, "refs/")) {
                // Try refs/heads/ first (most common)
                const head_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{current_ref});
                defer allocator.free(head_ref);
                if (resolveRefOnce(git_dir, head_ref, platform_impl, allocator)) |head_resolved| {
                    if (head_resolved.is_symbolic) {
                        allocator.free(current_ref);
                        current_ref = try allocator.dupe(u8, head_resolved.target);
                        allocator.free(head_resolved.target);
                        continue; // Continue the loop with the symbolic target
                    } else {
                        defer allocator.free(head_resolved.target);
                        return try resolveAnnotatedTag(git_dir, head_resolved.target, platform_impl, allocator);
                    }
                } else |_| {}
                
                // Try refs/tags/ 
                const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{current_ref});
                defer allocator.free(tag_ref);
                if (resolveRefOnce(git_dir, tag_ref, platform_impl, allocator)) |tag_resolved| {
                    if (tag_resolved.is_symbolic) {
                        allocator.free(current_ref);
                        current_ref = try allocator.dupe(u8, tag_resolved.target);
                        allocator.free(tag_resolved.target);
                        continue;
                    } else {
                        defer allocator.free(tag_resolved.target);
                        return try resolveAnnotatedTag(git_dir, tag_resolved.target, platform_impl, allocator);
                    }
                } else |_| {}
                
                // Try refs/remotes/ (for remote tracking branches)
                const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}", .{current_ref});
                defer allocator.free(remote_ref);
                if (resolveRefOnce(git_dir, remote_ref, platform_impl, allocator)) |remote_resolved| {
                    if (remote_resolved.is_symbolic) {
                        allocator.free(current_ref);
                        current_ref = try allocator.dupe(u8, remote_resolved.target);
                        allocator.free(remote_resolved.target);
                        continue;
                    } else {
                        defer allocator.free(remote_resolved.target);
                        return try resolveAnnotatedTag(git_dir, remote_resolved.target, platform_impl, allocator);
                    }
                } else |_| {}
            }
            
            return err; // All fallback attempts failed
        };
        
        if (resolved.is_symbolic) {
            // Update current_ref for next iteration
            allocator.free(current_ref);
            current_ref = try allocator.dupe(u8, resolved.target);
            allocator.free(resolved.target);
        } else {
            // Found final hash, check if it's an annotated tag
            const final_hash = try resolveAnnotatedTag(git_dir, resolved.target, platform_impl, allocator);
            allocator.free(resolved.target);
            return final_hash;
        }
    }
    
    return error.TooManySymbolicRefs;
}

/// Result of a single ref resolution step
const RefResolution = struct {
    target: []u8,
    is_symbolic: bool,
};

/// Resolve a reference one level (without following symbolic refs)
fn resolveRefOnce(git_dir: []const u8, ref_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !RefResolution {
    // Try to read as file first
    const ref_path = if (std.mem.eql(u8, ref_name, "HEAD"))
        try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir})
    else if (std.mem.startsWith(u8, ref_name, "refs/"))
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name })
    else
        // Try common locations for short ref names
        try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_dir, ref_name });
    defer allocator.free(ref_path);
    
    const content = platform_impl.fs.readFile(allocator, ref_path) catch |err| switch (err) {
        error.FileNotFound => {
            // Try packed-refs
            const full_ref_name = if (std.mem.startsWith(u8, ref_name, "refs/"))
                ref_name
            else if (std.mem.eql(u8, ref_name, "HEAD"))
                "HEAD"
            else
                // Try multiple locations
                ref_name; // This will be handled in packed-refs search
            
            if (readFromPackedRefs(git_dir, full_ref_name, platform_impl, allocator)) |hash| {
                return RefResolution{
                    .target = hash,
                    .is_symbolic = false,
                };
            } else |packed_err| switch (packed_err) {
                error.RefNotFound => {
                    // Try alternative locations for short names
                    if (!std.mem.startsWith(u8, ref_name, "refs/") and !std.mem.eql(u8, ref_name, "HEAD")) {
                        // Try refs/tags/
                        const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{ref_name});
                        defer allocator.free(tag_ref);
                        
                        if (readFromPackedRefs(git_dir, tag_ref, platform_impl, allocator)) |hash| {
                            return RefResolution{
                                .target = hash,
                                .is_symbolic = false,
                            };
                        } else |_| {}
                        
                        // Try refs/remotes/
                        const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}", .{ref_name});
                        defer allocator.free(remote_ref);
                        
                        if (readFromPackedRefs(git_dir, remote_ref, platform_impl, allocator)) |hash| {
                            return RefResolution{
                                .target = hash,
                                .is_symbolic = false,
                            };
                        } else |_| {}
                    }
                    return error.RefNotFound;
                },
                else => return packed_err,
            }
        },
        else => return err,
    };
    defer allocator.free(content);
    
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    
    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        // Symbolic reference
        const target_ref = trimmed["ref: ".len..];
        return RefResolution{
            .target = try allocator.dupe(u8, target_ref),
            .is_symbolic = true,
        };
    } else if (isValidHash(trimmed)) {
        // Direct hash reference
        return RefResolution{
            .target = try allocator.dupe(u8, trimmed),
            .is_symbolic = false,
        };
    } else {
        return error.InvalidRef;
    }
}

/// Get the hash for any ref (including remote tracking refs)
pub fn getRef(git_dir: []const u8, ref_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) ![]u8 {
    const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name });
    defer allocator.free(ref_path);

    const content = platform_impl.fs.readFile(allocator, ref_path) catch |err| switch (err) {
        error.FileNotFound => {
            // Try to find it in packed-refs
            return readFromPackedRefs(git_dir, ref_name, platform_impl, allocator);
        },
        else => return err,
    };
    defer allocator.free(content);

    const hash = std.mem.trim(u8, content, " \t\n\r");
    if (hash.len == 40 and isValidHash(hash)) {
        return try allocator.dupe(u8, hash);
    } else {
        return error.InvalidHash;
    }
}

pub fn updateRef(git_dir: []const u8, ref_name: []const u8, hash: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !void {
    const ref_path = if (std.mem.startsWith(u8, ref_name, "refs/"))
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name })
    else
        try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_dir, ref_name });
    defer allocator.free(ref_path);

    // Create parent directory if it doesn't exist
    const parent_dir = std.fs.path.dirname(ref_path).?;
    platform_impl.fs.makeDir(parent_dir) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };

    const content = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
    defer allocator.free(content);
    try platform_impl.fs.writeFile(ref_path, content);
}

pub fn updateHEAD(git_dir: []const u8, branch_or_hash: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !void {
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);

    const content = if (branch_or_hash.len == 40 and isValidHash(branch_or_hash)) 
        try std.fmt.allocPrint(allocator, "{s}\n", .{branch_or_hash})
    else
        try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{branch_or_hash});
    defer allocator.free(content);

    try platform_impl.fs.writeFile(head_path, content);
}

pub fn listBranches(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !std.ArrayList([]u8) {
    var branches = std.ArrayList([]u8).init(allocator);
    
    const refs_heads_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{git_dir});
    defer allocator.free(refs_heads_path);
    
    // Try to read the directory directly
    const entries = platform_impl.fs.readDir(allocator, refs_heads_path) catch |err| switch (err) {
        error.FileNotFound => {
            // Directory doesn't exist, no branches yet
            return branches;
        },
        error.NotSupported => {
            // Platform doesn't support readDir, fall back to common names
            const common_branches = [_][]const u8{ "master", "main", "develop", "dev", "feature1" };
            
            for (common_branches) |branch_name| {
                const branch_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_dir, branch_name });
                defer allocator.free(branch_path);
                
                if (platform_impl.fs.exists(branch_path) catch false) {
                    try branches.append(try allocator.dupe(u8, branch_name));
                }
            }
            return branches;
        },
        else => return err,
    };
    defer {
        for (entries) |entry| {
            allocator.free(entry);
        }
        allocator.free(entries);
    }
    
    // Add all branch files found
    for (entries) |entry| {
        try branches.append(try allocator.dupe(u8, entry));
    }
    
    // If no branches found, check if master exists via HEAD as fallback
    if (branches.items.len == 0) {
        const current_branch = getCurrentBranch(git_dir, platform_impl, allocator) catch "master";
        defer allocator.free(current_branch);
        
        if (!std.mem.eql(u8, current_branch, "HEAD")) {
            try branches.append(try allocator.dupe(u8, current_branch));
        } else {
            try branches.append(try allocator.dupe(u8, "master"));
        }
    }
    
    return branches;
}

pub fn branchExists(git_dir: []const u8, branch_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !bool {
    const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_dir, branch_name });
    defer allocator.free(ref_path);

    if (platform_impl.fs.exists(ref_path) catch false) {
        return true;
    }
    
    // Check packed-refs
    const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name});
    defer allocator.free(ref_name);
    
    if (readFromPackedRefs(git_dir, ref_name, platform_impl, allocator)) |hash| {
        allocator.free(hash);
        return true;
    } else |err| switch (err) {
        error.RefNotFound => return false,
        else => return false,
    }
}

pub fn createBranch(git_dir: []const u8, branch_name: []const u8, start_point: ?[]const u8, platform_impl: anytype, allocator: std.mem.Allocator) !void {
    const hash = if (start_point) |sp|
        if (sp.len == 40 and isValidHash(sp))
            try allocator.dupe(u8, sp)
        else blk: {
            // Resolve branch name to hash
            const commit_hash = try getBranchCommit(git_dir, sp, platform_impl, allocator);
            if (commit_hash) |h| {
                break :blk h;
            } else {
                return error.InvalidStartPoint;
            }
        }
    else blk: {
        // Use current HEAD
        const current_commit = try getCurrentCommit(git_dir, platform_impl, allocator);
        if (current_commit) |h| {
            break :blk h;
        } else {
            return error.NoCommitsYet;
        }
    };
    defer allocator.free(hash);

    try updateRef(git_dir, branch_name, hash, platform_impl, allocator);
}

pub fn deleteBranch(git_dir: []const u8, branch_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !void {
    const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_dir, branch_name });
    defer allocator.free(ref_path);

    try platform_impl.fs.deleteFile(ref_path);
}

pub fn getBranchCommit(git_dir: []const u8, branch_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !?[]u8 {
    const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_dir, branch_name });
    defer allocator.free(ref_path);

    const content = platform_impl.fs.readFile(allocator, ref_path) catch |err| switch (err) {
        error.FileNotFound => {
            // Try to find it in packed-refs
            const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name});
            defer allocator.free(ref_name);
            return readFromPackedRefs(git_dir, ref_name, platform_impl, allocator) catch null;
        },
        else => return err,
    };
    defer allocator.free(content);

    const hash = std.mem.trim(u8, content, " \t\n\r");
    if (hash.len == 40 and isValidHash(hash)) {
        return try allocator.dupe(u8, hash);
    } else {
        return error.InvalidHash;
    }
}

fn isValidHash(hash: []const u8) bool {
    if (hash.len != 40) return false;
    for (hash) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn isValidRefName(ref_name: []const u8) bool {
    if (ref_name.len == 0) return false;
    if (ref_name.len > 1024) return false; // Reasonable limit
    
    // Check for invalid characters and patterns
    for (ref_name, 0..) |c, i| {
        switch (c) {
            ' ', '\t', '\n', '\r', '~', '^', ':', '?', '*', '[', '\\', 0x7F => return false,
            '.' => {
                // Cannot start with a dot or have consecutive dots
                if (i == 0) return false;
                if (i > 0 and ref_name[i-1] == '.') return false;
            },
            '/' => {
                // Cannot start or end with slash, or have consecutive slashes
                if (i == 0 or i == ref_name.len - 1) return false;
                if (i > 0 and ref_name[i-1] == '/') return false;
            },
            else => {
                // Control characters are not allowed
                if (c < 0x20 or c > 0x7E) return false;
            },
        }
    }
    
    // Cannot end with .lock
    if (std.mem.endsWith(u8, ref_name, ".lock")) return false;
    
    return true;
}

/// Resolve annotated tag to commit (if the hash points to a tag object)
fn resolveAnnotatedTag(git_dir: []const u8, hash: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) ![]u8 {
    const objects = @import("objects.zig");
    
    // Try to load the object to see if it's a tag
    const obj = objects.GitObject.load(hash, git_dir, platform_impl, allocator) catch {
        // If we can't load the object, just return the hash as-is
        return try allocator.dupe(u8, hash);
    };
    defer obj.deinit(allocator);
    
    if (obj.type == .tag) {
        // Parse tag object to find the commit it points to
        if (parseTagObject(obj.data)) |target_hash| {
            // Recursively resolve in case the tag points to another tag
            return resolveAnnotatedTag(git_dir, target_hash, platform_impl, allocator);
        } else {
            // Malformed tag object, return original hash
            return try allocator.dupe(u8, hash);
        }
    } else {
        // Not a tag object, return the hash as-is
        return try allocator.dupe(u8, hash);
    }
}

/// Parse a tag object to extract the target hash
fn parseTagObject(tag_content: []const u8) ?[]const u8 {
    // Tag object format:
    // object <sha1>
    // type <object_type>
    // tag <tag_name>
    // tagger <author_info>
    // <blank_line>
    // <tag_message>
    
    var lines = std.mem.split(u8, tag_content, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "object ")) {
            const target_hash = line["object ".len..];
            // Verify it's a valid 40-character hex hash
            if (target_hash.len == 40 and isValidHash(target_hash)) {
                return target_hash;
            }
        }
    }
    return null;
}

/// List all remote references
pub fn listRemotes(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !std.ArrayList([]u8) {
    var remotes = std.ArrayList([]u8).init(allocator);
    
    const refs_remotes_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes", .{git_dir});
    defer allocator.free(refs_remotes_path);
    
    const entries = platform_impl.fs.readDir(allocator, refs_remotes_path) catch |err| switch (err) {
        error.FileNotFound, error.NotSupported => return remotes,
        else => return err,
    };
    defer {
        for (entries) |entry| {
            allocator.free(entry);
        }
        allocator.free(entries);
    }
    
    for (entries) |entry| {
        try remotes.append(try allocator.dupe(u8, entry));
    }
    
    return remotes;
}

/// List branches for a specific remote
pub fn listRemoteBranches(git_dir: []const u8, remote_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !std.ArrayList([]u8) {
    var branches = std.ArrayList([]u8).init(allocator);
    
    const remote_refs_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}", .{ git_dir, remote_name });
    defer allocator.free(remote_refs_path);
    
    const entries = platform_impl.fs.readDir(allocator, remote_refs_path) catch |err| switch (err) {
        error.FileNotFound, error.NotSupported => return branches,
        else => return err,
    };
    defer {
        for (entries) |entry| {
            allocator.free(entry);
        }
        allocator.free(entries);
    }
    
    for (entries) |entry| {
        try branches.append(try allocator.dupe(u8, entry));
    }
    
    return branches;
}

/// Get the commit hash for a remote branch
pub fn getRemoteBranchCommit(git_dir: []const u8, remote_name: []const u8, branch_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !?[]u8 {
    const ref_name = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ remote_name, branch_name });
    defer allocator.free(ref_name);
    
    return resolveRef(git_dir, ref_name, platform_impl, allocator);
}

/// List all tags
pub fn listTags(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !std.ArrayList([]u8) {
    var tags = std.ArrayList([]u8).init(allocator);
    
    const refs_tags_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_dir});
    defer allocator.free(refs_tags_path);
    
    const entries = platform_impl.fs.readDir(allocator, refs_tags_path) catch |err| switch (err) {
        error.FileNotFound, error.NotSupported => {
            // Try to find tags in packed-refs
            return findTagsInPackedRefs(git_dir, platform_impl, allocator) catch tags;
        },
        else => return err,
    };
    defer {
        for (entries) |entry| {
            allocator.free(entry);
        }
        allocator.free(entries);
    }
    
    for (entries) |entry| {
        try tags.append(try allocator.dupe(u8, entry));
    }
    
    // Also check packed-refs for additional tags
    const packed_tags = findTagsInPackedRefs(git_dir, platform_impl, allocator) catch std.ArrayList([]u8).init(allocator);
    defer {
        for (packed_tags.items) |tag| {
            allocator.free(tag);
        }
        packed_tags.deinit();
    }
    
    // Add packed tags that aren't already in the list
    for (packed_tags.items) |packed_tag| {
        var found = false;
        for (tags.items) |existing_tag| {
            if (std.mem.eql(u8, existing_tag, packed_tag)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try tags.append(try allocator.dupe(u8, packed_tag));
        }
    }
    
    return tags;
}

/// Find tags in packed-refs file
fn findTagsInPackedRefs(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !std.ArrayList([]u8) {
    var tags = std.ArrayList([]u8).init(allocator);
    
    const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_refs_path);

    const content = platform_impl.fs.readFile(allocator, packed_refs_path) catch |err| switch (err) {
        error.FileNotFound => return tags,
        else => return err,
    };
    defer allocator.free(content);

    var lines = std.mem.split(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        
        // Skip comments and empty lines
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        
        // Format: "<hash> <ref_name>"
        if (std.mem.indexOf(u8, trimmed, " ")) |space_pos| {
            const ref_path = trimmed[space_pos + 1..];
            
            if (std.mem.startsWith(u8, ref_path, "refs/tags/")) {
                const tag_name = ref_path["refs/tags/".len..];
                try tags.append(try allocator.dupe(u8, tag_name));
            }
        }
    }
    
    return tags;
}

/// Cache for packed-refs to avoid re-reading the file multiple times
var packed_refs_cache: ?struct {
    git_dir: []const u8,
    content: []const u8,
    last_modified: i64,
} = null;
var cache_allocator: ?std.mem.Allocator = null;

/// Read ref hash from packed-refs file with enhanced performance and validation
fn readFromPackedRefs(git_dir: []const u8, ref_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) ![]u8 {
    // Input validation
    if (ref_name.len == 0) return error.EmptyRefName;
    if (ref_name.len > 1024) return error.RefNameTooLong;
    
    const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_refs_path);

    // Try to use cached content if available and fresh
    var content: []const u8 = undefined;
    var should_free_content = true;
    
    if (packed_refs_cache) |cache| {
        if (std.mem.eql(u8, cache.git_dir, git_dir)) {
            // Check if file has been modified since cache
            if (std.fs.cwd().statFile(packed_refs_path)) |file_stat| {
                const file_mtime = @divTrunc(file_stat.mtime, std.time.ns_per_s);
                if (file_mtime <= cache.last_modified) {
                    content = cache.content;
                    should_free_content = false;
                }
            } else |_| {
                // If we can't stat the file but have cache, use cache
                content = cache.content;
                should_free_content = false;
            }
        }
    }
    
    if (should_free_content) {
        content = platform_impl.fs.readFile(allocator, packed_refs_path) catch |err| switch (err) {
            error.FileNotFound => return error.RefNotFound,
            error.AccessDenied => return error.PackedRefsAccessDenied,
            else => return err,
        };
        
        // Update cache
        if (packed_refs_cache) |old_cache| {
            if (cache_allocator) |ca| {
                ca.free(old_cache.git_dir);
                ca.free(old_cache.content);
            }
        }
        
        packed_refs_cache = .{
            .git_dir = try allocator.dupe(u8, git_dir),
            .content = try allocator.dupe(u8, content),
            .last_modified = std.time.timestamp(),
        };
        cache_allocator = allocator;
    }
    
    defer if (should_free_content) allocator.free(content);

    // Validate packed-refs file size (reasonable limit: 10MB)
    if (content.len > 10 * 1024 * 1024) {
        std.debug.print("Warning: packed-refs file is very large ({} bytes)\n", .{content.len});
    }

    // Check if the file is sorted (git pack-refs --all usually sorts)
    var is_sorted = false;
    var lines_iter = std.mem.split(u8, content, "\n");
    
    // Parse the header to check for capabilities
    while (lines_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        
        if (std.mem.startsWith(u8, trimmed, "#")) {
            // Check for sorted capability
            if (std.mem.indexOf(u8, trimmed, "sorted") != null) {
                is_sorted = true;
            }
            continue;
        }
        
        // First non-comment line, we can start searching
        break;
    }
    
    // Reset iterator for full search
    lines_iter = std.mem.split(u8, content, "\n");
    
    // Parse packed-refs file
    var prev_ref: ?[]const u8 = null;
    while (lines_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        
        // Skip comments and empty lines
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        
        // Handle peeled refs (start with ^)
        if (trimmed[0] == '^') {
            // Peeled ref for previous ref - handle annotated tags
            if (prev_ref != null and std.mem.eql(u8, prev_ref.?, ref_name) and trimmed.len >= 41) {
                const peeled_hash = trimmed[1..41];
                if (isValidHash(peeled_hash)) {
                    return try allocator.dupe(u8, peeled_hash);
                }
            }
            continue;
        }
        
        // Format: "<hash> <ref_name>"
        if (std.mem.indexOf(u8, trimmed, " ")) |space_pos| {
            const hash = trimmed[0..space_pos];
            const ref_path = trimmed[space_pos + 1..];
            
            // Store current ref for peeled ref handling
            prev_ref = ref_path;
            
            if (std.mem.eql(u8, ref_path, ref_name) and isValidHash(hash)) {
                return try allocator.dupe(u8, hash);
            }
            
            // If sorted and we've passed our target, we can stop searching
            if (is_sorted and std.mem.lessThan(u8, ref_name, ref_path)) {
                break;
            }
        }
    }
    
    return error.RefNotFound;
}

/// Clear the packed-refs cache (useful for testing or after repo changes)
pub fn clearPackedRefsCache() void {
    if (packed_refs_cache) |cache| {
        if (cache_allocator) |allocator| {
            allocator.free(cache.git_dir);
            allocator.free(cache.content);
        }
        packed_refs_cache = null;
        cache_allocator = null;
    }
}

/// Optimized ref resolution with caching and batch operations
pub const RefResolver = struct {
    git_dir: []const u8,
    allocator: std.mem.Allocator,
    ref_cache: std.HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    cache_valid_until: i64,
    cache_duration: i64, // Cache validity duration in seconds
    
    const Self = @This();
    
    pub fn init(git_dir: []const u8, allocator: std.mem.Allocator) Self {
        return Self{
            .git_dir = git_dir,
            .allocator = allocator,
            .ref_cache = std.HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .cache_valid_until = 0,
            .cache_duration = 30, // 30 seconds cache
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.clearCache();
        self.ref_cache.deinit();
    }
    
    /// Clear the internal ref cache
    pub fn clearCache(self: *Self) void {
        var iter = self.ref_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.ref_cache.clearRetainingCapacity();
        self.cache_valid_until = 0;
    }
    
    /// Check if cache is still valid
    fn isCacheValid(self: Self) bool {
        return std.time.timestamp() < self.cache_valid_until;
    }
    
    /// Resolve a ref with caching
    pub fn resolve(self: *Self, ref_name: []const u8, platform_impl: anytype) !?[]u8 {
        // Check cache first
        if (self.isCacheValid()) {
            if (self.ref_cache.get(ref_name)) |cached_value| {
                return try self.allocator.dupe(u8, cached_value);
            }
        } else {
            // Cache expired, clear it
            self.clearCache();
        }
        
        // Resolve using standard method
        const result = resolveRef(self.git_dir, ref_name, platform_impl, self.allocator) catch |err| switch (err) {
            error.RefNotFound => return null,
            else => return err,
        };
        
        if (result) |hash| {
            // Cache the result
            self.ref_cache.put(
                try self.allocator.dupe(u8, ref_name),
                try self.allocator.dupe(u8, hash)
            ) catch {}; // Ignore cache errors
            
            // Update cache validity
            self.cache_valid_until = std.time.timestamp() + self.cache_duration;
            
            return hash;
        }
        
        return null;
    }
    
    /// Batch resolve multiple refs efficiently
    pub fn resolveBatch(self: *Self, ref_names: []const []const u8, platform_impl: anytype) ![]?[]u8 {
        var results = try self.allocator.alloc(?[]u8, ref_names.len);
        
        // Refresh cache if needed by pre-loading refs
        if (!self.isCacheValid()) {
            try self.preloadRefs(platform_impl);
        }
        
        for (ref_names, 0..) |ref_name, i| {
            results[i] = try self.resolve(ref_name, platform_impl);
        }
        
        return results;
    }
    
    /// Pre-load common refs into cache for better performance
    fn preloadRefs(self: *Self, platform_impl: anytype) !void {
        self.clearCache();
        
        // Load packed-refs if available
        const packed_refs_path = try std.fmt.allocPrint(self.allocator, "{s}/packed-refs", .{self.git_dir});
        defer self.allocator.free(packed_refs_path);
        
        const content = platform_impl.fs.readFile(self.allocator, packed_refs_path) catch return;
        defer self.allocator.free(content);
        
        var lines = std.mem.split(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            
            // Skip comments and empty lines
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '^') continue;
            
            if (std.mem.indexOf(u8, trimmed, " ")) |space_pos| {
                const hash = trimmed[0..space_pos];
                const ref_path = trimmed[space_pos + 1..];
                
                if (isValidHash(hash)) {
                    self.ref_cache.put(
                        try self.allocator.dupe(u8, ref_path),
                        try self.allocator.dupe(u8, hash)
                    ) catch continue;
                }
            }
        }
        
        // Load common loose refs
        const common_refs = [_][]const u8{ "HEAD", "refs/heads/master", "refs/heads/main" };
        for (common_refs) |ref_name| {
            const ref_path = if (std.mem.eql(u8, ref_name, "HEAD"))
                try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{self.git_dir})
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, ref_name });
            defer self.allocator.free(ref_path);
            
            const ref_content = platform_impl.fs.readFile(self.allocator, ref_path) catch continue;
            defer self.allocator.free(ref_content);
            
            const trimmed = std.mem.trim(u8, ref_content, " \t\n\r");
            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                // Symbolic ref - don't cache directly, let normal resolution handle it
                continue;
            } else if (isValidHash(trimmed)) {
                self.ref_cache.put(
                    try self.allocator.dupe(u8, ref_name),
                    try self.allocator.dupe(u8, trimmed)
                ) catch continue;
            }
        }
        
        self.cache_valid_until = std.time.timestamp() + self.cache_duration;
    }
    
    /// Set cache duration (in seconds)
    pub fn setCacheDuration(self: *Self, duration: i64) void {
        self.cache_duration = duration;
    }
    
    /// Get cache statistics
    pub fn getCacheStats(self: Self) struct {
        entries: usize,
        is_valid: bool,
        expires_in: i64,
        
        pub fn print(stats: @This()) void {
            std.debug.print("RefResolver Cache Statistics:\n");
            std.debug.print("  Cached entries: {}\n", .{stats.entries});
            std.debug.print("  Cache valid: {}\n", .{stats.is_valid});
            std.debug.print("  Expires in: {}s\n", .{stats.expires_in});
        }
    } {
        const now = std.time.timestamp();
        return .{
            .entries = self.ref_cache.count(),
            .is_valid = self.isCacheValid(),
            .expires_in = if (self.cache_valid_until > now) self.cache_valid_until - now else 0,
        };
    }
};

/// Smart ref name expansion - tries to find the best match for partial ref names
pub fn expandRefName(git_dir: []const u8, partial_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !?[]u8 {
    // If it's already a full ref, check if it exists
    if (std.mem.startsWith(u8, partial_name, "refs/")) {
        if (resolveRef(git_dir, partial_name, platform_impl, allocator)) |hash| {
            defer allocator.free(hash);
            return try allocator.dupe(u8, partial_name);
        } else |_| {}
    }
    
    // Try different prefixes in order of likelihood
    const prefixes = [_][]const u8{
        "refs/heads/",     // Local branches (most common)
        "refs/tags/",      // Tags
        "refs/remotes/",   // Remote branches
        "refs/",           // Other refs
    };
    
    for (prefixes) |prefix| {
        const full_ref = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, partial_name });
        defer allocator.free(full_ref);
        
        if (resolveRef(git_dir, full_ref, platform_impl, allocator)) |hash| {
            defer allocator.free(hash);
            return try allocator.dupe(u8, full_ref);
        } else |_| {}
    }
    
    return null;
}

/// Check if a ref exists without resolving it fully
pub fn refExists(git_dir: []const u8, ref_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !bool {
    const result = resolveRef(git_dir, ref_name, platform_impl, allocator) catch |err| switch (err) {
        error.RefNotFound => return false,
        else => return err,
    };
    
    if (result) |hash| {
        allocator.free(hash);
        return true;
    }
    
    return false;
}

/// Get the short name of a ref (removes refs/heads/, refs/tags/, etc.)
pub fn getShortRefName(ref_name: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (std.mem.startsWith(u8, ref_name, "refs/heads/")) {
        return try allocator.dupe(u8, ref_name["refs/heads/".len..]);
    } else if (std.mem.startsWith(u8, ref_name, "refs/tags/")) {
        return try allocator.dupe(u8, ref_name["refs/tags/".len..]);
    } else if (std.mem.startsWith(u8, ref_name, "refs/remotes/")) {
        return try allocator.dupe(u8, ref_name["refs/remotes/".len..]);
    } else if (std.mem.startsWith(u8, ref_name, "refs/")) {
        return try allocator.dupe(u8, ref_name["refs/".len..]);
    } else {
        return try allocator.dupe(u8, ref_name);
    }
}

/// Get the type of a ref based on its prefix
pub const RefType = enum {
    branch,
    tag,
    remote,
    other,
    head,
};

pub fn getRefType(ref_name: []const u8) RefType {
    if (std.mem.eql(u8, ref_name, "HEAD")) {
        return .head;
    } else if (std.mem.startsWith(u8, ref_name, "refs/heads/")) {
        return .branch;
    } else if (std.mem.startsWith(u8, ref_name, "refs/tags/")) {
        return .tag;
    } else if (std.mem.startsWith(u8, ref_name, "refs/remotes/")) {
        return .remote;
    } else {
        return .other;
    }
}

/// Enhanced ref validation function
pub fn validateRefName(ref_name: []const u8) !void {
    if (ref_name.len == 0) return error.EmptyRefName;
    if (ref_name.len > 1024) return error.RefNameTooLong;
    
    // Check for invalid characters
    for (ref_name) |c| {
        switch (c) {
            ' ', '\t', '\n', '\r', '\\', '^', '~', ':', '?', '*', '[' => return error.InvalidRefName,
            0...31, 127 => return error.InvalidRefName, // Control characters
            else => {},
        }
    }
    
    // Check for invalid patterns
    if (std.mem.indexOf(u8, ref_name, "..")) |_| return error.InvalidRefName;
    if (std.mem.indexOf(u8, ref_name, "/.")) |_| return error.InvalidRefName;
    if (std.mem.indexOf(u8, ref_name, "@{")) |_| return error.InvalidRefName;
    if (std.mem.startsWith(u8, ref_name, ".") or std.mem.endsWith(u8, ref_name, ".")) return error.InvalidRefName;
    if (std.mem.startsWith(u8, ref_name, "/") or std.mem.endsWith(u8, ref_name, "/")) return error.InvalidRefName;
}

/// Batch resolve multiple refs efficiently with caching
pub fn resolveRefs(git_dir: []const u8, ref_names: []const []const u8, platform_impl: anytype, allocator: std.mem.Allocator) ![]?[]u8 {
    var results = try allocator.alloc(?[]u8, ref_names.len);
    
    // Pre-load packed-refs once for all lookups
    const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_refs_path);
    
    const packed_content = platform_impl.fs.readFile(allocator, packed_refs_path) catch null;
    defer if (packed_content) |content| allocator.free(content);
    
    // Create a temporary ref cache for this batch operation
    var ref_cache = std.HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
    defer {
        var cache_iter = ref_cache.iterator();
        while (cache_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        ref_cache.deinit();
    }
    
    // Parse packed-refs into cache if available
    if (packed_content) |content| {
        var lines = std.mem.split(u8, content, "\n");
        var prev_ref: ?[]const u8 = null;
        
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            
            if (trimmed[0] == '^') {
                // Peeled ref - update previous entry if it matches
                if (prev_ref != null and trimmed.len >= 41) {
                    const peeled_hash = trimmed[1..41];
                    if (isValidHash(peeled_hash)) {
                        // Replace previous entry with peeled version
                        if (ref_cache.get(prev_ref.?)) |_| {
                            try ref_cache.put(try allocator.dupe(u8, prev_ref.?), try allocator.dupe(u8, peeled_hash));
                        }
                    }
                }
                continue;
            }
            
            if (std.mem.indexOf(u8, trimmed, " ")) |space_pos| {
                const hash = trimmed[0..space_pos];
                const ref_path = trimmed[space_pos + 1..];
                prev_ref = ref_path;
                
                if (isValidHash(hash)) {
                    try ref_cache.put(try allocator.dupe(u8, ref_path), try allocator.dupe(u8, hash));
                }
            }
        }
    }
    
    // Now resolve each ref, using cache when possible
    for (ref_names, 0..) |ref_name, i| {
        // First try exact cache lookup
        if (ref_cache.get(ref_name)) |cached_hash| {
            results[i] = try allocator.dupe(u8, cached_hash);
            continue;
        }
        
        // Try with refs/ prefixes
        const prefixes = [_][]const u8{ "refs/heads/", "refs/tags/", "refs/remotes/" };
        var found = false;
        
        for (prefixes) |prefix| {
            const full_ref = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, ref_name });
            defer allocator.free(full_ref);
            
            if (ref_cache.get(full_ref)) |cached_hash| {
                results[i] = try allocator.dupe(u8, cached_hash);
                found = true;
                break;
            }
        }
        
        if (!found) {
            // Fall back to standard resolution
            results[i] = resolveRef(git_dir, ref_name, platform_impl, allocator) catch null;
        }
    }
    
    return results;
}

/// Enhanced ref name completion - suggests similar ref names when resolution fails
pub fn suggestSimilarRefs(git_dir: []const u8, partial_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) ![][]u8 {
    var suggestions = std.ArrayList([]u8).init(allocator);
    
    // Get all available refs
    const all_refs = try listAllRefs(git_dir, platform_impl, allocator);
    defer {
        for (all_refs) |ref| {
            allocator.free(ref);
        }
        allocator.free(all_refs);
    }
    
    // Find refs that contain the partial name
    for (all_refs) |ref| {
        if (std.mem.indexOf(u8, ref, partial_name) != null) {
            try suggestions.append(try allocator.dupe(u8, ref));
        }
    }
    
    // If no exact matches, try fuzzy matching
    if (suggestions.items.len == 0) {
        for (all_refs) |ref| {
            if (fuzzyMatch(ref, partial_name)) {
                try suggestions.append(try allocator.dupe(u8, ref));
            }
        }
    }
    
    return suggestions.toOwnedSlice();
}

/// Get the most recently modified branch (useful for determining active development)
pub fn getMostRecentlyModifiedBranch(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !?[]u8 {
    const branches = try listBranches(git_dir, platform_impl, allocator);
    defer {
        for (branches.items) |branch| {
            allocator.free(branch);
        }
        branches.deinit();
    }
    
    if (branches.items.len == 0) return null;
    
    var most_recent_branch: ?[]const u8 = null;
    var most_recent_time: i64 = 0;
    
    for (branches.items) |branch| {
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_dir, branch });
        defer allocator.free(ref_path);
        
        if (std.fs.cwd().statFile(ref_path)) |stat| {
            const mod_time = @divTrunc(stat.mtime, std.time.ns_per_s);
            if (mod_time > most_recent_time) {
                most_recent_time = mod_time;
                most_recent_branch = branch;
            }
        } else |_| {
            // If stat fails, skip this branch
            continue;
        }
    }
    
    if (most_recent_branch) |branch| {
        return try allocator.dupe(u8, branch);
    }
    
    return null;
}

/// Check if a commit exists in the repository (faster than full object loading)
pub fn commitExists(git_dir: []const u8, commit_hash: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !bool {
    if (commit_hash.len != 40 or !isValidHash(commit_hash)) return false;
    
    // First try to resolve as a ref in case it's actually a ref name
    if (resolveRef(git_dir, commit_hash, platform_impl, allocator)) |resolved| {
        defer allocator.free(resolved);
        return true;
    } else |_| {}
    
    // Try to load the object to verify it exists and is a commit
    const objects = @import("objects.zig");
    const obj = objects.GitObject.load(commit_hash, git_dir, platform_impl, allocator) catch return false;
    defer obj.deinit(allocator);
    
    return obj.type == .commit;
}

/// Advanced ref management operations
pub const RefManager = struct {
    git_dir: []const u8,
    allocator: std.mem.Allocator,
    
    pub fn init(git_dir: []const u8, allocator: std.mem.Allocator) RefManager {
        return RefManager{
            .git_dir = git_dir,
            .allocator = allocator,
        };
    }
    
    /// Create a new branch reference
    pub fn createBranch(self: RefManager, branch_name: []const u8, commit_hash: []const u8, platform_impl: anytype) !void {
        // Validate inputs
        if (branch_name.len == 0) return error.EmptyBranchName;
        if (commit_hash.len != 40 or !isValidHash(commit_hash)) return error.InvalidCommitHash;
        
        // Check if branch already exists
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch_name});
        defer self.allocator.free(ref_name);
        
        if (refExists(self.git_dir, ref_name, platform_impl, self.allocator)) |exists| {
            if (exists) return error.BranchAlreadyExists;
        } else |_| {}
        
        // Create branch ref file
        const ref_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, ref_name });
        defer self.allocator.free(ref_path);
        
        // Ensure refs/heads directory exists
        const refs_heads_dir = try std.fmt.allocPrint(self.allocator, "{s}/refs/heads", .{self.git_dir});
        defer self.allocator.free(refs_heads_dir);
        
        std.fs.cwd().makePath(refs_heads_dir) catch {};
        
        try platform_impl.fs.writeFile(ref_path, commit_hash);
    }
    
    /// Delete a branch reference
    pub fn deleteBranch(self: RefManager, branch_name: []const u8, platform_impl: anytype) !void {
        if (branch_name.len == 0) return error.EmptyBranchName;
        
        // Don't allow deleting current branch
        const current_branch = getCurrentBranch(self.git_dir, platform_impl, self.allocator) catch null;
        if (current_branch) |current| {
            defer self.allocator.free(current);
            if (std.mem.eql(u8, current, branch_name)) {
                return error.CannotDeleteCurrentBranch;
            }
        }
        
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch_name});
        defer self.allocator.free(ref_name);
        
        const ref_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, ref_name });
        defer self.allocator.free(ref_path);
        
        // Try to delete the file
        platform_impl.fs.deleteFile(ref_path) catch |err| switch (err) {
            error.FileNotFound => return error.BranchNotFound,
            else => return err,
        };
    }
    
    /// Update HEAD to point to a different branch
    pub fn checkoutBranch(self: RefManager, branch_name: []const u8, platform_impl: anytype) !void {
        if (branch_name.len == 0) return error.EmptyBranchName;
        
        // Verify branch exists
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch_name});
        defer self.allocator.free(ref_name);
        
        if (refExists(self.git_dir, ref_name, platform_impl, self.allocator)) |exists| {
            if (!exists) return error.BranchNotFound;
        } else |_| {
            return error.BranchNotFound;
        }
        
        // Update HEAD
        const head_path = try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{self.git_dir});
        defer self.allocator.free(head_path);
        
        const head_content = try std.fmt.allocPrint(self.allocator, "ref: {s}\n", .{ref_name});
        defer self.allocator.free(head_content);
        
        try platform_impl.fs.writeFile(head_path, head_content);
    }
    
    /// Get detailed information about a ref
    pub fn getRefInfo(self: RefManager, ref_name: []const u8, platform_impl: anytype) !RefInfo {
        const resolved_hash = resolveRef(self.git_dir, ref_name, platform_impl, self.allocator) catch |err| switch (err) {
            error.RefNotFound => return error.RefNotFound,
            else => return err,
        };
        
        if (resolved_hash) |hash| {
            defer self.allocator.free(hash);
            
            // Determine ref type
            var ref_type: RefType = .branch;
            if (std.mem.startsWith(u8, ref_name, "refs/heads/")) {
                ref_type = .branch;
            } else if (std.mem.startsWith(u8, ref_name, "refs/tags/")) {
                ref_type = .tag;
            } else if (std.mem.startsWith(u8, ref_name, "refs/remotes/")) {
                ref_type = .remote_branch;
            } else if (std.mem.eql(u8, ref_name, "HEAD")) {
                ref_type = .head;
            } else {
                ref_type = .other;
            }
            
            // Check if it's symbolic
            const resolution = resolveRefOnce(self.git_dir, ref_name, platform_impl, self.allocator) catch {
                return RefInfo{
                    .name = try self.allocator.dupe(u8, ref_name),
                    .hash = try self.allocator.dupe(u8, hash),
                    .ref_type = ref_type,
                    .is_symbolic = false,
                    .target = null,
                };
            };
            defer if (resolution.target) |target| self.allocator.free(target);
            
            return RefInfo{
                .name = try self.allocator.dupe(u8, ref_name),
                .hash = try self.allocator.dupe(u8, hash),
                .ref_type = ref_type,
                .is_symbolic = resolution.is_symbolic,
                .target = if (resolution.is_symbolic) try self.allocator.dupe(u8, resolution.target) else null,
            };
        } else {
            return error.RefNotFound;
        }
    }
    
    /// List all refs with their information
    pub fn getAllRefsInfo(self: RefManager, platform_impl: anytype) ![]RefInfo {
        var refs_info = std.ArrayList(RefInfo).init(self.allocator);
        
        const all_refs = listAllRefs(self.git_dir, platform_impl, self.allocator) catch return refs_info.toOwnedSlice();
        defer {
            for (all_refs) |ref| {
                self.allocator.free(ref);
            }
            self.allocator.free(all_refs);
        }
        
        for (all_refs) |ref| {
            if (self.getRefInfo(ref, platform_impl)) |info| {
                try refs_info.append(info);
            } else |_| {}
        }
        
        return refs_info.toOwnedSlice();
    }
};

/// Detailed information about a reference
pub const RefInfo = struct {
    name: []const u8,
    hash: []const u8,
    ref_type: RefType,
    is_symbolic: bool,
    target: ?[]const u8, // For symbolic refs
    
    pub fn deinit(self: RefInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.hash);
        if (self.target) |target| allocator.free(target);
    }
    
    pub fn print(self: RefInfo) void {
        const type_str = switch (self.ref_type) {
            .branch => "branch",
            .tag => "tag",
            .remote_branch => "remote-branch",
            .head => "HEAD",
            .other => "other",
        };
        
        if (self.is_symbolic and self.target != null) {
            std.debug.print("{s} -> {s} ({s}) [{s}]\n", .{ self.name, self.target.?, self.hash, type_str });
        } else {
            std.debug.print("{s} {s} [{s}]\n", .{ self.name, self.hash, type_str });
        }
    }
};

/// Simple fuzzy matching for ref name suggestions
fn fuzzyMatch(ref: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    if (pattern.len > ref.len) return false;
    
    var ref_i: usize = 0;
    var pattern_i: usize = 0;
    
    while (ref_i < ref.len and pattern_i < pattern.len) {
        if (std.ascii.toLower(ref[ref_i]) == std.ascii.toLower(pattern[pattern_i])) {
            pattern_i += 1;
        }
        ref_i += 1;
    }
    
    return pattern_i == pattern.len;
}

/// List all refs in the repository
fn listAllRefs(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) ![][]u8 {
    var all_refs = std.ArrayList([]u8).init(allocator);
    
    // Add HEAD
    const head_exists = refExists(git_dir, "HEAD", platform_impl, allocator) catch false;
    if (head_exists) {
        try all_refs.append(try allocator.dupe(u8, "HEAD"));
    }
    
    // List refs from filesystem
    const refs_path = try std.fmt.allocPrint(allocator, "{s}/refs", .{git_dir});
    defer allocator.free(refs_path);
    
    try listRefsInDir(refs_path, "refs", platform_impl, allocator, &all_refs);
    
    // Add refs from packed-refs
    try listRefsFromPackedRefs(git_dir, platform_impl, allocator, &all_refs);
    
    return all_refs.toOwnedSlice();
}

/// Recursively list refs in a directory
fn listRefsInDir(dir_path: []const u8, prefix: []const u8, platform_impl: anytype, allocator: std.mem.Allocator, refs_list: *std.ArrayList([]u8)) !void {
    
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(full_path);
        
        if (entry.kind == .directory) {
            const new_prefix = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            defer allocator.free(new_prefix);
            try listRefsInDir(full_path, new_prefix, platform_impl, allocator, refs_list);
        } else if (entry.kind == .file) {
            const ref_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            try refs_list.append(ref_name);
        }
    }
}

/// List refs from packed-refs file
fn listRefsFromPackedRefs(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator, refs_list: *std.ArrayList([]u8)) !void {
    const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_refs_path);
    
    const content = platform_impl.fs.readFile(allocator, packed_refs_path) catch return;
    defer allocator.free(content);
    
    var lines = std.mem.split(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\n\r");
        
        // Skip comments, empty lines, and peeled refs
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '^') continue;
        
        // Format: "<hash> <ref_name>"
        if (std.mem.indexOf(u8, trimmed, " ")) |space_pos| {
            const ref_name = trimmed[space_pos + 1..];
            
            // Check if we already have this ref
            var already_added = false;
            for (refs_list.items) |existing_ref| {
                if (std.mem.eql(u8, existing_ref, ref_name)) {
                    already_added = true;
                    break;
                }
            }
            
            if (!already_added) {
                try refs_list.append(try allocator.dupe(u8, ref_name));
            }
        }
    }
}

/// Enhanced branch management with upstream tracking
pub const BranchManager = struct {
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, git_dir: []const u8) BranchManager {
        return BranchManager{
            .allocator = allocator,
            .git_dir = git_dir,
        };
    }
    
    /// Create a new branch
    pub fn createBranch(self: BranchManager, branch_name: []const u8, start_point: ?[]const u8, platform_impl: anytype) !void {
        // Validate branch name
        if (!isValidRefName(branch_name)) {
            return error.InvalidBranchName;
        }
        
        // Resolve start point (default to HEAD)
        const start_hash = if (start_point) |sp|
            (try resolveRef(self.git_dir, sp, platform_impl, self.allocator)) orelse return error.InvalidStartPoint
        else
            (try resolveRef(self.git_dir, "HEAD", platform_impl, self.allocator)) orelse return error.NoHEAD;
        
        defer self.allocator.free(start_hash);
        
        // Create branch ref
        const branch_path = try std.fmt.allocPrint(self.allocator, "{s}/refs/heads/{s}", .{self.git_dir, branch_name});
        defer self.allocator.free(branch_path);
        
        try std.fs.cwd().writeFile(branch_path, start_hash);
    }
    
    /// Delete a branch
    pub fn deleteBranch(self: BranchManager, branch_name: []const u8, force: bool, platform_impl: anytype) !void {
        // Prevent deleting current branch
        const current_branch = getCurrentBranch(self.git_dir, platform_impl, self.allocator) catch null;
        if (current_branch) |current| {
            defer self.allocator.free(current);
            if (std.mem.eql(u8, current, branch_name)) {
                return error.CannotDeleteCurrentBranch;
            }
        }
        
        // Check if branch is merged (unless force)
        if (!force) {
            // TODO: Check if branch is merged into HEAD
            // For now, we'll just allow deletion
        }
        
        const branch_path = try std.fmt.allocPrint(self.allocator, "{s}/refs/heads/{s}", .{self.git_dir, branch_name});
        defer self.allocator.free(branch_path);
        
        std.fs.cwd().deleteFile(branch_path) catch |err| switch (err) {
            error.FileNotFound => return error.BranchNotFound,
            else => return err,
        };
    }
    
    /// Set upstream tracking for a branch
    pub fn setUpstream(self: BranchManager, branch_name: []const u8, upstream_remote: []const u8, upstream_branch: []const u8) !void {
        const config = @import("config.zig");
        var git_config = config.loadGitConfig(self.git_dir, self.allocator) catch config.GitConfig.init(self.allocator);
        defer git_config.deinit();
        
        try git_config.setValue("branch", branch_name, "remote", upstream_remote);
        
        const merge_ref = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{upstream_branch});
        defer self.allocator.free(merge_ref);
        try git_config.setValue("branch", branch_name, "merge", merge_ref);
        
        // Write config back
        const config_path = try std.fmt.allocPrint(self.allocator, "{s}/config", .{self.git_dir});
        defer self.allocator.free(config_path);
        try git_config.writeToFile(config_path);
    }
};

