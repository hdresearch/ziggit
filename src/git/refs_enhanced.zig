const std = @import("std");
const refs = @import("refs.zig");
const objects = @import("objects.zig");

/// Enhanced ref resolution with detailed information
pub const RefInfo = struct {
    name: []u8,
    hash: []u8,
    ref_type: RefType,
    target_type: ?ObjectType, // Type of the final object (for annotated tags)
    symbolic_target: ?[]u8, // If this is a symbolic ref, what it points to
    
    pub const RefType = enum {
        direct,      // Points directly to a commit/object hash
        symbolic,    // Points to another ref (like HEAD -> refs/heads/main)
        annotated,   // Annotated tag (tag object pointing to commit)
    };
    
    pub const ObjectType = enum {
        commit,
        tree,
        blob,
        tag,
    };
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, hash: []const u8, ref_type: RefType) !RefInfo {
        return RefInfo{
            .name = try allocator.dupe(u8, name),
            .hash = try allocator.dupe(u8, hash),
            .ref_type = ref_type,
            .target_type = null,
            .symbolic_target = null,
        };
    }
    
    pub fn deinit(self: RefInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.hash);
        if (self.symbolic_target) |target| {
            allocator.free(target);
        }
    }
    
    pub fn setSymbolicTarget(self: *RefInfo, allocator: std.mem.Allocator, target: []const u8) !void {
        if (self.symbolic_target) |old_target| {
            allocator.free(old_target);
        }
        self.symbolic_target = try allocator.dupe(u8, target);
    }
    
    pub fn print(self: RefInfo) void {
        std.debug.print("Ref: {s}\n", .{self.name});
        std.debug.print("  Hash: {s}\n", .{self.hash});
        std.debug.print("  Type: {}\n", .{self.ref_type});
        if (self.target_type) |target_type| {
            std.debug.print("  Target Type: {}\n", .{target_type});
        }
        if (self.symbolic_target) |target| {
            std.debug.print("  Symbolic Target: {s}\n", .{target});
        }
    }
};

/// Get detailed information about a reference
pub fn getRefInfo(git_dir: []const u8, ref_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !RefInfo {
    // First, resolve the reference to get the final hash
    const final_hash = refs.resolveRef(git_dir, ref_name, platform_impl, allocator) catch |err| {
        return err;
    };
    defer if (final_hash) |hash| allocator.free(hash);
    
    if (final_hash == null) {
        return error.RefNotFound;
    }
    
    var ref_info = try RefInfo.init(allocator, ref_name, final_hash.?, .direct);
    
    // Check if this is a symbolic ref
    const direct_resolution = resolveRefDirect(git_dir, ref_name, platform_impl, allocator) catch {
        return ref_info; // Return what we have
    };
    defer if (direct_resolution.symbolic_target) |target| allocator.free(target);
    
    if (direct_resolution.is_symbolic) {
        ref_info.ref_type = .symbolic;
        try ref_info.setSymbolicTarget(allocator, direct_resolution.symbolic_target.?);
    }
    
    // Check if the final hash points to an annotated tag
    const target_object = objects.GitObject.load(final_hash.?, git_dir, platform_impl, allocator) catch {
        return ref_info; // Can't load object, return what we have
    };
    defer target_object.deinit(allocator);
    
    ref_info.target_type = switch (target_object.type) {
        .commit => .commit,
        .tree => .tree,
        .blob => .blob,
        .tag => blk: {
            ref_info.ref_type = .annotated;
            break :blk .tag;
        },
    };
    
    return ref_info;
}

/// Direct ref resolution (one level only)
const DirectRefResolution = struct {
    hash: []u8,
    is_symbolic: bool,
    symbolic_target: ?[]u8,
};

fn resolveRefDirect(git_dir: []const u8, ref_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !DirectRefResolution {
    const ref_path = if (std.mem.eql(u8, ref_name, "HEAD"))
        try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir})
    else if (std.mem.startsWith(u8, ref_name, "refs/"))
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name })
    else
        try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_dir, ref_name });
    defer allocator.free(ref_path);
    
    const content = platform_impl.fs.readFile(allocator, ref_path) catch {
        return DirectRefResolution{
            .hash = try allocator.dupe(u8, ref_name), // Assume it's a hash
            .is_symbolic = false,
            .symbolic_target = null,
        };
    };
    defer allocator.free(content);
    
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    
    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        return DirectRefResolution{
            .hash = try allocator.dupe(u8, ""),
            .is_symbolic = true,
            .symbolic_target = try allocator.dupe(u8, trimmed[5..]),
        };
    } else {
        return DirectRefResolution{
            .hash = try allocator.dupe(u8, trimmed),
            .is_symbolic = false,
            .symbolic_target = null,
        };
    }
}

