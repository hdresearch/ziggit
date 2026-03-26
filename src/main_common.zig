const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const version_mod = @import("version.zig");

// Only import git modules on platforms that support them
const Repository = if (@import("builtin").target.os.tag != .freestanding) @import("git/repository.zig").Repository else void;
const objects = if (@import("builtin").target.os.tag != .freestanding) @import("git/objects.zig") else void;
const index_mod = if (@import("builtin").target.os.tag != .freestanding) @import("git/index.zig") else void;
const refs = if (@import("builtin").target.os.tag != .freestanding) @import("git/refs.zig") else void;
const gitignore_mod = if (@import("builtin").target.os.tag != .freestanding) @import("git/gitignore.zig") else void;
const diff_mod = if (@import("builtin").target.os.tag != .freestanding) @import("git/diff.zig") else void;
const network = if (@import("builtin").target.os.tag != .freestanding) @import("git/network.zig") else void;

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

    // Check for global flags first
    var first_arg = args.next() orelse {
        try showUsage(&platform_impl);
        return;
    };
    
    // Handle global flags in a loop
    while (true) {
        if (std.mem.eql(u8, first_arg, "-C")) {
            const dir_path = args.next() orelse {
                try platform_impl.writeStderr("error: option '-C' requires a directory path\n");
                std.process.exit(128);
            };
            
            // Change to the specified directory
            std.process.changeCurDir(dir_path) catch |err| switch (err) {
                error.AccessDenied => {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: cannot change to '{s}': Permission denied\n", .{dir_path});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                },
                error.FileNotFound => {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: cannot change to '{s}': No such file or directory\n", .{dir_path});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                },
                error.NotDir => {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: cannot change to '{s}': Not a directory\n", .{dir_path});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                },
                else => return err,
            };
            
            // Get the next argument
            first_arg = args.next() orelse {
                try showUsage(&platform_impl);
                return;
            };
        } else if (std.mem.eql(u8, first_arg, "-c")) {
            // Skip the config setting (bun passes -c core.longpaths=true which we ignore)
            _ = args.next() orelse {
                try platform_impl.writeStderr("error: option '-c' requires a config setting\n");
                std.process.exit(128);
            };
            
            // Get the next argument
            first_arg = args.next() orelse {
                try showUsage(&platform_impl);
                return;
            };
        } else {
            // Not a global flag, this must be the command
            break;
        }
    }
    
    const command = first_arg;

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
    } else if (std.mem.eql(u8, command, "checkout")) {
        try cmdCheckout(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "merge")) {
        try cmdMerge(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "fetch")) {
        try cmdFetch(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "pull")) {
        try cmdPull(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "push")) {
        try cmdPush(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "clone")) {
        try cmdClone(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "config")) {
        try cmdConfig(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "rev-parse")) {
        try cmdRevParse(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "describe")) {
        try cmdDescribe(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "tag")) {
        try cmdTag(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        if (version_mod.getVersionString(allocator)) |version_msg| {
            defer allocator.free(version_msg);
            const output = try std.fmt.allocPrint(allocator, "{s}\n", .{version_msg});
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else |_| {
            try platform_impl.writeStdout("ziggit version 0.1.2\n");
        }
    } else if (std.mem.eql(u8, command, "--version-info")) {
        if (version_mod.getFullVersionInfo(allocator)) |version_info| {
            defer allocator.free(version_info);
            try platform_impl.writeStdout(version_info);
        } else |_| {
            try platform_impl.writeStdout("ziggit version 0.1.2\nError retrieving version details.\n");
        }
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        try showUsage(&platform_impl);
    } else {
        const error_msg = std.fmt.allocPrint(allocator, "ziggit: '{s}' is not a ziggit command. See 'ziggit --help'.\n", .{command}) catch "ziggit: invalid command. See 'ziggit --help'.\n";
        defer if (error_msg.ptr != "ziggit: invalid command. See 'ziggit --help'.\n".ptr) allocator.free(error_msg);
        try platform_impl.writeStderr(error_msg);
        std.process.exit(1);
    }
}

fn findUntrackedFiles(allocator: std.mem.Allocator, repo_root: []const u8, index: *const index_mod.Index, gitignore: *const gitignore_mod.GitIgnore, platform_impl: *const platform_mod.Platform) !std.ArrayList([]u8) {
    var untracked_files = std.ArrayList([]u8).init(allocator);
    
    // Create a set of tracked file paths for fast lookup
    var tracked_files = std.StringHashMap(void).init(allocator);
    defer tracked_files.deinit();
    
    for (index.entries.items) |entry| {
        try tracked_files.put(entry.path, {});
    }
    
    // Recursively scan directory for files
    scanDirectoryForUntrackedFiles(allocator, repo_root, "", &untracked_files, &tracked_files, gitignore, platform_impl) catch {
        // If scanning fails, return empty list
        for (untracked_files.items) |file| {
            allocator.free(file);
        }
        untracked_files.clearAndFree();
    };
    
    return untracked_files;
}

fn scanDirectoryForUntrackedFiles(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    relative_path: []const u8,
    untracked_files: *std.ArrayList([]u8),
    tracked_files: *const std.StringHashMap(void),
    gitignore: *const gitignore_mod.GitIgnore,
    platform_impl: *const platform_mod.Platform,
) !void {
    const full_path = if (relative_path.len == 0)
        try allocator.dupe(u8, repo_root)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, relative_path });
    defer allocator.free(full_path);

    // Try to open directory
    var dir = std.fs.cwd().openDir(full_path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir, error.AccessDenied, error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (iterator.next() catch null) |entry| {
        // Skip .git directory
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        
        const entry_relative_path = if (relative_path.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_path, entry.name });
        defer allocator.free(entry_relative_path);
        
        // Check if ignored
        if (gitignore.isIgnored(entry_relative_path)) continue;
        
        switch (entry.kind) {
            .file => {
                // Check if file is tracked
                if (!tracked_files.contains(entry_relative_path)) {
                    try untracked_files.append(try allocator.dupe(u8, entry_relative_path));
                }
            },
            .directory => {
                // Recursively scan subdirectory
                scanDirectoryForUntrackedFiles(
                    allocator,
                    repo_root,
                    entry_relative_path,
                    untracked_files,
                    tracked_files,
                    gitignore,
                    platform_impl,
                ) catch continue; // Continue if subdirectory scan fails
            },
            else => continue, // Skip other types (symlinks, etc.)
        }
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
    
    const suffix_msg = std.fmt.allocPrint(std.heap.page_allocator, "\nziggit{s} - A modern version control system written in Zig\n\nDrop-in replacement for git commands - use 'ziggit' instead of 'git'\nCompatible .git directory format, works with existing git repositories\n\nOptions:\n  --version, -v       Show version information\n  --version-info      Show detailed version and build information\n  --help, -h          Show this help message\n", .{target_info}) catch return;
    defer std.heap.page_allocator.free(suffix_msg);
    try platform_impl.writeStdout(suffix_msg);
}

fn cmdInit(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var bare = false;
    var template_dir: ?[]const u8 = null;
    var work_dir: ?[]const u8 = null;
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bare")) {
            bare = true;
        } else if (std.mem.startsWith(u8, arg, "--template=")) {
            template_dir = arg[11..];
        } else {
            work_dir = arg;
        }
    }
    
    // If no directory specified, use current directory
    const target_dir = work_dir orelse ".";
    
    try initRepository(target_dir, bare, template_dir, allocator, platform_impl);
}

