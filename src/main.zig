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

    // Use platform-specific argument handling for WASM compatibility
    const args_result = if (@import("builtin").target.os.tag == .wasi) 
        try std.process.ArgIterator.initWithAllocator(allocator) 
    else 
        std.process.args();
    
    var args = args_result;
    defer if (@import("builtin").target.os.tag == .wasi) args.deinit();
    
    _ = args.skip(); // skip program name

    const command = args.next() orelse {
        try showUsage(stdout);
        return;
    };

    if (std.mem.eql(u8, command, "init")) {
        try cmdInit(allocator, &args, stdout, stderr);
    } else if (std.mem.eql(u8, command, "status")) {
        try cmdStatus(allocator, &args, stdout, stderr);
    } else if (std.mem.eql(u8, command, "add")) {
        try cmdAdd(allocator, &args, stdout, stderr);
    } else if (std.mem.eql(u8, command, "commit")) {
        try cmdCommit(allocator, &args, stdout, stderr);
    } else if (std.mem.eql(u8, command, "log")) {
        try cmdLog(allocator, &args, stdout, stderr);
    } else if (std.mem.eql(u8, command, "diff")) {
        try cmdDiff(allocator, &args, stdout, stderr);
    } else if (std.mem.eql(u8, command, "branch")) {
        try cmdBranch(allocator, &args, stdout, stderr);
    } else if (std.mem.eql(u8, command, "checkout")) {
        try cmdCheckout(allocator, &args, stdout, stderr);
    } else if (std.mem.eql(u8, command, "merge")) {
        try cmdMerge(allocator, &args, stdout, stderr);
    } else {
        try stderr.print("ziggit: '{s}' is not a ziggit command. See 'ziggit --help'.\n", .{command});
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

fn showUsage(stdout: anytype) !void {
    try stdout.print("usage: ziggit <command> [<args>]\n\n", .{});
    try stdout.print("These are common ziggit commands used in various situations:\n\n", .{});
    try stdout.print("start a working area (see also: ziggit help tutorial)\n", .{});
    try stdout.print("   init       Create an empty Git repository or reinitialize an existing one\n\n", .{});
    try stdout.print("work on the current change (see also: ziggit help everyday)\n", .{});
    try stdout.print("   add        Add file contents to the index\n", .{});
    try stdout.print("   status     Show the working tree status\n", .{});
    try stdout.print("   commit     Record changes to the repository\n", .{});
    try stdout.print("   log        Show commit logs\n", .{});
    try stdout.print("   diff       Show changes between commits, commit and working tree, etc\n\n", .{});
}

fn cmdAdd(allocator: std.mem.Allocator, args: *std.process.ArgIterator, stdout: anytype, stderr: anytype) !void {
    _ = stdout;
    
    const git_dir = findGitDir() catch |err| switch (err) {
        GitError.NotAGitRepository => {
            try stderr.print("fatal: not a git repository (or any of the parent directories): .git\n", .{});
            std.process.exit(128);
        },
        else => return err,
    };
    defer std.heap.page_allocator.free(git_dir);
    
    // Collect all file arguments
    var files = std.ArrayList([]const u8).init(allocator);
    defer files.deinit();
    
    while (args.next()) |arg| {
        try files.append(arg);
    }
    
    if (files.items.len == 0) {
        try stderr.print("Nothing specified, nothing added.\n", .{});
        try stderr.print("hint: Maybe you wanted to say 'git add .'?\n", .{});
        try stderr.print("hint: Turn this message off by running\n", .{});
        try stderr.print("hint: \"git config advice.addEmptyPathspec false\"\n", .{});
        return;
    }
    
    // Load the index
    var idx = index_mod.Index.load(git_dir, allocator) catch |err| {
        try stderr.print("fatal: unable to read index: {}\n", .{err});
        std.process.exit(128);
    };
    defer idx.deinit();
    
    // Add each file to the index
    for (files.items) |file_path| {
        if (std.mem.eql(u8, file_path, ".")) {
            // Add all files in current directory
            try addAllFiles(git_dir, &idx, ".", allocator, stderr);
        } else {
            // Add specific file
            const abs_path = try getAbsolutePath(file_path, allocator);
            defer allocator.free(abs_path);
            
            // Check if file exists
            std.fs.accessAbsolute(abs_path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    try stderr.print("fatal: pathspec '{s}' did not match any files\n", .{file_path});
                    std.process.exit(128);
                },
                else => return err,
            };
            
            // Get relative path for the index
            var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const cwd = try std.process.getCwd(&cwd_buf);
            
            const rel_path = if (std.fs.path.isAbsolute(file_path)) 
                try std.fs.path.relative(allocator, cwd, abs_path)
            else 
                try allocator.dupe(u8, file_path);
            defer allocator.free(rel_path);
            
            // Create blob and add to index
            addFileToIndex(git_dir, &idx, rel_path, abs_path, allocator, stderr) catch |err| {
                try stderr.print("error: unable to add '{s}': {}\n", .{ file_path, err });
                std.process.exit(128);
            };
        }
    }
    
    // Save the index
    idx.save(git_dir) catch |err| {
        try stderr.print("fatal: unable to write index: {}\n", .{err});
        std.process.exit(128);
    };
}