/// List all references in a repository with their information
pub fn listAllRefs(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !std.ArrayList(RefInfo) {
    var refs_list = std.ArrayList(RefInfo).init(allocator);
    errdefer {
        for (refs_list.items) |ref_info| {
            ref_info.deinit(allocator);
        }
        refs_list.deinit();
    }
    
    // Add HEAD if it exists
    if (getRefInfo(git_dir, "HEAD", platform_impl, allocator)) |head_info| {
        try refs_list.append(head_info);
    } else |_| {}
    
    // List refs/heads/
    try listRefsInDirectory(git_dir, "refs/heads", platform_impl, allocator, &refs_list);
    
    // List refs/tags/
    try listRefsInDirectory(git_dir, "refs/tags", platform_impl, allocator, &refs_list);
    
    // List refs/remotes/
    try listRefsInDirectory(git_dir, "refs/remotes", platform_impl, allocator, &refs_list);
    
    return refs_list;
}

fn listRefsInDirectory(git_dir: []const u8, refs_subdir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator, refs_list: *std.ArrayList(RefInfo)) !void {
    const refs_dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, refs_subdir });
    defer allocator.free(refs_dir_path);
    
    var refs_dir = std.fs.cwd().openDir(refs_dir_path, .{ .iterate = true }) catch {
        return; // Directory doesn't exist, that's ok
    };
    defer refs_dir.close();
    
    var iterator = refs_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        
        const full_ref_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ refs_subdir, entry.name });
        defer allocator.free(full_ref_name);
        
        if (getRefInfo(git_dir, full_ref_name, platform_impl, allocator)) |ref_info| {
            try refs_list.append(ref_info);
        } else |_| {
            // Skip refs we can't resolve
        }
    }
}

/// Find refs that point to a specific commit
pub fn findRefsPointingTo(git_dir: []const u8, target_hash: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !std.ArrayList(RefInfo) {
    var matching_refs = std.ArrayList(RefInfo).init(allocator);
    errdefer {
        for (matching_refs.items) |ref_info| {
            ref_info.deinit(allocator);
        }
        matching_refs.deinit();
    }
    
    const all_refs = try listAllRefs(git_dir, platform_impl, allocator);
    defer {
        for (all_refs.items) |ref_info| {
            ref_info.deinit(allocator);
        }
        all_refs.deinit();
    }
    
    for (all_refs.items) |ref_info| {
        if (std.mem.eql(u8, ref_info.hash, target_hash)) {
            try matching_refs.append(try RefInfo.init(allocator, ref_info.name, ref_info.hash, ref_info.ref_type));
        }
    }
    
    return matching_refs;
}

/// Validate that a ref name follows git naming conventions
pub fn isValidRefName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name.len > 1024) return false; // Reasonable limit
    
    // Check for invalid characters
    for (name) |c| {
        switch (c) {
            ' ', '\t', '\n', '\r', '~', '^', ':', '?', '*', '[', '\\', 0x7F => return false,
            0x00...0x1F => return false, // Control characters
            else => {},
        }
    }
    
    // Check for invalid patterns
    if (name[0] == '.') return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.endsWith(u8, name, "/")) return false;
    if (std.mem.endsWith(u8, name, ".lock")) return false;
    if (std.mem.indexOf(u8, name, "@{") != null) return false;
    
    // Can't be just "@"
    if (std.mem.eql(u8, name, "@")) return false;
    
    return true;
}