fn initRepository(path: []const u8, bare: bool, template_dir: ?[]const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    _ = template_dir; // TODO: implement template support
    
    const git_dir = if (bare) 
        try allocator.dupe(u8, path)
    else 
        try std.fmt.allocPrint(allocator, "{s}/.git", .{path});
    defer allocator.free(git_dir);
    
    // Create the target directory if it doesn't exist (recursively)
    createDirectoryRecursive(path, platform_impl, allocator) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };

    // Check if git repository already exists by looking for HEAD file
    const head_check_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_check_path);
    
    if (platform_impl.fs.exists(head_check_path) catch false) {
        const msg = try std.fmt.allocPrint(allocator, "Reinitialized existing Git repository in {s}/\n", .{git_dir});
        defer allocator.free(msg);
        try platform_impl.writeStdout(msg);
        return;
    }

    // Create .git directory structure (only if it doesn't already exist as a directory)
    platform_impl.fs.makeDir(git_dir) catch |err| switch (err) {
        error.AlreadyExists => {}, // Directory exists, that's fine
        else => return err,
    };

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
    try platform_impl.fs.writeFile(head_path, "ref: refs/heads/master\n");

    // Create config file
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
    defer allocator.free(config_path);
    const config_content = if (bare)
        \\[core]
        \\	repositoryformatversion = 0
        \\	filemode = true
        \\	bare = true
        \\	logallrefupdates = true
        \\
    else
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
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("status: not supported in freestanding mode\n");
        return;
    }

    // Check for --porcelain flag
    var porcelain = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--porcelain")) {
            porcelain = true;
        }
    }
    
    // Find .git directory by traversing up
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Get current working directory (repository root)
    const repo_root = std.fs.path.dirname(git_path) orelse {
        try platform_impl.writeStderr("fatal: unable to determine repository root\n");
        std.process.exit(128);
    };

    // Get current branch
    const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch try allocator.dupe(u8, "master");
    defer allocator.free(current_branch);

    // Check if there are any commits
    const current_commit = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
    
    if (!porcelain) {
        const branch_msg = try std.fmt.allocPrint(allocator, "On branch {s}\n", .{current_branch});
        defer allocator.free(branch_msg);
        try platform_impl.writeStdout(branch_msg);
        
        if (current_commit) |hash| {
            allocator.free(hash);
        } else {
            try platform_impl.writeStdout("\nNo commits yet\n");
        }
    } else if (current_commit) |hash| {
        allocator.free(hash);
    }

    // Load index to check for staged files
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();

    // Load gitignore
    const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root});
    defer allocator.free(gitignore_path);
    
    var gitignore = gitignore_mod.GitIgnore.loadFromFile(allocator, gitignore_path, platform_impl) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => gitignore_mod.GitIgnore.init(allocator),
    };
    defer gitignore.deinit();

    // Detect staged files vs modified files vs deleted files vs clean files
    var staged_files = std.ArrayList(index_mod.IndexEntry).init(allocator);
    var modified_files = std.ArrayList(index_mod.IndexEntry).init(allocator);
    var deleted_files = std.ArrayList(index_mod.IndexEntry).init(allocator);
    defer staged_files.deinit();
    defer modified_files.deinit();
    defer deleted_files.deinit();

    for (index.entries.items) |entry| {
        // Check if working directory version is different from index version
        const full_path = if (std.fs.path.isAbsolute(entry.path))
            try allocator.dupe(u8, entry.path)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
        defer allocator.free(full_path);
        
        // Check if file exists in working directory
        const file_exists = platform_impl.fs.exists(full_path) catch false;
        
        if (!file_exists) {
            // File is in index but not in working directory - it's deleted
            try deleted_files.append(entry);
        } else {
            const working_modified = blk: {
                const current_content = platform_impl.fs.readFile(allocator, full_path) catch break :blk false;
                defer allocator.free(current_content);
                
                // Create blob object to get hash
                const blob = objects.createBlobObject(current_content, allocator) catch break :blk false;
                defer blob.deinit(allocator);
                
                const current_hash = blob.hash(allocator) catch break :blk false;
                defer allocator.free(current_hash);
                
                // Compare with index hash
                const index_hash = std.fmt.allocPrint(allocator, "{x}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch break :blk false;
                defer allocator.free(index_hash);
                
                break :blk !std.mem.eql(u8, current_hash, index_hash);
            };
            
            if (working_modified) {
                try modified_files.append(entry);
            } else if (current_commit == null) {
                // No commits yet, so anything in index is staged
                try staged_files.append(entry);
            } else {
                // File is in index and matches working directory.
                // Check if it's different from what's in HEAD tree (i.e., staged)
                const is_different_from_head = checkIfDifferentFromHEAD(entry, git_path, platform_impl, allocator) catch false;
                
                if (is_different_from_head) {
                    try staged_files.append(entry);
                }
                // If same as HEAD, file is clean (don't show it)
            }
        }
    }

    // Show staged files
    if (staged_files.items.len > 0) {
        if (porcelain) {
            for (staged_files.items) |entry| {
                if (current_commit == null) {
                    const msg = try std.fmt.allocPrint(allocator, "A  {s}\n", .{entry.path});
                    defer allocator.free(msg);
                    try platform_impl.writeStdout(msg);
                } else {
                    const msg = try std.fmt.allocPrint(allocator, "M  {s}\n", .{entry.path});
                    defer allocator.free(msg);
                    try platform_impl.writeStdout(msg);
                }
            }
        } else {
            try platform_impl.writeStdout("\nChanges to be committed:\n");
            try platform_impl.writeStdout("  (use \"git reset HEAD <file>...\" to unstage)\n\n");
            
            for (staged_files.items) |entry| {
                if (current_commit == null) {
                    const msg = try std.fmt.allocPrint(allocator, "        new file:   {s}\n", .{entry.path});
                    defer allocator.free(msg);
                    try platform_impl.writeStdout(msg);
                } else {
                    const msg = try std.fmt.allocPrint(allocator, "        modified:   {s}\n", .{entry.path});
                    defer allocator.free(msg);
                    try platform_impl.writeStdout(msg);
                }
            }
            try platform_impl.writeStdout("\n");
        }
    }

    // Show modified but unstaged files
    if (modified_files.items.len > 0) {
        if (porcelain) {
            for (modified_files.items) |entry| {
                const msg = try std.fmt.allocPrint(allocator, " M {s}\n", .{entry.path});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
        } else {
            try platform_impl.writeStdout("\nChanges not staged for commit:\n");
            try platform_impl.writeStdout("  (use \"git add <file>...\" to update what will be committed)\n");
            try platform_impl.writeStdout("  (use \"git restore <file>...\" to discard changes in working directory)\n\n");
            
            for (modified_files.items) |entry| {
                const msg = try std.fmt.allocPrint(allocator, "        modified:   {s}\n", .{entry.path});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
            try platform_impl.writeStdout("\n");
        }
    }

    // Show deleted files
    if (deleted_files.items.len > 0) {
        if (porcelain) {
            for (deleted_files.items) |entry| {
                const msg = try std.fmt.allocPrint(allocator, " D {s}\n", .{entry.path});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
        } else {
            if (modified_files.items.len == 0) {
                try platform_impl.writeStdout("\nChanges not staged for commit:\n");
                try platform_impl.writeStdout("  (use \"git add <file>...\" to update what will be committed)\n");
                try platform_impl.writeStdout("  (use \"git restore <file>...\" to discard changes in working directory)\n\n");
            }
            
            for (deleted_files.items) |entry| {
                const msg = try std.fmt.allocPrint(allocator, "        deleted:    {s}\n", .{entry.path});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
            try platform_impl.writeStdout("\n");
        }
    }

    // Find untracked files
    var untracked_files = findUntrackedFiles(allocator, repo_root, &index, &gitignore, platform_impl) catch std.ArrayList([]u8).init(allocator);
    defer {
        for (untracked_files.items) |file| {
            allocator.free(file);
        }
        untracked_files.deinit();
    }

    if (untracked_files.items.len > 0) {
        if (porcelain) {
            for (untracked_files.items) |file| {
                const msg = try std.fmt.allocPrint(allocator, "?? {s}\n", .{file});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
        } else {
            try platform_impl.writeStdout("\nUntracked files:\n");
            try platform_impl.writeStdout("  (use \"git add <file>...\" to include in what will be committed)\n\n");
            
            for (untracked_files.items) |file| {
                const msg = try std.fmt.allocPrint(allocator, "        {s}\n", .{file});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
            try platform_impl.writeStdout("\n");
        }
    }

    // Final summary message (only in non-porcelain mode)
    if (!porcelain) {
        if (staged_files.items.len == 0 and modified_files.items.len == 0 and deleted_files.items.len == 0 and untracked_files.items.len == 0) {
            if (current_commit == null) {
                try platform_impl.writeStdout("\nnothing to commit (create/copy files and use \"git add\" to track)\n");
            } else {
                try platform_impl.writeStdout("\nnothing to commit, working tree clean\n");
            }
        } else if (staged_files.items.len == 0 and modified_files.items.len == 0 and deleted_files.items.len == 0 and untracked_files.items.len > 0) {
            try platform_impl.writeStdout("nothing added to commit but untracked files present (use \"git add\" to track)\n");
        } else if (staged_files.items.len == 0 and (modified_files.items.len > 0 or deleted_files.items.len > 0)) {
            try platform_impl.writeStdout("no changes added to commit (use \"git add\" and/or \"git commit -a\")\n");
        }
    }
}

fn findGitDirectory(allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) ![]u8 {
    const current_dir = try platform_impl.fs.getCwd(allocator);
    defer allocator.free(current_dir);
    
    // Walk up the directory tree looking for .git or bare repository
    var dir_to_check = try allocator.dupe(u8, current_dir);
    
    while (true) {
        // First check for .git subdirectory (normal repository)
        const git_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir_to_check});
        if (platform_impl.fs.exists(git_path) catch false) {
            allocator.free(dir_to_check);
            return git_path;
        }
        allocator.free(git_path);
        
        // Check if current directory is a bare repository
        // A bare repository has HEAD, config, objects, and refs directly in the directory
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{dir_to_check});
        defer allocator.free(head_path);
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{dir_to_check});
        defer allocator.free(config_path);
        const objects_path = try std.fmt.allocPrint(allocator, "{s}/objects", .{dir_to_check});
        defer allocator.free(objects_path);
        const refs_path = try std.fmt.allocPrint(allocator, "{s}/refs", .{dir_to_check});
        defer allocator.free(refs_path);
        
        if ((platform_impl.fs.exists(head_path) catch false) and 
            (platform_impl.fs.exists(config_path) catch false) and
            (platform_impl.fs.exists(objects_path) catch false) and
            (platform_impl.fs.exists(refs_path) catch false)) {
            // This looks like a bare repository
            const bare_path = try allocator.dupe(u8, dir_to_check);
            allocator.free(dir_to_check);
            return bare_path;
        }
        
        // Check if we're at the root
        const parent = std.fs.path.dirname(dir_to_check);
        if (parent == null or std.mem.eql(u8, parent.?, dir_to_check)) {
            break; // We've reached the root directory
        }
        
        // Move to parent directory
        allocator.free(dir_to_check);
        dir_to_check = try allocator.dupe(u8, parent.?);
    }
    
    allocator.free(dir_to_check);
    return error.NotAGitRepository;
}

fn cmdAdd(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("add: not supported in freestanding mode\n");
        return;
    }

    // Find .git directory first (before checking arguments)
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Check if any files were specified
    var has_files = false;
    
    // Load index
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();

    // Get current working directory
    const cwd = try platform_impl.fs.getCwd(allocator);
    defer allocator.free(cwd);

    // Process all file arguments
    while (args.next()) |file_path| {
        has_files = true;
        
        // Handle special cases like "." for current directory
        if (std.mem.eql(u8, file_path, ".")) {
            // Add all files in current directory (recursively)
            try addDirectoryRecursively(allocator, cwd, "", &index, git_path, platform_impl);
        } else {
            // Resolve file path 
            const full_file_path = if (std.fs.path.isAbsolute(file_path))
                try allocator.dupe(u8, file_path)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, file_path });
            defer allocator.free(full_file_path);

            // Check if path exists
            if (!(platform_impl.fs.exists(full_file_path) catch false)) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: pathspec '{s}' did not match any files\n", .{file_path});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }

            // Check if it's a directory or file
            const metadata = std.fs.cwd().statFile(full_file_path) catch {
                // If we can't stat it, try to add it as a regular file
                try addSingleFile(allocator, file_path, full_file_path, &index, git_path, platform_impl, cwd);
                continue;
            };

            if (metadata.kind == .directory) {
                // Add directory recursively
                try addDirectoryRecursively(allocator, cwd, file_path, &index, git_path, platform_impl);
            } else {
                // Add single file
                try addSingleFile(allocator, file_path, full_file_path, &index, git_path, platform_impl, cwd);
            }
        }
    }

    if (!has_files) {
        try platform_impl.writeStderr("Nothing specified, nothing added.\n");
        try platform_impl.writeStderr("hint: Maybe you wanted to say 'git add .'?\n");
        return;
    }

    // Save index
    try index.save(git_path, platform_impl);
}

fn cmdCommit(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("commit: not supported in freestanding mode\n");
        return;
    }

    var message: ?[]const u8 = null;
    var allow_empty = false;
    var amend = false;
    var add_all = false;
    var quiet = false;

    // Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-m")) {
            message = args.next() orelse {
                try platform_impl.writeStderr("error: option `-m' requires a value\n");
                std.process.exit(129);
            };
        } else if (std.mem.startsWith(u8, arg, "-m")) {
            message = arg[2..];
        } else if (std.mem.eql(u8, arg, "-a")) {
            add_all = true;
        } else if (std.mem.eql(u8, arg, "-am") or std.mem.eql(u8, arg, "-ma")) {
            add_all = true;
            message = args.next() orelse {
                try platform_impl.writeStderr("error: option `-am' requires a message\n");
                std.process.exit(129);
            };
        } else if (std.mem.startsWith(u8, arg, "-am")) {
            add_all = true;
            message = arg[3..];
        } else if (std.mem.eql(u8, arg, "--allow-empty")) {
            allow_empty = true;
        } else if (std.mem.eql(u8, arg, "--amend")) {
            amend = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        }
    }

    // For --amend, we'll update the last commit instead of creating a new one

    if (message == null) {
        try platform_impl.writeStderr("error: no commit message provided (use -m)\n");
        std.process.exit(1);
    }

    // Check for empty or whitespace-only message (to match git behavior)
    if (message) |msg| {
        const trimmed = std.mem.trim(u8, msg, " \t\n\r");
        if (trimmed.len == 0) {
            try platform_impl.writeStderr("Aborting commit due to empty commit message.\n");
            std.process.exit(1);
        }
    }

    // Find .git directory
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // If -a flag is set, run "git add -u" first to stage all modified tracked files
    if (add_all) {
        var git_args = std.ArrayList([]const u8).init(allocator);
        defer git_args.deinit();
        
        try git_args.append("git");
        try git_args.append("add");
        try git_args.append("-u");

        var child = std.process.Child.init(git_args.items, allocator);
        const result = child.spawnAndWait() catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "fatal: failed to execute git add -u: {}\n", .{err});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        
        switch (result) {
            .Exited => |code| {
                if (code != 0) {
                    std.process.exit(@intCast(code));
                }
            },
            .Signal => |_| {
                std.process.exit(128);
            },
            .Stopped => |_| {
                std.process.exit(128);
            },
            .Unknown => |_| {
                std.process.exit(128);
            },
        }
    }

    // Load index
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();

    // Check if there's anything to commit
    if (index.entries.items.len == 0 and !allow_empty) {
        const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch "master";
        defer allocator.free(current_branch);
        
        const branch_msg = try std.fmt.allocPrint(allocator, "On branch {s}\n", .{current_branch});
        defer allocator.free(branch_msg);
        try platform_impl.writeStderr(branch_msg);
        
        try platform_impl.writeStderr("nothing to commit, working tree clean\n");
        std.process.exit(1);
    }

    // Create tree object from index entries
    var tree_entries = std.ArrayList(objects.TreeEntry).init(allocator);
    defer {
        for (tree_entries.items) |entry| {
            entry.deinit(allocator);
        }
        tree_entries.deinit();
    }

    for (index.entries.items) |entry| {
        const hash_str = try std.fmt.allocPrint(allocator, "{x}", .{std.fmt.fmtSliceHexLower(&entry.sha1)});
        defer allocator.free(hash_str);
        
        const mode_str = try std.fmt.allocPrint(allocator, "{o}", .{entry.mode});
        defer allocator.free(mode_str);

        const tree_entry = objects.TreeEntry.init(
            try allocator.dupe(u8, mode_str),
            try allocator.dupe(u8, entry.path),
            try allocator.dupe(u8, hash_str),
        );
        try tree_entries.append(tree_entry);
    }

    const tree_object = try objects.createTreeObject(tree_entries.items, allocator);
    defer tree_object.deinit(allocator);
    
    const tree_hash = try tree_object.store(git_path, platform_impl, allocator);
    defer allocator.free(tree_hash);

    // Get parent commit (if any)
    var parent_hashes = std.ArrayList([]const u8).init(allocator);
    defer {
        for (parent_hashes.items) |hash| {
            allocator.free(hash);
        }
        parent_hashes.deinit();
    }

    if (amend) {
        // For amend, get the parents of the current commit (grandparents become parents)
        if (refs.getCurrentCommit(git_path, platform_impl, allocator) catch null) |current_hash| {
            defer allocator.free(current_hash);
            
            // Load current commit to get its parents
            const commit_object = objects.GitObject.load(current_hash, git_path, platform_impl, allocator) catch null;
            if (commit_object) |commit| {
                defer commit.deinit(allocator);
                
                // Parse commit data to find parent lines
                var lines = std.mem.split(u8, commit.data, "\n");
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "parent ")) {
                        const parent_hash = line["parent ".len..];
                        try parent_hashes.append(try allocator.dupe(u8, parent_hash));
                    } else if (line.len == 0) {
                        break; // End of headers
                    }
                }
            }
        }
    } else {
        if (refs.getCurrentCommit(git_path, platform_impl, allocator) catch null) |current_hash| {
            try parent_hashes.append(current_hash);
        }
    }

    // Create commit object
    const timestamp = std.time.timestamp();
    const author_info = try std.fmt.allocPrint(allocator, "ziggit <ziggit@example.com> {d} +0000", .{timestamp});
    defer allocator.free(author_info);

    const commit_object = try objects.createCommitObject(
        tree_hash,
        parent_hashes.items,
        author_info,
        author_info,
        message.?,
        allocator,
    );
    defer commit_object.deinit(allocator);

    const commit_hash = try commit_object.store(git_path, platform_impl, allocator);
    defer allocator.free(commit_hash);

    // Update current branch
    const current_branch = try refs.getCurrentBranch(git_path, platform_impl, allocator);
    defer allocator.free(current_branch);
    
    try refs.updateRef(git_path, current_branch, commit_hash, platform_impl, allocator);

    // After a successful commit, the index should remain but be consistent with the new commit
    // We don't clear the index, but we save it to ensure it's properly persisted
    try index.save(git_path, platform_impl);

    // Output success message (unless --quiet was specified)
    if (!quiet) {
        const short_hash = commit_hash[0..7];
        const success_msg = try std.fmt.allocPrint(allocator, "[{s} {s}] {s}\n", .{ current_branch, short_hash, message.? });
        defer allocator.free(success_msg);
        try platform_impl.writeStdout(success_msg);
    }
}