fn cmdCommit(allocator: std.mem.Allocator, args: *std.process.ArgIterator, stdout: anytype, stderr: anytype) !void {
    // Parse arguments
    var message: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-m") and arg.len > 2) {
            message = arg[2..];
        } else if (std.mem.eql(u8, arg, "-m")) {
            message = args.next() orelse {
                try stderr.print("fatal: option '-m' requires a value\n", .{});
                std.process.exit(128);
            };
        }
    }
    
    // Find git repository
    const git_dir = findGitDir() catch |err| switch (err) {
        GitError.NotAGitRepository => {
            try stderr.print("fatal: not a git repository (or any of the parent directories): .git\n", .{});
            std.process.exit(128);
        },
        else => return err,
    };
    defer std.heap.page_allocator.free(git_dir);
    
    // Load the index
    var idx = index_mod.Index.load(git_dir, allocator) catch |err| {
        try stderr.print("fatal: unable to read index: {}\n", .{err});
        std.process.exit(128);
    };
    defer idx.deinit();
    
    // Check if index is empty
    if (idx.entries.items.len == 0) {
        const current_branch = refs.getCurrentBranch(git_dir, allocator) catch |err| switch (err) {
            error.InvalidHEAD => {
                try stderr.print("fatal: bad HEAD - strange repository\n", .{});
                std.process.exit(128);
            },
            else => return err,
        };
        defer allocator.free(current_branch);
        
        const current_commit = refs.getCurrentCommit(git_dir, allocator) catch null;
        if (current_commit) |commit| {
            defer allocator.free(commit);
            try stderr.print("On branch {s}\nnothing to commit, working tree clean\n", .{current_branch});
        } else {
            try stderr.print("On branch {s}\n\nNo commits yet\n\nnothing to commit (create/copy files and use \"git add\" to track)\n", .{current_branch});
        }
        std.process.exit(1);
    }
    
    // Create tree object from index
    var tree_entries = std.ArrayList(objects.TreeEntry).init(allocator);
    defer tree_entries.deinit();
    
    for (idx.entries.items) |entry| {
        const hash_str = try std.fmt.allocPrint(allocator, "{x}", .{std.fmt.fmtSliceHexLower(&entry.hash)});
        defer allocator.free(hash_str);
        
        const mode = if (entry.mode & 0o100000 != 0) "100644" else "040000"; // File vs directory
        const tree_entry = objects.TreeEntry.init(try allocator.dupe(u8, mode), try allocator.dupe(u8, entry.path), try allocator.dupe(u8, hash_str));
        try tree_entries.append(tree_entry);
    }
    defer {
        for (tree_entries.items) |entry| {
            allocator.free(entry.mode);
            allocator.free(entry.name);
            allocator.free(entry.hash);
        }
    }
    
    const tree_object = objects.createTreeObject(tree_entries.items, allocator) catch |err| {
        try stderr.print("fatal: unable to create tree object: {}\n", .{err});
        std.process.exit(128);
    };
    defer tree_object.deinit(allocator);
    
    const tree_hash = tree_object.store(git_dir, allocator) catch |err| {
        try stderr.print("fatal: unable to store tree object: {}\n", .{err});
        std.process.exit(128);
    };
    defer allocator.free(tree_hash);
    
    // Get current commit (parent)
    const parent_commit = refs.getCurrentCommit(git_dir, allocator) catch null;
    defer if (parent_commit) |p| allocator.free(p);
    
    var parents = std.ArrayList([]const u8).init(allocator);
    defer parents.deinit();
    if (parent_commit) |p| {
        try parents.append(p);
    }
    
    // Create commit message
    const commit_message = message orelse "Initial commit";
    
    // Create author/committer info
    const timestamp = std.time.timestamp();
    const author_info = try std.fmt.allocPrint(allocator, "User <user@example.com> {d} +0000", .{timestamp});
    defer allocator.free(author_info);
    
    // Create commit object
    const commit_object = objects.createCommitObject(tree_hash, parents.items, author_info, author_info, commit_message, allocator) catch |err| {
        try stderr.print("fatal: unable to create commit object: {}\n", .{err});
        std.process.exit(128);
    };
    defer commit_object.deinit(allocator);
    
    const commit_hash = commit_object.store(git_dir, allocator) catch |err| {
        try stderr.print("fatal: unable to store commit object: {}\n", .{err});
        std.process.exit(128);
    };
    defer allocator.free(commit_hash);
    
    // Update branch reference
    const current_branch = refs.getCurrentBranch(git_dir, allocator) catch |err| switch (err) {
        error.InvalidHEAD => {
            try stderr.print("fatal: bad HEAD - strange repository\n", .{});
            std.process.exit(128);
        },
        else => return err,
    };
    defer allocator.free(current_branch);
    
    if (!std.mem.eql(u8, current_branch, "HEAD")) {
        refs.updateRef(git_dir, current_branch, commit_hash, allocator) catch |err| {
            try stderr.print("fatal: unable to update branch: {}\n", .{err});
            std.process.exit(128);
        };
    } else {
        // Update detached HEAD
        refs.updateHEAD(git_dir, commit_hash, allocator) catch |err| {
            try stderr.print("fatal: unable to update HEAD: {}\n", .{err});
            std.process.exit(128);
        };
    }
    
    // Print success message
    const short_hash = commit_hash[0..7];
    if (parent_commit == null) {
        try stdout.print("[{s} (root-commit) {s}] {s}\n", .{ current_branch, short_hash, commit_message });
    } else {
        try stdout.print("[{s} {s}] {s}\n", .{ current_branch, short_hash, commit_message });
    }
    try stdout.print(" {d} file(s) changed\n", .{idx.entries.items.len});
}