/// Check if a commit is reachable from another commit (ancestry check)
pub fn isAncestor(git_dir: []const u8, ancestor_hash: []const u8, descendant_hash: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !bool {
    if (std.mem.eql(u8, ancestor_hash, descendant_hash)) {
        return true; // Same commit
    }
    
    // Simple implementation: walk back from descendant to see if we reach ancestor
    var current_hash = try allocator.dupe(u8, descendant_hash);
    defer allocator.free(current_hash);
    
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();
    
    var depth: u32 = 0;
    const max_depth = 10000; // Prevent infinite loops
    
    while (depth < max_depth) {
        // Check if we've visited this commit before (cycle detection)
        if (visited.contains(current_hash)) {
            break;
        }
        try visited.put(current_hash, {});
        
        // Load the commit object
        const commit_obj = objects.GitObject.load(current_hash, git_dir, platform_impl, allocator) catch {
            break; // Can't load object, stop searching
        };
        defer commit_obj.deinit(allocator);
        
        if (commit_obj.type != .commit) {
            break; // Not a commit, stop
        }
        
        // Parse commit to find parents
        const parents = try parseCommitParents(commit_obj.data, allocator);
        defer {
            for (parents.items) |parent| {
                allocator.free(parent);
            }
            parents.deinit();
        }
        
        // Check if ancestor is among the parents
        for (parents.items) |parent| {
            if (std.mem.eql(u8, parent, ancestor_hash)) {
                return true;
            }
        }
        
        // Continue with first parent (main line of history)
        if (parents.items.len > 0) {
            allocator.free(current_hash);
            current_hash = try allocator.dupe(u8, parents.items[0]);
        } else {
            break; // No parents, reached root
        }
        
        depth += 1;
    }
    
    return false;
}

/// Parse commit object to extract parent hashes
fn parseCommitParents(commit_data: []const u8, allocator: std.mem.Allocator) !std.ArrayList([]u8) {
    var parents = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (parents.items) |parent| {
            allocator.free(parent);
        }
        parents.deinit();
    }
    
    var lines = std.mem.split(u8, commit_data, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "parent ")) {
            const parent_hash = std.mem.trim(u8, line[7..], " \t");
            if (parent_hash.len == 40) { // Valid SHA-1
                try parents.append(try allocator.dupe(u8, parent_hash));
            }
        } else if (line.len == 0) {
            break; // End of header, start of commit message
        }
    }
    
    return parents;
}

/// Get the most recent common ancestor of two commits
pub fn getMergeBase(git_dir: []const u8, hash1: []const u8, hash2: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !?[]u8 {
    // Simple implementation: find common ancestors by walking back from both commits
    var ancestors1 = std.StringHashMap(void).init(allocator);
    defer ancestors1.deinit();
    
    // Collect ancestors of first commit
    try collectAncestors(git_dir, hash1, platform_impl, allocator, &ancestors1, 1000);
    
    // Walk back from second commit until we find a common ancestor
    var current_hash = try allocator.dupe(u8, hash2);
    defer allocator.free(current_hash);
    
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();
    
    var depth: u32 = 0;
    const max_depth = 1000;
    
    while (depth < max_depth) {
        if (visited.contains(current_hash)) break;
        try visited.put(current_hash, {});
        
        // Check if this commit is an ancestor of the first commit
        if (ancestors1.contains(current_hash)) {
            return try allocator.dupe(u8, current_hash);
        }
        
        // Load commit and get first parent
        const commit_obj = objects.GitObject.load(current_hash, git_dir, platform_impl, allocator) catch break;
        defer commit_obj.deinit(allocator);
        
        if (commit_obj.type != .commit) break;
        
        const parents = try parseCommitParents(commit_obj.data, allocator);
        defer {
            for (parents.items) |parent| {
                allocator.free(parent);
            }
            parents.deinit();
        }
        
        if (parents.items.len > 0) {
            allocator.free(current_hash);
            current_hash = try allocator.dupe(u8, parents.items[0]);
        } else {
            break;
        }
        
        depth += 1;
    }
    
    return null; // No common ancestor found
}

fn collectAncestors(git_dir: []const u8, start_hash: []const u8, platform_impl: anytype, allocator: std.mem.Allocator, ancestors: *std.StringHashMap(void), max_depth: u32) !void {
    var current_hash = try allocator.dupe(u8, start_hash);
    defer allocator.free(current_hash);
    
    var depth: u32 = 0;
    
    while (depth < max_depth) {
        if (ancestors.contains(current_hash)) break;
        try ancestors.put(current_hash, {});
        
        const commit_obj = objects.GitObject.load(current_hash, git_dir, platform_impl, allocator) catch break;
        defer commit_obj.deinit(allocator);
        
        if (commit_obj.type != .commit) break;
        
        const parents = try parseCommitParents(commit_obj.data, allocator);
        defer {
            for (parents.items) |parent| {
                allocator.free(parent);
            }
            parents.deinit();
        }
        
        if (parents.items.len > 0) {
            allocator.free(current_hash);
            current_hash = try allocator.dupe(u8, parents.items[0]);
        } else {
            break;
        }
        
        depth += 1;
    }
}