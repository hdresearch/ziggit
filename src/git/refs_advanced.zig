const std = @import("std");
const refs_mod = @import("refs.zig");

/// Advanced ref operations and utilities
pub const RefsAdvanced = struct {
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, git_dir: []const u8) !RefsAdvanced {
        return RefsAdvanced{
            .allocator = allocator,
            .git_dir = try allocator.dupe(u8, git_dir),
        };
    }
    
    pub fn deinit(self: *RefsAdvanced) void {
        self.allocator.free(self.git_dir);
    }
    
    /// Get detailed information about a ref including its resolution chain
    pub fn getRefInfo(self: RefsAdvanced, ref_name: []const u8, platform_impl: anytype) !RefInfo {
        var info = RefInfo.init(self.allocator);
        
        // Track resolution chain
        var current_ref = try self.allocator.dupe(u8, ref_name);
        defer self.allocator.free(current_ref);
        
        var depth: u32 = 0;
        const max_depth = 20;
        
        while (depth < max_depth) {
            defer depth += 1;
            
            // Add to resolution chain
            try info.resolution_chain.append(try self.allocator.dupe(u8, current_ref));
            
            // Try to resolve this ref
            const resolution = self.resolveRefOnce(current_ref, platform_impl) catch |err| {
                info.error_msg = try std.fmt.allocPrint(self.allocator, "Failed to resolve {s}: {}", .{ current_ref, err });
                break;
            };
            defer self.allocator.free(resolution.target);
            
            if (resolution.is_symbolic) {
                // Continue following the chain
                self.allocator.free(current_ref);
                current_ref = try self.allocator.dupe(u8, resolution.target);
                info.is_symbolic = true;
            } else {
                // Found final hash
                info.final_hash = try self.allocator.dupe(u8, resolution.target);
                break;
            }
        }
        
        if (depth >= max_depth) {
            info.error_msg = try std.fmt.allocPrint(self.allocator, "Too many symbolic ref levels (>{} )", .{max_depth});
        }
        
        // Determine ref type
        info.ref_type = determineRefType(ref_name);
        
        return info;
    }
    
    /// Get all refs in the repository
    pub fn getAllRefs(self: RefsAdvanced, platform_impl: anytype) !RefList {
        var ref_list = RefList.init(self.allocator);
        
        // Collect from loose refs
        try self.collectLooseRefs(&ref_list, platform_impl);
        
        // Collect from packed-refs
        try self.collectPackedRefs(&ref_list, platform_impl);
        
        // Sort refs by name
        std.sort.block(RefEntry, ref_list.refs.items, {}, struct {
            fn lessThan(context: void, lhs: RefEntry, rhs: RefEntry) bool {
                _ = context;
                return std.mem.lessThan(u8, lhs.name, rhs.name);
            }
        }.lessThan);
        
        return ref_list;
    }
    
    /// Update a ref safely (with reflog)
    pub fn updateRef(self: RefsAdvanced, ref_name: []const u8, new_hash: []const u8, old_hash: ?[]const u8, message: []const u8, platform_impl: anytype) !void {
        // Validate hash format
        if (new_hash.len != 40 or !isValidHash(new_hash)) {
            return error.InvalidHash;
        }
        
        // Check if ref exists and get current value
        const current_hash = refs_mod.resolveRef(self.git_dir, ref_name, platform_impl, self.allocator) catch null;
        defer if (current_hash) |ch| self.allocator.free(ch);
        
        // Verify old hash if provided
        if (old_hash) |expected| {
            if (current_hash) |current| {
                if (!std.mem.eql(u8, current, expected)) {
                    return error.RefUpdateConflict;
                }
            } else {
                // Expected specific hash but ref doesn't exist
                return error.RefUpdateConflict;
            }
        }
        
        // Write new ref value
        const ref_path = try self.getRefPath(ref_name);
        defer self.allocator.free(ref_path);
        
        // Ensure parent directory exists
        if (std.fs.path.dirname(ref_path)) |parent_dir| {
            std.fs.cwd().makePath(parent_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        
        // Write new hash
        try platform_impl.fs.writeFile(ref_path, new_hash);
        
        // Update reflog
        try self.addReflogEntry(ref_name, current_hash orelse "0000000000000000000000000000000000000000", new_hash, message, platform_impl);
    }
    
    /// Create a symbolic ref
    pub fn createSymbolicRef(self: RefsAdvanced, ref_name: []const u8, target: []const u8, platform_impl: anytype) !void {
        const ref_path = try self.getRefPath(ref_name);
        defer self.allocator.free(ref_path);
        
        const content = try std.fmt.allocPrint(self.allocator, "ref: {s}", .{target});
        defer self.allocator.free(content);
        
        try platform_impl.fs.writeFile(ref_path, content);
    }
    
    /// Delete a ref
    pub fn deleteRef(self: RefsAdvanced, ref_name: []const u8, old_hash: ?[]const u8, platform_impl: anytype) !void {
        // Get current value for verification
        const current_hash = refs_mod.resolveRef(self.git_dir, ref_name, platform_impl, self.allocator) catch {
            return error.RefNotFound;
        };
        defer self.allocator.free(current_hash);
        
        // Verify old hash if provided
        if (old_hash) |expected| {
            if (!std.mem.eql(u8, current_hash, expected)) {
                return error.RefDeleteConflict;
            }
        }
        
        // Delete the ref file
        const ref_path = try self.getRefPath(ref_name);
        defer self.allocator.free(ref_path);
        
        std.fs.cwd().deleteFile(ref_path) catch |err| switch (err) {
            error.FileNotFound => {}, // Already deleted, that's OK
            else => return err,
        };
        
        // Add deletion to reflog
        try self.addReflogEntry(ref_name, current_hash, "0000000000000000000000000000000000000000", "deleted", platform_impl);
    }
    
    /// Get the path for a ref file
    fn getRefPath(self: RefsAdvanced, ref_name: []const u8) ![]u8 {
        if (std.mem.eql(u8, ref_name, "HEAD")) {
            return try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{self.git_dir});
        } else if (std.mem.startsWith(u8, ref_name, "refs/")) {
            return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, ref_name });
        } else {
            return try std.fmt.allocPrint(self.allocator, "{s}/refs/heads/{s}", .{ self.git_dir, ref_name });
        }
    }
    
    /// Resolve a ref one level
    fn resolveRefOnce(self: RefsAdvanced, ref_name: []const u8, platform_impl: anytype) !RefResolution {
        const ref_path = try self.getRefPath(ref_name);
        defer self.allocator.free(ref_path);
        
        const content = platform_impl.fs.readFile(self.allocator, ref_path) catch |err| switch (err) {
            error.FileNotFound => {
                // Try packed-refs
                return self.resolveFromPackedRefs(ref_name, platform_impl);
            },
            else => return err,
        };
        defer self.allocator.free(content);
        
        const trimmed = std.mem.trim(u8, content, " \t\n\r");
        
        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            return RefResolution{
                .target = try self.allocator.dupe(u8, trimmed[5..]),
                .is_symbolic = true,
            };
        } else if (trimmed.len == 40 and isValidHash(trimmed)) {
            return RefResolution{
                .target = try self.allocator.dupe(u8, trimmed),
                .is_symbolic = false,
            };
        } else {
            return error.InvalidRef;
        }
    }
    
    /// Resolve from packed-refs file
    fn resolveFromPackedRefs(self: RefsAdvanced, ref_name: []const u8, platform_impl: anytype) !RefResolution {
        const packed_refs_path = try std.fmt.allocPrint(self.allocator, "{s}/packed-refs", .{self.git_dir});
        defer self.allocator.free(packed_refs_path);
        
        const content = platform_impl.fs.readFile(self.allocator, packed_refs_path) catch {
            return error.RefNotFound;
        };
        defer self.allocator.free(content);
        
        var lines = std.mem.split(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '^') continue;
            
            // Format: <hash> <ref>
            const space_pos = std.mem.indexOf(u8, trimmed, " ") orelse continue;
            const hash = trimmed[0..space_pos];
            const ref = trimmed[space_pos + 1..];
            
            if (std.mem.eql(u8, ref, ref_name)) {
                return RefResolution{
                    .target = try self.allocator.dupe(u8, hash),
                    .is_symbolic = false,
                };
            }
        }
        
        return error.RefNotFound;
    }
    
    /// Collect loose refs from filesystem
    fn collectLooseRefs(self: RefsAdvanced, ref_list: *RefList, platform_impl: anytype) !void {
        const refs_path = try std.fmt.allocPrint(self.allocator, "{s}/refs", .{self.git_dir});
        defer self.allocator.free(refs_path);
        
        try self.walkRefsDir(refs_path, "refs", ref_list, platform_impl);
        
        // Also check HEAD
        if (refs_mod.resolveRef(self.git_dir, "HEAD", platform_impl, self.allocator)) |hash| {
            defer self.allocator.free(hash);
            try ref_list.addRef("HEAD", hash, .head);
        } else |_| {}
    }
    
    /// Recursively walk refs directory
    fn walkRefsDir(self: RefsAdvanced, dir_path: []const u8, prefix: []const u8, ref_list: *RefList, platform_impl: anytype) !void {
        _ = platform_impl;
        
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();
        
        var iterator = dir.iterate();
        while (iterator.next() catch null) |entry| {
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer self.allocator.free(full_path);
            
            const ref_name = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
            defer self.allocator.free(ref_name);
            
            if (entry.kind == .directory) {
                try self.walkRefsDir(full_path, ref_name, ref_list, platform_impl);
            } else if (entry.kind == .file) {
                // Try to read the ref
                const content = std.fs.cwd().readFileAlloc(self.allocator, full_path, 1024) catch continue;
                defer self.allocator.free(content);
                
                const trimmed = std.mem.trim(u8, content, " \t\n\r");
                if (trimmed.len == 40 and isValidHash(trimmed)) {
                    const ref_type = determineRefType(ref_name);
                    try ref_list.addRef(ref_name, trimmed, ref_type);
                }
            }
        }
    }
    
    /// Collect refs from packed-refs file
    fn collectPackedRefs(self: RefsAdvanced, ref_list: *RefList, platform_impl: anytype) !void {
        const packed_refs_path = try std.fmt.allocPrint(self.allocator, "{s}/packed-refs", .{self.git_dir});
        defer self.allocator.free(packed_refs_path);
        
        const content = platform_impl.fs.readFile(self.allocator, packed_refs_path) catch return; // File doesn't exist
        defer self.allocator.free(content);
        
        var lines = std.mem.split(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '^') continue;
            
            const space_pos = std.mem.indexOf(u8, trimmed, " ") orelse continue;
            const hash = trimmed[0..space_pos];
            const ref_name = trimmed[space_pos + 1..];
            
            if (hash.len == 40 and isValidHash(hash)) {
                const ref_type = determineRefType(ref_name);
                try ref_list.addRef(ref_name, hash, ref_type);
            }
        }
    }
    
    /// Add entry to reflog
    fn addReflogEntry(self: RefsAdvanced, ref_name: []const u8, old_hash: []const u8, new_hash: []const u8, message: []const u8, platform_impl: anytype) !void {
        const reflog_dir = try std.fmt.allocPrint(self.allocator, "{s}/logs", .{self.git_dir});
        defer self.allocator.free(reflog_dir);
        
        // Ensure logs directory exists
        std.fs.cwd().makePath(reflog_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        
        const reflog_path = if (std.mem.eql(u8, ref_name, "HEAD"))
            try std.fmt.allocPrint(self.allocator, "{s}/logs/HEAD", .{self.git_dir})
        else if (std.mem.startsWith(u8, ref_name, "refs/"))
            try std.fmt.allocPrint(self.allocator, "{s}/logs/{s}", .{ self.git_dir, ref_name })
        else
            try std.fmt.allocPrint(self.allocator, "{s}/logs/refs/heads/{s}", .{ self.git_dir, ref_name });
        defer self.allocator.free(reflog_path);
        
        // Ensure parent directory exists
        if (std.fs.path.dirname(reflog_path)) |parent_dir| {
            std.fs.cwd().makePath(parent_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        
        // Format: <old_hash> <new_hash> <name> <email> <timestamp> <timezone> \t<message>
        const timestamp = std.time.timestamp();
        const entry = try std.fmt.allocPrint(self.allocator, "{s} {s} Unknown <unknown@localhost> {} +0000\t{s}\n", .{ old_hash, new_hash, timestamp, message });
        defer self.allocator.free(entry);
        
        // Append to reflog file
        var file = std.fs.cwd().openFile(reflog_path, .{ .mode = .write_only }) catch {
            // File doesn't exist, create it
            var new_file = try std.fs.cwd().createFile(reflog_path, .{});
            try new_file.writeAll(entry);
            new_file.close();
            return;
        };
        defer file.close();
        
        try file.seekToEnd();
        try file.writeAll(entry);
    }
};

/// Reference resolution result
const RefResolution = struct {
    target: []u8,
    is_symbolic: bool,
};

/// Detailed information about a ref
pub const RefInfo = struct {
    allocator: std.mem.Allocator,
    resolution_chain: std.ArrayList([]u8),
    final_hash: ?[]u8 = null,
    is_symbolic: bool = false,
    ref_type: RefType = .unknown,
    error_msg: ?[]u8 = null,
    
    pub fn init(allocator: std.mem.Allocator) RefInfo {
        return RefInfo{
            .allocator = allocator,
            .resolution_chain = std.ArrayList([]u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *RefInfo) void {
        for (self.resolution_chain.items) |item| {
            self.allocator.free(item);
        }
        self.resolution_chain.deinit();
        
        if (self.final_hash) |hash| {
            self.allocator.free(hash);
        }
        
        if (self.error_msg) |msg| {
            self.allocator.free(msg);
        }
    }
    
    pub fn print(self: RefInfo) void {
        std.debug.print("Reference Information:\n", .{});
        std.debug.print("  Type: {s}\n", .{@tagName(self.ref_type)});
        std.debug.print("  Symbolic: {}\n", .{self.is_symbolic});
        
        if (self.resolution_chain.items.len > 0) {
            std.debug.print("  Resolution chain:\n", .{});
            for (self.resolution_chain.items) |ref| {
                std.debug.print("    -> {s}\n", .{ref});
            }
        }
        
        if (self.final_hash) |hash| {
            std.debug.print("  Final hash: {s}\n", .{hash});
        }
        
        if (self.error_msg) |msg| {
            std.debug.print("  Error: {s}\n", .{msg});
        }
    }
};

/// Collection of refs
pub const RefList = struct {
    allocator: std.mem.Allocator,
    refs: std.ArrayList(RefEntry),
    
    pub fn init(allocator: std.mem.Allocator) RefList {
        return RefList{
            .allocator = allocator,
            .refs = std.ArrayList(RefEntry).init(allocator),
        };
    }
    
    pub fn deinit(self: *RefList) void {
        for (self.refs.items) |ref| {
            ref.deinit(self.allocator);
        }
        self.refs.deinit();
    }
    
    pub fn addRef(self: *RefList, name: []const u8, hash: []const u8, ref_type: RefType) !void {
        try self.refs.append(RefEntry{
            .name = try self.allocator.dupe(u8, name),
            .hash = try self.allocator.dupe(u8, hash),
            .ref_type = ref_type,
        });
    }
    
    /// Filter refs by type
    pub fn filterByType(self: RefList, ref_type: RefType, allocator: std.mem.Allocator) ![]RefEntry {
        var filtered = std.ArrayList(RefEntry).init(allocator);
        defer filtered.deinit();
        
        for (self.refs.items) |ref| {
            if (ref.ref_type == ref_type) {
                try filtered.append(RefEntry{
                    .name = try allocator.dupe(u8, ref.name),
                    .hash = try allocator.dupe(u8, ref.hash),
                    .ref_type = ref.ref_type,
                });
            }
        }
        
        return try filtered.toOwnedSlice();
    }
    
    pub fn print(self: RefList) void {
        std.debug.print("Refs ({} total):\n", .{self.refs.items.len});
        for (self.refs.items) |ref| {
            std.debug.print("  {s:<30} {s} ({s})\n", .{ ref.name, ref.hash, @tagName(ref.ref_type) });
        }
    }
};

pub const RefEntry = struct {
    name: []u8,
    hash: []u8,
    ref_type: RefType,
    
    pub fn deinit(self: RefEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.hash);
    }
};

pub const RefType = enum {
    head,
    branch,
    tag,
    remote,
    unknown,
};

fn determineRefType(ref_name: []const u8) RefType {
    if (std.mem.eql(u8, ref_name, "HEAD")) {
        return .head;
    } else if (std.mem.startsWith(u8, ref_name, "refs/heads/")) {
        return .branch;
    } else if (std.mem.startsWith(u8, ref_name, "refs/tags/")) {
        return .tag;
    } else if (std.mem.startsWith(u8, ref_name, "refs/remotes/")) {
        return .remote;
    } else {
        return .unknown;
    }
}

fn isValidHash(hash: []const u8) bool {
    if (hash.len != 40) return false;
    
    for (hash) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    
    return true;
}