fn cmdLog(allocator: std.mem.Allocator, args: *std.process.ArgIterator, stdout: anytype, stderr: anytype) !void {
    _ = args; // TODO: parse log-specific arguments like --oneline, -n, etc.
    
    // Find git repository
    const git_dir = findGitDir() catch |err| switch (err) {
        GitError.NotAGitRepository => {
            try stderr.print("fatal: not a git repository (or any of the parent directories): .git\n", .{});
            std.process.exit(128);
        },
        else => return err,
    };
    defer std.heap.page_allocator.free(git_dir);
    
    // Get current commit
    const current_commit = refs.getCurrentCommit(git_dir, allocator) catch |err| switch (err) {
        else => {
            try stderr.print("fatal: your current branch 'master' does not have any commits yet\n", .{});
            std.process.exit(128);
        },
    } orelse {
        try stderr.print("fatal: your current branch 'master' does not have any commits yet\n", .{});
        std.process.exit(128);
    };
    defer allocator.free(current_commit);
    
    // Walk the commit history
    var commit_hash = try allocator.dupe(u8, current_commit);
    defer allocator.free(commit_hash);
    
    while (true) {
        // Load commit object
        const commit_object = objects.GitObject.load(commit_hash, git_dir, allocator) catch |err| switch (err) {
            error.ObjectNotFound => {
                try stderr.print("fatal: bad object {s}\n", .{commit_hash});
                std.process.exit(128);
            },
            else => return err,
        };
        defer commit_object.deinit(allocator);
        
        if (commit_object.type != .commit) {
            try stderr.print("fatal: object {s} is not a commit\n", .{commit_hash});
            std.process.exit(128);
        }
        
        // Parse commit data
        const commit_data = commit_object.data;
        var lines = std.mem.split(u8, commit_data, "\n");
        
        var tree_hash: ?[]const u8 = null;
        var parents = std.ArrayList([]const u8).init(allocator);
        defer parents.deinit();
        var author: ?[]const u8 = null;
        var committer: ?[]const u8 = null;
        
        // Parse headers
        while (lines.next()) |line| {
            if (line.len == 0) break; // End of headers
            
            if (std.mem.startsWith(u8, line, "tree ")) {
                tree_hash = line["tree ".len..];
            } else if (std.mem.startsWith(u8, line, "parent ")) {
                try parents.append(line["parent ".len..]);
            } else if (std.mem.startsWith(u8, line, "author ")) {
                author = line["author ".len..];
            } else if (std.mem.startsWith(u8, line, "committer ")) {
                committer = line["committer ".len..];
            }
        }
        
        // Get commit message
        var message = std.ArrayList(u8).init(allocator);
        defer message.deinit();
        while (lines.next()) |line| {
            if (message.items.len > 0) {
                try message.append('\n');
            }
            try message.appendSlice(line);
        }
        
        // Print commit info
        try stdout.print("commit {s}\n", .{commit_hash});
        if (author) |a| {
            try stdout.print("Author: {s}\n", .{a});
        }
        if (committer) |c| {
            // Extract timestamp from committer info (format: "Name <email> timestamp timezone")
            // Find second-to-last space (before timezone offset)
            var spaces: [2]usize = undefined;
            var space_count: usize = 0;
            var i: usize = c.len;
            while (i > 0 and space_count < 2) {
                i -= 1;
                if (c[i] == ' ') {
                    spaces[space_count] = i;
                    space_count += 1;
                }
            }
            
            if (space_count >= 2) {
                const timestamp_start = spaces[1] + 1;
                const timestamp_end = spaces[0];
                const timestamp_str = c[timestamp_start..timestamp_end];
                if (std.fmt.parseInt(i64, timestamp_str, 10)) |timestamp| {
                    // For now just show the timestamp - could format as human readable later
                    try stdout.print("Date: {d}\n", .{timestamp});
                } else |_| {
                    try stdout.print("Date: {s}\n", .{c});
                }
            } else {
                try stdout.print("Date: {s}\n", .{c});
            }
        }
        try stdout.print("\n    {s}\n\n", .{message.items});
        
        // Move to parent commit
        if (parents.items.len == 0) break; // No more parents
        
        allocator.free(commit_hash);
        commit_hash = try allocator.dupe(u8, parents.items[0]);
    }
}

