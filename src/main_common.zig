const std = @import("std");
const platform_mod = @import("platform/platform.zig");

// Only import git modules on platforms that support them
const Repository = if (@import("builtin").target.os.tag != .freestanding) @import("git/repository.zig").Repository else void;
const objects = if (@import("builtin").target.os.tag != .freestanding) @import("git/objects.zig") else void;
const index_mod = if (@import("builtin").target.os.tag != .freestanding) @import("git/index.zig") else void;
const refs = if (@import("builtin").target.os.tag != .freestanding) @import("git/refs.zig") else void;

const GitError = error{
    NotAGitRepository,
    AlreadyExists,
    InvalidPath,
};

pub fn zigzitMain(allocator: std.mem.Allocator) !void {
    const platform_impl = platform_mod.getCurrentPlatform();
    
    var args = try platform_impl.getArgs(allocator);
    defer args.deinit();
    
    // Skip program name
    _ = args.skip();

    const command = args.next() orelse {
        try showUsage(&platform_impl);
        return;
    };

    if (std.mem.eql(u8, command, "init")) {
        try cmdInit(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "status")) {
        try cmdStatus(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "add")) {
        try cmdAdd(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "commit")) {
        try cmdCommit(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "log")) {
        try cmdLog(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "diff")) {
        try cmdDiff(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "branch")) {
        try cmdBranch(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        const target_info = switch (@import("builtin").target.os.tag) {
            .wasi => " (WASI)",
            .freestanding => " (Browser)",
            else => "",
        };
        const version_msg = std.fmt.allocPrint(allocator, "ziggit version 0.1.0{s}\n", .{target_info}) catch "ziggit version 0.1.0\n";
        defer if (version_msg.ptr != "ziggit version 0.1.0\n".ptr) allocator.free(version_msg);
        try platform_impl.writeStdout(version_msg);
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try showUsage(&platform_impl);
    } else {
        const error_msg = std.fmt.allocPrint(allocator, "ziggit: '{s}' is not a ziggit command. See 'ziggit --help'.\n", .{command}) catch "ziggit: invalid command. See 'ziggit --help'.\n";
        defer if (error_msg.ptr != "ziggit: invalid command. See 'ziggit --help'.\n".ptr) allocator.free(error_msg);
        try platform_impl.writeStderr(error_msg);
    }
}

fn showUsage(platform_impl: *const platform_mod.Platform) !void {
    const target_info = switch (@import("builtin").target.os.tag) {
        .wasi => " (WASI)",
        .freestanding => " (Browser)",
        else => "",
    };
    
    try platform_impl.writeStdout("usage: ziggit <command> [<args>]\n\n");
    try platform_impl.writeStdout("These are common ziggit commands used in various situations:\n\n");
    try platform_impl.writeStdout("start a working area (see also: ziggit help tutorial)\n");
    try platform_impl.writeStdout("   init       Create an empty Git repository or reinitialize an existing one\n\n");
    try platform_impl.writeStdout("work on the current change (see also: ziggit help everyday)\n");
    try platform_impl.writeStdout("   add        Add file contents to the index\n");
    try platform_impl.writeStdout("   status     Show the working tree status\n");
    try platform_impl.writeStdout("   commit     Record changes to the repository\n");
    try platform_impl.writeStdout("   log        Show commit logs\n");
    try platform_impl.writeStdout("   diff       Show changes between commits, commit and working tree, etc\n");
    
    if (@import("builtin").target.os.tag != .freestanding) {
        try platform_impl.writeStdout("\n");
        try platform_impl.writeStdout("collaborate (see also: ziggit help workflows)\n");
        try platform_impl.writeStdout("   fetch      Download objects and refs from another repository\n");
        try platform_impl.writeStdout("   pull       Fetch from and integrate with another repository or a local branch\n");
        try platform_impl.writeStdout("   push       Update remote refs along with associated objects\n");
    }
    
    const suffix_msg = std.fmt.allocPrint(std.heap.page_allocator, "\nziggit{s} - A modern version control system written in Zig\n", .{target_info}) catch return;
    defer std.heap.page_allocator.free(suffix_msg);
    try platform_impl.writeStdout(suffix_msg);
}

fn cmdInit(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
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
    
    try initRepository(work_dir, bare, template_dir, allocator, platform_impl);
}

fn initRepository(path: []const u8, bare: bool, template_dir: ?[]const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    _ = template_dir; // TODO: implement template support
    
    const git_dir = if (bare) 
        try allocator.dupe(u8, path)
    else 
        try std.fmt.allocPrint(allocator, "{s}/.git", .{path});
    defer allocator.free(git_dir);
    
    // Create the target directory if it doesn't exist (for non-bare repos)
    if (!bare) {
        platform_impl.fs.makeDir(path) catch |err| switch (err) {
            error.AlreadyExists => {},
            else => return err,
        };
    }

    // Check if .git directory already exists  
    if (platform_impl.fs.exists(git_dir) catch false) {
        const msg = try std.fmt.allocPrint(allocator, "Reinitialized existing Git repository in {s}/\n", .{git_dir});
        defer allocator.free(msg);
        try platform_impl.writeStdout(msg);
        return;
    }

    // Create .git directory structure
    try platform_impl.fs.makeDir(git_dir);

    // Create subdirectories
    const subdirs = [_][]const u8{
        "objects", "refs", "refs/heads", "refs/tags", "hooks", "info"
    };

    for (subdirs) |subdir| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, subdir });
        defer allocator.free(full_path);
        
        try platform_impl.fs.makeDir(full_path);
    }

    // Create HEAD file
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    try platform_impl.fs.writeFile(head_path, "ref: refs/heads/main\n");

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
    try platform_impl.fs.writeFile(config_path, config_content);

    // Create description file
    const desc_path = try std.fmt.allocPrint(allocator, "{s}/description", .{git_dir});
    defer allocator.free(desc_path);
    try platform_impl.fs.writeFile(desc_path, "Unnamed repository; edit this file 'description' to name the repository.\n");

    const success_msg = if (bare)
        try std.fmt.allocPrint(allocator, "Initialized empty Git repository in {s}/\n", .{git_dir})
    else
        try std.fmt.allocPrint(allocator, "Initialized empty Git repository in {s}/.git/\n", .{path});
    defer allocator.free(success_msg);
    try platform_impl.writeStdout(success_msg);
}

