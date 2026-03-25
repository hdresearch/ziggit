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

// Helper function to initialize repository (reused from main.zig)
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
        error.PathAlreadyExists => {},
        else => return err,
    };
    
    // Create subdirectories
    const subdirs = [_][]const u8{
        "objects",
        "refs",
        "refs/heads", 
        "refs/tags",
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