fn cmdDiff(allocator: std.mem.Allocator, args: *std.process.ArgIterator, stdout: anytype, stderr: anytype) !void {
    _ = args; // TODO: parse diff-specific arguments like --cached, file paths
    
    // Find git repository
    const git_dir = findGitDir() catch |err| switch (err) {
        GitError.NotAGitRepository => {
            try stderr.print("fatal: not a git repository (or any of the parent directories): .git\n", .{});
            std.process.exit(128);
        },
        else => return err,
    };
    defer std.heap.page_allocator.free(git_dir);
    
    // Load the index
    var idx = index_mod.Index.load(git_dir, allocator) catch |err| {
        try stderr.print("fatal: unable to read index: {}\n", .{err});
        std.process.exit(128);
    };
    defer idx.deinit();
    
    // For basic implementation, show diff between working tree and index (staged)
    // This would normally show changes that are not staged
    var has_diff = false;
    
    for (idx.entries.items) |entry| {
        // Read current file content
        const file = std.fs.cwd().openFile(entry.path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // File was deleted
                try stdout.print("diff --git a/{s} b/{s}\n", .{ entry.path, entry.path });
                try stdout.print("deleted file mode {o}\n", .{entry.mode});
                try stdout.print("index {x}..0000000\n", .{std.fmt.fmtSliceHexLower(entry.hash[0..7])});
                try stdout.print("--- a/{s}\n", .{entry.path});
                try stdout.print("+++ /dev/null\n", .{});
                has_diff = true;
                continue;
            },
            else => return err,
        };
        defer file.close();
        
        const stat = try file.stat();
        
        // Check if file has been modified (simple comparison by size and mtime)
        if (stat.size != entry.size or @as(u32, @intCast(@divTrunc(stat.mtime, std.time.ns_per_s))) != entry.mtime_sec) {
            // File has been modified
            const content = try file.readToEndAlloc(allocator, stat.size);
            defer allocator.free(content);
            
            // Create blob to get hash
            const blob = objects.createBlobObject(content);
            const current_hash_str = try blob.hash(allocator);
            defer allocator.free(current_hash_str);
            
            const index_hash_str = try std.fmt.allocPrint(allocator, "{x}", .{std.fmt.fmtSliceHexLower(&entry.hash)});
            defer allocator.free(index_hash_str);
            
            if (!std.mem.eql(u8, current_hash_str, index_hash_str)) {
                try stdout.print("diff --git a/{s} b/{s}\n", .{ entry.path, entry.path });
                try stdout.print("index {s}..{s} {o}\n", .{ index_hash_str[0..7], current_hash_str[0..7], entry.mode });
                try stdout.print("--- a/{s}\n", .{entry.path});
                try stdout.print("+++ b/{s}\n", .{entry.path});
                
                // Load old content from git object
                const old_object = objects.GitObject.load(index_hash_str, git_dir, allocator) catch |load_err| {
                    try stdout.print("@@ -1,1 +1,1 @@\n", .{});
                    try stdout.print("-[cannot load old content: {}]\n", .{load_err});
                    try stdout.print("+{s}", .{content});
                    has_diff = true;
                    continue;
                };
                defer old_object.deinit(allocator);
                
                // Generate simple line-by-line diff
                try generateSimpleDiff(allocator, old_object.data, content, stdout);
                
                has_diff = true;
            }
        }
    }
    
    // Check for untracked files (simplified)
    // TODO: Implement proper untracked file detection
    
    if (!has_diff) {
        // No output when no differences (like real git)
    }
}

