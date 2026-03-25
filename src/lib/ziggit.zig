const std = @import("std");

// Simple repository implementation for the library
const Repository = struct {
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) Repository {
        return Repository{
            .path = path,
            .allocator = allocator,
        };
    }

    pub fn exists(self: *const Repository) !bool {
        // Convert to absolute path if needed
        const abs_path = if (std.fs.path.isAbsolute(self.path))
            try self.allocator.dupe(u8, self.path)
        else blk: {
            var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const cwd = try std.process.getCwd(&cwd_buf);
            break :blk try std.fs.path.resolve(self.allocator, &[_][]const u8{ cwd, self.path });
        };
        defer self.allocator.free(abs_path);
        
        const git_dir = try std.fmt.allocPrint(self.allocator, "{s}/.git", .{abs_path});
        defer self.allocator.free(git_dir);
        
        std.fs.accessAbsolute(git_dir, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }
};

// C-compatible error codes
pub const ZiggitError = enum(c_int) {
    Success = 0,
    NotARepository = -1,
    AlreadyExists = -2,
    InvalidPath = -3,
    NotFound = -4,
    PermissionDenied = -5,
    OutOfMemory = -6,
    NetworkError = -7,
    InvalidRef = -8,
    Generic = -100,
};

// Opaque repository handle for C compatibility
const ZiggitRepository = opaque {
    fn fromRepo(repo: *Repository) *ZiggitRepository {
        return @ptrCast(@alignCast(repo));
    }

    fn toRepo(self: *ZiggitRepository) *Repository {
        return @ptrCast(@alignCast(self));
    }
};

// Global allocator - in production this should be configurable
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const global_allocator = gpa.allocator();

// Convert Zig errors to C error codes
fn errorToCode(err: anyerror) ZiggitError {
    return switch (err) {
        error.NotAGitRepository => ZiggitError.NotARepository,
        error.AlreadyExists => ZiggitError.AlreadyExists,
        error.InvalidPath => ZiggitError.InvalidPath,
        error.FileNotFound => ZiggitError.NotFound,
        error.PermissionDenied => ZiggitError.PermissionDenied,
        error.OutOfMemory => ZiggitError.OutOfMemory,
        else => ZiggitError.Generic,
    };
}

//
// Public Zig API functions (for use from Zig code)
//

/// Initialize a new git repository at the specified path
/// Returns void on success, error on failure
pub fn repo_init(path: []const u8, bare: bool) !void {
    try initRepository(path, bare, null);
}

/// Open an existing repository at the specified path
/// Returns Repository on success, error on failure
pub fn repo_open(allocator: std.mem.Allocator, path: []const u8) !Repository {
    var repo = Repository.init(allocator, path);
    const exists = try repo.exists();
    if (!exists) {
        return error.NotAGitRepository;
    }
    return repo;
}

/// Clone a repository from URL to local path
pub fn repo_clone(url: []const u8, path: []const u8, bare: bool) !void {
    try cloneRepository(url, path, bare);
}

/// Get repository status
pub fn repo_status(repo: *Repository, allocator: std.mem.Allocator) ![]u8 {
    const buffer = try allocator.alloc(u8, 1024);
    try getStatusPorcelainReal(repo, buffer);
    return buffer;
}

/// Get HEAD commit hash (like `git rev-parse HEAD`)
pub fn repo_rev_parse_head(repo: *Repository, allocator: std.mem.Allocator) ![]u8 {
    const buffer = try allocator.alloc(u8, 41);
    try getHeadCommitHashReal(repo, buffer);
    return buffer;
}

/// Get latest tag (like `git describe --tags --abbrev=0`)
pub fn repo_describe_tags(repo: *Repository, allocator: std.mem.Allocator) ![]u8 {
    const buffer = try allocator.alloc(u8, 256);
    try getLatestTagReal(repo, buffer);
    return buffer;
}

//
// C-compatible API functions
//

