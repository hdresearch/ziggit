const std = @import("std");
const platform = @import("platform/platform.zig");
const Repository = @import("git/repository.zig").Repository;

const GitError = error{
    NotAGitRepository,
    AlreadyExists,
    InvalidPath,
};

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.args();
    _ = args.skip(); // skip program name

    const command = args.next() orelse {
        try showUsage(&plat);
        return;
    };

    if (std.mem.eql(u8, command, "init")) {
        try cmdInit(allocator, &args, stdout, stderr);
    } else if (std.mem.eql(u8, command, "status")) {
        try cmdStatus(allocator, &args, stdout, stderr);
    } else {
        try stderr.print("ziggit: '{s}' is not yet implemented\n", .{command});
        std.process.exit(1);
    }
}

fn cmdInit(allocator: std.mem.Allocator, args: *std.process.ArgIterator, stdout: anytype, stderr: anytype) !void {
    _ = allocator; // TODO: will be used for argument parsing
    _ = stderr;
    
    var bare = false;
    var template_dir: ?[]const u8 = null;
    var work_dir: []const u8 = ".";
    
    // Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bare")) {
            bare = true;
        } else if (std.mem.startsWith(u8, arg, "--template=")) {
            template_dir = arg[11..];
        } else {
            // Directory argument
            work_dir = arg;
        }
    }
    
    try initRepository(work_dir, bare, template_dir, stdout);
}

fn initRepository(path: []const u8, bare: bool, template_dir: ?[]const u8, stdout: anytype) !void {
    _ = template_dir; // TODO: implement template support
    
    // Convert to absolute path
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    
    const abs_path = if (std.fs.path.isAbsolute(path)) 
        try std.heap.page_allocator.dupe(u8, path)
    else
        try std.fs.path.resolve(std.heap.page_allocator, &[_][]const u8{ cwd, path });
    defer std.heap.page_allocator.free(abs_path);
    
    const git_dir = if (bare) 
        try std.heap.page_allocator.dupe(u8, abs_path)
    else 
        try std.fmt.allocPrint(std.heap.page_allocator, "{s}/.git", .{abs_path});
    defer std.heap.page_allocator.free(git_dir);
    
    // Create the target directory if it doesn't exist
    if (!bare) {
        std.fs.makeDirAbsolute(abs_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    
    // Check if repository already exists
    var already_exists = false;
    if (std.fs.accessAbsolute(git_dir, .{})) {
        already_exists = true;
    } else |err| switch (err) {
        error.FileNotFound => {}, // Directory doesn't exist, continue
        else => return err,
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
        const full_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ git_dir, subdir });
        defer std.heap.page_allocator.free(full_path);
        std.fs.makeDirAbsolute(full_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    
    // Create HEAD file
    const head_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/HEAD", .{git_dir});
    defer std.heap.page_allocator.free(head_path);
    const head_file = try std.fs.createFileAbsolute(head_path, .{ .truncate = true });
    defer head_file.close();
    try head_file.writeAll("ref: refs/heads/master\n");
    
    // Create config file
    const config_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/config", .{git_dir});
    defer std.heap.page_allocator.free(config_path);
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
    const desc_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/description", .{git_dir});
    defer std.heap.page_allocator.free(desc_path);
    const desc_file = try std.fs.createFileAbsolute(desc_path, .{ .truncate = true });
    defer desc_file.close();
    try desc_file.writeAll("Unnamed repository; edit this file 'description' to name the repository.\n");
    
    // Print success message
    const action = if (already_exists) "Reinitialized existing" else "Initialized empty";
    if (bare) {
        try stdout.print("{s} Git repository in {s}\n", .{ action, abs_path });
    } else {
        try stdout.print("{s} Git repository in {s}\n", .{ action, git_dir });
    }
}

fn cmdStatus(allocator: std.mem.Allocator, args: *std.process.ArgIterator, stdout: anytype, stderr: anytype) !void {
    _ = allocator; // TODO: will be used for argument parsing
    _ = args; // TODO: parse status-specific arguments
    
    // Find git repository
    const git_dir = findGitDir() catch |err| switch (err) {
        GitError.NotAGitRepository => {
            try stderr.print("fatal: not a git repository (or any of the parent directories): .git\n", .{});
            std.process.exit(128);
        },
        else => return err,
    };
    defer std.heap.page_allocator.free(git_dir);
    
    try displayStatus(git_dir, stdout);
}

fn findGitDir() ![]u8 {
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    
    var current_dir = try std.heap.page_allocator.dupe(u8, cwd);
    defer std.heap.page_allocator.free(current_dir);
    
    while (true) {
        const git_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/.git", .{current_dir});
        defer std.heap.page_allocator.free(git_path);
        
        // Check if .git exists
        if (std.fs.accessAbsolute(git_path, .{})) {
            // Return a copy that the caller owns
            return try std.heap.page_allocator.dupe(u8, git_path);
        } else |_| {
            // Move up to parent directory
            const parent = std.fs.path.dirname(current_dir) orelse break;
            if (std.mem.eql(u8, parent, current_dir)) break; // Reached root
            
            const new_current = try std.heap.page_allocator.dupe(u8, parent);
            std.heap.page_allocator.free(current_dir);
            current_dir = new_current;
        }
    }
    
    return GitError.NotAGitRepository;
}

fn displayStatus(git_dir: []const u8, stdout: anytype) !void {
    _ = git_dir; // TODO: use git_dir to read actual repository state
    
    // For now, display a basic status that matches git's output for empty repositories
    try stdout.print("On branch master\n\n", .{});
    try stdout.print("No commits yet\n\n", .{});
    try stdout.print("nothing to commit (create/copy files and use \"git add\" to track)\n", .{});
}