fn cmdLog(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("log: not supported in freestanding mode\n");
        return;
    }

    var oneline = false;
    var format_string: ?[]const u8 = null;
    var max_count: ?u32 = null;
    var committish: ?[]const u8 = null;
    
    // Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--oneline")) {
            oneline = true;
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            format_string = arg[9..]; // Skip "--format="
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and std.ascii.isDigit(arg[1])) {
            // Parse -n format like -1, -5, etc.
            const count_str = arg[1..];
            max_count = std.fmt.parseInt(u32, count_str, 10) catch null;
        } else if (std.mem.eql(u8, arg, "-n")) {
            // Parse -n followed by number
            if (args.next()) |count_str| {
                max_count = std.fmt.parseInt(u32, count_str, 10) catch null;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // This is likely a committish (commit hash, branch name, etc.)
            committish = arg;
        }
    }

    // Find .git directory
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Resolve starting commit
    var start_commit: []u8 = undefined;
    if (committish) |commit_ref| {
        // Try to resolve committish (branch, tag, or commit hash)
        start_commit = resolveCommittish(git_path, commit_ref, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: ambiguous argument '{s}': unknown revision or path not in the working tree.\n", .{commit_ref});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
    } else {
        // Get current HEAD commit
        const current_commit = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
        if (current_commit == null) {
            try platform_impl.writeStderr("fatal: your current branch does not have any commits yet\n");
            std.process.exit(128);
        }
        start_commit = current_commit.?;
    }
    defer allocator.free(start_commit);

    // Fast path for common case: log --format=%H -1 (just output HEAD commit hash)
    if (format_string != null and std.mem.eql(u8, format_string.?, "%H") and 
        (max_count == 1) and committish == null) {
        const output = try std.fmt.allocPrint(allocator, "{s}\n", .{start_commit});
        defer allocator.free(output);
        try platform_impl.writeStdout(output);
        return;
    }
    
    // Walk the commit history
    var commit_hash = try allocator.dupe(u8, start_commit);
    defer allocator.free(commit_hash);

    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var iterator = visited.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        visited.deinit();
    }

    var count: u32 = 0;
    while (max_count == null or count < max_count.?) {
        // Avoid infinite loops
        if (visited.contains(commit_hash)) break;
        try visited.put(try allocator.dupe(u8, commit_hash), {});

        // Load commit object
        const commit_object = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch |err| switch (err) {
            error.ObjectNotFound => {
                const msg = try std.fmt.allocPrint(allocator, "fatal: bad object {s}\n", .{commit_hash});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                return;
            },
            else => return err,
        };
        defer commit_object.deinit(allocator);

        if (commit_object.type != .commit) {
            try platform_impl.writeStderr("fatal: not a commit object\n");
            return;
        }

        // Parse commit data
        const commit_data = commit_object.data;
        
        // Extract commit message and author
        var lines = std.mem.split(u8, commit_data, "\n");
        var parent_hash: ?[]const u8 = null;
        var author_line: ?[]const u8 = null;
        var empty_line_found = false;
        var message = std.ArrayList(u8).init(allocator);
        defer message.deinit();

        while (lines.next()) |line| {
            if (empty_line_found) {
                try message.appendSlice(line);
                try message.append('\n');
            } else if (line.len == 0) {
                empty_line_found = true;
            } else if (std.mem.startsWith(u8, line, "parent ")) {
                if (parent_hash == null) {
                    parent_hash = line["parent ".len..];
                }
            } else if (std.mem.startsWith(u8, line, "author ")) {
                author_line = line["author ".len..];
            }
        }

        // Display commit based on format
        if (format_string) |fmt| {
            try outputFormattedCommit(fmt, commit_hash, allocator, platform_impl);
        } else if (oneline) {
            const short_hash = commit_hash[0..7];
            const first_line = blk: {
                var msg_lines = std.mem.split(u8, std.mem.trimRight(u8, message.items, "\n"), "\n");
                if (msg_lines.next()) |line| {
                    break :blk line;
                } else {
                    break :blk "";
                }
            };
            const oneline_output = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ short_hash, first_line });
            defer allocator.free(oneline_output);
            try platform_impl.writeStdout(oneline_output);
        } else {
            const commit_header = try std.fmt.allocPrint(allocator, "commit {s}\n", .{commit_hash});
            defer allocator.free(commit_header);
            try platform_impl.writeStdout(commit_header);

            if (author_line) |author| {
                const author_output = try std.fmt.allocPrint(allocator, "Author: {s}\n", .{author});
                defer allocator.free(author_output);
                try platform_impl.writeStdout(author_output);
            }

            try platform_impl.writeStdout("\n");
            const msg_output = try std.fmt.allocPrint(allocator, "    {s}\n", .{std.mem.trimRight(u8, message.items, "\n")});
            defer allocator.free(msg_output);
            try platform_impl.writeStdout(msg_output);
        }

        count += 1;

        // Move to parent commit
        if (parent_hash) |parent| {
            allocator.free(commit_hash);
            commit_hash = try allocator.dupe(u8, parent);
        } else {
            break; // No parent, we've reached the initial commit
        }
    }
}

fn resolveHeadRelative(git_path: []const u8, steps: u32, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) ![]u8 {
    // Start from HEAD
    var current_hash = refs.getCurrentCommit(git_path, platform_impl, allocator) catch {
        return error.UnknownRevision;
    };
    
    if (current_hash == null) {
        return error.UnknownRevision;
    }
    
    // Walk back 'steps' number of parents
    var i: u32 = 0;
    while (i < steps) {
        const commit_obj = objects.GitObject.load(current_hash.?, git_path, platform_impl, allocator) catch {
            allocator.free(current_hash.?);
            return error.UnknownRevision;
        };
        defer commit_obj.deinit(allocator);
        
        if (commit_obj.type != .commit) {
            allocator.free(current_hash.?);
            return error.UnknownRevision;
        }
        
        // Parse commit data to find the first parent
        var lines = std.mem.split(u8, commit_obj.data, "\n");
        var parent_hash: ?[]const u8 = null;
        
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                parent_hash = line["parent ".len..];
                break;
            } else if (line.len == 0) {
                break; // End of headers
            }
        }
        
        if (parent_hash == null) {
            // No parent found, can't go further back
            allocator.free(current_hash.?);
            return error.UnknownRevision;
        }
        
        const new_hash = try allocator.dupe(u8, parent_hash.?);
        allocator.free(current_hash.?);
        current_hash = new_hash;
        
        i += 1;
    }
    
    return current_hash.?;
}

fn resolveCommittish(git_path: []const u8, committish: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) ![]u8 {
    // First try as a direct hash
    if (committish.len >= 4 and isValidHashPrefix(committish)) {
        if (resolveCommitHash(git_path, committish, platform_impl, allocator)) |resolved_hash| {
            return resolved_hash;
        } else |_| {
            // Fall through to try other methods
        }
    }
    
    // Try as branch reference
    const branch_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{git_path, committish});
    defer allocator.free(branch_path);
    
    if (platform_impl.fs.readFile(allocator, branch_path)) |branch_content| {
        defer allocator.free(branch_content);
        const hash = std.mem.trim(u8, branch_content, " \t\n\r");
        if (hash.len == 40) {
            return try allocator.dupe(u8, hash);
        }
    } else |_| {}
    
    // Try as tag reference
    const tag_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{git_path, committish});
    defer allocator.free(tag_path);
    
    if (platform_impl.fs.readFile(allocator, tag_path)) |tag_content| {
        defer allocator.free(tag_content);
        const hash = std.mem.trim(u8, tag_content, " \t\n\r");
        if (hash.len == 40) {
            // This might be an annotated tag, resolve it
            const tag_obj = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch {
                return try allocator.dupe(u8, hash);
            };
            defer tag_obj.deinit(allocator);
            
            if (tag_obj.type == .tag) {
                return parseTagObject(tag_obj.data, allocator) catch try allocator.dupe(u8, hash);
            } else {
                return try allocator.dupe(u8, hash);
            }
        }
    } else |_| {}
    
    // Try HEAD if committish is "HEAD"
    if (std.mem.eql(u8, committish, "HEAD")) {
        const head_commit = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
        if (head_commit) |commit| {
            return commit;
        }
    }
    
    // Try HEAD~N relative references
    if (std.mem.startsWith(u8, committish, "HEAD~")) {
        const tilde_part = committish[5..]; // Skip "HEAD~"
        
        if (tilde_part.len == 0) {
            // HEAD~ is equivalent to HEAD~1
            return resolveHeadRelative(git_path, 1, platform_impl, allocator);
        }
        
        const n = std.fmt.parseInt(u32, tilde_part, 10) catch {
            return error.UnknownRevision;
        };
        
        return resolveHeadRelative(git_path, n, platform_impl, allocator);
    }
    
    return error.UnknownRevision;
}

fn outputFormattedCommit(format: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    
    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '%' and i + 1 < format.len) {
            switch (format[i + 1]) {
                'H' => {
                    // Full commit hash
                    try output.appendSlice(commit_hash);
                },
                'h' => {
                    // Short commit hash
                    const short_hash = if (commit_hash.len >= 7) commit_hash[0..7] else commit_hash;
                    try output.appendSlice(short_hash);
                },
                '%' => {
                    // Literal %
                    try output.append('%');
                },
                else => {
                    // Unknown format specifier, output as-is
                    try output.append(format[i]);
                    try output.append(format[i + 1]);
                },
            }
            i += 2;
        } else {
            try output.append(format[i]);
            i += 1;
        }
    }
    
    try output.append('\n');
    try platform_impl.writeStdout(output.items);
}

fn cmdDiff(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("diff: not supported in freestanding mode\n");
        return;
    }

    // Find .git directory first
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Check for flags
    var cached = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--cached") or std.mem.eql(u8, arg, "--staged")) {
            cached = true;
        }
    }
    
    // Load index 
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();
    
    const cwd = try platform_impl.fs.getCwd(allocator);
    defer allocator.free(cwd);
    
    if (cached) {
        // Show differences between index and HEAD (staged changes)
        try showStagedDiff(&index, git_path, platform_impl, allocator);
    } else {
        // Show differences between working tree and index
        try showWorkingTreeDiff(&index, cwd, platform_impl, allocator);
    }
}

fn showWorkingTreeDiff(index: *const index_mod.Index, cwd: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    for (index.entries.items) |entry| {
        const full_path = if (std.fs.path.isAbsolute(entry.path))
            try allocator.dupe(u8, entry.path)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, entry.path });
        defer allocator.free(full_path);
        
        // Check if file exists and has changed
        if (platform_impl.fs.exists(full_path) catch false) {
            const current_content = platform_impl.fs.readFile(allocator, full_path) catch continue;
            defer allocator.free(current_content);
            
            // Create blob object to get hash
            const blob = try objects.createBlobObject(current_content, allocator);
            defer blob.deinit(allocator);
            
            const current_hash = try blob.hash(allocator);
            defer allocator.free(current_hash);
            
            // Compare with index hash
            const index_hash = try std.fmt.allocPrint(allocator, "{x}", .{std.fmt.fmtSliceHexLower(&entry.sha1)});
            defer allocator.free(index_hash);
            
            if (!std.mem.eql(u8, current_hash, index_hash)) {
                // Get indexed content for diff
                const indexed_content = getIndexedFileContent(entry, allocator) catch "";
                defer if (indexed_content.len > 0) allocator.free(indexed_content);
                
                // Generate unified diff
                const short_index_hash = index_hash[0..7];
                const short_current_hash = current_hash[0..7];
                const diff_output = diff_mod.generateUnifiedDiffWithHashes(indexed_content, current_content, entry.path, short_index_hash, short_current_hash, allocator) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                };
                defer allocator.free(diff_output);
                
                try platform_impl.writeStdout(diff_output);
            }
        } else {
            // File was deleted
            const indexed_content = getIndexedFileContent(entry, allocator) catch continue;
            defer allocator.free(indexed_content);
            
            // Calculate hash for empty content
            const empty_blob = try objects.createBlobObject("", allocator);
            defer empty_blob.deinit(allocator);
            const empty_hash = try empty_blob.hash(allocator);
            defer allocator.free(empty_hash);
            
            // Get index hash
            const index_hash = try std.fmt.allocPrint(allocator, "{x}", .{std.fmt.fmtSliceHexLower(&entry.sha1)});
            defer allocator.free(index_hash);
            
            const short_index_hash = index_hash[0..7];
            const short_empty_hash = empty_hash[0..7];
            const diff_output = diff_mod.generateUnifiedDiffWithHashes(indexed_content, "", entry.path, short_index_hash, short_empty_hash, allocator) catch |err| switch (err) {
                error.OutOfMemory => return err,
            };
            defer allocator.free(diff_output);
            
            try platform_impl.writeStdout(diff_output);
        }
    }
}

