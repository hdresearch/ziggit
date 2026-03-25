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
    } else if (std.mem.eql(u8, command, "checkout")) {
        try cmdCheckout(allocator, &args, &platform_impl);
    } else if (std.mem.eql(u8, command, "merge")) {
        try cmdMerge(allocator, &args, &platform_impl);
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
        std.process.exit(1);
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

    _ = args; // No args for basic status
    
    // Find .git directory by traversing up
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Get current branch
    const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch "master";
    defer allocator.free(current_branch);

    const branch_msg = try std.fmt.allocPrint(allocator, "On branch {s}\n", .{current_branch});
    defer allocator.free(branch_msg);
    try platform_impl.writeStdout(branch_msg);

    // Check if there are any commits
    const current_commit = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
    if (current_commit) |hash| {
        allocator.free(hash);
    } else {
        try platform_impl.writeStdout("\nNo commits yet\n");
    }

    // Load index to check for staged files
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();

    if (index.entries.items.len > 0) {
        try platform_impl.writeStdout("\nChanges to be committed:\n");
        try platform_impl.writeStdout("  (use \"git reset HEAD <file>...\" to unstage)\n\n");
        
        for (index.entries.items) |entry| {
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
    } else if (current_commit == null) {
        try platform_impl.writeStdout("\nnothing to commit (create/copy files and use \"git add\" to track)\n");
    } else {
        try platform_impl.writeStdout("\nnothing to commit, working tree clean\n");
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

    const file_path = args.next() orelse {
        try platform_impl.writeStderr("Nothing specified, nothing added.\n");
        try platform_impl.writeStderr("hint: Maybe you wanted to say 'git add .'?\n");
        return;
    };

    // Load index
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();

    // Get current working directory
    const cwd = try platform_impl.fs.getCwd(allocator);
    defer allocator.free(cwd);

    // Resolve file path 
    const full_file_path = if (std.fs.path.isAbsolute(file_path))
        try allocator.dupe(u8, file_path)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, file_path });
    defer allocator.free(full_file_path);

    // Check if file exists
    if (!(platform_impl.fs.exists(full_file_path) catch false)) {
        const msg = try std.fmt.allocPrint(allocator, "fatal: pathspec '{s}' did not match any files\n", .{file_path});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    }

    // Add to index
    index.add(file_path, full_file_path, platform_impl) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            const msg = try std.fmt.allocPrint(allocator, "error: failed to add '{s}' to index\n", .{file_path});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            return;
        },
    };

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

    // Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-m")) {
            message = args.next() orelse {
                try platform_impl.writeStderr("error: option `-m' requires a value\n");
                std.process.exit(129);
            };
        } else if (std.mem.startsWith(u8, arg, "-m")) {
            message = arg[2..];
        } else if (std.mem.eql(u8, arg, "--allow-empty")) {
            allow_empty = true;
        }
    }

    if (message == null) {
        try platform_impl.writeStderr("error: no commit message provided (use -m)\n");
        std.process.exit(1);
    }

    // Find .git directory
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Load index
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();

    // Check if there's anything to commit
    if (index.entries.items.len == 0 and !allow_empty) {
        try platform_impl.writeStderr("On branch master\n");
        try platform_impl.writeStderr("nothing to commit, working tree clean\n");
        std.process.exit(1);
    }

    // Create tree object from index entries
    var tree_entries = std.ArrayList(objects.TreeEntry).init(allocator);
    defer tree_entries.deinit();

    for (index.entries.items) |entry| {
        const hash_str = try std.fmt.allocPrint(allocator, "{x}", .{std.fmt.fmtSliceHexLower(&entry.hash)});
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

    if (refs.getCurrentCommit(git_path, platform_impl, allocator) catch null) |current_hash| {
        try parent_hashes.append(current_hash);
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

    // Output success message
    const short_hash = commit_hash[0..7];
    const success_msg = try std.fmt.allocPrint(allocator, "[{s} {s}] {s}\n", .{ current_branch, short_hash, message.? });
    defer allocator.free(success_msg);
    try platform_impl.writeStdout(success_msg);
}

fn cmdLog(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("log: not supported in freestanding mode\n");
        return;
    }

    _ = args;

    // Find .git directory
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Get current commit
    const current_commit = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
    if (current_commit == null) {
        try platform_impl.writeStderr("fatal: your current branch does not have any commits yet\n");
        std.process.exit(128);
    }
    defer if (current_commit) |hash| allocator.free(hash);

    // Walk the commit history
    var commit_hash = try allocator.dupe(u8, current_commit.?);
    defer allocator.free(commit_hash);

    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    while (true) {
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

        // Display commit
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

        // Move to parent commit
        if (parent_hash) |parent| {
            allocator.free(commit_hash);
            commit_hash = try allocator.dupe(u8, parent);
        } else {
            break; // No parent, we've reached the initial commit
        }
    }
}

