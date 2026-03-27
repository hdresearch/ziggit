const std = @import("std");
const objects = @import("objects.zig");
const refs = @import("refs.zig");
const index_mod = @import("index.zig");

/// Basic HTTP client for git operations
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return HttpClient{
            .allocator = allocator,
        };
    }
    
    /// Fetch data from a URL using HTTP GET (simplified implementation)
    pub fn get(self: HttpClient, url: []const u8) ![]u8 {
        // For now, return error to indicate network operations are not yet fully implemented
        // A full implementation would use std.http.Client with proper configuration
        _ = self;
        _ = url;
        
        // This would be the real implementation:
        // var server_header_buffer: [16384]u8 = undefined;
        // var client = std.http.Client{ .allocator = self.allocator };
        // defer client.deinit();
        // const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        // var request = try client.open(.GET, uri, .{ .server_header_buffer = &server_header_buffer });
        // defer request.deinit();
        // try request.send(.{});
        // try request.finish();
        // try request.wait();
        // if (request.response.status != .ok) return error.HttpError;
        // return try request.reader().readAllAlloc(self.allocator, 64 * 1024 * 1024);
        
        return error.HttpError;
    }
};

/// Dumb HTTP protocol implementation for git
pub const DumbHttpProtocol = struct {
    http_client: HttpClient,
    base_url: []const u8,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, url: []const u8) !DumbHttpProtocol {
        // Normalize URL - ensure it ends with .git if it's a repo URL
        const normalized_url = if (std.mem.endsWith(u8, url, ".git"))
            try allocator.dupe(u8, url)
        else
            try std.fmt.allocPrint(allocator, "{s}.git", .{url});
        
        return DumbHttpProtocol{
            .http_client = HttpClient.init(allocator),
            .base_url = normalized_url,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: DumbHttpProtocol) void {
        self.allocator.free(self.base_url);
    }
    
    /// Get the list of references from info/refs
    pub fn getRefs(self: DumbHttpProtocol) !std.ArrayList(RefInfo) {
        const refs_url = try std.fmt.allocPrint(self.allocator, "{s}/info/refs", .{self.base_url});
        defer self.allocator.free(refs_url);
        
        const refs_content = self.http_client.get(refs_url) catch |err| switch (err) {
            error.HttpError => return error.RepositoryNotFound,
            else => return err,
        };
        defer self.allocator.free(refs_content);
        
        var ref_list = std.ArrayList(RefInfo).init(self.allocator);
        
        var lines = std.mem.splitSequence(u8, refs_content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            
            // Parse line: <hash><tab><refname>
            if (std.mem.indexOf(u8, trimmed, "\t")) |tab_pos| {
                const hash = trimmed[0..tab_pos];
                const refname = trimmed[tab_pos + 1..];
                
                if (hash.len == 40) { // Valid SHA-1 hash
                    try ref_list.append(RefInfo{
                        .hash = try self.allocator.dupe(u8, hash),
                        .name = try self.allocator.dupe(u8, refname),
                    });
                }
            }
        }
        
        return ref_list;
    }
    
    /// Get a specific object by hash
    pub fn getObject(self: DumbHttpProtocol, hash: []const u8) ![]u8 {
        const obj_url = try std.fmt.allocPrint(
            self.allocator, 
            "{s}/objects/{s}/{s}", 
            .{ self.base_url, hash[0..2], hash[2..] }
        );
        defer self.allocator.free(obj_url);
        
        return self.http_client.get(obj_url);
    }
    
    /// Download pack file from a pack URL
    pub fn getPackFile(self: DumbHttpProtocol, pack_hash: []const u8) ![]u8 {
        const pack_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/objects/pack/pack-{s}.pack",
            .{ self.base_url, pack_hash }
        );
        defer self.allocator.free(pack_url);
        
        return self.http_client.get(pack_url);
    }
    
    /// Download pack index from a pack URL  
    pub fn getPackIndex(self: DumbHttpProtocol, pack_hash: []const u8) ![]u8 {
        const idx_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/objects/pack/pack-{s}.idx",
            .{ self.base_url, pack_hash }
        );
        defer self.allocator.free(idx_url);
        
        return self.http_client.get(idx_url);
    }
    
    /// Get info about available pack files
    pub fn getPacksInfo(self: DumbHttpProtocol) ![][]const u8 {
        const packs_url = try std.fmt.allocPrint(self.allocator, "{s}/objects/info/packs", .{self.base_url});
        defer self.allocator.free(packs_url);
        
        const packs_content = self.http_client.get(packs_url) catch |err| switch (err) {
            error.HttpError => {
                // If info/packs doesn't exist, return empty list
                return try self.allocator.alloc([]const u8, 0);
            },
            else => return err,
        };
        defer self.allocator.free(packs_content);
        
        var pack_list = std.ArrayList([]const u8).init(self.allocator);
        
        var lines = std.mem.splitSequence(u8, packs_content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            
            // Format: P pack-<hash>.pack
            if (std.mem.startsWith(u8, trimmed, "P pack-") and std.mem.endsWith(u8, trimmed, ".pack")) {
                const pack_name = trimmed[2..]; // Skip "P "
                const hash_part = pack_name[5..pack_name.len-5]; // Extract hash from pack-<hash>.pack
                try pack_list.append(try self.allocator.dupe(u8, hash_part));
            }
        }
        
        return pack_list.toOwnedSlice();
    }
};

