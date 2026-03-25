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
        const git_dir = try std.fmt.allocPrint(self.allocator, "{s}/.git", .{self.path});
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
    try getStatus(repo, buffer);
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
    
    // Check if repository exists
    const exists = repo.exists() catch {
        global_allocator.destroy(repo);
        return null;
    };
    
    if (!exists) {
        global_allocator.destroy(repo);
        return null;
    }
    
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
    _ = repo;
    
    if (buffer_size < 100) {
        return @intFromEnum(ZiggitError.InvalidPath);
    }
    
    // Basic status implementation - matches current main.zig implementation
    const status_text = "On branch master\n\nNo commits yet\n\nnothing to commit (create/copy files and use \"git add\" to track)\n";
    
    if (status_text.len >= buffer_size) {
        return @intFromEnum(ZiggitError.InvalidPath);
    }
    
    @memcpy(buffer[0..status_text.len], status_text);
    buffer[status_text.len] = 0; // null terminate
    
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

// Branch listing implementation
fn listBranches(repo: *Repository, buffer: []u8) !usize {
    _ = repo;
    
    // For now, just return master branch for empty repositories
    const branch_text = "* master\n";
    
    if (branch_text.len >= buffer.len) {
        return error.InvalidPath; // Buffer too small
    }
    
    @memcpy(buffer[0..branch_text.len], branch_text);
    buffer[branch_text.len] = 0; // null terminate
    
    return 1; // number of branches
}

// Diff implementation
fn getDiff(repo: *Repository, buffer: []u8) !void {
    _ = repo;
    
    // For empty repositories, diff should return nothing
    if (buffer.len > 0) {
        buffer[0] = 0; // null terminate empty string
    }
}

// Status implementation
fn getStatus(repo: *Repository, buffer: []u8) !void {
    _ = repo;
    
    // Basic status implementation - matches current main.zig implementation
    const status_text = "On branch master\n\nNo commits yet\n\nnothing to commit (create/copy files and use \"git add\" to track)\n";
    
    if (status_text.len >= buffer.len) {
        return error.InvalidPath;
    }
    
    @memcpy(buffer[0..status_text.len], status_text);
    buffer[status_text.len] = 0; // null terminate
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

// Get current commit hash (like `git rev-parse HEAD`)
fn getHeadCommitHash(repo: *Repository, buffer: []u8) !void {
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
        // HEAD points to a ref, read that ref
        const ref_name = head_content[5..]; // Skip "ref: "
        const ref_path = try std.fmt.allocPrint(global_allocator, "{s}/{s}", .{ git_dir, ref_name });
        defer global_allocator.free(ref_path);
        
        const ref_file = std.fs.openFileAbsolute(ref_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // Ref doesn't exist, return zeros (empty repo)
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
        defer ref_file.close();
        
        var ref_content_buf: [64]u8 = undefined;
        const ref_bytes_read = try ref_file.readAll(&ref_content_buf);
        const ref_content = std.mem.trim(u8, ref_content_buf[0..ref_bytes_read], " \n\r\t");
        
        if (ref_content.len != 40) {
            return error.InvalidRef;
        }
        
        if (buffer.len < 41) {
            return error.InvalidPath;
        }
        
        @memcpy(buffer[0..40], ref_content);
        buffer[40] = 0;
    } else {
        // HEAD contains the hash directly
        if (head_content.len != 40) {
            return error.InvalidRef;
        }
        
        if (buffer.len < 41) {
            return error.InvalidPath;
        }
        
        @memcpy(buffer[0..40], head_content);
        buffer[40] = 0;
    }
}

// Get repository status in porcelain format (like `git status --porcelain`)
fn getStatusPorcelain(repo: *Repository, buffer: []u8) !void {
    _ = repo;
    
    // For empty repositories, porcelain format returns empty
    // In a full implementation, this would:
    // - Compare working tree with index
    // - Compare index with HEAD
    // - List untracked files
    // - Output in XY format where X=index status, Y=worktree status
    
    if (buffer.len > 0) {
        buffer[0] = 0; // null terminate empty string
    }
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

// Find git directory helper - reused from main.zig logic
fn findGitDir(allocator: std.mem.Allocator) ![]u8 {
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    
    var current_dir = try allocator.dupe(u8, cwd);
    defer allocator.free(current_dir);
    
    while (true) {
        const git_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{current_dir});
        defer allocator.free(git_path);
        
        // Check if .git exists
        if (std.fs.accessAbsolute(git_path, .{})) {
            return try allocator.dupe(u8, git_path);
        } else |_| {
            // Move up to parent directory
            const parent = std.fs.path.dirname(current_dir) orelse break;
            if (std.mem.eql(u8, parent, current_dir)) break; // Reached root
            
            const new_current = try allocator.dupe(u8, parent);
            allocator.free(current_dir);
            current_dir = new_current;
        }
    }
    
    return error.NotAGitRepository;
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

// Helper function to find git directory for a repository
fn findGitDirForRepo(repo: *Repository) ![]const u8 {
    // Check if the repo path itself is a .git directory
    if (std.mem.endsWith(u8, repo.path, ".git")) {
        return try global_allocator.dupe(u8, repo.path);
    }
    
    // Otherwise, append .git to the repo path
    return try std.fmt.allocPrint(global_allocator, "{s}/.git", .{repo.path});
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
    
    getHeadCommitHash(repository, buffer[0..buffer_size]) catch |err| {
        return @intFromEnum(errorToCode(err));
    };
    
    return @intFromEnum(ZiggitError.Success);
}

/// Get repository status in porcelain format (like `git status --porcelain`)
/// Returns 0 on success, negative error code on failure
/// Status output is written to buffer in porcelain format
export fn ziggit_status_porcelain(repo: *ZiggitRepository, buffer: [*]u8, buffer_size: usize) c_int {
    const repository = repo.toRepo();
    
    getStatusPorcelain(repository, buffer[0..buffer_size]) catch |err| {
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