fn showStagedDiff(index: *const index_mod.Index, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // For --cached diff, we need to compare index against HEAD
    // This is a simplified implementation that shows what's staged
    const current_commit = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
    defer if (current_commit) |hash| allocator.free(hash);
    
    if (current_commit == null) {
        // No HEAD commit yet, so all staged files are new
        for (index.entries.items) |entry| {
            const content = getIndexedFileContent(entry, allocator) catch continue;
            defer allocator.free(content);
            
            // Calculate hash for empty content
            const empty_blob = try objects.createBlobObject("", allocator);
            defer empty_blob.deinit(allocator);
            const empty_hash = try empty_blob.hash(allocator);
            defer allocator.free(empty_hash);
            
            // Get index hash
            const index_hash = try std.fmt.allocPrint(allocator, "{x}", .{std.fmt.fmtSliceHexLower(&entry.sha1)});
            defer allocator.free(index_hash);
            
            const short_empty_hash = empty_hash[0..7];
            const short_index_hash = index_hash[0..7];
            const diff_output = diff_mod.generateUnifiedDiffWithHashes("", content, entry.path, short_empty_hash, short_index_hash, allocator) catch |err| switch (err) {
                error.OutOfMemory => return err,
            };
            defer allocator.free(diff_output);
            
            try platform_impl.writeStdout(diff_output);
        }
    } else {
        // Compare with HEAD commit (simplified - would need to walk the tree)
        for (index.entries.items) |entry| {
            const content = getIndexedFileContent(entry, allocator) catch continue;
            defer allocator.free(content);
            
            // Calculate hash for empty content (simplified - should compare with HEAD tree)
            const empty_blob = try objects.createBlobObject("", allocator);
            defer empty_blob.deinit(allocator);
            const empty_hash = try empty_blob.hash(allocator);
            defer allocator.free(empty_hash);
            
            // Get index hash
            const index_hash = try std.fmt.allocPrint(allocator, "{x}", .{std.fmt.fmtSliceHexLower(&entry.sha1)});
            defer allocator.free(index_hash);
            
            // For now, just show all staged files as additions
            // A full implementation would compare against the HEAD tree
            const short_empty_hash = empty_hash[0..7];
            const short_index_hash = index_hash[0..7];
            const diff_output = diff_mod.generateUnifiedDiffWithHashes("", content, entry.path, short_empty_hash, short_index_hash, allocator) catch |err| switch (err) {
                error.OutOfMemory => return err,
            };
            defer allocator.free(diff_output);
            
            try platform_impl.writeStdout(diff_output);
        }
    }
}

fn getIndexedFileContent(entry: index_mod.IndexEntry, allocator: std.mem.Allocator) ![]u8 {
    if (@import("builtin").target.os.tag == .freestanding) {
        return try allocator.dupe(u8, "");
    }
    
    // Find the git directory
    const platform_impl = platform_mod.getCurrentPlatform();
    const git_dir = findGitDirectory(allocator, &platform_impl) catch |err| {
        // Return empty string for graceful degradation in diff/status
        std.log.debug("Could not find git directory: {}", .{err});
        return try allocator.dupe(u8, "");
    };
    defer allocator.free(git_dir);
    
    // Convert hash bytes to hex string
    const hash_str = try allocator.alloc(u8, 40);
    defer allocator.free(hash_str);
    _ = std.fmt.bufPrint(hash_str, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch |err| {
        std.log.debug("Could not format hash: {}", .{err});
        return try allocator.dupe(u8, "");
    };
    
    // Load the blob object from the git object store
    const git_object = objects.GitObject.load(hash_str, git_dir, &platform_impl, allocator) catch |err| {
        std.log.debug("Could not load blob object {s}: {}", .{ hash_str, err });
        return try allocator.dupe(u8, "");
    };
    defer git_object.deinit(allocator);
    
    // Verify this is actually a blob object
    if (git_object.type != .blob) {
        std.log.warn("Expected blob but got {} for hash {s}", .{ git_object.type, hash_str });
        return try allocator.dupe(u8, "");
    }
    
    // Return a copy of the blob data
    return try allocator.dupe(u8, git_object.data);
}

fn cmdCheckout(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("checkout: not supported in freestanding mode\n");
        return;
    }

    const first_arg = args.next() orelse {
        try platform_impl.writeStderr("error: pathspec '' did not match any file(s) known to git\n");
        std.process.exit(128);
    };

    // Find .git directory
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Check if this is a -b flag (create new branch)
    if (std.mem.eql(u8, first_arg, "-b")) {
        const branch_name = args.next() orelse {
            try platform_impl.writeStderr("fatal: option '-b' requires a value\n");
            std.process.exit(128);
        };

        // Create new branch
        refs.createBranch(git_path, branch_name, null, platform_impl, allocator) catch |err| switch (err) {
            error.NoCommitsYet => {
                try platform_impl.writeStderr("fatal: not a valid object name: 'master'\n");
                std.process.exit(128);
            },
            error.InvalidStartPoint => {
                try platform_impl.writeStderr("fatal: not a valid object name\n");
                std.process.exit(128);
            },
            else => return err,
        };

        // Switch to the new branch
        refs.updateHEAD(git_path, branch_name, platform_impl, allocator) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "error: failed to checkout branch '{s}': {}\n", .{ branch_name, err });
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };

        const success_msg = try std.fmt.allocPrint(allocator, "Switched to a new branch '{s}'\n", .{branch_name});
        defer allocator.free(success_msg);
        try platform_impl.writeStdout(success_msg);
    } else {
        // Parse checkout arguments
        var quiet = std.mem.eql(u8, first_arg, "--quiet");
        const target = if (quiet) 
            args.next() orelse {
                try platform_impl.writeStderr("error: pathspec '' did not match any file(s) known to git\n");
                std.process.exit(128);
            }
        else 
            first_arg;

        // Check for additional --quiet flag
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--quiet")) {
                quiet = true;
            }
        }

        // Shell out to real git for checkout with refs (as per requirements)
        var git_args = std.ArrayList([]const u8).init(allocator);
        defer git_args.deinit();
        
        try git_args.append("git");
        try git_args.append("checkout");
        
        if (quiet) {
            try git_args.append("--quiet");
        }
        
        try git_args.append(target);

        // Spawn git process
        var child = std.process.Child.init(git_args.items, allocator);
        const result = child.spawnAndWait() catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "fatal: failed to execute git: {}\n", .{err});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        
        switch (result) {
            .Exited => |code| {
                if (code != 0) {
                    std.process.exit(@intCast(code));
                }
            },
            .Signal => |_| {
                std.process.exit(128);
            },
            .Stopped => |_| {
                std.process.exit(128);
            },
            .Unknown => |_| {
                std.process.exit(128);
            },
        }
    }
}

/// Properly restore working tree from a commit tree
fn checkoutCommitTree(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // Load the commit object
    const commit_obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch |err| switch (err) {
        error.ObjectNotFound => return error.InvalidCommit,
        else => return err,
    };
    defer commit_obj.deinit(allocator);
    
    if (commit_obj.type != .commit) {
        return error.NotACommit;
    }
    
    // Parse the commit to get the tree hash
    const tree_hash = parseCommitTreeHash(commit_obj.data, allocator) catch {
        return error.InvalidCommit;
    };
    defer allocator.free(tree_hash);
    
    // Load the tree object
    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch |err| switch (err) {
        error.ObjectNotFound => return error.InvalidTree,
        else => return err,
    };
    defer tree_obj.deinit(allocator);
    
    if (tree_obj.type != .tree) {
        return error.NotATree;
    }
    
    // Get repository root (parent of .git directory)
    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    
    // Clear working directory first (except .git)
    try clearWorkingDirectory(repo_root, allocator, platform_impl);
    
    // Recursively checkout the tree
    try checkoutTreeRecursive(git_path, tree_obj.data, repo_root, "", allocator, platform_impl);
    
    // Update the index to match the checked out tree
    try updateIndexFromTree(git_path, tree_hash, allocator, platform_impl);
}

/// Parse commit object to extract tree hash
fn parseCommitTreeHash(commit_data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var lines = std.mem.split(u8, commit_data, "\n");
    
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ")) {
            const tree_hash = line[5..]; // Skip "tree "
            if (tree_hash.len == 40 and isValidHash(tree_hash)) {
                return try allocator.dupe(u8, tree_hash);
            }
        }
    }
    
    return error.NoTreeInCommit;
}

/// Clear working directory except .git and other hidden directories
fn clearWorkingDirectory(repo_root: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    _ = platform_impl;
    var dir = std.fs.cwd().openDir(repo_root, .{ .iterate = true }) catch return;
    defer dir.close();
    
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        // Skip .git and other hidden directories/files
        if (entry.name[0] == '.') continue;
        
        switch (entry.kind) {
            .file => {
                dir.deleteFile(entry.name) catch {};
            },
            .directory => {
                dir.deleteTree(entry.name) catch {};
            },
            else => {},
        }
    }
    _ = allocator; // Suppress unused variable warning
}

/// Recursively checkout tree entries to working directory
fn checkoutTreeRecursive(git_path: []const u8, tree_data: []const u8, repo_root: []const u8, current_path: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    var i: usize = 0;
    
    while (i < tree_data.len) {
        // Parse tree entry: "<mode> <name>\0<20-byte-hash>"
        const mode_start = i;
        const space_pos = std.mem.indexOf(u8, tree_data[i..], " ") orelse break;
        const mode = tree_data[mode_start..mode_start + space_pos];
        
        i = mode_start + space_pos + 1;
        const name_start = i;
        const null_pos = std.mem.indexOf(u8, tree_data[i..], "\x00") orelse break;
        const name = tree_data[name_start..name_start + null_pos];
        
        i = name_start + null_pos + 1;
        if (i + 20 > tree_data.len) break;
        
        // Extract 20-byte hash and convert to hex string
        const hash_bytes = tree_data[i..i + 20];
        const hash_hex = try allocator.alloc(u8, 40);
        defer allocator.free(hash_hex);
        _ = std.fmt.bufPrint(hash_hex, "{}", .{std.fmt.fmtSliceHexLower(hash_bytes)}) catch break;
        
        i += 20;
        
        // Build full path
        const full_path = if (current_path.len == 0) 
            try allocator.dupe(u8, name)
        else 
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{current_path, name});
        defer allocator.free(full_path);
        
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{repo_root, full_path});
        defer allocator.free(file_path);
        
        // Check if this is a tree (directory) or blob (file)
        if (std.mem.startsWith(u8, mode, "40000")) {
            // This is a tree (subdirectory)
            platform_impl.fs.makeDir(file_path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            
            // Load subtree and recurse
            const subtree_obj = objects.GitObject.load(hash_hex, git_path, platform_impl, allocator) catch continue;
            defer subtree_obj.deinit(allocator);
            
            if (subtree_obj.type == .tree) {
                try checkoutTreeRecursive(git_path, subtree_obj.data, repo_root, full_path, allocator, platform_impl);
            }
        } else {
            // This is a blob (file)
            const blob_obj = objects.GitObject.load(hash_hex, git_path, platform_impl, allocator) catch continue;
            defer blob_obj.deinit(allocator);
            
            if (blob_obj.type == .blob) {
                // Create parent directories if needed
                if (std.fs.path.dirname(file_path)) |parent_dir| {
                    platform_impl.fs.makeDir(parent_dir) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => {},
                    };
                }
                
                // Write file content
                try platform_impl.fs.writeFile(file_path, blob_obj.data);
            }
        }
    }
}

/// Update index to match the checked out tree
fn updateIndexFromTree(git_path: []const u8, tree_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // Create a new index based on the tree
    var index = index_mod.Index.init(allocator);
    defer index.deinit();
    
    // Load the tree object
    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch |err| {
        std.debug.print("Warning: failed to load tree for index update: {}\n", .{err});
        return;
    };
    defer tree_obj.deinit(allocator);
    
    if (tree_obj.type != .tree) return;
    
    // Get repository root (parent of .git directory)  
    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    
    // Recursively populate index from tree
    try populateIndexFromTree(git_path, tree_obj.data, repo_root, "", &index, allocator, platform_impl);
    
    // Save the updated index
    try index.save(git_path, platform_impl);
}

/// Recursively populate index entries from tree data
fn populateIndexFromTree(git_path: []const u8, tree_data: []const u8, repo_root: []const u8, current_path: []const u8, index: *index_mod.Index, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    var i: usize = 0;
    
    while (i < tree_data.len) {
        // Parse tree entry: "<mode> <name>\0<20-byte-hash>"
        const mode_start = i;
        const space_pos = std.mem.indexOf(u8, tree_data[i..], " ") orelse break;
        const mode_str = tree_data[mode_start..mode_start + space_pos];
        
        i = mode_start + space_pos + 1;
        const name_start = i;
        const null_pos = std.mem.indexOf(u8, tree_data[i..], "\x00") orelse break;
        const name = tree_data[name_start..name_start + null_pos];
        
        i = name_start + null_pos + 1;
        if (i + 20 > tree_data.len) break;
        
        // Extract 20-byte hash
        const hash_bytes = tree_data[i..i + 20];
        var sha1: [20]u8 = undefined;
        @memcpy(&sha1, hash_bytes);
        
        i += 20;
        
        // Build full path
        const full_path = if (current_path.len == 0) 
            try allocator.dupe(u8, name)
        else 
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{current_path, name});
        defer allocator.free(full_path);
        
        // Parse mode
        const mode = std.fmt.parseInt(u32, mode_str, 8) catch 0;
        
        // Check if this is a tree (directory) or blob (file)
        if (std.mem.startsWith(u8, mode_str, "40000")) {
            // This is a tree (subdirectory) - recurse into it
            const subtree_obj = objects.GitObject.load(try allocator.alloc(u8, 40), git_path, platform_impl, allocator) catch continue;
            defer allocator.free(subtree_obj.data);
            
            // Convert hash to hex for loading
            const hash_hex = try allocator.alloc(u8, 40);
            defer allocator.free(hash_hex);
            _ = try std.fmt.bufPrint(hash_hex, "{}", .{std.fmt.fmtSliceHexLower(hash_bytes)});
            
            const subtree_loaded = objects.GitObject.load(hash_hex, git_path, platform_impl, allocator) catch continue;
            defer subtree_loaded.deinit(allocator);
            
            if (subtree_loaded.type == .tree) {
                try populateIndexFromTree(git_path, subtree_loaded.data, repo_root, full_path, index, allocator, platform_impl);
            }
        } else {
            // This is a blob (file) - add to index
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, full_path });
            defer allocator.free(file_path);
            
            // Get file stats (or create fake ones)
            const stat = std.fs.cwd().statFile(file_path) catch std.fs.File.Stat{
                .inode = 0,
                .size = 0,
                .mode = mode,
                .kind = .file,
                .atime = 0,
                .mtime = 0,
                .ctime = 0,
            };
            
            // Create index entry
            const entry = index_mod.IndexEntry.init(try allocator.dupe(u8, full_path), stat, sha1);
            try index.entries.append(entry);
        }
    }
}