/// Information about a git reference
pub const RefInfo = struct {
    hash: []const u8,
    name: []const u8,
    
    pub fn deinit(self: RefInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.hash);
        allocator.free(self.name);
    }
};

/// Clone a repository using the dumb HTTP protocol
pub fn cloneRepository(allocator: std.mem.Allocator, url: []const u8, target_dir: []const u8, platform_impl: anytype) !void {
    // Initialize the protocol
    var protocol = try DumbHttpProtocol.init(allocator, url);
    defer protocol.deinit();
    
    // Create target directory
    try std.fs.cwd().makeDir(target_dir);
    
    // Initialize git repository in target directory
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{target_dir});
    defer allocator.free(git_dir);
    
    try createGitDirectory(git_dir, platform_impl);
    
    // Get references from remote
    var remote_refs = try protocol.getRefs();
    defer {
        for (remote_refs.items) |ref| {
            ref.deinit(allocator);
        }
        remote_refs.deinit();
    }
    
    // Find HEAD or master/main reference
    var head_hash: ?[]const u8 = null;
    var head_ref: ?[]const u8 = null;
    
    for (remote_refs.items) |ref| {
        if (std.mem.eql(u8, ref.name, "refs/heads/main") or 
            std.mem.eql(u8, ref.name, "refs/heads/master")) {
            head_hash = ref.hash;
            head_ref = ref.name;
            break;
        }
    }
    
    // If no main/master, use the first refs/heads branch
    if (head_hash == null) {
        for (remote_refs.items) |ref| {
            if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
                head_hash = ref.hash;
                head_ref = ref.name;
                break;
            }
        }
    }
    
    if (head_hash == null) {
        return error.NoValidBranch;
    }
    
    // Download objects starting from HEAD
    try downloadObjects(protocol, head_hash.?, git_dir, platform_impl, allocator);
    
    // Set up HEAD to point to the default branch
    const branch_name = if (head_ref) |ref| 
        if (std.mem.startsWith(u8, ref, "refs/heads/"))
            ref[11..] // Remove "refs/heads/" prefix
        else "master"
    else "master";
    
    try refs.updateHEAD(git_dir, branch_name, platform_impl, allocator);
    try refs.updateRef(git_dir, branch_name, head_hash.?, platform_impl, allocator);
    
    // Checkout the working tree
    try checkoutWorkingTree(git_dir, head_hash.?, target_dir, platform_impl, allocator);
}