fn cmdDiff(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("diff: not supported in freestanding mode\n");
        return;
    }

    // Find .git directory first
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    _ = args;

    // For now, just output empty diff (no changes)
    // In a real implementation, this would show actual differences
}

fn cmdCheckout(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("checkout: not supported in freestanding mode\n");
        return;
    }

    const target = args.next() orelse {
        try platform_impl.writeStderr("error: pathspec '' did not match any file(s) known to git\n");
        std.process.exit(1);
    };

    // Find .git directory
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Check if target is a branch name or commit hash
    if (refs.branchExists(git_path, target, platform_impl, allocator) catch false) {
        // Switch to branch
        refs.updateHEAD(git_path, target, platform_impl, allocator) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "error: failed to checkout branch '{s}': {}\n", .{ target, err });
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            return;
        };

        const success_msg = try std.fmt.allocPrint(allocator, "Switched to branch '{s}'\n", .{target});
        defer allocator.free(success_msg);
        try platform_impl.writeStdout(success_msg);
    } else if (target.len == 40 and isValidHash(target)) {
        // Detached HEAD checkout
        refs.updateHEAD(git_path, target, platform_impl, allocator) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "error: failed to checkout commit '{s}': {}\n", .{ target, err });
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            return;
        };

        const short_hash = target[0..7];
        const success_msg = try std.fmt.allocPrint(allocator, "HEAD is now at {s}\n", .{short_hash});
        defer allocator.free(success_msg);
        try platform_impl.writeStdout(success_msg);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "error: pathspec '{s}' did not match any file(s) known to git\n", .{target});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    }
}

fn cmdMerge(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("merge: not supported in freestanding mode\n");
        return;
    }

    _ = args;
    const msg = try std.fmt.allocPrint(allocator, "ziggit merge: not yet implemented\n", .{});
    defer allocator.free(msg);
    try platform_impl.writeStderr(msg);
}

fn isValidHash(hash: []const u8) bool {
    if (hash.len != 40) return false;
    for (hash) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
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
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
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
            try platform_impl.writeStderr("error: branch name required\n");
            return;
        };

        const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch "master";
        defer allocator.free(current_branch);

        if (std.mem.eql(u8, branch_name, current_branch)) {
            try platform_impl.writeStderr("error: Cannot delete branch 'master' checked out at 'HEAD'\n");
            return;
        }

        refs.deleteBranch(git_path, branch_name, platform_impl, allocator) catch |err| switch (err) {
            error.FileNotFound => {
                const msg = try std.fmt.allocPrint(allocator, "error: branch '{s}' not found.\n", .{branch_name});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                return;
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
                try platform_impl.writeStderr("fatal: Not a valid object name: 'HEAD'.\n");
                return;
            },
            error.InvalidStartPoint => {
                const msg = try std.fmt.allocPrint(allocator, "fatal: Not a valid object name: '{s}'.\n", .{start_point.?});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                return;
            },
            else => return err,
        };
    }
}
