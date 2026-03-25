// WASI-specific main that uses relative paths and avoids problematic absolute path operations
const std = @import("std");
const platform = @import("platform/platform.zig");
const Repository = @import("git/repository.zig").Repository;
const objects = @import("git/objects.zig");
const index_mod = @import("git/index.zig");
const refs = @import("git/refs.zig");

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

    // Use WASI-compatible argument handling
    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    defer args.deinit();
    
    // Skip program name
    _ = args.next();
    
    const command = args.next() orelse {
        try printHelp(stdout);
        return;
    };

    if (std.mem.eql(u8, command, "init")) {
        try handleInit(&args, allocator, stdout, stderr);
    } else if (std.mem.eql(u8, command, "status")) {
        try handleStatus(allocator, stdout, stderr);
    } else if (std.mem.eql(u8, command, "add")) {
        try handleAdd(&args, allocator, stdout, stderr);
    } else if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try stdout.print("ziggit version 0.1.0 (WASI)\n", .{});
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printHelp(stdout);
    } else {
        try stderr.print("ziggit: '{s}' is not a ziggit command.\n", .{command});
        try stderr.print("See 'ziggit --help'.\n", .{});
        std.process.exit(1);
    }
}

fn printHelp(stdout: anytype) !void {
    try stdout.print("ziggit: a modern version control system written in Zig (WASI)\n", .{});
    try stdout.print("usage: ziggit <command> [<args>]\n\n", .{});
    try stdout.print("Commands:\n", .{});
    try stdout.print("  init       Create an empty repository\n", .{});
    try stdout.print("  add        Add file contents to the index\n", .{});
    try stdout.print("  status     Show the working tree status\n", .{});
    try stdout.print("\n", .{});
    try stdout.print("Other commands will be added in future versions.\n", .{});
}

fn handleInit(args: *std.process.ArgIterator, allocator: std.mem.Allocator, stdout: anytype, stderr: anytype) !void {
    _ = stderr;
    
    var bare = false;
    var template_dir: ?[]const u8 = null;
    var work_dir: []const u8 = ".";
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bare")) {
            bare = true;
        } else if (std.mem.startsWith(u8, arg, "--template=")) {
            template_dir = arg[11..];
        } else {
            work_dir = arg;
        }
    }
    
    try initRepository(work_dir, bare, template_dir, allocator, stdout);
}

fn initRepository(path: []const u8, bare: bool, template_dir: ?[]const u8, allocator: std.mem.Allocator, stdout: anytype) !void {
    _ = template_dir; // TODO: implement template support
    
    const git_dir = if (bare) 
        try allocator.dupe(u8, path)
    else 
        try std.fmt.allocPrint(allocator, "{s}/.git", .{path});
    defer allocator.free(git_dir);
    
    // Create the target directory if it doesn't exist
    if (!bare) {
        std.fs.cwd().makeDir(path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Check if .git directory already exists  
    if (std.fs.cwd().access(git_dir, .{})) {
        try stdout.print("Reinitialized existing Git repository in {s}\n", .{git_dir});
        return;
    } else |_| {}

    // Create .git directory structure
    std.fs.cwd().makeDir(git_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Create subdirectories
    const subdirs = [_][]const u8{
        "objects", "refs", "refs/heads", "refs/tags", "hooks", "info"
    };

    for (subdirs) |subdir| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, subdir });
        defer allocator.free(full_path);
        
        std.fs.cwd().makeDir(full_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Create HEAD file
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    try std.fs.cwd().writeFile(.{ .sub_path = head_path, .data = "ref: refs/heads/main\n" });

    // Create config file
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
    defer allocator.free(config_path);
    const config_content =
        \\[core]
        \\	repositoryformatversion = 0
        \\	filemode = true
        \\	bare = false
        \\	logallrefupdates = true
        \\
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = config_path, .data = config_content });

    // Create description file
    const desc_path = try std.fmt.allocPrint(allocator, "{s}/description", .{git_dir});
    defer allocator.free(desc_path);
    try std.fs.cwd().writeFile(.{ .sub_path = desc_path, .data = "Unnamed repository; edit this file 'description' to name the repository.\n" });

    if (bare) {
        try stdout.print("Initialized empty Git repository in {s}\n", .{git_dir});
    } else {
        try stdout.print("Initialized empty Git repository in {s}/.git/\n", .{path});
    }
}

fn handleStatus(allocator: std.mem.Allocator, stdout: anytype, stderr: anytype) !void {
    // Find .git directory
    var current_path = std.ArrayList(u8).init(allocator);
    defer current_path.deinit();
    try current_path.appendSlice(".");
    
    const git_path = while (true) {
        const test_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{current_path.items});
        defer allocator.free(test_path);
        
        if (std.fs.cwd().access(test_path, .{})) {
            break try allocator.dupe(u8, test_path);
        } else |_| {
            // Try parent directory
            if (std.mem.eql(u8, current_path.items, "..")) {
                try stderr.print("fatal: not a git repository (or any of the parent directories): .git\n", .{});
                std.process.exit(128);
            }
            current_path.clearRetainingCapacity();
            try current_path.appendSlice("../");
            try current_path.appendSlice(current_path.items[3..]);
        }
    } else unreachable;
    defer allocator.free(git_path);

    try stdout.print("On branch main\n\n", .{});
    
    // Check if there are any commits
    const refs_heads_main_path = try std.fmt.allocPrint(allocator, "{s}/.git/refs/heads/main", .{"."});
    defer allocator.free(refs_heads_main_path);
    
    if (std.fs.cwd().access(refs_heads_main_path, .{})) |_| {
        try stdout.print("nothing to commit, working tree clean\n", .{});
    } else |_| {
        try stdout.print("No commits yet\n\n", .{});
        try stdout.print("nothing to commit (create/copy files and use \"ziggit add\" to track)\n", .{});
    }
}

fn handleAdd(args: *std.process.ArgIterator, allocator: std.mem.Allocator, stdout: anytype, stderr: anytype) !void {
    _ = allocator;
    _ = stdout;
    
    const file_path = args.next() orelse {
        try stderr.print("Nothing specified, nothing added.\n", .{});
        try stderr.print("hint: Maybe you wanted to say 'ziggit add .'?\n", .{});
        std.process.exit(128);
    };

    // Simple implementation - just indicate the file would be added
    try stderr.print("ziggit add: '{s}' - add functionality not yet fully implemented in WASI version\n", .{file_path});
}