/// Download objects recursively starting from a commit
fn downloadObjects(protocol: DumbHttpProtocol, start_hash: []const u8, git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !void {
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var iterator = visited.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        visited.deinit();
    }
    
    var to_download = std.ArrayList([]const u8).init(allocator);
    defer {
        for (to_download.items) |hash| {
            allocator.free(hash);
        }
        to_download.deinit();
    }
    
    try to_download.append(try allocator.dupe(u8, start_hash));
    
    while (to_download.items.len > 0) {
        const hash = to_download.popOrNull() orelse break;
        defer allocator.free(hash);
        
        if (visited.contains(hash)) continue;
        try visited.put(try allocator.dupe(u8, hash), {});
        
        // Check if object already exists locally
        if (objectExists(git_dir, hash, platform_impl, allocator)) continue;
        
        // Download the object
        const obj_data = protocol.getObject(hash) catch |err| switch (err) {
            error.HttpError => {
                // Object might be in a pack file, skip for now
                continue;
            },
            else => return err,
        };
        defer allocator.free(obj_data);
        
        // Store object locally
        try storeObject(git_dir, hash, obj_data, platform_impl, allocator);
        
        // Parse object to find dependencies
        const obj = try objects.GitObject.load(hash, git_dir, platform_impl, allocator);
        defer obj.deinit(allocator);
        
        try addObjectDependencies(obj, &to_download, allocator);
    }
}

/// Check if an object exists in the local repository
fn objectExists(git_dir: []const u8, hash: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) bool {
    const obj_path = std.fmt.allocPrint(allocator, "{s}/objects/{s}/{s}", .{ git_dir, hash[0..2], hash[2..] }) catch return false;
    defer allocator.free(obj_path);
    
    return platform_impl.fs.exists(obj_path) catch false;
}

/// Store object data in the local repository
fn storeObject(git_dir: []const u8, hash: []const u8, obj_data: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !void {
    const obj_dir = try std.fmt.allocPrint(allocator, "{s}/objects/{s}", .{ git_dir, hash[0..2] });
    defer allocator.free(obj_dir);
    
    platform_impl.fs.makeDir(obj_dir) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };
    
    const obj_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ obj_dir, hash[2..] });
    defer allocator.free(obj_path);
    
    try platform_impl.fs.writeFile(obj_path, obj_data);
}

/// Add object dependencies to the download queue  
fn addObjectDependencies(obj: objects.GitObject, to_download: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    switch (obj.type) {
        .commit => {
            var lines = std.mem.splitSequence(u8, obj.data, "\n");
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "tree ")) {
                    const tree_hash = line[5..];
                    if (tree_hash.len == 40) {
                        try to_download.append(try allocator.dupe(u8, tree_hash));
                    }
                } else if (std.mem.startsWith(u8, line, "parent ")) {
                    const parent_hash = line[7..];
                    if (parent_hash.len == 40) {
                        try to_download.append(try allocator.dupe(u8, parent_hash));
                    }
                } else if (line.len == 0) {
                    break; // End of headers
                }
            }
        },
        .tree => {
            var pos: usize = 0;
            while (pos < obj.data.len) {
                // Find null terminator after mode and name
                const null_pos = std.mem.indexOfScalar(u8, obj.data[pos..], 0) orelse break;
                pos += null_pos + 1;
                
                // Next 20 bytes are the hash
                if (pos + 20 <= obj.data.len) {
                    const hash_bytes = obj.data[pos..pos + 20];
                    const hash_str = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(hash_bytes)});
                    try to_download.append(hash_str);
                    pos += 20;
                } else {
                    break;
                }
            }
        },
        .blob, .tag => {
            // No dependencies
        },
    }
}

/// Create basic git directory structure
fn createGitDirectory(git_dir: []const u8, platform_impl: anytype) !void {
    try platform_impl.fs.makeDir(git_dir);
    
    const subdirs = [_][]const u8{
        "objects", "refs", "refs/heads", "refs/tags", "hooks", "info", "objects/pack"
    };
    
    for (subdirs) |subdir| {
        const full_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ git_dir, subdir });
        defer std.heap.page_allocator.free(full_path);
        try platform_impl.fs.makeDir(full_path);
    }
    
    // Create basic files
    const head_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/HEAD", .{git_dir});
    defer std.heap.page_allocator.free(head_path);
    try platform_impl.fs.writeFile(head_path, "ref: refs/heads/master\n");
    
    const config_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/config", .{git_dir});
    defer std.heap.page_allocator.free(config_path);
    try platform_impl.fs.writeFile(config_path, 
        \\[core]
        \\    repositoryformatversion = 0
        \\    filemode = true
        \\    bare = false
        \\    logallrefupdates = true
        \\
    );
}