fn cmdBranch(allocator: std.mem.Allocator, args: *std.process.ArgIterator, stdout: anytype, stderr: anytype) !void {
    // Find git repository
    const git_dir = findGitDir() catch |err| switch (err) {
        GitError.NotAGitRepository => {
            try stderr.print("fatal: not a git repository (or any of the parent directories): .git\n", .{});
            std.process.exit(128);
        },
        else => return err,
    };
    defer std.heap.page_allocator.free(git_dir);
    
    // Parse arguments
    var new_branch_name: ?[]const u8 = null;
    var delete_branch: ?[]const u8 = null;
    var force_delete = false;
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d")) {
            delete_branch = args.next() orelse {
                try stderr.print("fatal: branch name required\n", .{});
                std.process.exit(128);
            };
        } else if (std.mem.eql(u8, arg, "-D")) {
            force_delete = true;
            delete_branch = args.next() orelse {
                try stderr.print("fatal: branch name required\n", .{});
                std.process.exit(128);
            };
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            new_branch_name = arg;
        }
    }
    
    // Handle delete branch
    if (delete_branch) |branch_name| {
        const current_branch = refs.getCurrentBranch(git_dir, allocator) catch |err| switch (err) {
            error.InvalidHEAD => {
                try stderr.print("fatal: bad HEAD - strange repository\n", .{});
                std.process.exit(128);
            },
            else => return err,
        };
        defer allocator.free(current_branch);
        
        if (std.mem.eql(u8, branch_name, current_branch)) {
            try stderr.print("error: Cannot delete branch '{s}' checked out\n", .{branch_name});
            std.process.exit(1);
        }
        
        if (refs.branchExists(git_dir, branch_name, allocator) catch false) {
            refs.deleteBranch(git_dir, branch_name, allocator) catch |err| {
                try stderr.print("fatal: unable to delete branch: {}\n", .{err});
                std.process.exit(128);
            };
            try stdout.print("Deleted branch {s}.\n", .{branch_name});
        } else {
            try stderr.print("error: branch '{s}' not found.\n", .{branch_name});
            std.process.exit(1);
        }
        return;
    }
    
    // Handle create branch
    if (new_branch_name) |branch_name| {
        if (refs.branchExists(git_dir, branch_name, allocator) catch false) {
            try stderr.print("fatal: A branch named '{s}' already exists.\n", .{branch_name});
            std.process.exit(128);
        }
        
        refs.createBranch(git_dir, branch_name, null, allocator) catch |err| switch (err) {
            error.NoCommitsYet => {
                try stderr.print("fatal: Not a valid object name: 'HEAD'.\n", .{});
                std.process.exit(128);
            },
            else => {
                try stderr.print("fatal: unable to create branch: {}\n", .{err});
                std.process.exit(128);
            },
        };
        return;
    }
    
    // List all branches
    const current_branch = refs.getCurrentBranch(git_dir, allocator) catch |err| switch (err) {
        error.InvalidHEAD => {
            try stderr.print("fatal: bad HEAD - strange repository\n", .{});
            std.process.exit(128);
        },
        else => return err,
    };
    defer allocator.free(current_branch);
    
    var branches = refs.listBranches(git_dir, allocator) catch |err| {
        try stderr.print("fatal: unable to list branches: {}\n", .{err});
        std.process.exit(128);
    };
    defer {
        for (branches.items) |branch| {
            allocator.free(branch);
        }
        branches.deinit();
    }
    
    if (branches.items.len == 0) {
        // No branches yet - repository has no commits
        return;
    }
    
    // Sort branches
    std.sort.block([]u8, branches.items, {}, struct {
        fn lessThan(context: void, lhs: []u8, rhs: []u8) bool {
            _ = context;
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    
    for (branches.items) |branch| {
        if (std.mem.eql(u8, branch, current_branch)) {
            try stdout.print("* {s}\n", .{branch});
        } else {
            try stdout.print("  {s}\n", .{branch});
        }
    }
}

fn cmdCheckout(allocator: std.mem.Allocator, args: *std.process.ArgIterator, stdout: anytype, stderr: anytype) !void {
    // Find git repository
    const git_dir = findGitDir() catch |err| switch (err) {
        GitError.NotAGitRepository => {
            try stderr.print("fatal: not a git repository (or any of the parent directories): .git\n", .{});
            std.process.exit(128);
        },
        else => return err,
    };
    defer std.heap.page_allocator.free(git_dir);
    
    // Parse arguments
    var target_branch: ?[]const u8 = null;
    var create_branch = false;
    var force_checkout = false;
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-b")) {
            create_branch = true;
            target_branch = args.next() orelse {
                try stderr.print("fatal: switch `b' requires a value\n", .{});
                std.process.exit(128);
            };
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force_checkout = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            target_branch = arg;
        }
    }
    
    if (target_branch == null) {
        // Check if in empty repository
        const current_commit = refs.getCurrentCommit(git_dir, allocator) catch null;
        if (current_commit) |c| {
            allocator.free(c);
        }
        if (current_commit == null) {
            try stderr.print("fatal: You are on a branch yet to be born\n", .{});
            std.process.exit(1);
        }
        try stderr.print("fatal: you must specify path(s) to restore or a branch to switch to\n", .{});
        std.process.exit(128);
    }
    
    const branch_name = target_branch.?;
    
    // Get current branch for comparison
    const current_branch = refs.getCurrentBranch(git_dir, allocator) catch |err| switch (err) {
        error.InvalidHEAD => {
            try stderr.print("fatal: bad HEAD - strange repository\n", .{});
            std.process.exit(128);
        },
        else => return err,
    };
    defer allocator.free(current_branch);
    
    // Check if we're already on this branch
    if (std.mem.eql(u8, branch_name, current_branch) and !create_branch) {
        try stdout.print("Already on '{s}'\n", .{branch_name});
        return;
    }
    
    // Handle create branch
    if (create_branch) {
        if (refs.branchExists(git_dir, branch_name, allocator) catch false) {
            try stderr.print("fatal: A branch named '{s}' already exists.\n", .{branch_name});
            std.process.exit(128);
        }
        
        refs.createBranch(git_dir, branch_name, null, allocator) catch |err| switch (err) {
            error.NoCommitsYet => {
                // Create branch anyway, it will point to nothing until first commit
                refs.updateRef(git_dir, branch_name, "0000000000000000000000000000000000000000", allocator) catch |create_err| {
                    try stderr.print("fatal: unable to create branch: {}\n", .{create_err});
                    std.process.exit(128);
                };
            },
            else => {
                try stderr.print("fatal: unable to create branch: {}\n", .{err});
                std.process.exit(128);
            },
        };
    } else {
        // Check if target branch exists
        if (!(refs.branchExists(git_dir, branch_name, allocator) catch false)) {
            try stderr.print("error: pathspec '{s}' did not match any file(s) known to git\n", .{branch_name});
            std.process.exit(1);
        }
    }
    
    // Update HEAD to point to the new branch
    refs.updateHEAD(git_dir, branch_name, allocator) catch |err| {
        try stderr.print("fatal: unable to update HEAD: {}\n", .{err});
        std.process.exit(128);
    };
    
    if (create_branch) {
        try stdout.print("Switched to a new branch '{s}'\n", .{branch_name});
    } else {
        try stdout.print("Switched to branch '{s}'\n", .{branch_name});
    }
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
    const allocator = std.heap.page_allocator;
    
    // Get current branch
    const current_branch = refs.getCurrentBranch(git_dir, allocator) catch |err| switch (err) {
        error.InvalidHEAD => {
            try stdout.print("fatal: bad HEAD - strange repository\n", .{});
            std.process.exit(128);
        },
        else => return err,
    };
    defer allocator.free(current_branch);
    
    // Check if there are any commits
    const current_commit = refs.getCurrentCommit(git_dir, allocator) catch null;
    defer if (current_commit) |c| allocator.free(c);
    
    try stdout.print("On branch {s}\n", .{current_branch});
    
    if (current_commit == null) {
        try stdout.print("\nNo commits yet\n", .{});
    }
    
    // Load the index to see staged files
    var idx = index_mod.Index.load(git_dir, allocator) catch |err| {
        try stdout.print("fatal: unable to read index: {}\n", .{err});
        std.process.exit(128);
    };
    defer idx.deinit();
    
    var has_staged = false;
    const has_changes = false; // TODO: implement checking for modified files
    var has_untracked = false;
    
    // Lists to track different file states
    var untracked_files = std.ArrayList([]const u8).init(allocator);
    defer {
        for (untracked_files.items) |file| {
            allocator.free(file);
        }
        untracked_files.deinit();
    }
    
    // Check for staged files
    if (idx.entries.items.len > 0) {
        has_staged = true;
    }
    
    // Scan for untracked files
    try scanForUntrackedFiles(allocator, &idx, &untracked_files);
    if (untracked_files.items.len > 0) {
        has_untracked = true;
    }
    
    // For now, simplified output
    try stdout.print("\n", .{});
    
    if (has_staged) {
        try stdout.print("Changes to be committed:\n", .{});
        try stdout.print("  (use \"git rm --cached <file>...\" to unstage)\n", .{});
        try stdout.print("\n", .{});
        for (idx.entries.items) |entry| {
            if (current_commit == null) {
                try stdout.print("\tnew file:   {s}\n", .{entry.path});
            } else {
                try stdout.print("\tmodified:   {s}\n", .{entry.path});
            }
        }
        try stdout.print("\n", .{});
    }
    
    if (has_untracked) {
        try stdout.print("Untracked files:\n", .{});
        try stdout.print("  (use \"git add <file>...\" to include in what will be committed)\n", .{});
        try stdout.print("\n", .{});
        for (untracked_files.items) |file| {
            try stdout.print("\t{s}\n", .{file});
        }
        try stdout.print("\n", .{});
    }
    
    if (!has_staged and !has_changes and !has_untracked) {
        if (current_commit == null) {
            try stdout.print("nothing to commit (create/copy files and use \"git add\" to track)\n", .{});
        } else {
            try stdout.print("nothing to commit, working tree clean\n", .{});
        }
    }
}

