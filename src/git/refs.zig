const std = @import("std");

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
        if (std.ascii.indexOfIgnoreCase(ref, partial_name) != null) {
            try suggestions.append(try allocator.dupe(u8, ref));
        }
    }
    
    // Sort suggestions by similarity (shorter refs first)
    std.sort.block([]u8, suggestions.items, {}, struct {
        fn lessThan(context: void, lhs: []u8, rhs: []u8) bool {
            _ = context;
            return lhs.len < rhs.len;
        }
    }.lessThan);
    
    return suggestions.toOwnedSlice();
}

/// List all available refs in the repository
fn listAllRefs(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) ![][]u8 {
    var all_refs = std.ArrayList([]u8).init(allocator);
    
    // Add HEAD if it exists
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    
    if (platform_impl.fs.exists(head_path) catch false) {
        try all_refs.append(try allocator.dupe(u8, "HEAD"));
    }
    
    // Recursively scan refs directory
    const refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs", .{git_dir});
    defer allocator.free(refs_dir);
    
    try scanRefsDirectory(refs_dir, "refs", platform_impl, allocator, &all_refs);
    
    // Add refs from packed-refs
    const packed_refs = findAllRefsInPackedRefs(git_dir, platform_impl, allocator) catch std.ArrayList([]u8).init(allocator);
    defer {
        for (packed_refs.items) |ref| {
            allocator.free(ref);
        }
        packed_refs.deinit();
    }
    
    // Merge packed refs that aren't already in the list
    for (packed_refs.items) |packed_ref| {
        var found = false;
        for (all_refs.items) |existing_ref| {
            if (std.mem.eql(u8, existing_ref, packed_ref)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try all_refs.append(try allocator.dupe(u8, packed_ref));
        }
    }
    
    return all_refs.toOwnedSlice();
}

/// Recursively scan refs directory for all refs
fn scanRefsDirectory(dir_path: []const u8, ref_prefix: []const u8, platform_impl: anytype, allocator: std.mem.Allocator, refs_list: *std.ArrayList([]u8)) !void {
    const entries = platform_impl.fs.readDir(allocator, dir_path) catch return;
    defer {
        for (entries) |entry| {
            allocator.free(entry);
        }
        allocator.free(entries);
    }
    
    for (entries) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry });
        defer allocator.free(full_path);
        
        const full_ref = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ref_prefix, entry });
        
        // Check if it's a directory
        const stat = std.fs.cwd().statFile(full_path) catch continue;
        if (stat.kind == .directory) {
            defer allocator.free(full_ref);
            try scanRefsDirectory(full_path, full_ref, platform_impl, allocator, refs_list);
        } else {
            try refs_list.append(full_ref);
        }
    }
}

/// Find all refs in packed-refs file
fn findAllRefsInPackedRefs(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !std.ArrayList([]u8) {
    var refs = std.ArrayList([]u8).init(allocator);
    
    const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_refs_path);

    const content = platform_impl.fs.readFile(allocator, packed_refs_path) catch return refs;
    defer allocator.free(content);

    var lines = std.mem.split(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        
        // Skip comments, empty lines, and peeled refs
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '^') continue;
        
        if (std.mem.indexOf(u8, trimmed, " ")) |space_pos| {
            const ref_path = trimmed[space_pos + 1..];
            try refs.append(try allocator.dupe(u8, ref_path));
        }
    }
    
    return refs;
}