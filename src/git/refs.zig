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

pub fn getCurrentBranch(git_dir: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);

    const file = try std.fs.openFileAbsolute(head_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024);
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

pub fn getCurrentCommit(git_dir: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);

    const file = try std.fs.openFileAbsolute(head_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    
    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const ref_path = trimmed["ref: ".len..];
        const ref_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_path });
        defer allocator.free(ref_file_path);

        const ref_file = std.fs.openFileAbsolute(ref_file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null, // Branch exists but no commits yet
            else => return err,
        };
        defer ref_file.close();

        const ref_content = try ref_file.readToEndAlloc(allocator, 1024);
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

pub fn updateRef(git_dir: []const u8, ref_name: []const u8, hash: []const u8, allocator: std.mem.Allocator) !void {
    const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_dir, ref_name });
    defer allocator.free(ref_path);

    // Create parent directory if it doesn't exist
    const parent_dir = std.fs.path.dirname(ref_path).?;
    std.fs.makeDirAbsolute(parent_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const file = try std.fs.createFileAbsolute(ref_path, .{ .truncate = true });
    defer file.close();
    
    try file.writer().print("{s}\n", .{hash});
}

pub fn updateHEAD(git_dir: []const u8, branch_or_hash: []const u8, allocator: std.mem.Allocator) !void {
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);

    const file = try std.fs.createFileAbsolute(head_path, .{ .truncate = true });
    defer file.close();

    if (branch_or_hash.len == 40 and isValidHash(branch_or_hash)) {
        // Detached HEAD
        try file.writer().print("{s}\n", .{branch_or_hash});
    } else {
        // Branch reference
        try file.writer().print("ref: refs/heads/{s}\n", .{branch_or_hash});
    }
}

pub fn listBranches(git_dir: []const u8, allocator: std.mem.Allocator) !std.ArrayList([]u8) {
    const heads_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{git_dir});
    defer allocator.free(heads_path);

    var branches = std.ArrayList([]u8).init(allocator);
    
    var dir = std.fs.openDirAbsolute(heads_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return branches, // No branches yet
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file) {
            try branches.append(try allocator.dupe(u8, entry.name));
        }
    }

    return branches;
}

pub fn branchExists(git_dir: []const u8, branch_name: []const u8, allocator: std.mem.Allocator) !bool {
    const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_dir, branch_name });
    defer allocator.free(ref_path);

    std.fs.accessAbsolute(ref_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    
    return true;
}

pub fn createBranch(git_dir: []const u8, branch_name: []const u8, start_point: ?[]const u8, allocator: std.mem.Allocator) !void {
    const hash = if (start_point) |sp| blk: {
        if (sp.len == 40 and isValidHash(sp)) {
            break :blk try allocator.dupe(u8, sp);
        } else {
            // Resolve branch name to hash
            const commit_hash = try getBranchCommit(git_dir, sp, allocator);
            if (commit_hash) |h| {
                break :blk h;
            } else {
                return error.InvalidStartPoint;
            }
        }
    } else blk: {
        // Use current HEAD
        const current_commit = try getCurrentCommit(git_dir, allocator);
        if (current_commit) |h| {
            break :blk h;
        } else {
            return error.NoCommitsYet;
        }
    };
    defer allocator.free(hash);

    try updateRef(git_dir, branch_name, hash, allocator);
}

pub fn deleteBranch(git_dir: []const u8, branch_name: []const u8, allocator: std.mem.Allocator) !void {
    const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_dir, branch_name });
    defer allocator.free(ref_path);

    try std.fs.deleteFileAbsolute(ref_path);
}

pub fn getBranchCommit(git_dir: []const u8, branch_name: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_dir, branch_name });
    defer allocator.free(ref_path);

    const file = std.fs.openFileAbsolute(ref_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024);
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