fn scanForUntrackedFiles(allocator: std.mem.Allocator, idx: *const index_mod.Index, untracked_files: *std.ArrayList([]const u8)) !void {
    var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch {
        // If we can't open the current directory, skip untracked file detection
        return;
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file) {
            // Skip .git directory contents and other hidden files for now
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            
            // Check if file is in index
            const in_index = idx.getEntry(entry.name) != null;
            
            if (!in_index) {
                try untracked_files.append(try allocator.dupe(u8, entry.name));
            }
        }
    }
}

fn getAbsolutePath(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try allocator.dupe(u8, path);
    } else {
        var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const cwd = try std.process.getCwd(&cwd_buf);
        return try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, path });
    }
}

fn addFileToIndex(git_dir: []const u8, idx: *index_mod.Index, rel_path: []const u8, abs_path: []const u8, allocator: std.mem.Allocator, stderr: anytype) !void {
    // Read file content
    const file = std.fs.openFileAbsolute(abs_path, .{}) catch |err| {
        try stderr.print("error: unable to open '{s}': {}\n", .{ rel_path, err });
        return err;
    };
    defer file.close();
    
    const stat = try file.stat();
    const content = try file.readToEndAlloc(allocator, stat.size);
    defer allocator.free(content);

    // Create blob object and store it
    const blob = objects.createBlobObject(content);
    const hash_str = try blob.store(git_dir, allocator);
    defer allocator.free(hash_str);

    // Add to index
    try idx.add(rel_path, abs_path);
}