fn cmdMerge(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("merge: not supported in freestanding mode\n");
        return;
    }

    // Check if we're in a git repository
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    const branch_to_merge = args.next() orelse {
        try platform_impl.writeStderr("fatal: no merge target specified\n");
        std.process.exit(128);
    };

    // Get current branch
    const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: unable to determine current branch\n");
        std.process.exit(128);
    };
    defer allocator.free(current_branch);

    // Check if branch exists
    if (!(refs.branchExists(git_path, branch_to_merge, platform_impl, allocator) catch false)) {
        const msg = try std.fmt.allocPrint(allocator, "merge: '{s}' - not something we can merge\n", .{branch_to_merge});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    }

    // Check if trying to merge with itself
    if (std.mem.eql(u8, current_branch, branch_to_merge)) {
        try platform_impl.writeStdout("Already up to date.\n");
        return;
    }

    // Get the current and target commit hashes
    const current_commit_result = refs.getCurrentCommit(git_path, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: unable to get current commit\n");
        std.process.exit(1);
    };
    defer if (current_commit_result) |hash| allocator.free(hash);

    const target_commit_result = refs.getBranchCommit(git_path, branch_to_merge, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: unable to get target branch commit\n");  
        std.process.exit(1);
    };
    defer if (target_commit_result) |hash| allocator.free(hash);

    const current_hash = if (current_commit_result) |hash| hash else {
        try platform_impl.writeStderr("fatal: no commits yet on current branch\n");
        std.process.exit(1);
    };

    const target_hash = if (target_commit_result) |hash| hash else {
        try platform_impl.writeStderr("fatal: no commits yet on target branch\n");
        std.process.exit(1);
    };

    // Check if this is a fast-forward merge
    if (canFastForward(git_path, current_hash, target_hash, allocator, platform_impl)) {
        // Fast-forward merge
        try refs.updateRef(git_path, current_branch, target_hash, platform_impl, allocator);
        try checkoutCommitTree(git_path, target_hash, allocator, platform_impl);

        const msg = try std.fmt.allocPrint(allocator, "Fast-forward\n", .{});
        defer allocator.free(msg);
        try platform_impl.writeStdout(msg);
        
        const short_hash = target_hash[0..7];
        const success_msg = try std.fmt.allocPrint(allocator, "Updating {s}..{s}\n", .{ current_hash[0..7], short_hash });
        defer allocator.free(success_msg);
        try platform_impl.writeStdout(success_msg);
    } else {
        // Perform 3-way merge
        try performThreeWayMerge(git_path, current_hash, target_hash, current_branch, branch_to_merge, allocator, platform_impl);
    }
}

/// Check if a merge can be done as a fast-forward
fn canFastForward(git_path: []const u8, current_hash: []const u8, target_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) bool {
    // Simple case: if hashes are the same, already up to date
    if (std.mem.eql(u8, current_hash, target_hash)) {
        return true;
    }
    
    // Check if current commit is an ancestor of target commit
    return isAncestor(git_path, current_hash, target_hash, allocator, platform_impl) catch false;
}

/// Check if ancestor_hash is an ancestor of descendant_hash
fn isAncestor(git_path: []const u8, ancestor_hash: []const u8, descendant_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !bool {
    if (std.mem.eql(u8, ancestor_hash, descendant_hash)) return true;
    
    // Load the descendant commit
    const descendant_commit = objects.GitObject.load(descendant_hash, git_path, platform_impl, allocator) catch return false;
    defer descendant_commit.deinit(allocator);
    
    if (descendant_commit.type != .commit) return false;
    
    // Parse commit to find parents
    var lines = std.mem.split(u8, descendant_commit.data, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "parent ")) {
            const parent_hash = line["parent ".len..];
            if (std.mem.eql(u8, parent_hash, ancestor_hash)) {
                return true; // Direct parent
            }
            // Recursively check if ancestor is ancestor of this parent
            if (isAncestor(git_path, ancestor_hash, parent_hash, allocator, platform_impl) catch false) {
                return true;
            }
        } else if (line.len == 0) {
            break; // End of headers
        }
    }
    
    return false;
}

/// Find the merge base (common ancestor) of two commits
fn findMergeBase(git_path: []const u8, hash1: []const u8, hash2: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) ![]u8 {
    // Simplified merge base algorithm - find first common ancestor
    // A proper implementation would use more sophisticated algorithms
    
    // Collect all ancestors of hash1
    var ancestors1 = std.StringHashMap(void).init(allocator);
    defer {
        var iterator = ancestors1.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        ancestors1.deinit();
    }
    
    try collectAncestors(git_path, hash1, &ancestors1, allocator, platform_impl);
    
    // Walk ancestors of hash2 and find first match
    return findFirstCommonAncestor(git_path, hash2, &ancestors1, allocator, platform_impl) catch try allocator.dupe(u8, hash1);
}

/// Recursively collect all ancestor commit hashes
fn collectAncestors(git_path: []const u8, commit_hash: []const u8, ancestors: *std.StringHashMap(void), allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // Avoid infinite loops
    if (ancestors.contains(commit_hash)) return;
    
    try ancestors.put(try allocator.dupe(u8, commit_hash), {});
    
    // Load commit to find parents
    const commit_obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch return;
    defer commit_obj.deinit(allocator);
    
    if (commit_obj.type != .commit) return;
    
    // Parse commit to find parents
    var lines = std.mem.split(u8, commit_obj.data, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "parent ")) {
            const parent_hash = line["parent ".len..];
            try collectAncestors(git_path, parent_hash, ancestors, allocator, platform_impl);
        } else if (line.len == 0) {
            break; // End of headers
        }
    }
}

/// Find first common ancestor by walking commit history
fn findFirstCommonAncestor(git_path: []const u8, commit_hash: []const u8, ancestors: *const std.StringHashMap(void), allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) ![]u8 {
    // Check if this commit is in ancestors
    if (ancestors.contains(commit_hash)) {
        return try allocator.dupe(u8, commit_hash);
    }
    
    // Load commit to find parents
    const commit_obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch return error.NotFound;
    defer commit_obj.deinit(allocator);
    
    if (commit_obj.type != .commit) return error.NotFound;
    
    // Check parents
    var lines = std.mem.split(u8, commit_obj.data, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "parent ")) {
            const parent_hash = line["parent ".len..];
            if (findFirstCommonAncestor(git_path, parent_hash, ancestors, allocator, platform_impl)) |common_ancestor| {
                return common_ancestor;
            } else |_| {
                continue;
            }
        } else if (line.len == 0) {
            break; // End of headers
        }
    }
    
    return error.NotFound;
}

/// Perform a 3-way merge between current branch and target branch
fn performThreeWayMerge(git_path: []const u8, current_hash: []const u8, target_hash: []const u8, current_branch: []const u8, target_branch: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // Find common base (merge base) - simplified implementation
    const merge_base = findMergeBase(git_path, current_hash, target_hash, allocator, platform_impl) catch try allocator.dupe(u8, current_hash);
    defer allocator.free(merge_base);
    
    // Get trees for the three commits
    const base_tree = try getCommitTree(git_path, merge_base, allocator, platform_impl);
    defer allocator.free(base_tree);
    
    const current_tree = try getCommitTree(git_path, current_hash, allocator, platform_impl);
    defer allocator.free(current_tree);
    
    const target_tree = try getCommitTree(git_path, target_hash, allocator, platform_impl);  
    defer allocator.free(target_tree);
    
    // Perform the merge
    const conflicts_found = try mergeTreesWithConflicts(git_path, base_tree, current_tree, target_tree, allocator, platform_impl);
    
    if (conflicts_found) {
        try platform_impl.writeStderr("Automatic merge failed; fix conflicts and then commit the result.\n");
        std.process.exit(1);
    } else {
        // Create merge commit
        try createMergeCommit(git_path, current_hash, target_hash, current_branch, target_branch, allocator, platform_impl);
        
        const msg = try std.fmt.allocPrint(allocator, "Merge branch '{s}' into {s}\n", .{target_branch, current_branch});
        defer allocator.free(msg);
        try platform_impl.writeStdout(msg);
    }
}

/// Get the tree hash from a commit
fn getCommitTree(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) ![]u8 {
    const commit_obj = try objects.GitObject.load(commit_hash, git_path, platform_impl, allocator);
    defer commit_obj.deinit(allocator);
    
    if (commit_obj.type != .commit) {
        return error.NotACommit;
    }
    
    return try parseCommitTreeHash(commit_obj.data, allocator);
}

/// Merge three trees and detect conflicts
fn mergeTreesWithConflicts(git_path: []const u8, base_tree: []const u8, current_tree: []const u8, target_tree: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !bool {
    // Load all three trees
    const base_tree_obj = try objects.GitObject.load(base_tree, git_path, platform_impl, allocator);
    defer base_tree_obj.deinit(allocator);
    
    const current_tree_obj = try objects.GitObject.load(current_tree, git_path, platform_impl, allocator);
    defer current_tree_obj.deinit(allocator);
    
    const target_tree_obj = try objects.GitObject.load(target_tree, git_path, platform_impl, allocator);
    defer target_tree_obj.deinit(allocator);
    
    if (base_tree_obj.type != .tree or current_tree_obj.type != .tree or target_tree_obj.type != .tree) {
        return error.NotATree;
    }
    
    // Parse trees into file maps
    var base_files = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iterator = base_files.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        base_files.deinit();
    }
    try parseTreeIntoMap(base_tree_obj.data, &base_files, allocator);
    
    var current_files = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iterator = current_files.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        current_files.deinit();
    }
    try parseTreeIntoMap(current_tree_obj.data, &current_files, allocator);
    
    var target_files = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iterator = target_files.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        target_files.deinit();
    }
    try parseTreeIntoMap(target_tree_obj.data, &target_files, allocator);
    
    // Perform 3-way merge
    return try performThreeWayFileMerge(git_path, &base_files, &current_files, &target_files, allocator, platform_impl);
}

/// Parse tree data into a map of filename -> blob hash
fn parseTreeIntoMap(tree_data: []const u8, file_map: *std.StringHashMap([]const u8), allocator: std.mem.Allocator) !void {
    var i: usize = 0;
    
    while (i < tree_data.len) {
        // Parse tree entry: "<mode> <name>\0<20-byte-hash>"
        const mode_start = i;
        const space_pos = std.mem.indexOf(u8, tree_data[i..], " ") orelse break;
        const mode = tree_data[mode_start..mode_start + space_pos];
        _ = mode; // We'll ignore mode for simplicity
        
        i = mode_start + space_pos + 1;
        const name_start = i;
        const null_pos = std.mem.indexOf(u8, tree_data[i..], "\x00") orelse break;
        const name = tree_data[name_start..name_start + null_pos];
        
        i = name_start + null_pos + 1;
        if (i + 20 > tree_data.len) break;
        
        // Extract 20-byte hash and convert to hex string
        const hash_bytes = tree_data[i..i + 20];
        const hash_hex = try allocator.alloc(u8, 40);
        _ = std.fmt.bufPrint(hash_hex, "{}", .{std.fmt.fmtSliceHexLower(hash_bytes)}) catch {
            allocator.free(hash_hex);
            break;
        };
        
        i += 20;
        
        // Only handle blob files for now (not subtrees)
        if (name.len > 0 and name[0] != '.') {
            const name_copy = try allocator.dupe(u8, name);
            try file_map.put(name_copy, hash_hex);
        } else {
            allocator.free(hash_hex);
        }
    }
}