fn cmdStatus(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    _ = args; // No args for basic status
    
    // Find .git directory by traversing up
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        return;
    };
    defer allocator.free(git_path);

    try platform_impl.writeStdout("On branch main\n\n");
    
    // Check if there are any commits
    const refs_heads_main_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/main", .{git_path});
    defer allocator.free(refs_heads_main_path);
    
    if (platform_impl.fs.exists(refs_heads_main_path) catch false) {
        try platform_impl.writeStdout("nothing to commit, working tree clean\n");
    } else {
        try platform_impl.writeStdout("No commits yet\n\n");
        try platform_impl.writeStdout("nothing to commit (create/copy files and use \"ziggit add\" to track)\n");
    }
}

fn findGitDirectory(allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) ![]u8 {
    const cwd = try platform_impl.fs.getCwd(allocator);
    defer allocator.free(cwd);
    
    // For now, just check current directory
    const git_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{cwd});
    if (platform_impl.fs.exists(git_path) catch false) {
        return git_path;
    }
    allocator.free(git_path);
    
    return error.NotAGitRepository;
}

fn cmdAdd(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const file_path = args.next() orelse {
        try platform_impl.writeStderr("Nothing specified, nothing added.\n");
        try platform_impl.writeStderr("hint: Maybe you wanted to say 'ziggit add .'?\n");
        return;
    };

    // Simple implementation - just indicate the file would be added
    const msg = try std.fmt.allocPrint(allocator, "ziggit add: '{s}' - add functionality not yet fully implemented\n", .{file_path});
    defer allocator.free(msg);
    try platform_impl.writeStderr(msg);
}

fn cmdCommit(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    _ = args;
    const msg = try std.fmt.allocPrint(allocator, "ziggit commit: not yet implemented\n", .{});
    defer allocator.free(msg);
    try platform_impl.writeStderr(msg);
}

fn cmdLog(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    _ = args;
    const msg = try std.fmt.allocPrint(allocator, "ziggit log: not yet implemented\n", .{});
    defer allocator.free(msg);
    try platform_impl.writeStderr(msg);
}

fn cmdDiff(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    _ = args;
    const msg = try std.fmt.allocPrint(allocator, "ziggit diff: not yet implemented\n", .{});
    defer allocator.free(msg);
    try platform_impl.writeStderr(msg);
}

fn cmdBranch(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    _ = args;
    const msg = try std.fmt.allocPrint(allocator, "ziggit branch: not yet implemented\n", .{});
    defer allocator.free(msg);
    try platform_impl.writeStderr(msg);
}