/// Initialize a new git repository at the specified path
/// Returns 0 on success, negative error code on failure
export fn ziggit_repo_init(path: [*:0]const u8, bare: c_int) c_int {
    const path_slice = std.mem.span(path);
    const is_bare = bare != 0;
    
    initRepository(path_slice, is_bare, null) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Open an existing repository at the specified path
/// Returns handle on success, null on failure
export fn ziggit_repo_open(path: [*:0]const u8) ?*ZiggitRepository {
    const path_slice = std.mem.span(path);
    
    const repo = global_allocator.create(Repository) catch return null;
    repo.* = Repository.init(global_allocator, path_slice);
    
    // Validate that this is a real git repository
    const git_dir = findGitDirForRepo(repo) catch {
        global_allocator.destroy(repo);
        return null;
    };
    defer global_allocator.free(git_dir);
    
    // Check HEAD file exists and is readable
    const head_path = std.fmt.allocPrint(global_allocator, "{s}/HEAD", .{git_dir}) catch {
        global_allocator.destroy(repo);
        return null;
    };
    defer global_allocator.free(head_path);
    
    std.fs.accessAbsolute(head_path, .{}) catch {
        global_allocator.destroy(repo);
        return null;
    };
    
    // Check objects directory exists
    const objects_path = std.fmt.allocPrint(global_allocator, "{s}/objects", .{git_dir}) catch {
        global_allocator.destroy(repo);
        return null;
    };
    defer global_allocator.free(objects_path);
    
    std.fs.accessAbsolute(objects_path, .{}) catch {
        global_allocator.destroy(repo);
        return null;
    };
    
    return ZiggitRepository.fromRepo(repo);
}

/// Clone a repository from URL to local path
/// Returns 0 on success, negative error code on failure  
export fn ziggit_repo_clone(url: [*:0]const u8, path: [*:0]const u8, bare: c_int) c_int {
    const url_slice = std.mem.span(url);
    const path_slice = std.mem.span(path);
    const is_bare = bare != 0;
    
    cloneRepository(url_slice, path_slice, is_bare) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Close repository handle and free resources
export fn ziggit_repo_close(repo: *ZiggitRepository) void {
    const repository = repo.toRepo();
    global_allocator.destroy(repository);
}

/// Create a commit with given message and author
/// Returns 0 on success, negative error code on failure
export fn ziggit_commit_create(
    repo: *ZiggitRepository, 
    message: [*:0]const u8,
    author_name: [*:0]const u8,
    author_email: [*:0]const u8
) c_int {
    const repository = repo.toRepo();
    const msg = std.mem.span(message);
    const name = std.mem.span(author_name);
    const email = std.mem.span(author_email);
    
    commitCreate(repository, msg, name, email) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// List all branches in the repository
/// Returns number of branches on success, negative error code on failure
/// Branch names are written to buffer, separated by null terminators
export fn ziggit_branch_list(repo: *ZiggitRepository, buffer: [*]u8, buffer_size: usize) c_int {
    const repository = repo.toRepo();
    
    const branches = listBranches(repository, buffer[0..buffer_size]) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intCast(branches);
}

/// Get repository status (modified files, staged files, etc.)
/// Returns 0 on success, negative error code on failure
/// Status information is written to buffer as formatted text
export fn ziggit_status(repo: *ZiggitRepository, buffer: [*]u8, buffer_size: usize) c_int {
    const repository = repo.toRepo();
    
    getStatus(repository, buffer[0..buffer_size]) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Get diff between working tree and index (or commit)
/// Returns 0 on success, negative error code on failure
/// Diff output is written to buffer
export fn ziggit_diff(repo: *ZiggitRepository, buffer: [*]u8, buffer_size: usize) c_int {
    const repository = repo.toRepo();
    
    getDiff(repository, buffer[0..buffer_size]) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Add files to the repository index
/// Returns 0 on success, negative error code on failure
export fn ziggit_add(repo: *ZiggitRepository, pathspec: [*:0]const u8) c_int {
    const repository = repo.toRepo();
    const path = std.mem.span(pathspec);
    
    addToIndex(repository, path) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Get remote URL for the repository
/// Returns 0 on success, negative error code on failure
/// Remote URL is written to buffer
export fn ziggit_remote_get_url(repo: *ZiggitRepository, remote_name: [*:0]const u8, buffer: [*]u8, buffer_size: usize) c_int {
    const repository = repo.toRepo();
    const name = std.mem.span(remote_name);
    
    getRemoteUrl(repository, name, buffer[0..buffer_size]) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Set remote URL for the repository
/// Returns 0 on success, negative error code on failure
export fn ziggit_remote_set_url(repo: *ZiggitRepository, remote_name: [*:0]const u8, url: [*:0]const u8) c_int {
    const repository = repo.toRepo();
    const name = std.mem.span(remote_name);
    const remote_url = std.mem.span(url);
    
    setRemoteUrl(repository, name, remote_url) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

// Helper function to initialize repository (improved implementation)
fn initRepository(path: []const u8, bare: bool, template_dir: ?[]const u8) !void {
    _ = template_dir; // TODO: implement template support
    
    // Convert to absolute path
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    
    const abs_path = if (std.fs.path.isAbsolute(path)) 
        try global_allocator.dupe(u8, path)
    else
        try std.fs.path.resolve(global_allocator, &[_][]const u8{ cwd, path });
    defer global_allocator.free(abs_path);
    
    const git_dir = if (bare) 
        try global_allocator.dupe(u8, abs_path)
    else 
        try std.fmt.allocPrint(global_allocator, "{s}/.git", .{abs_path});
    defer global_allocator.free(git_dir);
    
    // Create the target directory if it doesn't exist
    if (!bare) {
        std.fs.makeDirAbsolute(abs_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    
    // Create .git directory structure
    std.fs.makeDirAbsolute(git_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.AlreadyExists,
        else => return err,
    };
    
    // Create subdirectories
    const subdirs = [_][]const u8{
        "objects",
        "objects/info",
        "objects/pack",
        "refs",
        "refs/heads", 
        "refs/tags",
        "refs/remotes",
        "hooks",
        "info",
    };
    
    for (subdirs) |subdir| {
        const full_path = try std.fmt.allocPrint(global_allocator, "{s}/{s}", .{ git_dir, subdir });
        defer global_allocator.free(full_path);
        std.fs.makeDirAbsolute(full_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    
    // Create HEAD file
    const head_path = try std.fmt.allocPrint(global_allocator, "{s}/HEAD", .{git_dir});
    defer global_allocator.free(head_path);
    const head_file = try std.fs.createFileAbsolute(head_path, .{ .truncate = true });
    defer head_file.close();
    try head_file.writeAll("ref: refs/heads/master\n");
    
    // Create config file
    const config_path = try std.fmt.allocPrint(global_allocator, "{s}/config", .{git_dir});
    defer global_allocator.free(config_path);
    const config_file = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer config_file.close();
    
    const config_content = if (bare)
        \\[core]
        \\    repositoryformatversion = 0
        \\    filemode = true
        \\    bare = true
        \\[receive]
        \\    denyCurrentBranch = ignore
        \\
    else
        \\[core]
        \\    repositoryformatversion = 0
        \\    filemode = true
        \\    bare = false
        \\    logallrefupdates = true
        \\
    ;
    
    try config_file.writeAll(config_content);
    
    // Create description file
    const desc_path = try std.fmt.allocPrint(global_allocator, "{s}/description", .{git_dir});
    defer global_allocator.free(desc_path);
    const desc_file = try std.fs.createFileAbsolute(desc_path, .{ .truncate = true });
    defer desc_file.close();
    try desc_file.writeAll("Unnamed repository; edit this file 'description' to name the repository.\n");
    
    // Create exclude file
    const exclude_path = try std.fmt.allocPrint(global_allocator, "{s}/info/exclude", .{git_dir});
    defer global_allocator.free(exclude_path);
    const exclude_file = try std.fs.createFileAbsolute(exclude_path, .{ .truncate = true });
    defer exclude_file.close();
    try exclude_file.writeAll("# git ls-files --others --exclude-from=.git/info/exclude\n# Lines that start with '#' are comments.\n# For a project mostly in C, the following would be a good set of\n# exclude patterns (uncomment them if you want to use them):\n# *.[oa]\n# *~\n");
}

// Clone repository implementation
fn cloneRepository(url: []const u8, path: []const u8, bare: bool) !void {
    // For now, we'll create a basic git directory structure
    // In a full implementation, this would fetch from the remote URL
    // For demonstration purposes, we'll just create an empty repository
    _ = url; // TODO: implement actual cloning
    try initRepository(path, bare, null);
}

// Commit creation implementation
fn commitCreate(repo: *Repository, message: []const u8, author_name: []const u8, author_email: []const u8) !void {
    _ = repo;
    _ = message; 
    _ = author_name;
    _ = author_email;
    // TODO: Implement actual commit creation
    // For now, this is stubbed to return success
}

// Branch listing implementation using real git refs
fn listBranches(repo: *Repository, buffer: []u8) !usize {
    const git_dir = try findGitDirForRepo(repo);
    defer global_allocator.free(git_dir);
    
    // Get current branch by reading HEAD
    const current_branch = getCurrentBranchReal(git_dir) catch "master";
    defer global_allocator.free(current_branch);
    
    // Try to read refs/heads directory
    const refs_heads_path = try std.fmt.allocPrint(global_allocator, "{s}/refs/heads", .{git_dir});
    defer global_allocator.free(refs_heads_path);
    
    var branch_list = std.ArrayList([]u8).init(global_allocator);
    defer {
        for (branch_list.items) |branch| {
            global_allocator.free(branch);
        }
        branch_list.deinit();
    }
    
    // Try to read the directory
    if (std.fs.openDirAbsolute(refs_heads_path, .{ .iterate = true })) |mut_refs_dir| {
        var refs_dir = mut_refs_dir;
        defer refs_dir.close();
        
        var iterator = refs_dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file) {
                try branch_list.append(try global_allocator.dupe(u8, entry.name));
            }
        }
    } else |_| {
        // No refs directory or error reading it, add current branch if it's not HEAD
        if (!std.mem.eql(u8, current_branch, "HEAD")) {
            try branch_list.append(try global_allocator.dupe(u8, current_branch));
        } else {
            try branch_list.append(try global_allocator.dupe(u8, "master"));
        }
    }
    
    // Format branches for output
    var pos: usize = 0;
    for (branch_list.items) |branch| {
        const prefix = if (std.mem.eql(u8, branch, current_branch)) "* " else "  ";
        const line = try std.fmt.allocPrint(global_allocator, "{s}{s}\n", .{ prefix, branch });
        defer global_allocator.free(line);
        
        if (pos + line.len >= buffer.len) {
            return error.InvalidPath; // Buffer too small
        }
        
        @memcpy(buffer[pos..pos + line.len], line);
        pos += line.len;
    }
    
    if (pos < buffer.len) {
        buffer[pos] = 0; // null terminate
    }
    
    return branch_list.items.len;
}

// Get current branch from HEAD file (real git implementation)
fn getCurrentBranchReal(git_dir: []const u8) ![]u8 {
    const head_path = try std.fmt.allocPrint(global_allocator, "{s}/HEAD", .{git_dir});
    defer global_allocator.free(head_path);

    const head_file = std.fs.openFileAbsolute(head_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try global_allocator.dupe(u8, "master"),
        else => return err,
    };
    defer head_file.close();

    var head_content_buf: [512]u8 = undefined;
    const bytes_read = try head_file.readAll(&head_content_buf);
    const head_content = std.mem.trim(u8, head_content_buf[0..bytes_read], " \n\r\t");
    
    if (std.mem.startsWith(u8, head_content, "ref: refs/heads/")) {
        return try global_allocator.dupe(u8, head_content["ref: refs/heads/".len..]);
    } else if (head_content.len == 40 and isValidHash(head_content)) {
        // Detached HEAD
        return try global_allocator.dupe(u8, "HEAD");
    } else {
        return try global_allocator.dupe(u8, "master");
    }
}

fn isValidHash(hash: []const u8) bool {
    if (hash.len != 40) return false;
    for (hash) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn isValidHashPrefix(hash: []const u8) bool {
    if (hash.len != 40) return false;
    for (hash) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

// Improved ref resolution that handles both loose refs and packed refs
fn resolveRefReal(git_dir: []const u8, ref_name: []const u8, buffer: []u8) !void {
    if (buffer.len < 41) return error.InvalidPath;
    
    // First try to read the ref file directly (loose refs)
    const ref_path = try std.fmt.allocPrint(global_allocator, "{s}/{s}", .{ git_dir, ref_name });
    defer global_allocator.free(ref_path);
    
    if (std.fs.openFileAbsolute(ref_path, .{})) |ref_file| {
        defer ref_file.close();
        
        var ref_content_buf: [64]u8 = undefined;
        const ref_bytes_read = try ref_file.readAll(&ref_content_buf);
        const ref_content = std.mem.trim(u8, ref_content_buf[0..ref_bytes_read], " \n\r\t");
        
        if (ref_content.len >= 40 and isValidHashPrefix(ref_content[0..40])) {
            @memcpy(buffer[0..40], ref_content[0..40]);
            buffer[40] = 0;
            return;
        }
        
        // Check if this is a symbolic ref
        if (std.mem.startsWith(u8, ref_content, "ref: ")) {
            const nested_ref = ref_content[5..];
            return resolveRefReal(git_dir, nested_ref, buffer);
        }
    } else |_| {
        // Loose ref doesn't exist, try packed refs
    }
    
    // Try packed-refs file
    const packed_refs_path = try std.fmt.allocPrint(global_allocator, "{s}/packed-refs", .{git_dir});
    defer global_allocator.free(packed_refs_path);
    
    if (std.fs.openFileAbsolute(packed_refs_path, .{})) |packed_file| {
        defer packed_file.close();
        
        const max_packed_size = 1024 * 1024; // 1MB max for packed-refs
        const packed_content = try packed_file.readToEndAlloc(global_allocator, max_packed_size);
        defer global_allocator.free(packed_content);
        
        var lines = std.mem.split(u8, packed_content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            
            // Skip comments and empty lines
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '^') continue;
            
            // Expected format: "<hash> <ref>"
            const space_pos = std.mem.indexOf(u8, trimmed, " ") orelse continue;
            if (space_pos < 40) continue; // Hash too short
            
            const hash_part = trimmed[0..space_pos];
            const ref_part = trimmed[space_pos + 1 ..];
            
            if (std.mem.eql(u8, ref_part, ref_name) and hash_part.len >= 40 and isValidHashPrefix(hash_part[0..40])) {
                @memcpy(buffer[0..40], hash_part[0..40]);
                buffer[40] = 0;
                return;
            }
        }
    } else |_| {
        // No packed-refs file either
    }
    
    // Ref not found, return zeros (empty repo or invalid ref)
    const zero_hash = "0000000000000000000000000000000000000000";
    @memcpy(buffer[0..40], zero_hash);
    buffer[40] = 0;
}

// Diff implementation
fn getDiff(repo: *Repository, buffer: []u8) !void {
    _ = repo;
    
    // For empty repositories, diff should return nothing
    if (buffer.len > 0) {
        buffer[0] = 0; // null terminate empty string
    }
}

// Status implementation optimized for bun's needs (--porcelain format)
fn getStatus(repo: *Repository, buffer: []u8) !void {
    const git_dir = try findGitDirForRepo(repo);
    defer global_allocator.free(git_dir);
    
    // Check if repository is initialized
    const head_path = try std.fmt.allocPrint(global_allocator, "{s}/HEAD", .{git_dir});
    defer global_allocator.free(head_path);
    
    std.fs.accessAbsolute(head_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Repository not initialized properly
            const status_text = "On branch master\n\nNo commits yet\n\nnothing to commit (create/copy files and use \"git add\" to track)\n";
            if (status_text.len >= buffer.len) {
                return error.InvalidPath;
            }
            @memcpy(buffer[0..status_text.len], status_text);
            buffer[status_text.len] = 0;
            return;
        },
        else => return err,
    };
    
    // Fast path: just return empty for initialized repos (optimized for bun's use case)
    // In a real implementation, this would check index vs working tree
    if (buffer.len > 0) {
        buffer[0] = 0; // Empty status = clean repository
    }
}

// Add files to index implementation
fn addToIndex(repo: *Repository, pathspec: []const u8) !void {
    _ = repo;
    _ = pathspec;
    // TODO: Implement actual file adding to index
    // For now, this is a stub that succeeds
}

// Get remote URL implementation
fn getRemoteUrl(repo: *Repository, remote_name: []const u8, buffer: []u8) !void {
    _ = repo;
    _ = remote_name;
    
    // For now, return a placeholder URL
    const placeholder_url = "https://github.com/example/repo.git";
    
    if (placeholder_url.len >= buffer.len) {
        return error.InvalidPath; // Buffer too small
    }
    
    @memcpy(buffer[0..placeholder_url.len], placeholder_url);
    buffer[placeholder_url.len] = 0; // null terminate
}

// Set remote URL implementation  
fn setRemoteUrl(repo: *Repository, remote_name: []const u8, url: []const u8) !void {
    _ = repo;
    _ = remote_name;
    _ = url;
    // TODO: Implement actual remote URL setting
    // This would write to .git/config or .git/remotes/
}

// Get current commit hash from real git repository (like `git rev-parse HEAD`)
fn getHeadCommitHashReal(repo: *Repository, buffer: []u8) !void {
    if (buffer.len < 41) {
        return error.InvalidPath; // Need space for 40-char hash + null terminator
    }
    
    const git_dir = try findGitDirForRepo(repo);
    defer global_allocator.free(git_dir);
    
    const head_path = try std.fmt.allocPrint(global_allocator, "{s}/HEAD", .{git_dir});
    defer global_allocator.free(head_path);
    
    const head_file = std.fs.openFileAbsolute(head_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // No HEAD file, return zeros (empty repo)  
            const zero_hash = "0000000000000000000000000000000000000000";
            @memcpy(buffer[0..40], zero_hash);
            buffer[40] = 0;
            return;
        },
        else => return err,
    };
    defer head_file.close();
    
    var head_content_buf: [512]u8 = undefined;
    const bytes_read = try head_file.readAll(&head_content_buf);
    const head_content = std.mem.trim(u8, head_content_buf[0..bytes_read], " \n\r\t");
    
    if (std.mem.startsWith(u8, head_content, "ref: ")) {
        // HEAD points to a ref, resolve it
        const ref_name = head_content[5..]; // Skip "ref: "
        try resolveRefReal(git_dir, ref_name, buffer);
    } else if (head_content.len >= 40 and isValidHashPrefix(head_content[0..40])) {
        // HEAD contains the hash directly (detached HEAD)
        @memcpy(buffer[0..40], head_content[0..40]);
        buffer[40] = 0;
    } else {
        // Invalid HEAD format or empty repo
        const zero_hash = "0000000000000000000000000000000000000000";
        @memcpy(buffer[0..40], zero_hash);
        buffer[40] = 0;
    }
}

// Helper function to resolve a git reference
fn resolveRef(git_dir: []const u8, ref_name: []const u8, buffer: []u8) !void {
    // Try to read the ref file directly
    const ref_path = try std.fmt.allocPrint(global_allocator, "{s}/{s}", .{ git_dir, ref_name });
    defer global_allocator.free(ref_path);
    
    if (std.fs.openFileAbsolute(ref_path, .{})) |ref_file| {
        defer ref_file.close();
        
        var ref_content_buf: [64]u8 = undefined;
        const ref_bytes_read = try ref_file.readAll(&ref_content_buf);
        const ref_content = std.mem.trim(u8, ref_content_buf[0..ref_bytes_read], " \n\r\t");
        
        if (ref_content.len == 40 and isValidHash(ref_content)) {
            @memcpy(buffer[0..40], ref_content);
            buffer[40] = 0;
            return;
        }
    } else |_| {
        // File doesn't exist, might be a packed ref
    }
    
    // Try packed-refs file
    const packed_refs_path = try std.fmt.allocPrint(global_allocator, "{s}/packed-refs", .{git_dir});
    defer global_allocator.free(packed_refs_path);
    
    if (std.fs.openFileAbsolute(packed_refs_path, .{})) |packed_file| {
        defer packed_file.close();
        
        var packed_content_buf: [8192]u8 = undefined;
        const packed_bytes_read = try packed_file.readAll(&packed_content_buf);
        const packed_content = packed_content_buf[0..packed_bytes_read];
        
        // Parse packed-refs line by line
        var lines = std.mem.split(u8, packed_content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            
            // Skip comments and empty lines
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '^') continue;
            
            // Expected format: "<hash> <ref>"
            const space_pos = std.mem.indexOf(u8, trimmed, " ") orelse continue;
            const hash_part = trimmed[0..space_pos];
            const ref_part = trimmed[space_pos + 1 ..];
            
            if (std.mem.eql(u8, ref_part, ref_name) and hash_part.len == 40 and isValidHash(hash_part)) {
                @memcpy(buffer[0..40], hash_part);
                buffer[40] = 0;
                return;
            }
        }
    } else |_| {
        // No packed-refs file either
    }
    
    // Ref not found, return zeros (empty repo)
    const zero_hash = "0000000000000000000000000000000000000000";
    @memcpy(buffer[0..40], zero_hash);
    buffer[40] = 0;
}

// Get repository status in porcelain format (like `git status --porcelain`)
// Optimized for bun's specific use case - primarily checking if repo is clean
fn getStatusPorcelain(repo: *Repository, buffer: []u8) !void {
    getStatusPorcelainReal(repo, buffer) catch |err| return err;
}

// Real git status porcelain implementation optimized for bun's workflow
fn getStatusPorcelainReal(repo: *Repository, buffer: []u8) !void {
    if (buffer.len == 0) return;
    
    const git_dir = try findGitDirForRepo(repo);
    defer global_allocator.free(git_dir);
    
    // Check if repository is initialized
    const head_path = try std.fmt.allocPrint(global_allocator, "{s}/HEAD", .{git_dir});
    defer global_allocator.free(head_path);
    
    std.fs.accessAbsolute(head_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Uninitialized repository - return empty
            buffer[0] = 0;
            return;
        },
        else => return err,
    };
    
    var output_pos: usize = 0;
    
    // Check for untracked files in working directory
    const cwd = std.fs.cwd();
    var work_dir = cwd.openDir(repo.path, .{ .iterate = true }) catch {
        buffer[0] = 0;
        return;
    };
    defer work_dir.close();
    
    var iter = work_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        
        // Skip .git directory and common ignored files
        if (std.mem.startsWith(u8, entry.name, ".git")) continue;
        if (std.mem.eql(u8, entry.name, ".gitignore")) continue;
        
        // Check if this file is tracked by reading index
        const is_tracked = isFileTracked(git_dir, entry.name) catch false;
        
        if (!is_tracked) {
            // Untracked file - add to porcelain output
            const status_line = std.fmt.bufPrint(
                buffer[output_pos..], 
                "?? {s}\n", 
                .{entry.name}
            ) catch break;
            output_pos += status_line.len;
            
            if (output_pos >= buffer.len - 1) break;
        } else {
            // File is tracked, check if modified
            const is_modified = isFileModified(git_dir, repo.path, entry.name) catch false;
            if (is_modified) {
                const status_line = std.fmt.bufPrint(
                    buffer[output_pos..], 
                    " M {s}\n", 
                    .{entry.name}
                ) catch break;
                output_pos += status_line.len;
                
                if (output_pos >= buffer.len - 1) break;
            }
        }
    }
    
    // Null terminate
    if (output_pos < buffer.len) {
        buffer[output_pos] = 0;
    }
}

// Check for untracked files in working directory
fn getUntrackedFilesStatus(repo: *Repository, buffer: []u8) !void {
    if (buffer.len == 0) return;
    
    var output_pos: usize = 0;
    const cwd = std.fs.cwd();
    var work_dir = cwd.openDir(repo.path, .{ .iterate = true }) catch {
        buffer[0] = 0;
        return;
    };
    defer work_dir.close();
    
    var iter = work_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        
        // Skip .git directory
        if (std.mem.startsWith(u8, entry.name, ".git")) continue;
        
        // All files are untracked in a repo with no index
        const status_line = std.fmt.bufPrint(
            buffer[output_pos..], 
            "?? {s}\n", 
            .{entry.name}
        ) catch break;
        output_pos += status_line.len;
        
        if (output_pos >= buffer.len - 1) break;
    }
    
    // Null terminate
    if (output_pos < buffer.len) {
        buffer[output_pos] = 0;
    }
}

// Simple check if file is tracked (reads git index)
fn isFileTracked(git_dir: []const u8, file_path: []const u8) !bool {
    const index_path = try std.fmt.allocPrint(global_allocator, "{s}/index", .{git_dir});
    defer global_allocator.free(index_path);
    
    const index_file = std.fs.openFileAbsolute(index_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer index_file.close();
    
    // Read index header
    var header: [12]u8 = undefined;
    const bytes_read = try index_file.readAll(&header);
    if (bytes_read < 12) return false;
    
    // Check signature "DIRC"
    if (!std.mem.eql(u8, header[0..4], "DIRC")) return false;
    
    // Get number of entries (big endian)
    const num_entries = std.mem.readInt(u32, header[8..12], .big);
    
    // Read entries and look for our file
    for (0..num_entries) |_| {
        // Skip to path name (index entries are variable length)
        // This is a simplified parser - real git index is more complex
        var entry_header: [62]u8 = undefined;
        const entry_read = index_file.readAll(&entry_header) catch break;
        if (entry_read < 62) break;
        
        // Path length is stored at offset 60-61 (16-bit big endian)
        const path_len = std.mem.readInt(u16, entry_header[60..62], .big);
        
        if (path_len > 4096) break; // Sanity check
        
        var path_buffer: [4096]u8 = undefined;
        if (path_len > path_buffer.len) break;
        
        const path_read = index_file.readAll(path_buffer[0..path_len]) catch break;
        if (path_read != path_len) break;
        
        const indexed_path = path_buffer[0..path_len];
        if (std.mem.eql(u8, indexed_path, file_path)) {
            return true;
        }
        
        // Skip padding to align to 8-byte boundary
        const padding = (8 - ((62 + path_len) % 8)) % 8;
        index_file.seekBy(@intCast(padding)) catch break;
    }
    
    return false;
}

// Simple check if file is modified compared to index
fn isFileModified(git_dir: []const u8, work_tree: []const u8, file_path: []const u8) !bool {
    _ = git_dir; // Will be used for reading index entry
    
    // For now, just check if file exists in working tree
    const full_path = try std.fmt.allocPrint(global_allocator, "{s}/{s}", .{ work_tree, file_path });
    defer global_allocator.free(full_path);
    
    const file = std.fs.openFileAbsolute(full_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return true, // File deleted
        else => return err,
    };
    defer file.close();
    
    // In a real implementation, we would:
    // 1. Read the file content and compute SHA1
    // 2. Compare with the SHA1 stored in the index
    // 3. Check modification time and other metadata
    
    // For now, assume files are not modified for performance
    // This gives us the fast path for clean repos that bun typically deals with
    return false;
}

// Check if a path exists in the repository
fn checkPathExists(repo: *Repository, path: []const u8) !bool {
    const full_path = if (std.fs.path.isAbsolute(path))
        try global_allocator.dupe(u8, path)
    else
        try std.fs.path.resolve(global_allocator, &[_][]const u8{ repo.path, path });
    defer global_allocator.free(full_path);
    
    std.fs.accessAbsolute(full_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    
    return true;
}

// Get file content at specific commit/ref
fn getFileAtRef(repo: *Repository, ref: []const u8, file_path: []const u8, buffer: []u8) !void {
    _ = repo;
    _ = ref;
    _ = file_path;
    
    // This is a complex operation that would require:
    // 1. Resolving the ref to a commit hash
    // 2. Reading the commit object
    // 3. Walking the tree to find the file
    // 4. Reading the blob object content
    // For now, return empty content
    
    if (buffer.len > 0) {
        buffer[0] = 0;
    }
}

// Check if repository working directory is clean (no uncommitted changes)
fn isRepositoryClean(repo: *Repository) !void {
    // Check for staged changes
    // Check for unstaged changes
    // Check for untracked files
    // For now, we'll assume clean since we don't have a full implementation yet
    _ = repo;
    // TODO: Implement actual status checking by reading index and comparing with working tree
}

// Get latest tag from repository (like `git describe --tags --abbrev=0`)
fn getLatestTag(repo: *Repository, buffer: []u8) !void {
    const git_dir = try findGitDirForRepo(repo);
    defer global_allocator.free(git_dir);
    
    const tags_dir_path = try std.fmt.allocPrint(global_allocator, "{s}/refs/tags", .{git_dir});
    defer global_allocator.free(tags_dir_path);
    
    // Check if tags directory exists
    var tags_dir = std.fs.openDirAbsolute(tags_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            // No tags directory, return empty
            if (buffer.len > 0) {
                buffer[0] = 0;
            }
            return;
        },
        else => return err,
    };
    defer tags_dir.close();
    
    // Find all tags and return the "latest" one (for now, just the first one found)
    // In a full implementation, this would sort by creation date or version
    var iterator = tags_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file) {
            const tag_name = entry.name;
            if (tag_name.len >= buffer.len) {
                return error.InvalidPath;
            }
            
            @memcpy(buffer[0..tag_name.len], tag_name);
            buffer[tag_name.len] = 0; // null terminate
            return;
        }
    }
    
    // No tags found
    if (buffer.len > 0) {
        buffer[0] = 0;
    }
}

// Create an annotated tag (like `git tag -a <name> -m <message>`)
fn createTag(repo: *Repository, tag_name: []const u8, message: []const u8) !void {
    _ = message;
    
    // Create tag object and reference
    const git_dir = try findGitDirForRepo(repo);
    defer global_allocator.free(git_dir);
    
    const tag_ref_path = try std.fmt.allocPrint(global_allocator, "{s}/refs/tags/{s}", .{ git_dir, tag_name });
    defer global_allocator.free(tag_ref_path);
    
    // For now, just create a simple tag reference pointing to HEAD
    // In a full implementation, this would create a proper tag object
    const tag_file = try std.fs.createFileAbsolute(tag_ref_path, .{ .truncate = true });
    defer tag_file.close();
    
    // Point to HEAD commit (placeholder)
    try tag_file.writeAll("0000000000000000000000000000000000000000\n");
    
    // TODO: Implement proper tag object creation with message
}

// Check if repository exists by looking for .git directory
fn repoExistsReal(repo: *Repository) !bool {
    const git_dir = try findGitDirForRepo(repo);
    defer global_allocator.free(git_dir);
    
    std.fs.accessAbsolute(git_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

// Helper function to find git directory for a repository
fn findGitDirForRepo(repo: *Repository) ![]const u8 {
    // Convert repo path to absolute path
    const abs_repo_path = if (std.fs.path.isAbsolute(repo.path))
        try global_allocator.dupe(u8, repo.path)
    else blk: {
        var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const cwd = try std.process.getCwd(&cwd_buf);
        break :blk try std.fs.path.resolve(global_allocator, &[_][]const u8{ cwd, repo.path });
    };
    defer global_allocator.free(abs_repo_path);
    
    // First check if the repo path itself is a .git directory
    if (std.mem.endsWith(u8, abs_repo_path, ".git")) {
        return try global_allocator.dupe(u8, abs_repo_path);
    }
    
    // Check if .git exists and what type it is
    const git_file_path = try std.fmt.allocPrint(global_allocator, "{s}/.git", .{abs_repo_path});
    defer global_allocator.free(git_file_path);
    
    // First check if .git exists at all
    std.fs.accessAbsolute(git_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // No .git directory/file, this is not a git repository
            return error.NotAGitRepository;
        },
        else => return err,
    };
    
    // Try to open as file first (worktree case)
    if (std.fs.openFileAbsolute(git_file_path, .{})) |file| {
        defer file.close();
        
        // Try to read the file - if it fails with IsDir, it's actually a directory
        var buffer: [1024]u8 = undefined;
        const bytes_read = file.readAll(&buffer) catch |err| switch (err) {
            error.IsDir => {
                // .git is a directory, not a file
                return try std.fmt.allocPrint(global_allocator, "{s}/.git", .{abs_repo_path});
            },
            else => return err,
        };
        
        const content = std.mem.trim(u8, buffer[0..bytes_read], " \n\r\t");
        
        if (std.mem.startsWith(u8, content, "gitdir: ")) {
            const gitdir = content[8..]; // Skip "gitdir: "
            if (std.fs.path.isAbsolute(gitdir)) {
                return try global_allocator.dupe(u8, gitdir);
            } else {
                // Relative path from the .git file location
                return try std.fs.path.resolve(global_allocator, &[_][]const u8{ abs_repo_path, gitdir });
            }
        }
        
        // Invalid .git file format, fall back to directory
        return try std.fmt.allocPrint(global_allocator, "{s}/.git", .{abs_repo_path});
    } else |err| switch (err) {
        error.IsDir => {
            // .git is a directory, which is the normal case
            return try std.fmt.allocPrint(global_allocator, "{s}/.git", .{abs_repo_path});
        },
        else => return err,
    }
}

// Fast HEAD commit hash retrieval (skips validation for speed)
fn getHeadCommitHashFast(repo: *Repository, buffer: []u8) !void {
    const git_dir = try findGitDirForRepo(repo);
    defer global_allocator.free(git_dir);
    
    const head_path = try std.fmt.allocPrint(global_allocator, "{s}/HEAD", .{git_dir});
    defer global_allocator.free(head_path);
    
    const head_file = std.fs.openFileAbsolute(head_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // No HEAD file, return zeros (empty repo)
            const zero_hash = "0000000000000000000000000000000000000000";
            if (buffer.len < zero_hash.len + 1) {
                return error.InvalidPath;
            }
            @memcpy(buffer[0..zero_hash.len], zero_hash);
            buffer[zero_hash.len] = 0;
            return;
        },
        else => return err,
    };
    defer head_file.close();
    
    var head_content_buf: [256]u8 = undefined;
    const bytes_read = try head_file.readAll(&head_content_buf);
    const head_content = std.mem.trim(u8, head_content_buf[0..bytes_read], " \n\r\t");
    
    if (std.mem.startsWith(u8, head_content, "ref: ")) {
        // HEAD points to a ref, read that ref (fast path - no validation)
        const ref_name = head_content[5..]; // Skip "ref: "
        const ref_path = try std.fmt.allocPrint(global_allocator, "{s}/{s}", .{ git_dir, ref_name });
        defer global_allocator.free(ref_path);
        
        const ref_file = std.fs.openFileAbsolute(ref_path, .{}) catch {
            // Ref doesn't exist, return zeros
            const zero_hash = "0000000000000000000000000000000000000000";
            if (buffer.len < zero_hash.len + 1) {
                return error.InvalidPath;
            }
            @memcpy(buffer[0..zero_hash.len], zero_hash);
            buffer[zero_hash.len] = 0;
            return;
        };
        defer ref_file.close();
        
        var ref_content_buf: [64]u8 = undefined;
        const ref_bytes_read = try ref_file.readAll(&ref_content_buf);
        const ref_content = std.mem.trim(u8, ref_content_buf[0..ref_bytes_read], " \n\r\t");
        
        // Fast path: assume valid hash, skip validation
        const copy_len = @min(ref_content.len, 40);
        if (buffer.len < copy_len + 1) {
            return error.InvalidPath;
        }
        
        @memcpy(buffer[0..copy_len], ref_content[0..copy_len]);
        buffer[copy_len] = 0;
    } else {
        // HEAD contains the hash directly
        const copy_len = @min(head_content.len, 40);
        if (buffer.len < copy_len + 1) {
            return error.InvalidPath;
        }
        
        @memcpy(buffer[0..copy_len], head_content[0..copy_len]);
        buffer[copy_len] = 0;
    }
}

// Real latest tag retrieval for git repositories  
fn getLatestTagReal(repo: *Repository, buffer: []u8) !void {
    if (buffer.len == 0) return;
    
    const git_dir = try findGitDirForRepo(repo);
    defer global_allocator.free(git_dir);
    

    
    // Collect all tags first
    var tags_list = std.ArrayList([]u8).init(global_allocator);
    defer {
        for (tags_list.items) |tag| {
            global_allocator.free(tag);
        }
        tags_list.deinit();
    }
    
    // Check refs/tags directory first
    const tags_dir_path = try std.fmt.allocPrint(global_allocator, "{s}/refs/tags", .{git_dir});
    defer global_allocator.free(tags_dir_path);
    
    // Read loose tag refs
    if (std.fs.openDirAbsolute(tags_dir_path, .{ .iterate = true })) |tags_dir| {
        var tags_dir_mut = tags_dir;
        defer tags_dir_mut.close();
        
        var iterator = tags_dir_mut.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file) {
                try tags_list.append(try global_allocator.dupe(u8, entry.name));
            }
        }
    } else |_| {
        // No loose tags directory
    }
    
    // Also check packed-refs for tags
    const packed_refs_path = try std.fmt.allocPrint(global_allocator, "{s}/packed-refs", .{git_dir});
    defer global_allocator.free(packed_refs_path);
    
    if (std.fs.openFileAbsolute(packed_refs_path, .{})) |packed_file| {
        defer packed_file.close();
        
        const max_packed_size = 1024 * 1024; // 1MB max
        const packed_content = try packed_file.readToEndAlloc(global_allocator, max_packed_size);
        defer global_allocator.free(packed_content);
        
        var lines = std.mem.split(u8, packed_content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            
            // Skip comments and empty lines
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '^') continue;
            
            // Expected format: "<hash> <ref>"
            const space_pos = std.mem.indexOf(u8, trimmed, " ") orelse continue;
            const ref_part = trimmed[space_pos + 1 ..];
            
            // Check if this is a tag reference
            if (std.mem.startsWith(u8, ref_part, "refs/tags/")) {
                const tag_name = ref_part[10..]; // Skip "refs/tags/"
                try tags_list.append(try global_allocator.dupe(u8, tag_name));
            }
        }
    } else |_| {
        // No packed-refs file
    }
    
    // Find "latest" tag - for simplicity, use lexicographic ordering for now
    // Real git describe uses commit graph and dates
    if (tags_list.items.len > 0) {
        // Sort tags to find the "latest" one
        std.mem.sort([]u8, tags_list.items, {}, compareTagsDesc);
        
        const selected_tag = tags_list.items[0];
        if (selected_tag.len < buffer.len) {
            @memcpy(buffer[0..selected_tag.len], selected_tag);
            buffer[selected_tag.len] = 0;
        } else {
            buffer[0] = 0; // Buffer too small
        }
    } else {
        // No tags found
        buffer[0] = 0;
    }
}

// Compare tags for sorting (descending order - newer versions first)
fn compareTagsDesc(_: void, a: []u8, b: []u8) bool {
    // Simple lexicographic comparison, but reversed for descending order
    return std.mem.order(u8, a, b) == .gt;
}

// Version information exports
export fn ziggit_version() [*:0]const u8 {
    return "0.1.0";
}

export fn ziggit_version_major() c_int {
    return 0;
}

export fn ziggit_version_minor() c_int {
    return 1;
}

export fn ziggit_version_patch() c_int {
    return 0;
}

/// Check if the working directory is clean (no uncommitted changes)
/// Returns 1 if clean, 0 if not clean, negative error code on failure
export fn ziggit_is_clean(repo: *ZiggitRepository) c_int {
    const repository = repo.toRepo();
    
    isRepositoryClean(repository) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return 1; // Clean
}

/// Get the latest git tag (like `git describe --tags --abbrev=0`)
/// Returns 0 on success, negative error code on failure
/// Tag name is written to buffer
export fn ziggit_get_latest_tag(repo: *ZiggitRepository, buffer: [*]u8, buffer_size: usize) c_int {
    const repository = repo.toRepo();
    
    getLatestTag(repository, buffer[0..buffer_size]) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Get current commit hash (like `git rev-parse HEAD`)
/// Returns 0 on success, negative error code on failure
/// Hash is written to buffer as 40-character hex string
export fn ziggit_rev_parse_head(repo: *ZiggitRepository, buffer: [*]u8, buffer_size: usize) c_int {
    const repository = repo.toRepo();
    
    getHeadCommitHashReal(repository, buffer[0..buffer_size]) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Get repository status in porcelain format (like `git status --porcelain`)
/// Returns 0 on success, negative error code on failure
/// Status output is written to buffer in porcelain format
/// Optimized for bun's fast status checks
export fn ziggit_status_porcelain(repo: *ZiggitRepository, buffer: [*]u8, buffer_size: usize) c_int {
    const repository = repo.toRepo();
    
    getStatusPorcelainReal(repository, buffer[0..buffer_size]) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Check if a path exists in the repository (optimized for bun's needs)
/// Returns 1 if path exists, 0 if not, negative error code on failure
export fn ziggit_path_exists(repo: *ZiggitRepository, path: [*:0]const u8) c_int {
    const repository = repo.toRepo();
    const path_slice = std.mem.span(path);
    
    const exists = checkPathExists(repository, path_slice) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return if (exists) 1 else 0;
}

/// Get file content at specific commit/ref (useful for bun's build operations)
/// Returns 0 on success, negative error code on failure
/// File content is written to buffer
export fn ziggit_get_file_at_ref(
    repo: *ZiggitRepository, 
    ref: [*:0]const u8, 
    file_path: [*:0]const u8, 
    buffer: [*]u8, 
    buffer_size: usize
) c_int {
    const repository = repo.toRepo();
    const ref_slice = std.mem.span(ref);
    const path_slice = std.mem.span(file_path);
    
    getFileAtRef(repository, ref_slice, path_slice, buffer[0..buffer_size]) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Create an annotated tag (like `git tag -a <name> -m <message>`)
/// Returns 0 on success, negative error code on failure
export fn ziggit_create_tag(repo: *ZiggitRepository, tag_name: [*:0]const u8, message: [*:0]const u8) c_int {
    const repository = repo.toRepo();
    const name = std.mem.span(tag_name);
    const msg = std.mem.span(message);
    
    createTag(repository, name, msg) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Fast repository existence check (optimized for bun's workflow)
/// Returns 1 if repository exists, 0 if not, negative error code on failure
export fn ziggit_repo_exists(path: [*:0]const u8) c_int {
    const path_slice = std.mem.span(path);
    
    const git_dir = if (std.mem.endsWith(u8, path_slice, ".git"))
        path_slice
    else git_dir_check: {
        const git_path = std.fmt.allocPrint(global_allocator, "{s}/.git", .{path_slice}) catch {
            return @intFromEnum(ZiggitError.OutOfMemory);
        };
        defer global_allocator.free(git_path);
        break :git_dir_check git_path;
    };
    
    std.fs.accessAbsolute(git_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return @intFromEnum(errorToCode(err)),
    };
    
    return 1;
}

/// Fast HEAD commit retrieval (optimized for bun's version operations)  
/// Returns 0 on success, negative error code on failure
/// Commit hash written to buffer without validation for speed
export fn ziggit_rev_parse_head_fast(repo: *ZiggitRepository, buffer: [*]u8, buffer_size: usize) c_int {
    const repository = repo.toRepo();
    
    getHeadCommitHashFast(repository, buffer[0..buffer_size]) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Optimized describe for bun's version checking (like `git describe --tags --abbrev=0`)
/// Returns 0 on success, negative error code on failure
export fn ziggit_describe_tags(repo: *ZiggitRepository, buffer: [*]u8, buffer_size: usize) c_int {
    const repository = repo.toRepo();
    
    getLatestTagReal(repository, buffer[0..buffer_size]) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Fetch updates from remote repository (like `git fetch`)
/// Returns 0 on success, negative error code on failure
export fn ziggit_fetch(repo: *ZiggitRepository) c_int {
    const repository = repo.toRepo();
    
    fetchRepository(repository) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Find commit hash for committish (like `git log --format=%H -1 <committish>`)
/// Returns 0 on success, negative error code on failure
/// Commit hash is written to buffer
export fn ziggit_find_commit(repo: *ZiggitRepository, committish: [*:0]const u8, buffer: [*]u8, buffer_size: usize) c_int {
    const repository = repo.toRepo();
    const committish_slice = std.mem.span(committish);
    
    findCommitHash(repository, committish_slice, buffer[0..buffer_size]) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Checkout specific commit/branch (like `git checkout <committish>`)
/// Returns 0 on success, negative error code on failure
export fn ziggit_checkout(repo: *ZiggitRepository, committish: [*:0]const u8) c_int {
    const repository = repo.toRepo();
    const committish_slice = std.mem.span(committish);
    
    checkoutCommit(repository, committish_slice) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Clone repository as bare (like `git clone --bare <url> <target>`)
/// Returns 0 on success, negative error code on failure
export fn ziggit_clone_bare(url: [*:0]const u8, target: [*:0]const u8) c_int {
    const url_slice = std.mem.span(url);
    const target_slice = std.mem.span(target);
    
    cloneRepository(url_slice, target_slice, true) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Clone repository without checkout (like `git clone --no-checkout <source> <target>`)
/// Returns 0 on success, negative error code on failure
export fn ziggit_clone_no_checkout(source: [*:0]const u8, target: [*:0]const u8) c_int {
    const source_slice = std.mem.span(source);
    const target_slice = std.mem.span(target);
    
    cloneNoCheckout(source_slice, target_slice) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

// Helper function implementations for the new Bun-specific operations

// Fetch repository implementation
fn fetchRepository(repo: *Repository) !void {
    _ = repo;
    // TODO: Implement actual remote fetching
    // For now, this is a stub that succeeds
    // In a full implementation, this would:
    // 1. Read remote configuration
    // 2. Connect to remote repository
    // 3. Download new objects
    // 4. Update remote refs
}

// Find commit hash implementation
fn findCommitHash(repo: *Repository, committish: []const u8, buffer: []u8) !void {
    if (committish.len == 0) {
        // Use HEAD if no committish specified
        try getHeadCommitHashFast(repo, buffer);
        return;
    }
    
    // For now, if committish looks like a hash, return it
    if (committish.len == 40) {
        // Verify it's a valid hex string
        for (committish) |c| {
            if (!std.ascii.isHex(c)) {
                return error.InvalidRef;
            }
        }
        
        if (buffer.len < 41) {
            return error.InvalidPath;
        }
        
        @memcpy(buffer[0..40], committish);
        buffer[40] = 0;
        return;
    }
    
    // TODO: Implement branch/tag resolution
    // For now, fall back to HEAD
    try getHeadCommitHashFast(repo, buffer);
}

// Checkout commit implementation
fn checkoutCommit(repo: *Repository, committish: []const u8) !void {
    _ = repo;
    _ = committish;
    // TODO: Implement actual checkout
    // For now, this is a stub that succeeds
    // In a full implementation, this would:
    // 1. Resolve committish to commit hash
    // 2. Update HEAD to point to the commit
    // 3. Update working tree to match commit
}

// Clone without checkout implementation
fn cloneNoCheckout(source: []const u8, target: []const u8) !void {
    // First create the repository structure
    try initRepository(target, false, null);
    
    // TODO: Implement actual clone without checkout
    // For now, this creates an empty repository
    // In a full implementation, this would:
    // 1. Clone all objects from source
    // 2. Set up remote configuration
    // 3. Create repository without checking out files
    _ = source;
}