fn addAllFiles(git_dir: []const u8, idx: *index_mod.Index, dir_path: []const u8, allocator: std.mem.Allocator, stderr: anytype) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        try stderr.print("error: unable to open directory '{s}': {}\n", .{ dir_path, err });
        return err;
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file) {
            const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            defer allocator.free(file_path);
            
            const abs_path = try getAbsolutePath(file_path, allocator);
            defer allocator.free(abs_path);
            
            addFileToIndex(git_dir, idx, file_path, abs_path, allocator, stderr) catch |err| {
                try stderr.print("warning: unable to add '{s}': {}\n", .{ file_path, err });
            };
        }
    }
}

fn cmdMerge(allocator: std.mem.Allocator, args: *std.process.ArgIterator, stdout: anytype, stderr: anytype) !void {
    // Parse arguments
    var target_branch: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            target_branch = arg;
            break;
        }
    }
    
    if (target_branch == null) {
        try stderr.print("fatal: no merge target specified\n", .{});
        std.process.exit(128);
    }
    
    const git_dir = findGitDir() catch |err| switch (err) {
        GitError.NotAGitRepository => {
            try stderr.print("fatal: not a git repository (or any of the parent directories): .git\n", .{});
            std.process.exit(128);
        },
        else => return err,
    };
    defer std.heap.page_allocator.free(git_dir);
    
    // Get current branch and commit
    const current_branch = refs.getCurrentBranch(git_dir, allocator) catch |err| switch (err) {
        error.InvalidHEAD => {
            try stderr.print("fatal: bad HEAD - strange repository\n", .{});
            std.process.exit(128);
        },
        else => return err,
    };
    defer allocator.free(current_branch);
    
    const current_commit = refs.getCurrentCommit(git_dir, allocator) catch |err| {
        try stderr.print("fatal: unable to get current commit: {}\n", .{err});
        std.process.exit(128);
    } orelse {
        try stderr.print("fatal: no commits on current branch\n", .{});
        std.process.exit(128);
    };
    defer allocator.free(current_commit);
    
    // Get target branch commit
    const target_commit = refs.getBranchCommit(git_dir, target_branch.?, allocator) catch |err| {
        try stderr.print("fatal: unable to get target branch commit: {}\n", .{err});
        std.process.exit(128);
    } orelse {
        try stderr.print("fatal: branch '{s}' does not exist\n", .{target_branch.?});
        std.process.exit(128);
    };
    defer allocator.free(target_commit);
    
    // Check if already up to date
    if (std.mem.eql(u8, current_commit, target_commit)) {
        try stdout.print("Already up to date.\n", .{});
        return;
    }
    
    // For now, implement only fast-forward merge
    // TODO: Implement proper merge algorithm with conflict detection
    
    // Update current branch to point to target commit (fast-forward)
    refs.updateRef(git_dir, current_branch, target_commit, allocator) catch |err| {
        try stderr.print("fatal: unable to update branch: {}\n", .{err});
        std.process.exit(128);
    };
    
    const short_target = target_commit[0..7];
    const short_current = current_commit[0..7];
    
    try stdout.print("Fast-forward\n", .{});
    try stdout.print(" {s}..{s}  {s} -> {s}\n", .{ short_current, short_target, target_branch.?, current_branch });
}

fn generateSimpleDiff(allocator: std.mem.Allocator, old_content: []const u8, new_content: []const u8, stdout: anytype) !void {
    var old_lines = std.mem.split(u8, old_content, "\n");
    var new_lines = std.mem.split(u8, new_content, "\n");
    
    var old_line_list = std.ArrayList([]const u8).init(allocator);
    defer old_line_list.deinit();
    var new_line_list = std.ArrayList([]const u8).init(allocator);
    defer new_line_list.deinit();
    
    while (old_lines.next()) |line| {
        try old_line_list.append(line);
    }
    while (new_lines.next()) |line| {
        try new_line_list.append(line);
    }
    
    // Simple diff header
    try stdout.print("@@ -1,{} +1,{} @@\n", .{ old_line_list.items.len, new_line_list.items.len });
    
    // Show removed lines
    for (old_line_list.items) |line| {
        try stdout.print("-{s}\n", .{line});
    }
    
    // Show added lines
    for (new_line_list.items) |line| {
        try stdout.print("+{s}\n", .{line});
    }
}