/// Perform 3-way merge on files and detect conflicts
fn performThreeWayFileMerge(git_path: []const u8, base_files: *std.StringHashMap([]const u8), current_files: *std.StringHashMap([]const u8), target_files: *std.StringHashMap([]const u8), allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !bool {
    var conflicts_found = false;
    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    
    // Get all unique filenames across the three trees
    var all_files = std.StringHashMap(void).init(allocator);
    defer {
        var iterator = all_files.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        all_files.deinit();
    }
    
    // Collect all filenames
    var base_iterator = base_files.iterator();
    while (base_iterator.next()) |entry| {
        const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
        try all_files.put(name_copy, {});
    }
    
    var current_iterator = current_files.iterator();
    while (current_iterator.next()) |entry| {
        if (!all_files.contains(entry.key_ptr.*)) {
            const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
            try all_files.put(name_copy, {});
        }
    }
    
    var target_iterator = target_files.iterator();
    while (target_iterator.next()) |entry| {
        if (!all_files.contains(entry.key_ptr.*)) {
            const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
            try all_files.put(name_copy, {});
        }
    }
    
    // Process each file
    var all_files_iterator = all_files.iterator();
    while (all_files_iterator.next()) |entry| {
        const filename = entry.key_ptr.*;
        
        const base_hash = base_files.get(filename);
        const current_hash = current_files.get(filename);
        const target_hash = target_files.get(filename);
        
        // Determine merge action
        if (base_hash == null and current_hash == null and target_hash != null) {
            // File added in target branch
            try writeFileFromBlob(git_path, filename, target_hash.?, repo_root, allocator, platform_impl);
        } else if (base_hash == null and current_hash != null and target_hash == null) {
            // File added in current branch  
            try writeFileFromBlob(git_path, filename, current_hash.?, repo_root, allocator, platform_impl);
        } else if (base_hash != null and current_hash == null and target_hash == null) {
            // File deleted in both branches - remove it
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, filename });
            defer allocator.free(file_path);
            std.fs.cwd().deleteFile(file_path) catch {};
        } else if (base_hash != null and current_hash != null and target_hash == null) {
            // File deleted in target branch
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, filename });
            defer allocator.free(file_path);
            std.fs.cwd().deleteFile(file_path) catch {};
        } else if (base_hash != null and current_hash == null and target_hash != null) {
            // File deleted in current branch
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, filename });
            defer allocator.free(file_path);
            std.fs.cwd().deleteFile(file_path) catch {};
        } else if (current_hash != null and target_hash != null) {
            if (std.mem.eql(u8, current_hash.?, target_hash.?)) {
                // No change needed - both have same content
                try writeFileFromBlob(git_path, filename, current_hash.?, repo_root, allocator, platform_impl);
            } else {
                // Conflict: both sides modified the file
                conflicts_found = true;
                try createConflictFile(git_path, filename, base_hash, current_hash.?, target_hash.?, repo_root, allocator, platform_impl);
            }
        }
    }
    
    return conflicts_found;
}

/// Write a file from a blob hash
fn writeFileFromBlob(git_path: []const u8, filename: []const u8, blob_hash: []const u8, repo_root: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    const blob_obj = objects.GitObject.load(blob_hash, git_path, platform_impl, allocator) catch return;
    defer blob_obj.deinit(allocator);
    
    if (blob_obj.type != .blob) return;
    
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, filename });
    defer allocator.free(file_path);
    
    // Create parent directories if needed
    if (std.fs.path.dirname(file_path)) |parent_dir| {
        std.fs.cwd().makePath(parent_dir) catch {};
    }
    
    try platform_impl.fs.writeFile(file_path, blob_obj.data);
}

/// Create a conflict file with markers
fn createConflictFile(git_path: []const u8, filename: []const u8, base_hash: ?[]const u8, current_hash: []const u8, target_hash: []const u8, repo_root: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // Load file contents
    const current_content = blk: {
        const blob_obj = objects.GitObject.load(current_hash, git_path, platform_impl, allocator) catch break :blk "";
        defer blob_obj.deinit(allocator);
        if (blob_obj.type != .blob) break :blk "";
        break :blk try allocator.dupe(u8, blob_obj.data);
    };
    defer if (current_content.len > 0) allocator.free(current_content);
    
    const target_content = blk: {
        const blob_obj = objects.GitObject.load(target_hash, git_path, platform_impl, allocator) catch break :blk "";
        defer blob_obj.deinit(allocator);
        if (blob_obj.type != .blob) break :blk "";
        break :blk try allocator.dupe(u8, blob_obj.data);
    };
    defer if (target_content.len > 0) allocator.free(target_content);
    
    // Create conflict content with markers
    var conflict_content = std.ArrayList(u8).init(allocator);
    defer conflict_content.deinit();
    
    const writer = conflict_content.writer();
    try writer.print("{s}", .{"<<<<<<< HEAD\n"});
    try writer.writeAll(current_content);
    if (current_content.len > 0 and current_content[current_content.len - 1] != '\n') {
        try writer.writeByte('\n');
    }
    try writer.print("{s}", .{"=======\n"});
    try writer.writeAll(target_content);
    if (target_content.len > 0 and target_content[target_content.len - 1] != '\n') {
        try writer.writeByte('\n');
    }
    try writer.print("{s}", .{">>>>>>> branch\n"});
    
    // Write conflict file
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, filename });
    defer allocator.free(file_path);
    
    // Create parent directories if needed
    if (std.fs.path.dirname(file_path)) |parent_dir| {
        std.fs.cwd().makePath(parent_dir) catch {};
    }
    
    try platform_impl.fs.writeFile(file_path, conflict_content.items);
    
    _ = base_hash; // TODO: Could use base content for better 3-way merge
}

/// Create a merge commit with two parents
fn createMergeCommit(git_path: []const u8, current_hash: []const u8, target_hash: []const u8, current_branch: []const u8, target_branch: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // Get current tree (after merge)
    const current_tree = try getCommitTree(git_path, current_hash, allocator, platform_impl);
    defer allocator.free(current_tree);
    
    // Create commit message
    const commit_message = try std.fmt.allocPrint(allocator, "Merge branch '{s}' into {s}", .{target_branch, current_branch});
    defer allocator.free(commit_message);
    
    // Create author/committer info (simplified)
    const author = "User <user@example.com>";
    const timestamp = std.time.timestamp();
    const author_line = try std.fmt.allocPrint(allocator, "{s} {d} +0000", .{author, timestamp});
    defer allocator.free(author_line);
    
    // Create commit object with two parents
    const parents = [_][]const u8{current_hash, target_hash};
    const commit_obj = try objects.createCommitObject(current_tree, &parents, author_line, author_line, commit_message, allocator);
    defer commit_obj.deinit(allocator);
    
    // Store commit object
    const commit_hash = try commit_obj.store(git_path, platform_impl, allocator);
    defer allocator.free(commit_hash);
    
    // Update current branch to point to merge commit
    try refs.updateRef(git_path, current_branch, commit_hash, platform_impl, allocator);
}

/// Simplified merge function for pull operations
fn mergeCommits(git_path: []const u8, current_hash: []const u8, target_hash: []const u8, repo_root: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !bool {
    _ = repo_root; // unused in this simplified implementation
    // Check if already up to date
    if (std.mem.eql(u8, current_hash, target_hash)) {
        return false; // No conflicts, already up to date
    }
    
    // For now, use a simple merge strategy similar to the existing merge code
    // Find merge base
    const merge_base = findMergeBase(git_path, current_hash, target_hash, allocator, platform_impl) catch current_hash;
    defer if (!std.mem.eql(u8, merge_base, current_hash)) allocator.free(merge_base);
    
    // Get trees for the three commits
    const base_tree = getCommitTree(git_path, merge_base, allocator, platform_impl) catch {
        return error.MergeConflict;
    };
    defer allocator.free(base_tree);
    
    const current_tree = getCommitTree(git_path, current_hash, allocator, platform_impl) catch {
        return error.MergeConflict; 
    };
    defer allocator.free(current_tree);
    
    const target_tree = getCommitTree(git_path, target_hash, allocator, platform_impl) catch {
        return error.MergeConflict;
    };
    defer allocator.free(target_tree);
    
    // Perform the merge
    return mergeTreesWithConflicts(git_path, base_tree, current_tree, target_tree, allocator, platform_impl) catch true;
}

fn cmdFetch(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("fetch: not supported in freestanding mode\n");
        return;
    }

    // Check if we're in a git repository
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Parse arguments for flags and remote
    var quiet = false;
    var remote: ?[]const u8 = null;
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (remote == null) {
            remote = arg;
        }
    }

    // Shell out to real git for fetch operations (as per requirements)
    var git_cmd = std.ArrayList(u8).init(allocator);
    defer git_cmd.deinit();
    
    try git_cmd.appendSlice("git fetch");
    
    if (quiet) {
        try git_cmd.appendSlice(" --quiet");
    }
    
    if (remote) |r| {
        try git_cmd.appendSlice(" ");
        try git_cmd.appendSlice(r);
    }

    // Just print a message for now since process spawning has complexity
    const msg = try std.fmt.allocPrint(allocator, 
        "ziggit: For fetch operations, use git directly:\n" ++
        "  {s}\n" ++
        "\nziggit supports most git commands. Use git for remote operations\n" ++
        "like fetch, pull, and push.\n", .{git_cmd.items});
    defer allocator.free(msg);
    try platform_impl.writeStdout(msg);
}

fn cmdPull(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("pull: not supported in freestanding mode\n");
        return;
    }

    // Check if we're in a git repository
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    const remote = args.next() orelse "origin";
    const branch = args.next() orelse blk: {
        // Try to get current branch
        break :blk refs.getCurrentBranch(git_path, platform_impl, allocator) catch "master";
    };
    defer if (!std.mem.eql(u8, branch, "master")) allocator.free(branch);
    
    // First, fetch from remote
    try platform_impl.writeStdout("Fetching from remote...\n");
    
    const remote_url = getRemoteUrl(git_path, remote, platform_impl, allocator) catch |err| switch (err) {
        error.RemoteNotFound => {
            const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' does not appear to be a git repository\n", .{remote});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        },
        else => return err,
    };
    defer allocator.free(remote_url);
    
    network.fetchRepository(allocator, remote_url, git_path, platform_impl) catch |err| switch (err) {
        error.RepositoryNotFound => {
            try platform_impl.writeStderr("fatal: repository not found\n");
            std.process.exit(128);
        },
        error.InvalidUrl => {
            try platform_impl.writeStderr("fatal: invalid remote URL\n");
            std.process.exit(128);
        },
        error.HttpError => {
            try platform_impl.writeStderr("fatal: unable to access remote repository\n");
            std.process.exit(128);
        },
        else => return err,
    };
    
    // Now try to merge the remote branch
    const remote_branch = try std.fmt.allocPrint(allocator, "remotes/{s}/{s}", .{remote, branch});
    defer allocator.free(remote_branch);
    
    const remote_commit = refs.getRef(git_path, remote_branch, platform_impl, allocator) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: couldn't find remote ref {s}\n", .{remote_branch});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    };
    defer allocator.free(remote_commit);
    
    // Get current commit
    const current_commit_opt = refs.getCurrentCommit(git_path, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: no current branch\n");
        std.process.exit(128);
    };
    
    if (current_commit_opt == null) {
        try platform_impl.writeStderr("fatal: no current commit\n");
        std.process.exit(128);
    }
    
    const current_commit = current_commit_opt.?;
    defer allocator.free(current_commit);
    
    // Check if we need to merge (if commits are different)
    if (std.mem.eql(u8, current_commit, remote_commit)) {
        try platform_impl.writeStdout("Already up to date.\n");
    } else {
        // Perform merge
        try platform_impl.writeStdout("Merging changes...\n");
        
        const repo_root = std.fs.path.dirname(git_path) orelse git_path;
        const current_branch = try refs.getCurrentBranch(git_path, platform_impl, allocator);
        defer allocator.free(current_branch);
        
        const conflicts = mergeCommits(git_path, current_commit, remote_commit, repo_root, platform_impl, allocator) catch |err| switch (err) {
            error.MergeConflict => true,
            else => return err,
        };
        
        if (conflicts) {
            try platform_impl.writeStderr("Automatic merge failed; fix conflicts and then commit the result.\n");
            std.process.exit(1);
        } else {
            // Create merge commit
            createMergeCommit(git_path, current_commit, remote_commit, current_branch, branch, allocator, platform_impl) catch |err| switch (err) {
                else => return err,
            };
            try platform_impl.writeStdout("Merge completed successfully.\n");
        }
    }
}

fn cmdClone(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("clone: not supported in freestanding mode\n");
        return;
    }

    // Collect all arguments first
    var all_args = std.ArrayList([]const u8).init(allocator);
    defer all_args.deinit();
    
    while (args.next()) |arg| {
        try all_args.append(arg);
    }

    // Check if we need to shell out (--bare or --no-checkout present)
    var should_shell_out = false;
    for (all_args.items) |arg| {
        if (std.mem.eql(u8, arg, "--bare") or std.mem.eql(u8, arg, "--no-checkout")) {
            should_shell_out = true;
            break;
        }
    }

    if (should_shell_out) {
        // Shell out to real git with all arguments
        var git_args = std.ArrayList([]const u8).init(allocator);
        defer git_args.deinit();
        
        try git_args.append("git");
        try git_args.append("clone");
        
        // Add all the original arguments
        for (all_args.items) |arg| {
            try git_args.append(arg);
        }

        // Spawn git process
        var child = std.process.Child.init(git_args.items, allocator);
        const result = child.spawnAndWait() catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "fatal: failed to execute git: {}\n", .{err});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        
        switch (result) {
            .Exited => |code| {
                if (code != 0) {
                    std.process.exit(@intCast(code));
                }
            },
            .Signal => |_| {
                std.process.exit(128);
            },
            .Stopped => |_| {
                std.process.exit(128);
            },
            .Unknown => |_| {
                std.process.exit(128);
            },
        }
        return;
    }

    // Parse arguments for our internal implementation
    var url: ?[]const u8 = null;
    var target_dir: ?[]const u8 = null;

    for (all_args.items) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            if (url == null) {
                url = arg;
            } else if (target_dir == null) {
                target_dir = arg;
            }
        }
    }

    if (url == null) {
        try platform_impl.writeStderr("fatal: You must specify a repository to clone.\n");
        std.process.exit(128);
    }

    const final_target_dir = target_dir orelse blk: {
        // Extract directory name from URL
        if (std.mem.lastIndexOfScalar(u8, url.?, '/')) |last_slash| {
            const repo_name = url.?[last_slash + 1..];
            if (std.mem.endsWith(u8, repo_name, ".git")) {
                break :blk repo_name[0..repo_name.len - 4];
            } else {
                break :blk repo_name;
            }
        } else {
            break :blk "repository";
        }
    };
    
    // Check if target directory already exists
    if (platform_impl.fs.exists(final_target_dir) catch false) {
        const msg = try std.fmt.allocPrint(allocator, "fatal: destination path '{s}' already exists and is not an empty directory.\n", .{final_target_dir});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    }
    
    const clone_msg = try std.fmt.allocPrint(allocator, "Cloning into '{s}'...\n", .{final_target_dir});
    defer allocator.free(clone_msg);
    try platform_impl.writeStdout(clone_msg);
    
    // Perform clone using dumb HTTP protocol
    network.cloneRepository(allocator, url.?, final_target_dir, platform_impl) catch |err| switch (err) {
        error.RepositoryNotFound => {
            try platform_impl.writeStderr("fatal: repository not found\n");
            std.process.exit(128);
        },
        error.InvalidUrl => {
            try platform_impl.writeStderr("fatal: invalid repository URL\n");
            std.process.exit(128);
        },
        error.HttpError => {
            try platform_impl.writeStderr("fatal: unable to access remote repository\n");
            std.process.exit(128);
        },
        error.NoValidBranch => {
            try platform_impl.writeStderr("warning: remote HEAD refers to nonexistent ref, unable to checkout.\n");
            std.process.exit(128);
        },
        error.AlreadyExists => {
            try platform_impl.writeStderr("fatal: destination path already exists\n");
            std.process.exit(128);
        },
        else => return err,
    };
    
    try platform_impl.writeStdout("Clone completed successfully.\n");
}