/// Checkout working tree from a commit
fn checkoutWorkingTree(git_dir: []const u8, commit_hash: []const u8, target_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !void {
    // Load commit object
    const commit_obj = try objects.GitObject.load(commit_hash, git_dir, platform_impl, allocator);
    defer commit_obj.deinit(allocator);
    
    if (commit_obj.type != .commit) return error.InvalidCommit;
    
    // Find tree hash in commit
    var tree_hash: ?[]const u8 = null;
    var lines = std.mem.splitSequence(u8, commit_obj.data, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ")) {
            tree_hash = line[5..];
            break;
        }
    }
    
    if (tree_hash == null or tree_hash.?.len != 40) return error.InvalidCommit;
    
    // Checkout tree recursively
    try checkoutTree(git_dir, tree_hash.?, target_dir, "", platform_impl, allocator);
}

/// Recursively checkout a tree object
fn checkoutTree(git_dir: []const u8, tree_hash: []const u8, base_dir: []const u8, path_prefix: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !void {
    const tree_obj = try objects.GitObject.load(tree_hash, git_dir, platform_impl, allocator);
    defer tree_obj.deinit(allocator);
    
    if (tree_obj.type != .tree) return error.InvalidTree;
    
    var pos: usize = 0;
    while (pos < tree_obj.data.len) {
        // Parse mode and name
        const null_pos = std.mem.indexOfScalar(u8, tree_obj.data[pos..], 0) orelse break;
        const mode_and_name = tree_obj.data[pos..pos + null_pos];
        pos += null_pos + 1;
        
        // Parse mode and filename
        const space_pos = std.mem.indexOfScalar(u8, mode_and_name, ' ') orelse continue;
        const mode = mode_and_name[0..space_pos];
        const filename = mode_and_name[space_pos + 1..];
        
        // Get hash (20 bytes)
        if (pos + 20 > tree_obj.data.len) break;
        const hash_bytes = tree_obj.data[pos..pos + 20];
        const hash_str = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(hash_bytes)});
        defer allocator.free(hash_str);
        pos += 20;
        
        // Construct full path
        const full_path = if (path_prefix.len == 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, filename })
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ base_dir, path_prefix, filename });
        defer allocator.free(full_path);
        
        // Handle based on mode
        if (std.mem.eql(u8, mode, "40000")) {
            // Directory (tree)
            try platform_impl.fs.makeDir(full_path);
            const new_prefix = if (path_prefix.len == 0)
                try allocator.dupe(u8, filename)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path_prefix, filename });
            defer allocator.free(new_prefix);
            try checkoutTree(git_dir, hash_str, base_dir, new_prefix, platform_impl, allocator);
        } else {
            // Regular file (blob)
            const blob_obj = try objects.GitObject.load(hash_str, git_dir, platform_impl, allocator);
            defer blob_obj.deinit(allocator);
            
            if (blob_obj.type == .blob) {
                // Create parent directories if needed
                if (std.fs.path.dirname(full_path)) |parent_dir| {
                    platform_impl.fs.makeDir(parent_dir) catch |err| switch (err) {
                        error.AlreadyExists => {},
                        else => return err,
                    };
                }
                try platform_impl.fs.writeFile(full_path, blob_obj.data);
            }
        }
    }
}

/// Fetch updates from a remote repository
pub fn fetchRepository(allocator: std.mem.Allocator, url: []const u8, git_dir: []const u8, platform_impl: anytype) !void {
    var protocol = try DumbHttpProtocol.init(allocator, url);
    defer protocol.deinit();
    
    // Get references from remote
    var remote_refs = try protocol.getRefs();
    defer {
        for (remote_refs.items) |ref| {
            ref.deinit(allocator);
        }
        remote_refs.deinit();
    }
    
    // Download any new objects
    for (remote_refs.items) |ref| {
        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            // Download objects for this branch if we don't have them
            if (!objectExists(git_dir, ref.hash, platform_impl, allocator)) {
                try downloadObjects(protocol, ref.hash, git_dir, platform_impl, allocator);
            }
            
            // Update remote tracking branch
            const remote_ref_name = try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{ref.name[11..]});
            defer allocator.free(remote_ref_name);
            try refs.updateRef(git_dir, remote_ref_name, ref.hash, platform_impl, allocator);
        }
    }
}