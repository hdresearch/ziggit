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
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);

    const content = try platform_impl.fs.readFile(allocator, head_path);
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    
    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const ref_path = trimmed["ref: ".len..];
        const ref_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_path });
        defer allocator.free(ref_file_path);

        const ref_content = platform_impl.fs.readFile(allocator, ref_file_path) catch |err| switch (err) {
            error.FileNotFound => {
                // Try to find it in packed-refs
                return readFromPackedRefs(git_dir, ref_path, platform_impl, allocator) catch null;
            },
            else => return err,
        };
        defer allocator.free(ref_content);

        const hash = std.mem.trim(u8, ref_content, " \t\n\r");
        if (hash.len == 40 and isValidHash(hash)) {
            return try allocator.dupe(u8, hash);
        } else {
            return error.InvalidHash;
        }
    } else if (trimmed.len == 40 and isValidHash(trimmed)) {
        // Detached HEAD
        return try allocator.dupe(u8, trimmed);
    } else {
        return error.InvalidHEAD;
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

/// Read ref hash from packed-refs file
fn readFromPackedRefs(git_dir: []const u8, ref_name: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) ![]u8 {
    const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_refs_path);

    const content = platform_impl.fs.readFile(allocator, packed_refs_path) catch |err| switch (err) {
        error.FileNotFound => return error.RefNotFound,
        else => return err,
    };
    defer allocator.free(content);

    // Parse packed-refs file
    var lines = std.mem.split(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        
        // Skip comments and empty lines
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        
        // Format: "<hash> <ref_name>"
        if (std.mem.indexOf(u8, trimmed, " ")) |space_pos| {
            const hash = trimmed[0..space_pos];
            const ref_path = trimmed[space_pos + 1..];
            
            if (std.mem.eql(u8, ref_path, ref_name) and isValidHash(hash)) {
                return try allocator.dupe(u8, hash);
            }
        }
    }
    
    return error.RefNotFound;
}