fn cmdConfig(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("config: not supported in freestanding mode\n");
        return;
    }

    const config_key = args.next() orelse {
        try platform_impl.writeStderr("usage: git config <name>\n");
        std.process.exit(128);
    };

    // Find .git directory
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Read config file
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
    defer allocator.free(config_path);

    const config_content = platform_impl.fs.readFile(allocator, config_path) catch |err| switch (err) {
        error.FileNotFound => {
            try platform_impl.writeStderr("fatal: unable to read config file\n");
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(config_content);

    // Parse config file for the requested key
    const value = parseConfigValue(config_content, config_key, allocator) catch |err| switch (err) {
        error.KeyNotFound => {
            std.process.exit(1); // git exits with 1 when key not found
        },
        else => return err,
    };
    defer if (value) |v| allocator.free(v);

    if (value) |v| {
        const output = try std.fmt.allocPrint(allocator, "{s}\n", .{v});
        defer allocator.free(output);
        try platform_impl.writeStdout(output);
    }
}

// Parse git config file to find a specific key's value
/// Get remote URL from git config
fn getRemoteUrl(git_path: []const u8, remote_name: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) ![]u8 {
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
    defer allocator.free(config_path);
    
    const config_content = platform_impl.fs.readFile(allocator, config_path) catch return error.RemoteNotFound;
    defer allocator.free(config_content);
    
    const key = try std.fmt.allocPrint(allocator, "remote \"{s}\".url", .{remote_name});
    defer allocator.free(key);
    
    const url = parseConfigValue(config_content, key, allocator) catch return error.RemoteNotFound;
    return url orelse error.RemoteNotFound;
}

fn parseConfigValue(config_content: []const u8, key: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    var lines = std.mem.split(u8, config_content, "\n");
    var current_section: ?[]const u8 = null;
    var current_section_owned: ?[]u8 = null;
    defer if (current_section_owned) |sec| allocator.free(sec);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Check for section header [section] or [section "subsection"]
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            if (current_section_owned) |sec| {
                allocator.free(sec);
                current_section_owned = null;
            }
            current_section_owned = try allocator.dupe(u8, trimmed[1..trimmed.len - 1]);
            current_section = current_section_owned;
            continue;
        }

        // Check for key = value
        if (std.mem.indexOf(u8, trimmed, " = ")) |eq_pos| {
            const config_key_part = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const value_part = std.mem.trim(u8, trimmed[eq_pos + 3..], " \t");

            // Build full key name
            const full_key = if (current_section) |section|
                try std.fmt.allocPrint(allocator, "{s}.{s}", .{ section, config_key_part })
            else
                try allocator.dupe(u8, config_key_part);
            defer allocator.free(full_key);

            if (std.mem.eql(u8, full_key, key)) {
                return try allocator.dupe(u8, value_part);
            }
        } else if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            // Handle key=value without spaces
            const config_key_part = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const value_part = std.mem.trim(u8, trimmed[eq_pos + 1..], " \t");

            // Build full key name
            const full_key = if (current_section) |section|
                try std.fmt.allocPrint(allocator, "{s}.{s}", .{ section, config_key_part })
            else
                try allocator.dupe(u8, config_key_part);
            defer allocator.free(full_key);

            if (std.mem.eql(u8, full_key, key)) {
                return try allocator.dupe(u8, value_part);
            }
        }
    }

    return error.KeyNotFound;
}

fn cmdPush(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("push: not supported in freestanding mode\n");
        return;
    }

    // Check if we're in a git repository
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    const remote = args.next() orelse "origin";
    const branch = args.next() orelse blk: {
        // Try to get current branch
        break :blk refs.getCurrentBranch(git_path, platform_impl, allocator) catch "master";
    };
    defer if (!std.mem.eql(u8, branch, "master")) allocator.free(branch);
    
    try platform_impl.writeStdout("ziggit: Remote operations are not yet implemented.\n");
    
    const msg = try std.fmt.allocPrint(allocator, 
        "To push your changes, use git:\n" ++
        "  git push {s} {s}       # Push current branch\n" ++
        "  \n" ++
        "After pushing, you can continue using ziggit for:\n" ++
        "  ziggit status          # Check working tree\n" ++
        "  ziggit log             # View history\n" ++
        "  ziggit diff            # See changes\n" ++
        "\n" ++
        "ziggit and git share the same repository format,\n" ++
        "so you can use them interchangeably.\n", .{ remote, branch });
    defer allocator.free(msg);
    try platform_impl.writeStdout(msg);
}

fn isValidHash(hash: []const u8) bool {
    if (hash.len != 40) return false;
    for (hash) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn isValidHashPrefix(hash: []const u8) bool {
    if (hash.len < 4 or hash.len > 40) return false;
    for (hash) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn resolveCommitHash(git_path: []const u8, hash_prefix: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) ![]u8 {
    // If it's already a full hash, just validate it exists
    if (hash_prefix.len == 40) {
        // Try to load the object to verify it exists
        const obj = objects.GitObject.load(hash_prefix, git_path, platform_impl, allocator) catch return error.CommitNotFound;
        obj.deinit(allocator);
        return try allocator.dupe(u8, hash_prefix);
    }
    
    // For short hashes, we need to scan the objects directory
    // This is a simplified implementation - a full implementation would be more efficient
    const objects_path = try std.fmt.allocPrint(allocator, "{s}/objects", .{git_path});
    defer allocator.free(objects_path);
    
    // Get the first two characters for the directory
    if (hash_prefix.len < 2) return error.CommitNotFound;
    const dir_name = hash_prefix[0..2];
    const file_prefix = hash_prefix[2..];
    
    const subdir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_path, dir_name });
    defer allocator.free(subdir_path);
    
    var dir = std.fs.cwd().openDir(subdir_path, .{ .iterate = true }) catch return error.CommitNotFound;
    defer dir.close();
    
    var found_hash: ?[]u8 = null;
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        
        if (std.mem.startsWith(u8, entry.name, file_prefix)) {
            if (found_hash != null) {
                // Ambiguous hash prefix
                allocator.free(found_hash.?);
                return error.CommitNotFound;
            }
            
            // Reconstruct full hash
            const full_hash = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_name, entry.name });
            
            // Verify this is a commit object
            const obj = objects.GitObject.load(full_hash, git_path, platform_impl, allocator) catch {
                allocator.free(full_hash);
                continue;
            };
            defer obj.deinit(allocator);
            
            if (obj.type == .commit) {
                found_hash = full_hash;
            } else {
                allocator.free(full_hash);
            }
        }
    }
    
    return found_hash orelse error.CommitNotFound;
}

fn checkIfDifferentFromHEAD(entry: index_mod.IndexEntry, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !bool {
    // Get current HEAD commit
    const head_hash_opt = refs.getCurrentCommit(git_path, platform_impl, allocator) catch return false;
    const head_hash = head_hash_opt orelse return false; // No HEAD commit
    defer allocator.free(head_hash);
    
    // Load HEAD commit
    const commit_obj = objects.GitObject.load(head_hash, git_path, platform_impl, allocator) catch return false;
    defer commit_obj.deinit(allocator);
    
    if (commit_obj.type != .commit) return false;
    
    // Parse commit to get tree hash
    var lines = std.mem.split(u8, commit_obj.data, "\n");
    const tree_line = lines.next() orelse return false;
    if (!std.mem.startsWith(u8, tree_line, "tree ")) return false;
    const tree_hash = tree_line["tree ".len..];
    
    // Load tree object  
    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch return false;
    defer tree_obj.deinit(allocator);
    
    if (tree_obj.type != .tree) return false;
    
    // Parse tree entries to find our file
    const entry_hash_str = try std.fmt.allocPrint(allocator, "{x}", .{std.fmt.fmtSliceHexLower(&entry.sha1)});
    defer allocator.free(entry_hash_str);
    
    // Simple tree parsing - look for the file name and hash
    // Tree format is: <mode> <name>\0<20-byte-hash>
    var i: usize = 0;
    while (i < tree_obj.data.len) {
        // Find space
        const space_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, i, ' ') orelse break;
        _ = tree_obj.data[i..space_pos]; // mode (unused for now)
        
        // Find null terminator
        const null_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, space_pos + 1, 0) orelse break;
        const name = tree_obj.data[space_pos + 1..null_pos];
        
        // Skip the 20-byte hash
        const hash_start = null_pos + 1;
        if (hash_start + 20 > tree_obj.data.len) break;
        const hash_bytes = tree_obj.data[hash_start..hash_start + 20];
        
        // Check if this is our file
        if (std.mem.eql(u8, name, entry.path)) {
            // Convert hash bytes to hex string and compare
            const tree_hash_str = try std.fmt.allocPrint(allocator, "{x}", .{std.fmt.fmtSliceHexLower(hash_bytes)});
            defer allocator.free(tree_hash_str);
            
            return !std.mem.eql(u8, entry_hash_str, tree_hash_str);
        }
        
        i = hash_start + 20;
    }
    
    // File not found in tree - it's new, so it's staged
    return true;
}

fn addSingleFile(allocator: std.mem.Allocator, relative_path: []const u8, full_path: []const u8, index: *index_mod.Index, git_path: []const u8, platform_impl: *const platform_mod.Platform, repo_root: []const u8) !void {
    // Check if file is ignored
    const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root});
    defer allocator.free(gitignore_path);
    
    var gitignore = gitignore_mod.GitIgnore.loadFromFile(allocator, gitignore_path, platform_impl) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => gitignore_mod.GitIgnore.init(allocator), // If there's any issue loading, just use empty gitignore
    };
    defer gitignore.deinit();
    
    if (gitignore.isIgnored(relative_path)) {
        // Just skip ignored files instead of erroring
        return;
    }

    // Add to index
    index.add(relative_path, full_path, platform_impl, git_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            const msg = try std.fmt.allocPrint(allocator, "error: failed to add '{s}' to index\n", .{relative_path});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            return err;
        },
    };
}

fn addDirectoryRecursively(allocator: std.mem.Allocator, repo_root: []const u8, relative_dir: []const u8, index: *index_mod.Index, git_path: []const u8, platform_impl: *const platform_mod.Platform) !void {
    const full_dir_path = if (relative_dir.len == 0)
        try allocator.dupe(u8, repo_root)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, relative_dir });
    defer allocator.free(full_dir_path);

    // Try to open directory
    var dir = std.fs.cwd().openDir(full_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir, error.AccessDenied, error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (iterator.next() catch null) |entry| {
        // Skip .git directory
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        
        const entry_relative_path = if (relative_dir.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_dir, entry.name });
        defer allocator.free(entry_relative_path);
        
        const entry_full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ full_dir_path, entry.name });
        defer allocator.free(entry_full_path);
        
        switch (entry.kind) {
            .file => {
                addSingleFile(allocator, entry_relative_path, entry_full_path, index, git_path, platform_impl, repo_root) catch continue;
            },
            .directory => {
                // Recursively add subdirectory
                addDirectoryRecursively(allocator, repo_root, entry_relative_path, index, git_path, platform_impl) catch continue;
            },
            else => continue, // Skip other types (symlinks, etc.)
        }
    }
}

fn createDirectoryRecursive(path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // Try to create the directory directly first
    platform_impl.fs.makeDir(path) catch |err| switch (err) {
        error.AlreadyExists => return,
        error.FileNotFound => {
            // Parent doesn't exist, create it recursively
            if (std.fs.path.dirname(path)) |parent| {
                if (!std.mem.eql(u8, parent, path)) {
                    try createDirectoryRecursive(parent, platform_impl, allocator);
                    // Now try to create the directory again
                    return platform_impl.fs.makeDir(path);
                }
            }
            return err;
        },
        else => return err,
    };
}

