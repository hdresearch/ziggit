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
    var current_ref = try allocator.dupe(u8, ref_name);
    defer allocator.free(current_ref);
    
    var depth: u32 = 0;
    const max_depth = 10; // Prevent infinite loops
    
    while (depth < max_depth) {
        defer depth += 1;
        
        const resolved = resolveRefOnce(git_dir, current_ref, platform_impl, allocator) catch |err| {
            // If resolution fails, try without assuming the ref is partial
            if (std.mem.eql(u8, current_ref, "HEAD")) {
                return err; // HEAD should always exist
            }
            // Try as full ref path if it failed as a short name
            if (!std.mem.startsWith(u8, current_ref, "refs/")) {
                const full_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{current_ref});
                defer allocator.free(full_ref);
                const backup_resolved = resolveRefOnce(git_dir, full_ref, platform_impl, allocator) catch return err;
                if (!backup_resolved.is_symbolic) {
                    const final_hash = try resolveAnnotatedTag(git_dir, backup_resolved.target, platform_impl, allocator);
                    allocator.free(backup_resolved.target);
                    return final_hash;
                } else {
                    allocator.free(current_ref);
                    current_ref = backup_resolved.target;
                    continue;
                }
            }
            return err;
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
    const hash = if (start_point) |sp| blk: {
        if (sp.len == 40 and isValidHash(sp)) {
            break :blk try allocator.dupe(u8, sp);
        } else {
            // Resolve branch name to hash
            const commit_hash = try getBranchCommit(git_dir, sp, platform_impl, allocator);
            if (commit_hash) |h| {
                break :blk h;
            } else {
                return error.InvalidStartPoint;
            }
        }
    } else blk: {
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

/// Read ref hash from packed-refs file with improved performance
fn readFromPackedRefs(git_dir: []const u8, ref_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) ![]u8 {
    const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_refs_path);

    const content = platform_impl.fs.readFile(allocator, packed_refs_path) catch |err| switch (err) {
        error.FileNotFound => return error.RefNotFound,
        else => return err,
    };
    defer allocator.free(content);

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