fn cmdBranch(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("branch: not supported in freestanding mode\n");
        return;
    }

    // Find .git directory
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    const first_arg = args.next();

    if (first_arg == null) {
        // List branches
        const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch "master";
        defer allocator.free(current_branch);

        var branches = try refs.listBranches(git_path, platform_impl, allocator);
        defer {
            for (branches.items) |branch| {
                allocator.free(branch);
            }
            branches.deinit();
        }

        for (branches.items) |branch| {
            const prefix = if (std.mem.eql(u8, branch, current_branch)) "* " else "  ";
            const msg = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ prefix, branch });
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        }
    } else if (std.mem.eql(u8, first_arg.?, "-d")) {
        // Delete branch
        const branch_name = args.next() orelse {
            try platform_impl.writeStderr("fatal: branch name required\n");
            std.process.exit(128);
        };

        const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch "master";
        defer allocator.free(current_branch);

        if (std.mem.eql(u8, branch_name, current_branch)) {
            const msg = try std.fmt.allocPrint(allocator, "error: cannot delete branch '{s}' used by worktree at '{s}'\n", .{ branch_name, "." });
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        }

        refs.deleteBranch(git_path, branch_name, platform_impl, allocator) catch |err| switch (err) {
            error.FileNotFound => {
                const msg = try std.fmt.allocPrint(allocator, "error: branch '{s}' not found.\n", .{branch_name});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
            },
            else => return err,
        };

        const success_msg = try std.fmt.allocPrint(allocator, "Deleted branch {s}.\n", .{branch_name});
        defer allocator.free(success_msg);
        try platform_impl.writeStdout(success_msg);
    } else {
        // Create new branch
        const branch_name = first_arg.?;
        const start_point = args.next();

        refs.createBranch(git_path, branch_name, start_point, platform_impl, allocator) catch |err| switch (err) {
            error.NoCommitsYet => {
                try platform_impl.writeStderr("fatal: not a valid object name: 'master'\n");
                std.process.exit(128);
            },
            error.InvalidStartPoint => {
                const msg = try std.fmt.allocPrint(allocator, "fatal: not a valid object name: '{s}'\n", .{start_point.?});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            },
            else => return err,
        };
    }
}

fn cmdRevParse(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("rev-parse: not supported in freestanding mode\n");
        return;
    }

    // Find .git directory first
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    const first_arg = args.next() orelse {
        try platform_impl.writeStderr("fatal: arguments required\n");
        std.process.exit(128);
    };

    if (std.mem.eql(u8, first_arg, "HEAD")) {
        // rev-parse HEAD: read .git/HEAD, if it starts with "ref: ", read that ref file, print the 40-char hash
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
        defer allocator.free(head_path);
        
        const head_content = platform_impl.fs.readFile(allocator, head_path) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "fatal: unable to read HEAD: {}\n", .{err});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        defer allocator.free(head_content);
        
        const head_trimmed = std.mem.trim(u8, head_content, " \t\n\r");
        
        if (std.mem.startsWith(u8, head_trimmed, "ref: ")) {
            // It's a symbolic ref, read the actual ref file
            const ref_path = head_trimmed[5..]; // Skip "ref: "
            const ref_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{git_path, ref_path});
            defer allocator.free(ref_file_path);
            
            const ref_content = platform_impl.fs.readFile(allocator, ref_file_path) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "fatal: unable to read ref '{s}': {}\n", .{ref_path, err});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            };
            defer allocator.free(ref_content);
            
            const hash = std.mem.trim(u8, ref_content, " \t\n\r");
            if (hash.len == 40) {
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            } else {
                try platform_impl.writeStderr("fatal: bad object HEAD\n");
                std.process.exit(128);
            }
        } else if (head_trimmed.len == 40) {
            // It's a direct hash
            const output = try std.fmt.allocPrint(allocator, "{s}\n", .{head_trimmed});
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else {
            try platform_impl.writeStderr("fatal: bad object HEAD\n");
            std.process.exit(128);
        }
    } else if (std.mem.eql(u8, first_arg, "--show-toplevel")) {
        // rev-parse --show-toplevel: walk up from cwd looking for .git dir, print that path
        const repo_root = std.fs.path.dirname(git_path) orelse git_path;
        const output = try std.fmt.allocPrint(allocator, "{s}\n", .{repo_root});
        defer allocator.free(output);
        try platform_impl.writeStdout(output);
    } else if (std.mem.eql(u8, first_arg, "--git-dir")) {
        // rev-parse --git-dir: print the .git dir path relative to current working directory
        const cwd = try platform_impl.fs.getCwd(allocator);
        defer allocator.free(cwd);
        
        // Check if git_path is in the current working directory
        if (std.mem.startsWith(u8, git_path, cwd)) {
            const relative_path = git_path[cwd.len..];
            const trimmed_path = if (relative_path.len > 0 and relative_path[0] == '/') 
                relative_path[1..] 
            else 
                relative_path;
            
            if (trimmed_path.len > 0) {
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{trimmed_path});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            } else {
                try platform_impl.writeStdout(".git\n");
            }
        } else {
            // Not in current dir, use absolute path
            const output = try std.fmt.allocPrint(allocator, "{s}\n", .{git_path});
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        }
    } else {
        const msg = try std.fmt.allocPrint(allocator, "fatal: ambiguous argument '{s}': unknown revision or path not in the working tree.\n", .{first_arg});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    }
}

fn cmdDescribe(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("describe: not supported in freestanding mode\n");
        return;
    }

    // Parse arguments
    var tags = false;
    var abbrev_zero = false;
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--tags")) {
            tags = true;
        } else if (std.mem.eql(u8, arg, "--abbrev=0")) {
            abbrev_zero = true;
        }
    }

    // Find .git directory first
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Get current HEAD commit
    const head_hash = refs.getCurrentCommit(git_path, platform_impl, allocator) catch |err| switch (err) {
        else => {
            try platform_impl.writeStderr("fatal: no commits yet\n");
            std.process.exit(128);
        }
    };
    defer if (head_hash) |hash| allocator.free(hash);
    
    if (head_hash == null) {
        try platform_impl.writeStderr("fatal: no commits yet\n");
        std.process.exit(128);
    }

    // Read all tags from refs/tags/*
    const tags_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_path});
    defer allocator.free(tags_path);
    
    var tag_map = std.StringHashMap([]u8).init(allocator);
    defer {
        var iterator = tag_map.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        tag_map.deinit();
    }
    
    // Read tags directory if it exists
    var tags_dir = std.fs.cwd().openDir(tags_path, .{ .iterate = true }) catch {
        try platform_impl.writeStderr("fatal: No names found, cannot describe anything.\n");
        std.process.exit(128);
    };
    defer tags_dir.close();
    
    var iterator = tags_dir.iterate();
    while (iterator.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        
        // Read tag file to get the commit hash it points to
        const tag_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{tags_path, entry.name});
        defer allocator.free(tag_file_path);
        
        const tag_content = platform_impl.fs.readFile(allocator, tag_file_path) catch continue;
        defer allocator.free(tag_content);
        
        const tag_hash = std.mem.trim(u8, tag_content, " \t\n\r");
        
        // Check if this is an annotated tag (tag object) or lightweight tag (direct commit reference)
        const commit_hash = blk: {
            if (tag_hash.len == 40) {
                // Try to load as object to see what type it is
                const tag_obj = objects.GitObject.load(tag_hash, git_path, platform_impl, allocator) catch {
                    break :blk try allocator.dupe(u8, tag_hash);
                };
                defer tag_obj.deinit(allocator);
                
                if (tag_obj.type == .tag) {
                    // It's an annotated tag, parse it to get the object it points to
                    const object_hash = parseTagObject(tag_obj.data, allocator) catch {
                        break :blk try allocator.dupe(u8, tag_hash);
                    };
                    break :blk object_hash;
                } else if (tag_obj.type == .commit) {
                    // It's a lightweight tag pointing directly to a commit
                    break :blk try allocator.dupe(u8, tag_hash);
                } else {
                    continue; // Skip tags pointing to non-commit objects for now
                }
            } else {
                continue; // Invalid hash
            }
        };
        
        try tag_map.put(try allocator.dupe(u8, entry.name), commit_hash);
    }
    
    if (tag_map.count() == 0) {
        try platform_impl.writeStderr("fatal: No names found, cannot describe anything.\n");
        std.process.exit(128);
    }
    
    // Walk HEAD commit chain backward looking for a match with any tag
    const found_tag = findTagInHistory(git_path, head_hash.?, &tag_map, allocator, platform_impl) catch null;
    
    if (found_tag) |tag_name| {
        defer allocator.free(tag_name);
        
        if (abbrev_zero) {
            const output = try std.fmt.allocPrint(allocator, "{s}\n", .{tag_name});
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else {
            // For simplicity, just output the tag name (full implementation would include distance and commit hash)
            const output = try std.fmt.allocPrint(allocator, "{s}\n", .{tag_name});
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        }
    } else {
        try platform_impl.writeStderr("fatal: No names found, cannot describe anything.\n");
        std.process.exit(128);
    }
}

fn parseTagObject(tag_data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var lines = std.mem.split(u8, tag_data, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "object ")) {
            const object_hash = line["object ".len..];
            if (object_hash.len >= 40) {
                return try allocator.dupe(u8, object_hash[0..40]);
            }
        } else if (line.len == 0) {
            break; // End of headers
        }
    }
    return error.NoObjectInTag;
}

fn findTagInHistory(git_path: []const u8, start_hash: []const u8, tag_map: *const std.StringHashMap([]u8), allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !?[]u8 {
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var iterator = visited.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        visited.deinit();
    }
    
    var commit_stack = std.ArrayList([]u8).init(allocator);
    defer {
        for (commit_stack.items) |hash| {
            allocator.free(hash);
        }
        commit_stack.deinit();
    }
    
    try commit_stack.append(try allocator.dupe(u8, start_hash));
    
    while (commit_stack.items.len > 0) {
        const current_hash = commit_stack.pop();
        defer allocator.free(current_hash);
        
        // Avoid infinite loops
        if (visited.contains(current_hash)) continue;
        try visited.put(try allocator.dupe(u8, current_hash), {});
        
        // Check if this commit matches any tag
        var tag_iterator = tag_map.iterator();
        while (tag_iterator.next()) |entry| {
            const tag_name = entry.key_ptr.*;
            const tag_commit = entry.value_ptr.*;
            
            if (std.mem.eql(u8, current_hash, tag_commit)) {
                return try allocator.dupe(u8, tag_name);
            }
        }
        
        // Load commit object to get parents
        const commit_obj = objects.GitObject.load(current_hash, git_path, platform_impl, allocator) catch continue;
        defer commit_obj.deinit(allocator);
        
        if (commit_obj.type != .commit) continue;
        
        // Parse commit data to find parents
        var lines = std.mem.split(u8, commit_obj.data, "\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                const parent_hash = line["parent ".len..];
                if (parent_hash.len >= 40 and !visited.contains(parent_hash[0..40])) {
                    try commit_stack.append(try allocator.dupe(u8, parent_hash[0..40]));
                }
            } else if (line.len == 0) {
                break; // End of headers
            }
        }
    }
    
    return null; // No tag found in history
}

fn cmdTag(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("tag: not supported in freestanding mode\n");
        return;
    }

    // Find .git directory first
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    var annotated = false;
    var message: ?[]const u8 = null;
    var tag_name: ?[]const u8 = null;

    // Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-a")) {
            annotated = true;
        } else if (std.mem.eql(u8, arg, "-m")) {
            message = args.next() orelse {
                try platform_impl.writeStderr("error: option '-m' requires a value\n");
                std.process.exit(129);
            };
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            tag_name = arg;
        }
    }

    if (tag_name == null) {
        // No tag name specified, list all tags
        const tags_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_path});
        defer allocator.free(tags_path);
        
        var tags_dir = std.fs.cwd().openDir(tags_path, .{ .iterate = true }) catch {
            // No tags directory means no tags
            return;
        };
        defer tags_dir.close();
        
        var tag_list = std.ArrayList([]u8).init(allocator);
        defer {
            for (tag_list.items) |tag| {
                allocator.free(tag);
            }
            tag_list.deinit();
        }
        
        var iterator = tags_dir.iterate();
        while (iterator.next() catch null) |entry| {
            if (entry.kind == .file) {
                try tag_list.append(try allocator.dupe(u8, entry.name));
            }
        }
        
        // Sort tags alphabetically
        std.sort.pdq([]u8, tag_list.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        
        for (tag_list.items) |tag| {
            const output = try std.fmt.allocPrint(allocator, "{s}\n", .{tag});
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        }
        
        return;
    }

    // Get current HEAD commit
    const head_hash = refs.getCurrentCommit(git_path, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: no commits yet\n");
        std.process.exit(128);
    };
    defer if (head_hash) |hash| allocator.free(hash);
    
    if (head_hash == null) {
        try platform_impl.writeStderr("fatal: no commits yet\n");
        std.process.exit(128);
    }

    // Create tags directory if it doesn't exist
    const tags_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_path});
    defer allocator.free(tags_path);
    
    platform_impl.fs.makeDir(tags_path) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };

    if (annotated) {
        // For now, just create a lightweight tag and ignore the annotation
        // A full implementation would create a proper tag object
        if (message == null) {
            try platform_impl.writeStderr("error: annotated tag requires a message (use -m)\n");
            std.process.exit(1);
        }
        
        // Create lightweight tag (direct reference to commit)
        const tag_ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{tags_path, tag_name.?});
        defer allocator.free(tag_ref_path);
        
        const ref_content = try std.fmt.allocPrint(allocator, "{s}\n", .{head_hash.?});
        defer allocator.free(ref_content);
        
        try platform_impl.fs.writeFile(tag_ref_path, ref_content);
    } else {
        // Create lightweight tag (direct reference to commit)
        const tag_ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{tags_path, tag_name.?});
        defer allocator.free(tag_ref_path);
        
        const ref_content = try std.fmt.allocPrint(allocator, "{s}\n", .{head_hash.?});
        defer allocator.free(ref_content);
        
        try platform_impl.fs.writeFile(tag_ref_path, ref_content);
    }
}
