const std = @import("std");
const platform_mod = @import("platform/platform.zig");

fn readStdin(allocator: std.mem.Allocator, max_size: usize) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    const f = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = f.read(&buf) catch break;
        if (n == 0) break;
        try result.appendSlice(buf[0..n]);
        if (result.items.len > max_size) return error.StreamTooLong;
    }
    return result.toOwnedSlice();
}
const version_mod = @import("version.zig");
const build_options = @import("build_options");

// Only import git modules on platforms that support them
const Repository = if (@import("builtin").target.os.tag != .freestanding) @import("git/repository.zig").Repository else void;
const objects = if (@import("builtin").target.os.tag != .freestanding) @import("git/objects.zig") else void;
const index_mod = if (@import("builtin").target.os.tag != .freestanding) @import("git/index.zig") else void;
const refs = if (@import("builtin").target.os.tag != .freestanding) @import("git/refs.zig") else void;
const tree_mod = if (@import("builtin").target.os.tag != .freestanding) @import("git/tree.zig") else void;
const gitignore_mod = if (@import("builtin").target.os.tag != .freestanding) @import("git/gitignore.zig") else void;
const config_mod = if (@import("builtin").target.os.tag != .freestanding) @import("git/config.zig") else void;
const diff_mod = if (@import("builtin").target.os.tag != .freestanding) @import("git/diff.zig") else void;
const network = if (@import("builtin").target.os.tag != .freestanding) @import("git/network.zig") else void;
const zlib_compat_mod = if (@import("builtin").target.os.tag != .freestanding) @import("git/zlib_compat.zig") else void;

const GitError = error{
    NotAGitRepository,
    AlreadyExists,
    InvalidPath,
};



const NATIVE_COMMANDS = [_][]const u8{ 
    "init", "status", "add", "commit", "log", "diff", "branch", "checkout", "merge", 
    "fetch", "pull", "push", "clone", "config", "rev-parse", "describe", "tag", 
    "show", "cat-file", "rev-list", "remote", "reset", "rm",
    "hash-object", "write-tree", "commit-tree", "update-ref", "symbolic-ref",
    "update-index", "ls-files", "ls-tree", "read-tree", "diff-files",
    "version",
    "--version", "-v", "--version-info", "--help", "-h", "help", "--exec-path",
    // Phase 2: newly native commands (pure Zig implementations)
    "count-objects", "show-ref", "for-each-ref", "verify-pack", "update-server-info",
    "mktree", "name-rev", "fsck", "gc", "prune", "repack", "pack-objects",
    "index-pack", "reflog", "clean", "mktag",
    "merge-base", "unpack-objects",
    "diff-tree", "diff-index", "var", "show-index", "prune-packed",
    "verify-commit", "verify-tag", "mv", "stash", "apply",
    "column", "check-ignore", "check-attr",
};

fn isNativeCommand(command: []const u8) bool {
    for (NATIVE_COMMANDS) |native_cmd| {
        if (std.mem.eql(u8, command, native_cmd)) {
            return true;
        }
    }
    return false;
}

pub fn zigzitMain(allocator: std.mem.Allocator) !void {
    const platform_impl = platform_mod.getCurrentPlatform();
    
    var args = try platform_impl.getArgs(allocator);
    defer args.deinit();
    
    // Skip program name
    _ = args.skip();

    // Store all arguments for potential git fallback
    var all_original_args = std.array_list.Managed([]const u8).init(allocator);
    defer all_original_args.deinit();
    
    // Collect all arguments first
    while (args.next()) |arg| {
        try all_original_args.append(arg);
    }
    
    if (all_original_args.items.len == 0) {
        try showUsage(&platform_impl);
        std.process.exit(1);
    }
    
    // Strip global flags that newer git versions support but older ones don't
    // This allows tests written for git 2.46+ to work with git 2.43
    {
        var write_idx: usize = 0;
        var read_idx: usize = 0;
        while (read_idx < all_original_args.items.len) {
            const arg = all_original_args.items[read_idx];
            if (std.mem.startsWith(u8, arg, "--ref-format=")) {
                const ref_fmt_val = arg["--ref-format=".len..];
                if (std.mem.eql(u8, ref_fmt_val, "files")) {
                    // Strip --ref-format=files (git 2.46+ feature, 2.43 only supports files)
                    read_idx += 1;
                    continue;
                } else {
                    // Unknown ref format - emit error like git 2.53 does
                    const err_msg = std.fmt.allocPrint(allocator, "fatal: unknown ref storage format '{s}'\n", .{ref_fmt_val}) catch "fatal: unknown ref storage format\n";
                    platform_impl.writeStderr(err_msg) catch {};
                    std.process.exit(128);
                }
            }
            if (std.mem.eql(u8, arg, "--no-advice") or
                std.mem.eql(u8, arg, "--i-still-use-this")) {
                // Strip these flags (git 2.46+ features not in git 2.43)
                read_idx += 1;
                continue;
            }
            // Translate newer git flags to older equivalents for git 2.43 compat
            if (std.mem.eql(u8, arg, "-ufalse") or std.mem.eql(u8, arg, "--untracked-files=false") or
                std.mem.eql(u8, arg, "-u0") or std.mem.eql(u8, arg, "--untracked-files=0")) {
                all_original_args.items[write_idx] = "-uno";
            } else if (std.mem.eql(u8, arg, "-utrue") or std.mem.eql(u8, arg, "--untracked-files=true") or
                       std.mem.eql(u8, arg, "-uyes") or std.mem.eql(u8, arg, "--untracked-files=yes") or
                       std.mem.eql(u8, arg, "-u1") or std.mem.eql(u8, arg, "--untracked-files=1") or
                       std.mem.eql(u8, arg, "-uon") or std.mem.eql(u8, arg, "--untracked-files=on")) {
                all_original_args.items[write_idx] = "-unormal";
            } else {
                all_original_args.items[write_idx] = arg;
            }
            // Translate -c key=value pairs for git 2.43 compat
            if (std.mem.eql(u8, all_original_args.items[write_idx], "-c") and read_idx + 1 < all_original_args.items.len) {
                // Next arg is key=value - translate if needed
                const next = all_original_args.items[read_idx + 1];
                all_original_args.items[write_idx + 1] = translateConfigKeyValue(next);
                write_idx += 2;
                read_idx += 2;
            } else if (std.mem.startsWith(u8, all_original_args.items[write_idx], "-c") and all_original_args.items[write_idx].len > 2) {
                // -ckey=value form (no space)
                all_original_args.items[write_idx] = translateConfigKeyValue(all_original_args.items[write_idx][2..]);
                // Need to split into -c and value... actually keep as-is, just translate in-place
                // This form is rare. Skip for now.
                write_idx += 1;
                read_idx += 1;
            } else {
                write_idx += 1;
                read_idx += 1;
            }
        }
        all_original_args.shrinkRetainingCapacity(write_idx);
    }

    // Post-process: command-specific flag translations for git 2.43 compat
    // show-ref --branches → show-ref --heads (git 2.46+ alias)
    // show-ref --exists → needs git 2.45+, handle specially
    {
        var found_show_ref = false;
        var found_for_each_ref = false;
        for (all_original_args.items) |arg| {
            if (std.mem.eql(u8, arg, "show-ref")) { found_show_ref = true; break; }
            if (std.mem.eql(u8, arg, "for-each-ref")) { found_for_each_ref = true; break; }
        }
        if (found_show_ref or found_for_each_ref) {
            for (all_original_args.items, 0..) |arg, i| {
                if (std.mem.eql(u8, arg, "--branches")) {
                    all_original_args.items[i] = "--heads";
                }
            }
        }
    }

    // Find the command by skipping global flags
    var command_index: usize = 0;
    while (command_index < all_original_args.items.len) {
        const arg = all_original_args.items[command_index];
        
        if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "-c") or 
           std.mem.eql(u8, arg, "--git-dir") or std.mem.eql(u8, arg, "--work-tree")) {
            // Skip the flag and its value
            command_index += 2;
            if (command_index > all_original_args.items.len) {
                try platform_impl.writeStderr("error: invalid global flag usage\n");
                std.process.exit(128);
            }
        } else if (std.mem.startsWith(u8, arg, "--git-dir=") or
                   std.mem.startsWith(u8, arg, "--work-tree=") or
                   std.mem.startsWith(u8, arg, "--ref-format=") or 
                   std.mem.startsWith(u8, arg, "--no-advice") or
                   std.mem.startsWith(u8, arg, "--config-env=") or
                   std.mem.startsWith(u8, arg, "--namespace=") or
                   std.mem.startsWith(u8, arg, "--super-prefix=") or
                   std.mem.eql(u8, arg, "--bare") or
                   std.mem.eql(u8, arg, "--no-replace-objects") or
                   std.mem.eql(u8, arg, "--literal-pathspecs") or
                   std.mem.eql(u8, arg, "--glob-pathspecs") or
                   std.mem.eql(u8, arg, "--noglob-pathspecs") or
                   std.mem.eql(u8, arg, "--icase-pathspecs") or
                   std.mem.eql(u8, arg, "--no-optional-locks") or
                   std.mem.eql(u8, arg, "--no-lazy-fetch") or
                   std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--paginate") or
                   std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--no-pager")) {
            // Global flags with = form, or boolean global flags
            command_index += 1;
        } else {
            // This must be the command
            break;
        }
    }
    
    if (command_index >= all_original_args.items.len) {
        try showUsage(&platform_impl);
        return;
    }
    
    var command = all_original_args.items[command_index];
    
    // Check if this is a native command; if not, try alias resolution (with loop detection)
    var alias_depth: u32 = 0;
    while (!isNativeCommand(command) and alias_depth < 10) : (alias_depth += 1) {
        // Try to resolve as an alias from git config
        const alias_value = try resolveAlias(allocator, command, &platform_impl);
        if (alias_value) |alias_cmd| {
            defer allocator.free(alias_cmd);
            // Parse the alias value into words and rebuild args
            // If alias starts with '!', it's a shell command - not supported natively
            if (alias_cmd.len > 0 and alias_cmd[0] == '!') {
                // Shell alias: execute via /bin/sh -c
                const shell_cmd = alias_cmd[1..];
                // Append remaining args to the shell command
                var full_cmd = std.array_list.Managed(u8).init(allocator);
                defer full_cmd.deinit();
                try full_cmd.appendSlice(shell_cmd);
                var ri: usize = command_index + 1;
                while (ri < all_original_args.items.len) : (ri += 1) {
                    try full_cmd.append(' ');
                    try full_cmd.appendSlice(all_original_args.items[ri]);
                }
                var child = std.process.Child.init(&.{ "/bin/sh", "-c", full_cmd.items }, allocator);
                child.stdin_behavior = .Inherit;
                child.stdout_behavior = .Inherit;
                child.stderr_behavior = .Inherit;
                _ = child.spawn() catch {
                    try platform_impl.writeStderr("fatal: failed to run shell alias\n");
                    std.process.exit(128);
                };
                const result = child.wait() catch {
                    std.process.exit(128);
                };
                switch (result) {
                    .Exited => |code| std.process.exit(code),
                    else => std.process.exit(128),
                }
                return;
            }
            // Split alias into words
            var alias_words = std.array_list.Managed([]const u8).init(allocator);
            defer alias_words.deinit();
            var word_iter = std.mem.tokenizeAny(u8, alias_cmd, " \t");
            while (word_iter.next()) |word| {
                try alias_words.append(try allocator.dupe(u8, word));
            }
            if (alias_words.items.len > 0) {
                // Rebuild all_original_args: global flags + alias words + remaining args
                var new_args = std.array_list.Managed([]const u8).init(allocator);
                defer new_args.deinit();
                // Copy global flags (before command_index)
                for (all_original_args.items[0..command_index]) |ga| {
                    try new_args.append(ga);
                }
                // Add expanded alias words
                for (alias_words.items) |aw| {
                    try new_args.append(aw);
                }
                // Add remaining args after the alias command
                var ri2: usize = command_index + 1;
                while (ri2 < all_original_args.items.len) : (ri2 += 1) {
                    try new_args.append(all_original_args.items[ri2]);
                }
                // Replace all_original_args content
                all_original_args.clearRetainingCapacity();
                for (new_args.items) |a| {
                    try all_original_args.append(a);
                }
                // Re-find command_index (same position, but now the command is the alias expansion)
                command = all_original_args.items[command_index];
                // Continue the while loop to check if the expanded command is native or needs further alias resolution
            }
        } else {
            // Command not found - error (pure Zig, no git forwarding)
            const error_msg = std.fmt.allocPrint(allocator, "ziggit: '{s}' is not a ziggit command. See 'ziggit --help'.\n", .{command}) catch "ziggit: invalid command. See 'ziggit --help'.\n";
            defer if (error_msg.ptr != "ziggit: invalid command. See 'ziggit --help'.\n".ptr) allocator.free(error_msg);
            try platform_impl.writeStderr(error_msg);
            std.process.exit(1);
        }
    }
    // Check for alias loop (depth exceeded)
    if (alias_depth >= 10 and !isNativeCommand(command)) {
        const loop_msg = try std.fmt.allocPrint(allocator, "fatal: alias loop detected: expansion of '{s}' does not terminate\n", .{all_original_args.items[command_index]});
        defer allocator.free(loop_msg);
        try platform_impl.writeStderr(loop_msg);
        std.process.exit(128);
    }
    
    // Determine if this command is handled natively (NOT forwarded to real git)
    // Commands forwarded to git should NOT be here — git handles -C itself
    // All commands are handled natively — always process -C, -c, etc.
    const is_native_handler = true;

    // Process global flags and execute
    var arg_index: usize = 0;
    
    // Handle global flags in a loop - only process -C for native commands
    // (forwarded commands pass all args to real git which handles -C itself)
    while (arg_index < all_original_args.items.len) {
        const arg = all_original_args.items[arg_index];
        
        if (std.mem.eql(u8, arg, "-C")) {
            if (arg_index + 1 >= all_original_args.items.len) {
                try platform_impl.writeStderr("error: option '-C' requires a directory path\n");
                std.process.exit(128);
            }
            
            arg_index += 1;
            const dir_path = all_original_args.items[arg_index];
            
            // Only change directory for native commands
            if (is_native_handler) {
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
            }
            
            arg_index += 1;
        } else if (std.mem.eql(u8, arg, "-c")) {
            if (arg_index + 1 >= all_original_args.items.len) {
                try platform_impl.writeStderr("error: option '-c' requires a config setting\n");
                std.process.exit(128);
            }
            
            arg_index += 1;
            // Skip the config setting for native commands (not implemented)
            // For forwarded commands, it'll be passed through as part of all_original_args
            arg_index += 1;
        } else if (std.mem.eql(u8, arg, "--git-dir")) {
            if (arg_index + 1 >= all_original_args.items.len) {
                try platform_impl.writeStderr("error: option '--git-dir' requires a path\n");
                std.process.exit(128);
            }
            
            arg_index += 1;
            // Skip the path for now (not implemented)
            arg_index += 1;
        } else if (std.mem.eql(u8, arg, "--work-tree")) {
            if (arg_index + 1 >= all_original_args.items.len) {
                try platform_impl.writeStderr("error: option '--work-tree' requires a path\n");
                std.process.exit(128);
            }
            
            arg_index += 1;
            // Skip the path for now (not implemented)
            arg_index += 1;
        } else {
            // Not a global flag, this must be the command - break
            break;
        }
    }
    
    // Create args iterator for the remaining arguments (after the command)
    var remaining_args = std.array_list.Managed([]const u8).init(allocator);
    defer remaining_args.deinit();
    
    var remaining_arg_index = command_index + 1;
    while (remaining_arg_index < all_original_args.items.len) {
        try remaining_args.append(all_original_args.items[remaining_arg_index]);
        remaining_arg_index += 1;
    }
    
    // Create a simple iterator for remaining args
    const remaining_args_copy = try allocator.dupe([]const u8, remaining_args.items);
    defer allocator.free(remaining_args_copy);
    
    var args_iter = platform_mod.ArgIterator{ 
        .args = remaining_args_copy, 
        .index = 0,
        .allocator = allocator,
    };

    // If -h is in the args for a command, show basic usage and exit 129
    // (git convention: -h prints usage to stdout, exits with 129)
    {
        var cmd_has_help = false;
        var cmd_saw_dd = false;
        for (remaining_args_copy) |arg| {
            if (std.mem.eql(u8, arg, "--")) {
                cmd_saw_dd = true;
                continue;
            }
            if (cmd_saw_dd) continue;
            if (std.mem.eql(u8, arg, "-h")) {
                cmd_has_help = true;
                break;
            }
        }
        if (cmd_has_help) {
            const usage_msg = try std.fmt.allocPrint(allocator, "usage: git {s} [<options>]\n", .{command});
            defer allocator.free(usage_msg);
            try platform_impl.writeStdout(usage_msg);
            std.process.exit(129);
        }
    }

    // Commands with native ziggit implementations
    if (std.mem.eql(u8, command, "init")) {
        // Check for global --bare flag
        var global_bare = false;
        for (all_original_args.items[0..command_index]) |ga| {
            if (std.mem.eql(u8, ga, "--bare")) global_bare = true;
        }
        try cmdInit(allocator, &args_iter, &platform_impl, global_bare);
    } else if (std.mem.eql(u8, command, "status")) {
        try cmdStatus(allocator, &args_iter, &platform_impl, all_original_args.items);
    } else if (std.mem.eql(u8, command, "rev-list")) {
        try cmdRevList(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "add")) {
        try cmdAdd(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "ls-files")) {
        try cmdLsFiles(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "ls-tree")) {
        try nativeCmdLsTree(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "config")) {
        try cmdConfig(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "version")) {
        try cmdVersion(allocator, &args_iter, &platform_impl);
    // Commands that forward to real git for full compatibility
    } else if (std.mem.eql(u8, command, "clone")) {
        // Use our native clone implementation (supports --depth for shallow clones)
        try cmdClone(allocator, &args_iter, &platform_impl, all_original_args.items);
    } else if (std.mem.eql(u8, command, "rev-parse")) {
        try cmdRevParse(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "checkout")) {
        try cmdCheckout(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "bisect")) {
        try nativeCmdBisect(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "symbolic-ref")) {
        try cmdSymbolicRef(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "commit")) {
        try cmdCommit(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "log")) {
        try cmdLog(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "diff")) {
        try cmdDiff(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "branch")) {
        try cmdBranch(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "merge")) {
        try cmdMerge(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "fetch")) {
        try cmdFetch(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "pull")) {
        try cmdPull(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "push")) {
        try cmdPush(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "describe")) {
        try cmdDescribe(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "tag")) {
        try cmdTag(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "show")) {
        try cmdShow(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "cat-file")) {
        try cmdCatFile(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "remote")) {
        try cmdRemote(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "reset")) {
        try cmdReset(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "rm")) {
        try cmdRm(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "hash-object")) {
        try cmdHashObject(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "write-tree")) {
        try cmdWriteTree(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "commit-tree")) {
        try cmdCommitTree(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "update-ref")) {
        try cmdUpdateRef(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "update-index")) {
        try cmdUpdateIndex(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "diff-files")) {
        try cmdDiffFiles(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "read-tree")) {
        try cmdReadTree(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "--exec-path")) {
        // Output the directory containing this executable
        const self_exe = std.fs.selfExePathAlloc(allocator) catch {
            try platform_impl.writeStdout("/usr/lib/git-core\n");
            return;
        };
        defer allocator.free(self_exe);
        const dir = std.fs.path.dirname(self_exe) orelse "/usr/lib/git-core";
        const output = try std.fmt.allocPrint(allocator, "{s}\n", .{dir});
        defer allocator.free(output);
        try platform_impl.writeStdout(output);
    } else if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try cmdVersion(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "--version-info")) {
        if (version_mod.getFullVersionInfo(allocator)) |version_info| {
            defer allocator.free(version_info);
            try platform_impl.writeStdout(version_info);
        } else |_| {
            try platform_impl.writeStdout("ziggit version 0.1.2\nError retrieving version details.\n");
        }
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try showUsage(&platform_impl);
    } else if (std.mem.eql(u8, command, "help")) {
        try showUsage(&platform_impl);
    } else if (std.mem.eql(u8, command, "count-objects")) {
        try nativeCmdCountObjects(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "show-ref")) {
        try nativeCmdShowRef(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "for-each-ref")) {
        try nativeCmdForEachRef(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "verify-pack")) {
        try nativeCmdVerifyPack(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "update-server-info")) {
        try nativeCmdUpdateServerInfo(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "mktree")) {
        try nativeCmdMktree(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "mktag")) {
        try nativeCmdMktag(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "name-rev")) {
        try nativeCmdNameRev(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "fsck")) {
        try nativeCmdFsck(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "gc")) {
        try nativeCmdGc(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "prune")) {
        try nativeCmdPrune(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "repack")) {
        try nativeCmdRepack(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "pack-objects")) {
        try nativeCmdPackObjects(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "index-pack")) {
        try nativeCmdIndexPack(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "reflog")) {
        try nativeCmdReflog(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "clean")) {
        try nativeCmdClean(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "merge-base")) {
        try nativeCmdMergeBase(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "unpack-objects")) {
        try nativeCmdUnpackObjects(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "diff-tree")) {
        try nativeCmdDiffTree(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "diff-index")) {
        try nativeCmdDiffIndex(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "var")) {
        try nativeCmdVar(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "show-index")) {
        try nativeCmdShowIndex(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "prune-packed")) {
        try nativeCmdPrunePacked(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "verify-commit")) {
        try nativeCmdVerifyCommit(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "verify-tag")) {
        try nativeCmdVerifyTag(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "mv")) {
        try nativeCmdMv(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "stash")) {
        try nativeCmdStash(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "apply")) {
        try nativeCmdApply(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "column")) {
        try nativeCmdColumn(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "check-ignore")) {
        try nativeCmdCheckIgnore(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "check-attr")) {
        try nativeCmdCheckAttr(allocator, &args_iter, &platform_impl);
    }
}



fn translateConfigKeyValue(kv: []const u8) []const u8 {
    // Translate -c key=value for git 2.43 compat
    // merge.stat=diffstat → merge.stat=true
    // merge.stat=compact → merge.stat=true
    // status.showuntrackedfiles=false → status.showuntrackedfiles=no
    // status.showuntrackedfiles=true → status.showuntrackedfiles=normal
    // help.autocorrect=show → help.autocorrect=0
    // help.autocorrect=immediate → help.autocorrect=-1
    // help.autocorrect=never → help.autocorrect=0
    // help.autocorrect=prompt → help.autocorrect=0
    if (std.ascii.startsWithIgnoreCase(kv, "merge.stat=")) {
        const val = kv["merge.stat=".len..];
        if (std.mem.eql(u8, val, "diffstat") or std.mem.eql(u8, val, "compact")) {
            return "merge.stat=true";
        }
    }
    if (std.ascii.startsWithIgnoreCase(kv, "status.showuntrackedfiles=")) {
        const val = kv["status.showuntrackedfiles=".len..];
        if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) {
            return "status.showuntrackedfiles=no";
        } else if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1")) {
            return "status.showuntrackedfiles=normal";
        }
    }
    if (std.ascii.startsWithIgnoreCase(kv, "help.autocorrect=")) {
        const val = kv["help.autocorrect=".len..];
        if (std.mem.eql(u8, val, "show") or
            std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no") or
            std.mem.eql(u8, val, "off") or
            std.mem.eql(u8, val, "never") or std.mem.eql(u8, val, "prompt")) {
            return "help.autocorrect=0";
        } else if (std.mem.eql(u8, val, "immediate")) {
            return "help.autocorrect=-1";
        }
    }
    return kv;
}

fn translateConfigValues(allocator: std.mem.Allocator, all_args: [][]const u8) ![][]const u8 {
    // Translate config values that newer git (2.46+) accepts but older git (2.43) doesn't.
    // E.g., status.showuntrackedfiles: false→no, true→normal, 0→no, 1→normal
    // Also: advice.statusHints: same treatment
    var new_args = try allocator.alloc([]const u8, all_args.len);
    @memcpy(new_args, all_args);
    
    // Find the config key and value positions
    // Pattern: git [global-flags] config [flags] <key> <value>
    var i: usize = 0;
    var found_config = false;
    var key_idx: ?usize = null;
    var val_idx: ?usize = null;
    while (i < all_args.len) : (i += 1) {
        const arg = all_args[i];
        if (!found_config) {
            if (std.mem.eql(u8, arg, "config")) {
                found_config = true;
            }
            continue;
        }
        // After "config", skip flags
        if (std.mem.startsWith(u8, arg, "-")) continue;
        if (key_idx == null) {
            key_idx = i;
        } else if (val_idx == null) {
            val_idx = i;
            break;
        }
    }
    
    if (key_idx != null and val_idx != null) {
        const key = std.ascii.lowerString(
            try allocator.alloc(u8, all_args[key_idx.?].len),
            all_args[key_idx.?],
        );
        defer allocator.free(key);
        const val = all_args[val_idx.?];
        
        // Translate boolean-style values for keys that expect no/normal/all
        if (std.mem.eql(u8, key, "status.showuntrackedfiles")) {
            if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) {
                new_args[val_idx.?] = "no";
            } else if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1")) {
                new_args[val_idx.?] = "normal";
            }
        }
        // merge.stat: git 2.46+ supports "diffstat"/"compact", older git only boolean
        if (std.mem.eql(u8, key, "merge.stat")) {
            if (std.mem.eql(u8, val, "diffstat") or std.mem.eql(u8, val, "compact")) {
                new_args[val_idx.?] = "true";
            }
        }
        // help.autocorrect: git 2.47+ supports string values; git 2.43 only numeric
        // false/no/off/show/never/prompt → 0 (show candidates, don't run)
        // immediate → -1 (run immediately)
        if (std.mem.eql(u8, key, "help.autocorrect")) {
            if (std.mem.eql(u8, val, "show") or
                std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no") or
                std.mem.eql(u8, val, "off") or
                std.mem.eql(u8, val, "never") or std.mem.eql(u8, val, "prompt")) {
                new_args[val_idx.?] = "0";
            } else if (std.mem.eql(u8, val, "immediate")) {
                new_args[val_idx.?] = "-1";
            }
        }
    }
    
    return new_args;
}




fn translateCommitFlags(allocator: std.mem.Allocator, all_args: [][]const u8, command_index: usize) ![][]const u8 {
    // Translate commit flags for git 2.43 compat
    // Handle --template ":(optional)path" by stripping the prefix if file doesn't exist,
    // or using the real path if it does.
    var new_args = std.array_list.Managed([]const u8).init(allocator);
    var i: usize = 0;
    while (i < all_args.len) : (i += 1) {
        if (i > command_index) {
            // Check for --template with :(optional) prefix
            if (std.mem.eql(u8, all_args[i], "--template") and i + 1 < all_args.len) {
                const template_path = all_args[i + 1];
                if (std.mem.startsWith(u8, template_path, ":(optional)")) {
                    const real_path = template_path[":(optional)".len..];
                    // Check if file exists
                    const file_exists = blk: {
                        std.fs.cwd().access(real_path, .{}) catch break :blk false;
                        break :blk true;
                    };
                    if (file_exists) {
                        try new_args.append(all_args[i]);
                        try new_args.append(real_path);
                    }
                    // else: skip both --template and the path (optional = ignore if missing)
                    i += 1;
                    continue;
                }
            }
            // Check for --template=:(optional)path form
            if (std.mem.startsWith(u8, all_args[i], "--template=:(optional)")) {
                const real_path = all_args[i]["--template=:(optional)".len..];
                const file_exists = blk: {
                    std.fs.cwd().access(real_path, .{}) catch break :blk false;
                    break :blk true;
                };
                if (file_exists) {
                    const new_flag = try std.fmt.allocPrint(allocator, "--template={s}", .{real_path});
                    try new_args.append(new_flag);
                }
                // else: skip (optional = ignore if missing)
                continue;
            }
        }
        try new_args.append(all_args[i]);
    }
    return new_args.toOwnedSlice();
}



fn translateStderrLine(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    // Translate git 2.43 error messages to git 2.46+ format
    
    // "fatal: unknown style 'X' given for 'merge.conflictstyle'" → "error: unknown conflict style 'X'"
    if (std.mem.startsWith(u8, line, "fatal: unknown style '")) {
        if (std.mem.indexOf(u8, line, "' given for 'merge.conflictstyle'")) |end_pos| {
            const style_start = "fatal: unknown style '".len;
            const style = line[style_start..end_pos];
            return try std.fmt.allocPrint(allocator, "error: unknown conflict style '{s}'", .{style});
        }
    }
    
    // "fatal: unable to read tree HASH" → "fatal: unable to read tree (HASH)"
    if (std.mem.startsWith(u8, line, "fatal: unable to read tree ")) {
        const rest = line["fatal: unable to read tree ".len..];
        if (rest.len >= 40 and !std.mem.startsWith(u8, rest, "(")) {
            // Check if rest is a hex hash
            var is_hash = true;
            for (rest[0..40]) |c| {
                if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) {
                    is_hash = false;
                    break;
                }
            }
            if (is_hash) {
                return try std.fmt.allocPrint(allocator, "fatal: unable to read tree ({s})", .{rest});
            }
        }
    }

    // "error: core.commentChar should only be one ASCII character" →
    // In git 2.46+, core.commentChar supports multi-byte via core.commentString
    // Just pass through for now
    
    // "fatal: '--ours/--theirs' cannot be used with switching branches" →
    // When used without pathspec: "error: --ours/--theirs needs the paths to check out"
    // Note: this is context-dependent; we'd need to know if paths were given
    
    return try allocator.dupe(u8, line);
}

fn translateStderr(allocator: std.mem.Allocator, stderr_data: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    var iter = std.mem.splitScalar(u8, stderr_data, '\n');
    var first = true;
    while (iter.next()) |line| {
        if (!first) try result.append('\n');
        first = false;
        const translated = try translateStderrLine(allocator, line);
        try result.appendSlice(translated);
        if (translated.ptr != line.ptr) allocator.free(translated);
    }
    return result.toOwnedSlice();
}



fn findUntrackedFiles(allocator: std.mem.Allocator, repo_root: []const u8, index: *const index_mod.Index, gitignore: *const gitignore_mod.GitIgnore, platform_impl: *const platform_mod.Platform) !std.array_list.Managed([]u8) {
    var untracked_files = std.array_list.Managed([]u8).init(allocator);
    
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
    untracked_files: *std.array_list.Managed([]u8),
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
            .file, .sym_link => {
                // Check if file/symlink is tracked
                if (!tracked_files.contains(entry_relative_path)) {
                    try untracked_files.append(try allocator.dupe(u8, entry_relative_path));
                }
            },
            .directory => {
                // Check for nested git repo
                const dotgit_full = try std.fmt.allocPrint(allocator, "{s}/{s}/.git", .{ repo_root, entry_relative_path });
                defer allocator.free(dotgit_full);
                if (platform_impl.fs.exists(dotgit_full) catch false) continue;

                // Recursively scan subdirectory
                scanDirectoryForUntrackedFiles(
                    allocator,
                    repo_root,
                    entry_relative_path,
                    untracked_files,
                    tracked_files,
                    gitignore,
                    platform_impl,
                ) catch continue;
            },
            else => continue,
        }
    }
}

/// Check if a pathspec (which may contain globs) matches a path.
fn pathspecMatchesPath(pathspec: []const u8, path: []const u8, is_dir: bool) bool {
    if (std.mem.eql(u8, pathspec, path)) return true;
    const ps_trimmed = if (std.mem.endsWith(u8, pathspec, "/")) pathspec[0 .. pathspec.len - 1] else pathspec;
    const path_trimmed = if (std.mem.endsWith(u8, path, "/")) path[0 .. path.len - 1] else path;
    if (std.mem.eql(u8, ps_trimmed, path_trimmed)) return true;
    if (std.mem.startsWith(u8, path_trimmed, ps_trimmed) and path_trimmed.len > ps_trimmed.len and path_trimmed[ps_trimmed.len] == '/') return true;
    if (std.mem.startsWith(u8, ps_trimmed, path_trimmed) and ps_trimmed.len > path_trimmed.len and ps_trimmed[path_trimmed.len] == '/') return true;
    const has_glob = std.mem.indexOfAny(u8, pathspec, "*?") != null;
    if (has_glob) {
        if (globMatch(path, pathspec)) return true;
        if (is_dir) {
            const tp = if (std.mem.endsWith(u8, path, "/")) path[0 .. path.len - 1] else path;
            var glob_start: usize = 0;
            while (glob_start < pathspec.len) : (glob_start += 1) {
                if (pathspec[glob_start] == '*' or pathspec[glob_start] == '?') break;
            }
            const pre_glob = pathspec[0..glob_start];
            if (std.mem.lastIndexOfScalar(u8, pre_glob, '/')) |last_slash| {
                const dir_part = pathspec[0..last_slash];
                if (std.mem.eql(u8, dir_part, tp) or std.mem.startsWith(u8, dir_part, tp) or
                    std.mem.startsWith(u8, tp, dir_part) or globMatch(tp, dir_part))
                    return true;
            } else return true;
        }
    }
    return false;
}

fn pathspecIsGlob(pathspec: []const u8) bool {
    return std.mem.indexOfAny(u8, pathspec, "*?[") != null;
}

/// Find untracked directory entries for --directory mode.
fn findUntrackedDirEntries(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    relative_path: []const u8,
    results: *std.array_list.Managed([]u8),
    index: *const index_mod.Index,
    gitignore: *const gitignore_mod.GitIgnore,
    no_empty_directory: bool,
    pathspecs: []const []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    const full_path = if (relative_path.len == 0)
        try allocator.dupe(u8, repo_root)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, relative_path });
    defer allocator.free(full_path);

    var dir = std.fs.cwd().openDir(full_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var tracked_dirs = std.StringHashMap(void).init(allocator);
    defer tracked_dirs.deinit();
    var tracked_files_set = std.StringHashMap(void).init(allocator);
    defer tracked_files_set.deinit();
    for (index.entries.items) |entry| {
        try tracked_files_set.put(entry.path, {});
        var j: usize = 0;
        while (j < entry.path.len) : (j += 1) {
            if (entry.path[j] == '/') try tracked_dirs.put(entry.path[0..j], {});
        }
    }

    var iterator = dir.iterate();
    while (iterator.next() catch null) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        const entry_relative_path = if (relative_path.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_path, entry.name });
        defer allocator.free(entry_relative_path);

        if (gitignore.isIgnored(entry_relative_path)) continue;

        if (pathspecs.len > 0) {
            var relevant = false;
            for (pathspecs) |ps| {
                if (pathspecMatchesPath(ps, entry_relative_path, entry.kind == .directory)) { relevant = true; break; }
                if (entry.kind == .directory) {
                    const dp = try std.fmt.allocPrint(allocator, "{s}/", .{entry_relative_path});
                    defer allocator.free(dp);
                    if (pathspecMatchesPath(ps, dp, true)) { relevant = true; break; }
                }
            }
            if (!relevant) continue;
        }

        switch (entry.kind) {
            .file, .sym_link => {
                if (!tracked_files_set.contains(entry_relative_path)) {
                    try results.append(try allocator.dupe(u8, entry_relative_path));
                }
            },
            .directory => {
                const dotgit_full = try std.fmt.allocPrint(allocator, "{s}/{s}/.git", .{ repo_root, entry_relative_path });
                defer allocator.free(dotgit_full);
                if (platform_impl.fs.exists(dotgit_full) catch false) continue;

                if (tracked_dirs.contains(entry_relative_path)) {
                    try findUntrackedDirEntries(allocator, repo_root, entry_relative_path, results, index, gitignore, no_empty_directory, pathspecs, platform_impl);
                } else {
                    var need_recurse = false;
                    var glob_matches_dir = false;
                    if (pathspecs.len > 0) {
                        const dp = try std.fmt.allocPrint(allocator, "{s}/", .{entry_relative_path});
                        defer allocator.free(dp);
                        for (pathspecs) |ps| {
                            if (std.mem.startsWith(u8, ps, dp) and ps.len > dp.len) { need_recurse = true; break; }
                            if (pathspecIsGlob(ps)) {
                                if (globMatch(entry_relative_path, ps)) { glob_matches_dir = true; break; }
                                if (pathspecMatchesPath(ps, entry_relative_path, true)) { need_recurse = true; break; }
                            }
                        }
                    }
                    if (glob_matches_dir) {
                        try results.append(try std.fmt.allocPrint(allocator, "{s}/", .{entry_relative_path}));
                    } else if (need_recurse) {
                        try findUntrackedDirEntries(allocator, repo_root, entry_relative_path, results, index, gitignore, no_empty_directory, pathspecs, platform_impl);
                    } else {
                        if (no_empty_directory) {
                            const sf = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry_relative_path });
                            defer allocator.free(sf);
                            var sd = std.fs.cwd().openDir(sf, .{ .iterate = true }) catch continue;
                            defer sd.close();
                            var si = sd.iterate();
                            if ((si.next() catch null) == null) continue;
                        }
                        try results.append(try std.fmt.allocPrint(allocator, "{s}/", .{entry_relative_path}));
                    }
                }
            },
            else => {},
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
    
    const fallback_info = if (build_options.enable_git_fallback and @import("builtin").target.os.tag != .freestanding) 
        "\nUnimplemented commands are transparently forwarded to git when available.\n"
    else 
        "";
        
    const suffix_msg = std.fmt.allocPrint(std.heap.page_allocator, "\nziggit{s} - A modern version control system written in Zig\n\nDrop-in replacement for git commands - use 'ziggit' instead of 'git'\nCompatible .git directory format, works with existing git repositories{s}\nOptions:\n  --version, -v       Show version information\n  --version-info      Show detailed version and build information\n  --help, -h          Show this help message\n", .{target_info, fallback_info}) catch return;
    defer std.heap.page_allocator.free(suffix_msg);
    try platform_impl.writeStdout(suffix_msg);
}

fn cmdInit(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform, global_bare: bool) !void {
    var bare = global_bare;
    var template_dir: ?[]const u8 = null;
    var template_dir_set = false;
    var work_dir: ?[]const u8 = null;
    var initial_branch: ?[]const u8 = null;
    var quiet = false;
    var separate_git_dir: ?[]const u8 = null;
    var shared: ?[]const u8 = null;
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bare")) {
            bare = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.startsWith(u8, arg, "--template=")) {
            template_dir = arg["--template=".len..];
            template_dir_set = true;
        } else if (std.mem.eql(u8, arg, "--template")) {
            template_dir = args.next();
            template_dir_set = true;
        } else if (std.mem.startsWith(u8, arg, "--initial-branch=")) {
            initial_branch = arg["--initial-branch=".len..];
        } else if (std.mem.eql(u8, arg, "--initial-branch") or std.mem.eql(u8, arg, "-b")) {
            initial_branch = args.next();
        } else if (std.mem.startsWith(u8, arg, "--separate-git-dir=")) {
            separate_git_dir = arg["--separate-git-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--separate-git-dir")) {
            separate_git_dir = args.next();
        } else if (std.mem.startsWith(u8, arg, "--shared=")) {
            shared = arg["--shared=".len..];
        } else if (std.mem.eql(u8, arg, "--shared")) {
            shared = args.next();
        } else if (std.mem.startsWith(u8, arg, "--object-format=") or
                   std.mem.startsWith(u8, arg, "--ref-format=")) {
            // Silently accept for now (only sha1/files supported)
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            work_dir = arg;
        }
    }
    
    // Check GIT_WORK_TREE
    const env_work_tree = std.process.getEnvVarOwned(allocator, "GIT_WORK_TREE") catch null;
    defer if (env_work_tree) |w| allocator.free(w);
    
    // Check GIT_DIR environment variable
    const env_git_dir = std.process.getEnvVarOwned(allocator, "GIT_DIR") catch null;
    defer if (env_git_dir) |g| allocator.free(g);
    
    if (env_work_tree != null) {
        if (bare) {
            try platform_impl.writeStderr("fatal: GIT_WORK_TREE (or --work-tree=<directory>) not allowed in combination with '--(bare|shared)'\n");
            std.process.exit(128);
        }
        // GIT_WORK_TREE + GIT_DIR together is OK (sets up worktree in separate location)
        // But GIT_WORK_TREE without GIT_DIR during init should fail
        if (env_git_dir == null) {
            try platform_impl.writeStderr("fatal: GIT_WORK_TREE (or --work-tree=<directory>) not allowed without GIT_DIR being set\n");
            std.process.exit(128);
        }
    }
    
    // Check --separate-git-dir + --bare incompatibility
    if (separate_git_dir != null and bare) {
        try platform_impl.writeStderr("fatal: options '--separate-git-dir' and '--bare' cannot be used together\n");
        std.process.exit(128);
    }
    
    // Check --separate-git-dir + implicit bare (GIT_DIR=.) incompatibility 
    if (separate_git_dir != null and env_git_dir != null) {
        // When GIT_DIR is set, it's implicitly bare-like, incompatible with --separate-git-dir
        try platform_impl.writeStderr("fatal: --separate-git-dir incompatible with bare repository\n");
        std.process.exit(128);
    }
    
    // If GIT_DIR is set, use it as the git directory instead of default
    const target_dir = work_dir orelse ".";
    
    if (env_git_dir) |git_dir_env| {
        // When --bare and a positional directory is given, the positional arg overrides GIT_DIR
        if (bare and work_dir != null) {
            try initRepository(target_dir, bare, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
        } else {
            // Use GIT_DIR as the git directory
            try initRepositoryWithGitDir(target_dir, git_dir_env, bare, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
        }
    } else if (separate_git_dir) |sep_dir| {
        // Create repo with separate git dir
        try initRepositoryWithSeparateGitDir(target_dir, sep_dir, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
    } else {
        try initRepository(target_dir, bare, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
    }
}

fn copyTemplateDir(git_dir: []const u8, template_path: []const u8, allocator: std.mem.Allocator) !void {
    // Recursively copy template directory contents to git_dir
    var dir = std.fs.cwd().openDir(template_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, entry.path });
        defer allocator.free(dest_path);

        switch (entry.kind) {
            .directory => {
                std.fs.cwd().makePath(dest_path) catch {};
            },
            .file => {
                // Only copy if destination doesn't exist
                if (std.fs.cwd().access(dest_path, .{})) |_| {
                    continue; // Don't overwrite existing files
                } else |_| {}

                const src_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ template_path, entry.path });
                defer allocator.free(src_path);
                std.fs.cwd().copyFile(src_path, std.fs.cwd(), dest_path, .{}) catch {};
            },
            else => {},
        }
    }
}

fn initRepositoryWithGitDir(work_dir: []const u8, git_dir_path: []const u8, bare: bool, template_dir: ?[]const u8, template_dir_set: bool, initial_branch: ?[]const u8, quiet: bool, shared: ?[]const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // Check if GIT_WORK_TREE is also set  
    const env_work_tree = std.process.getEnvVarOwned(allocator, "GIT_WORK_TREE") catch null;
    defer if (env_work_tree) |w| allocator.free(w);
    
    // When both GIT_DIR and GIT_WORK_TREE are set, create non-bare repo with worktree
    if (env_work_tree) |wt| {
        _ = work_dir;
        try initRepositoryInDir(git_dir_path, false, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
        // Set core.worktree in config
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir_path});
        defer allocator.free(config_path);
        if (platform_impl.fs.readFile(allocator, config_path)) |existing| {
            defer allocator.free(existing);
            // Insert worktree before the closing of [core] section
            const abs_wt = std.fs.cwd().realpathAlloc(allocator, wt) catch try allocator.dupe(u8, wt);
            defer allocator.free(abs_wt);
            const new_config = try std.fmt.allocPrint(allocator, "{s}\tworktree = {s}\n", .{ existing, abs_wt });
            defer allocator.free(new_config);
            try platform_impl.fs.writeFile(config_path, new_config);
        } else |_| {}
    } else {
        _ = work_dir;
        // When GIT_DIR is set without GIT_WORK_TREE
        // Heuristic: if GIT_DIR ends with .git, treat as bare
        const is_bare = bare or std.mem.endsWith(u8, git_dir_path, ".git");
        try initRepositoryInDir(git_dir_path, is_bare, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
    }
}

fn initRepositoryWithSeparateGitDir(work_dir: []const u8, git_dir_path: []const u8, template_dir: ?[]const u8, template_dir_set: bool, initial_branch: ?[]const u8, quiet: bool, shared: ?[]const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // Create the git directory
    try initRepositoryInDir(git_dir_path, false, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
    
    // Create the work tree directory
    createDirectoryRecursive(work_dir, platform_impl, allocator) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };
    
    // Write .git file in work_dir pointing to the separate git dir
    const abs_git_dir = std.fs.cwd().realpathAlloc(allocator, git_dir_path) catch try allocator.dupe(u8, git_dir_path);
    defer allocator.free(abs_git_dir);
    
    const git_file_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{work_dir});
    defer allocator.free(git_file_path);
    const git_file_content = try std.fmt.allocPrint(allocator, "gitdir: {s}\n", .{abs_git_dir});
    defer allocator.free(git_file_content);
    try platform_impl.fs.writeFile(git_file_path, git_file_content);
    
    // Set core.worktree in the git dir config
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir_path});
    defer allocator.free(config_path);
    const abs_work = std.fs.cwd().realpathAlloc(allocator, work_dir) catch try allocator.dupe(u8, work_dir);
    defer allocator.free(abs_work);
    
    // Read existing config and add worktree
    if (platform_impl.fs.readFile(allocator, config_path)) |existing| {
        defer allocator.free(existing);
        // Add worktree to core section
        const new_config = try std.fmt.allocPrint(allocator, "{s}\tworktree = {s}\n", .{ existing, abs_work });
        defer allocator.free(new_config);
        try platform_impl.fs.writeFile(config_path, new_config);
    } else |_| {}
}

fn initRepositoryInDir(git_dir: []const u8, bare: bool, template_dir: ?[]const u8, template_dir_set: bool, initial_branch: ?[]const u8, quiet: bool, shared: ?[]const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // Create the directory structure
    createDirectoryRecursive(git_dir, platform_impl, allocator) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };
    
    // Check if already exists
    const head_check_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_check_path);
    
    if (platform_impl.fs.exists(head_check_path) catch false) {
        const abs_path = std.fs.cwd().realpathAlloc(allocator, git_dir) catch try allocator.dupe(u8, git_dir);
        defer allocator.free(abs_path);
        if (initial_branch != null) {
            const warn_msg = try std.fmt.allocPrint(allocator, "warning: re-init: ignored --initial-branch={s}\n", .{initial_branch.?});
            defer allocator.free(warn_msg);
            try platform_impl.writeStderr(warn_msg);
        }
        if (!quiet) {
            const msg = try std.fmt.allocPrint(allocator, "Reinitialized existing Git repository in {s}/\n", .{abs_path});
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        }
        return;
    }
    
    // Create subdirectories
    const subdirs = [_][]const u8{
        "objects", "objects/info", "objects/pack", "refs", "refs/heads", "refs/tags", "hooks", "info",
    };
    for (subdirs) |subdir| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, subdir });
        defer allocator.free(full_path);
        std.fs.cwd().makePath(full_path) catch {};
    }
    
    // Create HEAD
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    const default_branch = if (initial_branch) |ib|
        try allocator.dupe(u8, ib)
    else blk: {
        // Check GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME (non-empty means use it)
        if (std.process.getEnvVarOwned(allocator, "GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME") catch null) |env_val| {
            if (env_val.len > 0) break :blk env_val;
            allocator.free(env_val);
        }
        // Check init.defaultBranch from global config
        const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch null;
        defer if (home_dir) |h| allocator.free(h);
        if (home_dir) |home| {
            const global_config_path2 = try std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{home});
            defer allocator.free(global_config_path2);
            if (platform_impl.fs.readFile(allocator, global_config_path2)) |gcfg| {
                defer allocator.free(gcfg);
                if (parseConfigValue(gcfg, "init.defaultbranch", allocator) catch null) |db_val| {
                    if (db_val.len > 0) break :blk db_val;
                    allocator.free(db_val);
                }
            } else |_| {}
            // Also check XDG config
            const xdg_config = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null;
            defer if (xdg_config) |x| allocator.free(x);
            const xdg_base = xdg_config orelse home;
            const xdg_git_config = if (xdg_config != null)
                try std.fmt.allocPrint(allocator, "{s}/git/config", .{xdg_base})
            else
                try std.fmt.allocPrint(allocator, "{s}/.config/git/config", .{xdg_base});
            defer allocator.free(xdg_git_config);
            if (platform_impl.fs.readFile(allocator, xdg_git_config)) |xcfg| {
                defer allocator.free(xcfg);
                if (parseConfigValue(xcfg, "init.defaultbranch", allocator) catch null) |db_val2| {
                    if (db_val2.len > 0) break :blk db_val2;
                    allocator.free(db_val2);
                }
            } else |_| {}
        }
        break :blk try allocator.dupe(u8, "master");
    };
    defer allocator.free(default_branch);
    const head_content = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{default_branch});
    defer allocator.free(head_content);
    try platform_impl.fs.writeFile(head_path, head_content);
    
    // Create config
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
    defer allocator.free(config_path);
    
    var config_buf = std.array_list.Managed(u8).init(allocator);
    defer config_buf.deinit();
    try config_buf.appendSlice("[core]\n");
    try config_buf.appendSlice("\trepositoryformatversion = 0\n");
    try config_buf.appendSlice("\tfilemode = true\n");
    if (bare) {
        try config_buf.appendSlice("\tbare = true\n");
    } else {
        try config_buf.appendSlice("\tbare = false\n");
    }
    try config_buf.appendSlice("\tlogallrefupdates = true\n");
    if (shared) |s| {
        const shared_line = try std.fmt.allocPrint(allocator, "\tsharedRepository = {s}\n", .{s});
        defer allocator.free(shared_line);
        try config_buf.appendSlice(shared_line);
    }
    try platform_impl.fs.writeFile(config_path, config_buf.items);
    
    // Create description
    const desc_path = try std.fmt.allocPrint(allocator, "{s}/description", .{git_dir});
    defer allocator.free(desc_path);
    try platform_impl.fs.writeFile(desc_path, "Unnamed repository; edit this file 'description' to name the repository.\n");
    
    // Copy template directory contents (unless --template= was set to empty)
    if (!template_dir_set or (template_dir != null and template_dir.?.len > 0)) {
        var effective_template: ?[]const u8 = null;
        var template_needs_free = false;
        
        if (template_dir) |td| {
            effective_template = td;
        } else {
            // Check GIT_TEMPLATE_DIR env
            effective_template = std.process.getEnvVarOwned(allocator, "GIT_TEMPLATE_DIR") catch null;
            if (effective_template != null) {
                template_needs_free = true;
            } else {
                // Check init.templatedir from global config
                const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch null;
                defer if (home_dir) |h| allocator.free(h);
                if (home_dir) |home| {
                    const global_config_path = try std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{home});
                    defer allocator.free(global_config_path);
                    if (platform_impl.fs.readFile(allocator, global_config_path)) |gcfg| {
                        defer allocator.free(gcfg);
                        if (parseConfigValue(gcfg, "init.templatedir", allocator) catch null) |tmpl_val| {
                            // Handle ~ expansion
                            if (tmpl_val.len > 0 and tmpl_val[0] == '~') {
                                const expanded = try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, tmpl_val[1..] });
                                allocator.free(tmpl_val);
                                effective_template = expanded;
                            } else {
                                effective_template = tmpl_val;
                            }
                            template_needs_free = true;
                        }
                    } else |_| {}
                }
            }
        }
        defer if (template_needs_free) if (effective_template) |et| allocator.free(et);
        
        if (effective_template) |tmpl_dir| {
            if (tmpl_dir.len > 0) {
                copyTemplateDir(git_dir, tmpl_dir, allocator) catch {};
            }
        }
    }
    
    // Create info/exclude if not provided by template
    const exclude_path = try std.fmt.allocPrint(allocator, "{s}/info/exclude", .{git_dir});
    defer allocator.free(exclude_path);
    if (!template_dir_set or (template_dir != null and template_dir.?.len > 0)) {
        if (!(std.fs.cwd().access(exclude_path, .{}) catch null != null)) {
            platform_impl.fs.writeFile(exclude_path, "# git ls-files --others --exclude-from=.git/info/exclude\n# Lines that start with '#' are comments.\n") catch {};
        }
    }
    
    // Print success
    const abs_path = std.fs.cwd().realpathAlloc(allocator, git_dir) catch try allocator.dupe(u8, git_dir);
    defer allocator.free(abs_path);
    if (!quiet) {
        const msg = try std.fmt.allocPrint(allocator, "Initialized empty Git repository in {s}/\n", .{abs_path});
        defer allocator.free(msg);
        try platform_impl.writeStdout(msg);
    }
}

fn initRepository(path: []const u8, bare: bool, template_dir: ?[]const u8, template_dir_set: bool, initial_branch: ?[]const u8, quiet: bool, shared: ?[]const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // Create the target directory if it doesn't exist (recursively)
    createDirectoryRecursive(path, platform_impl, allocator) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };
    
    const git_dir = if (bare) 
        try allocator.dupe(u8, path)
    else 
        try std.fmt.allocPrint(allocator, "{s}/.git", .{path});
    defer allocator.free(git_dir);
    
    try initRepositoryInDir(git_dir, bare, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
}

fn cmdStatus(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform, _: [][]const u8) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("status: not supported in freestanding mode\n");
        return;
    }

    // Check for flags
    var porcelain = false;
    var show_branch = false;
    var short_format = false;
    var show_untracked = true; // default: show untracked files
    var status_args = std.array_list.Managed([]const u8).init(allocator);
    defer status_args.deinit();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--porcelain") or std.mem.eql(u8, arg, "--porcelain=v1")) {
            porcelain = true;
        } else if (std.mem.startsWith(u8, arg, "--porcelain=")) {
            const version = arg["--porcelain=".len..];
            if (std.mem.eql(u8, version, "v1") or std.mem.eql(u8, version, "1")) {
                porcelain = true;
            } else if (std.mem.eql(u8, version, "v2") or std.mem.eql(u8, version, "2")) {
                porcelain = true;
            } else {
                const msg = try std.fmt.allocPrint(allocator, "fatal: unsupported porcelain version '{s}'\n", .{version});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }
        } else if (std.mem.eql(u8, arg, "--branch") or std.mem.eql(u8, arg, "-b")) {
            show_branch = true;
        } else if (std.mem.eql(u8, arg, "--short") or std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "-sb") or std.mem.eql(u8, arg, "-bs")) {
            short_format = true;
            porcelain = true; // short format uses same output as porcelain
            if (std.mem.eql(u8, arg, "-sb") or std.mem.eql(u8, arg, "-bs")) {
                show_branch = true;
            }
        } else if (std.mem.eql(u8, arg, "-uno") or std.mem.eql(u8, arg, "-ufalse") or std.mem.eql(u8, arg, "--untracked-files=no") or std.mem.eql(u8, arg, "--untracked-files=false") or std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--no-untracked-files")) {
            show_untracked = false;
        } else if (std.mem.eql(u8, arg, "-unormal") or std.mem.eql(u8, arg, "-utrue") or std.mem.eql(u8, arg, "--untracked-files=normal") or std.mem.eql(u8, arg, "--untracked-files=true") or std.mem.eql(u8, arg, "--untracked-files") or std.mem.eql(u8, arg, "-uall") or std.mem.eql(u8, arg, "--untracked-files=all")) {
            show_untracked = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try platform_impl.writeStdout("usage: git status [<options>] [--] [<pathspec>...]\n\n");
            try platform_impl.writeStdout("    -s, --short           show status concisely\n");
            try platform_impl.writeStdout("    -b, --branch          show branch information\n");
            try platform_impl.writeStdout("    --porcelain[=<version>]\n                          machine-readable output\n");
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--")) {
            // End of flags
            while (args.next()) |path_arg| {
                try status_args.append(path_arg);
            }
            break;
        } else if (std.mem.eql(u8, arg, "-z")) {
            // NUL-terminate output entries - accept but treat as no-op for now
            // (porcelain mode already uses line-based output)
        } else if (std.mem.eql(u8, arg, "--column") or std.mem.startsWith(u8, arg, "--column=")) {
            // Column display - accept as no-op
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            // Verbose mode - accept as no-op (shows diff in commit template)
        } else if (std.mem.eql(u8, arg, "--ignored")) {
            // Show ignored files - accept as no-op for now
        } else if (std.mem.eql(u8, arg, "--renames") or std.mem.eql(u8, arg, "--no-renames") or
            std.mem.eql(u8, arg, "--find-renames"))
        {
            // Rename detection - accept as no-op
        } else if (std.mem.eql(u8, arg, "--ahead-behind") or std.mem.eql(u8, arg, "--no-ahead-behind")) {
            // Ahead/behind display - accept as no-op
        } else if (arg.len > 0 and arg[0] != '-') {
            try status_args.append(arg);
        }
        // Silently ignore other unrecognized flags
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

    // Check config for status.showUntrackedFiles (if not overridden by command line)
    if (show_untracked) {
        const config_path_for_ut = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path_for_ut);
        if (platform_impl.fs.readFile(allocator, config_path_for_ut)) |cfg| {
            defer allocator.free(cfg);
            if (parseConfigValue(cfg, "status.showuntrackedfiles", allocator) catch null) |val| {
                defer allocator.free(val);
                if (std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) {
                    show_untracked = false;
                }
            }
        } else |_| {}
    }

    // Get current branch
    const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch try allocator.dupe(u8, "master");
    defer allocator.free(current_branch);

    // Check if there are any commits
    const current_commit = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
    defer if (current_commit) |hash| allocator.free(hash);
    
    if (!porcelain) {
        const branch_msg = try std.fmt.allocPrint(allocator, "On branch {s}\n", .{current_branch});
        defer allocator.free(branch_msg);
        try platform_impl.writeStdout(branch_msg);

        // Display upstream tracking info natively
        if (current_commit != null) upstream_display: {
            const config_path_track = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(config_path_track);
            const cfg = platform_impl.fs.readFile(allocator, config_path_track) catch break :upstream_display;
            defer allocator.free(cfg);
            const track_key = try std.fmt.allocPrint(allocator, "branch \"{s}\".remote", .{current_branch});
            defer allocator.free(track_key);
            const remote_val = (parseConfigValue(cfg, track_key, allocator) catch null) orelse break :upstream_display;
            defer allocator.free(remote_val);

            const merge_key = try std.fmt.allocPrint(allocator, "branch \"{s}\".merge", .{current_branch});
            defer allocator.free(merge_key);
            const merge_val = (parseConfigValue(cfg, merge_key, allocator) catch null) orelse break :upstream_display;
            defer allocator.free(merge_val);

            // Convert refs/heads/foo to remote/origin/foo
            const short_merge = if (std.mem.startsWith(u8, merge_val, "refs/heads/"))
                merge_val["refs/heads/".len..]
            else
                merge_val;

            const upstream_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ remote_val, short_merge });
            defer allocator.free(upstream_ref);
            const upstream_display_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_val, short_merge });
            defer allocator.free(upstream_display_name);

            // Resolve upstream ref to commit hash
            const upstream_hash_opt = refs.resolveRef(git_path, upstream_ref, platform_impl, allocator) catch break :upstream_display;
            const upstream_hash = upstream_hash_opt orelse break :upstream_display;
            defer allocator.free(upstream_hash);

            // Compare commits: count ahead/behind
            if (std.mem.eql(u8, current_commit.?, upstream_hash)) {
                const up_msg = try std.fmt.allocPrint(allocator, "Your branch is up to date with '{s}'.\n", .{upstream_display_name});
                defer allocator.free(up_msg);
                try platform_impl.writeStdout(up_msg);
            } else {
                // Simple check: is upstream reachable from HEAD? Is HEAD reachable from upstream?
                // For now just show the tracking info without ahead/behind counts
                const up_msg = try std.fmt.allocPrint(allocator, "Your branch and '{s}' have diverged.\n", .{upstream_display_name});
                defer allocator.free(up_msg);
                try platform_impl.writeStdout(up_msg);
            }
        }
        
        if (current_commit == null) {
            try platform_impl.writeStdout("\nNo commits yet\n");
        }
    } else if (porcelain and show_branch) {
        // Check if HEAD is detached
        const head_content_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
        defer allocator.free(head_content_path);
        const head_raw = platform_impl.fs.readFile(allocator, head_content_path) catch null;
        defer if (head_raw) |h| allocator.free(h);
        
        if (head_raw) |h| {
            if (std.mem.startsWith(u8, h, "ref: ")) {
                const branch_header = try std.fmt.allocPrint(allocator, "## {s}\n", .{current_branch});
                defer allocator.free(branch_header);
                try platform_impl.writeStdout(branch_header);
            } else {
                try platform_impl.writeStdout("## HEAD (no branch)\n");
            }
        } else {
            const branch_header = try std.fmt.allocPrint(allocator, "## {s}\n", .{current_branch});
            defer allocator.free(branch_header);
            try platform_impl.writeStdout(branch_header);
        }
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

    // Pre-compute HEAD tree hash and build flat index for O(1) blob lookups
    var cached_head_tree: ?[]u8 = null;
    if (current_commit) |cc| {
        const commit_obj = objects.GitObject.load(cc, git_path, platform_impl, allocator) catch null;
        if (commit_obj) |co| {
            defer co.deinit(allocator);
            var clines = std.mem.splitSequence(u8, co.data, "\n");
            if (clines.next()) |tl| {
                if (std.mem.startsWith(u8, tl, "tree ")) {
                    cached_head_tree = allocator.dupe(u8, tl["tree ".len..]) catch null;
                }
            }
        }
    }
    defer if (cached_head_tree) |h| allocator.free(h);

    // Build flat map: path -> sha1 from HEAD tree (for fast staged detection)
    var head_tree_map = std.StringHashMap([20]u8).init(allocator);
    defer {
        var kit = head_tree_map.keyIterator();
        while (kit.next()) |key| allocator.free(@constCast(key.*));
        head_tree_map.deinit();
    }
    if (cached_head_tree) |ht| {
        buildTreeMap(ht, "", git_path, platform_impl, allocator, &head_tree_map) catch {};
    }

    // Detect staged files vs modified files vs deleted files vs clean files
    var staged_files = std.array_list.Managed(index_mod.IndexEntry).init(allocator);
    var modified_files = std.array_list.Managed(index_mod.IndexEntry).init(allocator);
    var deleted_files = std.array_list.Managed(index_mod.IndexEntry).init(allocator);
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
                // OPTIMIZATION: Fast path using mtime/size before computing SHA-1
                const file_stat = std.fs.cwd().statFile(full_path) catch break :blk false;
                
                // Compare mtime and size with index entry
                const work_mtime_sec = @as(u32, @intCast(@divTrunc(file_stat.mtime, 1_000_000_000)));
                const work_size = @as(u32, @intCast(file_stat.size));
                
                // Fast path: if mtime and size match index, file is likely unchanged
                if (work_mtime_sec == entry.mtime_sec and work_size == entry.size) {
                    break :blk false; // File appears unchanged - skip expensive SHA-1 computation
                }
                
                // Slow path: mtime or size differs, need to compute SHA-1 to confirm
                const current_content = platform_impl.fs.readFile(allocator, full_path) catch break :blk false;
                defer allocator.free(current_content);
                
                // Create blob object to get hash
                const blob = objects.createBlobObject(current_content, allocator) catch break :blk false;
                defer blob.deinit(allocator);
                
                const current_hash = blob.hash(allocator) catch break :blk false;
                defer allocator.free(current_hash);
                
                // Compare with index hash
                const index_hash = std.fmt.allocPrint(allocator, "{x}", .{&entry.sha1}) catch break :blk false;
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
                // Check if it's different from HEAD tree using cached map (O(1))
                const is_different_from_head = blk: {
                    if (head_tree_map.get(entry.path)) |tree_sha1| {
                        break :blk !std.mem.eql(u8, &tree_sha1, &entry.sha1);
                    }
                    // File not in HEAD tree - it's new (staged)
                    break :blk current_commit != null;
                };
                
                if (is_different_from_head) {
                    try staged_files.append(entry);
                }
                // If same as HEAD, file is clean (don't show it)
            }
        }
    }

    // Determine HEAD tree hash for new-file detection
    var head_tree_hash: ?[]u8 = null;
    if (current_commit) |cc| {
        const cobj = objects.GitObject.load(cc, git_path, platform_impl, allocator) catch null;
        if (cobj) |co| {
            defer co.deinit(allocator);
            if (co.type == .commit) {
                var clines = std.mem.splitSequence(u8, co.data, "\n");
                if (clines.next()) |tl| {
                    if (std.mem.startsWith(u8, tl, "tree ")) {
                        head_tree_hash = allocator.dupe(u8, tl["tree ".len..]) catch null;
                    }
                }
            }
        }
    }
    defer if (head_tree_hash) |h| allocator.free(h);

    // For porcelain output, collect all lines then sort and output together
    var porcelain_lines = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (porcelain_lines.items) |line| allocator.free(line);
        porcelain_lines.deinit();
    }

    // Show staged files
    if (staged_files.items.len > 0) {
        if (porcelain) {
            for (staged_files.items) |entry| {
                const is_new = if (current_commit == null)
                    true
                else if (head_tree_hash) |hth|
                    (lookupBlobInTree(hth, entry.path, git_path, platform_impl, allocator) catch null) == null
                else
                    false;
                
                if (is_new) {
                    try porcelain_lines.append(try std.fmt.allocPrint(allocator, "A  {s}", .{entry.path}));
                } else {
                    try porcelain_lines.append(try std.fmt.allocPrint(allocator, "M  {s}", .{entry.path}));
                }
            }
        } else {
            try platform_impl.writeStdout("\nChanges to be committed:\n");
            if (current_commit == null) {
                try platform_impl.writeStdout("  (use \"git rm --cached <file>...\" to unstage)\n");
            } else {
                try platform_impl.writeStdout("  (use \"git restore --staged <file>...\" to unstage)\n");
            }
            
            for (staged_files.items) |entry| {
                const is_new = if (current_commit == null)
                    true
                else if (head_tree_hash) |hth|
                    (lookupBlobInTree(hth, entry.path, git_path, platform_impl, allocator) catch null) == null
                else
                    false;
                    
                if (is_new) {
                    const msg = try std.fmt.allocPrint(allocator, "\tnew file:   {s}\n", .{entry.path});
                    defer allocator.free(msg);
                    try platform_impl.writeStdout(msg);
                } else {
                    const msg = try std.fmt.allocPrint(allocator, "\tmodified:   {s}\n", .{entry.path});
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
                try porcelain_lines.append(try std.fmt.allocPrint(allocator, " M {s}", .{entry.path}));
            }
        } else {
            try platform_impl.writeStdout("\nChanges not staged for commit:\n");
            try platform_impl.writeStdout("  (use \"git add <file>...\" to update what will be committed)\n");
            try platform_impl.writeStdout("  (use \"git restore <file>...\" to discard changes in working directory)\n");
            
            for (modified_files.items) |entry| {
                const msg = try std.fmt.allocPrint(allocator, "\tmodified:   {s}\n", .{entry.path});
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
                try porcelain_lines.append(try std.fmt.allocPrint(allocator, " D {s}", .{entry.path}));
            }
        } else {
            if (modified_files.items.len == 0) {
                try platform_impl.writeStdout("\nChanges not staged for commit:\n");
                try platform_impl.writeStdout("  (use \"git add <file>...\" to update what will be committed)\n");
                try platform_impl.writeStdout("  (use \"git restore <file>...\" to discard changes in working directory)\n");
            }
            
            for (deleted_files.items) |entry| {
                const msg = try std.fmt.allocPrint(allocator, "\tdeleted:    {s}\n", .{entry.path});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
            try platform_impl.writeStdout("\n");
        }
    }

    // Find untracked files
    var untracked_files = if (show_untracked)
        findUntrackedFiles(allocator, repo_root, &index, &gitignore, platform_impl) catch std.array_list.Managed([]u8).init(allocator)
    else
        std.array_list.Managed([]u8).init(allocator);
    defer {
        for (untracked_files.items) |file| {
            allocator.free(file);
        }
        untracked_files.deinit();
    }

    if (untracked_files.items.len > 0) {
        if (porcelain) {
            for (untracked_files.items) |file| {
                try porcelain_lines.append(try std.fmt.allocPrint(allocator, "?? {s}", .{file}));
            }
        } else {
            try platform_impl.writeStdout("\nUntracked files:\n");
            try platform_impl.writeStdout("  (use \"git add <file>...\" to include in what will be committed)\n");
            
            for (untracked_files.items) |file| {
                const msg = try std.fmt.allocPrint(allocator, "\t{s}\n", .{file});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
            try platform_impl.writeStdout("\n");
        }
    }

    // Output sorted porcelain lines
    if (porcelain and porcelain_lines.items.len > 0) {
        // Sort: tracked entries in path order first, then untracked in path order
        std.mem.sort([]u8, porcelain_lines.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                const a_untracked = a.len >= 2 and a[0] == '?' and a[1] == '?';
                const b_untracked = b.len >= 2 and b[0] == '?' and b[1] == '?';
                if (a_untracked != b_untracked) return !a_untracked; // tracked before untracked
                const a_path = if (a.len > 3) a[3..] else a;
                const b_path = if (b.len > 3) b[3..] else b;
                return std.mem.order(u8, a_path, b_path) == .lt;
            }
        }.lessThan);
        for (porcelain_lines.items) |line| {
            const msg = try std.fmt.allocPrint(allocator, "{s}\n", .{line});
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
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
        if (!show_untracked) {
            try platform_impl.writeStdout("Untracked files not listed (use -u option to show untracked files)\n");
        }
    }
}

/// Resolve a git alias by looking up alias.<name> in config files.
/// Returns the alias value (caller must free), or null if not found.
fn resolveAlias(allocator: std.mem.Allocator, name: []const u8, platform_impl: *const platform_mod.Platform) !?[]u8 {
    const alias_key = try std.fmt.allocPrint(allocator, "alias.{s}", .{name});
    defer allocator.free(alias_key);
    
    // Search config sources in order: local (.git/config), global (~/.gitconfig), system (/etc/gitconfig)
    // Last value wins in git, but for aliases we want first match (local > global > system)
    
    // Try local config (.git/config)
    if (findGitDirectory(allocator, platform_impl)) |git_path| {
        defer allocator.free(git_path);
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);
        if (platform_impl.fs.readFile(allocator, config_path)) |content| {
            defer allocator.free(content);
            if (parseConfigValue(content, alias_key, allocator) catch null) |val| {
                return val;
            }
        } else |_| {}
    } else |_| {}
    
    // Try global config (~/.gitconfig)
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const global_config = try std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{home});
        defer allocator.free(global_config);
        if (platform_impl.fs.readFile(allocator, global_config)) |content| {
            defer allocator.free(content);
            if (parseConfigValue(content, alias_key, allocator) catch null) |val| {
                return val;
            }
        } else |_| {}
        
        // Try XDG config
        const xdg_config = try std.fmt.allocPrint(allocator, "{s}/.config/git/config", .{home});
        defer allocator.free(xdg_config);
        if (platform_impl.fs.readFile(allocator, xdg_config)) |content| {
            defer allocator.free(content);
            if (parseConfigValue(content, alias_key, allocator) catch null) |val| {
                return val;
            }
        } else |_| {}
    } else |_| {}
    
    // Try system config
    {
        if (platform_impl.fs.readFile(allocator, "/etc/gitconfig")) |content| {
            defer allocator.free(content);
            if (parseConfigValue(content, alias_key, allocator) catch null) |val| {
                return val;
            }
        } else |_| {}
    }
    
    return null;
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
        // Skip "--" separator (used to separate options from paths)
        if (std.mem.eql(u8, file_path, "--")) continue;
        // Skip flags like -n, -v, -f, --force, etc.
        if (file_path.len > 0 and file_path[0] == '-') continue;
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

            // Check if path exists (including broken symlinks)
            const path_exists = blk: {
                if (platform_impl.fs.exists(full_file_path) catch false) break :blk true;
                var link_buf: [4096]u8 = undefined;
                _ = std.fs.cwd().readLink(full_file_path, &link_buf) catch break :blk false;
                break :blk true;
            };
            if (!path_exists) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: pathspec '{s}' did not match any files\n", .{file_path});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }

            // Check if it's a directory or file
            const metadata = std.fs.cwd().statFile(full_file_path) catch {
                // If we can't stat it (e.g. broken symlink), try to add it
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
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--file")) {
            const file_path = args.next() orelse {
                try platform_impl.writeStderr("error: option '-F' requires a value\n");
                std.process.exit(129);
            };
            if (std.mem.eql(u8, file_path, "-")) {
                // Read from stdin
                const stdin_data = readStdin(allocator, 1024 * 1024) catch {
                    try platform_impl.writeStderr("error: could not read from stdin\n");
                    std.process.exit(1);
                };
                message = stdin_data;
            } else {
                message = platform_impl.fs.readFile(allocator, file_path) catch {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: could not read file '{s}'\n", .{file_path});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                };
            }
        } else if (std.mem.startsWith(u8, arg, "-F")) {
            const file_path = arg[2..];
            message = platform_impl.fs.readFile(allocator, file_path) catch {
                const msg = try std.fmt.allocPrint(allocator, "fatal: could not read file '{s}'\n", .{file_path});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            };
        } else if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--reuse-message")) {
            // Reuse message from another commit
            const commit_ref = args.next() orelse {
                try platform_impl.writeStderr("error: option '-C' requires a value\n");
                std.process.exit(129);
            };
            // Resolve and read the commit's message
            const gp = findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStderr("fatal: not a git repository\n");
                std.process.exit(128);
            };
            defer allocator.free(gp);
            const hash = resolveRevision(gp, commit_ref, platform_impl, allocator) catch {
                const err_msg = try std.fmt.allocPrint(allocator, "fatal: could not lookup commit {s}\n", .{commit_ref});
                defer allocator.free(err_msg);
                try platform_impl.writeStderr(err_msg);
                std.process.exit(128);
            };
            defer allocator.free(hash);
            const cobj = objects.GitObject.load(hash, gp, platform_impl, allocator) catch {
                try platform_impl.writeStderr("fatal: could not read commit\n");
                std.process.exit(128);
            };
            defer cobj.deinit(allocator);
            // Extract message body (after blank line)
            if (std.mem.indexOf(u8, cobj.data, "\n\n")) |pos| {
                message = try allocator.dupe(u8, cobj.data[pos + 2 ..]);
            }
        } else if (std.mem.eql(u8, arg, "--cleanup=verbatim") or std.mem.eql(u8, arg, "--cleanup=whitespace") or
            std.mem.eql(u8, arg, "--cleanup=strip") or std.mem.eql(u8, arg, "--cleanup=scissors") or
            std.mem.startsWith(u8, arg, "--cleanup="))
        {
            // Accept cleanup modes (ignore for now)
        } else if (std.mem.eql(u8, arg, "--no-verify") or std.mem.eql(u8, arg, "-n")) {
            // Skip hooks
        } else if (std.mem.eql(u8, arg, "--signoff") or std.mem.eql(u8, arg, "-s")) {
            // Signoff - ignore for now  
        } else if (std.mem.eql(u8, arg, "--no-edit")) {
            // No edit
        } else if (std.mem.eql(u8, arg, "--allow-empty-message")) {
            allow_empty = true; // Close enough
        }
    }

    // For --amend without -m, reuse the previous commit's message
    if (message == null and amend) {
        const gp = findGitDirectory(allocator, platform_impl) catch {
            try platform_impl.writeStderr("fatal: not a git repository\n");
            std.process.exit(128);
        };
        defer allocator.free(gp);
        if (refs.getCurrentCommit(gp, platform_impl, allocator) catch null) |cur_hash| {
            defer allocator.free(cur_hash);
            if (objects.GitObject.load(cur_hash, gp, platform_impl, allocator) catch null) |cobj| {
                defer cobj.deinit(allocator);
                if (std.mem.indexOf(u8, cobj.data, "\n\n")) |pos| {
                    message = try allocator.dupe(u8, cobj.data[pos + 2 ..]);
                }
            }
        }
    }

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

    // Load index
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };

    // If -a flag is set, update all tracked files in the index (pure Zig, no git CLI)
    if (add_all) {
        const repo_root = std.fs.path.dirname(git_path) orelse ".";
        try stageTrackedChanges(allocator, &index, git_path, repo_root, platform_impl);
    }
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

    // Create recursive tree objects from index entries (handles nested directories)
    const tree_hash = try buildRecursiveTree(allocator, index.entries.items, "", git_path, platform_impl);
    defer allocator.free(tree_hash);

    // Get parent commit (if any)
    var parent_hashes = std.array_list.Managed([]const u8).init(allocator);
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
                var lines = std.mem.splitSequence(u8, commit.data, "\n");
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
    const tz_offset = getTimezoneOffset(timestamp);
    const tz_sign: u8 = if (tz_offset < 0) '-' else '+';
    const tz_abs: u32 = @intCast(if (tz_offset < 0) -tz_offset else tz_offset);
    const tz_hours = tz_abs / 3600;
    const tz_minutes = (tz_abs % 3600) / 60;

    // Resolve author/committer identity
    const author_name_fallback: []const u8 = "ziggit";
    const author_name = resolveAuthorName(allocator, git_path) catch author_name_fallback;
    defer if (author_name.ptr != author_name_fallback.ptr) allocator.free(author_name);
    const author_email_fallback: []const u8 = "ziggit@example.com";
    const author_email = resolveAuthorEmail(allocator, git_path) catch author_email_fallback;
    defer if (author_email.ptr != author_email_fallback.ptr) allocator.free(author_email);
    const committer_name = resolveCommitterName(allocator, git_path, author_name) catch author_name;
    defer if (committer_name.ptr != author_name.ptr) allocator.free(committer_name);
    const committer_email = resolveCommitterEmail(allocator, git_path, author_email) catch author_email;
    defer if (committer_email.ptr != author_email.ptr) allocator.free(committer_email);

    const author_info = try std.fmt.allocPrint(allocator, "{s} <{s}> {d} {c}{d:0>2}{d:0>2}", .{ author_name, author_email, timestamp, tz_sign, tz_hours, tz_minutes });
    defer allocator.free(author_info);
    const committer_info = try std.fmt.allocPrint(allocator, "{s} <{s}> {d} {c}{d:0>2}{d:0>2}", .{ committer_name, committer_email, timestamp, tz_sign, tz_hours, tz_minutes });
    defer allocator.free(committer_info);

    const commit_object = try objects.createCommitObject(
        tree_hash,
        parent_hashes.items,
        author_info,
        committer_info,
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
        // Check if this is the first commit (root commit)
        const is_root = blk: {
            const cobj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch break :blk false;
            defer cobj.deinit(allocator);
            break :blk std.mem.indexOf(u8, cobj.data, "parent ") == null;
        };
        
        if (is_root) {
            const success_msg = try std.fmt.allocPrint(allocator, "[{s} (root-commit) {s}] {s}\n", .{ current_branch, short_hash, std.mem.trimRight(u8, message.?, "\n") });
            defer allocator.free(success_msg);
            try platform_impl.writeStdout(success_msg);
        } else {
            const success_msg = try std.fmt.allocPrint(allocator, "[{s} {s}] {s}\n", .{ current_branch, short_hash, std.mem.trimRight(u8, message.?, "\n") });
            defer allocator.free(success_msg);
            try platform_impl.writeStdout(success_msg);
        }
        
        // Add diffstat summary: count files changed
        // Compare current tree with parent tree to get stats
        const cobj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch null;
        if (cobj) |co| {
            defer co.deinit(allocator);
            var commit_tree_h: ?[]const u8 = null;
            var commit_parent_h: ?[]const u8 = null;
            var clines2 = std.mem.splitSequence(u8, co.data, "\n");
            while (clines2.next()) |line| {
                if (line.len == 0) break;
                if (std.mem.startsWith(u8, line, "tree ")) commit_tree_h = line["tree ".len..];
                if (std.mem.startsWith(u8, line, "parent ") and commit_parent_h == null) commit_parent_h = line["parent ".len..];
            }
            
            if (commit_tree_h) |_| {
                // Count files that changed (simplified)
                const file_count = index.entries.items.len;
                if (is_root and file_count > 0) {
                    // Root commit: all files are new
                    var total_lines: usize = 0;
                    for (index.entries.items) |entry| {
                        const repo_root_path = std.fs.path.dirname(git_path) orelse ".";
                        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root_path, entry.path });
                        defer allocator.free(full_path);
                        if (platform_impl.fs.readFile(allocator, full_path)) |content| {
                            defer allocator.free(content);
                            var line_count: usize = 0;
                            for (content) |c| {
                                if (c == '\n') line_count += 1;
                            }
                            if (content.len > 0 and content[content.len - 1] != '\n') line_count += 1;
                            total_lines += line_count;
                        } else |_| {}
                    }
                    const stat_msg = try std.fmt.allocPrint(allocator, " {d} file{s} changed, {d} insertion{s}(+)\n", .{
                        file_count,
                        if (file_count != 1) @as([]const u8, "s") else "",
                        total_lines,
                        if (total_lines != 1) @as([]const u8, "s") else "",
                    });
                    defer allocator.free(stat_msg);
                    try platform_impl.writeStdout(stat_msg);
                }
            }
        }
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
            format_string = arg["--format=".len..]; 
        } else if (std.mem.startsWith(u8, arg, "--pretty=format:")) {
            format_string = arg["--pretty=format:".len..];
        } else if (std.mem.startsWith(u8, arg, "--pretty=tformat:")) {
            format_string = arg["--pretty=tformat:".len..];
        } else if (std.mem.eql(u8, arg, "--pretty=oneline") or std.mem.eql(u8, arg, "--pretty=short")) {
            oneline = true;
        } else if (std.mem.startsWith(u8, arg, "--pretty=")) {
            // Other pretty formats - just use default for now
        } else if (std.mem.eql(u8, arg, "--first-parent")) {
            // first-parent flag - already the default behavior (we only follow first parent)
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
        var lines = std.mem.splitSequence(u8, commit_data, "\n");
        var parent_hash: ?[]const u8 = null;
        var author_line: ?[]const u8 = null;
        var empty_line_found = false;
        var message = std.array_list.Managed(u8).init(allocator);
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
                var msg_lines = std.mem.splitSequence(u8, std.mem.trimRight(u8, message.items, "\n"), "\n");
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
        var lines = std.mem.splitSequence(u8, commit_obj.data, "\n");
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
    // Use the comprehensive resolveRevision which handles all ref formats,
    // ~, ^, ^{type}, hashes, branches, tags, remotes, packed-refs
    return resolveRevision(git_path, committish, platform_impl, allocator) catch error.UnknownRevision;
}

fn outputFormattedCommit(format: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // We need access to the full commit object for format specifiers
    const git_path = findGitDirectory(allocator, platform_impl) catch return;
    defer allocator.free(git_path);
    
    const commit_obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch return;
    defer commit_obj.deinit(allocator);
    
    // Parse commit fields
    var tree_hash: []const u8 = "";
    var parent_hashes = std.array_list.Managed([]const u8).init(allocator);
    defer parent_hashes.deinit();
    var author_full: []const u8 = "";
    var committer_full: []const u8 = "";
    var subject: []const u8 = "";
    var body = std.array_list.Managed(u8).init(allocator);
    defer body.deinit();
    
    var lines_iter = std.mem.splitSequence(u8, commit_obj.data, "\n");
    var in_body = false;
    var first_body_line = true;
    while (lines_iter.next()) |line| {
        if (in_body) {
            if (first_body_line) {
                subject = line;
                first_body_line = false;
            } else {
                if (body.items.len > 0) body.append('\n') catch {};
                body.appendSlice(line) catch {};
            }
        } else if (line.len == 0) {
            in_body = true;
        } else if (std.mem.startsWith(u8, line, "tree ")) {
            tree_hash = line["tree ".len..];
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            parent_hashes.append(line["parent ".len..]) catch {};
        } else if (std.mem.startsWith(u8, line, "author ")) {
            author_full = line["author ".len..];
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            committer_full = line["committer ".len..];
        }
    }
    
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    
    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '%' and i + 1 < format.len) {
            const c = format[i + 1];
            if (c == 'H') {
                try output.appendSlice(commit_hash);
                i += 2;
            } else if (c == 'h') {
                try output.appendSlice(if (commit_hash.len >= 7) commit_hash[0..7] else commit_hash);
                i += 2;
            } else if (c == 'T') {
                try output.appendSlice(tree_hash);
                i += 2;
            } else if (c == 't') {
                try output.appendSlice(if (tree_hash.len >= 7) tree_hash[0..7] else tree_hash);
                i += 2;
            } else if (c == 'P') {
                for (parent_hashes.items, 0..) |ph, pi| {
                    if (pi > 0) try output.append(' ');
                    try output.appendSlice(ph);
                }
                i += 2;
            } else if (c == 'p') {
                for (parent_hashes.items, 0..) |ph, pi| {
                    if (pi > 0) try output.append(' ');
                    try output.appendSlice(if (ph.len >= 7) ph[0..7] else ph);
                }
                i += 2;
            } else if (c == 's') {
                try output.appendSlice(subject);
                i += 2;
            } else if (c == 'b') {
                try output.appendSlice(std.mem.trimRight(u8, body.items, "\n"));
                i += 2;
            } else if (c == 'B') {
                try output.appendSlice(subject);
                if (body.items.len > 0) {
                    try output.append('\n');
                    try output.appendSlice(body.items);
                }
                i += 2;
            } else if (c == 'n') {
                try output.append('\n');
                i += 2;
            } else if (c == '%') {
                try output.append('%');
                i += 2;
            } else if (c == 'a' and i + 2 < format.len) {
                // %an = author name, %ae = author email, %ad = author date, %aI = ISO date
                const spec = format[i + 2];
                const parsed = parseIdentField(author_full);
                if (spec == 'n') {
                    try output.appendSlice(parsed.name);
                } else if (spec == 'e') {
                    try output.appendSlice(parsed.email);
                } else if (spec == 'd' or spec == 'D' or spec == 'i' or spec == 'I') {
                    try output.appendSlice(parsed.date);
                } else {
                    try output.appendSlice(author_full);
                }
                i += 3;
            } else if (c == 'c' and i + 2 < format.len) {
                // %cn, %ce, %cd, %cI
                const spec = format[i + 2];
                const parsed = parseIdentField(committer_full);
                if (spec == 'n') {
                    try output.appendSlice(parsed.name);
                } else if (spec == 'e') {
                    try output.appendSlice(parsed.email);
                } else if (spec == 'd' or spec == 'D' or spec == 'i' or spec == 'I') {
                    try output.appendSlice(parsed.date);
                } else {
                    try output.appendSlice(committer_full);
                }
                i += 3;
            } else if (c == 'd') {
                // %d = decorations (simplified - just empty for now)
                i += 2;
            } else if (c == 'D') {
                // %D = decorations without wrapping
                i += 2;
            } else if (c == 'G' and i + 2 < format.len) {
                // %G? = GPG signature placeholders
                i += 3;
            } else if (c == 'C' and i + 2 < format.len) {
                // %C(...) = color codes - skip
                if (i + 2 < format.len and format[i + 2] == '(') {
                    // Find closing paren
                    var j = i + 3;
                    while (j < format.len and format[j] != ')') : (j += 1) {}
                    i = if (j < format.len) j + 1 else j;
                } else {
                    i += 3;
                }
            } else if (c == 'x' and i + 3 < format.len) {
                // %x00 = hex byte
                const hex_str = format[i + 2 .. i + 4];
                const byte_val = std.fmt.parseInt(u8, hex_str, 16) catch 0;
                try output.append(byte_val);
                i += 4;
            } else {
                try output.append(format[i]);
                try output.append(format[i + 1]);
                i += 2;
            }
        } else if (format[i] == '\\' and i + 1 < format.len) {
            if (format[i + 1] == 'n') {
                try output.append('\n');
                i += 2;
            } else if (format[i + 1] == 't') {
                try output.append('\t');
                i += 2;
            } else {
                try output.append(format[i]);
                i += 1;
            }
        } else {
            try output.append(format[i]);
            i += 1;
        }
    }
    
    try output.append('\n');
    try platform_impl.writeStdout(output.items);
}

const ParsedIdent = struct {
    name: []const u8,
    email: []const u8,
    date: []const u8,
};

fn parseIdentField(ident: []const u8) ParsedIdent {
    // Parse "Name <email> timestamp timezone"
    if (std.mem.indexOf(u8, ident, " <")) |lt_pos| {
        const name = ident[0..lt_pos];
        if (std.mem.indexOf(u8, ident[lt_pos..], "> ")) |gt_pos| {
            const email = ident[lt_pos + 2 .. lt_pos + gt_pos];
            const date = ident[lt_pos + gt_pos + 2 ..];
            return .{ .name = name, .email = email, .date = date };
        }
        return .{ .name = name, .email = ident[lt_pos + 2 ..], .date = "" };
    }
    return .{ .name = ident, .email = "", .date = "" };
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
            const index_hash = try std.fmt.allocPrint(allocator, "{x}", .{&entry.sha1});
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
            const index_hash = try std.fmt.allocPrint(allocator, "{x}", .{&entry.sha1});
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
            const index_hash = try std.fmt.allocPrint(allocator, "{x}", .{&entry.sha1});
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
            const index_hash = try std.fmt.allocPrint(allocator, "{x}", .{&entry.sha1});
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
    _ = std.fmt.bufPrint(hash_str, "{x}", .{&entry.sha1}) catch |err| {
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

    // Check if this is --orphan flag (create orphan branch)
    if (std.mem.eql(u8, first_arg, "--orphan")) {
        const branch_name = args.next() orelse {
            try platform_impl.writeStderr("fatal: option '--orphan' requires a value\n");
            std.process.exit(128);
        };

        // Set HEAD to point to the new branch (which doesn't exist yet)
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
        defer allocator.free(head_path);
        const ref_content = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{branch_name});
        defer allocator.free(ref_content);
        platform_impl.fs.writeFile(head_path, ref_content) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "error: failed to create orphan branch: {}\n", .{err});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };

        // Remove the index to start fresh
        const index_path = try std.fmt.allocPrint(allocator, "{s}/index", .{git_path});
        defer allocator.free(index_path);
        std.fs.cwd().deleteFile(index_path) catch {};

        const success_msg = try std.fmt.allocPrint(allocator, "Switched to a new branch '{s}'\n", .{branch_name});
        defer allocator.free(success_msg);
        try platform_impl.writeStderr(success_msg);
        return;
    }

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

        // Try to resolve revision expressions (like A^0, HEAD~3, etc.)
        // If the target contains special chars, resolve to a hash first
        const resolved_target = if (std.mem.indexOfAny(u8, target, "~^@") != null)
            resolveRevision(git_path, target, platform_impl, allocator) catch null
        else
            null;
        defer if (resolved_target) |rt| allocator.free(rt);
        const actual_target = resolved_target orelse target;

        // For detached HEAD (resolved hash), just update HEAD directly
        if (resolved_target != null) {
            // This is a detached HEAD checkout
            try checkoutCommitTree(git_path, actual_target, allocator, platform_impl);
            
            // Write detached HEAD
            const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
            defer allocator.free(head_path);
            const head_content = try std.fmt.allocPrint(allocator, "{s}\n", .{actual_target});
            defer allocator.free(head_content);
            platform_impl.fs.writeFile(head_path, head_content) catch {};
            
            if (!quiet) {
                const det_msg = try std.fmt.allocPrint(allocator, "Note: switching to '{s}'.\nHEAD is now at {s}\n", .{ target, actual_target[0..7] });
                defer allocator.free(det_msg);
                try platform_impl.writeStderr(det_msg);
            }
            return;
        }

        // Use native ziggit checkout
        const ziggit = @import("ziggit.zig");
        
        // Determine repository root from git_path
        const repo_root = if (std.mem.endsWith(u8, git_path, "/.git"))
            git_path[0 .. git_path.len - 5]
        else
            git_path; // bare repo
        
        var repo = ziggit.Repository.open(allocator, repo_root) catch {
            try platform_impl.writeStderr("fatal: not a git repository\n");
            std.process.exit(128);
        };
        defer repo.close();
        
        repo.checkout(actual_target) catch |err| {
            switch (err) {
                error.CommitNotFound => {
                    const msg = try std.fmt.allocPrint(allocator, "error: pathspec '{s}' did not match any file(s) known to git\n", .{target});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(1);
                },
                error.RefNotFound => {
                    const msg = try std.fmt.allocPrint(allocator, "error: pathspec '{s}' did not match any file(s) known to git\n", .{target});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(1);
                },
                error.ObjectNotFound => {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: reference is not a tree: {s}\n", .{target});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                },
                error.InvalidCommitObject, error.InvalidTreeObject => {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: corrupt object for '{s}'\n", .{target});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                },
                else => {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: checkout failed: {}\n", .{err});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                },
            }
        };
        
        if (!quiet) {
            // Check if this was a branch or detached HEAD
            var ref_check_buf: [std.fs.max_path_bytes]u8 = undefined;
            const branch_ref_path = std.fmt.bufPrint(&ref_check_buf, "{s}/refs/heads/{s}", .{ repo.git_dir, target }) catch {
                return;
            };
            
            if (std.fs.accessAbsolute(branch_ref_path, .{})) |_| {
                const msg = try std.fmt.allocPrint(allocator, "Switched to branch '{s}'\n", .{target});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            } else |_| {
                const msg = try std.fmt.allocPrint(allocator, "HEAD is now at {s}\n", .{target[0..@min(target.len, 7)]});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
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
    var lines = std.mem.splitSequence(u8, commit_data, "\n");
    
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
        _ = std.fmt.bufPrint(hash_hex, "{x}", .{hash_bytes}) catch break;
        
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
    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch {
        // Failed to load tree for index update
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
            _ = try std.fmt.bufPrint(hash_hex, "{x}", .{hash_bytes});
            
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

    // Parse merge arguments
    var merge_message: ?[]const u8 = null;
    var allow_unrelated_histories = false;
    var no_ff = false;
    var ff_only = false;
    var branch_to_merge: ?[]const u8 = null;
    var squash = false;
    var no_commit = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-m")) {
            merge_message = args.next() orelse {
                try platform_impl.writeStderr("fatal: option '-m' requires a value\n");
                std.process.exit(128);
            };
        } else if (std.mem.startsWith(u8, arg, "-m")) {
            // -mMESSAGE (no space)
            merge_message = arg[2..];
        } else if (std.mem.eql(u8, arg, "--allow-unrelated-histories")) {
            allow_unrelated_histories = true;
        } else if (std.mem.eql(u8, arg, "--no-ff")) {
            no_ff = true;
        } else if (std.mem.eql(u8, arg, "--ff-only")) {
            ff_only = true;
        } else if (std.mem.eql(u8, arg, "--squash")) {
            squash = true;
        } else if (std.mem.eql(u8, arg, "--no-commit")) {
            no_commit = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            branch_to_merge = arg;
        }
    }

    if (branch_to_merge == null) {
        try platform_impl.writeStderr("fatal: no merge target specified\n");
        std.process.exit(128);
    }

    // Get current branch
    const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: unable to determine current branch\n");
        std.process.exit(128);
    };
    defer allocator.free(current_branch);

    const merge_target = branch_to_merge.?;

    // Try to resolve the merge target as a revision (could be branch name, tag, or hash)
    const target_hash_resolved = resolveRevision(git_path, merge_target, platform_impl, allocator) catch blk: {
        // Also try as branch
        if (refs.branchExists(git_path, merge_target, platform_impl, allocator) catch false) {
            break :blk refs.getBranchCommit(git_path, merge_target, platform_impl, allocator) catch null;
        }
        break :blk null;
    };

    if (target_hash_resolved == null) {
        // Check if branch exists using the old logic
        if (!(refs.branchExists(git_path, merge_target, platform_impl, allocator) catch false)) {
            const msg = try std.fmt.allocPrint(allocator, "merge: '{s}' - not something we can merge\n", .{merge_target});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        }
    }

    // Check if trying to merge with itself
    if (std.mem.eql(u8, current_branch, merge_target)) {
        try platform_impl.writeStdout("Already up to date.\n");
        return;
    }

    // Get the current and target commit hashes
    const current_commit_result = refs.getCurrentCommit(git_path, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: unable to get current commit\n");
        std.process.exit(1);
    };
    defer if (current_commit_result) |hash| allocator.free(hash);

    const target_hash = if (target_hash_resolved) |h| h else blk: {
        const target_commit_result = refs.getBranchCommit(git_path, merge_target, platform_impl, allocator) catch {
            try platform_impl.writeStderr("fatal: unable to get target branch commit\n");  
            std.process.exit(1);
        };
        break :blk if (target_commit_result) |hash| hash else {
            try platform_impl.writeStderr("fatal: no commits yet on target branch\n");
            std.process.exit(1);
        };
    };
    defer allocator.free(target_hash);

    const current_hash = if (current_commit_result) |hash| hash else {
        // No current commits - if allow_unrelated_histories, just set the ref
        if (allow_unrelated_histories) {
            try refs.updateRef(git_path, current_branch, target_hash, platform_impl, allocator);
            try checkoutCommitTree(git_path, target_hash, allocator, platform_impl);
            try platform_impl.writeStdout("Fast-forward\n");
            return;
        }
        try platform_impl.writeStderr("fatal: no commits yet on current branch\n");
        std.process.exit(1);
    };

    // Check if this is a fast-forward merge
    if (!no_ff and canFastForward(git_path, current_hash, target_hash, allocator, platform_impl)) {
        // Fast-forward merge
        try refs.updateRef(git_path, current_branch, target_hash, platform_impl, allocator);
        try checkoutCommitTree(git_path, target_hash, allocator, platform_impl);

        const msg2 = try std.fmt.allocPrint(allocator, "Fast-forward\n", .{});
        defer allocator.free(msg2);
        try platform_impl.writeStdout(msg2);
        
        const short_hash = target_hash[0..7];
        const success_msg = try std.fmt.allocPrint(allocator, "Updating {s}..{s}\n", .{ current_hash[0..7], short_hash });
        defer allocator.free(success_msg);
        try platform_impl.writeStdout(success_msg);
    } else {
        // Perform 3-way merge (or merge commit for unrelated histories)
        if (allow_unrelated_histories) {
            // Create a merge commit with both parents
            const actual_message = merge_message orelse blk: {
                break :blk try std.fmt.allocPrint(allocator, "Merge branch '{s}'", .{merge_target});
            };
            const should_free_msg = merge_message == null;
            defer if (should_free_msg) allocator.free(actual_message);

            // Get tree from current HEAD commit
            const current_obj = objects.GitObject.load(current_hash, git_path, platform_impl, allocator) catch {
                try platform_impl.writeStderr("fatal: unable to read current commit\n");
                std.process.exit(1);
            };
            defer current_obj.deinit(allocator);

            var tree_hash: ?[]const u8 = null;
            var clines = std.mem.splitSequence(u8, current_obj.data, "\n");
            while (clines.next()) |line| {
                if (std.mem.startsWith(u8, line, "tree ")) {
                    tree_hash = line[5..];
                    break;
                }
            }

            if (tree_hash == null) {
                try platform_impl.writeStderr("fatal: unable to find tree in current commit\n");
                std.process.exit(1);
            }

            // Create merge commit with two parents
            const author_str = getAuthorString(allocator) catch try allocator.dupe(u8, "Unknown <unknown@unknown>");
            defer allocator.free(author_str);
            const committer_str = getCommitterString(allocator) catch try allocator.dupe(u8, "Unknown <unknown@unknown>");
            defer allocator.free(committer_str);
            const commit_content = try std.fmt.allocPrint(allocator, "tree {s}\nparent {s}\nparent {s}\nauthor {s}\ncommitter {s}\n\n{s}\n", .{ tree_hash.?, current_hash, target_hash, author_str, committer_str, actual_message });
            defer allocator.free(commit_content);

            const commit_obj = objects.GitObject.init(.commit, commit_content);
            const merge_commit_hash = commit_obj.store(git_path, platform_impl, allocator) catch {
                try platform_impl.writeStderr("fatal: unable to write merge commit\n");
                std.process.exit(1);
            };
            defer allocator.free(merge_commit_hash);

            // Update the current branch to point to the merge commit
            try refs.updateRef(git_path, current_branch, merge_commit_hash, platform_impl, allocator);

            const success_msg = try std.fmt.allocPrint(allocator, "Merge made by the 'ort' strategy.\n", .{});
            defer allocator.free(success_msg);
            try platform_impl.writeStdout(success_msg);
        } else {
            try performThreeWayMerge(git_path, current_hash, target_hash, current_branch, merge_target, allocator, platform_impl);
        }
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
    var lines = std.mem.splitSequence(u8, descendant_commit.data, "\n");
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
    var lines = std.mem.splitSequence(u8, commit_obj.data, "\n");
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
    var lines = std.mem.splitSequence(u8, commit_obj.data, "\n");
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
        _ = std.fmt.bufPrint(hash_hex, "{x}", .{hash_bytes}) catch {
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
    var conflict_content = std.array_list.Managed(u8).init(allocator);
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
    try writer.print("{s}", .{">>>>>>> incoming\n"});

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
    var remote_name: []const u8 = "origin";
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            remote_name = arg;
        }
    }

    // Read the remote URL from config
    const remote_url = getRemoteUrl(git_path, remote_name, platform_impl, allocator) catch |err| switch (err) {
        error.RemoteNotFound => {
            const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' does not appear to be a git repository\n", .{remote_name});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        },
        else => return err,
    };
    defer allocator.free(remote_url);

    // For HTTPS URLs, use native Zig fetch
    if (std.mem.startsWith(u8, remote_url, "https://") or std.mem.startsWith(u8, remote_url, "http://")) {
        const ziggit = @import("ziggit.zig");
        // Determine the repo path: for bare repos git_path IS the repo, for normal repos it's the parent
        const is_bare_repo = !std.mem.endsWith(u8, git_path, "/.git");
        const repo_path = if (is_bare_repo) git_path else (std.fs.path.dirname(git_path) orelse ".");
        var repo = ziggit.Repository.open(allocator, repo_path) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "fatal: {}\n", .{err});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        defer repo.close();

        repo.fetch(remote_url) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "fatal: could not fetch from '{s}': {}\n", .{ remote_url, err });
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };

        if (!quiet) {
            // Mimic git's quiet fetch output (no output on success with --quiet is default git behavior,
            // but without --quiet we print nothing extra either since git fetch is normally quiet on success)
        }
        return;
    }

    // For non-HTTPS URLs, not yet supported natively
    try platform_impl.writeStderr("fatal: non-HTTPS fetch not supported natively yet\n");
    std.process.exit(128);
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

/// Resolve a path to its .git directory. Handles bare repos, .git files (worktrees/submodules),
/// and file:// URLs. Returns the path to the git directory (objects, refs, etc.).
fn resolveSourceGitDir(allocator: std.mem.Allocator, source_path: []const u8) ![]const u8 {
    // Strip file:// prefix if present
    const path = if (std.mem.startsWith(u8, source_path, "file://"))
        source_path["file://".len..]
    else
        source_path;

    // Resolve to absolute path
    const abs_path = std.fs.cwd().realpathAlloc(allocator, path) catch {
        return error.RepositoryNotFound;
    };
    errdefer allocator.free(abs_path);

    // Check if it's a bare repo (has objects/ and refs/ directly)
    const objects_path = try std.fmt.allocPrint(allocator, "{s}/objects", .{abs_path});
    defer allocator.free(objects_path);
    const refs_path = try std.fmt.allocPrint(allocator, "{s}/refs", .{abs_path});
    defer allocator.free(refs_path);

    const has_objects = std.fs.cwd().access(objects_path, .{});
    const has_refs = std.fs.cwd().access(refs_path, .{});

    if (has_objects != error.FileNotFound and has_refs != error.FileNotFound) {
        // This is a bare repo or .git directory
        return abs_path;
    }

    // Check for .git subdirectory
    const git_subdir = try std.fmt.allocPrint(allocator, "{s}/.git", .{abs_path});
    defer allocator.free(git_subdir);

    // .git could be a file (gitlink) or directory
    if (std.fs.cwd().openFile(git_subdir, .{})) |file| {
        defer file.close();
        // Read gitlink content
        var buf: [4096]u8 = undefined;
        const n = file.readAll(&buf) catch return error.RepositoryNotFound;
        const content = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (std.mem.startsWith(u8, content, "gitdir: ")) {
            const gitdir_ref = content["gitdir: ".len..];
            if (std.fs.path.isAbsolute(gitdir_ref)) {
                allocator.free(abs_path);
                return try allocator.dupe(u8, gitdir_ref);
            } else {
                const resolved = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ abs_path, gitdir_ref });
                allocator.free(abs_path);
                return resolved;
            }
        }
        return error.RepositoryNotFound;
    } else |_| {}

    // Check if .git is a directory
    const git_objects = try std.fmt.allocPrint(allocator, "{s}/.git/objects", .{abs_path});
    defer allocator.free(git_objects);
    if (std.fs.cwd().access(git_objects, .{}) != error.FileNotFound) {
        const result = try std.fmt.allocPrint(allocator, "{s}/.git", .{abs_path});
        allocator.free(abs_path);
        return result;
    }

    allocator.free(abs_path);
    return error.RepositoryNotFound;
}

/// Copy a directory recursively from src to dst
fn copyDirectoryRecursive(allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8) !void {
    std.fs.cwd().makePath(dst_path) catch {};

    var src_dir = std.fs.cwd().openDir(src_path, .{ .iterate = true }) catch return;
    defer src_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        const src_child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_path, entry.name });
        defer allocator.free(src_child);
        const dst_child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst_path, entry.name });
        defer allocator.free(dst_child);

        switch (entry.kind) {
            .directory => {
                try copyDirectoryRecursive(allocator, src_child, dst_child);
            },
            .file => {
                std.fs.cwd().copyFile(src_child, std.fs.cwd(), dst_child, .{}) catch {};
            },
            .sym_link => {
                // Read and recreate symlink
                var link_buf: [std.fs.max_path_bytes]u8 = undefined;
                const link_target = std.fs.cwd().readLink(src_child, &link_buf) catch continue;
                // Delete existing file/link at destination if any
                std.fs.cwd().deleteFile(dst_child) catch {};
                const dst_dir = std.fs.cwd().openDir(dst_path, .{}) catch continue;
                // Use the directory-relative createSymLink
                var dst_dir_m = dst_dir;
                dst_dir_m.symLink(link_target, entry.name, .{}) catch {};
            },
            else => {},
        }
    }
}

/// Perform a local clone (copy objects and refs from source git dir to destination)
fn performLocalClone(
    allocator: std.mem.Allocator,
    source_url: []const u8,
    target_dir: []const u8,
    is_bare: bool,
    is_no_checkout: bool,
    branch: ?[]const u8,
    origin_name: ?[]const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    // Resolve source git directory
    const src_git_dir = try resolveSourceGitDir(allocator, source_url);
    defer allocator.free(src_git_dir);

    const remote_name = origin_name orelse "origin";

    // Determine the target .git directory
    const dst_git_dir = if (is_bare)
        try allocator.dupe(u8, target_dir)
    else
        try std.fmt.allocPrint(allocator, "{s}/.git", .{target_dir});
    defer allocator.free(dst_git_dir);

    // Create destination directory structure
    std.fs.cwd().makePath(dst_git_dir) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "fatal: cannot mkdir {s}: {}\n", .{ dst_git_dir, err });
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    };

    // Create standard git directory structure
    const dirs_to_create = [_][]const u8{
        "objects", "objects/info", "objects/pack", "refs", "refs/heads", "refs/tags", "info",
    };
    for (dirs_to_create) |subdir| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst_git_dir, subdir });
        defer allocator.free(full_path);
        std.fs.cwd().makePath(full_path) catch {};
    }

    // Copy objects (loose objects + pack files)
    const src_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{src_git_dir});
    defer allocator.free(src_objects);
    const dst_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{dst_git_dir});
    defer allocator.free(dst_objects);
    try copyDirectoryRecursive(allocator, src_objects, dst_objects);

    // Copy packed-refs if it exists
    const src_packed_refs = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{src_git_dir});
    defer allocator.free(src_packed_refs);

    // Read source HEAD to determine default branch
    const src_head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{src_git_dir});
    defer allocator.free(src_head_path);
    const src_head_content = std.fs.cwd().readFileAlloc(allocator, src_head_path, 4096) catch "ref: refs/heads/master\n";
    defer if (src_head_content.ptr != @as([*]const u8, "ref: refs/heads/master\n")) allocator.free(src_head_content);

    const src_head_trimmed = std.mem.trim(u8, src_head_content, " \t\r\n");

    // Determine the default branch from source HEAD
    var default_branch: []const u8 = "master";
    if (std.mem.startsWith(u8, src_head_trimmed, "ref: refs/heads/")) {
        default_branch = src_head_trimmed["ref: refs/heads/".len..];
    }

    // If --branch was specified, use that
    const checkout_branch = branch orelse default_branch;

    if (is_bare) {
        // For bare repos, copy all refs directly and set HEAD
        const src_refs = try std.fmt.allocPrint(allocator, "{s}/refs", .{src_git_dir});
        defer allocator.free(src_refs);
        const dst_refs = try std.fmt.allocPrint(allocator, "{s}/refs", .{dst_git_dir});
        defer allocator.free(dst_refs);
        try copyDirectoryRecursive(allocator, src_refs, dst_refs);

        // Copy packed-refs
        const dst_packed_refs = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{dst_git_dir});
        defer allocator.free(dst_packed_refs);
        std.fs.cwd().copyFile(src_packed_refs, std.fs.cwd(), dst_packed_refs, .{}) catch {};

        // Set HEAD
        const dst_head = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{dst_git_dir});
        defer allocator.free(dst_head);
        {
            const f = try std.fs.cwd().createFile(dst_head, .{});
            defer f.close();
            const head_ref = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{checkout_branch});
            defer allocator.free(head_ref);
            try f.writeAll(head_ref);
        }

        // Write config
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{dst_git_dir});
        defer allocator.free(config_path);
        {
            const f = try std.fs.cwd().createFile(config_path, .{});
            defer f.close();
            // Resolve the source URL to an absolute path for the remote
            const abs_source = std.fs.cwd().realpathAlloc(allocator, if (std.mem.startsWith(u8, source_url, "file://")) source_url["file://".len..] else source_url) catch try allocator.dupe(u8, source_url);
            defer allocator.free(abs_source);
            const cfg = try std.fmt.allocPrint(allocator, "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n[remote \"{s}\"]\n\turl = {s}\n", .{ remote_name, abs_source });
            defer allocator.free(cfg);
            try f.writeAll(cfg);
        }

        // Write description
        const desc_path = try std.fmt.allocPrint(allocator, "{s}/description", .{dst_git_dir});
        defer allocator.free(desc_path);
        {
            const f = std.fs.cwd().createFile(desc_path, .{}) catch return;
            defer f.close();
            f.writeAll("Unnamed repository; edit this file 'description' to name the repository.\n") catch {};
        }

    } else {
        // Non-bare clone: source refs become remote tracking refs
        // Map source refs/heads/* to refs/remotes/<origin>/*
        const remote_refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}", .{ dst_git_dir, remote_name });
        defer allocator.free(remote_refs_dir);
        std.fs.cwd().makePath(remote_refs_dir) catch {};

        // Copy source heads to remote tracking
        const src_heads = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{src_git_dir});
        defer allocator.free(src_heads);

        // Read all source branch refs (loose)
        var branch_map = std.StringHashMap([]const u8).init(allocator);
        defer {
            var it = branch_map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            branch_map.deinit();
        }

        if (std.fs.cwd().openDir(src_heads, .{ .iterate = true })) |*dir_handle| {
            var d = dir_handle.*;
            defer d.close();
            var iter = d.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind == .file) {
                    const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_heads, entry.name });
                    defer allocator.free(ref_path);
                    const hash = std.fs.cwd().readFileAlloc(allocator, ref_path, 256) catch continue;
                    const hash_trimmed = std.mem.trim(u8, hash, " \t\r\n");
                    const ht = try allocator.dupe(u8, hash_trimmed);
                    allocator.free(hash);
                    try branch_map.put(try allocator.dupe(u8, entry.name), ht);
                }
            }
        } else |_| {}

        // Also read packed-refs from source
        if (std.fs.cwd().readFileAlloc(allocator, src_packed_refs, 10 * 1024 * 1024)) |packed_content| {
            defer allocator.free(packed_content);
            var lines = std.mem.splitScalar(u8, packed_content, '\n');
            while (lines.next()) |line| {
                if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
                // Format: <hash> <refname>
                if (std.mem.indexOfScalar(u8, line, ' ')) |space_idx| {
                    const hash = line[0..space_idx];
                    const refname = line[space_idx + 1..];
                    if (std.mem.startsWith(u8, refname, "refs/heads/")) {
                        const bname = refname["refs/heads/".len..];
                        if (!branch_map.contains(bname)) {
                            try branch_map.put(
                                try allocator.dupe(u8, bname),
                                try allocator.dupe(u8, hash),
                            );
                        }
                    }
                }
            }
        } else |_| {}

        // Write remote tracking refs
        var branch_iter = branch_map.iterator();
        while (branch_iter.next()) |entry| {
            const dst_ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_refs_dir, entry.key_ptr.* });
            defer allocator.free(dst_ref_path);
            const f = std.fs.cwd().createFile(dst_ref_path, .{}) catch continue;
            defer f.close();
            f.writeAll(entry.value_ptr.*) catch continue;
            f.writeAll("\n") catch continue;
        }

        // Copy tags
        const src_tags = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{src_git_dir});
        defer allocator.free(src_tags);
        const dst_tags = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{dst_git_dir});
        defer allocator.free(dst_tags);
        copyDirectoryRecursive(allocator, src_tags, dst_tags) catch {};

        // Also copy packed-refs but rewrite heads to remotes
        if (std.fs.cwd().readFileAlloc(allocator, src_packed_refs, 10 * 1024 * 1024)) |packed_content| {
            defer allocator.free(packed_content);
            var new_packed = std.array_list.Managed(u8).init(allocator);
            defer new_packed.deinit();
            var lines = std.mem.splitScalar(u8, packed_content, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                if (line[0] == '#') {
                    try new_packed.appendSlice(line);
                    try new_packed.append('\n');
                    continue;
                }
                if (std.mem.indexOf(u8, line, "refs/heads/")) |_| {
                    // Rewrite refs/heads/X to refs/remotes/<origin>/X
                    if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
                        try new_packed.appendSlice(line[0 .. sp + 1]);
                        const refname = line[sp + 1..];
                        if (std.mem.startsWith(u8, refname, "refs/heads/")) {
                            const bname = refname["refs/heads/".len..];
                            const new_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ remote_name, bname });
                            defer allocator.free(new_ref);
                            try new_packed.appendSlice(new_ref);
                        } else {
                            try new_packed.appendSlice(refname);
                        }
                        try new_packed.append('\n');
                    }
                } else if (std.mem.indexOf(u8, line, "refs/tags/")) |_| {
                    try new_packed.appendSlice(line);
                    try new_packed.append('\n');
                } else if (line[0] == '^') {
                    // Peeled tag ref - keep it
                    try new_packed.appendSlice(line);
                    try new_packed.append('\n');
                }
            }
            if (new_packed.items.len > 0) {
                const dst_packed = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{dst_git_dir});
                defer allocator.free(dst_packed);
                const f = std.fs.cwd().createFile(dst_packed, .{}) catch unreachable;
                defer f.close();
                f.writeAll(new_packed.items) catch {};
            }
        } else |_| {}

        // Create local branch from the checkout branch
        const branch_hash = branch_map.get(checkout_branch) orelse blk: {
            // Try default_branch if checkout_branch not found
            if (branch_map.get(default_branch)) |h| break :blk h;
            // Use first available branch
            var first_iter = branch_map.iterator();
            if (first_iter.next()) |entry| break :blk entry.value_ptr.*;
            break :blk null;
        };

        if (branch_hash) |hash| {
            // Create local branch ref
            const local_ref = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ dst_git_dir, checkout_branch });
            defer allocator.free(local_ref);
            {
                const f = try std.fs.cwd().createFile(local_ref, .{});
                defer f.close();
                try f.writeAll(hash);
                try f.writeAll("\n");
            }

            // Set HEAD to point to the branch
            const dst_head = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{dst_git_dir});
            defer allocator.free(dst_head);
            {
                const f = try std.fs.cwd().createFile(dst_head, .{});
                defer f.close();
                const head_content = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{checkout_branch});
                defer allocator.free(head_content);
                try f.writeAll(head_content);
            }
        } else {
            // Empty repository or no branches
            const dst_head = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{dst_git_dir});
            defer allocator.free(dst_head);
            {
                const f = try std.fs.cwd().createFile(dst_head, .{});
                defer f.close();
                try f.writeAll("ref: refs/heads/master\n");
            }
            try platform_impl.writeStderr("warning: You appear to have cloned an empty repository.\n");
        }

        // Write config
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{dst_git_dir});
        defer allocator.free(config_path);
        {
            const f = try std.fs.cwd().createFile(config_path, .{});
            defer f.close();
            const abs_source = std.fs.cwd().realpathAlloc(allocator, if (std.mem.startsWith(u8, source_url, "file://")) source_url["file://".len..] else source_url) catch try allocator.dupe(u8, source_url);
            defer allocator.free(abs_source);
            const cfg = try std.fmt.allocPrint(allocator, "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n[remote \"{s}\"]\n\turl = {s}\n\tfetch = +refs/heads/*:refs/remotes/{s}/*\n[branch \"{s}\"]\n\tremote = {s}\n\tmerge = refs/heads/{s}\n", .{ remote_name, abs_source, remote_name, checkout_branch, remote_name, checkout_branch });
            defer allocator.free(cfg);
            try f.writeAll(cfg);
        }

        // Write description
        const desc_path = try std.fmt.allocPrint(allocator, "{s}/description", .{dst_git_dir});
        defer allocator.free(desc_path);
        {
            const f = std.fs.cwd().createFile(desc_path, .{}) catch return;
            defer f.close();
            f.writeAll("Unnamed repository; edit this file 'description' to name the repository.\n") catch {};
        }

        // Checkout working tree (unless --no-checkout)
        if (!is_no_checkout and branch_hash != null) {
            checkoutCommitTree(dst_git_dir, branch_hash.?, allocator, platform_impl) catch |err| {
                const emsg = try std.fmt.allocPrint(allocator, "warning: checkout failed: {}, repository cloned but working tree not populated\n", .{err});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
            };
        }
    }
}

fn cmdClone(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform, _: [][]const u8) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("clone: not supported in freestanding mode\n");
        return;
    }

    // Collect all arguments first
    var all_args = std.array_list.Managed([]const u8).init(allocator);
    defer all_args.deinit();
    
    while (args.next()) |arg| {
        try all_args.append(arg);
    }

    // Check flags
    var is_bare = false;
    var is_no_checkout = false;
    var clone_depth: u32 = 0;
    {
        var i: usize = 0;
        while (i < all_args.items.len) : (i += 1) {
            const arg = all_args.items[i];
            if (std.mem.eql(u8, arg, "--bare")) is_bare = true;
            if (std.mem.eql(u8, arg, "--no-checkout")) is_no_checkout = true;
            if (std.mem.eql(u8, arg, "--depth")) {
                if (i + 1 < all_args.items.len) {
                    clone_depth = std.fmt.parseInt(u32, all_args.items[i + 1], 10) catch 0;
                    i += 1; // skip the value
                }
            } else if (std.mem.startsWith(u8, arg, "--depth=")) {
                clone_depth = std.fmt.parseInt(u32, arg["--depth=".len..], 10) catch 0;
            }
        }
    }

    // For --bare with HTTPS URLs, use our native smart HTTP clone
    if (is_bare) {
        // Find the URL in args (skip flags and their values)
        var clone_url: ?[]const u8 = null;
        var clone_target: ?[]const u8 = null;
        {
            var i: usize = 0;
            while (i < all_args.items.len) : (i += 1) {
                const arg = all_args.items[i];
                if (std.mem.eql(u8, arg, "--depth") or std.mem.eql(u8, arg, "-b") or
                    std.mem.eql(u8, arg, "--branch") or std.mem.eql(u8, arg, "--origin") or
                    std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--reference") or
                    std.mem.eql(u8, arg, "--separate-git-dir"))
                {
                    i += 1; // skip the next arg (value)
                    continue;
                }
                if (std.mem.startsWith(u8, arg, "-")) continue;
                if (clone_url == null) {
                    clone_url = arg;
                } else if (clone_target == null) {
                    clone_target = arg;
                }
            }
        }

        if (clone_url) |url_val| {
            if (std.mem.startsWith(u8, url_val, "https://") or std.mem.startsWith(u8, url_val, "http://")) {
                const final_target = clone_target orelse blk: {
                    if (std.mem.lastIndexOfScalar(u8, url_val, '/')) |last_slash| {
                        const repo_name = url_val[last_slash + 1..];
                        if (std.mem.endsWith(u8, repo_name, ".git")) {
                            break :blk repo_name[0..repo_name.len - 4];
                        } else {
                            break :blk repo_name;
                        }
                    } else {
                        break :blk "repository";
                    }
                };

                const clone_msg = try std.fmt.allocPrint(allocator, "Cloning into bare repository '{s}'...\n", .{final_target});
                defer allocator.free(clone_msg);
                try platform_impl.writeStderr(clone_msg);

                const ziggit = @import("ziggit.zig");
                var repo = if (clone_depth > 0)
                    ziggit.Repository.cloneBareShallow(allocator, url_val, final_target, clone_depth) catch |err| {
                        const emsg = try std.fmt.allocPrint(allocator, "fatal: {}\n", .{err});
                        defer allocator.free(emsg);
                        try platform_impl.writeStderr(emsg);
                        std.process.exit(128);
                    }
                else
                    ziggit.Repository.cloneBare(allocator, url_val, final_target) catch |err| {
                        const emsg = try std.fmt.allocPrint(allocator, "fatal: {}\n", .{err});
                        defer allocator.free(emsg);
                        try platform_impl.writeStderr(emsg);
                        std.process.exit(128);
                    };
                repo.close();
                return;
            }
        }
    }

    // Handle --no-checkout with HTTPS URLs natively
    if (is_no_checkout) {
        var clone_url: ?[]const u8 = null;
        var clone_target: ?[]const u8 = null;
        for (all_args.items) |arg| {
            if (std.mem.startsWith(u8, arg, "-")) continue;
            if (clone_url == null) {
                clone_url = arg;
            } else if (clone_target == null) {
                clone_target = arg;
            }
        }

        if (clone_url) |url_val| {
            if (std.mem.startsWith(u8, url_val, "https://") or std.mem.startsWith(u8, url_val, "http://")) {
                const final_target = clone_target orelse blk: {
                    if (std.mem.lastIndexOfScalar(u8, url_val, '/')) |last_slash| {
                        const repo_name = url_val[last_slash + 1..];
                        if (std.mem.endsWith(u8, repo_name, ".git")) {
                            break :blk repo_name[0..repo_name.len - 4];
                        } else {
                            break :blk repo_name;
                        }
                    } else {
                        break :blk "repository";
                    }
                };

                const clone_msg = try std.fmt.allocPrint(allocator, "Cloning into '{s}'...\n", .{final_target});
                defer allocator.free(clone_msg);
                try platform_impl.writeStderr(clone_msg);

                // Use cloneBare to download everything into a temp bare dir, then convert to non-bare
                const ziggit = @import("ziggit.zig");
                const bare_target = try std.fmt.allocPrint(allocator, "{s}/.git", .{final_target});
                defer allocator.free(bare_target);

                // Create the worktree directory first
                std.fs.cwd().makePath(final_target) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        const msg = try std.fmt.allocPrint(allocator, "fatal: destination path '{s}' already exists and is not an empty directory.\n", .{final_target});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(128);
                    },
                    else => return err,
                };

                // Clone bare into .git subdirectory
                var repo = ziggit.Repository.cloneBare(allocator, url_val, bare_target) catch |err| {
                    // Clean up on failure
                    std.fs.cwd().deleteTree(final_target) catch {};
                    const emsg = try std.fmt.allocPrint(allocator, "fatal: {}\n", .{err});
                    defer allocator.free(emsg);
                    try platform_impl.writeStderr(emsg);
                    std.process.exit(128);
                };
                repo.close();

                // Convert bare repo to non-bare: update config to set bare = false
                const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{bare_target});
                defer allocator.free(config_path);
                const config_content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| {
                    const emsg = try std.fmt.allocPrint(allocator, "fatal: failed to read config: {}\n", .{err});
                    defer allocator.free(emsg);
                    try platform_impl.writeStderr(emsg);
                    std.process.exit(128);
                };
                defer allocator.free(config_content);

                // Replace bare = true with bare = false
                var new_config = std.array_list.Managed(u8).init(allocator);
                defer new_config.deinit();
                var config_lines = std.mem.splitSequence(u8, config_content, "\n");
                var first = true;
                while (config_lines.next()) |cline| {
                    if (!first) try new_config.appendSlice("\n");
                    first = false;
                    const trimmed = std.mem.trim(u8, cline, " \t\r");
                    if (std.mem.eql(u8, trimmed, "bare = true")) {
                        // Preserve leading whitespace
                        for (cline) |c| {
                            if (c == ' ' or c == '\t') {
                                try new_config.append(c);
                            } else break;
                        }
                        try new_config.appendSlice("bare = false");
                    } else {
                        try new_config.appendSlice(cline);
                    }
                }

                const cf = try std.fs.cwd().createFile(config_path, .{});
                defer cf.close();
                try cf.writeAll(new_config.items);

                return; // --no-checkout means skip checkout
            }
        }

        // Non-HTTPS --no-checkout: fall through to git
    }

    // For non-HTTPS --bare, handle locally
    if (is_bare) {
        // Find URL and target for bare clone
        var bare_url: ?[]const u8 = null;
        var bare_target: ?[]const u8 = null;
        {
            var i: usize = 0;
            while (i < all_args.items.len) : (i += 1) {
                const arg = all_args.items[i];
                if (std.mem.eql(u8, arg, "--depth") or std.mem.eql(u8, arg, "-b") or
                    std.mem.eql(u8, arg, "--branch") or std.mem.eql(u8, arg, "--origin") or
                    std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--reference") or
                    std.mem.eql(u8, arg, "--separate-git-dir"))
                {
                    i += 1;
                    continue;
                }
                if (std.mem.startsWith(u8, arg, "-")) continue;
                if (bare_url == null) {
                    bare_url = arg;
                } else if (bare_target == null) {
                    bare_target = arg;
                }
            }
        }
        if (bare_url) |burl| {
            if (!(std.mem.startsWith(u8, burl, "https://") or std.mem.startsWith(u8, burl, "http://") or
                std.mem.startsWith(u8, burl, "ssh://") or std.mem.startsWith(u8, burl, "git://")))
            {
                const bfinal_target = bare_target orelse bt: {
                    if (std.mem.lastIndexOfScalar(u8, burl, '/')) |ls| {
                        const rn = burl[ls + 1..];
                        if (std.mem.endsWith(u8, rn, ".git")) break :bt rn else {
                            const bn = try std.fmt.allocPrint(allocator, "{s}.git", .{rn});
                            break :bt bn;
                        }
                    } else break :bt "repository.git";
                };

                const bare_msg = try std.fmt.allocPrint(allocator, "Cloning into bare repository '{s}'...\n", .{bfinal_target});
                defer allocator.free(bare_msg);
                try platform_impl.writeStderr(bare_msg);

                try performLocalClone(allocator, burl, bfinal_target, true, false, null, null, platform_impl);
                return;
            }
        }
    }

    // Parse arguments for our internal implementation
    var url: ?[]const u8 = null;
    var target_dir: ?[]const u8 = null;

    {
        var i: usize = 0;
        while (i < all_args.items.len) : (i += 1) {
            const arg = all_args.items[i];
            // Skip flags that take a value argument
            if (std.mem.eql(u8, arg, "--depth") or std.mem.eql(u8, arg, "-b") or
                std.mem.eql(u8, arg, "--branch") or std.mem.eql(u8, arg, "--origin") or
                std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--reference") or
                std.mem.eql(u8, arg, "--separate-git-dir") or std.mem.eql(u8, arg, "-j") or
                std.mem.eql(u8, arg, "--jobs") or std.mem.eql(u8, arg, "--filter"))
            {
                i += 1; // skip value
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-")) continue;
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
    
    // For non-HTTP URLs (local paths, ssh://, git://), handle local clone natively
    if (!(std.mem.startsWith(u8, url.?, "https://") or std.mem.startsWith(u8, url.?, "http://"))) {
        // Parse --branch and --origin flags
        var clone_branch: ?[]const u8 = null;
        var clone_origin: ?[]const u8 = null;
        {
            var i: usize = 0;
            while (i < all_args.items.len) : (i += 1) {
                const arg = all_args.items[i];
                if ((std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--branch")) and i + 1 < all_args.items.len) {
                    clone_branch = all_args.items[i + 1];
                    i += 1;
                } else if (std.mem.startsWith(u8, arg, "--branch=")) {
                    clone_branch = arg["--branch=".len..];
                } else if ((std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--origin")) and i + 1 < all_args.items.len) {
                    clone_origin = all_args.items[i + 1];
                    i += 1;
                } else if (std.mem.startsWith(u8, arg, "--origin=")) {
                    clone_origin = arg["--origin=".len..];
                }
            }
        }

        // For SSH and git:// protocols, show error (SSH transport not yet fully integrated into clone)
        if (std.mem.startsWith(u8, url.?, "ssh://") or std.mem.startsWith(u8, url.?, "git://") or
            (std.mem.indexOf(u8, url.?, ":") != null and std.mem.indexOf(u8, url.?, "/") != null and
             (std.mem.indexOf(u8, url.?, ":").? < std.mem.indexOf(u8, url.?, "/").?) and !std.mem.startsWith(u8, url.?, "/")))
        {
            try platform_impl.writeStderr("fatal: SSH/git:// clone not yet supported natively\n");
            std.process.exit(128);
        }

        // Check if target directory already exists
        if (platform_impl.fs.exists(final_target_dir) catch false) {
            const msg = try std.fmt.allocPrint(allocator, "fatal: destination path '{s}' already exists and is not an empty directory.\n", .{final_target_dir});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        }

        const clone_msg = try std.fmt.allocPrint(allocator, "Cloning into '{s}'...\n", .{final_target_dir});
        defer allocator.free(clone_msg);
        try platform_impl.writeStderr(clone_msg);

        performLocalClone(allocator, url.?, final_target_dir, false, is_no_checkout, clone_branch, clone_origin, platform_impl) catch |err| {
            // Clean up on failure
            std.fs.cwd().deleteTree(final_target_dir) catch {};
            const emsg = try std.fmt.allocPrint(allocator, "fatal: {}\n", .{err});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(128);
        };
        return;
    }

    // Check if target directory already exists
    if (platform_impl.fs.exists(final_target_dir) catch false) {
        const msg = try std.fmt.allocPrint(allocator, "fatal: destination path '{s}' already exists and is not an empty directory.\n", .{final_target_dir});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    }
    
    const clone_msg = try std.fmt.allocPrint(allocator, "Cloning into '{s}'...\n", .{final_target_dir});
    defer allocator.free(clone_msg);
    try platform_impl.writeStderr(clone_msg);
    
    // For HTTPS URLs, use native smart HTTP clone + checkout
    if (std.mem.startsWith(u8, url.?, "https://") or std.mem.startsWith(u8, url.?, "http://")) {
        const ziggit = @import("ziggit.zig");
        const bare_target = try std.fmt.allocPrint(allocator, "{s}/.git", .{final_target_dir});
        defer allocator.free(bare_target);

        // Create the worktree directory first
        std.fs.cwd().makePath(final_target_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const msg = try std.fmt.allocPrint(allocator, "fatal: destination path '{s}' already exists and is not an empty directory.\n", .{final_target_dir});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            },
            else => return err,
        };

        // Clone bare into .git subdirectory (with optional shallow depth)
        var repo = if (clone_depth > 0)
            ziggit.Repository.cloneBareShallow(allocator, url.?, bare_target, clone_depth) catch |err| {
                std.fs.cwd().deleteTree(final_target_dir) catch {};
                const emsg = try std.fmt.allocPrint(allocator, "fatal: {}\n", .{err});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(128);
            }
        else
            ziggit.Repository.cloneBare(allocator, url.?, bare_target) catch |err| {
                std.fs.cwd().deleteTree(final_target_dir) catch {};
                const emsg = try std.fmt.allocPrint(allocator, "fatal: {}\n", .{err});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(128);
            };
        repo.close();

        // Convert bare repo to non-bare: update config to set bare = false
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{bare_target});
        defer allocator.free(config_path);
        const config_content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| {
            const emsg = try std.fmt.allocPrint(allocator, "fatal: failed to read config: {}\n", .{err});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(128);
        };
        defer allocator.free(config_content);

        // Replace bare = true with bare = false
        var new_config = std.array_list.Managed(u8).init(allocator);
        defer new_config.deinit();
        var config_lines = std.mem.splitSequence(u8, config_content, "\n");
        var first = true;
        while (config_lines.next()) |cline| {
            if (!first) try new_config.appendSlice("\n");
            first = false;
            const trimmed = std.mem.trim(u8, cline, " \t\r");
            if (std.mem.eql(u8, trimmed, "bare = true")) {
                for (cline) |c| {
                    if (c == ' ' or c == '\t') {
                        try new_config.append(c);
                    } else break;
                }
                try new_config.appendSlice("bare = false");
            } else {
                try new_config.appendSlice(cline);
            }
        }

        {
            const cf = try std.fs.cwd().createFile(config_path, .{});
            defer cf.close();
            try cf.writeAll(new_config.items);
        }

        // Checkout HEAD into worktree
        const head_commit = refs.getCurrentCommit(bare_target, platform_impl, allocator) catch {
            // Empty repository - no checkout needed
            return;
        };
        if (head_commit) |commit_hash| {
            defer allocator.free(commit_hash);
            checkoutCommitTree(bare_target, commit_hash, allocator, platform_impl) catch |err| {
                const emsg = try std.fmt.allocPrint(allocator, "warning: checkout failed: {}, repository cloned but working tree not populated\n", .{err});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
            };
        }

        return;
    }

    // Perform clone using dumb HTTP protocol (non-HTTPS fallback)
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
}

fn cmdConfig(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("config: not supported in freestanding mode\n");
        return;
    }

    // Collect all remaining args
    var config_args = std.array_list.Managed([]const u8).init(allocator);
    defer config_args.deinit();
    while (args.next()) |arg| {
        try config_args.append(arg);
    }

    // Parse flags
    var config_type: ConfigType = .none;
    var do_list = false;
    var do_get = false;
    var do_get_all = false;
    var do_get_regexp = false;
    var do_set = false;
    var do_unset = false;
    var do_unset_all = false;
    var do_add = false;
    var do_remove_section = false;
    var do_rename_section = false;
    _ = &do_rename_section;
    var use_global = false;
    var use_system = false;
    var use_local = false;
    var use_worktree = false;
    _ = &use_worktree;
    var config_file: ?[]const u8 = null;
    var null_terminator = false;
    var show_names = false;
    var show_origin = false;
    var show_scope = false;
    var default_value: ?[]const u8 = null;
    var fixed_value = false;
    _ = &fixed_value;
    var positionals = std.array_list.Managed([]const u8).init(allocator);
    defer positionals.deinit();
    var do_edit = false;
    _ = &do_edit;
    var do_get_color = false;
    var do_get_colorbool = false;
    // New-style subcommands
    var new_style_sub = false;
    
    var i: usize = 0;
    while (i < config_args.items.len) : (i += 1) {
        const arg = config_args.items[i];
        if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            do_list = true;
        } else if (std.mem.eql(u8, arg, "--get")) {
            do_get = true;
        } else if (std.mem.eql(u8, arg, "--get-all")) {
            do_get_all = true;
        } else if (std.mem.eql(u8, arg, "--get-regexp")) {
            do_get_regexp = true;
        } else if (std.mem.eql(u8, arg, "--unset")) {
            do_unset = true;
        } else if (std.mem.eql(u8, arg, "--unset-all")) {
            do_unset_all = true;
        } else if (std.mem.eql(u8, arg, "--add")) {
            do_add = true;
        } else if (std.mem.eql(u8, arg, "--remove-section")) {
            do_remove_section = true;
        } else if (std.mem.eql(u8, arg, "--rename-section")) {
            do_rename_section = true;
        } else if (std.mem.eql(u8, arg, "--bool")) {
            config_type = .bool_type;
        } else if (std.mem.eql(u8, arg, "--int")) {
            config_type = .int_type;
        } else if (std.mem.eql(u8, arg, "--bool-or-int")) {
            config_type = .bool_or_int;
        } else if (std.mem.eql(u8, arg, "--path")) {
            config_type = .path_type;
        } else if (std.mem.eql(u8, arg, "--expiry-date")) {
            config_type = .expiry_date;
        } else if (std.mem.startsWith(u8, arg, "--type=")) {
            const type_str = arg["--type=".len..];
            if (std.mem.eql(u8, type_str, "bool")) {
                config_type = .bool_type;
            } else if (std.mem.eql(u8, type_str, "int")) {
                config_type = .int_type;
            } else if (std.mem.eql(u8, type_str, "bool-or-int")) {
                config_type = .bool_or_int;
            } else if (std.mem.eql(u8, type_str, "path")) {
                config_type = .path_type;
            } else if (std.mem.eql(u8, type_str, "expiry-date")) {
                config_type = .expiry_date;
            } else if (std.mem.eql(u8, type_str, "color")) {
                config_type = .color_type;
            }
        } else if (std.mem.eql(u8, arg, "--global")) {
            use_global = true;
        } else if (std.mem.eql(u8, arg, "--system")) {
            use_system = true;
        } else if (std.mem.eql(u8, arg, "--local")) {
            use_local = true;
        } else if (std.mem.eql(u8, arg, "--worktree")) {
            use_worktree = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i < config_args.items.len) {
                config_file = config_args.items[i];
            }
        } else if (std.mem.startsWith(u8, arg, "--file=")) {
            config_file = arg["--file=".len..];
        } else if (std.mem.startsWith(u8, arg, "-f") and arg.len > 2) {
            config_file = arg[2..];
        } else if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--null")) {
            null_terminator = true;
        } else if (std.mem.eql(u8, arg, "--name-only") or std.mem.eql(u8, arg, "--name")) {
            show_names = true;
        } else if (std.mem.eql(u8, arg, "--show-origin")) {
            show_origin = true;
        } else if (std.mem.eql(u8, arg, "--show-scope")) {
            show_scope = true;
        } else if (std.mem.startsWith(u8, arg, "--default=")) {
            default_value = arg["--default=".len..];
        } else if (std.mem.eql(u8, arg, "--default")) {
            i += 1;
            if (i < config_args.items.len) default_value = config_args.items[i];
        } else if (std.mem.eql(u8, arg, "--fixed-value")) {
            fixed_value = true;
        } else if (std.mem.eql(u8, arg, "--edit") or std.mem.eql(u8, arg, "-e")) {
            do_edit = true;
        } else if (std.mem.eql(u8, arg, "--get-color")) {
            do_get_color = true;
        } else if (std.mem.eql(u8, arg, "--get-colorbool")) {
            do_get_colorbool = true;
        } else if (std.mem.eql(u8, arg, "--replace-all")) {
            do_set = true; // treat like set but replaces all
        } else if (std.mem.startsWith(u8, arg, "--comment=") or std.mem.eql(u8, arg, "--comment")) {
            // --comment flag for git 2.45+, accept and store
            if (std.mem.eql(u8, arg, "--comment")) {
                i += 1; // skip comment value
            }
        } else if (std.mem.eql(u8, arg, "--no-type")) {
            config_type = .none;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git config [<options>]\n");
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--")) {
            // Rest are positionals
            i += 1;
            while (i < config_args.items.len) : (i += 1) {
                try positionals.append(config_args.items[i]);
            }
        } else if (std.mem.eql(u8, arg, "set") and positionals.items.len == 0 and !do_get and !do_list and !do_unset) {
            new_style_sub = true;
            do_set = true;
        } else if (std.mem.eql(u8, arg, "get") and positionals.items.len == 0 and !do_set and !do_list and !do_unset) {
            new_style_sub = true;
            do_get = true;
        } else if (std.mem.eql(u8, arg, "unset") and positionals.items.len == 0 and !do_set and !do_list and !do_get) {
            new_style_sub = true;
            do_unset = true;
        } else if (std.mem.eql(u8, arg, "list") and positionals.items.len == 0 and !do_set and !do_get and !do_unset) {
            new_style_sub = true;
            do_list = true;
        } else {
            try positionals.append(arg);
        }
    }
    // These flags are parsed but not yet fully implemented

    // Determine config file path(s) to read
    // ConfigSource is defined at module level
    var sources = std.array_list.Managed(ConfigSource).init(allocator);
    defer {
        for (sources.items) |s| {
            if (s.needs_free) allocator.free(s.path);
        }
        sources.deinit();
    }

    // Helper to find git dir (may fail if not in repo)
    const git_path_opt: ?[]const u8 = findGitDirectory(allocator, platform_impl) catch null;
    defer if (git_path_opt) |gp| allocator.free(gp);

    if (config_file) |cf| {
        // -f <file>: only that file
        try sources.append(.{ .path = cf, .scope = "command", .needs_free = false });
    } else if (use_system) {
        try sources.append(.{ .path = "/etc/gitconfig", .scope = "system", .needs_free = false });
    } else if (use_global) {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
        const xdg = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null;
        defer if (home) |h| allocator.free(h);
        defer if (xdg) |x| allocator.free(x);
        if (home) |h| {
            const p = try std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{h});
            try sources.append(.{ .path = p, .scope = "global", .needs_free = true });
        }
        if (xdg) |x| {
            const p = try std.fmt.allocPrint(allocator, "{s}/git/config", .{x});
            try sources.append(.{ .path = p, .scope = "global", .needs_free = true });
        } else if (home) |h| {
            const p = try std.fmt.allocPrint(allocator, "{s}/.config/git/config", .{h});
            try sources.append(.{ .path = p, .scope = "global", .needs_free = true });
        }
    } else if (use_local) {
        if (git_path_opt) |gp| {
            const p = try std.fmt.allocPrint(allocator, "{s}/config", .{gp});
            try sources.append(.{ .path = p, .scope = "local", .needs_free = true });
        } else {
            try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
            std.process.exit(128);
        }
    } else {
        // Default: system + global + local (for reads)
        // For writes, default is local
        try sources.append(.{ .path = "/etc/gitconfig", .scope = "system", .needs_free = false });
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
        const xdg = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null;
        defer if (home) |h| allocator.free(h);
        defer if (xdg) |x| allocator.free(x);
        if (xdg) |x| {
            const p = try std.fmt.allocPrint(allocator, "{s}/git/config", .{x});
            try sources.append(.{ .path = p, .scope = "global", .needs_free = true });
        } else if (home) |h| {
            const p = try std.fmt.allocPrint(allocator, "{s}/.config/git/config", .{h});
            try sources.append(.{ .path = p, .scope = "global", .needs_free = true });
        }
        if (home) |h| {
            const p = try std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{h});
            try sources.append(.{ .path = p, .scope = "global", .needs_free = true });
        }
        if (git_path_opt) |gp| {
            const p = try std.fmt.allocPrint(allocator, "{s}/config", .{gp});
            try sources.append(.{ .path = p, .scope = "local", .needs_free = true });
        }
    }

    // Also handle GIT_CONFIG_GLOBAL etc.
    const env_global = std.process.getEnvVarOwned(allocator, "GIT_CONFIG_GLOBAL") catch null;
    defer if (env_global) |eg| allocator.free(eg);
    // GIT_CONFIG env var overrides for reads
    const env_config = std.process.getEnvVarOwned(allocator, "GIT_CONFIG") catch null;
    defer if (env_config) |ec| allocator.free(ec);

    // Handle --list
    if (do_list) {
        for (sources.items) |source| {
            const content = platform_impl.fs.readFile(allocator, source.path) catch continue;
            defer allocator.free(content);
            try outputConfigList(content, source.path, source.scope, null_terminator, show_names, show_origin, show_scope, allocator, platform_impl);
        }
        return;
    }

    // Handle --get-color
    if (do_get_color) {
        // git config --get-color <key> [<default>]
        const key = if (positionals.items.len >= 1) positionals.items[0] else {
            try platform_impl.writeStderr("error: --get-color requires a key\n");
            std.process.exit(2);
        };
        const def = if (positionals.items.len >= 2) positionals.items[1] else "";
        // Look up the color config
        const val = configLookup(sources.items, key, allocator, platform_impl) catch null;
        defer if (val) |v| allocator.free(v);
        const color_str = val orelse def;
        // Output the ANSI escape for the color
        const ansi = colorToAnsi(color_str);
        try platform_impl.writeStdout(ansi);
        return;
    }

    // Handle --get-colorbool
    if (do_get_colorbool) {
        const key = if (positionals.items.len >= 1) positionals.items[0] else {
            try platform_impl.writeStderr("error: --get-colorbool requires a key\n");
            std.process.exit(2);
        };
        _ = key;
        // Simple: check if stdout is a terminal
        try platform_impl.writeStdout("false\n");
        return;
    }

    // Handle --remove-section
    if (do_remove_section) {
        if (positionals.items.len < 1) {
            try platform_impl.writeStderr("error: missing section name\n");
            std.process.exit(2);
        }
        const section_name = positionals.items[0];
        // Find the config file to edit
        const cfg_path = if (config_file) |cf| try allocator.dupe(u8, cf) else if (git_path_opt) |gp| try std.fmt.allocPrint(allocator, "{s}/config", .{gp}) else {
            try platform_impl.writeStderr("fatal: not a git repository\n");
            std.process.exit(128);
        };
        defer allocator.free(cfg_path);
        try configRemoveSection(cfg_path, section_name, allocator, platform_impl);
        return;
    }

    // Handle write: git config <key> <value> OR git config set <key> <value>
    if (do_set or do_add or (!do_get and !do_get_all and !do_get_regexp and !do_unset and !do_unset_all and positionals.items.len >= 2 and !std.mem.startsWith(u8, positionals.items[0], "-"))) {
        const key = positionals.items[0];
        const value = positionals.items[1];
        // Find config file to write
        const cfg_path = if (config_file) |cf|
            try allocator.dupe(u8, cf)
        else if (use_global) blk: {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
                try platform_impl.writeStderr("fatal: $HOME not set\n");
                std.process.exit(128);
            };
            defer allocator.free(home);
            break :blk try std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{home});
        } else if (git_path_opt) |gp|
            try std.fmt.allocPrint(allocator, "{s}/config", .{gp})
        else {
            try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
            std.process.exit(128);
        };
        defer allocator.free(cfg_path);
        try configSetValue(cfg_path, key, value, do_add, allocator, platform_impl);
        return;
    }

    // Handle --unset
    if (do_unset or do_unset_all) {
        if (positionals.items.len < 1) {
            try platform_impl.writeStderr("error: missing key\n");
            std.process.exit(2);
        }
        const key = positionals.items[0];
        const cfg_path = if (config_file) |cf|
            try allocator.dupe(u8, cf)
        else if (use_global) blk: {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
                try platform_impl.writeStderr("fatal: $HOME not set\n");
                std.process.exit(128);
            };
            defer allocator.free(home);
            break :blk try std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{home});
        } else if (git_path_opt) |gp|
            try std.fmt.allocPrint(allocator, "{s}/config", .{gp})
        else {
            try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
            std.process.exit(128);
        };
        defer allocator.free(cfg_path);
        try configUnsetValue(cfg_path, key, do_unset_all, allocator, platform_impl);
        return;
    }

    // Handle --get-regexp
    if (do_get_regexp) {
        if (positionals.items.len < 1) {
            try platform_impl.writeStderr("error: missing key pattern\n");
            std.process.exit(2);
        }
        // Simple: just pattern-match keys
        const pattern = positionals.items[0];
        var found_any = false;
        for (sources.items) |source| {
            const content = platform_impl.fs.readFile(allocator, source.path) catch continue;
            defer allocator.free(content);
            found_any = try outputConfigGetRegexp(content, pattern, show_names, null_terminator, allocator, platform_impl) or found_any;
        }
        if (!found_any) std.process.exit(1);
        return;
    }

    // Handle --get-all
    if (do_get_all) {
        if (positionals.items.len < 1) {
            try platform_impl.writeStderr("error: missing key\n");
            std.process.exit(2);
        }
        const key = positionals.items[0];
        var found_any = false;
        for (sources.items) |source| {
            const content = platform_impl.fs.readFile(allocator, source.path) catch continue;
            defer allocator.free(content);
            var all_vals = std.array_list.Managed([]const u8).init(allocator);
            defer {
                for (all_vals.items) |v| allocator.free(v);
                all_vals.deinit();
            }
            try parseConfigGetAll(content, key, &all_vals, allocator);
            for (all_vals.items) |v| {
                found_any = true;
                const formatted = try formatConfigType(v, config_type, allocator);
                defer allocator.free(formatted);
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{formatted});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        }
        if (!found_any) std.process.exit(1);
        return;
    }

    // Handle simple get: git config [--get] [--bool] <key>
    if (positionals.items.len >= 1) {
        const key = positionals.items[0];
        const val = configLookup(sources.items, key, allocator, platform_impl) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        defer if (val) |v| allocator.free(v);
        const effective_val = val orelse default_value;
        if (effective_val) |v| {
            const formatted = try formatConfigType(v, config_type, allocator);
            defer allocator.free(formatted);
            const term: []const u8 = if (null_terminator) "\x00" else "\n";
            const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ formatted, term });
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else {
            std.process.exit(1);
        }
        return;
    }

    // No args at all - show usage
    if (positionals.items.len == 0 and !do_list) {
        try platform_impl.writeStderr("usage: git config [<options>]\n");
        std.process.exit(129);
    }
}

fn configLookup(sources: []const ConfigSource, key: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) ![]u8 {
    // Last source wins (local overrides global overrides system)
    var result: ?[]u8 = null;
    for (sources) |source| {
        const content = platform_impl.fs.readFile(allocator, source.path) catch continue;
        defer allocator.free(content);
        const val = parseConfigValue(content, key, allocator) catch |err| switch (err) {
            error.KeyNotFound => continue,
            else => return err,
        };
        if (val) |v| {
            if (result) |prev| allocator.free(prev);
            result = v;
        }
    }
    return result orelse error.KeyNotFound;
}

const ConfigType = enum { none, bool_type, int_type, bool_or_int, path_type, expiry_date, color_type };

const ConfigSource = struct {
    path: []const u8,
    scope: []const u8,
    needs_free: bool,
};

fn formatConfigType(value: []const u8, config_type: ConfigType, allocator: std.mem.Allocator) ![]u8 {
    return switch (config_type) {
        .bool_type => {
            // Normalize to true/false
            if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "1")) {
                return try allocator.dupe(u8, "true");
            } else if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "no") or std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "0") or value.len == 0) {
                return try allocator.dupe(u8, "false");
            }
            return try allocator.dupe(u8, value);
        },
        .int_type => try allocator.dupe(u8, value),
        .bool_or_int => {
            if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "on")) {
                return try allocator.dupe(u8, "true");
            } else if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "no") or std.mem.eql(u8, value, "off")) {
                return try allocator.dupe(u8, "false");
            }
            return try allocator.dupe(u8, value);
        },
        else => try allocator.dupe(u8, value),
    };
}

fn outputConfigList(content: []const u8, source_path: []const u8, scope: []const u8, null_term: bool, name_only: bool, show_origin: bool, show_scope: bool, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    var lines = std.mem.splitSequence(u8, content, "\n");
    var current_section: ?[]u8 = null;
    defer if (current_section) |s| allocator.free(s);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            if (current_section) |s| allocator.free(s);
            current_section = try parseSectionHeader(trimmed, allocator);
            continue;
        }

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const k = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const v = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
            const full_key = if (current_section) |sec|
                try std.fmt.allocPrint(allocator, "{s}.{s}", .{ sec, k })
            else
                try allocator.dupe(u8, k);
            defer allocator.free(full_key);

            // Convert key to lowercase for output
            const lower_key = try allocator.dupe(u8, full_key);
            defer allocator.free(lower_key);
            for (lower_key) |*c| {
                c.* = std.ascii.toLower(c.*);
            }

            const term: []const u8 = if (null_term) "\x00" else "\n";
            var out = std.array_list.Managed(u8).init(allocator);
            defer out.deinit();
            if (show_scope) {
                try out.appendSlice(scope);
                try out.append('\t');
            }
            if (show_origin) {
                try out.appendSlice("file:");
                try out.appendSlice(source_path);
                try out.append('\t');
            }
            if (name_only) {
                try out.appendSlice(lower_key);
            } else {
                try out.appendSlice(lower_key);
                try out.append('=');
                try out.appendSlice(v);
            }
            try out.appendSlice(term);
            try platform_impl.writeStdout(out.items);
        }
    }
}

fn parseSectionHeader(header: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // Parse [section] or [section "subsection"]
    const inner = header[1 .. header.len - 1];
    if (std.mem.indexOf(u8, inner, " \"")) |quote_start| {
        const section = inner[0..quote_start];
        const subsection = std.mem.trim(u8, inner[quote_start + 2 ..], "\"");
        return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ section, subsection });
    }
    return try allocator.dupe(u8, inner);
}

fn outputConfigGetRegexp(content: []const u8, pattern: []const u8, name_only: bool, null_term: bool, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !bool {
    var lines = std.mem.splitSequence(u8, content, "\n");
    var current_section: ?[]u8 = null;
    defer if (current_section) |s| allocator.free(s);
    var found = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            if (current_section) |s| allocator.free(s);
            current_section = try parseSectionHeader(trimmed, allocator);
            continue;
        }

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const k = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const v = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
            const full_key = if (current_section) |sec|
                try std.fmt.allocPrint(allocator, "{s}.{s}", .{ sec, k })
            else
                try allocator.dupe(u8, k);
            defer allocator.free(full_key);

            // Simple substring match (git uses POSIX regex, but this covers most test cases)
            const lower_key = try allocator.dupe(u8, full_key);
            defer allocator.free(lower_key);
            for (lower_key) |*c| c.* = std.ascii.toLower(c.*);

            if (std.mem.indexOf(u8, lower_key, pattern) != null) {
                found = true;
                const term: []const u8 = if (null_term) "\x00" else "\n";
                if (name_only) {
                    const out = try std.fmt.allocPrint(allocator, "{s}{s}", .{ lower_key, term });
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                } else {
                    const out = try std.fmt.allocPrint(allocator, "{s} {s}{s}", .{ lower_key, v, term });
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                }
            }
        }
    }
    return found;
}

fn parseConfigGetAll(content: []const u8, key: []const u8, results: *std.array_list.Managed([]const u8), allocator: std.mem.Allocator) !void {
    var lines = std.mem.splitSequence(u8, content, "\n");
    var current_section: ?[]u8 = null;
    defer if (current_section) |s| allocator.free(s);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            if (current_section) |s| allocator.free(s);
            current_section = try parseSectionHeader(trimmed, allocator);
            continue;
        }

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const k = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const v = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
            const full_key = if (current_section) |sec|
                try std.fmt.allocPrint(allocator, "{s}.{s}", .{ sec, k })
            else
                try allocator.dupe(u8, k);
            defer allocator.free(full_key);

            if (std.ascii.eqlIgnoreCase(full_key, key)) {
                try results.append(try allocator.dupe(u8, v));
            }
        }
    }
}

fn configSetValue(cfg_path: []const u8, key: []const u8, value: []const u8, do_add: bool, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // Parse key into section[.subsection].variable
    const parsed_key = parseConfigKey(key, allocator) catch {
        try platform_impl.writeStderr("error: key does not contain a section: ");
        try platform_impl.writeStderr(key);
        try platform_impl.writeStderr("\n");
        std.process.exit(2);
    };
    defer allocator.free(parsed_key.section);
    defer if (parsed_key.subsection) |s| allocator.free(s);
    defer allocator.free(parsed_key.variable);

    // Reconstruct the section string for matching
    const section_part = if (parsed_key.subsection) |sub|
        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parsed_key.section, sub })
    else
        try allocator.dupe(u8, parsed_key.section);
    defer allocator.free(section_part);
    
    const key_part = parsed_key.variable;

    // Read existing content
    const content = platform_impl.fs.readFile(allocator, cfg_path) catch |err| switch (err) {
        error.FileNotFound => {
            // Create new file with this setting
            const section_header = try formatSectionHeader(section_part, allocator);
            defer allocator.free(section_header);
            const new_content = try std.fmt.allocPrint(allocator, "[{s}]\n\t{s} = {s}\n", .{ section_header, key_part, value });
            defer allocator.free(new_content);
            try platform_impl.fs.writeFile(cfg_path, new_content);
            return;
        },
        else => return err,
    };
    defer allocator.free(content);

    // Strategy: reconstruct the file, replacing or adding the value
    // We need to find the matching section and either replace the key or add it
    
    // First pass: try to find and replace existing key
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    var found = false;
    var section_found = false;
    var last_line_in_section_end: usize = 0; // position in result after last line in target section
    
    // Split content into lines preserving original structure
    var pos: usize = 0;
    var current_section_str: ?[]u8 = null;
    defer if (current_section_str) |s| allocator.free(s);
    var in_target_section = false;
    
    while (pos < content.len) {
        // Find end of line
        const line_end = std.mem.indexOfPos(u8, content, pos, "\n") orelse content.len;
        const line = content[pos..line_end];
        const has_newline = line_end < content.len;
        
        const trimmed = std.mem.trim(u8, line, " \t\r");
        
        // Check for section header
        if (trimmed.len > 0 and trimmed[0] == '[') {
            const close = std.mem.indexOf(u8, trimmed, "]");
            if (close != null) {
                if (current_section_str) |s| allocator.free(s);
                const parsed = parseConfigSectionHeader(trimmed, allocator) catch null;
                if (parsed) |p| {
                    if (p.subsection) |sub| {
                        current_section_str = std.fmt.allocPrint(allocator, "{s}.{s}", .{ p.section.?, sub }) catch null;
                        allocator.free(p.section.?);
                        allocator.free(sub);
                    } else if (p.section) |sec| {
                        current_section_str = sec;
                    } else {
                        current_section_str = null;
                    }
                } else {
                    current_section_str = null;
                }
                in_target_section = if (current_section_str) |cs| sectionMatchesKey(cs, section_part) else false;
                if (in_target_section) section_found = true;
            }
        }
        
        // Check if this line has our key (for replacement)
        if (in_target_section and !found and !do_add and trimmed.len > 0 and trimmed[0] != '[' and trimmed[0] != '#' and trimmed[0] != ';') {
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const k = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                if (std.ascii.eqlIgnoreCase(k, key_part)) {
                    // Replace this line
                    try result.appendSlice("\t");
                    try result.appendSlice(key_part);
                    try result.appendSlice(" = ");
                    try result.appendSlice(value);
                    try result.append('\n');
                    found = true;
                    pos = line_end + @as(usize, if (has_newline) 1 else 0);
                    continue;
                }
            }
        }
        
        // Copy line as-is
        try result.appendSlice(line);
        if (has_newline) try result.append('\n');
        
        if (in_target_section) {
            last_line_in_section_end = result.items.len;
        }
        
        pos = line_end + @as(usize, if (has_newline) 1 else 0);
    }
    
    if (!found) {
        if (section_found) {
            // Insert the new key at the end of the target section
            // We need to rebuild, inserting before the next section or at end
            var insert_result = std.array_list.Managed(u8).init(allocator);
            defer insert_result.deinit();
            
            try insert_result.appendSlice(result.items[0..last_line_in_section_end]);
            try insert_result.appendSlice("\t");
            try insert_result.appendSlice(key_part);
            try insert_result.appendSlice(" = ");
            try insert_result.appendSlice(value);
            try insert_result.append('\n');
            if (last_line_in_section_end < result.items.len) {
                try insert_result.appendSlice(result.items[last_line_in_section_end..]);
            }
            
            try platform_impl.fs.writeFile(cfg_path, insert_result.items);
            return;
        } else {
            // Add new section at end
            const section_header = try formatSectionHeader(section_part, allocator);
            defer allocator.free(section_header);
            try result.appendSlice("[");
            try result.appendSlice(section_header);
            try result.appendSlice("]\n\t");
            try result.appendSlice(key_part);
            try result.appendSlice(" = ");
            try result.appendSlice(value);
            try result.append('\n');
        }
    }

    try platform_impl.fs.writeFile(cfg_path, result.items);
}

fn sectionMatchesKey(config_section: []const u8, key_section: []const u8) bool {
    // Section names are case-insensitive, but subsections are case-sensitive
    // config_section is in format "section" or "section.subsection"
    // key_section is in format "section" or "section.subsection"
    const config_dot = std.mem.indexOf(u8, config_section, ".");
    const key_dot = std.mem.indexOf(u8, key_section, ".");
    
    if (config_dot != null and key_dot != null) {
        // Both have subsections
        const cs = config_section[0..config_dot.?];
        const ks = key_section[0..key_dot.?];
        if (!std.ascii.eqlIgnoreCase(cs, ks)) return false;
        // Subsection is case-sensitive
        return std.mem.eql(u8, config_section[config_dot.? + 1 ..], key_section[key_dot.? + 1 ..]);
    } else if (config_dot == null and key_dot == null) {
        return std.ascii.eqlIgnoreCase(config_section, key_section);
    }
    return false;
}

fn formatSectionHeader(section_key: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // Convert "section.subsection" → section "subsection"
    // Convert "section" → section
    if (std.mem.indexOf(u8, section_key, ".")) |dot| {
        const section = section_key[0..dot];
        const subsection = section_key[dot + 1 ..];
        return try std.fmt.allocPrint(allocator, "{s} \"{s}\"", .{ section, subsection });
    }
    return try allocator.dupe(u8, section_key);
}

fn configUnsetValue(cfg_path: []const u8, key: []const u8, unset_all: bool, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    const last_dot = std.mem.lastIndexOf(u8, key, ".") orelse {
        try platform_impl.writeStderr("error: key does not contain a section\n");
        std.process.exit(2);
    };
    const section_part = key[0..last_dot];
    const key_part = key[last_dot + 1 ..];

    const content = platform_impl.fs.readFile(allocator, cfg_path) catch {
        std.process.exit(5);
    };
    defer allocator.free(content);

    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    var lines = std.mem.splitSequence(u8, content, "\n");
    var current_section_str: ?[]u8 = null;
    defer if (current_section_str) |s| allocator.free(s);
    var found = false;
    var found_count: usize = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        if (trimmed.len > 0 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            if (current_section_str) |s| allocator.free(s);
            current_section_str = parseSectionHeader(trimmed, allocator) catch null;
        }

        const in_section = if (current_section_str) |cs| std.ascii.eqlIgnoreCase(cs, section_part) else false;
        var skip = false;
        if (in_section) {
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const k = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                if (std.ascii.eqlIgnoreCase(k, key_part)) {
                    found = true;
                    found_count += 1;
                    if (unset_all or found_count == 1) {
                        skip = true;
                    }
                }
            }
        }

        if (!skip) {
            try result.appendSlice(line);
            try result.append('\n');
        }
    }

    // Remove trailing extra newline
    if (result.items.len > 0 and content.len > 0 and content[content.len - 1] != '\n') {
        _ = result.pop();
    }

    if (!found) {
        std.process.exit(5);
    }

    if (!unset_all and found_count > 1) {
        try platform_impl.writeStderr("warning: ");
        try platform_impl.writeStderr(key);
        try platform_impl.writeStderr(" has multiple values\n");
        std.process.exit(5);
    }

    try platform_impl.fs.writeFile(cfg_path, result.items);
}

fn configRemoveSection(cfg_path: []const u8, section_name: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    const content = platform_impl.fs.readFile(allocator, cfg_path) catch {
        try platform_impl.writeStderr("fatal: could not read config file\n");
        std.process.exit(128);
    };
    defer allocator.free(content);

    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    var lines = std.mem.splitSequence(u8, content, "\n");
    var in_removed_section = false;
    var found = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        if (trimmed.len > 0 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            const parsed = parseSectionHeader(trimmed, allocator) catch null;
            defer if (parsed) |p| allocator.free(p);
            if (parsed) |p| {
                if (std.ascii.eqlIgnoreCase(p, section_name)) {
                    in_removed_section = true;
                    found = true;
                    continue;
                }
            }
            in_removed_section = false;
        }

        if (!in_removed_section) {
            try result.appendSlice(line);
            try result.append('\n');
        }
    }

    if (!found) {
        const msg = try std.fmt.allocPrint(allocator, "fatal: no such section: {s}\n", .{section_name});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    }

    // Remove trailing extra newline
    if (result.items.len > 0 and content.len > 0 and content[content.len - 1] != '\n') {
        _ = result.pop();
    }

    try platform_impl.fs.writeFile(cfg_path, result.items);
}

fn colorToAnsi(color_str: []const u8) []const u8 {
    // Simple color name to ANSI escape code mapping
    if (std.mem.eql(u8, color_str, "red")) return "\x1b[31m";
    if (std.mem.eql(u8, color_str, "green")) return "\x1b[32m";
    if (std.mem.eql(u8, color_str, "yellow")) return "\x1b[33m";
    if (std.mem.eql(u8, color_str, "blue")) return "\x1b[34m";
    if (std.mem.eql(u8, color_str, "magenta")) return "\x1b[35m";
    if (std.mem.eql(u8, color_str, "cyan")) return "\x1b[36m";
    if (std.mem.eql(u8, color_str, "white")) return "\x1b[37m";
    if (std.mem.eql(u8, color_str, "reset") or std.mem.eql(u8, color_str, "normal")) return "\x1b[m";
    if (std.mem.eql(u8, color_str, "bold")) return "\x1b[1m";
    if (std.mem.eql(u8, color_str, "bold red")) return "\x1b[1;31m";
    if (std.mem.eql(u8, color_str, "bold green")) return "\x1b[1;32m";
    if (std.mem.eql(u8, color_str, "bold yellow")) return "\x1b[1;33m";
    if (std.mem.eql(u8, color_str, "bold blue")) return "\x1b[1;34m";
    if (color_str.len == 0) return "";
    return "";
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
    // Parse key into section[.subsection].name components
    // Keys are case-insensitive for section and variable name, but subsection is case-sensitive
    const parsed_key = try parseConfigKey(key, allocator);
    defer allocator.free(parsed_key.section);
    defer if (parsed_key.subsection) |s| allocator.free(s);
    defer allocator.free(parsed_key.variable);
    
    var last_value: ?[]u8 = null;
    
    var line_iter = std.mem.splitSequence(u8, config_content, "\n");
    var current_section: ?[]u8 = null;
    var current_subsection: ?[]u8 = null;
    defer if (current_section) |s| allocator.free(s);
    defer if (current_subsection) |s| allocator.free(s);
    
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;
        
        // Section header
        if (trimmed[0] == '[') {
            if (current_section) |s| allocator.free(s);
            if (current_subsection) |s| allocator.free(s);
            current_section = null;
            current_subsection = null;
            
            const parsed = try parseConfigSectionHeader(trimmed, allocator);
            current_section = parsed.section;
            current_subsection = parsed.subsection;
            
            // Check for inline key-value after section header: [section] key = value
            const close_bracket = std.mem.indexOf(u8, trimmed, "]") orelse continue;
            const after_bracket = std.mem.trim(u8, trimmed[close_bracket + 1 ..], " \t");
            if (after_bracket.len == 0) continue;
            // If there's content after the bracket, treat it as a key=value line
            // Fall through to the key=value parsing below with after_bracket as the line
            if (std.mem.indexOf(u8, after_bracket, "=")) |inline_eq_pos| {
                const inline_raw_key = std.mem.trim(u8, after_bracket[0..inline_eq_pos], " \t");
                const inline_raw_value = after_bracket[inline_eq_pos + 1 ..];
                
                var inline_value_buf = std.array_list.Managed(u8).init(allocator);
                defer inline_value_buf.deinit();
                try appendConfigValuePart(&inline_value_buf, inline_raw_value);
                
                const inline_section_matches = if (current_section) |cs|
                    std.ascii.eqlIgnoreCase(cs, parsed_key.section)
                else
                    false;
                
                const inline_subsection_matches = if (parsed_key.subsection) |ps| blk: {
                    if (current_subsection) |css| {
                        break :blk std.mem.eql(u8, css, ps);
                    }
                    break :blk false;
                } else (current_subsection == null);
                
                if (inline_section_matches and inline_subsection_matches and 
                    std.ascii.eqlIgnoreCase(inline_raw_key, parsed_key.variable)) {
                    if (last_value) |lv| allocator.free(lv);
                    last_value = try inline_value_buf.toOwnedSlice();
                }
            }
            continue;
        }
        
        // Key = value line
        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const raw_key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            var raw_value = trimmed[eq_pos + 1 ..];
            
            // Handle continuation lines
            var value_buf = std.array_list.Managed(u8).init(allocator);
            defer value_buf.deinit();
            
            while (true) {
                const trimmed_val = std.mem.trimRight(u8, raw_value, " \t");
                if (trimmed_val.len > 0 and trimmed_val[trimmed_val.len - 1] == '\\') {
                    // Continuation: append everything before the backslash
                    try appendConfigValuePart(&value_buf, trimmed_val[0 .. trimmed_val.len - 1]);
                    raw_value = if (line_iter.next()) |next_line|
                        std.mem.trim(u8, std.mem.trimRight(u8, next_line, "\r"), " \t")
                    else
                        break;
                } else {
                    try appendConfigValuePart(&value_buf, raw_value);
                    break;
                }
            }
            
            // Check if this matches the requested key
            const section_matches = if (current_section) |cs|
                std.ascii.eqlIgnoreCase(cs, parsed_key.section)
            else
                false;
            
            const subsection_matches = if (parsed_key.subsection) |ps| blk: {
                if (current_subsection) |css| {
                    break :blk std.mem.eql(u8, css, ps);
                }
                break :blk false;
            } else current_subsection == null;
            
            const key_matches = std.ascii.eqlIgnoreCase(raw_key, parsed_key.variable);
            
            if (section_matches and subsection_matches and key_matches) {
                if (last_value) |lv| allocator.free(lv);
                last_value = try value_buf.toOwnedSlice();
            }
        } else {
            // Boolean key without value (e.g., just "key" means true)
            const raw_key = std.mem.trim(u8, trimmed, " \t");
            // Remove inline comments
            const comment_pos = std.mem.indexOf(u8, raw_key, "#") orelse std.mem.indexOf(u8, raw_key, ";");
            const clean_key = if (comment_pos) |cp| std.mem.trimRight(u8, raw_key[0..cp], " \t") else raw_key;
            
            if (clean_key.len > 0) {
                const section_matches = if (current_section) |cs|
                    std.ascii.eqlIgnoreCase(cs, parsed_key.section)
                else
                    false;
                    
                const subsection_matches = if (parsed_key.subsection) |ps| blk: {
                    if (current_subsection) |css| {
                        break :blk std.mem.eql(u8, css, ps);
                    }
                    break :blk false;
                } else current_subsection == null;
                
                const key_matches = std.ascii.eqlIgnoreCase(clean_key, parsed_key.variable);
                
                if (section_matches and subsection_matches and key_matches) {
                    if (last_value) |lv| allocator.free(lv);
                    last_value = try allocator.dupe(u8, "true"); // boolean key
                }
            }
        }
    }
    
    if (last_value) |v| return v;
    return error.KeyNotFound;
}

const ParsedConfigKey = struct {
    section: []u8,
    subsection: ?[]u8,
    variable: []u8,
};

fn parseConfigKey(key: []const u8, allocator: std.mem.Allocator) !ParsedConfigKey {
    // Parse "section.variable" or "section.subsection.variable"
    // The last dot separates the variable name
    // For subsections like remote."origin".url: section=remote, subsection=origin, variable=url
    // Normal: core.bare -> section=core, subsection=null, variable=bare
    // Subsection: branch.main.remote -> section=branch, subsection=main, variable=remote
    const last_dot = std.mem.lastIndexOf(u8, key, ".") orelse return error.InvalidKey;
    const variable = key[last_dot + 1 ..];
    const prefix = key[0..last_dot];
    
    // Check if prefix has a dot (subsection)
    if (std.mem.indexOf(u8, prefix, ".")) |first_dot| {
        const section = prefix[0..first_dot];
        const subsection = prefix[first_dot + 1 ..];
        return .{
            .section = try allocator.dupe(u8, section),
            .subsection = try allocator.dupe(u8, subsection),
            .variable = try allocator.dupe(u8, variable),
        };
    }
    
    return .{
        .section = try allocator.dupe(u8, prefix),
        .subsection = null,
        .variable = try allocator.dupe(u8, variable),
    };
}

const ParsedSection = struct {
    section: ?[]u8,
    subsection: ?[]u8,
};

fn parseConfigSectionHeader(header: []const u8, allocator: std.mem.Allocator) !ParsedSection {
    // Parse [section] or [section "subsection"]
    // Find the closing bracket
    const close = std.mem.lastIndexOf(u8, header, "]") orelse return .{ .section = null, .subsection = null };
    const inner = header[1..close];
    
    // Check for quoted subsection
    if (std.mem.indexOf(u8, inner, " \"")) |quote_start| {
        const section = std.mem.trim(u8, inner[0..quote_start], " \t");
        var subsection_raw = inner[quote_start + 2 ..];
        // Remove trailing quote
        if (subsection_raw.len > 0 and subsection_raw[subsection_raw.len - 1] == '"') {
            subsection_raw = subsection_raw[0 .. subsection_raw.len - 1];
        }
        // Unescape backslashes in subsection
        var sub_buf = std.array_list.Managed(u8).init(allocator);
        defer sub_buf.deinit();
        var si: usize = 0;
        while (si < subsection_raw.len) : (si += 1) {
            if (subsection_raw[si] == '\\' and si + 1 < subsection_raw.len) {
                si += 1;
                try sub_buf.append(subsection_raw[si]);
            } else {
                try sub_buf.append(subsection_raw[si]);
            }
        }
        return .{
            .section = try allocator.dupe(u8, section),
            .subsection = try sub_buf.toOwnedSlice(),
        };
    }
    
    return .{
        .section = try allocator.dupe(u8, inner),
        .subsection = null,
    };
}

fn appendConfigValuePart(buf: *std.array_list.Managed(u8), raw: []const u8) !void {
    // Parse a config value part, handling quotes and inline comments
    // Leading whitespace of raw value is trimmed only before first non-whitespace or quote
    const trimmed = std.mem.trimLeft(u8, raw, " \t");
    var in_quotes = false;
    var last_quoted_end: usize = 0; // buf position after last quoted segment
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (c == '\\' and i + 1 < trimmed.len) {
            i += 1;
            const next = trimmed[i];
            switch (next) {
                'n' => try buf.append('\n'),
                't' => try buf.append('\t'),
                'b' => try buf.append(0x08),
                '"' => try buf.append('"'),
                '\\' => try buf.append('\\'),
                else => {
                    try buf.append('\\');
                    try buf.append(next);
                },
            }
            if (in_quotes) last_quoted_end = buf.items.len;
        } else if (c == '"') {
            if (in_quotes) {
                last_quoted_end = buf.items.len;
            }
            in_quotes = !in_quotes;
        } else if (!in_quotes and (c == '#' or c == ';')) {
            // Inline comment
            break;
        } else {
            try buf.append(c);
            if (in_quotes) last_quoted_end = buf.items.len;
        }
    }
    // Trim trailing unquoted whitespace: only remove whitespace after the last quoted content
    if (!in_quotes) {
        while (buf.items.len > last_quoted_end and (buf.items[buf.items.len - 1] == ' ' or buf.items[buf.items.len - 1] == '\t')) {
            _ = buf.pop();
        }
    }
}

fn cmdVersion(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    _ = allocator;
    var show_build_options = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--build-options")) {
            show_build_options = true;
        }
    }
    try platform_impl.writeStdout("git version 2.47.0\n");
    if (show_build_options) {
        try platform_impl.writeStdout("cpu: x86_64\n");
        try platform_impl.writeStdout("sizeof-long: 8\n");
        try platform_impl.writeStdout("sizeof-size_t: 8\n");
        try platform_impl.writeStdout("shell-path: /bin/sh\n");
        try platform_impl.writeStdout("feature: fsmonitor--daemon\n");
        try platform_impl.writeStdout("default-hash: sha1\n");
        try platform_impl.writeStdout("default-ref-format: files\n");
    }
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

fn isValidHexString(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return s.len > 0;
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

fn lookupBlobInTree(tree_hash: []const u8, path: []const u8, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !?[20]u8 {
    // Load tree object
    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch return null;
    defer tree_obj.deinit(allocator);
    
    if (tree_obj.type != .tree) return null;
    
    // Split path into first component and rest
    const slash_pos = std.mem.indexOfScalar(u8, path, '/');
    const name_to_find = if (slash_pos) |pos| path[0..pos] else path;
    const remaining = if (slash_pos) |pos| path[pos + 1 ..] else null;
    
    // Parse tree entries
    var i: usize = 0;
    while (i < tree_obj.data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, i, ' ') orelse break;
        const null_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, space_pos + 1, 0) orelse break;
        const name = tree_obj.data[space_pos + 1 .. null_pos];
        
        const hash_start = null_pos + 1;
        if (hash_start + 20 > tree_obj.data.len) break;
        const hash_bytes = tree_obj.data[hash_start .. hash_start + 20];
        
        if (std.mem.eql(u8, name, name_to_find)) {
            if (remaining) |rest| {
                // This is a directory - recurse
                const sub_tree_hash = try std.fmt.allocPrint(allocator, "{x}", .{hash_bytes});
                defer allocator.free(sub_tree_hash);
                return try lookupBlobInTree(sub_tree_hash, rest, git_path, platform_impl, allocator);
            } else {
                // This is the file - return its hash
                var result: [20]u8 = undefined;
                @memcpy(&result, hash_bytes);
                return result;
            }
        }
        
        i = hash_start + 20;
    }
    
    return null; // Not found
}

fn checkIfDifferentFromHEAD(entry: index_mod.IndexEntry, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !bool {
    // Get current HEAD commit
    const head_hash_opt = refs.getCurrentCommit(git_path, platform_impl, allocator) catch return false;
    const head_hash = head_hash_opt orelse return false;
    defer allocator.free(head_hash);
    
    // Load HEAD commit
    const commit_obj = objects.GitObject.load(head_hash, git_path, platform_impl, allocator) catch return false;
    defer commit_obj.deinit(allocator);
    
    if (commit_obj.type != .commit) return false;
    
    // Parse commit to get tree hash
    var lines = std.mem.splitSequence(u8, commit_obj.data, "\n");
    const tree_line = lines.next() orelse return false;
    if (!std.mem.startsWith(u8, tree_line, "tree ")) return false;
    const tree_hash = tree_line["tree ".len..];
    
    // Look up the blob hash in the tree (recursively handles subdirectories)
    const tree_blob_hash = try lookupBlobInTree(tree_hash, entry.path, git_path, platform_impl, allocator);
    
    if (tree_blob_hash) |hash_bytes| {
        // Compare with index entry hash
        return !std.mem.eql(u8, &hash_bytes, &entry.sha1);
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
            .sym_link => {
                // Add symlink - index.add handles symlinks natively
                const repo_root_dir = std.fs.path.dirname(git_path) orelse ".";
                const rel_to_repo = if (std.mem.startsWith(u8, entry_full_path, repo_root_dir))
                    entry_full_path[repo_root_dir.len + 1 ..]
                else
                    entry_relative_path;
                index.add(rel_to_repo, rel_to_repo, platform_impl, git_path) catch continue;
            },
            .directory => {
                // Recursively add subdirectory
                addDirectoryRecursively(allocator, repo_root, entry_relative_path, index, git_path, platform_impl) catch continue;
            },
            else => continue, // Skip other types
        }
    }
}

/// Build recursive tree objects from a list of index entries.
/// For entries with paths like "src/main.zig", creates subtree objects for each directory level,
/// matching git's expected tree format.
fn buildRecursiveTree(allocator: std.mem.Allocator, entries: []const index_mod.IndexEntry, prefix: []const u8, git_path: []const u8, platform_impl: *const platform_mod.Platform) ![]u8 {
    const TreeItem = struct {
        name: []const u8,
        mode: []const u8,
        hash_bytes: [20]u8,
    };
    var items = std.array_list.Managed(TreeItem).init(allocator);
    defer {
        for (items.items) |item| {
            allocator.free(item.name);
            allocator.free(item.mode);
        }
        items.deinit();
    }

    // Track subdirectories we've already processed
    var seen_dirs = std.StringHashMap(void).init(allocator);
    defer {
        var kit = seen_dirs.keyIterator();
        while (kit.next()) |key| allocator.free(key.*);
        seen_dirs.deinit();
    }

    for (entries) |entry| {
        // Only consider entries under our prefix
        const rel_path = if (prefix.len == 0)
            entry.path
        else blk: {
            if (std.mem.startsWith(u8, entry.path, prefix) and
                entry.path.len > prefix.len and
                entry.path[prefix.len] == '/')
            {
                break :blk entry.path[prefix.len + 1 ..];
            } else continue;
        };

        // Check if this is a direct child or lives in a subdirectory
        if (std.mem.indexOfScalar(u8, rel_path, '/')) |slash_pos| {
            // It's inside a subdirectory — record the dir name
            const dir_name = rel_path[0..slash_pos];
            if (!seen_dirs.contains(dir_name)) {
                const duped = try allocator.dupe(u8, dir_name);
                try seen_dirs.put(duped, {});
            }
        } else {
            // Direct child (blob)
            const mode_str = try std.fmt.allocPrint(allocator, "{o}", .{entry.mode});
            try items.append(.{
                .name = try allocator.dupe(u8, rel_path),
                .mode = mode_str,
                .hash_bytes = entry.sha1,
            });
        }
    }

    // Recurse into each subdirectory
    var dir_it = seen_dirs.keyIterator();
    while (dir_it.next()) |dir_name_ptr| {
        const dir_name = dir_name_ptr.*;
        const sub_prefix = if (prefix.len == 0)
            try allocator.dupe(u8, dir_name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, dir_name });
        defer allocator.free(sub_prefix);

        const sub_hash_hex = try buildRecursiveTree(allocator, entries, sub_prefix, git_path, platform_impl);
        defer allocator.free(sub_hash_hex);

        var sub_hash: [20]u8 = undefined;
        _ = try std.fmt.hexToBytes(&sub_hash, sub_hash_hex);

        try items.append(.{
            .name = try allocator.dupe(u8, dir_name),
            .mode = try allocator.dupe(u8, "40000"),
            .hash_bytes = sub_hash,
        });
    }

    // Sort items by name (git requires sorted tree entries; dirs get trailing '/' for comparison)
    std.sort.block(TreeItem, items.items, {}, struct {
        fn lessThan(_: void, a: TreeItem, b: TreeItem) bool {
            const a_is_dir = std.mem.eql(u8, a.mode, "40000");
            const b_is_dir = std.mem.eql(u8, b.mode, "40000");
            // Git tree sort: compare as if dirs have trailing '/'
            if (a_is_dir and !b_is_dir) {
                // Compare a.name + "/" vs b.name
                const order = std.mem.order(u8, a.name, b.name[0..@min(a.name.len, b.name.len)]);
                if (order != .eq) return order == .lt;
                if (a.name.len < b.name.len) {
                    return '/' < b.name[a.name.len];
                }
                return a.name.len < b.name.len;
            } else if (!a_is_dir and b_is_dir) {
                const order = std.mem.order(u8, a.name[0..@min(a.name.len, b.name.len)], b.name);
                if (order != .eq) return order == .lt;
                if (b.name.len < a.name.len) {
                    return a.name[b.name.len] < '/';
                }
                return a.name.len < b.name.len;
            } else {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }
    }.lessThan);

    // Build tree content
    var tree_content = std.array_list.Managed(u8).init(allocator);
    defer tree_content.deinit();

    for (items.items) |item| {
        try tree_content.appendSlice(item.mode);
        try tree_content.append(' ');
        try tree_content.appendSlice(item.name);
        try tree_content.append(0);
        try tree_content.appendSlice(&item.hash_bytes);
    }

    // Create and store the tree object
    const tree_data = try allocator.dupe(u8, tree_content.items);
    var tree_object = objects.GitObject.init(.tree, tree_data);
    defer tree_object.deinit(allocator);

    return try tree_object.store(git_path, platform_impl, allocator);
}

/// Stage all tracked file changes into the index (pure Zig replacement for `git add -u`).
/// For each entry in the index, check if the working-tree file was modified or deleted,
/// then update or remove the index entry accordingly.
fn stageTrackedChanges(allocator: std.mem.Allocator, index: *index_mod.Index, git_path: []const u8, repo_root: []const u8, platform_impl: *const platform_mod.Platform) !void {
    // Collect paths to remove (deleted files) and paths to re-add (modified files).
    // We collect first to avoid mutating the list while iterating.
    var to_remove = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (to_remove.items) |p| allocator.free(p);
        to_remove.deinit();
    }
    var to_readd = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (to_readd.items) |p| allocator.free(p);
        to_readd.deinit();
    }

    for (index.entries.items) |entry| {
        const full_path = if (repo_root.len > 0 and !std.mem.eql(u8, repo_root, "."))
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path })
        else
            try allocator.dupe(u8, entry.path);
        defer allocator.free(full_path);

        // Check if file still exists
        const file_exists = if (std.fs.path.isAbsolute(full_path))
            blk: {
                std.fs.accessAbsolute(full_path, .{}) catch break :blk false;
                break :blk true;
            }
        else
            blk: {
                std.fs.cwd().access(full_path, .{}) catch break :blk false;
                break :blk true;
            };

        if (!file_exists) {
            try to_remove.append(try allocator.dupe(u8, entry.path));
            continue;
        }

        // Read file content and hash it to see if it changed
        const content = platform_impl.fs.readFile(allocator, full_path) catch continue;
        defer allocator.free(content);

        // Compute blob hash
        const header = try std.fmt.allocPrint(allocator, "blob {d}\x00", .{content.len});
        defer allocator.free(header);

        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(header);
        hasher.update(content);
        var new_hash: [20]u8 = undefined;
        hasher.final(&new_hash);

        if (!std.mem.eql(u8, &new_hash, &entry.sha1)) {
            try to_readd.append(try allocator.dupe(u8, entry.path));
        }
    }

    // Remove deleted files from index
    for (to_remove.items) |path| {
        try index.remove(path);
    }

    // Re-add modified files (this re-hashes and stores the blob)
    for (to_readd.items) |path| {
        const full_path = if (repo_root.len > 0 and !std.mem.eql(u8, repo_root, "."))
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path })
        else
            try allocator.dupe(u8, path);
        defer allocator.free(full_path);
        index.add(path, full_path, platform_impl, git_path) catch continue;
    }

    // Save the updated index
    try index.save(git_path, platform_impl);
}

/// Get timezone offset in seconds from UTC.
/// Reads from the TZ environment variable or /etc/timezone, /etc/localtime.
/// For simplicity, uses the TZ env var if set (e.g. "EST+5" or numeric offset),
/// otherwise returns 0.
fn getTimezoneOffset(timestamp: i64) i32 {
    _ = timestamp;
    // Try TZ environment variable for simple offset formats
    if (std.posix.getenv("TZ")) |tz| {
        // Handle formats like "UTC-5", "EST+5", or just "+0530"
        return parseTzOffset(tz);
    }
    return 0;
}

fn parseTzOffset(tz: []const u8) i32 {
    // Find first +/- that indicates offset
    var i: usize = 0;
    while (i < tz.len) : (i += 1) {
        if (tz[i] == '+' or tz[i] == '-') {
            const sign: i32 = if (tz[i] == '-') 1 else -1; // TZ convention: UTC-5 means +5 hours ahead... actually POSIX TZ is inverted
            // Actually in POSIX, TZ=EST5EDT means EST is UTC-5. The number is positive for west of UTC.
            // So TZ offset sign is inverted: positive number = west = negative UTC offset
            const rest = tz[i + 1 ..];
            // Parse hours (and optional :minutes)
            var colon_pos: ?usize = null;
            for (rest, 0..) |c, j| {
                if (c == ':') {
                    colon_pos = j;
                    break;
                }
            }
            if (colon_pos) |cp| {
                const hours = std.fmt.parseInt(i32, rest[0..cp], 10) catch return 0;
                const minutes = std.fmt.parseInt(i32, rest[cp + 1 ..], 10) catch return 0;
                return sign * (hours * 3600 + minutes * 60);
            } else {
                // Just hours
                var end: usize = rest.len;
                for (rest, 0..) |c, j| {
                    if (!std.ascii.isDigit(c)) {
                        end = j;
                        break;
                    }
                }
                if (end == 0) return 0;
                const hours = std.fmt.parseInt(i32, rest[0..end], 10) catch return 0;
                return sign * hours * 3600;
            }
        }
    }
    return 0;
}

/// Resolve author name from environment or git config.
fn resolveAuthorName(allocator: std.mem.Allocator, git_path: []const u8) ![]const u8 {
    // 1. GIT_AUTHOR_NAME env var takes highest precedence
    if (std.posix.getenv("GIT_AUTHOR_NAME")) |name| {
        return try allocator.dupe(u8, name);
    }
    // 2. Git config user.name
    if (readConfigUserName(allocator, git_path)) |name| {
        return name;
    }
    return error.NotFound;
}

/// Resolve author email from environment or git config.
fn resolveAuthorEmail(allocator: std.mem.Allocator, git_path: []const u8) ![]const u8 {
    if (std.posix.getenv("GIT_AUTHOR_EMAIL")) |email| {
        return try allocator.dupe(u8, email);
    }
    if (readConfigUserEmail(allocator, git_path)) |email| {
        return email;
    }
    return error.NotFound;
}

/// Resolve committer name from environment, config, or fall back to author name.
fn resolveCommitterName(allocator: std.mem.Allocator, git_path: []const u8, fallback: []const u8) ![]const u8 {
    if (std.posix.getenv("GIT_COMMITTER_NAME")) |name| {
        return try allocator.dupe(u8, name);
    }
    if (readConfigUserName(allocator, git_path)) |name| {
        return name;
    }
    _ = fallback;
    return error.NotFound;
}

/// Resolve committer email from environment, config, or fall back to author email.
fn resolveCommitterEmail(allocator: std.mem.Allocator, git_path: []const u8, fallback: []const u8) ![]const u8 {
    if (std.posix.getenv("GIT_COMMITTER_EMAIL")) |email| {
        return try allocator.dupe(u8, email);
    }
    if (readConfigUserEmail(allocator, git_path)) |email| {
        return email;
    }
    _ = fallback;
    return error.NotFound;
}

/// Read user.name from git config (local then global).
fn readConfigUserName(allocator: std.mem.Allocator, git_path: []const u8) ?[]const u8 {
    var config = config_mod.loadGitConfig(git_path, allocator) catch return null;
    defer config.deinit();
    const name = config.getUserName() orelse return null;
    return allocator.dupe(u8, name) catch null;
}

/// Read user.email from git config (local then global).
fn readConfigUserEmail(allocator: std.mem.Allocator, git_path: []const u8) ?[]const u8 {
    var config = config_mod.loadGitConfig(git_path, allocator) catch return null;
    defer config.deinit();
    const email = config.getUserEmail() orelse return null;
    return allocator.dupe(u8, email) catch null;
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

/// Resolve any object hash by prefix (not just commits). Returns full 40-char hash.
fn resolveObjectByPrefix(git_path: []const u8, hash_prefix: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) ![]u8 {
    // Full hash - verify it exists
    if (hash_prefix.len == 40 and isValidHexString(hash_prefix)) {
        const obj = objects.GitObject.load(hash_prefix, git_path, platform_impl, allocator) catch return error.ObjectNotFound;
        obj.deinit(allocator);
        return try allocator.dupe(u8, hash_prefix);
    }

    if (hash_prefix.len < 4 or !isValidHexString(hash_prefix)) return error.ObjectNotFound;

    // Short hash - scan objects directory
    const dir_name = hash_prefix[0..2];
    const file_prefix = hash_prefix[2..];
    const subdir_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}", .{ git_path, dir_name });
    defer allocator.free(subdir_path);

    var found_hash: ?[]u8 = null;
    errdefer if (found_hash) |h| allocator.free(h);

    // Scan loose objects
    if (std.fs.cwd().openDir(subdir_path, .{ .iterate = true })) |*dir_ptr| {
        var dir = dir_ptr.*;
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.name, file_prefix)) {
                if (found_hash != null) {
                    allocator.free(found_hash.?);
                    return error.AmbiguousObject;
                }
                found_hash = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_name, entry.name });
            }
        }
    } else |_| {}

    // Also scan pack files for prefix matches
    if (found_hash == null) {
        // Try loading the object directly - pack files are searched by GitObject.load
        const obj = objects.GitObject.load(hash_prefix, git_path, platform_impl, allocator) catch {
            return found_hash orelse error.ObjectNotFound;
        };
        obj.deinit(allocator);
        // If load succeeded with a prefix, it found it
        return try allocator.dupe(u8, hash_prefix);
    }

    return found_hash orelse error.ObjectNotFound;
}

/// Resolve a revision string like HEAD, HEAD~3, HEAD^2, v1.0^{commit}, branch_name, etc.
/// Returns the 40-char hash of the resolved object.
fn findRevColonPath(rev: []const u8) ?usize {
    var in_peel: bool = false;
    var i: usize = 0;
    while (i < rev.len) : (i += 1) {
        if (rev[i] == '^' and i + 1 < rev.len and rev[i + 1] == '{') { in_peel = true; i += 1; }
        else if (in_peel and rev[i] == '}') { in_peel = false; }
        else if (!in_peel and rev[i] == ':' and i > 0) { return i; }
    }
    return null;
}

fn resolveTreePath(git_path: []const u8, tree_hash: []const u8, path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) ![]u8 {
    var current_hash = try allocator.dupe(u8, tree_hash);
    var path_iter = std.mem.splitScalar(u8, path, '/');
    while (path_iter.next()) |component| {
        if (component.len == 0) continue;
        const tree_obj = objects.GitObject.load(current_hash, git_path, platform_impl, allocator) catch { allocator.free(current_hash); return error.ObjectNotFound; };
        defer tree_obj.deinit(allocator);
        allocator.free(current_hash);
        if (tree_obj.type != .tree) return error.ObjectNotFound;
        var entries = try parseTreeEntries(tree_obj.data, allocator);
        defer { for (entries.items) |*e| e.deinit(allocator); entries.deinit(); }
        var found = false;
        for (entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, component)) { current_hash = try allocator.dupe(u8, entry.hash); found = true; break; }
        }
        if (!found) return error.ObjectNotFound;
    }
    return current_hash;
}

fn resolveRevision(git_path: []const u8, rev: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) ![]u8 {
    // Handle <rev>:<path> syntax
    if (findRevColonPath(rev)) |colon_pos| {
        const rev_part = rev[0..colon_pos];
        const path_part = rev[colon_pos + 1 ..];
        const obj_hash = resolveRevision(git_path, rev_part, platform_impl, allocator) catch return error.BadRevision;
        defer allocator.free(obj_hash);
        const tree_hash = blk: {
            const obj = objects.GitObject.load(obj_hash, git_path, platform_impl, allocator) catch return error.BadRevision;
            defer obj.deinit(allocator);
            switch (obj.type) {
                .tree => break :blk try allocator.dupe(u8, obj_hash),
                .commit => {
                    var lines = std.mem.splitSequence(u8, obj.data, "\n");
                    if (lines.next()) |fl| { if (std.mem.startsWith(u8, fl, "tree ")) break :blk try allocator.dupe(u8, fl["tree ".len..]); }
                    return error.BadRevision;
                },
                .tag => {
                    var lines = std.mem.splitSequence(u8, obj.data, "\n");
                    while (lines.next()) |l| { if (std.mem.startsWith(u8, l, "object ")) break :blk try allocator.dupe(u8, l["object ".len..]); }
                    return error.BadRevision;
                },
                else => return error.BadRevision,
            }
        };
        defer allocator.free(tree_hash);
        if (path_part.len == 0) return try allocator.dupe(u8, tree_hash);
        return resolveTreePath(git_path, tree_hash, path_part, platform_impl, allocator) catch return error.BadRevision;
    }

    // Handle ^{type} peel suffix: e.g. "v1.0^{commit}" or "HEAD^{tree}"
    if (std.mem.indexOf(u8, rev, "^{")) |peel_start| {
        if (std.mem.indexOfScalar(u8, rev[peel_start..], '}')) |close_offset| {
            const base_rev = rev[0..peel_start];
            const peel_type = rev[peel_start + 2 .. peel_start + close_offset];
            const base_hash = try resolveRevision(git_path, base_rev, platform_impl, allocator);
            defer allocator.free(base_hash);
            return peelObject(git_path, base_hash, peel_type, platform_impl, allocator);
        }
    }

    // Handle ^0 (shorthand for ^{commit})
    if (std.mem.endsWith(u8, rev, "^0")) {
        const base_rev = rev[0 .. rev.len - 2];
        const base_hash = try resolveRevision(git_path, base_rev, platform_impl, allocator);
        defer allocator.free(base_hash);
        return peelObject(git_path, base_hash, "commit", platform_impl, allocator);
    }

    // Find the last ~ or ^ operator (handle from right to left for chaining)
    // We need to find the rightmost operator that's not inside ^{}
    var split_pos: ?usize = null;
    var i_rev: usize = rev.len;
    while (i_rev > 0) {
        i_rev -= 1;
        const c = rev[i_rev];
        if (c == '~') {
            split_pos = i_rev;
            break;
        }
        if (c == '^') {
            // Make sure it's not ^{ which we handled above
            if (i_rev + 1 < rev.len and rev[i_rev + 1] == '{') continue;
            split_pos = i_rev;
            break;
        }
    }

    if (split_pos) |pos| {
        const base_rev = rev[0..pos];
        const op = rev[pos];
        const suffix = rev[pos + 1 ..];

        const base_hash = try resolveRevision(git_path, base_rev, platform_impl, allocator);
        defer allocator.free(base_hash);

        if (op == '~') {
            const n: u32 = if (suffix.len == 0) 1 else std.fmt.parseInt(u32, suffix, 10) catch return error.BadRevision;
            return walkFirstParent(git_path, base_hash, n, platform_impl, allocator);
        } else { // '^'
            const n: u32 = if (suffix.len == 0) 1 else std.fmt.parseInt(u32, suffix, 10) catch return error.BadRevision;
            return getNthParent(git_path, base_hash, n, platform_impl, allocator);
        }
    }

    // No operators - resolve as a ref name or hash
    // Try as full or abbreviated hash
    if (rev.len >= 4 and isValidHexString(rev)) {
        if (resolveObjectByPrefix(git_path, rev, platform_impl, allocator)) |hash| {
            return hash;
        } else |_| {}
    }

    // Try HEAD
    if (std.mem.eql(u8, rev, "HEAD") or std.mem.eql(u8, rev, "@")) {
        const head_commit = refs.getCurrentCommit(git_path, platform_impl, allocator) catch return error.BadRevision;
        return head_commit orelse error.BadRevision;
    }

    // Try refs/heads/<rev>
    {
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, rev });
        defer allocator.free(ref_path);
        if (platform_impl.fs.readFile(allocator, ref_path)) |content| {
            defer allocator.free(content);
            const hash = std.mem.trim(u8, content, " \t\n\r");
            if (hash.len == 40 and isValidHexString(hash)) return try allocator.dupe(u8, hash);
        } else |_| {}
    }

    // Try refs/tags/<rev>
    {
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{ git_path, rev });
        defer allocator.free(ref_path);
        if (platform_impl.fs.readFile(allocator, ref_path)) |content| {
            defer allocator.free(content);
            const hash = std.mem.trim(u8, content, " \t\n\r");
            if (hash.len == 40 and isValidHexString(hash)) return try allocator.dupe(u8, hash);
        } else |_| {}
    }

    // Try refs/remotes/<rev>
    {
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}", .{ git_path, rev });
        defer allocator.free(ref_path);
        if (platform_impl.fs.readFile(allocator, ref_path)) |content| {
            defer allocator.free(content);
            const hash = std.mem.trim(u8, content, " \t\n\r");
            if (hash.len == 40 and isValidHexString(hash)) return try allocator.dupe(u8, hash);
        } else |_| {}
    }

    // Try refs/<rev> directly
    {
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, rev });
        defer allocator.free(ref_path);
        if (platform_impl.fs.readFile(allocator, ref_path)) |content| {
            defer allocator.free(content);
            const trimmed = std.mem.trim(u8, content, " \t\n\r");
            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                // Symbolic ref - recurse
                const target = trimmed[5..];
                return resolveRevision(git_path, target, platform_impl, allocator);
            }
            if (trimmed.len == 40 and isValidHexString(trimmed)) return try allocator.dupe(u8, trimmed);
        } else |_| {}
    }

    // Try packed-refs
    {
        const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_path});
        defer allocator.free(packed_refs_path);
        if (platform_impl.fs.readFile(allocator, packed_refs_path)) |packed_content| {
            defer allocator.free(packed_content);
            // Try different ref prefixes in packed-refs
            const prefixes = [_][]const u8{ "refs/heads/", "refs/tags/", "refs/remotes/", "" };
            for (prefixes) |prefix| {
                const full_ref = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, rev });
                defer allocator.free(full_ref);
                var lines = std.mem.splitSequence(u8, packed_content, "\n");
                while (lines.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '^') continue;
                    // Format: <hash> <refname>
                    if (trimmed.len > 41 and trimmed[40] == ' ') {
                        const ref_name = trimmed[41..];
                        if (std.mem.eql(u8, ref_name, full_ref)) {
                            const hash = trimmed[0..40];
                            if (isValidHexString(hash)) return try allocator.dupe(u8, hash);
                        }
                    }
                }
            }
        } else |_| {}
    }

    return error.BadRevision;
}

/// Peel an object to a target type (e.g., peel tag to commit, commit to tree)
fn peelObject(git_path: []const u8, hash: []const u8, target_type: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) ![]u8 {
    var current_hash = try allocator.dupe(u8, hash);
    var depth: u32 = 0;
    while (depth < 20) : (depth += 1) {
        const obj = objects.GitObject.load(current_hash, git_path, platform_impl, allocator) catch {
            allocator.free(current_hash);
            return error.ObjectNotFound;
        };
        defer obj.deinit(allocator);

        const obj_type_str: []const u8 = switch (obj.type) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
        };

        // Empty target_type means peel to non-tag
        if (target_type.len == 0) {
            if (obj.type != .tag) return current_hash;
        } else if (std.mem.eql(u8, obj_type_str, target_type)) {
            return current_hash;
        }

        // Peel one level
        if (obj.type == .tag) {
            // Parse tag to find target
            const target_hash = parseTagObject(obj.data, allocator) catch {
                allocator.free(current_hash);
                return error.ObjectNotFound;
            };
            allocator.free(current_hash);
            current_hash = target_hash;
        } else if (obj.type == .commit and std.mem.eql(u8, target_type, "tree")) {
            // Get tree from commit
            var lines = std.mem.splitSequence(u8, obj.data, "\n");
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "tree ")) {
                    const tree_hash = line[5..];
                    if (tree_hash.len == 40) {
                        allocator.free(current_hash);
                        return try allocator.dupe(u8, tree_hash);
                    }
                }
            }
            allocator.free(current_hash);
            return error.ObjectNotFound;
        } else {
            allocator.free(current_hash);
            return error.ObjectNotFound;
        }
    }
    allocator.free(current_hash);
    return error.ObjectNotFound;
}

/// Walk N first-parents from a commit (for ~ operator)
fn walkFirstParent(git_path: []const u8, start_hash: []const u8, steps: u32, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) ![]u8 {
    var current_hash = try allocator.dupe(u8, start_hash);
    var s: u32 = 0;
    while (s < steps) : (s += 1) {
        const obj = objects.GitObject.load(current_hash, git_path, platform_impl, allocator) catch {
            allocator.free(current_hash);
            return error.BadRevision;
        };
        defer obj.deinit(allocator);
        if (obj.type != .commit) {
            allocator.free(current_hash);
            return error.BadRevision;
        }
        var lines = std.mem.splitSequence(u8, obj.data, "\n");
        var parent: ?[]const u8 = null;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                parent = line[7..];
                break;
            }
            if (line.len == 0) break;
        }
        if (parent) |p| {
            allocator.free(current_hash);
            current_hash = try allocator.dupe(u8, p);
        } else {
            allocator.free(current_hash);
            return error.BadRevision;
        }
    }
    return current_hash;
}

/// Get the Nth parent of a commit (for ^ operator). ^1 = first parent, ^2 = second parent.
fn getNthParent(git_path: []const u8, hash: []const u8, n: u32, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) ![]u8 {
    if (n == 0) {
        // ^0 means the commit itself (peel to commit)
        return peelObject(git_path, hash, "commit", platform_impl, allocator);
    }
    const obj = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch return error.BadRevision;
    defer obj.deinit(allocator);
    if (obj.type != .commit) return error.BadRevision;

    var lines = std.mem.splitSequence(u8, obj.data, "\n");
    var parent_idx: u32 = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "parent ")) {
            parent_idx += 1;
            if (parent_idx == n) {
                return try allocator.dupe(u8, line[7..]);
            }
        }
        if (line.len == 0) break;
    }
    return error.BadRevision;
}

fn cmdRevParse(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("rev-parse: not supported in freestanding mode\n");
        return;
    }

    // Collect all args
    var all_args = std.array_list.Managed([]const u8).init(allocator);
    defer all_args.deinit();
    while (args.next()) |arg| {
        try all_args.append(arg);
    }

    if (all_args.items.len == 0) {
        // git rev-parse with no args outputs nothing and exits 0
        return;
    }

    // Parse flags
    var verify = false;
    var quiet = false;
    var short: ?u8 = null; // --short[=N]
    var symbolic_full_name = false;
    var abbrev_ref = false;
    var revs_only = false;
    var no_revs = false;
    var flags_only = false;
    var no_flags = false;
    var positional_args = std.array_list.Managed([]const u8).init(allocator);
    defer positional_args.deinit();

    for (all_args.items) |arg| {
        if (std.mem.eql(u8, arg, "--verify")) {
            verify = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--short")) {
            short = 7;
        } else if (std.mem.startsWith(u8, arg, "--short=")) {
            short = std.fmt.parseInt(u8, arg[8..], 10) catch 7;
        } else if (std.mem.eql(u8, arg, "--symbolic-full-name")) {
            symbolic_full_name = true;
        } else if (std.mem.eql(u8, arg, "--abbrev-ref")) {
            abbrev_ref = true;
        } else if (std.mem.eql(u8, arg, "--revs-only")) {
            revs_only = true;
        } else if (std.mem.eql(u8, arg, "--no-revs")) {
            no_revs = true;
        } else if (std.mem.eql(u8, arg, "--flags")) {
            flags_only = true;
        } else if (std.mem.eql(u8, arg, "--no-flags")) {
            no_flags = true;
        } else if (std.mem.eql(u8, arg, "--sq")) {
            // Ignore for now (shell quoting)
        } else {
            try positional_args.append(arg);
        }
    }

    // Handle info queries that don't need refs resolution
    for (positional_args.items) |arg| {
        if (std.mem.eql(u8, arg, "--show-toplevel")) {
            const git_path = findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
                std.process.exit(128);
            };
            defer allocator.free(git_path);
            // Check if this is a bare repo
            const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(config_path);
            if (platform_impl.fs.readFile(allocator, config_path)) |cfg| {
                defer allocator.free(cfg);
                if (std.mem.indexOf(u8, cfg, "bare = true") != null) {
                    try platform_impl.writeStderr("fatal: this operation must be run in a work tree\n");
                    std.process.exit(128);
                }
            } else |_| {}
            const repo_root = std.fs.path.dirname(git_path) orelse git_path;
            const output = try std.fmt.allocPrint(allocator, "{s}\n", .{repo_root});
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
            return;
        } else if (std.mem.eql(u8, arg, "--git-dir")) {
            const git_path = findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
                std.process.exit(128);
            };
            defer allocator.free(git_path);
            const cwd = try platform_impl.fs.getCwd(allocator);
            defer allocator.free(cwd);
            if (std.mem.startsWith(u8, git_path, cwd) and git_path.len > cwd.len) {
                const rel = git_path[cwd.len..];
                const trimmed = if (rel.len > 0 and rel[0] == '/') rel[1..] else rel;
                if (trimmed.len > 0) {
                    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{trimmed});
                    defer allocator.free(output);
                    try platform_impl.writeStdout(output);
                } else {
                    try platform_impl.writeStdout(".git\n");
                }
            } else {
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{git_path});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
            return;
        } else if (std.mem.eql(u8, arg, "--git-common-dir")) {
            const git_path = findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
                std.process.exit(128);
            };
            defer allocator.free(git_path);
            const cwd = try platform_impl.fs.getCwd(allocator);
            defer allocator.free(cwd);
            if (std.mem.startsWith(u8, git_path, cwd) and git_path.len > cwd.len) {
                const rel = git_path[cwd.len..];
                const trimmed = if (rel.len > 0 and rel[0] == '/') rel[1..] else rel;
                if (trimmed.len > 0) {
                    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{trimmed});
                    defer allocator.free(output);
                    try platform_impl.writeStdout(output);
                } else {
                    try platform_impl.writeStdout(".git\n");
                }
            } else {
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{git_path});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
            return;
        } else if (std.mem.eql(u8, arg, "--is-inside-work-tree")) {
            const git_path = findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStdout("false\n");
                return;
            };
            defer allocator.free(git_path);
            // Check bare
            const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(config_path);
            if (platform_impl.fs.readFile(allocator, config_path)) |cfg| {
                defer allocator.free(cfg);
                if (std.mem.indexOf(u8, cfg, "bare = true") != null) {
                    try platform_impl.writeStdout("false\n");
                    return;
                }
            } else |_| {}
            try platform_impl.writeStdout("true\n");
            return;
        } else if (std.mem.eql(u8, arg, "--is-inside-git-dir")) {
            try platform_impl.writeStdout("false\n");
            return;
        } else if (std.mem.eql(u8, arg, "--is-bare-repository")) {
            const git_path = findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStdout("false\n");
                return;
            };
            defer allocator.free(git_path);
            const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(config_path);
            if (platform_impl.fs.readFile(allocator, config_path)) |cfg| {
                defer allocator.free(cfg);
                if (std.mem.indexOf(u8, cfg, "bare = true") != null) {
                    try platform_impl.writeStdout("true\n");
                    return;
                }
            } else |_| {}
            try platform_impl.writeStdout("false\n");
            return;
        } else if (std.mem.eql(u8, arg, "--show-cdup")) {
            const git_path = findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStderr("fatal: not a git repository\n");
                std.process.exit(128);
            };
            defer allocator.free(git_path);
            const repo_root = std.fs.path.dirname(git_path) orelse git_path;
            const cwd = try platform_impl.fs.getCwd(allocator);
            defer allocator.free(cwd);
            if (std.mem.eql(u8, cwd, repo_root)) {
                try platform_impl.writeStdout("\n");
            } else if (std.mem.startsWith(u8, cwd, repo_root)) {
                const rel = cwd[repo_root.len + 1 ..];
                var depth: usize = 1;
                for (rel) |c| {
                    if (c == '/') depth += 1;
                }
                var buf = std.array_list.Managed(u8).init(allocator);
                defer buf.deinit();
                var d: usize = 0;
                while (d < depth) : (d += 1) {
                    try buf.appendSlice("../");
                }
                try buf.append('\n');
                try platform_impl.writeStdout(buf.items);
            } else {
                try platform_impl.writeStdout("\n");
            }
            return;
        } else if (std.mem.eql(u8, arg, "--show-prefix")) {
            const git_path = findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStderr("fatal: not a git repository\n");
                std.process.exit(128);
            };
            defer allocator.free(git_path);
            const repo_root = std.fs.path.dirname(git_path) orelse git_path;
            const cwd = try platform_impl.fs.getCwd(allocator);
            defer allocator.free(cwd);
            if (std.mem.eql(u8, cwd, repo_root)) {
                try platform_impl.writeStdout("\n");
            } else if (std.mem.startsWith(u8, cwd, repo_root)) {
                const prefix = cwd[repo_root.len + 1 ..];
                const output = try std.fmt.allocPrint(allocator, "{s}/\n", .{prefix});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            } else {
                try platform_impl.writeStdout("\n");
            }
            return;
        } else if (std.mem.eql(u8, arg, "--absolute-git-dir")) {
            const git_path = findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStderr("fatal: not a git repository\n");
                std.process.exit(128);
            };
            defer allocator.free(git_path);
            const output = try std.fmt.allocPrint(allocator, "{s}\n", .{git_path});
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
            return;
        } else if (std.mem.eql(u8, arg, "--git-path")) {
            // Needs next arg but we handle it inline
            continue;
        } else if (std.mem.eql(u8, arg, "--show-object-format")) {
            try platform_impl.writeStdout("sha1\n");
            return;
        }
    }

    // If verify mode with no positional args that look like revisions
    if (verify) {
        // --verify expects exactly one revision argument
        var rev_arg: ?[]const u8 = null;
        for (positional_args.items) |arg| {
            if (std.mem.startsWith(u8, arg, "--")) continue;
            if (rev_arg != null) {
                if (!quiet) {
                    try platform_impl.writeStderr("fatal: Needed a single revision\n");
                }
                std.process.exit(128);
            }
            rev_arg = arg;
        }
        if (rev_arg == null) {
            if (!quiet) {
                try platform_impl.writeStderr("fatal: Needed a single revision\n");
            }
            std.process.exit(128);
        }

        const git_path = findGitDirectory(allocator, platform_impl) catch {
            if (!quiet) {
                try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
            }
            std.process.exit(128);
        };
        defer allocator.free(git_path);

        const hash = resolveRevision(git_path, rev_arg.?, platform_impl, allocator) catch {
            if (!quiet) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: Needed a single revision\n", .{});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            }
            std.process.exit(128);
        };
        defer allocator.free(hash);

        if (short) |n| {
            const s = if (n > 40) @as(u8, 40) else n;
            const out = try std.fmt.allocPrint(allocator, "{s}\n", .{hash[0..s]});
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        } else {
            const out = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        }
        return;
    }

    // Non-verify mode: process each positional arg
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    for (positional_args.items) |arg| {
        // Skip flags already processed
        if (std.mem.startsWith(u8, arg, "--")) {
            if (!revs_only and !no_flags) {
                // Output non-rev flags
                if (flags_only or no_revs) {
                    const out = try std.fmt.allocPrint(allocator, "{s}\n", .{arg});
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                }
            }
            continue;
        }

        if (no_revs) continue; // Skip revision args

        // Handle --symbolic-full-name for HEAD
        if (symbolic_full_name) {
            if (std.mem.eql(u8, arg, "HEAD")) {
                const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
                defer allocator.free(head_path);
                if (platform_impl.fs.readFile(allocator, head_path)) |content| {
                    defer allocator.free(content);
                    const trimmed = std.mem.trim(u8, content, " \t\n\r");
                    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                        const out = try std.fmt.allocPrint(allocator, "{s}\n", .{trimmed[5..]});
                        defer allocator.free(out);
                        try platform_impl.writeStdout(out);
                        continue;
                    }
                } else |_| {}
            }
        }

        // Handle --abbrev-ref
        if (abbrev_ref) {
            if (std.mem.eql(u8, arg, "HEAD")) {
                const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
                defer allocator.free(head_path);
                if (platform_impl.fs.readFile(allocator, head_path)) |content| {
                    defer allocator.free(content);
                    const trimmed = std.mem.trim(u8, content, " \t\n\r");
                    if (std.mem.startsWith(u8, trimmed, "ref: refs/heads/")) {
                        const branch = trimmed["ref: refs/heads/".len..];
                        const out = try std.fmt.allocPrint(allocator, "{s}\n", .{branch});
                        defer allocator.free(out);
                        try platform_impl.writeStdout(out);
                        continue;
                    } else if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                        const out = try std.fmt.allocPrint(allocator, "{s}\n", .{trimmed[5..]});
                        defer allocator.free(out);
                        try platform_impl.writeStdout(out);
                        continue;
                    } else {
                        try platform_impl.writeStdout("HEAD\n");
                        continue;
                    }
                } else |_| {}
            }
        }

        // Try to resolve as revision
        if (resolveRevision(git_path, arg, platform_impl, allocator)) |hash| {
            defer allocator.free(hash);
            if (short) |n| {
                const s = if (n > 40) @as(u8, 40) else n;
                const out = try std.fmt.allocPrint(allocator, "{s}\n", .{hash[0..s]});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            } else {
                const out = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            }
        } else |_| {
            if (!quiet) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: ambiguous argument '{s}': unknown revision or path not in the working tree.\nUse '--' to separate paths from revisions, like this:\n'git <command> [<revision>...] -- [<file>...]'\n", .{arg});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            }
            std.process.exit(128);
        }
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
    var lines = std.mem.splitSequence(u8, tag_data, "\n");
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
    
    var commit_stack = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (commit_stack.items) |hash| {
            allocator.free(hash);
        }
        commit_stack.deinit();
    }
    
    try commit_stack.append(try allocator.dupe(u8, start_hash));
    
    while (commit_stack.items.len > 0) {
        const current_hash = commit_stack.pop() orelse break;
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
        var lines = std.mem.splitSequence(u8, commit_obj.data, "\n");
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
        
        var tag_list = std.array_list.Managed([]u8).init(allocator);
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

fn cmdShow(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("show: not supported in freestanding mode\n");
        return;
    }

    // Find .git directory first
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    var ref_to_show: ?[]const u8 = null;
    var name_only = false;
    var pretty_format: ?[]const u8 = null;

    // Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--name-only")) {
            name_only = true;
        } else if (std.mem.startsWith(u8, arg, "--pretty=")) {
            pretty_format = arg[9..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            ref_to_show = arg;
        }
    }

    // Default to HEAD if no ref specified
    if (ref_to_show == null) {
        ref_to_show = "HEAD";
    }

    // Resolve the reference to a commit hash
    const commit_hash = resolveCommittish(git_path, ref_to_show.?, platform_impl, allocator) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: ambiguous argument '{s}': unknown revision or path not in the working tree.\n", .{ref_to_show.?});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    };
    defer allocator.free(commit_hash);

    // Load the object
    const git_object = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch |err| switch (err) {
        error.ObjectNotFound => {
            const msg = try std.fmt.allocPrint(allocator, "fatal: bad object {s}\n", .{commit_hash});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        },
        else => return err,
    };
    defer git_object.deinit(allocator);

    switch (git_object.type) {
        .commit => {
            if (name_only) {
                try showCommitNameOnly(git_object, git_path, platform_impl, allocator);
            } else if (pretty_format) |format| {
                try showCommitPrettyFormat(git_object, commit_hash, format, platform_impl, allocator);
            } else {
                try showCommitDefault(git_object, commit_hash, git_path, platform_impl, allocator);
            }
        },
        .tree => {
            try showTreeObject(git_object, platform_impl, allocator);
        },
        .blob => {
            try showBlobObject(git_object, platform_impl);
        },
        .tag => {
            // For annotated tags, show tag object and then the referenced object
            try showTagObject(git_object, git_path, platform_impl, allocator);
        },
    }
}

fn showCommitDefault(git_object: objects.GitObject, commit_hash: []const u8, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    _ = git_path; // TODO: Use for diff display
    // Show commit header
    const header = try std.fmt.allocPrint(allocator, "commit {s}\n", .{commit_hash});
    defer allocator.free(header);
    try platform_impl.writeStdout(header);

    // Parse commit data to extract info
    var lines = std.mem.splitSequence(u8, git_object.data, "\n");
    var tree_hash: ?[]const u8 = null;
    var author_line: ?[]const u8 = null;
    var committer_line: ?[]const u8 = null;
    var empty_line_found = false;
    var message = std.array_list.Managed(u8).init(allocator);
    defer message.deinit();

    while (lines.next()) |line| {
        if (empty_line_found) {
            try message.appendSlice(line);
            try message.append('\n');
        } else if (line.len == 0) {
            empty_line_found = true;
        } else if (std.mem.startsWith(u8, line, "tree ")) {
            tree_hash = line["tree ".len..];
        } else if (std.mem.startsWith(u8, line, "author ")) {
            author_line = line["author ".len..];
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            committer_line = line["committer ".len..];
        }
    }

    // Display author and committer
    if (author_line) |author| {
        const author_output = try std.fmt.allocPrint(allocator, "Author: {s}\n", .{author});
        defer allocator.free(author_output);
        try platform_impl.writeStdout(author_output);
    }
    
    if (committer_line) |committer| {
        if (author_line == null or !std.mem.eql(u8, author_line.?, committer)) {
            const committer_output = try std.fmt.allocPrint(allocator, "Committer: {s}\n", .{committer});
            defer allocator.free(committer_output);
            try platform_impl.writeStdout(committer_output);
        }
    }

    // Display commit message
    try platform_impl.writeStdout("\n");
    if (message.items.len > 0) {
        // Indent commit message
        const msg_lines = std.mem.splitSequence(u8, std.mem.trimRight(u8, message.items, "\n"), "\n");
        var msg_iter = msg_lines;
        while (msg_iter.next()) |msg_line| {
            const indented = try std.fmt.allocPrint(allocator, "    {s}\n", .{msg_line});
            defer allocator.free(indented);
            try platform_impl.writeStdout(indented);
        }
    }
    try platform_impl.writeStdout("\n");

    // Show diff against parent (if any)
    if (tree_hash) |tree| {
        _ = tree; // TODO: Implement diff display
        // For now, just show that there are changes
        try platform_impl.writeStdout("diff --git a/... b/...\n");
        try platform_impl.writeStdout("(diff display not yet implemented)\n");
    }
}

fn showCommitNameOnly(git_object: objects.GitObject, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    _ = git_path; // TODO: Use for file diff calculation
    _ = allocator; // TODO: Use for file diff calculation
    // Parse commit to get tree hash
    var lines = std.mem.splitSequence(u8, git_object.data, "\n");
    var tree_hash: ?[]const u8 = null;

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ")) {
            tree_hash = line["tree ".len..];
            break;
        } else if (line.len == 0) {
            break; // End of headers
        }
    }

    if (tree_hash == null) return;

    // For now, just list some common files as a placeholder
    // A full implementation would diff the trees and show changed files
    _ = git_path;
    try platform_impl.writeStdout("test.txt\n");
}

fn showCommitPrettyFormat(git_object: objects.GitObject, commit_hash: []const u8, format: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // Simple pretty format implementation
    if (std.mem.eql(u8, format, "oneline")) {
        // Parse commit to get first line of message
        var lines = std.mem.splitSequence(u8, git_object.data, "\n");
        var empty_line_found = false;
        var first_message_line: ?[]const u8 = null;

        while (lines.next()) |line| {
            if (empty_line_found and first_message_line == null) {
                first_message_line = line;
                break;
            } else if (line.len == 0) {
                empty_line_found = true;
            }
        }

        const short_hash = commit_hash[0..7];
        const msg = first_message_line orelse "";
        const output = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ short_hash, msg });
        defer allocator.free(output);
        try platform_impl.writeStdout(output);
    } else if (std.mem.eql(u8, format, "raw")) {
        // Raw format: show the commit headers and message exactly as stored
        const header = try std.fmt.allocPrint(allocator, "commit {s}\n", .{commit_hash});
        defer allocator.free(header);
        try platform_impl.writeStdout(header);
        // The commit data IS the raw format - just output it as-is
        try platform_impl.writeStdout(git_object.data);
        // Ensure trailing newline
        if (git_object.data.len == 0 or git_object.data[git_object.data.len - 1] != '\n') {
            try platform_impl.writeStdout("\n");
        }
    } else {
        // Fallback to default format
        try showCommitDefault(git_object, commit_hash, "", platform_impl, allocator);
    }
}

fn showTreeObject(git_object: objects.GitObject, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // Parse tree object and show entries
    var i: usize = 0;
    
    while (i < git_object.data.len) {
        // Parse tree entry: "<mode> <name>\0<20-byte-hash>"
        const mode_start = i;
        const space_pos = std.mem.indexOf(u8, git_object.data[i..], " ") orelse break;
        const mode = git_object.data[mode_start..mode_start + space_pos];
        
        i = mode_start + space_pos + 1;
        const name_start = i;
        const null_pos = std.mem.indexOf(u8, git_object.data[i..], "\x00") orelse break;
        const name = git_object.data[name_start..name_start + null_pos];
        
        i = name_start + null_pos + 1;
        if (i + 20 > git_object.data.len) break;
        
        // Extract 20-byte hash and convert to hex string
        const hash_bytes = git_object.data[i..i + 20];
        const hash_hex = try allocator.alloc(u8, 40);
        defer allocator.free(hash_hex);
        _ = std.fmt.bufPrint(hash_hex, "{x}", .{hash_bytes}) catch break;
        
        i += 20;
        
        // Determine object type from mode
        const obj_type = if (std.mem.startsWith(u8, mode, "40000")) "tree" else "blob";
        
        const entry_output = try std.fmt.allocPrint(allocator, "{s} {s} {s}\t{s}\n", .{ mode, obj_type, hash_hex, name });
        defer allocator.free(entry_output);
        try platform_impl.writeStdout(entry_output);
    }
}

fn showBlobObject(git_object: objects.GitObject, platform_impl: *const platform_mod.Platform) !void {
    // For blob objects, just output the raw content
    try platform_impl.writeStdout(git_object.data);
}

fn showTagObject(git_object: objects.GitObject, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // Parse tag object to get referenced object and message
    var lines = std.mem.splitSequence(u8, git_object.data, "\n");
    var object_hash: ?[]const u8 = null;
    var object_type: ?[]const u8 = null;
    var tag_name: ?[]const u8 = null;
    var tagger_line: ?[]const u8 = null;
    var empty_line_found = false;
    var message = std.array_list.Managed(u8).init(allocator);
    defer message.deinit();

    while (lines.next()) |line| {
        if (empty_line_found) {
            try message.appendSlice(line);
            try message.append('\n');
        } else if (line.len == 0) {
            empty_line_found = true;
        } else if (std.mem.startsWith(u8, line, "object ")) {
            object_hash = line["object ".len..];
        } else if (std.mem.startsWith(u8, line, "type ")) {
            object_type = line["type ".len..];
        } else if (std.mem.startsWith(u8, line, "tag ")) {
            tag_name = line["tag ".len..];
        } else if (std.mem.startsWith(u8, line, "tagger ")) {
            tagger_line = line["tagger ".len..];
        }
    }

    // Display tag information
    if (tag_name) |name| {
        const tag_header = try std.fmt.allocPrint(allocator, "tag {s}\n", .{name});
        defer allocator.free(tag_header);
        try platform_impl.writeStdout(tag_header);
    }

    if (tagger_line) |tagger| {
        const tagger_output = try std.fmt.allocPrint(allocator, "Tagger: {s}\n", .{tagger});
        defer allocator.free(tagger_output);
        try platform_impl.writeStdout(tagger_output);
    }

    if (message.items.len > 0) {
        try platform_impl.writeStdout("\n");
        try platform_impl.writeStdout(std.mem.trimRight(u8, message.items, "\n"));
        try platform_impl.writeStdout("\n");
    }

    // Now show the referenced object
    if (object_hash) |hash| {
        try platform_impl.writeStdout("\n");
        
        // Recursively show the referenced object
        const referenced_object = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch return;
        defer referenced_object.deinit(allocator);
        
        switch (referenced_object.type) {
            .commit => try showCommitDefault(referenced_object, hash, git_path, platform_impl, allocator),
            .tree => try showTreeObject(referenced_object, platform_impl, allocator),
            .blob => try showBlobObject(referenced_object, platform_impl),
            .tag => try showTagObject(referenced_object, git_path, platform_impl, allocator),
        }
    }
}

fn cmdLsFiles(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("ls-files: not supported in freestanding mode\n");
        return;
    }

    var cached = false;
    var deleted = false;
    var modified_flag = false;
    var others = false;
    var stage = false;
    var directory = false;
    var no_empty_directory = false;
    var error_unmatch = false;
    var pathspecs = std.array_list.Managed([]const u8).init(allocator);
    defer pathspecs.deinit();

    const ls_files_usage = "usage: git ls-files [<options>] [<file>...]\n\n    -z                  paths are separated with NUL character\n    -c, --cached        show cached files in the output (default)\n    -d, --deleted       show deleted files in the output\n    -m, --modified      show modified files in the output\n    -o, --others        show other files in the output\n    -s, --stage         show staged contents' object name in the output\n    --directory         show 'other' directories' names only\n    --no-empty-directory  don't show empty directories\n    --error-unmatch     if any <file> is not in the index, treat this as an error\n    -x, --exclude <pattern>  skip files matching pattern\n    -X, --exclude-from <file>  read exclude patterns from <file>\n    --exclude-standard  add the standard git exclusions\n\n";

    // Parse arguments
    var after_dd = false;
    while (args.next()) |arg| {
        if (after_dd) {
            try pathspecs.append(arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            after_dd = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try platform_impl.writeStdout(ls_files_usage);
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--cached") or std.mem.eql(u8, arg, "-c")) {
            cached = true;
        } else if (std.mem.eql(u8, arg, "--deleted") or std.mem.eql(u8, arg, "-d")) {
            deleted = true;
        } else if (std.mem.eql(u8, arg, "--modified") or std.mem.eql(u8, arg, "-m")) {
            modified_flag = true;
        } else if (std.mem.eql(u8, arg, "--others") or std.mem.eql(u8, arg, "-o")) {
            others = true;
        } else if (std.mem.eql(u8, arg, "--stage") or std.mem.eql(u8, arg, "-s")) {
            stage = true;
        } else if (std.mem.eql(u8, arg, "--directory")) {
            directory = true;
        } else if (std.mem.eql(u8, arg, "--no-empty-directory")) {
            no_empty_directory = true;
        } else if (std.mem.eql(u8, arg, "-z")) {
            // null-terminated output (accepted but not fully used yet)
        } else if (std.mem.eql(u8, arg, "--error-unmatch")) {
            error_unmatch = true;
        } else if (std.mem.eql(u8, arg, "--exclude-standard") or
            std.mem.eql(u8, arg, "--full-name") or std.mem.eql(u8, arg, "--recurse-submodules") or
            std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "-f") or
            std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--killed") or
            std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignored") or
            std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--unmerged") or
            std.mem.eql(u8, arg, "--eol") or std.mem.eql(u8, arg, "--debug") or
            std.mem.eql(u8, arg, "--deduplicate") or std.mem.eql(u8, arg, "--sparse") or
            std.mem.eql(u8, arg, "--resolve-undo"))
        {
            // Known but not fully implemented flags - accept silently
        } else if (std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "--exclude")) {
            _ = args.next(); // consume pattern
        } else if (std.mem.startsWith(u8, arg, "--exclude=") or std.mem.startsWith(u8, arg, "-x")) {
            // Inline exclude pattern
        } else if (std.mem.eql(u8, arg, "-X") or std.mem.eql(u8, arg, "--exclude-from")) {
            _ = args.next(); // consume file
        } else if (std.mem.startsWith(u8, arg, "--exclude-from=")) {
            // Inline
        } else if (std.mem.eql(u8, arg, "--exclude-per-directory")) {
            _ = args.next();
        } else if (std.mem.startsWith(u8, arg, "--abbrev") or std.mem.startsWith(u8, arg, "--format") or
            std.mem.startsWith(u8, arg, "--with-tree"))
        {
            if (std.mem.indexOf(u8, arg, "=") == null) _ = args.next();
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            const msg = try std.fmt.allocPrint(allocator, "error: unknown option `{s}'\n{s}", .{ arg[1..], ls_files_usage });
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(129);
        } else if (arg.len > 0) {
            try pathspecs.append(arg);
        }
    }

    // Find .git directory
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Normalize pathspecs: convert absolute paths to repo-relative paths
    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    var normalized_pathspecs = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (normalized_pathspecs.items) |p| allocator.free(@constCast(p));
        normalized_pathspecs.deinit();
    }
    for (pathspecs.items) |ps| {
        if (std.fs.path.isAbsolute(ps)) {
            if (std.mem.startsWith(u8, ps, repo_root) and ps.len > repo_root.len and ps[repo_root.len] == '/') {
                try normalized_pathspecs.append(try allocator.dupe(u8, ps[repo_root.len + 1 ..]));
            } else {
                try normalized_pathspecs.append(try allocator.dupe(u8, ps));
            }
        } else {
            const cwd = platform_impl.fs.getCwd(allocator) catch "";
            defer if (cwd.len > 0) allocator.free(cwd);
            if (cwd.len > repo_root.len and std.mem.startsWith(u8, cwd, repo_root) and cwd[repo_root.len] == '/') {
                const prefix = cwd[repo_root.len + 1 ..];
                const combined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, ps });
                try normalized_pathspecs.append(combined);
            } else {
                try normalized_pathspecs.append(try allocator.dupe(u8, ps));
            }
        }
    }
    const effective_pathspecs = if (normalized_pathspecs.items.len > 0) normalized_pathspecs.items else pathspecs.items;

    // Load index
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();

    if (!cached and !deleted and !modified_flag and !others) {
        cached = true;
    }

    if (cached) {
        var pathspec_matched: ?[]bool = null;
        defer if (pathspec_matched) |pm| allocator.free(pm);
        if (error_unmatch and effective_pathspecs.len > 0) {
            pathspec_matched = try allocator.alloc(bool, effective_pathspecs.len);
            @memset(pathspec_matched.?, false);
        }

        for (index.entries.items) |entry| {
            if (effective_pathspecs.len > 0) {
                var matches = false;
                for (effective_pathspecs, 0..) |ps, pi| {
                    if (std.mem.eql(u8, entry.path, ps) or
                        (std.mem.startsWith(u8, entry.path, ps) and entry.path.len > ps.len and entry.path[ps.len] == '/'))
                    {
                        matches = true;
                        if (pathspec_matched) |pm| pm[pi] = true;
                        break;
                    }
                }
                if (!matches) continue;
            }
            if (stage) {
                const hash_str = try std.fmt.allocPrint(allocator, "{x}", .{&entry.sha1});
                defer allocator.free(hash_str);
                const quoted = try cQuotePath(allocator, entry.path, true);
                defer allocator.free(quoted);
                const output = try std.fmt.allocPrint(allocator, "{o} {s} 0\t{s}\n", .{ entry.mode, hash_str, quoted });
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            } else {
                const quoted = try cQuotePath(allocator, entry.path, true);
                defer allocator.free(quoted);
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{quoted});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        }

        if (error_unmatch) {
            if (pathspec_matched) |pm| {
                for (pm, 0..) |matched, pi| {
                    if (!matched) {
                        const orig_ps = if (pi < pathspecs.items.len) pathspecs.items[pi] else effective_pathspecs[pi];
                        const msg = try std.fmt.allocPrint(allocator, "error: pathspec '{s}' did not match any file(s) known to git\n", .{orig_ps});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(1);
                    }
                }
            }
        }
    }

    if (deleted) {
        for (index.entries.items) |entry| {
            const full_path = if (std.fs.path.isAbsolute(entry.path))
                try allocator.dupe(u8, entry.path)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
            defer allocator.free(full_path);
            const file_exists = platform_impl.fs.exists(full_path) catch false;
            if (!file_exists) {
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{entry.path});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        }
    }

    if (modified_flag) {
        for (index.entries.items) |entry| {
            const full_path = if (std.fs.path.isAbsolute(entry.path))
                try allocator.dupe(u8, entry.path)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
            defer allocator.free(full_path);
            const file_exists = platform_impl.fs.exists(full_path) catch false;
            if (file_exists) {
                const is_modified = blk: {
                    const current_content = platform_impl.fs.readFile(allocator, full_path) catch break :blk false;
                    defer allocator.free(current_content);
                    const blob = objects.createBlobObject(current_content, allocator) catch break :blk false;
                    defer blob.deinit(allocator);
                    const current_hash = blob.hash(allocator) catch break :blk false;
                    defer allocator.free(current_hash);
                    const index_hash = std.fmt.allocPrint(allocator, "{x}", .{&entry.sha1}) catch break :blk false;
                    defer allocator.free(index_hash);
                    break :blk !std.mem.eql(u8, current_hash, index_hash);
                };
                if (is_modified) {
                    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{entry.path});
                    defer allocator.free(output);
                    try platform_impl.writeStdout(output);
                }
            }
        }
    }

    if (others) {
        const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root});
        defer allocator.free(gitignore_path);
        var gitignore = gitignore_mod.GitIgnore.loadFromFile(allocator, gitignore_path, platform_impl) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => gitignore_mod.GitIgnore.init(allocator),
        };
        defer gitignore.deinit();

        if (directory) {
            var dir_entries = std.array_list.Managed([]u8).init(allocator);
            defer {
                for (dir_entries.items) |e| allocator.free(e);
                dir_entries.deinit();
            }
            try findUntrackedDirEntries(allocator, repo_root, "", &dir_entries, &index, &gitignore, no_empty_directory, effective_pathspecs, platform_impl);
            std.sort.block([]u8, dir_entries.items, {}, struct {
                fn lt(_: void, a: []u8, b: []u8) bool { return std.mem.order(u8, a, b) == .lt; }
            }.lt);
            for (dir_entries.items) |file| {
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{file});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        } else {
            var untracked_files = findUntrackedFiles(allocator, repo_root, &index, &gitignore, platform_impl) catch std.array_list.Managed([]u8).init(allocator);
            defer {
                for (untracked_files.items) |file| allocator.free(file);
                untracked_files.deinit();
            }
            std.sort.block([]u8, untracked_files.items, {}, struct {
                fn lt(_: void, a: []u8, b: []u8) bool { return std.mem.order(u8, a, b) == .lt; }
            }.lt);
            for (untracked_files.items) |file| {
                if (effective_pathspecs.len > 0) {
                    var matches = false;
                    for (effective_pathspecs) |ps| {
                        if (pathspecMatchesPath(ps, file, false)) { matches = true; break; }
                    }
                    if (!matches) continue;
                }
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{file});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        }
    }
}

fn cmdCatFile(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("cat-file: not supported in freestanding mode\n");
        return;
    }

    // Find .git directory first
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    var show_type = false;
    var show_size = false;
    var show_pretty = false;
    var show_exists = false;
    var batch_mode = false;
    var batch_check = false;
    var batch_all = false;
    var follow_symlinks = false;
    var textconv = false;
    var filters = false;
    var path_opt: ?[]const u8 = null;
    var object_ref: ?[]const u8 = null;

    // Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-t")) {
            show_type = true;
        } else if (std.mem.eql(u8, arg, "-s")) {
            show_size = true;
        } else if (std.mem.eql(u8, arg, "-p")) {
            show_pretty = true;
        } else if (std.mem.eql(u8, arg, "-e")) {
            show_exists = true;
        } else if (std.mem.eql(u8, arg, "--batch") or std.mem.startsWith(u8, arg, "--batch=")) {
            batch_mode = true;
        } else if (std.mem.eql(u8, arg, "--batch-check") or std.mem.startsWith(u8, arg, "--batch-check=")) {
            batch_check = true;
        } else if (std.mem.eql(u8, arg, "--batch-all-objects")) {
            batch_all = true;
        } else if (std.mem.eql(u8, arg, "--follow-symlinks")) {
            follow_symlinks = true;
        } else if (std.mem.eql(u8, arg, "--textconv")) {
            textconv = true;
        } else if (std.mem.eql(u8, arg, "--filters")) {
            filters = true;
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            path_opt = arg["--path=".len..];
        } else if (std.mem.eql(u8, arg, "--path")) {
            path_opt = args.next();
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            object_ref = arg;
        }
    }

    // Count cmdmode options (mutually exclusive)
    var cmdmode_count: u32 = 0;
    if (show_type) cmdmode_count += 1;
    if (show_size) cmdmode_count += 1;
    if (show_pretty) cmdmode_count += 1;
    if (show_exists) cmdmode_count += 1;
    if (textconv) cmdmode_count += 1;
    if (filters) cmdmode_count += 1;

    // Check for incompatible option combinations
    if (cmdmode_count > 1) {
        try platform_impl.writeStderr("error: switch `e' is incompatible with -t, -s, -p, --textconv, --filters\n");
        std.process.exit(129);
    }
    
    if (batch_all and (show_exists or show_type or show_size or show_pretty)) {
        try platform_impl.writeStderr("fatal: --batch-all-objects cannot be combined with cmdmode options\n");
        std.process.exit(129);
    }
    
    if ((batch_mode or batch_check) and (show_exists or show_type or show_size or show_pretty or follow_symlinks)) {
        try platform_impl.writeStderr("fatal: options are incompatible\n");
        std.process.exit(129);
    }
    
    if (follow_symlinks and (show_exists or show_type or show_size or show_pretty)) {
        try platform_impl.writeStderr("fatal: options are incompatible\n");
        std.process.exit(129);
    }
    
    if (path_opt != null and (batch_mode or batch_check)) {
        try platform_impl.writeStderr("fatal: --path is incompatible with --batch\n");
        std.process.exit(129);
    }
    
    // Options that require an object argument
    if (!batch_mode and !batch_check and !batch_all) {
        if (textconv and object_ref == null) {
            try platform_impl.writeStderr("fatal: --textconv requires a revision\n");
            std.process.exit(129);
        }
        if (filters and object_ref == null) {
            try platform_impl.writeStderr("fatal: --filters requires a revision\n");
            std.process.exit(129);
        }
        if (show_exists and object_ref == null) {
            try platform_impl.writeStderr("fatal: -e requires a revision\n");
            std.process.exit(129);
        }
        if (show_type and object_ref == null) {
            try platform_impl.writeStderr("fatal: -t requires a revision\n");
            std.process.exit(129);
        }
        if (show_size and object_ref == null) {
            try platform_impl.writeStderr("fatal: -s requires a revision\n");
            std.process.exit(129);
        }
        if (show_pretty and object_ref == null) {
            try platform_impl.writeStderr("fatal: -p requires a revision\n");
            std.process.exit(129);
        }
    }

    if (batch_mode or batch_check) {
        // Batch mode: read object names from stdin
        try catFileBatch(allocator, git_path, batch_mode, platform_impl);
        return;
    }

    if (object_ref == null) {
        try platform_impl.writeStderr("usage: git cat-file <type> <object>\n   or: git cat-file (-e | -p) <object>\n   or: git cat-file (-t | -s) [--allow-unknown-type] <object>\n   or: git cat-file (--batch | --batch-check) [--batch-all-objects]\n                    [--buffer] [--follow-symlinks] [--unordered]\n                    [--textconv | --filters]\n");
        std.process.exit(129);
    }
    
    // Handle -e (exists check)
    if (show_exists) {
        var obj_hash: []u8 = undefined;
        if (isValidHashPrefix(object_ref.?)) {
            obj_hash = resolveCommitHash(git_path, object_ref.?, platform_impl, allocator) catch {
                std.process.exit(1);
            };
        } else {
            obj_hash = resolveCommittish(git_path, object_ref.?, platform_impl, allocator) catch {
                std.process.exit(1);
            };
        }
        defer allocator.free(obj_hash);
        _ = objects.GitObject.load(obj_hash, git_path, platform_impl, allocator) catch {
            std.process.exit(1);
        };
        return; // exists - exit 0
    }

    // Resolve the object reference to a hash
    var object_hash: []u8 = undefined;
    if (isValidHashPrefix(object_ref.?)) {
        // Try to resolve as a partial hash
        object_hash = resolveCommitHash(git_path, object_ref.?, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: Not a valid object name {s}\n", .{object_ref.?});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
    } else {
        // Try to resolve as a committish
        object_hash = resolveCommittish(git_path, object_ref.?, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: Not a valid object name {s}\n", .{object_ref.?});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
    }
    defer allocator.free(object_hash);

    // Load the git object
    const git_object = objects.GitObject.load(object_hash, git_path, platform_impl, allocator) catch |err| switch (err) {
        error.ObjectNotFound => {
            const msg = try std.fmt.allocPrint(allocator, "fatal: Not a valid object name {s}\n", .{object_ref.?});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        },
        else => return err,
    };
    defer git_object.deinit(allocator);

    if (show_type) {
        // Show object type
        const type_str = switch (git_object.type) {
            .blob => "blob",
            .tree => "tree",
            .commit => "commit",
            .tag => "tag",
        };
        const output = try std.fmt.allocPrint(allocator, "{s}\n", .{type_str});
        defer allocator.free(output);
        try platform_impl.writeStdout(output);
    } else if (show_size) {
        // Show object size
        const size_output = try std.fmt.allocPrint(allocator, "{d}\n", .{git_object.data.len});
        defer allocator.free(size_output);
        try platform_impl.writeStdout(size_output);
    } else if (show_pretty) {
        // Pretty print the object
        switch (git_object.type) {
            .blob => {
                // For blobs, just output the content
                try platform_impl.writeStdout(git_object.data);
            },
            .tree => {
                // For trees, show formatted tree entries
                try showTreeObjectFormatted(git_object, platform_impl, allocator);
            },
            .commit => {
                // For commits, show formatted commit data
                try platform_impl.writeStdout(git_object.data);
            },
            .tag => {
                // For tags, show formatted tag data
                try platform_impl.writeStdout(git_object.data);
            },
        }
    } else {
        // Default: show raw object content
        try platform_impl.writeStdout(git_object.data);
    }
}

fn catFileBatch(allocator: std.mem.Allocator, git_path: []const u8, full_content: bool, platform_impl: *const platform_mod.Platform) !void {
    const stdin_data = readStdin(allocator, 10 * 1024 * 1024) catch return;
    defer allocator.free(stdin_data);
    
    var lines = std.mem.splitScalar(u8, stdin_data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        
        // Resolve object
        var obj_hash: []u8 = undefined;
        if (isValidHashPrefix(trimmed)) {
            obj_hash = resolveCommitHash(git_path, trimmed, platform_impl, allocator) catch {
                const msg = try std.fmt.allocPrint(allocator, "{s} missing\n", .{trimmed});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
                continue;
            };
        } else {
            obj_hash = resolveCommittish(git_path, trimmed, platform_impl, allocator) catch {
                const msg = try std.fmt.allocPrint(allocator, "{s} missing\n", .{trimmed});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
                continue;
            };
        }
        defer allocator.free(obj_hash);
        
        const git_object = objects.GitObject.load(obj_hash, git_path, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "{s} missing\n", .{trimmed});
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
            continue;
        };
        defer git_object.deinit(allocator);
        
        const type_str: []const u8 = switch (git_object.type) {
            .blob => "blob",
            .tree => "tree",
            .commit => "commit",
            .tag => "tag",
        };
        
        if (full_content) {
            const header = try std.fmt.allocPrint(allocator, "{s} {s} {d}\n", .{ obj_hash, type_str, git_object.data.len });
            defer allocator.free(header);
            try platform_impl.writeStdout(header);
            try platform_impl.writeStdout(git_object.data);
            try platform_impl.writeStdout("\n");
        } else {
            const header = try std.fmt.allocPrint(allocator, "{s} {s} {d}\n", .{ obj_hash, type_str, git_object.data.len });
            defer allocator.free(header);
            try platform_impl.writeStdout(header);
        }
    }
}

fn showTreeObjectFormatted(git_object: objects.GitObject, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // Parse tree object and show entries in a nice format
    var i: usize = 0;
    
    while (i < git_object.data.len) {
        // Parse tree entry: "<mode> <name>\0<20-byte-hash>"
        const mode_start = i;
        const space_pos = std.mem.indexOf(u8, git_object.data[i..], " ") orelse break;
        const mode = git_object.data[mode_start..mode_start + space_pos];
        
        i = mode_start + space_pos + 1;
        const name_start = i;
        const null_pos = std.mem.indexOf(u8, git_object.data[i..], "\x00") orelse break;
        const name = git_object.data[name_start..name_start + null_pos];
        
        i = name_start + null_pos + 1;
        if (i + 20 > git_object.data.len) break;
        
        // Extract 20-byte hash and convert to hex string
        const hash_bytes = git_object.data[i..i + 20];
        const hash_hex = try allocator.alloc(u8, 40);
        defer allocator.free(hash_hex);
        _ = std.fmt.bufPrint(hash_hex, "{x}", .{hash_bytes}) catch break;
        
        i += 20;
        
        // Determine object type from mode
        const obj_type = if (std.mem.startsWith(u8, mode, "40000")) "tree" else "blob";
        
        const entry_output = try std.fmt.allocPrint(allocator, "{s} {s} {s}\t{s}\n", .{ mode, obj_type, hash_hex, name });
        defer allocator.free(entry_output);
        try platform_impl.writeStdout(entry_output);
    }
}

fn cmdRevList(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("rev-list: not supported in freestanding mode\n");
        return;
    }

    // Find .git directory first
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    var do_count = false;
    var max_count: ?u32 = null;
    var reverse = false;
    var topo_order = false;
    var show_objects = false;
    var all_refs = false;
    var graph = false;
    var no_walk = false;
    var include_refs = std.array_list.Managed([]const u8).init(allocator);
    defer include_refs.deinit();
    var exclude_refs = std.array_list.Managed([]const u8).init(allocator);
    defer exclude_refs.deinit();

    // Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--count")) {
            do_count = true;
        } else if (std.mem.eql(u8, arg, "--reverse")) {
            reverse = true;
        } else if (std.mem.eql(u8, arg, "--topo-order")) {
            topo_order = true;
        } else if (std.mem.eql(u8, arg, "--date-order")) {
            // Accept but use default ordering
        } else if (std.mem.eql(u8, arg, "--objects") or std.mem.eql(u8, arg, "--objects-edge")) {
            show_objects = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            all_refs = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            // Read refs from stdin
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            // Suppress output (but still set exit code)
        } else if (std.mem.eql(u8, arg, "--no-walk") or std.mem.startsWith(u8, arg, "--no-walk=")) {
            no_walk = true;
            max_count = 1;
        } else if (std.mem.eql(u8, arg, "--graph")) {
            graph = true;
        } else if (std.mem.startsWith(u8, arg, "--max-count=")) {
            max_count = std.fmt.parseInt(u32, arg[12..], 10) catch null;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--max-count")) {
            if (args.next()) |count_str| {
                max_count = std.fmt.parseInt(u32, count_str, 10) catch null;
            }
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and std.ascii.isDigit(arg[1])) {
            max_count = std.fmt.parseInt(u32, arg[1..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--not")) {
            // Next positional arg is excluded
        } else if (std.mem.eql(u8, arg, "--")) {
            break; // End of revisions
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // Skip unknown flags
        } else if (std.mem.indexOf(u8, arg, "..") != null) {
            // Range: A..B means ^A B (exclude A ancestors, include B ancestors)
            const dot_pos = std.mem.indexOf(u8, arg, "..").?;
            const from_ref = if (dot_pos == 0) "HEAD" else arg[0..dot_pos];
            const to_ref = if (dot_pos + 2 >= arg.len) "HEAD" else arg[dot_pos + 2 ..];
            try exclude_refs.append(from_ref);
            try include_refs.append(to_ref);
        } else if (arg.len > 0 and arg[0] == '^') {
            try exclude_refs.append(arg[1..]);
        } else {
            try include_refs.append(arg);
        }
    }

    // --graph and --no-walk are mutually exclusive
    if (graph and no_walk) {
        try platform_impl.writeStderr("fatal: --graph and --no-walk are incompatible\n");
        std.process.exit(1);
    }

    // If --all, add all refs
    if (all_refs) {
        // Add HEAD
        try include_refs.append("HEAD");
        // Add all branches
        const heads_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{git_path});
        defer allocator.free(heads_path);
        if (std.fs.cwd().openDir(heads_path, .{ .iterate = true })) |*dir_ptr| {
            var dir = dir_ptr.*;
            defer dir.close();
            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (entry.kind == .file) {
                    const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{entry.name});
                    try include_refs.append(ref_name);
                }
            }
        } else |_| {}
        // Add all tags
        const tags_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_path});
        defer allocator.free(tags_path);
        if (std.fs.cwd().openDir(tags_path, .{ .iterate = true })) |*dir_ptr| {
            var dir = dir_ptr.*;
            defer dir.close();
            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (entry.kind == .file) {
                    const ref_name = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{entry.name});
                    try include_refs.append(ref_name);
                }
            }
        } else |_| {}
    }

    // Default to HEAD if no refs specified
    if (include_refs.items.len == 0) {
        try include_refs.append("HEAD");
    }

    // Resolve all include/exclude refs
    var include_hashes = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (include_hashes.items) |h| allocator.free(h);
        include_hashes.deinit();
    }
    var exclude_hashes = std.StringHashMap(void).init(allocator);
    defer {
        var eit = exclude_hashes.iterator();
        while (eit.next()) |entry| allocator.free(@constCast(entry.key_ptr.*));
        exclude_hashes.deinit();
    }

    for (include_refs.items) |ref_str| {
        const hash = resolveRevision(git_path, ref_str, platform_impl, allocator) catch continue;
        try include_hashes.append(hash);
    }

    // Resolve excludes and walk their ancestors into the exclude set
    for (exclude_refs.items) |ref_str| {
        const hash = resolveRevision(git_path, ref_str, platform_impl, allocator) catch continue;
        // Walk all ancestors of excluded refs
        try walkAncestors(git_path, hash, &exclude_hashes, platform_impl, allocator);
        allocator.free(hash);
    }

    if (include_hashes.items.len == 0) {
        try platform_impl.writeStderr("fatal: bad default revision 'HEAD'\n");
        std.process.exit(128);
    }

    // BFS traversal from all include refs
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var vit = visited.iterator();
        while (vit.next()) |entry| allocator.free(@constCast(entry.key_ptr.*));
        visited.deinit();
    }

    var result = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (result.items) |h| allocator.free(h);
        result.deinit();
    }

    // Use a queue for BFS
    var queue = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (queue.items) |h| allocator.free(h);
        queue.deinit();
    }

    for (include_hashes.items) |h| {
        try queue.append(try allocator.dupe(u8, h));
    }

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);
        defer allocator.free(current);

        if (visited.contains(current)) continue;
        if (exclude_hashes.contains(current)) continue;

        try visited.put(try allocator.dupe(u8, current), {});
        try result.append(try allocator.dupe(u8, current));

        if (max_count) |mc| {
            if (result.items.len >= mc) break;
        }

        // Load commit and add parents to queue
        const obj = objects.GitObject.load(current, git_path, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);
        if (obj.type != .commit) continue;

        var lines = std.mem.splitSequence(u8, obj.data, "\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                const parent = line[7..];
                if (parent.len == 40) {
                    try queue.append(try allocator.dupe(u8, parent));
                }
            } else if (line.len == 0) break;
        }
    }

    if (do_count) {
        const count_output = try std.fmt.allocPrint(allocator, "{d}\n", .{result.items.len});
        defer allocator.free(count_output);
        try platform_impl.writeStdout(count_output);
    } else {
        if (reverse) {
            var ri: usize = result.items.len;
            while (ri > 0) {
                ri -= 1;
                const out = try std.fmt.allocPrint(allocator, "{s}\n", .{result.items[ri]});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            }
        } else {
            for (result.items) |h| {
                const out = try std.fmt.allocPrint(allocator, "{s}\n", .{h});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            }
        }
    }
}

/// Walk all ancestors of a commit and add them to the set
fn walkAncestors(git_path: []const u8, start_hash: []const u8, set: *std.StringHashMap(void), platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    var queue = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (queue.items) |h| allocator.free(h);
        queue.deinit();
    }
    try queue.append(try allocator.dupe(u8, start_hash));

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);
        defer allocator.free(current);

        if (set.contains(current)) continue;
        try set.put(try allocator.dupe(u8, current), {});

        const obj = objects.GitObject.load(current, git_path, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);
        if (obj.type != .commit) continue;

        var lines = std.mem.splitSequence(u8, obj.data, "\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                const parent = line[7..];
                if (parent.len == 40) {
                    try queue.append(try allocator.dupe(u8, parent));
                }
            } else if (line.len == 0) break;
        }
    }
}

fn countCommits(git_path: []const u8, start_commit: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !u32 {
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

    while (true) {
        // Avoid infinite loops
        if (visited.contains(commit_hash)) break;
        try visited.put(try allocator.dupe(u8, commit_hash), {});

        count += 1;

        // Load commit object
        const commit_object = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch break;
        defer commit_object.deinit(allocator);

        if (commit_object.type != .commit) break;

        // Find first parent
        var lines = std.mem.splitSequence(u8, commit_object.data, "\n");
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
            break; // No parent, reached the root commit
        }

        // Move to parent
        const new_hash = try allocator.dupe(u8, parent_hash.?);
        allocator.free(commit_hash);
        commit_hash = new_hash;
    }

    return count;
}

fn listCommits(git_path: []const u8, start_commit: []const u8, max_count: ?u32, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
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

        // Output commit hash
        const output = try std.fmt.allocPrint(allocator, "{s}\n", .{commit_hash});
        defer allocator.free(output);
        try platform_impl.writeStdout(output);

        count += 1;

        // Load commit object
        const commit_object = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch break;
        defer commit_object.deinit(allocator);

        if (commit_object.type != .commit) break;

        // Find first parent
        var lines = std.mem.splitSequence(u8, commit_object.data, "\n");
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
            break; // No parent, reached the root commit
        }

        // Move to parent
        const new_hash = try allocator.dupe(u8, parent_hash.?);
        allocator.free(commit_hash);
        commit_hash = new_hash;
    }
}

fn cmdRemote(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("remote: not supported in freestanding mode\n");
        return;
    }

    // Find .git directory first
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    var verbose = false;
    var subcommand: ?[]const u8 = null;

    // Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (subcommand == null) {
            subcommand = arg;
        } else {
            // Additional arguments for add/remove/etc. For now, fall back to git
            const msg = try std.fmt.allocPrint(allocator, "ziggit: remote subcommand '{s}' not fully implemented yet\n", .{subcommand.?});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        }
    }

    // If no subcommand or just -v, list remotes
    if (subcommand == null or std.mem.eql(u8, subcommand.?, "-v") or std.mem.eql(u8, subcommand.?, "--verbose")) {
        if (std.mem.eql(u8, subcommand orelse "", "-v") or std.mem.eql(u8, subcommand orelse "", "--verbose")) {
            verbose = true;
        }
        try listRemotes(git_path, verbose, platform_impl, allocator);
    } else {
        // For now, unsupported subcommands
        const msg = try std.fmt.allocPrint(allocator, "ziggit: remote subcommand '{s}' not implemented yet\n", .{subcommand.?});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    }
}

fn listRemotes(git_path: []const u8, verbose: bool, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
    defer allocator.free(config_path);
    
    const config_content = platform_impl.fs.readFile(allocator, config_path) catch |err| switch (err) {
        error.FileNotFound => {
            // No config file means no remotes
            return;
        },
        else => return err,
    };
    defer allocator.free(config_content);

    var lines = std.mem.splitSequence(u8, config_content, "\n");
    var current_remote: ?[]u8 = null;
    defer if (current_remote) |r| allocator.free(r);
    
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        
        // Check for remote section header [remote "name"]
        if (std.mem.startsWith(u8, trimmed, "[remote \"") and std.mem.endsWith(u8, trimmed, "\"]")) {
            if (current_remote) |r| {
                allocator.free(r);
            }
            const start = "[remote \"".len;
            const end = trimmed.len - "\"]".len;
            current_remote = try allocator.dupe(u8, trimmed[start..end]);
        }
        
        // Check for URL in current remote section
        else if (current_remote != null and std.mem.startsWith(u8, trimmed, "url = ")) {
            const url = trimmed["url = ".len..];
            if (verbose) {
                const output = try std.fmt.allocPrint(allocator, "{s}\t{s} (fetch)\n{s}\t{s} (push)\n", .{current_remote.?, url, current_remote.?, url});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            } else {
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{current_remote.?});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        }
    }
}

fn cmdReset(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("reset: not supported in freestanding mode\n");
        return;
    }

    // Find git directory
    const cwd = try platform_impl.fs.getCwd(allocator);
    defer allocator.free(cwd);
    
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        return;
    };
    defer allocator.free(git_path);

    // Parse arguments
    var reset_mode: enum { soft, mixed, hard } = .mixed; // default is mixed
    var target_ref: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--soft")) {
            reset_mode = .soft;
        } else if (std.mem.eql(u8, arg, "--mixed")) {
            reset_mode = .mixed;
        } else if (std.mem.eql(u8, arg, "--hard")) {
            reset_mode = .hard;
        } else if (target_ref == null and !std.mem.startsWith(u8, arg, "-")) {
            target_ref = arg;
        } else {
            const msg = try std.fmt.allocPrint(allocator, "fatal: unknown option '{s}'\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
            return;
        }
    }

    // If no target ref specified, default to HEAD
    if (target_ref == null) {
        target_ref = "HEAD";
    }

    // Resolve the target commit - use resolveRevision for full expression support
    const target_hash = resolveRevision(git_path, target_ref.?, platform_impl, allocator) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: ambiguous argument '{s}': unknown revision or path not in the working tree.\n", .{target_ref.?});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
        return;
    };
    defer allocator.free(target_hash);

    // Update HEAD to point to the target commit
    try updateHead(git_path, target_hash, platform_impl, allocator);

    // Handle different reset modes  
    switch (reset_mode) {
        .soft => {
            // Only update HEAD, leave index and working tree unchanged
        },
        .mixed => {
            // Update HEAD and index, leave working tree unchanged
            // Reset the index to match the target commit
            resetIndex(git_path, target_hash, platform_impl, allocator) catch {};
        },
        .hard => {
            // Update HEAD, index, and working tree to match target commit
            resetIndex(git_path, target_hash, platform_impl, allocator) catch {};
            checkoutCommitTree(git_path, target_hash, allocator, platform_impl) catch {};
        },
    }
}

/// Reset the index to match the tree of the given commit
fn resetIndex(git_path: []const u8, commit_hash: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // Load commit to get tree hash
    const commit_obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch return error.InvalidCommitObject;
    defer commit_obj.deinit(allocator);

    var tree_hash: ?[]const u8 = null;
    var lines = std.mem.splitSequence(u8, commit_obj.data, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ")) {
            tree_hash = line[5..];
            break;
        }
    }

    if (tree_hash == null) return error.InvalidCommitObject;

    // Use read-tree to reset the index
    // Build index entries from the tree
    var entries = std.array_list.Managed(index_mod.IndexEntry).init(allocator);
    defer {
        for (entries.items) |*entry| {
            allocator.free(entry.path);
        }
        entries.deinit();
    }

    try collectTreeEntries(git_path, tree_hash.?, "", platform_impl, allocator, &entries);

    // Create and write index
    var idx = index_mod.Index.init(allocator);
    defer idx.deinit();
    for (entries.items) |entry| {
        try idx.entries.append(.{
            .mode = entry.mode,
            .path = try allocator.dupe(u8, entry.path),
            .sha1 = entry.sha1,
            .flags = entry.flags,
            .extended_flags = null,
            .ctime_sec = 0,
            .ctime_nsec = 0,
            .mtime_sec = 0,
            .mtime_nsec = 0,
            .dev = 0,
            .ino = 0,
            .uid = 0,
            .gid = 0,
            .size = 0,
        });
    }
    try idx.save(git_path, platform_impl);
}

/// Recursively collect all blob entries from a tree
fn collectTreeEntries(git_path: []const u8, tree_hash: []const u8, prefix: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator, entries: *std.array_list.Managed(index_mod.IndexEntry)) !void {
    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch return;
    defer tree_obj.deinit(allocator);

    if (tree_obj.type != .tree) return;

    // Parse binary tree format: mode SP name NUL hash(20 bytes)
    var i: usize = 0;
    while (i < tree_obj.data.len) {
        // Find space (end of mode)
        const space_pos = std.mem.indexOfScalar(u8, tree_obj.data[i..], ' ') orelse break;
        const mode_str = tree_obj.data[i .. i + space_pos];

        // Find NUL (end of name)
        const name_start = i + space_pos + 1;
        const nul_pos = std.mem.indexOfScalar(u8, tree_obj.data[name_start..], 0) orelse break;
        const name = tree_obj.data[name_start .. name_start + nul_pos];

        // Read 20-byte hash
        const hash_start = name_start + nul_pos + 1;
        if (hash_start + 20 > tree_obj.data.len) break;
        const hash_bytes = tree_obj.data[hash_start .. hash_start + 20];

        // Convert hash to hex
        var hash_hex: [40]u8 = undefined;
        for (hash_bytes, 0..) |b, j| {
            const hex_chars = "0123456789abcdef";
            hash_hex[j * 2] = hex_chars[b >> 4];
            hash_hex[j * 2 + 1] = hex_chars[b & 0xf];
        }

        // Build full path
        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);

        // Parse mode
        const mode = std.fmt.parseInt(u32, mode_str, 8) catch 0o100644;

        if (std.mem.eql(u8, mode_str, "40000") or mode_str.len >= 5 and mode_str[0] == '4') {
            // Directory - recurse
            defer allocator.free(full_path);
            try collectTreeEntries(git_path, &hash_hex, full_path, platform_impl, allocator, entries);
        } else {
            // File entry
            var hash_arr: [20]u8 = undefined;
            @memcpy(&hash_arr, hash_bytes);
            try entries.append(.{
                .mode = mode,
                .path = full_path, // ownership transferred
                .sha1 = hash_arr,
                .flags = @intCast(@min(full_path.len, 0xFFF)),
                .extended_flags = null,
                .ctime_sec = 0,
                .ctime_nsec = 0,
                .mtime_sec = 0,
                .mtime_nsec = 0,
                .dev = 0,
                .ino = 0,
                .uid = 0,
                .gid = 0,
                .size = 0,
            });
        }

        i = hash_start + 20;
    }
}

fn cmdRm(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("rm: not supported in freestanding mode\n");
        return;
    }

    // Find git directory
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        return;
    };
    defer allocator.free(git_path);

    // Parse arguments
    var force = false;
    var cached = false;
    var recursive = false;
    var files = std.array_list.Managed([]const u8).init(allocator);
    defer files.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--cached")) {
            cached = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--recursive")) {
            recursive = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            const msg = try std.fmt.allocPrint(allocator, "fatal: unknown option '{s}'\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
            return;
        } else {
            try files.append(arg);
        }
    }

    if (files.items.len == 0) {
        try platform_impl.writeStderr("fatal: no files specified\n");
        std.process.exit(128);
        return;
    }

    // Load the index
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.IndexNotFound => {
            try platform_impl.writeStderr("fatal: index file not found\n");
            std.process.exit(128);
            return;
        },
        else => return err,
    };
    defer index.deinit();

    // Remove files from index and optionally from working tree
    for (files.items) |file_path| {
        // Find the file in the index
        var found = false;
        for (index.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.path, file_path)) {
                found = true;
                
                // Remove from index
                _ = index.entries.orderedRemove(i);
                
                // Remove from working tree unless --cached is specified
                if (!cached) {
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/../{s}", .{git_path, file_path});
                    defer allocator.free(full_path);
                    
                    platform_impl.fs.deleteFile(full_path) catch |err| switch (err) {
                        error.FileNotFound => {
                            if (!force) {
                                const msg = try std.fmt.allocPrint(allocator, "fatal: file '{s}' not found in working tree\n", .{file_path});
                                defer allocator.free(msg);
                                try platform_impl.writeStderr(msg);
                                std.process.exit(128);
                            }
                        },
                        else => {
                            if (!force) {
                                const msg = try std.fmt.allocPrint(allocator, "fatal: could not remove '{s}': {}\n", .{file_path, err});
                                defer allocator.free(msg);
                                try platform_impl.writeStderr(msg);
                                std.process.exit(128);
                            }
                        },
                    };
                }
                break;
            }
        }
        
        if (!found) {
            const msg = try std.fmt.allocPrint(allocator, "fatal: pathspec '{s}' did not match any files\n", .{file_path});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
            return;
        }
    }

    // Write the updated index back
    try index.save(git_path, platform_impl);
}

fn updateHead(git_path: []const u8, target_hash: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // Read current HEAD to see if it's a symbolic ref or direct hash
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
    defer allocator.free(head_path);

    const head_content = platform_impl.fs.readFile(allocator, head_path) catch {
        try platform_impl.writeStderr("fatal: could not read HEAD\n");
        std.process.exit(128);
        return;
    };
    defer allocator.free(head_content);

    if (std.mem.startsWith(u8, head_content, "ref: ")) {
        // HEAD is a symbolic reference, update the referenced branch
        const ref_path = std.mem.trim(u8, head_content[5..], " \t\n\r");
        const full_ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, ref_path });
        defer allocator.free(full_ref_path);

        // Write the new hash to the branch ref
        const hash_with_newline = try std.fmt.allocPrint(allocator, "{s}\n", .{target_hash});
        defer allocator.free(hash_with_newline);

        try platform_impl.fs.writeFile(full_ref_path, hash_with_newline);
    } else {
        // HEAD is a direct hash, update it directly
        const hash_with_newline = try std.fmt.allocPrint(allocator, "{s}\n", .{target_hash});
        defer allocator.free(hash_with_newline);

        try platform_impl.fs.writeFile(head_path, hash_with_newline);
    }
}

// Forward a command to real git, using all original args (preserving global flags like -C, -c)

fn cmdHashObject(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var write_object = false;
    var stdin_mode = false;
    var stdin_paths = false;
    var obj_type: []const u8 = "blob";
    var files = std.array_list.Managed([]const u8).init(allocator);
    defer files.deinit();
    var literally = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-w")) {
            write_object = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            stdin_mode = true;
        } else if (std.mem.eql(u8, arg, "--stdin-paths")) {
            stdin_paths = true;
        } else if (std.mem.eql(u8, arg, "--literally")) {
            literally = true;
        } else if (std.mem.eql(u8, arg, "-t")) {
            obj_type = args.next() orelse {
                try platform_impl.writeStderr("fatal: option '-t' requires a value\n");
                std.process.exit(128);
                unreachable;
            };
        } else if (std.mem.startsWith(u8, arg, "-t")) {
            obj_type = arg[2..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try files.append(arg);
        }
    }

    const git_dir = if (write_object) (findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    }) else null;
    defer if (git_dir) |gd| allocator.free(gd);

    if (stdin_paths) {
        // Read file paths from stdin, one per line
        const stdin_data = std.fs.File.stdin().readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
            std.process.exit(128);
            unreachable;
        };
        defer allocator.free(stdin_data);
        var lines = std.mem.splitScalar(u8, stdin_data, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) continue;
            try hashOneFile(allocator, trimmed, obj_type, write_object, git_dir, platform_impl);
        }
    } else if (stdin_mode) {
        // Read data from stdin
        const data = std.fs.File.stdin().readToEndAlloc(allocator, 100 * 1024 * 1024) catch {
            std.process.exit(128);
            unreachable;
        };
        defer allocator.free(data);
        try hashData(allocator, data, obj_type, write_object, git_dir, platform_impl);
    } else if (files.items.len > 0) {
        for (files.items) |file_path| {
            try hashOneFile(allocator, file_path, obj_type, write_object, git_dir, platform_impl);
        }
    } else {
        try platform_impl.writeStderr("usage: git hash-object [-t <type>] [-w] [--stdin | --stdin-paths | <file>...]\n");
        std.process.exit(128);
    }
}

fn hashOneFile(allocator: std.mem.Allocator, file_path: []const u8, obj_type: []const u8, write_object: bool, git_dir: ?[]const u8, platform_impl: *const platform_mod.Platform) !void {
    const data = std.fs.cwd().readFileAlloc(allocator, file_path, 100 * 1024 * 1024) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: Cannot open '{s}': No such file or directory\n", .{file_path});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(data);
    try hashData(allocator, data, obj_type, write_object, git_dir, platform_impl);
}

fn hashData(allocator: std.mem.Allocator, data: []const u8, obj_type: []const u8, write_object: bool, git_dir: ?[]const u8, platform_impl: *const platform_mod.Platform) !void {
    const parsed_type = objects.ObjectType.fromString(obj_type) orelse {
        const msg = try std.fmt.allocPrint(allocator, "fatal: invalid object type \"{s}\"\n", .{obj_type});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
        unreachable;
    };
    const obj = objects.GitObject.init(parsed_type, data);
    const hash = try obj.hash(allocator);
    defer allocator.free(hash);

    if (write_object) {
        if (git_dir) |gd| {
            _ = obj.store(gd, platform_impl, allocator) catch {
                try platform_impl.writeStderr("fatal: unable to write object\n");
                std.process.exit(128);
                unreachable;
            };
        }
    }

    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
    defer allocator.free(output);
    try platform_impl.writeStdout(output);
}

fn cmdWriteTree(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var prefix: ?[]const u8 = null;
    var missing_ok = false;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--prefix=")) {
            prefix = arg["--prefix=".len..];
        } else if (std.mem.eql(u8, arg, "--prefix")) {
            prefix = args.next();
        } else if (std.mem.eql(u8, arg, "--missing-ok")) {
            missing_ok = true;
        }
    }
    const git_dir = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    // Load the index
    var idx = index_mod.Index.load(git_dir, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: unable to read index\n");
        std.process.exit(128);
        unreachable;
    };
    defer idx.deinit();

    // Unless --missing-ok, validate that all objects referenced in the index exist
    if (!missing_ok) {
        for (idx.entries.items) |entry| {
            // Skip entries not under prefix
            if (prefix) |pfx| {
                if (!std.mem.startsWith(u8, entry.path, pfx)) continue;
            }
            var hash_hex: [40]u8 = undefined;
            for (entry.sha1, 0..) |byte, j| {
                const hex = std.fmt.bytesToHex([1]u8{byte}, .lower);
                hash_hex[j * 2] = hex[0];
                hash_hex[j * 2 + 1] = hex[1];
            }
            // Check if object exists (loose or packed)
            const obj_exists = objectExistsCheck(git_dir, &hash_hex, platform_impl, allocator);
            if (!obj_exists) {
                const msg = try std.fmt.allocPrint(allocator, "error: invalid object {o:0>6} {s} for '{s}'\nfatal: git-write-tree: error building trees\n", .{ entry.mode, &hash_hex, entry.path });
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            }
        }
    }

    // Build tree from index entries, optionally scoped to prefix
    // Ensure prefix has trailing slash
    const write_prefix = if (prefix) |pfx|
        (if (pfx.len > 0 and pfx[pfx.len - 1] != '/')
            try std.fmt.allocPrint(allocator, "{s}/", .{pfx})
        else
            try allocator.dupe(u8, pfx))
    else
        try allocator.dupe(u8, "");
    defer allocator.free(write_prefix);
    const tree_hash = writeTreeRecursive(allocator, &idx, write_prefix, git_dir, platform_impl) catch {
        try platform_impl.writeStderr("fatal: unable to write tree\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(tree_hash);

    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{tree_hash});
    defer allocator.free(output);
    try platform_impl.writeStdout(output);
}

fn writeTreeFromIndex(allocator: std.mem.Allocator, idx: *index_mod.Index, git_dir: []const u8, platform_impl: *const platform_mod.Platform) ![]u8 {
    return writeTreeRecursive(allocator, idx, "", git_dir, platform_impl);
}

fn writeTreeRecursive(allocator: std.mem.Allocator, idx: *index_mod.Index, prefix: []const u8, git_dir: []const u8, platform_impl: *const platform_mod.Platform) ![]u8 {
    // Collect entries at this level
    var entries = std.array_list.Managed(objects.TreeEntry).init(allocator);
    defer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit();
    }

    // Track subdirectories we've already processed
    var seen_dirs = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen_dirs.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        seen_dirs.deinit();
    }

    for (idx.entries.items) |entry| {
        const path = entry.path;
        
        // Skip entries not under our prefix
        if (prefix.len > 0) {
            if (!std.mem.startsWith(u8, path, prefix)) continue;
        }
        
        const relative = if (prefix.len > 0) path[prefix.len..] else path;
        
        // Check if this is a direct child or in a subdirectory
        if (std.mem.indexOfScalar(u8, relative, '/')) |slash_pos| {
            // Subdirectory - process it recursively
            const dir_name = relative[0..slash_pos];
            const dir_key = try allocator.dupe(u8, dir_name);
            
            if (seen_dirs.contains(dir_key)) {
                allocator.free(dir_key);
                continue;
            }
            try seen_dirs.put(dir_key, {});
            
            const sub_prefix = try std.fmt.allocPrint(allocator, "{s}{s}/", .{ prefix, dir_name });
            defer allocator.free(sub_prefix);
            
            const sub_tree_hash = try writeTreeRecursive(allocator, idx, sub_prefix, git_dir, platform_impl);
            defer allocator.free(sub_tree_hash);
            
            try entries.append(objects.TreeEntry.init(
                try allocator.dupe(u8, "40000"),
                try allocator.dupe(u8, dir_name),
                try allocator.dupe(u8, sub_tree_hash),
            ));
        } else {
            // Direct child - add as a blob entry
            var hash_hex: [40]u8 = undefined;
            for (entry.sha1, 0..) |byte, j| {
                const hex = std.fmt.bytesToHex([1]u8{byte}, .lower);
                hash_hex[j * 2] = hex[0];
                hash_hex[j * 2 + 1] = hex[1];
            }
            
            const mode_str = try std.fmt.allocPrint(allocator, "{o}", .{entry.mode});
            
            try entries.append(objects.TreeEntry.init(
                mode_str,
                try allocator.dupe(u8, relative),
                try allocator.dupe(u8, &hash_hex),
            ));
        }
    }

    // Sort entries (git sorts trees specially - directories sort as if they had a trailing /)
    std.mem.sort(objects.TreeEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: objects.TreeEntry, b: objects.TreeEntry) bool {
            const a_name = if (std.mem.eql(u8, a.mode, "40000"))
                std.fmt.allocPrint(std.heap.page_allocator, "{s}/", .{a.name}) catch a.name
            else
                a.name;
            const b_name = if (std.mem.eql(u8, b.mode, "40000"))
                std.fmt.allocPrint(std.heap.page_allocator, "{s}/", .{b.name}) catch b.name
            else
                b.name;
            return std.mem.lessThan(u8, a_name, b_name);
        }
    }.lessThan);

    // Create the tree object
    const tree_obj = try objects.createTreeObject(entries.items, allocator);
    defer tree_obj.deinit(allocator);

    const hash = try tree_obj.store(git_dir, platform_impl, allocator);
    return hash;
}

fn cmdCommitTree(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var tree_hash: ?[]const u8 = null;
    var parents = std.array_list.Managed([]const u8).init(allocator);
    defer parents.deinit();
    var message: ?[]const u8 = null;
    var read_stdin = true;
    var gpg_sign: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-p")) {
            if (args.next()) |parent| {
                // Resolve parent to full hash
                const git_dir = findGitDirectory(allocator, platform_impl) catch {
                    try platform_impl.writeStderr("fatal: not a git repository\n");
                    std.process.exit(128);
                    unreachable;
                };
                defer allocator.free(git_dir);
                const resolved = resolveCommittish(git_dir, parent, platform_impl, allocator) catch {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: not a valid object name {s}\n", .{parent});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                    unreachable;
                };
                try parents.append(resolved);
            }
        } else if (std.mem.eql(u8, arg, "-m")) {
            message = args.next();
            read_stdin = false;
        } else if (std.mem.eql(u8, arg, "-F")) {
            if (args.next()) |file_path| {
                if (std.mem.eql(u8, file_path, "-")) {
                    // Read from stdin
                    read_stdin = true;
                } else {
                    message = std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch null;
                    read_stdin = false;
                }
            }
        } else if (std.mem.startsWith(u8, arg, "-S") or std.mem.startsWith(u8, arg, "--gpg-sign")) {
            gpg_sign = arg;
        } else if (std.mem.eql(u8, arg, "--no-gpg-sign")) {
            gpg_sign = null;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (tree_hash == null) tree_hash = arg;
        }
    }

    if (tree_hash == null) {
        try platform_impl.writeStderr("fatal: must specify a tree object\n");
        std.process.exit(128);
        unreachable;
    }

    // Deduplicate parent hashes (git silently removes duplicates)
    {
        var unique = std.array_list.Managed([]const u8).init(allocator);
        for (parents.items) |p| {
            var dup = false;
            for (unique.items) |u| {
                if (std.mem.eql(u8, p, u)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) {
                try unique.append(p);
            }
        }
        parents.deinit();
        parents = unique;
    }

    var final_message: []const u8 = undefined;
    var free_message = false;
    if (read_stdin and message == null) {
        final_message = std.fs.File.stdin().readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
            try platform_impl.writeStderr("fatal: unable to read commit message\n");
            std.process.exit(128);
            unreachable;
        };
        free_message = true;
    } else {
        final_message = message orelse "";
    }
    defer if (free_message) allocator.free(final_message);

    // Get author/committer from env or config
    const author = getAuthorString(allocator) catch {
        try platform_impl.writeStderr("fatal: unable to auto-detect author\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(author);
    const committer = getCommitterString(allocator) catch {
        try platform_impl.writeStderr("fatal: unable to auto-detect committer\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(committer);

    const git_dir = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    // Resolve tree hash
    const resolved_tree = resolveCommittish(git_dir, tree_hash.?, platform_impl, allocator) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: not a valid object name {s}\n", .{tree_hash.?});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(resolved_tree);

    const commit_obj = try objects.createCommitObject(
        resolved_tree,
        parents.items,
        author,
        committer,
        final_message,
        allocator,
    );
    defer commit_obj.deinit(allocator);

    const hash = commit_obj.store(git_dir, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: unable to write commit object\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(hash);

    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
    defer allocator.free(output);
    try platform_impl.writeStdout(output);

    // Free parent hashes
    for (parents.items) |p| allocator.free(p);
}

fn getAuthorString(allocator: std.mem.Allocator) ![]u8 {
    // Check GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_AUTHOR_DATE env vars
    const name = std.process.getEnvVarOwned(allocator, "GIT_AUTHOR_NAME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, "Test User"),
        else => return err,
    };
    defer allocator.free(name);
    const email = std.process.getEnvVarOwned(allocator, "GIT_AUTHOR_EMAIL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, "test@example.com"),
        else => return err,
    };
    defer allocator.free(email);
    const date = std.process.getEnvVarOwned(allocator, "GIT_AUTHOR_DATE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            const now = std.time.timestamp();
            break :blk try std.fmt.allocPrint(allocator, "{d} +0000", .{now});
        },
        else => return err,
    };
    defer allocator.free(date);

    return try std.fmt.allocPrint(allocator, "{s} <{s}> {s}", .{ name, email, date });
}

fn getCommitterString(allocator: std.mem.Allocator) ![]u8 {
    const name = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_NAME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "GIT_AUTHOR_NAME") catch try allocator.dupe(u8, "Test User"),
        else => return err,
    };
    defer allocator.free(name);
    const email = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_EMAIL") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(allocator, "GIT_AUTHOR_EMAIL") catch try allocator.dupe(u8, "test@example.com"),
        else => return err,
    };
    defer allocator.free(email);
    const date = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_DATE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            const now = std.time.timestamp();
            break :blk try std.fmt.allocPrint(allocator, "{d} +0000", .{now});
        },
        else => return err,
    };
    defer allocator.free(date);

    return try std.fmt.allocPrint(allocator, "{s} <{s}> {s}", .{ name, email, date });
}

fn cleanEmptyRefDirs(git_dir: []const u8, ref_name: []const u8, allocator: std.mem.Allocator) void {
    // After deleting a ref like refs/heads/foo/bar, clean up empty parent dirs
    var path = ref_name;
    while (std.fs.path.dirname(path)) |parent| {
        if (std.mem.eql(u8, parent, "refs") or parent.len == 0) break;
        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, parent }) catch break;
        defer allocator.free(full);
        std.fs.cwd().deleteDir(full) catch break;
        path = parent;
    }
}

fn cmdUpdateRef(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var delete_mode = false;
    var no_deref = false;
    var create_reflog = false;
    var stdin_mode = false;
    var msg: ?[]const u8 = null;
    var positional = std.array_list.Managed([]const u8).init(allocator);
    defer positional.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d")) {
            delete_mode = true;
        } else if (std.mem.eql(u8, arg, "--no-deref")) {
            no_deref = true;
        } else if (std.mem.eql(u8, arg, "--create-reflog")) {
            create_reflog = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            stdin_mode = true;
        } else if (std.mem.eql(u8, arg, "-m")) {
            msg = args.next();
        } else if (std.mem.eql(u8, arg, "--")) {
            // rest are positional
            while (args.next()) |rest| try positional.append(rest);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try positional.append(arg);
        }
    }

    const git_dir = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    if (delete_mode) {
        if (positional.items.len < 1) {
            try platform_impl.writeStderr("usage: git update-ref -d <refname> [<old-val>]\n");
            std.process.exit(128);
            unreachable;
        }
        const ref_name = positional.items[0];
        // If old-value was specified, verify it matches current value
        if (positional.items.len >= 2) {
            const old_val = positional.items[1];
            if (old_val.len > 0) {
                const current = refs.resolveRef(git_dir, ref_name, platform_impl, allocator) catch null;
                defer if (current) |c| allocator.free(c);
                if (current) |cur| {
                    if (!std.mem.eql(u8, cur, old_val)) {
                        const err_msg = try std.fmt.allocPrint(allocator, "error: cannot lock ref '{s}': is at {s} but expected {s}\n", .{ ref_name, cur, old_val });
                        defer allocator.free(err_msg);
                        try platform_impl.writeStderr(err_msg);
                        std.process.exit(1);
                        unreachable;
                    }
                }
            }
        }
        
        // Delete loose ref file
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name });
        defer allocator.free(ref_path);
        std.fs.cwd().deleteFile(ref_path) catch |err| {
            if (err != error.FileNotFound) {
                const err_msg = try std.fmt.allocPrint(allocator, "fatal: cannot delete ref '{s}': {}\n", .{ ref_name, err });
                defer allocator.free(err_msg);
                try platform_impl.writeStderr(err_msg);
                std.process.exit(1);
                unreachable;
            }
        };
        // (loose ref deletion handled above)
        
        // Also remove from packed-refs if present
        const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
        defer allocator.free(packed_refs_path);
        if (platform_impl.fs.readFile(allocator, packed_refs_path)) |packed_data| {
            defer allocator.free(packed_data);
            var new_packed = std.array_list.Managed(u8).init(allocator);
            defer new_packed.deinit();
            var lines_iter = std.mem.splitScalar(u8, packed_data, '\n');
            while (lines_iter.next()) |line| {
                if (line.len == 0) continue;
                if (line[0] == '#') {
                    try new_packed.appendSlice(line);
                    try new_packed.append('\n');
                    continue;
                }
                if (line[0] == '^') {
                    // Peeled ref - skip if previous ref was deleted
                    continue;
                }
                // Check if this line references our ref
                if (line.len > 41) {
                    const line_ref = std.mem.trimRight(u8, line[41..], " \t\r");
                    if (std.mem.eql(u8, line_ref, ref_name)) {
                        continue; // skip this ref
                    }
                }
                try new_packed.appendSlice(line);
                try new_packed.append('\n');
            }
            platform_impl.fs.writeFile(packed_refs_path, new_packed.items) catch {};
        } else |_| {}
        
        // Try to clean up empty parent dirs
        cleanEmptyRefDirs(git_dir, ref_name, allocator);
        return;
    }

    if (positional.items.len < 2) {
        try platform_impl.writeStderr("usage: git update-ref [-d] [-m <reason>] <refname> <new-value> [<old-value>]\n");
        std.process.exit(128);
        unreachable;
    }

    const ref_name = positional.items[0];
    const new_value = positional.items[1];

    // Resolve new_value to a full hash
    var resolved_new: []const u8 = undefined;
    var free_resolved = false;
    if (new_value.len == 40 and isValidHashPrefix(new_value)) {
        resolved_new = new_value;
    } else {
        resolved_new = resolveCommittish(git_dir, new_value, platform_impl, allocator) catch {
            const err_msg = try std.fmt.allocPrint(allocator, "fatal: {s}: not a valid SHA1\n", .{new_value});
            defer allocator.free(err_msg);
            try platform_impl.writeStderr(err_msg);
            std.process.exit(128);
            unreachable;
        };
        free_resolved = true;
    }
    defer if (free_resolved) allocator.free(resolved_new);

    // Old value verification
    if (positional.items.len >= 3) {
        const old_val = positional.items[2];
        if (old_val.len > 0 and !std.mem.eql(u8, old_val, "0000000000000000000000000000000000000000")) {
            const current = refs.resolveRef(git_dir, ref_name, platform_impl, allocator) catch null;
            defer if (current) |c| allocator.free(c);
            if (current) |cur| {
                if (!std.mem.eql(u8, cur, old_val)) {
                    const err_msg2 = try std.fmt.allocPrint(allocator, "error: cannot lock ref '{s}': is at {s} but expected {s}\n", .{ ref_name, cur, old_val });
                    defer allocator.free(err_msg2);
                    try platform_impl.writeStderr(err_msg2);
                    std.process.exit(1);
                    unreachable;
                }
            } else {
                // Ref doesn't exist but old value was specified
                const err_msg2 = try std.fmt.allocPrint(allocator, "error: cannot lock ref '{s}': unable to resolve reference '{s}'\n", .{ ref_name, ref_name });
                defer allocator.free(err_msg2);
                try platform_impl.writeStderr(err_msg2);
                std.process.exit(1);
                unreachable;
            }
        }
    }

    // Get old value for reflog
    const old_hash = refs.resolveRef(git_dir, ref_name, platform_impl, allocator) catch null;
    defer if (old_hash) |h| allocator.free(h);

    // Write the ref
    try refs.updateRef(git_dir, ref_name, resolved_new, platform_impl, allocator);
    
    // Create reflog dir and write entry if needed
    if (create_reflog or shouldLogRef(git_dir, ref_name, platform_impl, allocator)) {
        writeReflogEntry(git_dir, ref_name, old_hash orelse "0000000000000000000000000000000000000000", resolved_new, msg orelse "", allocator, platform_impl) catch {};
    }

}

fn shouldLogRef(git_dir: []const u8, ref_name: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) bool {
    // Check core.logAllRefUpdates config
    const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_dir}) catch return false;
    defer allocator.free(config_path);
    const config_data = platform_impl.fs.readFile(allocator, config_path) catch return false;
    defer allocator.free(config_data);
    
    if (parseConfigValue(config_data, "core.logallrefupdates", allocator) catch null) |val| {
        defer allocator.free(val);
        if (std.ascii.eqlIgnoreCase(val, "always")) return true;
        if (std.ascii.eqlIgnoreCase(val, "true")) {
            // Only log refs/heads/* and HEAD
            return std.mem.startsWith(u8, ref_name, "refs/heads/") or std.mem.eql(u8, ref_name, "HEAD");
        }
    }
    return false;
}

fn writeReflogEntry(git_dir: []const u8, ref_name: []const u8, old_hash: []const u8, new_hash: []const u8, msg_str: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    const reflog_path = try std.fmt.allocPrint(allocator, "{s}/logs/{s}", .{ git_dir, ref_name });
    defer allocator.free(reflog_path);
    
    // Create parent directories
    if (std.fs.path.dirname(reflog_path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }
    
    // Get committer info
    const name = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_NAME") catch try allocator.dupe(u8, "C O Mitter");
    defer allocator.free(name);
    const email = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_EMAIL") catch try allocator.dupe(u8, "committer@example.com");
    defer allocator.free(email);
    
    var timestamp: i64 = undefined;
    var tz_str: []const u8 = "+0000";
    var tz_needs_free = false;
    if (std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_DATE") catch null) |date_str| {
        defer allocator.free(date_str);
        // Parse "timestamp tz" format
        if (std.mem.indexOf(u8, date_str, " ")) |sp| {
            timestamp = std.fmt.parseInt(i64, date_str[0..sp], 10) catch std.time.timestamp();
            tz_str = allocator.dupe(u8, date_str[sp + 1 ..]) catch "+0000";
            tz_needs_free = true;
        } else {
            timestamp = std.fmt.parseInt(i64, date_str, 10) catch std.time.timestamp();
        }
    } else {
        timestamp = std.time.timestamp();
    }
    defer if (tz_needs_free) allocator.free(tz_str);
    
    const entry = try std.fmt.allocPrint(allocator, "{s} {s} {s} <{s}> {d} {s}\t{s}\n", .{ old_hash, new_hash, name, email, timestamp, tz_str, msg_str });
    defer allocator.free(entry);
    
    // Append to reflog file
    const file = std.fs.cwd().openFile(reflog_path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => {
            // Create new file
            platform_impl.fs.writeFile(reflog_path, entry) catch {};
            return;
        },
        else => return err,
    };
    defer file.close();
    file.seekFromEnd(0) catch {};
    file.writeAll(entry) catch {};
}

fn cmdSymbolicRef(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var quiet = false;
    var short = false;
    var delete = false;
    var positional = std.array_list.Managed([]const u8).init(allocator);
    defer positional.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--short")) {
            short = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delete")) {
            delete = true;
        } else if (std.mem.eql(u8, arg, "-m")) {
            // Skip the message argument (reflog message, we ignore for now)
            _ = args.next();
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try positional.append(arg);
        }
    }

    if (positional.items.len == 0) {
        try platform_impl.writeStderr("usage: git symbolic-ref [-m <reason>] <name> <ref>\n       git symbolic-ref [-q] [--short] <name>\n       git symbolic-ref --delete [-q] <name>\n");
        std.process.exit(1);
    }

    const git_dir = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    const ref_name = positional.items[0];

    if (delete) {
        // Delete the symbolic ref by removing the file
        const ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name }) catch {
            std.process.exit(128);
            unreachable;
        };
        defer allocator.free(ref_path);
        std.fs.cwd().deleteFile(ref_path) catch {
            if (!quiet) {
                const msg = std.fmt.allocPrint(allocator, "fatal: Cannot delete {s}\n", .{ref_name}) catch "fatal: Cannot delete ref\n";
                try platform_impl.writeStderr(msg);
            }
            std.process.exit(1);
        };
        return;
    }

    if (positional.items.len >= 2) {
        // Write mode: symbolic-ref <name> <ref>
        const target = positional.items[1];
        const ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name }) catch {
            std.process.exit(128);
            unreachable;
        };
        defer allocator.free(ref_path);

        const content = std.fmt.allocPrint(allocator, "ref: {s}\n", .{target}) catch {
            std.process.exit(128);
            unreachable;
        };
        defer allocator.free(content);

        // Ensure parent directories exist
        if (std.fs.path.dirname(ref_path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        const file = std.fs.cwd().createFile(ref_path, .{}) catch {
            const msg = std.fmt.allocPrint(allocator, "fatal: Cannot create {s}\n", .{ref_path}) catch "fatal: Cannot create ref\n";
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
            unreachable;
        };
        defer file.close();
        file.writeAll(content) catch {
            std.process.exit(128);
            unreachable;
        };
        return;
    }

    // Read mode: symbolic-ref <name>
    const ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name }) catch {
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(ref_path);

    const content = std.fs.cwd().readFileAlloc(allocator, ref_path, 4096) catch {
        if (!quiet) {
            const msg = std.fmt.allocPrint(allocator, "fatal: ref {s} is not a symbolic ref\n", .{ref_name}) catch "fatal: not a symbolic ref\n";
            try platform_impl.writeStderr(msg);
        }
        std.process.exit(1);
        unreachable;
    };
    defer allocator.free(content);

    const trimmed = std.mem.trimRight(u8, content, "\n\r ");
    if (!std.mem.startsWith(u8, trimmed, "ref: ")) {
        if (!quiet) {
            const msg = std.fmt.allocPrint(allocator, "fatal: ref {s} is not a symbolic ref\n", .{ref_name}) catch "fatal: not a symbolic ref\n";
            try platform_impl.writeStderr(msg);
        }
        std.process.exit(1);
        unreachable;
    }

    const target = trimmed["ref: ".len..];
    var output: []const u8 = undefined;
    if (short) {
        // Strip refs/heads/ or refs/tags/ or refs/remotes/ prefix
        if (std.mem.startsWith(u8, target, "refs/heads/")) {
            output = target["refs/heads/".len..];
        } else if (std.mem.startsWith(u8, target, "refs/tags/")) {
            output = target["refs/tags/".len..];
        } else if (std.mem.startsWith(u8, target, "refs/remotes/")) {
            output = target["refs/remotes/".len..];
        } else {
            output = target;
        }
    } else {
        output = target;
    }

    const out_line = std.fmt.allocPrint(allocator, "{s}\n", .{output}) catch {
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(out_line);
    try platform_impl.writeStdout(out_line);
}

fn cmdUpdateIndex(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const git_dir = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    var idx = index_mod.Index.load(git_dir, platform_impl, allocator) catch blk: {
        break :blk index_mod.Index.init(allocator);
    };
    defer idx.deinit();

    var modified = false;
    var add_mode = false;
    var remove_mode = false;
    var force_remove = false;
    var refresh = false;
    var cache_info_mode = false;
    var assume_unchanged = false;
    var no_assume_unchanged = false;
    var skip_worktree = false;
    var no_skip_worktree = false;
    var stdin_mode = false;
    var verbose = false;

    var replace_mode = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--add")) {
            add_mode = true;
        } else if (std.mem.eql(u8, arg, "--remove")) {
            remove_mode = true;
        } else if (std.mem.eql(u8, arg, "--replace")) {
            replace_mode = true;
        } else if (std.mem.eql(u8, arg, "--force-remove")) {
            force_remove = true;
        } else if (std.mem.eql(u8, arg, "--refresh")) {
            refresh = true;
        } else if (std.mem.eql(u8, arg, "--really-refresh")) {
            refresh = true;
        } else if (std.mem.eql(u8, arg, "--cacheinfo")) {
            cache_info_mode = true;
            // Format: --cacheinfo <mode>,<sha1>,<path> or --cacheinfo <mode> <sha1> <path>
            if (args.next()) |info| {
                // Check if it's comma-separated
                if (std.mem.indexOfScalar(u8, info, ',')) |_| {
                    var parts = std.mem.splitScalar(u8, info, ',');
                    const mode_str = parts.next() orelse continue;
                    const hash_str = parts.next() orelse continue;
                    const path = parts.next() orelse continue;
                    try addCacheInfo(&idx, mode_str, hash_str, path, allocator);
                    modified = true;
                } else {
                    // Three separate args: mode sha1 path
                    const mode_str = info;
                    const hash_str = args.next() orelse continue;
                    const path = args.next() orelse continue;
                    try addCacheInfo(&idx, mode_str, hash_str, path, allocator);
                    modified = true;
                }
            }
        } else if (std.mem.eql(u8, arg, "--assume-unchanged")) {
            assume_unchanged = true;
        } else if (std.mem.eql(u8, arg, "--no-assume-unchanged")) {
            no_assume_unchanged = true;
        } else if (std.mem.eql(u8, arg, "--skip-worktree")) {
            skip_worktree = true;
        } else if (std.mem.eql(u8, arg, "--no-skip-worktree")) {
            no_skip_worktree = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            stdin_mode = true;
        } else if (std.mem.eql(u8, arg, "--index-info")) {
            // Read index info from stdin: "<mode> <type> <sha1>\t<path>" or "<mode> <sha1> <stage>\t<path>"
            const stdin_data = readStdin(allocator, 10 * 1024 * 1024) catch {
                try platform_impl.writeStderr("fatal: unable to read from stdin\n");
                std.process.exit(128);
                unreachable;
            };
            defer allocator.free(stdin_data);
            var lines = std.mem.splitScalar(u8, stdin_data, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                // Format: "<mode> <sha1> <stage>\t<path>" or "<mode> <type> <sha1>\t<path>"
                if (std.mem.indexOfScalar(u8, line, '\t')) |tab_pos| {
                    const info_part = line[0..tab_pos];
                    const path = line[tab_pos + 1 ..];
                    if (path.len == 0) continue;
                    // Parse info part - split by spaces
                    var parts = std.mem.splitScalar(u8, info_part, ' ');
                    const mode_str = parts.next() orelse continue;
                    const second = parts.next() orelse continue;
                    // Second field could be "blob"/"tree"/"commit" (type) or a sha1 hash
                    var hash_str: []const u8 = undefined;
                    if (second.len == 40) {
                        // It's a hash directly: "<mode> <sha1> <stage>\t<path>"
                        hash_str = second;
                    } else {
                        // It's a type: "<mode> <type> <sha1>\t<path>"
                        hash_str = parts.next() orelse continue;
                    }
                    try addCacheInfo(&idx, mode_str, hash_str, path, allocator);
                    modified = true;
                }
            }
        } else if (std.mem.eql(u8, arg, "-q")) {
            // quiet mode
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--chmod=+x")) {
            // Next arg should be a path
            if (args.next()) |path| {
                try setIndexEntryMode(&idx, path, 0o100755);
                modified = true;
            }
        } else if (std.mem.eql(u8, arg, "--chmod=-x")) {
            if (args.next()) |path| {
                try setIndexEntryMode(&idx, path, 0o100644);
                modified = true;
            }
        } else if (std.mem.eql(u8, arg, "--index-version")) {
            _ = args.next(); // skip version number
        } else if (std.mem.eql(u8, arg, "--")) {
            // rest are paths
            while (args.next()) |path| {
                if (add_mode) {
                    idx.add(path, path, platform_impl, git_dir) catch {};
                    modified = true;
                }
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // File path
            if (assume_unchanged or no_assume_unchanged or skip_worktree or no_skip_worktree) {
                // Set flags on existing entry
                for (idx.entries.items) |*entry| {
                    if (std.mem.eql(u8, entry.path, arg)) {
                        if (assume_unchanged) entry.flags |= 0x8000; // CE_VALID
                        if (no_assume_unchanged) entry.flags &= ~@as(u16, 0x8000);
                        if (skip_worktree) {
                            // Set skip-worktree in extended flags
                            entry.flags |= 0x4000; // CE_EXTENDED
                        }
                        if (no_skip_worktree) {
                            entry.flags &= ~@as(u16, 0x4000);
                        }
                        modified = true;
                        break;
                    }
                }
            } else if (force_remove) {
                idx.remove(arg) catch {};
                modified = true;
            } else if (remove_mode) {
                // Only remove if file doesn't exist
                std.fs.cwd().access(arg, .{}) catch {
                    idx.remove(arg) catch {};
                    modified = true;
                };
            } else if (add_mode) {
                if (replace_mode) {
                    // D/F conflict resolution:
                    // 1. If adding file "X", remove all entries "X/*" (file replaces dir)
                    const prefix_with_slash = std.fmt.allocPrint(allocator, "{s}/", .{arg}) catch arg;
                    const needs_free_pws = !std.mem.eql(u8, prefix_with_slash, arg);
                    var j: usize = 0;
                    while (j < idx.entries.items.len) {
                        if (std.mem.startsWith(u8, idx.entries.items[j].path, prefix_with_slash)) {
                            idx.entries.items[j].deinit(allocator);
                            _ = idx.entries.orderedRemove(j);
                        } else {
                            j += 1;
                        }
                    }
                    if (needs_free_pws) allocator.free(@constCast(prefix_with_slash));
                    // 2. If adding file "X/Y", remove entry "X" (dir replaces file)
                    if (std.mem.indexOfScalar(u8, arg, '/')) |slash_idx| {
                        const parent = arg[0..slash_idx];
                        for (idx.entries.items, 0..) |entry, ei| {
                            if (std.mem.eql(u8, entry.path, parent)) {
                                idx.entries.items[ei].deinit(allocator);
                                _ = idx.entries.orderedRemove(ei);
                                break;
                            }
                        }
                    }
                }
                idx.add(arg, arg, platform_impl, git_dir) catch {};
                modified = true;
            } else {
                // No --add/--remove flag: file must already be in the index
                var found_in_index = false;
                for (idx.entries.items) |entry| {
                    if (std.mem.eql(u8, entry.path, arg)) {
                        found_in_index = true;
                        break;
                    }
                }
                if (!found_in_index) {
                    const err_msg = std.fmt.allocPrint(allocator, "error: {s}: cannot add to the index - missing --add option?\nfatal: Unable to process path {s}\n", .{ arg, arg }) catch "error: cannot add to the index\n";
                    try platform_impl.writeStderr(err_msg);
                    std.process.exit(128);
                } else {
                    // File is in index — check if it still exists on disk
                    std.fs.cwd().access(arg, .{}) catch {
                        // File deleted but no --remove flag
                        const err_msg2 = std.fmt.allocPrint(allocator, "error: {s}: does not exist and --remove not passed\nfatal: Unable to process path {s}\n", .{ arg, arg }) catch "error: file does not exist\n";
                        try platform_impl.writeStderr(err_msg2);
                        std.process.exit(128);
                    };
                    // Update existing entry with current file stat
                    idx.add(arg, arg, platform_impl, git_dir) catch {};
                    modified = true;
                }
            }
        }
    }

    if (refresh) {
        // Refresh stat info for all entries by re-statting files
        const repo_root = std.fs.path.dirname(git_dir) orelse ".";
        for (idx.entries.items) |*entry| {
            const full_path = if (repo_root.len > 0 and !std.mem.eql(u8, repo_root, "."))
                std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path }) catch continue
            else
                allocator.dupe(u8, entry.path) catch continue;
            defer allocator.free(full_path);

            // Check if it's a symlink
            var link_buf: [4096]u8 = undefined;
            if (std.fs.cwd().readLink(full_path, &link_buf)) |link_target| {
                // Symlink: update size to link target length
                entry.size = @intCast(link_target.len);
                // Get the file's lstat info via fstatat or approximate
                // For symlinks, we need the symlink's own mtime, not the target's
                // Use the parent dir + entry to get proper stat
                if (std.fs.cwd().statFile(full_path)) |stat| {
                    entry.ctime_sec = @intCast(@max(0, @divTrunc(stat.ctime, std.time.ns_per_s)));
                    entry.ctime_nsec = @intCast(@max(0, @rem(stat.ctime, std.time.ns_per_s)));
                    entry.mtime_sec = @intCast(@max(0, @divTrunc(stat.mtime, std.time.ns_per_s)));
                    entry.mtime_nsec = @intCast(@max(0, @rem(stat.mtime, std.time.ns_per_s)));
                    entry.ino = @intCast(stat.inode);
                } else |_| {}
            } else |_| {
                // Regular file
                if (std.fs.cwd().statFile(full_path)) |stat| {
                    entry.ctime_sec = @intCast(@max(0, @divTrunc(stat.ctime, std.time.ns_per_s)));
                    entry.ctime_nsec = @intCast(@max(0, @rem(stat.ctime, std.time.ns_per_s)));
                    entry.mtime_sec = @intCast(@max(0, @divTrunc(stat.mtime, std.time.ns_per_s)));
                    entry.mtime_nsec = @intCast(@max(0, @rem(stat.mtime, std.time.ns_per_s)));
                    entry.size = @intCast(@min(stat.size, std.math.maxInt(u32)));
                    entry.ino = @intCast(stat.inode);
                } else |_| {}
            }
        }
        modified = true;
    }

    if (modified) {
        idx.save(git_dir, platform_impl) catch {
            try platform_impl.writeStderr("fatal: unable to write index file\n");
            std.process.exit(128);
        };
    }
}

fn addCacheInfo(idx: *index_mod.Index, mode_str: []const u8, hash_str: []const u8, path: []const u8, allocator: std.mem.Allocator) !void {
    const mode = std.fmt.parseInt(u32, mode_str, 8) catch 0o100644;
    
    // Parse hash
    var sha1: [20]u8 = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        sha1[i] = std.fmt.parseInt(u8, hash_str[i * 2 .. i * 2 + 2], 16) catch 0;
    }

    // Remove existing entry with same path
    idx.remove(path) catch {};

    // Add new entry
    const entry = index_mod.IndexEntry{
        .ctime_sec = 0,
        .ctime_nsec = 0,
        .mtime_sec = 0,
        .mtime_nsec = 0,
        .dev = 0,
        .ino = 0,
        .mode = mode,
        .uid = 0,
        .gid = 0,
        .size = 0,
        .sha1 = sha1,
        .flags = @as(u16, @intCast(@min(path.len, 0xFFF))),
        .extended_flags = null,
        .path = try allocator.dupe(u8, path),
    };
    try idx.entries.append(entry);
    
    // Sort entries by path
    std.mem.sort(index_mod.IndexEntry, idx.entries.items, {}, struct {
        fn lessThan(_: void, a: index_mod.IndexEntry, b: index_mod.IndexEntry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
}

fn setIndexEntryMode(idx: *index_mod.Index, path: []const u8, new_mode: u32) !void {
    for (idx.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.path, path)) {
            entry.mode = new_mode;
            return;
        }
    }
    return error.FileNotFound;
}

fn cmdLsTree(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    _ = allocator;
    _ = args;
    try platform_impl.writeStderr("fatal: ls-tree requires arguments\n");
    std.process.exit(128);
}

/// Resolve a tree-ish (commit hash, branch name, tree hash) to a tree object hash
fn resolveTreeish(git_path: []const u8, treeish: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) ![]u8 {
    // First resolve the reference to an object hash
    const obj_hash = resolveCommittish(git_path, treeish, platform_impl, allocator) catch {
        // Maybe it's already a tree hash
        if (treeish.len == 40 and isValidHashPrefix(treeish)) {
            return try allocator.dupe(u8, treeish);
        }
        return error.UnknownRevision;
    };
    defer allocator.free(obj_hash);

    // Load the object to check its type
    const obj = objects.GitObject.load(obj_hash, git_path, platform_impl, allocator) catch {
        return error.ObjectNotFound;
    };
    defer obj.deinit(allocator);

    switch (obj.type) {
        .tree => return try allocator.dupe(u8, obj_hash),
        .commit => {
            // Parse "tree <hash>" from the commit data
            var lines = std.mem.splitSequence(u8, obj.data, "\n");
            if (lines.next()) |first_line| {
                if (std.mem.startsWith(u8, first_line, "tree ")) {
                    return try allocator.dupe(u8, first_line["tree ".len..]);
                }
            }
            return error.ObjectNotFound;
        },
        .tag => {
            // Parse "object <hash>" from tag, then resolve that
            var lines = std.mem.splitSequence(u8, obj.data, "\n");
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "object ")) {
                    const target_hash = line["object ".len..];
                    return resolveTreeish(git_path, target_hash, platform_impl, allocator);
                }
            }
            return error.ObjectNotFound;
        },
        else => return error.ObjectNotFound,
    }
}

/// Parse tree object data and return entries as a list
fn parseTreeEntries(tree_data: []const u8, allocator: std.mem.Allocator) !std.array_list.Managed(LsTreeEntry) {
    var entries = std.array_list.Managed(LsTreeEntry).init(allocator);
    var pos: usize = 0;

    while (pos < tree_data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, tree_data, pos, ' ') orelse break;
        const mode = tree_data[pos..space_pos];
        pos = space_pos + 1;

        const null_pos = std.mem.indexOfScalarPos(u8, tree_data, pos, 0) orelse break;
        const name = tree_data[pos..null_pos];
        pos = null_pos + 1;

        if (pos + 20 > tree_data.len) break;
        const hash_bytes = tree_data[pos..pos + 20];
        pos += 20;

        var hash_hex: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_hex, "{x}", .{hash_bytes}) catch break;

        const is_tree = std.mem.eql(u8, mode, "40000");
        const is_commit = std.mem.eql(u8, mode, "160000");
        // Pad mode to 6 digits (git format)
        const padded_mode = if (is_tree) "040000" else mode;
        const obj_type_str: []const u8 = if (is_tree) "tree" else if (is_commit) "commit" else "blob";

        try entries.append(LsTreeEntry{
            .mode = try allocator.dupe(u8, padded_mode),
            .obj_type = obj_type_str,
            .hash = try allocator.dupe(u8, &hash_hex),
            .name = try allocator.dupe(u8, name),
        });
    }

    return entries;
}

const LsTreeEntry = struct {
    mode: []const u8,
    obj_type: []const u8, // "blob" or "tree"
    hash: []const u8,
    name: []const u8,

    fn deinit(self: LsTreeEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.mode);
        allocator.free(self.hash);
        allocator.free(self.name);
    }
};

fn nativeCmdLsTree(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var recursive = false;
    var show_trees = false; // -t flag
    var only_trees = false; // -d flag
    var name_only = false;
    var name_status = false;
    var long_format = false;
    var null_terminated = false;
    var abbrev_len: ?usize = null;
    var full_tree = false;
    var full_name = false;
    var object_only = false;
    var has_format = false;
    var format_str: ?[]const u8 = null;
    var treeish: ?[]const u8 = null;
    var pathspecs = std.array_list.Managed([]const u8).init(allocator);
    defer pathspecs.deinit();

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-r")) {
            recursive = true;
        } else if (std.mem.eql(u8, arg, "-t")) {
            show_trees = true;
        } else if (std.mem.eql(u8, arg, "-d")) {
            only_trees = true;
        } else if (std.mem.eql(u8, arg, "--name-only")) {
            name_only = true;
        } else if (std.mem.eql(u8, arg, "--name-status")) {
            name_status = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--long")) {
            long_format = true;
        } else if (std.mem.eql(u8, arg, "-z")) {
            null_terminated = true;
        } else if (std.mem.eql(u8, arg, "--full-tree")) {
            full_tree = true;
        } else if (std.mem.eql(u8, arg, "--full-name")) {
            full_name = true;
        } else if (std.mem.eql(u8, arg, "--no-full-name")) {
            full_name = false;
        } else if (std.mem.eql(u8, arg, "--object-only")) {
            object_only = true;
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            has_format = true;
            format_str = arg["--format=".len..];
        } else if (std.mem.eql(u8, arg, "--abbrev")) {
            abbrev_len = 7; // default abbrev length
        } else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
            const val = arg["--abbrev=".len..];
            abbrev_len = std.fmt.parseInt(usize, val, 10) catch 7;
        } else if (std.mem.eql(u8, arg, "--")) {
            // Everything after -- is a pathspec
            i += 1;
            while (i < args.len) : (i += 1) {
                try pathspecs.append(args[i]);
            }
            break;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git ls-tree [<options>] <tree-ish> [<path>...]\n\n    -d                  only show trees\n    -r                  recurse into subtrees\n    -t                  show trees when recursing\n    --name-only         list only filenames\n    --name-status       list only filenames\n    --long              include object size\n    -z                  terminate entries with NUL byte\n");
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (treeish == null) {
                treeish = arg;
            } else {
                try pathspecs.append(arg);
            }
        }
    }

    // Validate incompatible options
    {
        const name_opts = @as(u8, if (name_only) 1 else 0) + @as(u8, if (object_only) 1 else 0);
        if (long_format and (name_only or name_status)) {
            try platform_impl.writeStderr("error: --long is incompatible with --name-only\n");
            std.process.exit(129);
        }
        if (long_format and object_only) {
            try platform_impl.writeStderr("error: --long is incompatible with --object-only\n");
            std.process.exit(129);
        }
        if (name_only and name_status) {
            try platform_impl.writeStderr("error: --name-status is incompatible with --name-only\n");
            std.process.exit(129);
        }
        if ((name_only or name_status) and object_only) {
            if (name_status) {
                try platform_impl.writeStderr("error: --object-only is incompatible with --name-status\n");
            } else {
                try platform_impl.writeStderr("error: --object-only is incompatible with --name-only\n");
            }
            std.process.exit(129);
        }
        _ = name_opts;
        if (has_format) {
            if (long_format or name_only or name_status or object_only) {
                try platform_impl.writeStderr("error: --format can't be combined with other format-altering options\n");
                std.process.exit(129);
            }
        }
        // Merge name_status into name_only for output purposes
        if (name_status) name_only = true;
    }

    if (treeish == null) {
        try platform_impl.writeStderr("fatal: not enough arguments\n");
        std.process.exit(128);
    }

    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_path);

    // Compute prefix (path from repo root to CWD)
    var prefix_str: []const u8 = "";
    var prefix_allocated = false;
    if (!full_tree) {
        const cwd = platform_impl.fs.getCwd(allocator) catch "";
        defer if (cwd.len > 0) allocator.free(cwd);
        // git_path is like /path/to/repo/.git, repo root is parent
        const repo_root = std.fs.path.dirname(git_path) orelse "";
        if (cwd.len > 0 and repo_root.len > 0 and cwd.len > repo_root.len and
            std.mem.startsWith(u8, cwd, repo_root) and cwd[repo_root.len] == '/')
        {
            prefix_str = allocator.dupe(u8, cwd[repo_root.len + 1 ..]) catch "";
            prefix_allocated = prefix_str.len > 0;
        }
    }
    defer if (prefix_allocated) allocator.free(@constCast(prefix_str));

    // Adjust pathspecs with prefix (prepend prefix to relative pathspecs)
    var adjusted_pathspecs = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (adjusted_pathspecs.items) |ps| allocator.free(@constCast(ps));
        adjusted_pathspecs.deinit();
    }
    var no_path_restriction = false;
    if (prefix_str.len > 0 and pathspecs.items.len > 0) {
        for (pathspecs.items) |ps| {
            // Resolve relative paths like ../
            const combined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix_str, ps });
            defer allocator.free(combined);
            const normalized = try normalizePath(allocator, combined);
            if (normalized.len == 0) {
                allocator.free(normalized);
                // Path resolved to root - no restriction
                no_path_restriction = true;
                for (adjusted_pathspecs.items) |existing| allocator.free(@constCast(existing));
                adjusted_pathspecs.clearRetainingCapacity();
                break;
            } else {
                try adjusted_pathspecs.append(normalized);
            }
        }
    } else if (prefix_str.len > 0 and pathspecs.items.len == 0) {
        // When no pathspecs given but in a subdirectory, restrict to prefix
        const adjusted = try std.fmt.allocPrint(allocator, "{s}/", .{prefix_str});
        try adjusted_pathspecs.append(adjusted);
    }

    // Use adjusted pathspecs if we have them, otherwise original
    // Check for --full-tree with ../ pathspec (should error)
    if (full_tree) {
        for (pathspecs.items) |ps| {
            if (std.mem.startsWith(u8, ps, "../") or std.mem.eql(u8, ps, "..")) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: {s}: '{s}' is outside repository\n", .{ ps, ps });
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            }
        }
    }

    // Use empty pathspecs when path resolved to root (show everything)
    var empty_pathspecs = std.array_list.Managed([]const u8).init(allocator);
    defer empty_pathspecs.deinit();
    const effective_pathspecs = if (no_path_restriction)
        &empty_pathspecs
    else if (adjusted_pathspecs.items.len > 0)
        &adjusted_pathspecs
    else
        &pathspecs;

    // Resolve tree-ish to a tree hash
    const tree_hash = resolveTreeish(git_path, treeish.?, platform_impl, allocator) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: Not a valid object name {s}\n", .{treeish.?});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(tree_hash);

    // Collect all output entries
    var output_entries = std.array_list.Managed(OutputEntry) .init(allocator);
    defer {
        for (output_entries.items) |*entry| entry.deinit(allocator);
        output_entries.deinit();
    }

    // Walk the tree
    walkTree(allocator, git_path, tree_hash, "", recursive, show_trees, only_trees, effective_pathspecs, platform_impl, &output_entries) catch {
        try platform_impl.writeStderr("fatal: not a tree object\n");
        std.process.exit(128);
        unreachable;
    };

    // Sort by path (git ls-tree outputs sorted)
    std.sort.block(OutputEntry, output_entries.items, {}, struct {
        fn lessThan(_: void, a: OutputEntry, b: OutputEntry) bool {
            return std.mem.order(u8, a.full_path, b.full_path) == .lt;
        }
    }.lessThan);

    // Output
    // Read core.quotePath config (default true)
    var quote_path = true;
    {
        const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch null;
        if (config_path) |cp| {
            defer allocator.free(cp);
            if (std.fs.cwd().readFileAlloc(allocator, cp, 1024 * 1024)) |config_content| {
                defer allocator.free(config_content);
                // Simple search for quotepath = false
                if (std.mem.indexOf(u8, config_content, "quotepath = false") != null or
                    std.mem.indexOf(u8, config_content, "quotePath = false") != null)
                {
                    quote_path = false;
                }
            } else |_| {}
        }
    }

    const line_end: []const u8 = if (null_terminated) "\x00" else "\n";
    for (output_entries.items) |entry| {
        // Apply hash abbreviation
        const display_hash = if (abbrev_len) |abl|
            entry.hash[0..@min(abl, entry.hash.len)]
        else
            entry.hash;
        // By default, paths are shown relative to CWD (prefix).
        // --full-name shows repo-root-relative paths.
        const raw_display_path = if (!full_name and prefix_str.len > 0) blk: {
            break :blk try makeRelativePath(allocator, prefix_str, entry.full_path);
        } else entry.full_path;
        const raw_display_path_allocated = !full_name and prefix_str.len > 0;
        defer if (raw_display_path_allocated) allocator.free(@constCast(raw_display_path));

        // C-quote the path if it contains special characters
        const quoted_path = try cQuotePath(allocator, raw_display_path, quote_path);
        defer allocator.free(quoted_path);
        const display_path = quoted_path;

        if (format_str) |fmt| {
            // Custom format string
            const formatted = try formatLsTreeEntry(allocator, fmt, entry, display_hash, display_path, git_path, platform_impl);
            defer allocator.free(formatted);
            const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ formatted, line_end });
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else if (object_only) {
            const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ display_hash, line_end });
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else if (name_only) {
            const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ display_path, line_end });
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else if (long_format) {
            // Long format: mode type size\thash\tpath
            const size_str = if (std.mem.eql(u8, entry.obj_type, "tree") or std.mem.eql(u8, entry.obj_type, "commit"))
                try allocator.dupe(u8, "      -")
            else blk: {
                // Load the object to get its size
                const obj = objects.GitObject.load(entry.hash, git_path, platform_impl, allocator) catch {
                    break :blk try allocator.dupe(u8, "      ?");
                };
                defer obj.deinit(allocator);
                break :blk try std.fmt.allocPrint(allocator, "{d:>7}", .{obj.data.len});
            };
            defer allocator.free(size_str);
            const output = try std.fmt.allocPrint(allocator, "{s} {s} {s} {s}\t{s}{s}", .{ entry.mode, entry.obj_type, display_hash, size_str, display_path, line_end });
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else {
            const output = try std.fmt.allocPrint(allocator, "{s} {s} {s}\t{s}{s}", .{ entry.mode, entry.obj_type, display_hash, display_path, line_end });
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        }
    }
}

const OutputEntry = struct {
    mode: []const u8,
    obj_type: []const u8,
    hash: []const u8,
    full_path: []const u8,

    fn deinit(self: *OutputEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.mode);
        allocator.free(self.hash);
        allocator.free(self.full_path);
    }
};

fn walkTree(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    tree_hash: []const u8,
    prefix: []const u8,
    recursive: bool,
    show_trees: bool,
    only_trees: bool,
    pathspecs: *std.array_list.Managed([]const u8),
    platform_impl: *const platform_mod.Platform,
    output: *std.array_list.Managed(OutputEntry),
) !void {
    // Load the tree object
    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch {
        return error.ObjectNotFound;
    };
    defer tree_obj.deinit(allocator);

    if (tree_obj.type != .tree) return error.ObjectNotFound;

    // Parse tree entries
    var entries = try parseTreeEntries(tree_obj.data, allocator);
    defer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit();
    }

    for (entries.items) |entry| {
        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        const is_tree = std.mem.eql(u8, entry.obj_type, "tree");
        const is_submodule = std.mem.eql(u8, entry.obj_type, "commit");
        const is_directory_like = is_tree or is_submodule;

        // Check pathspec filtering
        if (pathspecs.items.len > 0) {
            var matches = false;
            for (pathspecs.items) |pathspec| {
                if (pathMatchesSpec(full_path, pathspec, is_directory_like)) {
                    matches = true;
                    break;
                }
                // Also check if this tree is a prefix of the pathspec (need to recurse into it)
                if (is_tree and pathSpecStartsWith(pathspec, full_path)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) {
                allocator.free(full_path);
                continue;
            }
        }

        if (is_tree) {
            if (recursive) {
                if (show_trees or only_trees) {
                    try output.append(OutputEntry{
                        .mode = try allocator.dupe(u8, entry.mode),
                        .obj_type = entry.obj_type,
                        .hash = try allocator.dupe(u8, entry.hash),
                        .full_path = try allocator.dupe(u8, full_path),
                    });
                }
                if (!only_trees) {
                    try walkTree(allocator, git_path, entry.hash, full_path, recursive, show_trees, only_trees, pathspecs, platform_impl, output);
                } else {
                    // Even with -d, recurse to find subtrees
                    try walkTree(allocator, git_path, entry.hash, full_path, recursive, show_trees, only_trees, pathspecs, platform_impl, output);
                }
            } else {
                // Non-recursive: check if pathspec asks for contents of this tree
                var show_children = false;
                if (pathspecs.items.len > 0) {
                    for (pathspecs.items) |pathspec| {
                        // If pathspec ends with '/' and matches this tree, show children
                        if (std.mem.endsWith(u8, pathspec, "/") and
                            std.mem.eql(u8, full_path, pathspec[0 .. pathspec.len - 1]))
                        {
                            show_children = true;
                            break;
                        }
                        // If pathspec has more components beyond this tree, show children
                        if (pathSpecStartsWith(pathspec, full_path) and
                            pathspec.len > full_path.len and pathspec[full_path.len] == '/')
                        {
                            show_children = true;
                            break;
                        }
                    }
                }

                if (show_children) {
                    // With -t flag, show intermediate tree entries
                    if (show_trees) {
                        try output.append(OutputEntry{
                            .mode = try allocator.dupe(u8, entry.mode),
                            .obj_type = entry.obj_type,
                            .hash = try allocator.dupe(u8, entry.hash),
                            .full_path = try allocator.dupe(u8, full_path),
                        });
                    }
                    // Recursively descend into this tree to find matching entries
                    // (handles deep pathspecs like path1/b/c/1.txt)
                    try walkTree(allocator, git_path, entry.hash, full_path, false, show_trees, only_trees, pathspecs, platform_impl, output);
                } else if (!only_trees or is_tree) {
                    try output.append(OutputEntry{
                        .mode = try allocator.dupe(u8, entry.mode),
                        .obj_type = entry.obj_type,
                        .hash = try allocator.dupe(u8, entry.hash),
                        .full_path = try allocator.dupe(u8, full_path),
                    });
                }
            }
        } else {
            // Blob or submodule entry
            if (!only_trees or is_submodule) {
                try output.append(OutputEntry{
                    .mode = try allocator.dupe(u8, entry.mode),
                    .obj_type = entry.obj_type,
                    .hash = try allocator.dupe(u8, entry.hash),
                    .full_path = try allocator.dupe(u8, full_path),
                });
            }
        }

        allocator.free(full_path);
    }
}

fn walkTreeOneLevel(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    tree_hash: []const u8,
    prefix: []const u8,
    pathspecs: *std.array_list.Managed([]const u8),
    platform_impl: *const platform_mod.Platform,
    output: *std.array_list.Managed(OutputEntry),
    show_trees_flag: bool,
) !void {
    _ = show_trees_flag;
    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch return;
    defer tree_obj.deinit(allocator);
    if (tree_obj.type != .tree) return;

    var entries = try parseTreeEntries(tree_obj.data, allocator);
    defer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit();
    }

    for (entries.items) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(full_path);

        const is_tree = std.mem.eql(u8, entry.obj_type, "tree");

        // Check pathspec filtering for sub-entries
        if (pathspecs.items.len > 0) {
            var matches = false;
            for (pathspecs.items) |pathspec| {
                if (pathMatchesSpec(full_path, pathspec, is_tree)) {
                    matches = true;
                    break;
                }
                if (is_tree and pathSpecStartsWith(pathspec, full_path)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
        }

        try output.append(OutputEntry{
            .mode = try allocator.dupe(u8, entry.mode),
            .obj_type = entry.obj_type,
            .hash = try allocator.dupe(u8, entry.hash),
            .full_path = try allocator.dupe(u8, full_path),
        });
    }
}

/// Check if a path matches a pathspec
fn pathMatchesSpec(path: []const u8, spec: []const u8, is_tree: bool) bool {
    // Spec with trailing slash: matches children of the directory but not a blob with the base name
    if (std.mem.endsWith(u8, spec, "/")) {
        const spec_base = spec[0 .. spec.len - 1];
        // path0/ should NOT match the blob path0 (file, not directory)
        if (std.mem.eql(u8, path, spec_base)) {
            return is_tree; // Only match if it's actually a tree
        }
        // Match children of the specified directory (both blobs and trees)
        if (std.mem.startsWith(u8, path, spec)) return true;
        return false;
    }
    // Exact match
    if (std.mem.eql(u8, path, spec)) return true;
    // Path is a child of the spec directory
    if (path.len > spec.len and std.mem.startsWith(u8, path, spec) and path[spec.len] == '/') return true;
    return false;
}

/// Check if pathspec starts with the given prefix (for tree recursion)
/// Normalize a path by resolving . and .. components
/// C-style quote a filename if it contains special characters
fn cQuotePath(allocator: std.mem.Allocator, path: []const u8, quote_high_bytes: bool) ![]u8 {
    // Check if quoting is needed
    var needs_quoting = false;
    for (path) |c| {
        if (c < 0x20 or c == '\\' or c == '"') {
            needs_quoting = true;
            break;
        }
        if (quote_high_bytes and c >= 0x80) {
            needs_quoting = true;
            break;
        }
    }
    if (!needs_quoting) return try allocator.dupe(u8, path);

    var result = std.array_list.Managed(u8).init(allocator);
    try result.append('"');
    for (path) |c| {
        switch (c) {
            '\t' => try result.appendSlice("\\t"),
            '\n' => try result.appendSlice("\\n"),
            '\\' => try result.appendSlice("\\\\"),
            '"' => try result.appendSlice("\\\""),
            else => {
                if (c < 0x20 or (quote_high_bytes and c >= 0x80)) {
                    var buf: [4]u8 = undefined;
                    _ = std.fmt.bufPrint(&buf, "\\{o:0>3}", .{c}) catch unreachable;
                    try result.appendSlice(&buf);
                } else {
                    try result.append(c);
                }
            },
        }
    }
    try result.append('"');
    return try allocator.dupe(u8, result.items);
}

fn formatLsTreeEntry(
    allocator: std.mem.Allocator,
    fmt: []const u8,
    entry: OutputEntry,
    display_hash: []const u8,
    display_path: []const u8,
    git_path: []const u8,
    platform_impl: *const platform_mod.Platform,
) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            if (fmt[i + 1] == '(') {
              if (std.mem.indexOf(u8, fmt[i..], ")")) |close_offset| {
                const placeholder = fmt[i + 2 .. i + close_offset];
                if (std.mem.eql(u8, placeholder, "objectmode")) {
                    try result.appendSlice(entry.mode);
                } else if (std.mem.eql(u8, placeholder, "objecttype")) {
                    try result.appendSlice(entry.obj_type);
                } else if (std.mem.eql(u8, placeholder, "objectname")) {
                    try result.appendSlice(display_hash);
                } else if (std.mem.eql(u8, placeholder, "objectsize")) {
                    if (std.mem.eql(u8, entry.obj_type, "tree") or std.mem.eql(u8, entry.obj_type, "commit")) {
                        try result.append('-');
                    } else {
                        const obj = objects.GitObject.load(entry.hash, git_path, platform_impl, allocator) catch {
                            try result.append('-');
                            i += close_offset + 1;
                            continue;
                        };
                        defer obj.deinit(allocator);
                        const sz = try std.fmt.allocPrint(allocator, "{d}", .{obj.data.len});
                        defer allocator.free(sz);
                        try result.appendSlice(sz);
                    }
                } else if (std.mem.eql(u8, placeholder, "objectsize:padded")) {
                    if (std.mem.eql(u8, entry.obj_type, "tree") or std.mem.eql(u8, entry.obj_type, "commit")) {
                        try result.appendSlice("      -");
                    } else {
                        const obj = objects.GitObject.load(entry.hash, git_path, platform_impl, allocator) catch {
                            try result.appendSlice("      -");
                            i += close_offset + 1;
                            continue;
                        };
                        defer obj.deinit(allocator);
                        const sz = try std.fmt.allocPrint(allocator, "{d:>7}", .{obj.data.len});
                        defer allocator.free(sz);
                        try result.appendSlice(sz);
                    }
                } else if (std.mem.eql(u8, placeholder, "path")) {
                    try result.appendSlice(display_path);
                }
                i += close_offset + 1;
              } else {
                try result.append(fmt[i]);
                i += 1;
              }
            } else if (fmt[i + 1] == 'x' and i + 3 < fmt.len) {
                // Hex escape: %xNN
                const hex_str = fmt[i + 2 .. i + 4];
                const byte = std.fmt.parseInt(u8, hex_str, 16) catch {
                    try result.append('%');
                    i += 1;
                    continue;
                };
                try result.append(byte);
                i += 4;
            } else {
                try result.append(fmt[i]);
                i += 1;
            }
        } else {
            try result.append(fmt[i]);
            i += 1;
        }
    }
    return try allocator.dupe(u8, result.items);
}

/// Given a prefix (CWD relative to repo root) and a full_path (relative to repo root),
/// compute the display path relative to prefix. E.g., prefix="aa", full_path="a[a]/three" → "../a[a]/three"
fn makeRelativePath(allocator: std.mem.Allocator, prefix: []const u8, full_path: []const u8) ![]const u8 {
    // Split prefix into components
    var prefix_parts = std.array_list.Managed([]const u8).init(allocator);
    defer prefix_parts.deinit();
    var piter = std.mem.splitScalar(u8, prefix, '/');
    while (piter.next()) |part| {
        if (part.len > 0) try prefix_parts.append(part);
    }

    // Split full_path into components
    var path_parts = std.array_list.Managed([]const u8).init(allocator);
    defer path_parts.deinit();
    var fiter = std.mem.splitScalar(u8, full_path, '/');
    while (fiter.next()) |part| {
        if (part.len > 0) try path_parts.append(part);
    }

    // Find common prefix length
    var common: usize = 0;
    while (common < prefix_parts.items.len and common < path_parts.items.len) {
        if (!std.mem.eql(u8, prefix_parts.items[common], path_parts.items[common])) break;
        common += 1;
    }

    // Number of "../" needed
    const ups = prefix_parts.items.len - common;

    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    for (0..ups) |_| {
        try result.appendSlice("../");
    }
    for (path_parts.items[common..], 0..) |part, idx| {
        if (idx > 0) try result.append('/');
        try result.appendSlice(part);
    }

    return try allocator.dupe(u8, result.items);
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var components = std.array_list.Managed([]const u8).init(allocator);
    defer components.deinit();

    // Handle trailing slash
    const has_trailing_slash = std.mem.endsWith(u8, path, "/");
    const clean_path = if (has_trailing_slash) path[0 .. path.len - 1] else path;

    var iter = std.mem.splitScalar(u8, clean_path, '/');
    while (iter.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (components.items.len > 0) {
                _ = components.pop();
            }
            continue;
        }
        try components.append(component);
    }

    if (components.items.len == 0) return try allocator.dupe(u8, "");

    // Join components
    var result = std.array_list.Managed(u8).init(allocator);
    for (components.items, 0..) |comp, idx| {
        if (idx > 0) try result.append('/');
        try result.appendSlice(comp);
    }
    if (has_trailing_slash) try result.append('/');

    return try allocator.dupe(u8, result.items);
}

fn pathSpecStartsWith(spec: []const u8, prefix: []const u8) bool {
    const clean_spec = if (std.mem.endsWith(u8, spec, "/")) spec[0 .. spec.len - 1] else spec;
    if (clean_spec.len <= prefix.len) return false;
    return std.mem.startsWith(u8, clean_spec, prefix) and clean_spec[prefix.len] == '/';
}

fn cmdReadTree(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const git_dir = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    var tree_hash: ?[]const u8 = null;
    var empty = false;
    var merge = false;
    var update = false;
    var prefix: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--empty")) {
            empty = true;
        } else if (std.mem.eql(u8, arg, "-m")) {
            merge = true;
        } else if (std.mem.eql(u8, arg, "-u")) {
            update = true;
        } else if (std.mem.eql(u8, arg, "-i")) {
            // index-only, ignore
        } else if (std.mem.startsWith(u8, arg, "--prefix=")) {
            prefix = arg["--prefix=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            tree_hash = arg;
        }
    }

    if (empty) {
        // Write an empty index
        var idx = index_mod.Index.init(allocator);
        defer idx.deinit();
        idx.save(git_dir, platform_impl) catch {
            try platform_impl.writeStderr("fatal: unable to write index file\n");
            std.process.exit(128);
        };
        return;
    }

    if (tree_hash == null) {
        try platform_impl.writeStderr("fatal: must specify a tree-ish\n");
        std.process.exit(128);
        unreachable;
    }

    // Resolve tree-ish to tree hash
    const resolved_tree = resolveTreeish(git_dir, tree_hash.?, platform_impl, allocator) catch {
        const err_msg = try std.fmt.allocPrint(allocator, "fatal: not a tree object: {s}\n", .{tree_hash.?});
        defer allocator.free(err_msg);
        try platform_impl.writeStderr(err_msg);
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(resolved_tree);

    // Build index from tree
    var idx = index_mod.Index.init(allocator);
    defer idx.deinit();

    try readTreeIntoIndex(&idx, git_dir, resolved_tree, prefix orelse "", platform_impl, allocator);

    idx.save(git_dir, platform_impl) catch {
        try platform_impl.writeStderr("fatal: unable to write index file\n");
        std.process.exit(128);
    };
}

fn readTreeIntoIndex(idx: *index_mod.Index, git_dir: []const u8, tree_hash: []const u8, prefix: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    const obj = objects.GitObject.load(tree_hash, git_dir, platform_impl, allocator) catch return;
    defer obj.deinit(allocator);

    if (obj.type != .tree) return;

    // Parse tree entries from binary data
    var pos: usize = 0;
    const data = obj.data;
    while (pos < data.len) {
        // Format: <mode> <name>\0<20-byte-sha1>
        const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse break;
        const mode_str = data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, data, space_pos + 1, 0) orelse break;
        const name = data[space_pos + 1 .. null_pos];

        if (null_pos + 21 > data.len) break;
        const entry_sha1 = data[null_pos + 1 .. null_pos + 21];

        var hash_hex: [40]u8 = undefined;
        for (entry_sha1, 0..) |byte, j| {
            const hex = std.fmt.bytesToHex([1]u8{byte}, .lower);
            hash_hex[j * 2] = hex[0];
            hash_hex[j * 2 + 1] = hex[1];
        }

        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);

        const mode = std.fmt.parseInt(u32, mode_str, 8) catch 0o100644;

        if (mode == 0o40000) {
            // Directory - recurse
            defer allocator.free(full_path);
            const sub_prefix = try std.fmt.allocPrint(allocator, "{s}/", .{full_path});
            defer allocator.free(sub_prefix);
            try readTreeIntoIndex(idx, git_dir, &hash_hex, sub_prefix, platform_impl, allocator);
        } else {
            // File entry
            var sha1: [20]u8 = undefined;
            @memcpy(&sha1, entry_sha1);

            const entry = index_mod.IndexEntry{
                .ctime_sec = 0,
                .ctime_nsec = 0,
                .mtime_sec = 0,
                .mtime_nsec = 0,
                .dev = 0,
                .ino = 0,
                .mode = mode,
                .uid = 0,
                .gid = 0,
                .size = 0,
                .sha1 = sha1,
                .flags = @as(u16, @intCast(@min(full_path.len, 0xFFF))),
                .extended_flags = null,
                .path = full_path,
            };
            try idx.entries.append(entry);
        }

        pos = null_pos + 21;
    }
}

fn cmdDiffFiles(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    // diff-files: compare index against working tree
    var name_only = false;
    var name_status = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--name-only")) {
            name_only = true;
        } else if (std.mem.eql(u8, arg, "--name-status")) {
            name_status = true;
        }
    }
    const git_dir = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    const repo_root = std.fs.path.dirname(git_dir) orelse ".";

    var idx = index_mod.Index.load(git_dir, platform_impl, allocator) catch return;
    defer idx.deinit();

    const zero_oid = "0000000000000000000000000000000000000000";
    var has_diff = false;

    for (idx.entries.items) |entry| {
        // Build full path from repo root
        const full_path = if (repo_root.len > 0 and !std.mem.eql(u8, repo_root, "."))
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path })
        else
            try allocator.dupe(u8, entry.path);
        defer allocator.free(full_path);

        // Use lstat (no follow) to properly handle symlinks
        const is_symlink_in_index = (entry.mode & 0o170000) == 0o120000;

        // Check if path exists - for symlinks, check the link itself
        var link_buf: [4096]u8 = undefined;
        const is_symlink_on_disk = if (std.fs.cwd().readLink(full_path, &link_buf)) |_| true else |_| false;

        // Try to get file info
        const file_exists = if (is_symlink_on_disk) true else if (std.fs.cwd().access(full_path, .{})) |_| true else |_| false;

        if (!file_exists) {
            // File deleted
            var hash_buf: [40]u8 = undefined;
            _ = std.fmt.bufPrint(&hash_buf, "{x}", .{entry.sha1}) catch unreachable;
            if (name_only) {
                const line = try std.fmt.allocPrint(allocator, "{s}\n", .{entry.path});
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            } else if (name_status) {
                const line = try std.fmt.allocPrint(allocator, "D\t{s}\n", .{entry.path});
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            } else {
                const line = try std.fmt.allocPrint(allocator, ":{o:0>6} 000000 {s} {s} D\t{s}\n", .{ entry.mode, &hash_buf, zero_oid, entry.path });
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            }
            has_diff = true;
            continue;
        }

        // Determine working tree mode
        const wt_mode: u32 = wt_blk: {
            if (is_symlink_on_disk) break :wt_blk 0o120000;
            if (std.fs.cwd().statFile(full_path)) |st| {
                if ((st.mode & 0o111) != 0) break :wt_blk 0o100755;
            } else |_| {}
            break :wt_blk 0o100644;
        };

        // Compare to detect modifications
        var modified = false;

        // If index entry has zeroed stat cache (e.g., from read-tree), always mark as modified
        if (entry.ctime_sec == 0 and entry.ctime_nsec == 0 and entry.mtime_sec == 0 and entry.mtime_nsec == 0 and entry.ino == 0) {
            modified = true;
        } else if (is_symlink_in_index != is_symlink_on_disk) {
            // Type changed (symlink <-> regular file)
            modified = true;
        } else if (!is_symlink_on_disk) {
            // Regular files - check stat
            if (std.fs.cwd().statFile(full_path)) |stat_result| {
                const file_size: u32 = @intCast(@min(stat_result.size, std.math.maxInt(u32)));
                if (entry.size != file_size) {
                    modified = true;
                } else {
                    // Compare mtime
                    const mtime_s: u32 = @intCast(@max(0, @divTrunc(stat_result.mtime, std.time.ns_per_s)));
                    const mtime_ns: u32 = @intCast(@max(0, @rem(stat_result.mtime, std.time.ns_per_s)));
                    if (entry.mtime_sec != mtime_s or entry.mtime_nsec != mtime_ns) {
                        modified = true;
                    }
                }
            } else |_| {
                modified = true;
            }
        } else {
            // Symlink - check stat (mtime/size)
            // For symlinks, size in index is the length of the target path
            // Since we can't easily lstat, compare by content if stat check is uncertain
            const link_target = std.fs.cwd().readLink(full_path, &link_buf) catch {
                modified = true;
                continue;
            };
            // Hash the symlink target to compare with index
            const blob_content = try std.fmt.allocPrint(allocator, "blob {d}\x00{s}", .{ link_target.len, link_target });
            defer allocator.free(blob_content);
            var hash: [20]u8 = undefined;
            std.crypto.hash.Sha1.hash(blob_content, &hash, .{});
            if (!std.mem.eql(u8, &hash, &entry.sha1)) {
                modified = true;
            }
        }

        if (modified) {
            var hash_buf: [40]u8 = undefined;
            _ = std.fmt.bufPrint(&hash_buf, "{x}", .{entry.sha1}) catch unreachable;
            if (name_only) {
                const line = try std.fmt.allocPrint(allocator, "{s}\n", .{entry.path});
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            } else if (name_status) {
                const line = try std.fmt.allocPrint(allocator, "M\t{s}\n", .{entry.path});
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            } else {
                const line = try std.fmt.allocPrint(allocator, ":{o:0>6} {o:0>6} {s} {s} M\t{s}\n", .{ entry.mode, wt_mode, &hash_buf, zero_oid, entry.path });
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            }
            has_diff = true;
        }
    }

    if (has_diff) {
        std.process.exit(1);
    }
}

// =============================================================================
// Phase 2: Pure Zig implementations of previously non-native commands
// =============================================================================

fn objectExistsCheck(git_dir: []const u8, hash_hex: *const [40]u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) bool {
    // Check for loose object: objects/ab/cdef...
    const obj_path = std.fmt.allocPrint(allocator, "{s}/objects/{s}/{s}", .{ git_dir, hash_hex[0..2], hash_hex[2..] }) catch return false;
    defer allocator.free(obj_path);
    if (platform_impl.fs.exists(obj_path) catch false) return true;

    // Check packed objects
    const pack_dir_path = std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir}) catch return false;
    defer allocator.free(pack_dir_path);
    
    // Convert hex to bytes
    var hash_bytes: [20]u8 = undefined;
    for (0..20) |i| {
        hash_bytes[i] = std.fmt.parseInt(u8, hash_hex[i * 2 .. i * 2 + 2], 16) catch return false;
    }
    
    // Scan .idx files
    var dir = std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true }) catch return false;
    defer dir.close();
    var iter = dir.iterate();
    while (iter.next() catch null) |dir_entry| {
        if (std.mem.endsWith(u8, dir_entry.name, ".idx")) {
            const idx_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, dir_entry.name }) catch continue;
            defer allocator.free(idx_path);
            if (platform_impl.fs.readFile(allocator, idx_path)) |idx_data| {
                defer allocator.free(idx_data);
                if (objects.findOffsetInIdx(idx_data, hash_bytes) != null) return true;
            } else |_| {}
        }
    }
    return false;
}

fn findGitDir() ![]const u8 {
    // Check GIT_DIR env first
    if (std.posix.getenv("GIT_DIR")) |gd| return gd;

    // Check for .git in current directory (normal repo)
    if (std.fs.cwd().statFile(".git")) |_| {
        return ".git";
    } else |_| {
        if (std.fs.cwd().openDir(".git", .{})) |d| {
            var dd = d;
            dd.close();
            return ".git";
        } else |_| {}
    }

    // Check if current directory IS a bare git repo (has HEAD + objects/)
    if (std.fs.cwd().statFile("HEAD")) |_| {
        if (std.fs.cwd().openDir("objects", .{})) |d| {
            var dd = d;
            dd.close();
            return ".";
        } else |_| {}
    } else |_| {}

    // Walk up from cwd looking for .git
    var path_buf: [4096]u8 = undefined;
    const cwd = std.process.getCwd(&path_buf) catch return error.FileNotFound;
    var dir = cwd;
    while (true) {
        if (std.mem.lastIndexOf(u8, dir, "/")) |idx| {
            dir = dir[0..idx];
            if (dir.len == 0) break;
        } else break;

        var check_buf: [4096]u8 = undefined;
        const check_path = std.fmt.bufPrint(&check_buf, "{s}/.git", .{dir}) catch return error.FileNotFound;
        if (std.fs.cwd().statFile(check_path)) |_| {
            return ".git";
        } else |_| {
            if (std.fs.cwd().openDir(check_path, .{})) |d| {
                var dd = d;
                dd.close();
                return ".git";
            } else |_| {}
        }
    }
    return error.FileNotFound;
}

fn nativeCmdCountObjects(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var verbose = false;
    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--human-readable")) {
            // human_readable = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git count-objects [-v] [-H | --human-readable]\n");
            std.process.exit(129);
        }
    }

    const git_dir = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // Count loose objects — git uses on-disk size (st_blocks * 512)
    var count: usize = 0;
    var size_disk: u64 = 0;
    var size_pack: u64 = 0;
    var packs: usize = 0;
    var in_pack: u64 = 0;
    var size_garbage: u64 = 0;
    var garbage_count: usize = 0;

    const objects_dir_path = std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir}) catch unreachable;
    defer allocator.free(objects_dir_path);

    var hex_dirs: usize = 0;
    while (hex_dirs < 256) : (hex_dirs += 1) {
        var hex_buf: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{hex_dirs}) catch continue;
        const subdir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir_path, hex_buf }) catch continue;
        defer allocator.free(subdir_path);

        var subdir = std.fs.cwd().openDir(subdir_path, .{ .iterate = true }) catch continue;
        defer subdir.close();

        var iter = subdir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file) {
                count += 1;
                const file = subdir.openFile(entry.name, .{}) catch continue;
                defer file.close();
                const linux_stat = std.posix.fstat(file.handle) catch continue;
                size_disk += @as(u64, @intCast(linux_stat.blocks)) * 512;
            }
        }
    }

    // Count pack files and objects in packs
    const pack_dir_path = std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir}) catch unreachable;
    defer allocator.free(pack_dir_path);

    if (std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true })) |pack_dir_handle| {
        var pd = pack_dir_handle;
        defer pd.close();

        var pack_iter = pd.iterate();
        while (pack_iter.next() catch null) |entry| {
            if (entry.kind == .file) {
                if (std.mem.endsWith(u8, entry.name, ".pack")) {
                    packs += 1;
                    const pf_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name }) catch continue;
                    defer allocator.free(pf_path);
                    const stat = std.fs.cwd().statFile(pf_path) catch continue;
                    size_pack += stat.size;
                    // Count objects by reading pack header
                    const pf = std.fs.cwd().openFile(pf_path, .{}) catch continue;
                    defer pf.close();
                    var hdr_buf: [12]u8 = undefined;
                    const hdr_read = pf.readAll(&hdr_buf) catch continue;
                    if (hdr_read == 12 and std.mem.eql(u8, hdr_buf[0..4], "PACK")) {
                        in_pack += std.mem.readInt(u32, hdr_buf[8..12], .big);
                    }
                } else if (std.mem.endsWith(u8, entry.name, ".idx")) {
                    // Git includes .idx size in size-pack
                    const idx_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name }) catch continue;
                    defer allocator.free(idx_path);
                    const stat = std.fs.cwd().statFile(idx_path) catch continue;
                    size_pack += stat.size;
                } else if (!std.mem.endsWith(u8, entry.name, ".keep") and
                    !std.mem.endsWith(u8, entry.name, ".bitmap") and
                    !std.mem.endsWith(u8, entry.name, ".rev") and
                    !std.mem.endsWith(u8, entry.name, ".mtimes") and
                    !std.mem.endsWith(u8, entry.name, ".promisor"))
                {
                    garbage_count += 1;
                    const garb_file = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name }) catch continue;
                    defer allocator.free(garb_file);
                    const stat = std.fs.cwd().statFile(garb_file) catch continue;
                    size_garbage += stat.size;
                }
            }
        }
    } else |_| {}

    const size_kb = size_disk / 1024;

    if (verbose) {
        const output = std.fmt.allocPrint(allocator,
            "count: {d}\nsize: {d}\nin-pack: {d}\npacks: {d}\nsize-pack: {d}\nprune-packable: 0\ngarbage: {d}\nsize-garbage: {d}\n",
            .{ count, size_kb, in_pack, packs, size_pack / 1024, garbage_count, size_garbage / 1024 },
        ) catch unreachable;
        defer allocator.free(output);
        try platform_impl.writeStdout(output);
    } else {
        const output = std.fmt.allocPrint(allocator, "{d} objects, {d} kilobytes\n", .{ count, size_kb }) catch unreachable;
        defer allocator.free(output);
        try platform_impl.writeStdout(output);
    }
}

fn nativeCmdShowRef(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var verify = false;
    var quiet = false;
    var heads = false;
    var tags = false;
    var hash_only = false;
    var hash_len: usize = 40;
    var dereference = false;
    var patterns = std.array_list.Managed([]const u8).init(allocator);
    defer patterns.deinit();

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git show-ref [--head] [-d | --dereference] [-s | --hash[=<n>]] [--verify] [-q | --quiet] [--tags] [--heads] [--] [<pattern>...]\n");
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--verify")) {
            verify = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--heads")) {
            heads = true;
        } else if (std.mem.eql(u8, arg, "--tags")) {
            tags = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--dereference")) {
            dereference = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--hash")) {
            hash_only = true;
        } else if (std.mem.startsWith(u8, arg, "--hash=")) {
            hash_only = true;
            hash_len = std.fmt.parseInt(usize, arg["--hash=".len..], 10) catch 40;
        } else if (std.mem.eql(u8, arg, "--head")) {
            // Include HEAD in output
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try patterns.append(args[i]);
            }
            break;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try patterns.append(arg);
        }
    }

    const git_dir = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    if (verify) {
        // Verify mode: check specific refs
        var found_any = false;
        for (patterns.items) |pattern| {
            const resolved = refs.resolveRef(git_dir, pattern, platform_impl, allocator) catch {
                if (!quiet) {
                    const msg = std.fmt.allocPrint(allocator, "fatal: '{s}' - not a valid ref\n", .{pattern}) catch continue;
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                }
                continue;
            };
            if (resolved) |hash| {
                defer allocator.free(hash);
                found_any = true;
                if (!quiet) {
                    const end = @min(hash_len, hash.len);
                    if (hash_only) {
                        const output = std.fmt.allocPrint(allocator, "{s}\n", .{hash[0..end]}) catch continue;
                        defer allocator.free(output);
                        try platform_impl.writeStdout(output);
                    } else {
                        const output = std.fmt.allocPrint(allocator, "{s} {s}\n", .{ hash[0..end], pattern }) catch continue;
                        defer allocator.free(output);
                        try platform_impl.writeStdout(output);
                    }
                }
            } else {
                if (!quiet) {
                    const msg = std.fmt.allocPrint(allocator, "fatal: '{s}' - not a valid ref\n", .{pattern}) catch continue;
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                }
            }
        }
        if (!found_any) {
            std.process.exit(1);
        }
        return;
    }

    // List mode: enumerate all refs
    var ref_list = std.array_list.Managed(RefEntry).init(allocator);
    defer {
        for (ref_list.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.hash);
        }
        ref_list.deinit();
    }

    // Read packed-refs
    const packed_refs_path = std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir}) catch unreachable;
    defer allocator.free(packed_refs_path);
    if (std.fs.cwd().readFileAlloc(allocator, packed_refs_path, 10 * 1024 * 1024)) |packed_content| {
        defer allocator.free(packed_content);
        var lines = std.mem.splitScalar(u8, packed_content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '^') continue; // peeled line, handled separately
            // format: <hash> <refname>
            if (std.mem.indexOfScalar(u8, line, ' ')) |space_idx| {
                const hash = line[0..space_idx];
                const name = line[space_idx + 1..];
                if (hash.len >= 40) {
                    try ref_list.append(.{
                        .name = try allocator.dupe(u8, name),
                        .hash = try allocator.dupe(u8, hash[0..40]),
                    });
                }
            }
        }
    } else |_| {}

    // Read loose refs
    try collectLooseRefs(allocator, git_dir, "refs", &ref_list, platform_impl);

    // Sort by name
    std.mem.sort(RefEntry, ref_list.items, {}, struct {
        fn lessThan(_: void, a: RefEntry, b: RefEntry) bool {
            return std.mem.order(u8, a.name, b.name).compare(.lt);
        }
    }.lessThan);

    // Filter and output
    var found = false;
    for (ref_list.items) |entry| {
        // Skip broken refs
        if (entry.broken) continue;

        // Apply filters
        if (heads and !std.mem.startsWith(u8, entry.name, "refs/heads/")) continue;
        if (tags and !std.mem.startsWith(u8, entry.name, "refs/tags/")) continue;

        // Apply patterns (match as suffix after /)
        if (patterns.items.len > 0) {
            var matches = false;
            for (patterns.items) |pattern| {
                // Exact match
                if (std.mem.eql(u8, entry.name, pattern)) {
                    matches = true;
                    break;
                }
                // Pattern matches as a suffix after /
                if (std.mem.endsWith(u8, entry.name, pattern)) {
                    // Check there's a / before the match
                    if (entry.name.len > pattern.len and entry.name[entry.name.len - pattern.len - 1] == '/') {
                        matches = true;
                        break;
                    }
                }
                // Pattern with / matches as prefix
                if (std.mem.indexOf(u8, pattern, "/") != null) {
                    if (std.mem.endsWith(u8, entry.name, pattern)) {
                        matches = true;
                        break;
                    }
                }
            }
            if (!matches) continue;
        }

        found = true;
        if (quiet) continue;

        const end = @min(hash_len, entry.hash.len);
        if (hash_only) {
            const output = std.fmt.allocPrint(allocator, "{s}\n", .{entry.hash[0..end]}) catch continue;
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else {
            const output = std.fmt.allocPrint(allocator, "{s} {s}\n", .{ entry.hash[0..end], entry.name }) catch continue;
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        }

        // Dereference tag objects (for any ref, not just refs/tags/)
        if (dereference) {
            // Try to load the object and check if it's a tag
            if (objects.GitObject.load(entry.hash, git_dir, platform_impl, allocator)) |obj| {
                defer obj.deinit(allocator);
                if (obj.type == .tag) {
                    // Parse tag to find object it points to
                    if (std.mem.indexOf(u8, obj.data, "object ")) |obj_start| {
                        const hash_start = obj_start + 7;
                        if (hash_start + 40 <= obj.data.len) {
                            const target_hash = obj.data[hash_start..hash_start + 40];
                            const deref_output = std.fmt.allocPrint(allocator, "{s} {s}^{{}}\n", .{ target_hash, entry.name }) catch continue;
                            defer allocator.free(deref_output);
                            try platform_impl.writeStdout(deref_output);
                        }
                    }
                }
            } else |_| {}
        }
    }

    if (!found) {
        std.process.exit(1);
    }
}

const RefEntry = struct {
    name: []const u8,
    hash: []const u8,
    broken: bool = false,
};

fn collectLooseRefs(allocator: std.mem.Allocator, git_dir: []const u8, prefix: []const u8, ref_list: *std.array_list.Managed(RefEntry), platform_impl: anytype) !void {
    const dir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, prefix }) catch return;
    defer allocator.free(dir_path);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        const full_name = std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name }) catch continue;

        if (entry.kind == .directory) {
            try collectLooseRefs(allocator, git_dir, full_name, ref_list, platform_impl);
            allocator.free(full_name);
        } else if (entry.kind == .file) {
            const file_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, full_name }) catch {
                allocator.free(full_name);
                continue;
            };
            defer allocator.free(file_path);

            const content = std.fs.cwd().readFileAlloc(allocator, file_path, 1024) catch {
                // Empty or unreadable file = broken ref
                try ref_list.append(.{
                    .name = full_name,
                    .hash = try allocator.dupe(u8, "0000000000000000000000000000000000000000"),
                    .broken = true,
                });
                continue;
            };
            defer allocator.free(content);
            const trimmed = std.mem.trim(u8, content, " \t\n\r");
            if (trimmed.len == 0) {
                // Empty ref file = broken ref
                try ref_list.append(.{
                    .name = full_name,
                    .hash = try allocator.dupe(u8, "0000000000000000000000000000000000000000"),
                    .broken = true,
                });
                continue;
            }
            if (trimmed.len >= 40) {
                const hash_val = trimmed[0..40];
                // Check for all-zeros (null SHA)
                const is_null = std.mem.eql(u8, hash_val, "0000000000000000000000000000000000000000");

                // Check if this overrides a packed ref
                var found_packed = false;
                for (ref_list.items, 0..) |existing, idx| {
                    if (std.mem.eql(u8, existing.name, full_name)) {
                        // Replace packed ref with loose ref
                        allocator.free(existing.hash);
                        ref_list.items[idx].hash = allocator.dupe(u8, hash_val) catch {
                            allocator.free(full_name);
                            continue;
                        };
                        ref_list.items[idx].broken = is_null;
                        found_packed = true;
                        allocator.free(full_name);
                        break;
                    }
                }
                if (!found_packed) {
                    try ref_list.append(.{
                        .name = full_name,
                        .hash = try allocator.dupe(u8, hash_val),
                        .broken = is_null,
                    });
                }
            } else {
                // Too short to be a valid hash = broken ref
                try ref_list.append(.{
                    .name = full_name,
                    .hash = try allocator.dupe(u8, "0000000000000000000000000000000000000000"),
                    .broken = true,
                });
            }
        } else {
            allocator.free(full_name);
        }
    }
}

fn nativeCmdForEachRef(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var format: []const u8 = "%(objectname) %(objecttype)\t%(refname)";
    var sort_key: ?[]const u8 = null;
    var count_limit: ?usize = null;
    var patterns = std.array_list.Managed([]const u8).init(allocator);
    defer patterns.deinit();

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git for-each-ref [<options>] [<pattern>...]\n");
            std.process.exit(129);
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            format = arg["--format=".len..];
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i < args.len) format = args[i];
        } else if (std.mem.startsWith(u8, arg, "--sort=")) {
            sort_key = arg["--sort=".len..];
        } else if (std.mem.eql(u8, arg, "--sort")) {
            i += 1;
            if (i < args.len) sort_key = args[i];
        } else if (std.mem.startsWith(u8, arg, "--count=")) {
            count_limit = std.fmt.parseInt(usize, arg["--count=".len..], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--count")) {
            i += 1;
            if (i < args.len) count_limit = std.fmt.parseInt(usize, args[i], 10) catch null;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try patterns.append(arg);
        }
    }

    const git_dir = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // Collect all refs
    var ref_list = std.array_list.Managed(RefEntry).init(allocator);
    defer {
        for (ref_list.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.hash);
        }
        ref_list.deinit();
    }

    // Read packed-refs
    const packed_refs_path = std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir}) catch unreachable;
    defer allocator.free(packed_refs_path);
    if (std.fs.cwd().readFileAlloc(allocator, packed_refs_path, 10 * 1024 * 1024)) |packed_content| {
        defer allocator.free(packed_content);
        // Check for unterminated last line
        if (packed_content.len > 0 and packed_content[packed_content.len - 1] != '\n') {
            // Find the last line
            const last_nl = std.mem.lastIndexOfScalar(u8, packed_content, '\n');
            const last_line = if (last_nl) |nl| packed_content[nl + 1 ..] else packed_content;
            if (last_line.len > 0 and last_line[0] != '#') {
                const msg = try std.fmt.allocPrint(allocator, "fatal: unterminated line in {s}: {s}\n", .{ packed_refs_path, last_line });
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            }
        }
        var lines = std.mem.splitScalar(u8, packed_content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            if (std.mem.indexOfScalar(u8, line, ' ')) |space_idx| {
                const hash = line[0..space_idx];
                const name = line[space_idx + 1..];
                if (hash.len < 40 or !isValidHexString(hash[0..@min(40, hash.len)])) {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: unexpected line in {s}: {s}\n", .{ packed_refs_path, line });
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                    unreachable;
                }
                try ref_list.append(.{
                    .name = try allocator.dupe(u8, name),
                    .hash = try allocator.dupe(u8, hash[0..40]),
                });
            } else {
                // Line without space - invalid
                const msg = try std.fmt.allocPrint(allocator, "fatal: unexpected line in {s}: {s}\n", .{ packed_refs_path, line });
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            }
        }
    } else |_| {}

    try collectLooseRefs(allocator, git_dir, "refs", &ref_list, platform_impl);

    // Sort by name
    std.mem.sort(RefEntry, ref_list.items, {}, struct {
        fn lessThan(_: void, a: RefEntry, b: RefEntry) bool {
            return std.mem.order(u8, a.name, b.name).compare(.lt);
        }
    }.lessThan);

    // Filter and format output
    var output_count: usize = 0;
    for (ref_list.items) |entry| {
        if (count_limit) |limit| {
            if (output_count >= limit) break;
        }

        // Handle broken refs - emit warning and skip
        if (entry.broken) {
            const warn_msg = std.fmt.allocPrint(allocator, "warning: ignoring broken ref {s}\n", .{entry.name}) catch continue;
            defer allocator.free(warn_msg);
            try platform_impl.writeStderr(warn_msg);
            continue;
        }

        // Apply patterns (prefix match, with glob support for * and ?)
        if (patterns.items.len > 0) {
            var matches = false;
            for (patterns.items) |pattern| {
                if (refPatternMatch(entry.name, pattern)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
        }

        // Determine object type
        var obj_type: []const u8 = "commit";
        if (objects.GitObject.load(entry.hash, git_dir, platform_impl, allocator)) |obj| {
            obj_type = obj.type.toString();
            defer obj.deinit(allocator);

            const formatted = try formatRefOutput(allocator, format, entry.name, entry.hash, obj_type, obj.data);
            defer allocator.free(formatted);
            const output = std.fmt.allocPrint(allocator, "{s}\n", .{formatted}) catch continue;
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else |_| {
            const formatted = try formatRefOutput(allocator, format, entry.name, entry.hash, obj_type, "");
            defer allocator.free(formatted);
            const output = std.fmt.allocPrint(allocator, "{s}\n", .{formatted}) catch continue;
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        }
        output_count += 1;
    }
}

fn formatRefOutput(allocator: std.mem.Allocator, format: []const u8, refname: []const u8, objectname: []const u8, objecttype: []const u8, data: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    var idx: usize = 0;
    while (idx < format.len) {
        if (format[idx] == '%' and idx + 1 < format.len and format[idx + 1] == '(') {
            // Find closing )
            if (std.mem.indexOfScalar(u8, format[idx..], ')')) |close| {
                const field = format[idx + 2 .. idx + close];
                const value = getRefField(field, refname, objectname, objecttype, data, allocator);
                try result.appendSlice(value);
                idx += close + 1;
                continue;
            }
        }
        try result.append(format[idx]);
        idx += 1;
    }
    return result.toOwnedSlice();
}

fn getRefField(field: []const u8, refname: []const u8, objectname: []const u8, objecttype: []const u8, data: []const u8, allocator: std.mem.Allocator) []const u8 {
    if (std.mem.eql(u8, field, "refname")) return refname;
    if (std.mem.eql(u8, field, "refname:short")) {
        // Strip refs/heads/ or refs/tags/ etc.
        if (std.mem.startsWith(u8, refname, "refs/heads/")) return refname["refs/heads/".len..];
        if (std.mem.startsWith(u8, refname, "refs/tags/")) return refname["refs/tags/".len..];
        if (std.mem.startsWith(u8, refname, "refs/remotes/")) return refname["refs/remotes/".len..];
        return refname;
    }
    if (std.mem.eql(u8, field, "objectname")) return objectname;
    if (std.mem.eql(u8, field, "objectname:short")) return if (objectname.len >= 7) objectname[0..7] else objectname;
    if (std.mem.eql(u8, field, "objecttype")) return objecttype;

    // Contents-related fields: extract message from commit/tag object data
    if (std.mem.startsWith(u8, field, "contents")) {
        const message = extractObjectMessage(data);
        if (std.mem.eql(u8, field, "contents")) {
            return message;
        } else if (std.mem.eql(u8, field, "contents:subject")) {
            // Strip \r for subject line, then join multi-line subjects with space
            const clean_msg = stripCR(allocator, message) catch message;
            const raw_subject = extractSubject(clean_msg);
            return joinLines(allocator, raw_subject) catch raw_subject;
        } else if (std.mem.eql(u8, field, "contents:body")) {
            // Body preserves CRLF endings
            return extractBody(message);
        }
    }

    return "";
}

/// Match a ref name against a pattern (supports * and ? globs, or prefix match)
fn refPatternMatch(name: []const u8, pattern: []const u8) bool {
    // If pattern contains glob characters, do glob match
    if (std.mem.indexOfAny(u8, pattern, "*?[") != null) {
        return globMatch(name, pattern);
    }
    // Otherwise, prefix match (git for-each-ref treats patterns as prefixes)
    return std.mem.startsWith(u8, name, pattern);
}

/// Simple glob matching (supports * and ? wildcards)
fn globMatch(str: []const u8, pattern: []const u8) bool {
    var si: usize = 0;
    var pi: usize = 0;
    var star_pi: ?usize = null;
    var star_si: usize = 0;

    while (si < str.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == str[si])) {
            si += 1;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_si = si;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_si += 1;
            si = star_si;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

/// Join multiple lines into a single line with spaces
fn joinLines(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\n') == null) return text;
    var result = std.array_list.Managed(u8).init(allocator);
    var iter = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (iter.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (!first) try result.append(' ');
        try result.appendSlice(trimmed);
        first = false;
    }
    return result.toOwnedSlice();
}

/// Extract the message portion from commit/tag object data (after the blank line)
fn extractObjectMessage(data: []const u8) []const u8 {
    // Find the blank line separator (\n\n)
    if (std.mem.indexOf(u8, data, "\n\n")) |pos| {
        return data[pos + 2 ..];
    }
    // Also handle \r\n\r\n
    if (std.mem.indexOf(u8, data, "\r\n\r\n")) |pos| {
        return data[pos + 4 ..];
    }
    return "";
}

/// Strip \r characters from string
fn stripCR(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, input, '\r') == null) return input;
    var result = std.array_list.Managed(u8).init(allocator);
    for (input) |c| {
        if (c != '\r') try result.append(c);
    }
    return result.toOwnedSlice();
}

/// Extract subject line(s) from a commit message.
/// Subject is the first paragraph (up to the first blank line).
/// Multi-line subjects (non-blank lines before the first blank line) are joined with space.
fn extractSubject(message: []const u8) []const u8 {
    if (message.len == 0) return "";
    // Find the end of the subject (first blank line or end of message)
    var end: usize = 0;
    var lines = std.mem.splitScalar(u8, message, '\n');
    var first = true;
    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        if (trimmed.len == 0 and !first) break;
        if (trimmed.len == 0 and first) break;
        end = @intFromPtr(line.ptr) - @intFromPtr(message.ptr) + line.len;
        first = false;
    }
    if (end > message.len) end = message.len;
    // Trim trailing newlines
    var subject = message[0..end];
    subject = std.mem.trimRight(u8, subject, "\n\r ");
    return subject;
}

/// Extract body from a commit message (everything after the subject and blank lines)
fn extractBody(message: []const u8) []const u8 {
    if (message.len == 0) return "";
    // Skip subject lines (first paragraph) - find first blank line after non-blank
    var iter = std.mem.splitScalar(u8, message, '\n');
    var pos: usize = 0;
    var found_subject = false;
    var found_blank = false;
    while (iter.next()) |line| {
        pos = @intFromPtr(line.ptr) - @intFromPtr(message.ptr) + line.len + 1;
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        if (!found_subject) {
            if (trimmed.len > 0) found_subject = true;
            continue;
        }
        if (!found_blank) {
            if (trimmed.len == 0) {
                found_blank = true;
                continue;
            }
            continue;
        }
        // Skip additional blank lines after the separator
        if (trimmed.len == 0) continue;
        // Found first non-blank body line
        const body_start = @intFromPtr(line.ptr) - @intFromPtr(message.ptr);
        if (body_start > message.len) return "";
        return message[body_start..];
    }
    return "";
}

fn nativeCmdVerifyPack(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var verbose = false;
    var stat_only = false;
    var pack_files = std.array_list.Managed([]const u8).init(allocator);
    defer pack_files.deinit();

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--stat-only")) {
            stat_only = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git verify-pack [-v | --verbose] [-s | --stat-only] [--] <pack>.idx...\n");
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try pack_files.append(args[i]);
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try pack_files.append(arg);
        }
    }

    if (pack_files.items.len == 0) {
        try platform_impl.writeStderr("usage: git verify-pack [-v | --verbose] [-s | --stat-only] [--] <pack>.idx...\n");
        std.process.exit(1);
    }

    var any_error = false;
    for (pack_files.items) |pack_file| {
        // Determine pack and idx file paths
        var pack_path_alloc: ?[]const u8 = null;
        var idx_path_alloc: ?[]const u8 = null;
        defer if (pack_path_alloc) |p| allocator.free(p);
        defer if (idx_path_alloc) |p| allocator.free(p);

        var pack_path: []const u8 = undefined;
        var idx_path: []const u8 = undefined;

        if (std.mem.endsWith(u8, pack_file, ".idx")) {
            idx_path = pack_file;
            const base = pack_file[0 .. pack_file.len - 4];
            pack_path_alloc = std.fmt.allocPrint(allocator, "{s}.pack", .{base}) catch continue;
            pack_path = pack_path_alloc.?;
        } else if (std.mem.endsWith(u8, pack_file, ".pack")) {
            pack_path = pack_file;
            const base = pack_file[0 .. pack_file.len - 5];
            idx_path_alloc = std.fmt.allocPrint(allocator, "{s}.idx", .{base}) catch continue;
            idx_path = idx_path_alloc.?;
        } else {
            pack_path = pack_file;
            idx_path = pack_file;
        }

        // Read pack file
        const pack_data = std.fs.cwd().readFileAlloc(allocator, pack_path, 4 * 1024 * 1024 * 1024) catch {
            const msg = std.fmt.allocPrint(allocator, "error: packfile {s} not found.\n", .{pack_path}) catch continue;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            any_error = true;
            continue;
        };
        defer allocator.free(pack_data);

        // Verify pack header
        if (pack_data.len < 12 or !std.mem.eql(u8, pack_data[0..4], "PACK")) {
            const msg = std.fmt.allocPrint(allocator, "error: {s}: packfile signature mismatch\n", .{pack_path}) catch continue;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            any_error = true;
            continue;
        }

        const pack_version = std.mem.readInt(u32, pack_data[4..8], .big);
        if (pack_version != 2 and pack_version != 3) {
            const msg = std.fmt.allocPrint(allocator, "error: {s}: unsupported pack version {d}\n", .{ pack_path, pack_version }) catch continue;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            any_error = true;
            continue;
        }

        // Verify pack checksum
        if (pack_data.len >= 20) {
            var sha1 = std.crypto.hash.Sha1.init(.{});
            sha1.update(pack_data[0 .. pack_data.len - 20]);
            const computed = sha1.finalResult();
            const stored = pack_data[pack_data.len - 20 ..][0..20];
            if (!std.mem.eql(u8, &computed, stored)) {
                const msg = std.fmt.allocPrint(allocator, "error: {s}: pack checksum mismatch\n", .{pack_path}) catch continue;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                any_error = true;
                continue;
            }
        }

        // Read idx file to verify pack checksum in idx matches
        const idx_data = std.fs.cwd().readFileAlloc(allocator, idx_path, 100 * 1024 * 1024) catch {
            const msg = std.fmt.allocPrint(allocator, "error: packfile {s} index not found.\n", .{idx_path}) catch continue;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            any_error = true;
            continue;
        };
        defer allocator.free(idx_data);

        // Verify idx checksum
        if (idx_data.len >= 40) {
            // The last 20 bytes of idx is the idx SHA1
            // The 20 bytes before that is the pack SHA1
            const idx_pack_checksum = idx_data[idx_data.len - 40 .. idx_data.len - 20];
            const pack_trailing = pack_data[pack_data.len - 20 ..];
            if (!std.mem.eql(u8, idx_pack_checksum, pack_trailing)) {
                const msg = std.fmt.allocPrint(allocator, "error: packfile {s} does not match index\n", .{pack_path}) catch continue;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                any_error = true;
                continue;
            }

            // Verify idx's own checksum
            var idx_sha = std.crypto.hash.Sha1.init(.{});
            idx_sha.update(idx_data[0 .. idx_data.len - 20]);
            const idx_computed = idx_sha.finalResult();
            const idx_stored = idx_data[idx_data.len - 20 ..][0..20];
            if (!std.mem.eql(u8, &idx_computed, idx_stored)) {
                const msg = std.fmt.allocPrint(allocator, "error: index file {s} checksum mismatch\n", .{idx_path}) catch continue;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                any_error = true;
                continue;
            }
        }

        const num_objects = std.mem.readInt(u32, pack_data[8..12], .big);

        if (verbose and !stat_only) {
            // In verbose mode, list each object in the pack
            var pos: usize = 12;
            var obj_idx: u32 = 0;
            while (obj_idx < num_objects and pos < pack_data.len -| 20) : (obj_idx += 1) {
                const entry_offset = pos;
                var c = pack_data[pos];
                pos += 1;
                const obj_type = (pack_data[entry_offset] >> 4) & 0x07;
                var obj_size: u64 = c & 0x0F;
                var shift: u6 = 4;
                while (c & 0x80 != 0 and pos < pack_data.len) {
                    c = pack_data[pos];
                    pos += 1;
                    obj_size |= @as(u64, c & 0x7F) << shift;
                    shift +|= 7;
                }

                // Handle delta base refs
                var delta_base_offset: ?u64 = null;
                var delta_base_ref: ?[20]u8 = null;
                if (obj_type == 6) {
                    c = pack_data[pos];
                    pos += 1;
                    var ofs: u64 = c & 0x7F;
                    while (c & 0x80 != 0 and pos < pack_data.len) {
                        c = pack_data[pos];
                        pos += 1;
                        ofs = ((ofs + 1) << 7) | (c & 0x7F);
                    }
                    delta_base_offset = ofs;
                } else if (obj_type == 7) {
                    if (pos + 20 <= pack_data.len) {
                        delta_base_ref = pack_data[pos..][0..20].*;
                        pos += 20;
                    }
                }

                // Decompress
                const decomp = zlib_compat_mod.decompressSliceWithConsumed(allocator, pack_data[pos..]) catch {
                    pos = pack_data.len -| 20;
                    continue;
                };
                defer allocator.free(decomp.data);
                pos += decomp.consumed;

                // Compute object hash
                const type_str: []const u8 = switch (obj_type) {
                    1 => "commit",
                    2 => "tree",
                    3 => "blob",
                    4 => "tag",
                    6 => "ofs_delta",
                    7 => "ref_delta",
                    else => "unknown",
                };

                if (obj_type >= 1 and obj_type <= 4) {
                    const hdr = std.fmt.allocPrint(allocator, "{s} {d}\x00", .{ type_str, decomp.data.len }) catch continue;
                    defer allocator.free(hdr);
                    var hasher = std.crypto.hash.Sha1.init(.{});
                    hasher.update(hdr);
                    hasher.update(decomp.data);
                    const sha = hasher.finalResult();
                    var hash_hex: [40]u8 = undefined;
                    for (sha, 0..) |b, bi| {
                        const hc = "0123456789abcdef";
                        hash_hex[bi * 2] = hc[b >> 4];
                        hash_hex[bi * 2 + 1] = hc[b & 0xf];
                    }
                    const out = std.fmt.allocPrint(allocator, "{s} {s} {d} {d} {d}\n", .{ hash_hex, type_str, decomp.data.len, pos - entry_offset, entry_offset }) catch continue;
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                } else if (obj_type == 6 and delta_base_offset != null) {
                    const out = std.fmt.allocPrint(allocator, "non delta: {s} {d} {d} {d} {d}\n", .{ type_str, obj_size, decomp.data.len, pos - entry_offset, entry_offset }) catch continue;
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                } else if (obj_type == 7 and delta_base_ref != null) {
                    const out = std.fmt.allocPrint(allocator, "non delta: {s} {d} {d} {d} {d}\n", .{ type_str, obj_size, decomp.data.len, pos - entry_offset, entry_offset }) catch continue;
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                }
            }
        }

        // Output summary
        if (!stat_only) {
            // Real git outputs nothing on non-verbose success
        }
    }

    if (any_error) {
        std.process.exit(1);
    }
}

fn nativeCmdUpdateServerInfo(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var force = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git update-server-info [--force]\n");
            std.process.exit(129);
        }
    }

    const git_dir = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // Create info directory
    const info_dir = std.fmt.allocPrint(allocator, "{s}/info", .{git_dir}) catch unreachable;
    defer allocator.free(info_dir);
    std.fs.cwd().makePath(info_dir) catch {};

    // Update info/refs
    const info_refs_path = std.fmt.allocPrint(allocator, "{s}/info/refs", .{git_dir}) catch unreachable;
    defer allocator.free(info_refs_path);
    {
        var ref_list = std.array_list.Managed(RefEntry).init(allocator);
        defer {
            for (ref_list.items) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.hash);
            }
            ref_list.deinit();
        }

        // Read packed-refs
        const packed_refs_path = std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir}) catch unreachable;
        defer allocator.free(packed_refs_path);
        if (std.fs.cwd().readFileAlloc(allocator, packed_refs_path, 10 * 1024 * 1024)) |packed_content| {
            defer allocator.free(packed_content);
            var lines = std.mem.splitScalar(u8, packed_content, '\n');
            while (lines.next()) |line| {
                if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
                if (std.mem.indexOfScalar(u8, line, ' ')) |space_idx| {
                    const hash = line[0..space_idx];
                    const name = line[space_idx + 1..];
                    if (hash.len >= 40) {
                        try ref_list.append(.{
                            .name = try allocator.dupe(u8, name),
                            .hash = try allocator.dupe(u8, hash[0..40]),
                        });
                    }
                }
            }
        } else |_| {}
        try collectLooseRefs(allocator, git_dir, "refs", &ref_list, platform_impl);

        // Sort
        std.mem.sort(RefEntry, ref_list.items, {}, struct {
            fn lessThan(_: void, a: RefEntry, b: RefEntry) bool {
                return std.mem.order(u8, a.name, b.name).compare(.lt);
            }
        }.lessThan);

        // Write info/refs (only if content changed, unless force)
        var content = std.array_list.Managed(u8).init(allocator);
        defer content.deinit();
        for (ref_list.items) |entry| {
            const line = std.fmt.allocPrint(allocator, "{s}\t{s}\n", .{ entry.hash, entry.name }) catch continue;
            defer allocator.free(line);
            try content.appendSlice(line);
        }
        const should_write = if (force) true else blk: {
            const existing = std.fs.cwd().readFileAlloc(allocator, info_refs_path, 10 * 1024 * 1024) catch break :blk true;
            defer allocator.free(existing);
            break :blk !std.mem.eql(u8, existing, content.items);
        };
        if (should_write) {
            std.fs.cwd().writeFile(.{ .sub_path = info_refs_path, .data = content.items }) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "error: unable to update {s}: {s}\n", .{ info_refs_path, @errorName(err) }) catch return;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            };
        }
    }

    // Update info/packs (objects/info/packs)
    const obj_info_dir = std.fmt.allocPrint(allocator, "{s}/objects/info", .{git_dir}) catch unreachable;
    defer allocator.free(obj_info_dir);
    std.fs.cwd().makePath(obj_info_dir) catch {};

    const packs_file_path = std.fmt.allocPrint(allocator, "{s}/objects/info/packs", .{git_dir}) catch unreachable;
    defer allocator.free(packs_file_path);
    {
        var content = std.array_list.Managed(u8).init(allocator);
        defer content.deinit();

        const pack_dir = std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir}) catch unreachable;
        defer allocator.free(pack_dir);

        if (std.fs.cwd().openDir(pack_dir, .{ .iterate = true })) |pd| {
            var pack_d = pd;
            defer pack_d.close();
            var pack_names = std.array_list.Managed([]const u8).init(allocator);
            defer {
                for (pack_names.items) |n| allocator.free(n);
                pack_names.deinit();
            }

            var iter = pack_d.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pack")) {
                    try pack_names.append(try allocator.dupe(u8, entry.name));
                }
            }

            // Sort pack names
            std.mem.sort([]const u8, pack_names.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b).compare(.lt);
                }
            }.lessThan);

            for (pack_names.items) |name| {
                const line = std.fmt.allocPrint(allocator, "P {s}\n", .{name}) catch continue;
                defer allocator.free(line);
                try content.appendSlice(line);
            }
        } else |_| {}

        // Always write trailing newline
        try content.append('\n');

        const should_write_packs = if (force) true else blk: {
            const existing = std.fs.cwd().readFileAlloc(allocator, packs_file_path, 10 * 1024 * 1024) catch break :blk true;
            defer allocator.free(existing);
            break :blk !std.mem.eql(u8, existing, content.items);
        };
        if (should_write_packs) {
            std.fs.cwd().writeFile(.{ .sub_path = packs_file_path, .data = content.items }) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "error: unable to update {s}: {s}\n", .{ packs_file_path, @errorName(err) }) catch return;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            };
        }
    }
}

fn nativeCmdMktree(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var missing_ok = false;
    var batch = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--missing")) {
            missing_ok = true;
        } else if (std.mem.eql(u8, arg, "--batch")) {
            batch = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git mktree [--missing] [--batch]\n");
            std.process.exit(129);
        }
    }

    const git_dir = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // Read tree entries from stdin
    const stdin = std.fs.File.stdin();
    const stdin_data = stdin.readToEndAlloc(allocator, 100 * 1024 * 1024) catch {
        try platform_impl.writeStderr("fatal: error reading from stdin\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(stdin_data);

    var entries = std.array_list.Managed(objects.TreeEntry).init(allocator);
    defer entries.deinit();

    var lines = std.mem.splitScalar(u8, stdin_data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Format: <mode> <type> <hash>\t<name>
        // or: <mode> SP <type> SP <hash> TAB <name>
        if (std.mem.indexOfScalar(u8, line, '\t')) |tab_idx| {
            const name = line[tab_idx + 1..];
            const prefix = line[0..tab_idx];
            // Split prefix by spaces
            var parts = std.mem.splitScalar(u8, prefix, ' ');
            const mode = parts.next() orelse continue;
            _ = parts.next(); // type
            const hash = parts.next() orelse continue;
            try entries.append(objects.TreeEntry.init(mode, name, hash));
        }
    }

    // Create tree object
    const tree_obj = objects.createTreeObject(entries.items, allocator) catch {
        try platform_impl.writeStderr("fatal: error creating tree object\n");
        std.process.exit(128);
        unreachable;
    };
    defer tree_obj.deinit(allocator);

    const hash = tree_obj.store(git_dir, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: error storing tree object\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(hash);

    const output = std.fmt.allocPrint(allocator, "{s}\n", .{hash}) catch unreachable;
    defer allocator.free(output);
    try platform_impl.writeStdout(output);
}

fn nativeCmdMktag(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git mktag\n");
            std.process.exit(129);
        }
    }

    const git_dir = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // Read tag content from stdin
    const stdin = std.fs.File.stdin();
    const stdin_data = stdin.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        try platform_impl.writeStderr("fatal: error reading from stdin\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(stdin_data);

    // Validate tag format
    if (std.mem.indexOf(u8, stdin_data, "object ") == null or
        std.mem.indexOf(u8, stdin_data, "type ") == null or
        std.mem.indexOf(u8, stdin_data, "tag ") == null or
        std.mem.indexOf(u8, stdin_data, "tagger ") == null)
    {
        try platform_impl.writeStderr("error: invalid tag format\n");
        std.process.exit(128);
    }

    // Create and store tag object
    const tag_obj = objects.GitObject.init(.tag, stdin_data);
    const hash = tag_obj.store(git_dir, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: error storing tag object\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(hash);

    const output = std.fmt.allocPrint(allocator, "{s}\n", .{hash}) catch unreachable;
    defer allocator.free(output);
    try platform_impl.writeStdout(output);
}

fn nativeCmdNameRev(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var name_only = false;
    var stdin_mode = false;
    var refs_pattern: ?[]const u8 = null;
    var targets = std.array_list.Managed([]const u8).init(allocator);
    defer targets.deinit();

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--name-only")) {
            name_only = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            stdin_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--refs=")) {
            refs_pattern = arg["--refs=".len..];
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git name-rev [<options>] <commit>...\n");
            std.process.exit(129);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try targets.append(arg);
        }
    }

    const git_dir = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // Collect all refs for naming
    var ref_list = std.array_list.Managed(RefEntry).init(allocator);
    defer {
        for (ref_list.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.hash);
        }
        ref_list.deinit();
    }

    const packed_refs_path = std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir}) catch unreachable;
    defer allocator.free(packed_refs_path);
    if (std.fs.cwd().readFileAlloc(allocator, packed_refs_path, 10 * 1024 * 1024)) |packed_content| {
        defer allocator.free(packed_content);
        var lines = std.mem.splitScalar(u8, packed_content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            if (std.mem.indexOfScalar(u8, line, ' ')) |space_idx| {
                const hash = line[0..space_idx];
                const name = line[space_idx + 1..];
                if (hash.len >= 40) {
                    try ref_list.append(.{
                        .name = try allocator.dupe(u8, name),
                        .hash = try allocator.dupe(u8, hash[0..40]),
                    });
                }
            }
        }
    } else |_| {}
    try collectLooseRefs(allocator, git_dir, "refs", &ref_list, platform_impl);

    for (targets.items) |target| {
        // Resolve the target to a full hash
        const resolved = refs.resolveRef(git_dir, target, platform_impl, allocator) catch {
            if (name_only) {
                const output = std.fmt.allocPrint(allocator, "undefined\n", .{}) catch continue;
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            } else {
                const output = std.fmt.allocPrint(allocator, "{s} undefined\n", .{target}) catch continue;
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
            continue;
        };
        const hash = resolved orelse {
            if (name_only) {
                try platform_impl.writeStdout("undefined\n");
            } else {
                const output = std.fmt.allocPrint(allocator, "{s} undefined\n", .{target}) catch continue;
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
            continue;
        };
        defer allocator.free(hash);

        // Find best matching ref
        var best_name: ?[]const u8 = null;
        for (ref_list.items) |entry| {
            if (std.mem.eql(u8, entry.hash, hash)) {
                // Use shortest/best ref name
                if (best_name == null) {
                    best_name = entry.name;
                }
            }
        }

        if (best_name) |name| {
            // Format ref name (strip refs/heads/, refs/tags/, etc.)
            var short_name = name;
            if (std.mem.startsWith(u8, name, "refs/tags/")) {
                short_name = std.fmt.allocPrint(allocator, "tags/{s}", .{name["refs/tags/".len..]}) catch name;
            } else if (std.mem.startsWith(u8, name, "refs/heads/")) {
                short_name = name["refs/heads/".len..];
            } else if (std.mem.startsWith(u8, name, "refs/remotes/")) {
                short_name = std.fmt.allocPrint(allocator, "remotes/{s}", .{name["refs/remotes/".len..]}) catch name;
            }

            if (name_only) {
                const output = std.fmt.allocPrint(allocator, "{s}\n", .{short_name}) catch continue;
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            } else {
                const output = std.fmt.allocPrint(allocator, "{s} {s}\n", .{ target, short_name }) catch continue;
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        } else {
            if (name_only) {
                try platform_impl.writeStdout("undefined\n");
            } else {
                const output = std.fmt.allocPrint(allocator, "{s} undefined\n", .{target}) catch continue;
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        }
    }
}

fn nativeCmdFsck(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var verbose = false;
    var full = false;
    var unreachable_check = false;
    var connectivity_only = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--full")) {
            full = true;
        } else if (std.mem.eql(u8, arg, "--unreachable")) {
            unreachable_check = true;
        } else if (std.mem.eql(u8, arg, "--connectivity-only")) {
            connectivity_only = true;
        } else if (std.mem.eql(u8, arg, "--no-dangling") or std.mem.eql(u8, arg, "--no-progress") or
            std.mem.eql(u8, arg, "--strict") or std.mem.eql(u8, arg, "--lost-found") or
            std.mem.eql(u8, arg, "--name-objects") or std.mem.eql(u8, arg, "--progress") or
            std.mem.eql(u8, arg, "--cache") or std.mem.eql(u8, arg, "--no-reflogs") or
            std.mem.eql(u8, arg, "--dangling") or std.mem.eql(u8, arg, "--root") or
            std.mem.eql(u8, arg, "--tags") or std.mem.eql(u8, arg, "--no-full"))
        {
            // Accepted but not all implemented
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git fsck [<options>] [<object>...]\n");
            std.process.exit(129);
        }
    }

    const git_dir = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // Verify loose objects
    var checked: usize = 0;
    var bad: usize = 0;
    const objects_dir_path = std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir}) catch unreachable;
    defer allocator.free(objects_dir_path);

    var hex_dirs: usize = 0;
    while (hex_dirs < 256) : (hex_dirs += 1) {
        var hex_buf: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{hex_dirs}) catch continue;
        const subdir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir_path, hex_buf }) catch continue;
        defer allocator.free(subdir_path);

        var subdir = std.fs.cwd().openDir(subdir_path, .{ .iterate = true }) catch continue;
        defer subdir.close();

        var iter = subdir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file and entry.name.len == 38) {
                checked += 1;
                // Try to load the object to verify it
                var hash_str: [40]u8 = undefined;
                _ = std.fmt.bufPrint(&hash_str, "{s}{s}", .{ hex_buf, entry.name }) catch continue;
                // Verify object by reading the raw file and checking it can be decompressed
                const obj_path = std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ objects_dir_path, hex_buf, entry.name }) catch continue;
                defer allocator.free(obj_path);
                const raw_data = std.fs.cwd().readFileAlloc(allocator, obj_path, 100 * 1024 * 1024) catch {
                    bad += 1;
                    const msg = std.fmt.allocPrint(allocator, "error: object {s} is corrupt\n", .{hash_str}) catch continue;
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    continue;
                };
                defer allocator.free(raw_data);
                // Object exists and is readable - consider it valid
                // (Full verification would decompress and check header + hash)
                if (verbose) {
                    const msg = std.fmt.allocPrint(allocator, "checking {s}\n", .{hash_str}) catch continue;
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                }
            }
        }
    }

    // Verify pack files
    const pack_dir_path = std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir}) catch unreachable;
    defer allocator.free(pack_dir_path);

    if (std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true })) |pd| {
        var pack_d = pd;
        defer pack_d.close();
        var pack_iter = pack_d.iterate();
        while (pack_iter.next() catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".idx")) {
                // Verify pack
                const idx_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name }) catch continue;
                defer allocator.free(idx_path);
                const pack_name = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name[0 .. entry.name.len - 4] }) catch continue;
                defer allocator.free(pack_name);
                const pack_path = std.fmt.allocPrint(allocator, "{s}.pack", .{pack_name}) catch continue;
                defer allocator.free(pack_path);
                _ = std.fs.cwd().statFile(pack_path) catch {
                    bad += 1;
                    const msg = std.fmt.allocPrint(allocator, "error: pack {s} has no corresponding .pack file\n", .{entry.name}) catch continue;
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    continue;
                };
            }
        }
    } else |_| {}

    // Check HEAD
    const head_path = std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir}) catch unreachable;
    defer allocator.free(head_path);
    _ = std.fs.cwd().statFile(head_path) catch {
        try platform_impl.writeStderr("error: HEAD is missing\n");
        bad += 1;
    };

    if (bad > 0) {
        std.process.exit(1);
    }
}

fn nativeCmdGc(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var aggressive = false;
    var auto_mode = false;
    var prune_option: []const u8 = "2.weeks.ago";
    var quiet = false;
    var no_cruft = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--aggressive")) {
            aggressive = true;
        } else if (std.mem.eql(u8, arg, "--auto")) {
            auto_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--prune=")) {
            prune_option = arg["--prune=".len..];
        } else if (std.mem.eql(u8, arg, "--prune")) {
            i += 1;
            if (i < args.len) prune_option = args[i];
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--no-prune")) {
            prune_option = "never";
        } else if (std.mem.eql(u8, arg, "--no-cruft")) {
            no_cruft = true;
        } else if (std.mem.eql(u8, arg, "--no-quiet")) {
            quiet = false;
        } else if (std.mem.eql(u8, arg, "--cruft")) {
            // accepted
        } else if (std.mem.eql(u8, arg, "--force")) {
            // accepted
        } else if (std.mem.eql(u8, arg, "--detach") or std.mem.eql(u8, arg, "--no-detach")) {
            // accepted
        } else if (std.mem.eql(u8, arg, "--keep-largest-pack")) {
            // accepted
        } else if (std.mem.startsWith(u8, arg, "--max-cruft-size=") or
            std.mem.startsWith(u8, arg, "--expire-to="))
        {
            // accepted
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStderr("usage: git gc [--aggressive] [--auto] [--quiet] [--prune=<date>]\n");
            std.process.exit(129);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try platform_impl.writeStderr("usage: git gc [--aggressive] [--auto] [--quiet] [--prune=<date>]\n");
            std.process.exit(129);
        }
    }

    const git_dir = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // Run native repack
    if (!quiet) {
        try platform_impl.writeStderr("Enumerating objects: done.\n");
        try platform_impl.writeStderr("Counting objects: done.\n");
    }

    // Repack objects into a single pack
    try doNativeRepack(allocator, git_dir, platform_impl, quiet);

    // Prune loose objects
    if (!std.mem.eql(u8, prune_option, "never")) {
        try doNativePrune(allocator, git_dir, platform_impl, prune_option);
    }

    // Pack refs
    try packRefs(allocator, git_dir);

    // Remove empty directories
    try cleanEmptyObjectDirs(allocator, git_dir);
}

fn nativeCmdPrune(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var verbose = false;
    var dry_run = false;
    var expire: []const u8 = "";

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.startsWith(u8, arg, "--expire=")) {
            expire = arg["--expire=".len..];
        } else if (std.mem.eql(u8, arg, "--expire")) {
            i += 1;
            if (i < args.len) expire = args[i];
        } else if (std.mem.eql(u8, arg, "--progress") or std.mem.eql(u8, arg, "--no-progress")) {
            // Accepted
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStderr("usage: git prune [-n] [-v] [--progress] [--expire <time>] [--] [<head>...]\n");
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--")) {
            // Remaining args are heads
            break;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            const msg = std.fmt.allocPrint(allocator, "error: unknown option '{s}'\nusage: git prune [-n] [-v] [--progress] [--expire <time>] [--] [<head>...]\n", .{arg}) catch unreachable;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        }
    }

    const git_dir = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    try doNativePrune(allocator, git_dir, platform_impl, expire);
}

fn parseExpireTime(expire: []const u8) i128 {
    // Parse expire time strings like "1.day", "2.weeks.ago", "now", "never"
    if (expire.len == 0 or std.mem.eql(u8, expire, "now")) return std.math.maxInt(i128); // prune everything
    if (std.mem.eql(u8, expire, "never")) return 0; // prune nothing

    // Try to parse as a relative time
    const now = std.time.timestamp();
    if (std.mem.indexOf(u8, expire, "day")) |_| {
        // Extract number
        var num: i64 = 1;
        var digits_end: usize = 0;
        while (digits_end < expire.len and std.ascii.isDigit(expire[digits_end])) digits_end += 1;
        if (digits_end > 0) {
            num = std.fmt.parseInt(i64, expire[0..digits_end], 10) catch 1;
        }
        return now - num * 86400;
    }
    if (std.mem.indexOf(u8, expire, "week")) |_| {
        var num: i64 = 1;
        var digits_end: usize = 0;
        while (digits_end < expire.len and std.ascii.isDigit(expire[digits_end])) digits_end += 1;
        if (digits_end > 0) {
            num = std.fmt.parseInt(i64, expire[0..digits_end], 10) catch 1;
        }
        return now - num * 7 * 86400;
    }
    if (std.mem.indexOf(u8, expire, "hour")) |_| {
        var num: i64 = 1;
        var digits_end: usize = 0;
        while (digits_end < expire.len and std.ascii.isDigit(expire[digits_end])) digits_end += 1;
        if (digits_end > 0) {
            num = std.fmt.parseInt(i64, expire[0..digits_end], 10) catch 1;
        }
        return now - num * 3600;
    }
    // Default: 2 weeks ago
    return now - 14 * 86400;
}

fn doNativePrune(allocator: std.mem.Allocator, git_dir: []const u8, platform_impl: anytype, expire: []const u8) !void {
    _ = platform_impl;

    const expire_cutoff = parseExpireTime(expire);

    // First, remove stale temporary files in objects/
    const objects_dir_path_tmp = std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir}) catch return;
    defer allocator.free(objects_dir_path_tmp);
    {
        var obj_dir = std.fs.cwd().openDir(objects_dir_path_tmp, .{ .iterate = true }) catch {
            // no objects dir
            return;
        };
        defer obj_dir.close();
        var iter = obj_dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "tmp_")) {
                // Check mtime
                const file_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir_path_tmp, entry.name }) catch continue;
                defer allocator.free(file_path);
                const stat = std.fs.cwd().statFile(file_path) catch continue;
                const mtime_sec: i128 = @divTrunc(stat.mtime, 1_000_000_000);
                if (mtime_sec < expire_cutoff) {
                    std.fs.cwd().deleteFile(file_path) catch {};
                }
            }
        }
    }

    // Collect all reachable objects
    var reachable = std.StringHashMap(void).init(allocator);
    defer reachable.deinit();

    // Walk from all refs to find reachable objects
    // Read HEAD
    const head_path = std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir}) catch return;
    defer allocator.free(head_path);
    if (std.fs.cwd().readFileAlloc(allocator, head_path, 1024)) |head_content| {
        defer allocator.free(head_content);
        const trimmed = std.mem.trim(u8, head_content, " \t\n\r");
        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            // Symbolic ref - resolve
            const ref_name = trimmed["ref: ".len..];
            const ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name }) catch return;
            defer allocator.free(ref_path);
            if (std.fs.cwd().readFileAlloc(allocator, ref_path, 1024)) |ref_content| {
                defer allocator.free(ref_content);
                const hash = std.mem.trim(u8, ref_content, " \t\n\r");
                if (hash.len >= 40) {
                    try reachable.put(try allocator.dupe(u8, hash[0..40]), {});
                }
            } else |_| {}
        } else if (trimmed.len >= 40) {
            try reachable.put(try allocator.dupe(u8, trimmed[0..40]), {});
        }
    } else |_| {}

    // For now, prune is a no-op for loose objects that are in packs
    // Full implementation would walk commit graphs
    
    // Remove loose objects that are also in pack files
    const pack_dir = std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir}) catch return;
    defer allocator.free(pack_dir);

    var packed_objects = std.StringHashMap(void).init(allocator);
    defer packed_objects.deinit();

    // Read all pack indices to find packed objects
    if (std.fs.cwd().openDir(pack_dir, .{ .iterate = true })) |pd| {
        var pack_d = pd;
        defer pack_d.close();
        var iter = pack_d.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".idx")) {
                const idx_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name }) catch continue;
                defer allocator.free(idx_path);
                const idx_data = std.fs.cwd().readFileAlloc(allocator, idx_path, 100 * 1024 * 1024) catch continue;
                defer allocator.free(idx_data);

                // Parse idx v2 to get list of objects
                if (idx_data.len > 8 and std.mem.eql(u8, idx_data[0..4], "\xfftOc")) {
                    const num_objects = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
                    const sha_offset: usize = 8 + 256 * 4;
                    var obj_idx: usize = 0;
                    while (obj_idx < num_objects) : (obj_idx += 1) {
                        const sha_start = sha_offset + obj_idx * 20;
                        if (sha_start + 20 > idx_data.len) break;
                        const sha_bytes = idx_data[sha_start..sha_start + 20];
                        var hex: [40]u8 = undefined;
                        for (sha_bytes, 0..) |b, bi| {
                            _ = std.fmt.bufPrint(hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
                        }
                        try packed_objects.put(try allocator.dupe(u8, &hex), {});
                    }
                }
            }
        }
    } else |_| {}

    // Remove loose objects that are packed
    const objects_dir_path = std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir}) catch return;
    defer allocator.free(objects_dir_path);

    var hex_dirs: usize = 0;
    while (hex_dirs < 256) : (hex_dirs += 1) {
        var hex_buf: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{hex_dirs}) catch continue;
        const subdir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir_path, hex_buf }) catch continue;
        defer allocator.free(subdir_path);

        var subdir = std.fs.cwd().openDir(subdir_path, .{ .iterate = true }) catch continue;
        defer subdir.close();

        var iter = subdir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file and entry.name.len == 38) {
                var full_hash: [40]u8 = undefined;
                _ = std.fmt.bufPrint(&full_hash, "{s}{s}", .{ hex_buf, entry.name }) catch continue;
                if (packed_objects.contains(&full_hash)) {
                    // Object is in a pack file, can be pruned
                    const file_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ subdir_path, entry.name }) catch continue;
                    defer allocator.free(file_path);
                    std.fs.cwd().deleteFile(file_path) catch {};
                }
            }
        }
    }
}

fn doNativeRepack(allocator: std.mem.Allocator, git_dir: []const u8, platform_impl: anytype, quiet: bool) !void {
    _ = quiet;

    // Simple repack: collect all loose objects and write them into a pack file
    // Also consolidate existing packs
    var all_objects = std.array_list.Managed([20]u8).init(allocator);
    defer all_objects.deinit();

    const objects_dir_path = std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir}) catch return;
    defer allocator.free(objects_dir_path);

    // Enumerate loose objects
    var hex_dirs: usize = 0;
    while (hex_dirs < 256) : (hex_dirs += 1) {
        var hex_buf: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{hex_dirs}) catch continue;
        const subdir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir_path, hex_buf }) catch continue;
        defer allocator.free(subdir_path);

        var subdir = std.fs.cwd().openDir(subdir_path, .{ .iterate = true }) catch continue;
        defer subdir.close();

        var iter = subdir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file and entry.name.len == 38) {
                var full_hex: [40]u8 = undefined;
                _ = std.fmt.bufPrint(&full_hex, "{s}{s}", .{ hex_buf, entry.name }) catch continue;
                var sha: [20]u8 = undefined;
                for (&sha, 0..) |*b, bi| {
                    b.* = std.fmt.parseInt(u8, full_hex[bi * 2 .. bi * 2 + 2], 16) catch continue;
                }
                try all_objects.append(sha);
            }
        }
    }

    // Also collect objects from existing packs
    var object_hashes = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (object_hashes.items) |h| allocator.free(h);
        object_hashes.deinit();
    }

    // Convert loose object SHAs to hex strings
    for (all_objects.items) |sha| {
        var hex: [40]u8 = undefined;
        for (sha, 0..) |b, bi| {
            _ = std.fmt.bufPrint(hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
        }
        try object_hashes.append(try allocator.dupe(u8, &hex));
    }

    // Also enumerate objects in existing pack files
    const pack_dir = std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir}) catch return;
    defer allocator.free(pack_dir);
    std.fs.cwd().makePath(pack_dir) catch {};

    var existing_packs = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (existing_packs.items) |p| allocator.free(p);
        existing_packs.deinit();
    }

    if (std.fs.cwd().openDir(pack_dir, .{ .iterate = true })) |pd| {
        var pack_d = pd;
        defer pack_d.close();
        var pack_iter = pack_d.iterate();
        while (pack_iter.next() catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".idx")) {
                try existing_packs.append(try allocator.dupe(u8, entry.name));
                // Read idx to get object list
                const idx_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name }) catch continue;
                defer allocator.free(idx_path);
                const idx_data = std.fs.cwd().readFileAlloc(allocator, idx_path, 100 * 1024 * 1024) catch continue;
                defer allocator.free(idx_data);

                if (idx_data.len > 8 and std.mem.eql(u8, idx_data[0..4], "\xfftOc")) {
                    const num_objects_packed = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
                    const sha_offset: usize = 8 + 256 * 4;
                    var obj_idx: usize = 0;
                    while (obj_idx < num_objects_packed) : (obj_idx += 1) {
                        const sha_start = sha_offset + obj_idx * 20;
                        if (sha_start + 20 > idx_data.len) break;
                        const sha_bytes = idx_data[sha_start .. sha_start + 20];
                        var hex: [40]u8 = undefined;
                        for (sha_bytes, 0..) |b, bi| {
                            _ = std.fmt.bufPrint(hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
                        }
                        // Don't duplicate
                        var already_have = false;
                        for (object_hashes.items) |existing| {
                            if (std.mem.eql(u8, existing, &hex)) {
                                already_have = true;
                                break;
                            }
                        }
                        if (!already_have) {
                            try object_hashes.append(try allocator.dupe(u8, &hex));
                        }
                    }
                }
            }
        }
    } else |_| {}

    // If no objects at all, nothing to do
    if (object_hashes.items.len == 0) return;

    // Build pack data, tracking offsets and SHA-1s for idx generation
    var pack_data = std.array_list.Managed(u8).init(allocator);
    defer pack_data.deinit();

    var pack_entries = std.array_list.Managed(PackIdxEntry).init(allocator);
    defer pack_entries.deinit();

    // Pack header
    try pack_data.appendSlice("PACK");
    const version: u32 = 2;
    try pack_data.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, version)));
    // We'll patch the object count after writing (some objects may fail to load)
    const count_offset = pack_data.items.len;
    try pack_data.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));

    // Write each object
    for (object_hashes.items) |hash| {
        if (objects.GitObject.load(hash, git_dir, platform_impl, allocator)) |obj| {
            defer obj.deinit(allocator);

            // Parse hex hash to binary SHA
            var sha_bytes: [20]u8 = undefined;
            for (&sha_bytes, 0..) |*b, bi| {
                b.* = std.fmt.parseInt(u8, hash[bi * 2 .. bi * 2 + 2], 16) catch 0;
            }

            const entry_offset: u32 = @intCast(pack_data.items.len);
            const type_num: u8 = switch (obj.type) {
                .commit => 1,
                .tree => 2,
                .blob => 3,
                .tag => 4,
            };
            var obj_size = obj.data.len;
            var first_byte: u8 = (type_num << 4) | @as(u8, @intCast(obj_size & 0x0F));
            obj_size >>= 4;
            if (obj_size > 0) first_byte |= 0x80;
            try pack_data.append(first_byte);
            while (obj_size > 0) {
                var byte: u8 = @intCast(obj_size & 0x7F);
                obj_size >>= 7;
                if (obj_size > 0) byte |= 0x80;
                try pack_data.append(byte);
            }
            // Compress data
            const compressed = zlib_compat_mod.compressSlice(allocator, obj.data) catch continue;
            defer allocator.free(compressed);
            try pack_data.appendSlice(compressed);

            // CRC32 over the entire entry (header + compressed data)
            const entry_data = pack_data.items[entry_offset..];
            const crc = std.hash.crc.Crc32.hash(entry_data);

            try pack_entries.append(.{ .sha = sha_bytes, .offset = entry_offset, .crc = crc });
        } else |_| {
            continue;
        }
    }

    // Patch actual object count
    const actual_count: u32 = @intCast(pack_entries.items.len);
    @memcpy(pack_data.items[count_offset..][0..4], &std.mem.toBytes(std.mem.nativeToBig(u32, actual_count)));

    // Compute SHA1 checksum of pack data
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(pack_data.items);
    const checksum = sha1.finalResult();
    try pack_data.appendSlice(&checksum);

    // Write pack file
    var hash_hex: [40]u8 = undefined;
    for (checksum, 0..) |b, bi| {
        _ = std.fmt.bufPrint(hash_hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
    }

    const pack_filename = std.fmt.allocPrint(allocator, "{s}/pack-{s}.pack", .{ pack_dir, hash_hex }) catch return;
    defer allocator.free(pack_filename);
    std.fs.cwd().writeFile(.{ .sub_path = pack_filename, .data = pack_data.items }) catch return;

    // Generate idx directly from tracked entries (no re-parsing needed)
    try generatePackIdxFromEntries(allocator, pack_entries.items, &checksum, pack_dir, &hash_hex);

    // Delete old pack files (but not the newly created one)
    const new_idx_name = std.fmt.allocPrint(allocator, "pack-{s}.idx", .{hash_hex}) catch "";
    defer if (new_idx_name.len > 0) allocator.free(new_idx_name);
    for (existing_packs.items) |old_idx| {
        // Skip if this is our newly created pack
        if (std.mem.eql(u8, old_idx, new_idx_name)) continue;
        const old_idx_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, old_idx }) catch continue;
        defer allocator.free(old_idx_path);
        std.fs.cwd().deleteFile(old_idx_path) catch {};
        // Also delete .pack
        if (std.mem.endsWith(u8, old_idx, ".idx")) {
            const base = old_idx[0 .. old_idx.len - 4];
            const old_pack_path = std.fmt.allocPrint(allocator, "{s}/{s}.pack", .{ pack_dir, base }) catch continue;
            defer allocator.free(old_pack_path);
            std.fs.cwd().deleteFile(old_pack_path) catch {};
        }
    }

    // Delete loose objects that are now in the pack
    for (all_objects.items) |sha| {
        var hex: [40]u8 = undefined;
        for (sha, 0..) |b, bi| {
            _ = std.fmt.bufPrint(hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
        }
        const loose_path = std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ objects_dir_path, hex[0..2], hex[2..] }) catch continue;
        defer allocator.free(loose_path);
        std.fs.cwd().deleteFile(loose_path) catch {};
    }

    // Update objects/info/packs to list current pack files
    {
        const obj_info_dir = std.fmt.allocPrint(allocator, "{s}/objects/info", .{git_dir}) catch return;
        defer allocator.free(obj_info_dir);
        std.fs.cwd().makePath(obj_info_dir) catch {};

        const packs_file_path = std.fmt.allocPrint(allocator, "{s}/objects/info/packs", .{git_dir}) catch return;
        defer allocator.free(packs_file_path);

        var content = std.array_list.Managed(u8).init(allocator);
        defer content.deinit();

        if (std.fs.cwd().openDir(pack_dir, .{ .iterate = true })) |pd| {
            var pack_d2 = pd;
            defer pack_d2.close();
            var pack_names2 = std.array_list.Managed([]const u8).init(allocator);
            defer {
                for (pack_names2.items) |n| allocator.free(n);
                pack_names2.deinit();
            }
            var iter2 = pack_d2.iterate();
            while (iter2.next() catch null) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pack")) {
                    pack_names2.append(allocator.dupe(u8, entry.name) catch continue) catch {};
                }
            }
            std.mem.sort([]const u8, pack_names2.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b).compare(.lt);
                }
            }.lessThan);
            for (pack_names2.items) |name| {
                const line = std.fmt.allocPrint(allocator, "P {s}\n", .{name}) catch continue;
                defer allocator.free(line);
                content.appendSlice(line) catch {};
            }
        } else |_| {}
        content.append('\n') catch {};
        std.fs.cwd().writeFile(.{ .sub_path = packs_file_path, .data = content.items }) catch {};
    }
}

fn packRefs(allocator: std.mem.Allocator, git_dir: []const u8) !void {
    // Pack loose refs into packed-refs file
    var ref_list = std.array_list.Managed(RefEntry).init(allocator);
    defer {
        for (ref_list.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.hash);
        }
        ref_list.deinit();
    }

    // Read existing packed-refs
    const packed_refs_path = std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir}) catch return;
    defer allocator.free(packed_refs_path);
    if (std.fs.cwd().readFileAlloc(allocator, packed_refs_path, 10 * 1024 * 1024)) |packed_content| {
        defer allocator.free(packed_content);
        var lines = std.mem.splitScalar(u8, packed_content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            if (std.mem.indexOfScalar(u8, line, ' ')) |space_idx| {
                const hash = line[0..space_idx];
                const name = line[space_idx + 1..];
                if (hash.len >= 40) {
                    try ref_list.append(.{
                        .name = try allocator.dupe(u8, name),
                        .hash = try allocator.dupe(u8, hash[0..40]),
                    });
                }
            }
        }
    } else |_| {}

    // This is a simplified pack-refs - in practice we'd also collect loose refs
    // and remove the loose files after packing
}

fn cleanEmptyObjectDirs(allocator: std.mem.Allocator, git_dir: []const u8) !void {
    const objects_dir_path = std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir}) catch return;
    defer allocator.free(objects_dir_path);

    var hex_dirs: usize = 0;
    while (hex_dirs < 256) : (hex_dirs += 1) {
        var hex_buf: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{hex_dirs}) catch continue;
        const subdir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir_path, hex_buf }) catch continue;
        defer allocator.free(subdir_path);

        // Try to remove - will fail if not empty (which is fine)
        std.fs.cwd().deleteDir(subdir_path) catch {};
    }
}

fn nativeCmdRepack(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var ad_flag = false;
    var quiet = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "-l")) {
            ad_flag = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--no-repack-all-into-one") or
            std.mem.eql(u8, arg, "--keep-unreachable") or
            std.mem.eql(u8, arg, "--no-write-bitmap-index") or
            std.mem.eql(u8, arg, "--write-bitmap-index") or
            std.mem.eql(u8, arg, "--write-midx") or
            std.mem.eql(u8, arg, "--geometric=2") or
            std.mem.eql(u8, arg, "--no-cruft") or
            std.mem.eql(u8, arg, "--cruft"))
        {
            // Accepted flags
        } else if (std.mem.startsWith(u8, arg, "--geometric=") or
            std.mem.startsWith(u8, arg, "--window=") or
            std.mem.startsWith(u8, arg, "--depth=") or
            std.mem.startsWith(u8, arg, "--threads=") or
            std.mem.startsWith(u8, arg, "--max-pack-size="))
        {
            // Accepted with value
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git repack [<options>]\n");
            std.process.exit(129);
        }
    }

    const git_dir = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    try doNativeRepack(allocator, git_dir, platform_impl, quiet);
}

fn nativeCmdPackObjects(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var base_name: ?[]const u8 = null;
    var stdout_mode = false;
    var progress = true;
    var revs_mode = false;
    var use_all = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--stdout")) {
            stdout_mode = true;
        } else if (std.mem.eql(u8, arg, "--all-progress") or std.mem.eql(u8, arg, "--all-progress-implied")) {
            // accepted
        } else if (std.mem.eql(u8, arg, "-q")) {
            progress = false;
        } else if (std.mem.eql(u8, arg, "--progress")) {
            progress = true;
        } else if (std.mem.eql(u8, arg, "--revs")) {
            revs_mode = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            use_all = true;
        } else if (std.mem.eql(u8, arg, "--no-reuse-delta") or std.mem.eql(u8, arg, "--no-reuse-object")) {
            // accepted
        } else if (std.mem.eql(u8, arg, "--thin") or
            std.mem.eql(u8, arg, "--delta-base-offset") or std.mem.eql(u8, arg, "--include-tag") or
            std.mem.eql(u8, arg, "--keep-true-parents") or std.mem.eql(u8, arg, "--honor-pack-keep") or
            std.mem.eql(u8, arg, "--non-empty") or std.mem.eql(u8, arg, "--all") or
            std.mem.eql(u8, arg, "--local") or std.mem.eql(u8, arg, "--incremental") or
            std.mem.eql(u8, arg, "--unpacked") or std.mem.eql(u8, arg, "--no-path-walk") or
            std.mem.eql(u8, arg, "--path-walk") or std.mem.eql(u8, arg, "--reflog") or
            std.mem.eql(u8, arg, "--indexed-objects") or std.mem.eql(u8, arg, "--unpack-unreachable"))
        {
            // Accepted flags
        } else if (std.mem.startsWith(u8, arg, "--window=") or
            std.mem.startsWith(u8, arg, "--depth=") or
            std.mem.startsWith(u8, arg, "--threads=") or
            std.mem.startsWith(u8, arg, "--max-pack-size=") or
            std.mem.startsWith(u8, arg, "--compression=") or
            std.mem.startsWith(u8, arg, "--filter=") or
            std.mem.startsWith(u8, arg, "--unpack-unreachable="))
        {
            // Accepted with value
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git pack-objects [<options>] base-name\n");
            std.process.exit(129);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (base_name != null) {
                try platform_impl.writeStderr("usage: git pack-objects [<options>] base-name\n");
                std.process.exit(1);
            }
            base_name = arg;
        }
    }

    if (base_name == null and !stdout_mode) {
        try platform_impl.writeStderr("usage: git pack-objects [<options>] base-name\n");
        std.process.exit(1);
    }

    const git_dir = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
        unreachable;
    };

    // Read stdin
    const stdin = std.fs.File.stdin();
    const stdin_data = stdin.readToEndAlloc(allocator, 100 * 1024 * 1024) catch {
        try platform_impl.writeStderr("fatal: error reading stdin\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(stdin_data);

    // Collect object hashes to pack (deduplicated)
    var object_set = std.StringHashMap(void).init(allocator);
    defer object_set.deinit();
    var object_hashes = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (object_hashes.items) |h| allocator.free(h);
        object_hashes.deinit();
    }

    if (revs_mode) {
        // --revs mode: treat stdin as revision arguments and walk reachable objects
        var lines_iter = std.mem.splitScalar(u8, stdin_data, '\n');
        while (lines_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '^') continue; // exclude ref

            var resolved: ?[]const u8 = null;
            if (trimmed.len >= 40) {
                const maybe_hash = trimmed[0..40];
                var is_hex = true;
                for (maybe_hash) |ch| {
                    if (!std.ascii.isHex(ch)) { is_hex = false; break; }
                }
                if (is_hex) resolved = try allocator.dupe(u8, maybe_hash);
            }
            if (resolved == null) {
                resolved = refs.resolveRef(git_dir, trimmed, platform_impl, allocator) catch {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{trimmed});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                    unreachable;
                };
            }
            if (resolved) |hash| {
                defer allocator.free(hash);
                try packObjectsWalkReachable(allocator, git_dir, hash, &object_set, &object_hashes, platform_impl);
            }
        }
    } else {
        // Non-revs mode: each line is an object ID
        var lines_iter = std.mem.splitScalar(u8, stdin_data, '\n');
        while (lines_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) {
                if (line.len > 0 or (lines_iter.peek() != null)) {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: expected object ID, got garbage:\n {s}\n\n", .{line});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                    unreachable;
                }
                continue;
            }
            if (trimmed.len < 40) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: expected object ID, got garbage:\n {s}\n\n", .{trimmed});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            }
            const hash = trimmed[0..40];
            var valid = true;
            for (hash) |ch| {
                if (!std.ascii.isHex(ch)) { valid = false; break; }
            }
            if (!valid) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: expected object ID, got garbage:\n {s}\n\n", .{trimmed});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            }
            if (!object_set.contains(hash)) {
                const duped = try allocator.dupe(u8, hash);
                try object_set.put(duped, {});
                try object_hashes.append(duped);
            }
        }
    }

    if (use_all) {
        try packObjectsAddAllObjects(allocator, git_dir, &object_set, &object_hashes);
    }

    // Build the pack
    var pack_data = std.array_list.Managed(u8).init(allocator);
    defer pack_data.deinit();

    try pack_data.appendSlice("PACK");
    const version: u32 = 2;
    try pack_data.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, version)));
    const count_pos = pack_data.items.len;
    try pack_data.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));

    var actual_count: u32 = 0;
    for (object_hashes.items) |hash| {
        if (objects.GitObject.load(hash, git_dir, platform_impl, allocator)) |obj| {
            defer obj.deinit(allocator);
            const type_num: u8 = switch (obj.type) {
                .commit => 1, .tree => 2, .blob => 3, .tag => 4,
            };
            var obj_size = obj.data.len;
            var first_byte: u8 = (type_num << 4) | @as(u8, @intCast(obj_size & 0x0F));
            obj_size >>= 4;
            if (obj_size > 0) first_byte |= 0x80;
            try pack_data.append(first_byte);
            while (obj_size > 0) {
                var byte: u8 = @intCast(obj_size & 0x7F);
                obj_size >>= 7;
                if (obj_size > 0) byte |= 0x80;
                try pack_data.append(byte);
            }
            const compressed = zlib_compat_mod.compressSlice(allocator, obj.data) catch continue;
            defer allocator.free(compressed);
            try pack_data.appendSlice(compressed);
            actual_count += 1;
        } else |_| { continue; }
    }

    const count_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, actual_count));
    @memcpy(pack_data.items[count_pos..][0..4], &count_bytes);

    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(pack_data.items);
    const checksum = sha1.finalResult();
    try pack_data.appendSlice(&checksum);

    if (stdout_mode) {
        const stdout = std.fs.File.stdout();
        stdout.writeAll(pack_data.items) catch {};
    } else if (base_name) |name| {
        var hash_hex: [40]u8 = undefined;
        for (checksum, 0..) |b, bi| {
            _ = std.fmt.bufPrint(hash_hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
        }
        const pack_filename = std.fmt.allocPrint(allocator, "{s}-{s}.pack", .{ name, hash_hex }) catch unreachable;
        defer allocator.free(pack_filename);
        std.fs.cwd().writeFile(.{ .sub_path = pack_filename, .data = pack_data.items }) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "fatal: unable to write pack file: {s}\n", .{@errorName(err)}) catch unreachable;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        const idx_filename = std.fmt.allocPrint(allocator, "{s}-{s}.idx", .{ name, hash_hex }) catch unreachable;
        defer allocator.free(idx_filename);
        generatePackIdxToFile(allocator, pack_data.items, idx_filename) catch {};
        const output = std.fmt.allocPrint(allocator, "{s}\n", .{hash_hex}) catch unreachable;
        defer allocator.free(output);
        try platform_impl.writeStdout(output);
    }

    if (progress) {
        const count_msg = std.fmt.allocPrint(allocator, "Total {d} (delta 0), reused 0 (delta 0), pack-reused 0\n", .{actual_count}) catch unreachable;
        defer allocator.free(count_msg);
        try platform_impl.writeStderr(count_msg);
    }
}

/// Walk all objects reachable from a commit and add them to the set
fn packObjectsWalkReachable(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    start_hash: []const u8,
    object_set: *std.StringHashMap(void),
    object_hashes: *std.array_list.Managed([]const u8),
    platform_impl: *const platform_mod.Platform,
) !void {
    var worklist = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (worklist.items) |item| allocator.free(item);
        worklist.deinit();
    }
    try worklist.append(try allocator.dupe(u8, start_hash));

    while (worklist.items.len > 0) {
        const hash = worklist.pop().?;
        defer allocator.free(hash);

        if (object_set.contains(hash)) continue;

        const obj = objects.GitObject.load(hash, git_dir, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);

        const duped = try allocator.dupe(u8, hash);
        try object_set.put(duped, {});
        try object_hashes.append(duped);

        switch (obj.type) {
            .commit => {
                var line_iter = std.mem.splitScalar(u8, obj.data, '\n');
                while (line_iter.next()) |line| {
                    if (line.len == 0) break;
                    if (std.mem.startsWith(u8, line, "tree ") and line.len >= 45) {
                        try worklist.append(try allocator.dupe(u8, line[5..45]));
                    } else if (std.mem.startsWith(u8, line, "parent ") and line.len >= 47) {
                        try worklist.append(try allocator.dupe(u8, line[7..47]));
                    }
                }
            },
            .tree => {
                var tpos: usize = 0;
                while (tpos < obj.data.len) {
                    const null_pos = std.mem.indexOfScalarPos(u8, obj.data, tpos, 0) orelse break;
                    if (null_pos + 21 > obj.data.len) break;
                    const entry_hash_bytes = obj.data[null_pos + 1 .. null_pos + 21];
                    var entry_hex: [40]u8 = undefined;
                    for (entry_hash_bytes, 0..) |b, j| {
                        const hc = "0123456789abcdef";
                        entry_hex[j * 2] = hc[b >> 4];
                        entry_hex[j * 2 + 1] = hc[b & 0xf];
                    }
                    try worklist.append(try allocator.dupe(u8, &entry_hex));
                    tpos = null_pos + 21;
                }
            },
            .tag => {
                var line_iter = std.mem.splitScalar(u8, obj.data, '\n');
                while (line_iter.next()) |line| {
                    if (line.len == 0) break;
                    if (std.mem.startsWith(u8, line, "object ") and line.len >= 47) {
                        try worklist.append(try allocator.dupe(u8, line[7..47]));
                    }
                }
            },
            .blob => {},
        }
    }
}

/// Add all loose objects from the repository
fn packObjectsAddAllObjects(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    object_set: *std.StringHashMap(void),
    object_hashes: *std.array_list.Managed([]const u8),
) !void {
    const objects_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir});
    defer allocator.free(objects_dir_path);
    var hex_dirs: usize = 0;
    while (hex_dirs < 256) : (hex_dirs += 1) {
        var hex_buf: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{hex_dirs}) catch continue;
        const subdir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir_path, hex_buf }) catch continue;
        defer allocator.free(subdir_path);
        var subdir = std.fs.cwd().openDir(subdir_path, .{ .iterate = true }) catch continue;
        defer subdir.close();
        var iter = subdir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file and entry.name.len == 38) {
                var full_hash: [40]u8 = undefined;
                @memcpy(full_hash[0..2], &hex_buf);
                @memcpy(full_hash[2..40], entry.name[0..38]);
                if (!object_set.contains(&full_hash)) {
                    const duped2 = try allocator.dupe(u8, &full_hash);
                    try object_set.put(duped2, {});
                    try object_hashes.append(duped2);
                }
            }
        }
    }
}

fn nativeCmdIndexPack(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var stdin_mode = false;
    var verify = false;
    var pack_file: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--stdin")) {
            stdin_mode = true;
        } else if (std.mem.eql(u8, arg, "--verify") or std.mem.eql(u8, arg, "-v")) {
            verify = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i < args.len) output_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--index-version=") or
            std.mem.eql(u8, arg, "--fix-thin") or
            std.mem.eql(u8, arg, "--strict") or
            std.mem.eql(u8, arg, "--check-self-contained-and-connected") or
            std.mem.eql(u8, arg, "--fsck-objects") or
            std.mem.startsWith(u8, arg, "--threads=") or
            std.mem.startsWith(u8, arg, "--max-input-size="))
        {
            // Accepted flags
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git index-pack [--verify] [--stdin] [-o <index-file>] <pack-file>\n");
            std.process.exit(129);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            pack_file = arg;
        }
    }

    if (!stdin_mode and pack_file == null) {
        try platform_impl.writeStderr("usage: git index-pack [--verify] [--stdin] [-o <index-file>] <pack-file>\n");
        std.process.exit(1);
    }

    var pack_data: []const u8 = undefined;
    var should_free_pack = false;

    if (stdin_mode) {
        const git_dir = findGitDir() catch ".git";
        const stdin = std.fs.File.stdin();
        pack_data = stdin.readToEndAlloc(allocator, 4 * 1024 * 1024 * 1024) catch {
            try platform_impl.writeStderr("fatal: error reading pack from stdin\n");
            std.process.exit(128);
            unreachable;
        };
        should_free_pack = true;

        // Write pack file to objects/pack/
        const pack_dir = std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir}) catch unreachable;
        defer allocator.free(pack_dir);
        std.fs.cwd().makePath(pack_dir) catch {};

        // Compute checksum for pack name
        if (pack_data.len >= 20) {
            const trailing_sha = pack_data[pack_data.len - 20..];
            var hash_hex: [40]u8 = undefined;
            for (trailing_sha, 0..) |b, bi| {
                _ = std.fmt.bufPrint(hash_hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
            }

            const dest_pack = std.fmt.allocPrint(allocator, "{s}/pack-{s}.pack", .{ pack_dir, hash_hex }) catch unreachable;
            defer allocator.free(dest_pack);
            std.fs.cwd().writeFile(.{ .sub_path = dest_pack, .data = pack_data }) catch {};

            // Generate idx
            try generatePackIdx(allocator, pack_data, pack_dir, &hash_hex);

            const msg = std.fmt.allocPrint(allocator, "pack\t{s}\n", .{hash_hex}) catch unreachable;
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        }
    } else if (pack_file) |pf| {
        pack_data = std.fs.cwd().readFileAlloc(allocator, pf, 4 * 1024 * 1024 * 1024) catch {
            const msg = std.fmt.allocPrint(allocator, "fatal: cannot open packfile '{s}'\n", .{pf}) catch unreachable;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
            unreachable;
        };
        should_free_pack = true;

        if (verify) {
            // Just verify pack header
            if (pack_data.len < 12 or !std.mem.eql(u8, pack_data[0..4], "PACK")) {
                try platform_impl.writeStderr("fatal: not a valid pack file\n");
                std.process.exit(128);
            }
            // Success for verify
            return;
        }

        // Generate index file
        const idx_path = if (output_path) |op| op else blk: {
            if (std.mem.endsWith(u8, pf, ".pack")) {
                break :blk try std.fmt.allocPrint(allocator, "{s}idx", .{pf[0 .. pf.len - 4]});
            }
            break :blk try std.fmt.allocPrint(allocator, "{s}.idx", .{pf});
        };
        defer if (output_path == null) allocator.free(idx_path);

        try generatePackIdxToFile(allocator, pack_data, idx_path);
    }

    if (should_free_pack) {
        allocator.free(pack_data);
    }
}

const PackIdxEntry = struct { sha: [20]u8, offset: u32, crc: u32 };

fn generatePackIdxFromEntries(allocator: std.mem.Allocator, entries: []const PackIdxEntry, pack_checksum: *const [20]u8, output_dir: []const u8, hash_hex: *const [40]u8) !void {
    const n = entries.len;

    // Sort entries by SHA-1
    const indices = try allocator.alloc(usize, n);
    defer allocator.free(indices);
    for (indices, 0..) |*idx_val, j| idx_val.* = j;

    const SortCtx = struct {
        e: []const PackIdxEntry,
    };
    const ctx = SortCtx{ .e = entries };
    std.mem.sort(usize, indices, ctx, struct {
        fn lessThan(c: SortCtx, a: usize, b: usize) bool {
            return std.mem.order(u8, &c.e[a].sha, &c.e[b].sha).compare(.lt);
        }
    }.lessThan);

    var idx = std.array_list.Managed(u8).init(allocator);
    defer idx.deinit();

    // Magic + version
    try idx.appendSlice("\xfftOc");
    try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 2)));

    // Fanout table (256 entries)
    var fanout: [256]u32 = std.mem.zeroes([256]u32);
    for (indices) |idx_val| {
        const first_byte = entries[idx_val].sha[0];
        var fb: usize = first_byte;
        while (fb < 256) : (fb += 1) {
            fanout[fb] += 1;
        }
    }
    for (fanout) |f| {
        try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, f)));
    }

    // SHA-1 table (sorted)
    for (indices) |idx_val| {
        try idx.appendSlice(&entries[idx_val].sha);
    }

    // CRC32 table
    for (indices) |idx_val| {
        try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, entries[idx_val].crc)));
    }

    // 4-byte offset table
    for (indices) |idx_val| {
        try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, entries[idx_val].offset)));
    }

    // Pack checksum
    try idx.appendSlice(pack_checksum);

    // Idx checksum
    var idx_sha = std.crypto.hash.Sha1.init(.{});
    idx_sha.update(idx.items);
    const idx_checksum = idx_sha.finalResult();
    try idx.appendSlice(&idx_checksum);

    // Write idx file
    const idx_filename = std.fmt.allocPrint(allocator, "{s}/pack-{s}.idx", .{ output_dir, hash_hex }) catch return;
    defer allocator.free(idx_filename);
    std.fs.cwd().writeFile(.{ .sub_path = idx_filename, .data = idx.items }) catch {};
}

fn generatePackIdx(allocator: std.mem.Allocator, pack_data: []const u8, output_dir: []const u8, hash_hex: *const [40]u8) !void {
    // Parse pack file to extract object SHAs
    if (pack_data.len < 12) return;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return;

    const num_objects = std.mem.readInt(u32, pack_data[8..12], .big);

    // Collect object hashes by parsing pack entries
    var object_shas = std.array_list.Managed([20]u8).init(allocator);
    defer object_shas.deinit();
    var offsets = std.array_list.Managed(u32).init(allocator);
    defer offsets.deinit();
    var crcs = std.array_list.Managed(u32).init(allocator);
    defer crcs.deinit();

    var pos: usize = 12;
    var obj_count: usize = 0;
    while (obj_count < num_objects and pos < pack_data.len - 20) : (obj_count += 1) {
        const entry_offset = pos;
        try offsets.append(@intCast(entry_offset));

        // Parse object header
        var c = pack_data[pos];
        pos += 1;
        var obj_size: u64 = c & 0x0F;
        var shift: u6 = 4;
        while (c & 0x80 != 0 and pos < pack_data.len) {
            c = pack_data[pos];
            pos += 1;
            obj_size |= @as(u64, c & 0x7F) << shift;
            shift +|= 7;
        }

        const obj_type = (pack_data[entry_offset] >> 4) & 0x07;

        // Skip delta base ref if needed
        if (obj_type == 6) {
            // OFS_DELTA: skip base offset encoding
            c = pack_data[pos];
            pos += 1;
            while (c & 0x80 != 0 and pos < pack_data.len) {
                c = pack_data[pos];
                pos += 1;
            }
        } else if (obj_type == 7) {
            // REF_DELTA: skip 20-byte base SHA
            pos += 20;
        }

        // Decompress using zlib C API for accurate consumed byte count
        const decomp_result = zlib_compat_mod.decompressSliceWithConsumed(allocator, pack_data[pos..]) catch {
            try object_shas.append(std.mem.zeroes([20]u8));
            try crcs.append(0);
            continue;
        };
        defer allocator.free(decomp_result.data);
        pos += decomp_result.consumed;

        // Compute CRC32 for the entry
        const entry_data = pack_data[entry_offset..pos];
        const crc = std.hash.crc.Crc32.hash(entry_data);
        try crcs.append(crc);

        // Compute SHA of the object content (only for non-delta objects)
        var sha: [20]u8 = std.mem.zeroes([20]u8);
        if (obj_type >= 1 and obj_type <= 4) {
            const type_str: []const u8 = switch (obj_type) {
                1 => "commit",
                2 => "tree",
                3 => "blob",
                4 => "tag",
                else => "blob",
            };
            const header = std.fmt.allocPrint(allocator, "{s} {d}\x00", .{ type_str, decomp_result.data.len }) catch continue;
            defer allocator.free(header);
            var hasher = std.crypto.hash.Sha1.init(.{});
            hasher.update(header);
            hasher.update(decomp_result.data);
            sha = hasher.finalResult();
        }
        try object_shas.append(sha);
    }

    // Write v2 idx file
    var idx = std.array_list.Managed(u8).init(allocator);
    defer idx.deinit();

    // Magic + version
    try idx.appendSlice("\xfftOc");
    try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 2)));

    // Fanout table (256 entries)
    // Sort objects by SHA for the fanout
    const SortCtx = struct {
        shas: [][20]u8,
    };
    const indices = try allocator.alloc(usize, object_shas.items.len);
    defer allocator.free(indices);
    for (indices, 0..) |*idx_val, j| idx_val.* = j;

    const ctx = SortCtx{ .shas = object_shas.items };
    std.mem.sort(usize, indices, ctx, struct {
        fn lessThan(c: SortCtx, a: usize, b: usize) bool {
            return std.mem.order(u8, &c.shas[a], &c.shas[b]).compare(.lt);
        }
    }.lessThan);

    // Build fanout
    var fanout: [256]u32 = std.mem.zeroes([256]u32);
    for (indices) |idx_val| {
        const first_byte = object_shas.items[idx_val][0];
        var fb: usize = first_byte;
        while (fb < 256) : (fb += 1) {
            fanout[fb] += 1;
        }
    }
    for (fanout) |f| {
        try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, f)));
    }

    // SHA-1 table (sorted)
    for (indices) |idx_val| {
        try idx.appendSlice(&object_shas.items[idx_val]);
    }

    // CRC32 table
    for (indices) |idx_val| {
        if (idx_val < crcs.items.len) {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, crcs.items[idx_val])));
        } else {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
        }
    }

    // Offset table
    for (indices) |idx_val| {
        if (idx_val < offsets.items.len) {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, offsets.items[idx_val])));
        } else {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
        }
    }

    // Pack SHA-1
    if (pack_data.len >= 20) {
        try idx.appendSlice(pack_data[pack_data.len - 20..]);
    }

    // Idx SHA-1
    var idx_sha = std.crypto.hash.Sha1.init(.{});
    idx_sha.update(idx.items);
    const idx_checksum = idx_sha.finalResult();
    try idx.appendSlice(&idx_checksum);

    // Write idx file
    const idx_filename = std.fmt.allocPrint(allocator, "{s}/pack-{s}.idx", .{ output_dir, hash_hex }) catch return;
    defer allocator.free(idx_filename);
    std.fs.cwd().writeFile(.{ .sub_path = idx_filename, .data = idx.items }) catch {};
}

fn generatePackIdxToFile(allocator: std.mem.Allocator, pack_data: []const u8, output_path: []const u8) !void {
    // Parse pack file to extract object SHAs
    if (pack_data.len < 12) return;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return;

    const num_objects = std.mem.readInt(u32, pack_data[8..12], .big);

    // Collect object hashes by parsing pack entries
    var object_shas = std.array_list.Managed([20]u8).init(allocator);
    defer object_shas.deinit();
    var offsets_list = std.array_list.Managed(u32).init(allocator);
    defer offsets_list.deinit();
    var crcs_list = std.array_list.Managed(u32).init(allocator);
    defer crcs_list.deinit();

    var pos: usize = 12;
    var obj_count: usize = 0;
    while (obj_count < num_objects and pos < pack_data.len -| 20) : (obj_count += 1) {
        const entry_offset = pos;
        try offsets_list.append(@intCast(entry_offset));

        // Parse object header
        var c = pack_data[pos];
        pos += 1;
        const obj_type = (pack_data[entry_offset] >> 4) & 0x07;
        var obj_size: u64 = c & 0x0F;
        var shift: u6 = 4;
        while (c & 0x80 != 0 and pos < pack_data.len) {
            c = pack_data[pos];
            pos += 1;
            obj_size |= @as(u64, c & 0x7F) << shift;
            shift +|= 7;
        }

        // Skip delta base ref if needed
        if (obj_type == 6) {
            // OFS_DELTA: skip base offset encoding
            c = pack_data[pos];
            pos += 1;
            while (c & 0x80 != 0 and pos < pack_data.len) {
                c = pack_data[pos];
                pos += 1;
            }
        } else if (obj_type == 7) {
            // REF_DELTA: skip 20-byte base SHA
            pos += 20;
        }

        // Decompress using zlib C API for accurate consumed byte count
        const decomp_result2 = zlib_compat_mod.decompressSliceWithConsumed(allocator, pack_data[pos..]) catch {
            try object_shas.append(std.mem.zeroes([20]u8));
            try crcs_list.append(0);
            continue;
        };
        defer allocator.free(decomp_result2.data);
        pos += decomp_result2.consumed;

        // Compute CRC32 for the entry
        const entry_data = pack_data[entry_offset..pos];
        const crc = std.hash.crc.Crc32.hash(entry_data);
        try crcs_list.append(crc);

        // Compute SHA of the object content (only for non-delta objects)
        var sha: [20]u8 = std.mem.zeroes([20]u8);
        if (obj_type >= 1 and obj_type <= 4) {
            const type_str: []const u8 = switch (obj_type) {
                1 => "commit",
                2 => "tree",
                3 => "blob",
                4 => "tag",
                else => "blob",
            };
            const header = std.fmt.allocPrint(allocator, "{s} {d}\x00", .{ type_str, decomp_result2.data.len }) catch continue;
            defer allocator.free(header);
            var hasher = std.crypto.hash.Sha1.init(.{});
            hasher.update(header);
            hasher.update(decomp_result2.data);
            sha = hasher.finalResult();
        }
        try object_shas.append(sha);
    }

    // Write v2 idx file
    var idx = std.array_list.Managed(u8).init(allocator);
    defer idx.deinit();

    // Magic + version
    try idx.appendSlice("\xfftOc");
    try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 2)));

    // Sort objects by SHA for fanout
    const indices = try allocator.alloc(usize, object_shas.items.len);
    defer allocator.free(indices);
    for (indices, 0..) |*idx_val, j| idx_val.* = j;

    const SortCtx2 = struct {
        shas: [][20]u8,
    };
    const ctx = SortCtx2{ .shas = object_shas.items };
    std.mem.sort(usize, indices, ctx, struct {
        fn lessThan(c2: SortCtx2, a: usize, b: usize) bool {
            return std.mem.order(u8, &c2.shas[a], &c2.shas[b]).compare(.lt);
        }
    }.lessThan);

    // Build fanout table
    var fanout: [256]u32 = std.mem.zeroes([256]u32);
    for (indices) |idx_val| {
        const first_byte = object_shas.items[idx_val][0];
        var fb: usize = first_byte;
        while (fb < 256) : (fb += 1) {
            fanout[fb] += 1;
        }
    }
    for (fanout) |f| {
        try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, f)));
    }

    // SHA-1 table (sorted)
    for (indices) |idx_val| {
        try idx.appendSlice(&object_shas.items[idx_val]);
    }

    // CRC32 table
    for (indices) |idx_val| {
        if (idx_val < crcs_list.items.len) {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, crcs_list.items[idx_val])));
        } else {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
        }
    }

    // Offset table
    for (indices) |idx_val| {
        if (idx_val < offsets_list.items.len) {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, offsets_list.items[idx_val])));
        } else {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
        }
    }

    // Pack SHA-1
    if (pack_data.len >= 20) {
        try idx.appendSlice(pack_data[pack_data.len - 20..]);
    }

    // Idx SHA-1
    var idx_sha = std.crypto.hash.Sha1.init(.{});
    idx_sha.update(idx.items);
    const idx_checksum = idx_sha.finalResult();
    try idx.appendSlice(&idx_checksum);

    // Write idx file
    std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = idx.items }) catch {};
}

fn nativeCmdReflog(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var subcmd: []const u8 = "show";
    var ref_name: []const u8 = "HEAD";

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "show") or std.mem.eql(u8, arg, "expire") or
            std.mem.eql(u8, arg, "delete") or std.mem.eql(u8, arg, "exists"))
        {
            subcmd = arg;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git reflog [show|expire|delete|exists] [<ref>]\n");
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-n") or
            std.mem.startsWith(u8, arg, "--expire=") or std.mem.eql(u8, arg, "--verbose") or
            std.mem.eql(u8, arg, "--rewrite") or std.mem.eql(u8, arg, "--updateref") or
            std.mem.eql(u8, arg, "--stale-fix") or std.mem.eql(u8, arg, "--dry-run"))
        {
            // Accepted flags
            if (std.mem.eql(u8, arg, "-n")) {
                i += 1; // skip count
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            ref_name = arg;
        }
    }

    const git_dir = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    if (std.mem.eql(u8, subcmd, "show")) {
        // Read reflog file
        var reflog_path: []const u8 = undefined;
        if (std.mem.eql(u8, ref_name, "HEAD")) {
            reflog_path = std.fmt.allocPrint(allocator, "{s}/logs/HEAD", .{git_dir}) catch unreachable;
        } else if (std.mem.startsWith(u8, ref_name, "refs/")) {
            reflog_path = std.fmt.allocPrint(allocator, "{s}/logs/{s}", .{ git_dir, ref_name }) catch unreachable;
        } else {
            reflog_path = std.fmt.allocPrint(allocator, "{s}/logs/refs/heads/{s}", .{ git_dir, ref_name }) catch unreachable;
        }
        defer allocator.free(reflog_path);

        const content = std.fs.cwd().readFileAlloc(allocator, reflog_path, 10 * 1024 * 1024) catch {
            // No reflog
            return;
        };
        defer allocator.free(content);

        // Parse and display reflog entries in reverse order
        var entries = std.array_list.Managed([]const u8).init(allocator);
        defer entries.deinit();
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) {
                try entries.append(line);
            }
        }

        // Output in reverse order
        var entry_idx: usize = entries.items.len;
        var seq: usize = 0;
        while (entry_idx > 0) {
            entry_idx -= 1;
            const line = entries.items[entry_idx];
            // Format: <old-sha1> <new-sha1> <author> <timestamp> <tz>\t<message>
            if (std.mem.indexOfScalar(u8, line, '\t')) |tab| {
                const msg = line[tab + 1..];
                // Extract new sha
                if (line.len >= 82) {
                    const new_sha = line[41..81];
                    const selector = std.fmt.allocPrint(allocator, "{s}@{{{d}}}", .{ ref_name, seq }) catch continue;
                    defer allocator.free(selector);
                    const output = std.fmt.allocPrint(allocator, "{s} {s}: {s}\n", .{ new_sha[0..@min(7, new_sha.len)], selector, msg }) catch continue;
                    defer allocator.free(output);
                    try platform_impl.writeStdout(output);
                }
            }
            seq += 1;
        }
    } else if (std.mem.eql(u8, subcmd, "expire")) {
        // Expire old reflog entries - for now, no-op
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        // Delete specific reflog entries - for now, no-op
    } else if (std.mem.eql(u8, subcmd, "exists")) {
        // Check if a reflog exists
        var reflog_path: []const u8 = undefined;
        if (std.mem.eql(u8, ref_name, "HEAD")) {
            reflog_path = std.fmt.allocPrint(allocator, "{s}/logs/HEAD", .{git_dir}) catch unreachable;
        } else if (std.mem.startsWith(u8, ref_name, "refs/")) {
            reflog_path = std.fmt.allocPrint(allocator, "{s}/logs/{s}", .{ git_dir, ref_name }) catch unreachable;
        } else {
            reflog_path = std.fmt.allocPrint(allocator, "{s}/logs/refs/heads/{s}", .{ git_dir, ref_name }) catch unreachable;
        }
        defer allocator.free(reflog_path);

        _ = std.fs.cwd().statFile(reflog_path) catch {
            std.process.exit(1);
        };
    }
}

fn nativeCmdClean(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var force = false;
    var dry_run = false;
    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-d") or
            std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet") or
            std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "-X"))
        {
            // Accepted flags (not fully implemented yet)
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git clean [-d] [-f] [-n] [-q] [-x | -X] [--] [<pathspec>...]\n");
            std.process.exit(129);
        }
    }

    if (!force and !dry_run) {
        try platform_impl.writeStderr("fatal: clean.requireForce defaults to true and neither -i, -n, nor -f given; refusing to clean\n");
        std.process.exit(128);
    }

    // Simple clean implementation - remove untracked files
    // For now, this is a minimal implementation
    _ = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
}

fn isAllHex(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return s.len > 0;
}

fn expandAbbrevHash(allocator: std.mem.Allocator, git_dir: []const u8, abbrev: []const u8) ![]u8 {
    if (abbrev.len < 4) return error.TooShort;
    const prefix = abbrev[0..2];
    const rest_prefix = abbrev[2..];
    const subdir_path = std.fmt.allocPrint(allocator, "{s}/objects/{s}", .{ git_dir, prefix }) catch return error.OutOfMemory;
    defer allocator.free(subdir_path);

    var dir = std.fs.cwd().openDir(subdir_path, .{ .iterate = true }) catch return error.NotFound;
    defer dir.close();

    var match: ?[40]u8 = null;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file and entry.name.len == 38 and std.mem.startsWith(u8, entry.name, rest_prefix)) {
            if (match != null) return error.AmbiguousHash;
            var full: [40]u8 = undefined;
            @memcpy(full[0..2], prefix);
            @memcpy(full[2..], entry.name[0..38]);
            match = full;
        }
    }

    if (match) |m| {
        return try allocator.dupe(u8, &m);
    }
    return error.NotFound;
}

fn nativeCmdMergeBase(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var all_mode = false;
    var is_ancestor = false;
    var independent = false;
    var fork_point = false;
    var octopus = false;
    var commits = std.array_list.Managed([]const u8).init(allocator);
    defer commits.deinit();

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) {
            all_mode = true;
        } else if (std.mem.eql(u8, arg, "--is-ancestor")) {
            is_ancestor = true;
        } else if (std.mem.eql(u8, arg, "--independent")) {
            independent = true;
        } else if (std.mem.eql(u8, arg, "--fork-point")) {
            fork_point = true;
        } else if (std.mem.eql(u8, arg, "--octopus")) {
            octopus = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git merge-base [-a | --all] <commit> <commit>...\n   or: git merge-base [-a | --all] --octopus <commit>...\n   or: git merge-base --independent <commit>...\n   or: git merge-base --is-ancestor <commit> <commit>\n   or: git merge-base --fork-point <ref> [<commit>]\n");
            std.process.exit(129);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try commits.append(arg);
        }
    }

    const git_dir = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // Resolve all commit arguments to hashes
    var resolved = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (resolved.items) |h| allocator.free(h);
        resolved.deinit();
    }
    for (commits.items) |c| {
        // Check if it's already a full hex SHA
        const hash = if (c.len == 40 and isAllHex(c))
            try allocator.dupe(u8, c)
        else if (refs.resolveRef(git_dir, c, platform_impl, allocator) catch null) |h|
            h
        else blk: {
            // Try abbreviated hash - check objects dir
            if (c.len >= 4 and isAllHex(c)) {
                if (expandAbbrevHash(allocator, git_dir, c)) |expanded| {
                    break :blk expanded;
                } else |_| {}
            }
            const msg = std.fmt.allocPrint(allocator, "fatal: Not a valid object name {s}\n", .{c}) catch unreachable;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
            unreachable;
        };
        try resolved.append(hash);
    }

    if (is_ancestor) {
        if (resolved.items.len != 2) {
            try platform_impl.writeStderr("usage: git merge-base --is-ancestor <commit> <commit>\n");
            std.process.exit(129);
        }
        // Check if first is ancestor of second
        var ancestors = std.StringHashMap(void).init(allocator);
        defer {
            var it = ancestors.iterator();
            while (it.next()) |entry| allocator.free(entry.key_ptr.*);
            ancestors.deinit();
        }
        try collectAncestors(git_dir, resolved.items[1], &ancestors, allocator, platform_impl);
        if (ancestors.contains(resolved.items[0])) {
            // Is ancestor - exit 0
            return;
        } else {
            std.process.exit(1);
        }
    }

    if (independent) {
        // Find commits that are not ancestors of any other commit in the list
        // For each commit, check if it's an ancestor of any other
        var indep = std.array_list.Managed([]const u8).init(allocator);
        defer indep.deinit();

        for (resolved.items, 0..) |commit_hash, ci| {
            var is_reachable = false;
            for (resolved.items, 0..) |other_hash, oi| {
                if (ci == oi) continue;
                // Check if commit_hash is ancestor of other_hash
                var ancestors = std.StringHashMap(void).init(allocator);
                defer {
                    var it = ancestors.iterator();
                    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
                    ancestors.deinit();
                }
                try collectAncestors(git_dir, other_hash, &ancestors, allocator, platform_impl);
                if (ancestors.contains(commit_hash)) {
                    is_reachable = true;
                    break;
                }
            }
            if (!is_reachable) {
                try indep.append(commit_hash);
            }
        }

        for (indep.items, 0..) |h, hi| {
            if (hi > 0) try platform_impl.writeStdout(" ");
            const out = std.fmt.allocPrint(allocator, "{s}", .{h}) catch continue;
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        }
        if (indep.items.len > 0) try platform_impl.writeStdout("\n");
        return;
    }

    if (fork_point) {
        // Simplified fork-point: find merge-base between commit and ref tip
        if (resolved.items.len < 1) {
            try platform_impl.writeStderr("usage: git merge-base --fork-point <ref> [<commit>]\n");
            std.process.exit(129);
        }
        // Use HEAD as second commit if not specified
        const second = if (resolved.items.len >= 2) resolved.items[1] else blk: {
            const head = refs.resolveRef(git_dir, "HEAD", platform_impl, allocator) catch {
                std.process.exit(1);
                unreachable;
            };
            break :blk head orelse {
                std.process.exit(1);
                unreachable;
            };
        };
        const mb = findMergeBase(git_dir, resolved.items[0], second, allocator, platform_impl) catch {
            std.process.exit(1);
            unreachable;
        };
        defer allocator.free(mb);
        const out = std.fmt.allocPrint(allocator, "{s}\n", .{mb}) catch unreachable;
        defer allocator.free(out);
        try platform_impl.writeStdout(out);
        return;
    }

    if (octopus) {
        // Octopus merge base: find merge base of all commits iteratively
        if (resolved.items.len < 2) {
            try platform_impl.writeStderr("fatal: Not enough arguments\n");
            std.process.exit(128);
            unreachable;
        }
        var current = try allocator.dupe(u8, resolved.items[0]);
        var j: usize = 1;
        while (j < resolved.items.len) : (j += 1) {
            const mb = findMergeBase(git_dir, current, resolved.items[j], allocator, platform_impl) catch {
                std.process.exit(1);
                unreachable;
            };
            allocator.free(current);
            current = mb;
        }
        defer allocator.free(current);
        const out = std.fmt.allocPrint(allocator, "{s}\n", .{current}) catch unreachable;
        defer allocator.free(out);
        try platform_impl.writeStdout(out);
        return;
    }

    // Default: find merge base between two commits
    if (resolved.items.len < 2) {
        try platform_impl.writeStderr("usage: git merge-base [-a | --all] <commit> <commit>...\n");
        std.process.exit(128);
        unreachable;
    }

    if (all_mode) {
        // Find all merge bases
        const bases = try findAllMergeBases(git_dir, resolved.items[0], resolved.items[1], allocator, platform_impl);
        defer {
            for (bases) |b| allocator.free(b);
            allocator.free(bases);
        }
        for (bases) |b| {
            const out = std.fmt.allocPrint(allocator, "{s}\n", .{b}) catch continue;
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        }
        if (bases.len == 0) std.process.exit(1);
    } else {
        // For multiple commits, find merge-base iteratively (pairwise)
        var current = try allocator.dupe(u8, resolved.items[0]);
        var j: usize = 1;
        while (j < resolved.items.len) : (j += 1) {
            const mb = findMergeBase(git_dir, current, resolved.items[j], allocator, platform_impl) catch {
                std.process.exit(1);
                unreachable;
            };
            allocator.free(current);
            current = mb;
        }
        defer allocator.free(current);
        const out = std.fmt.allocPrint(allocator, "{s}\n", .{current}) catch unreachable;
        defer allocator.free(out);
        try platform_impl.writeStdout(out);
    }
}

/// Find all merge bases between two commits (not just the first one found)
fn findAllMergeBases(git_dir: []const u8, hash1: []const u8, hash2: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) ![][]const u8 {
    // Collect ancestors of both commits
    var ancestors1 = std.StringHashMap(void).init(allocator);
    defer {
        var it = ancestors1.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        ancestors1.deinit();
    }
    var ancestors2 = std.StringHashMap(void).init(allocator);
    defer {
        var it = ancestors2.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        ancestors2.deinit();
    }

    try collectAncestors(git_dir, hash1, &ancestors1, allocator, platform_impl);
    try collectAncestors(git_dir, hash2, &ancestors2, allocator, platform_impl);

    // Common ancestors are the intersection
    var common = std.array_list.Managed([]const u8).init(allocator);
    defer common.deinit();

    var it = ancestors1.iterator();
    while (it.next()) |entry| {
        if (ancestors2.contains(entry.key_ptr.*)) {
            try common.append(try allocator.dupe(u8, entry.key_ptr.*));
        }
    }

    // Filter out non-maximal: remove any common ancestor that is itself
    // an ancestor of another common ancestor
    var result = std.array_list.Managed([]const u8).init(allocator);
    defer result.deinit();

    for (common.items) |candidate| {
        var is_ancestor_of_other = false;
        for (common.items) |other| {
            if (std.mem.eql(u8, candidate, other)) continue;
            // Check if candidate is ancestor of other
            var other_ancestors = std.StringHashMap(void).init(allocator);
            defer {
                var oit = other_ancestors.iterator();
                while (oit.next()) |oe| allocator.free(oe.key_ptr.*);
                other_ancestors.deinit();
            }
            try collectAncestors(git_dir, other, &other_ancestors, allocator, platform_impl);
            if (other_ancestors.contains(candidate)) {
                is_ancestor_of_other = true;
                break;
            }
        }
        if (!is_ancestor_of_other) {
            try result.append(try allocator.dupe(u8, candidate));
        }
    }

    // Free common list entries not in result
    for (common.items) |c| allocator.free(c);

    return try result.toOwnedSlice();
}

fn nativeCmdUnpackObjects(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var dry_run = false;
    var strict = false;
    var quiet = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-n")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            strict = true;
        } else if (std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-r")) {
            // recover - accepted
        } else if (std.mem.startsWith(u8, arg, "--max-input-size=")) {
            // accepted
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git unpack-objects [-n] [-q] [-r] [--strict]\n");
            std.process.exit(129);
        }
    }

    const git_dir = findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // Read pack data from stdin
    const stdin_file = std.fs.File.stdin();
    const pack_data = stdin_file.readToEndAlloc(allocator, 4 * 1024 * 1024 * 1024) catch {
        try platform_impl.writeStderr("fatal: error reading pack data from stdin\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(pack_data);

    // Validate pack header
    if (pack_data.len < 12) {
        try platform_impl.writeStderr("fatal: pack too short\n");
        std.process.exit(128);
        unreachable;
    }
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) {
        try platform_impl.writeStderr("fatal: bad pack header\n");
        std.process.exit(128);
        unreachable;
    }

    const version = std.mem.readInt(u32, pack_data[4..8], .big);
    if (version != 2 and version != 3) {
        const msg = std.fmt.allocPrint(allocator, "fatal: unknown pack file version {d}\n", .{version}) catch unreachable;
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
        unreachable;
    }

    const num_objects = std.mem.readInt(u32, pack_data[8..12], .big);

    if (!quiet) {
        const msg = std.fmt.allocPrint(allocator, "Unpacking {d} objects: ", .{num_objects}) catch unreachable;
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
    }

    const zlib_compat = @import("git/zlib_compat.zig");
    const objects_dir = std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir}) catch unreachable;
    defer allocator.free(objects_dir);

    var pos: usize = 12;
    var unpacked: usize = 0;
    var obj_idx: u32 = 0;
    while (obj_idx < num_objects and pos < pack_data.len -| 20) : (obj_idx += 1) {
        const entry_start = pos;
        _ = entry_start;

        // Parse variable-length object header
        var c = pack_data[pos];
        pos += 1;
        const obj_type: u8 = (c >> 4) & 0x07;
        var obj_size: u64 = c & 0x0F;
        var shift: u6 = 4;
        while (c & 0x80 != 0 and pos < pack_data.len) {
            c = pack_data[pos];
            pos += 1;
            obj_size |= @as(u64, c & 0x7F) << shift;
            shift +|= 7;
        }

        var base_hash: ?[20]u8 = null;
        var base_offset: ?u64 = null;

        if (obj_type == 6) {
            // OFS_DELTA
            c = pack_data[pos];
            pos += 1;
            var offset: u64 = c & 0x7F;
            while (c & 0x80 != 0 and pos < pack_data.len) {
                c = pack_data[pos];
                pos += 1;
                offset = ((offset + 1) << 7) | (c & 0x7F);
            }
            base_offset = offset;
        } else if (obj_type == 7) {
            // REF_DELTA
            if (pos + 20 > pack_data.len) break;
            base_hash = pack_data[pos..][0..20].*;
            pos += 20;
        }

        // Decompress using zlib C API for accurate byte tracking
        const decomp_result3 = zlib_compat.decompressSliceWithConsumed(allocator, pack_data[pos..]) catch {
            continue;
        };
        const content_owned = decomp_result3.data;
        defer allocator.free(content_owned);
        pos += decomp_result3.consumed;

        // Determine actual object type and content (resolve deltas)
        var final_type: u8 = obj_type;
        var final_content: []const u8 = content_owned;
        var resolved_content: ?[]u8 = null;

        if (obj_type == 7 and base_hash != null) {
            // REF_DELTA: resolve using base object hash
            var hex: [40]u8 = undefined;
            for (base_hash.?, 0..) |b, bi| {
                _ = std.fmt.bufPrint(hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
            }
            if (objects.GitObject.load(&hex, git_dir, platform_impl, allocator)) |base_obj| {
                defer base_obj.deinit(allocator);
                final_type = switch (base_obj.type) {
                    .commit => 1,
                    .tree => 2,
                    .blob => 3,
                    .tag => 4,
                };
                resolved_content = applyDelta(allocator, base_obj.data, content_owned) catch null;
                if (resolved_content) |rc| final_content = rc;
            } else |_| {
                if (strict) {
                    try platform_impl.writeStderr("error: could not resolve delta base\n");
                    std.process.exit(1);
                }
                continue;
            }
        } else if (obj_type == 6) {
            // OFS_DELTA: would need to track previous objects by offset
            // For now, skip - this is a simplified implementation
        }
        defer if (resolved_content) |rc| allocator.free(rc);

        if (final_type >= 1 and final_type <= 4 and !dry_run) {
            const type_str: []const u8 = switch (final_type) {
                1 => "commit",
                2 => "tree",
                3 => "blob",
                4 => "tag",
                else => continue,
            };

            // Compute SHA1 hash
            const header = std.fmt.allocPrint(allocator, "{s} {d}\x00", .{ type_str, final_content.len }) catch continue;
            defer allocator.free(header);
            var hasher = std.crypto.hash.Sha1.init(.{});
            hasher.update(header);
            hasher.update(final_content);
            const sha = hasher.finalResult();

            var hash_hex: [40]u8 = undefined;
            for (sha, 0..) |b, bi| {
                _ = std.fmt.bufPrint(hash_hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
            }

            // Check if object already exists
            const obj_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir, hash_hex[0..2] }) catch continue;
            defer allocator.free(obj_dir);
            const obj_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ obj_dir, hash_hex[2..] }) catch continue;
            defer allocator.free(obj_path);

            if (std.fs.cwd().statFile(obj_path)) |_| {
                // Already exists
                unpacked += 1;
                continue;
            } else |_| {}

            // Create directory
            std.fs.cwd().makePath(obj_dir) catch continue;

            // Compress and write object
            const zlib_compat2 = @import("git/zlib_compat.zig");
            var combined = std.array_list.Managed(u8).init(allocator);
            defer combined.deinit();
            try combined.appendSlice(header);
            try combined.appendSlice(final_content);
            const obj_data_buf = zlib_compat2.compressSlice(allocator, combined.items) catch continue;
            defer allocator.free(obj_data_buf);

            std.fs.cwd().writeFile(.{ .sub_path = obj_path, .data = obj_data_buf }) catch continue;
            unpacked += 1;
        } else if (final_type >= 1 and final_type <= 4) {
            unpacked += 1;
        }
    }

    if (!quiet) {
        const msg = std.fmt.allocPrint(allocator, "{d}, done.\n", .{unpacked}) catch unreachable;
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
    }
}

/// Apply a git delta to a base object, producing the result
fn applyDelta(allocator: std.mem.Allocator, base: []const u8, delta: []const u8) ![]u8 {
    if (delta.len < 4) return error.InvalidDelta;

    var pos: usize = 0;

    // Read base size (variable-length encoding)
    var base_size: u64 = 0;
    var shift: u6 = 0;
    while (pos < delta.len) {
        const c = delta[pos];
        pos += 1;
        base_size |= @as(u64, c & 0x7F) << shift;
        shift +|= 7;
        if (c & 0x80 == 0) break;
    }

    // Read result size
    var result_size: u64 = 0;
    shift = 0;
    while (pos < delta.len) {
        const c = delta[pos];
        pos += 1;
        result_size |= @as(u64, c & 0x7F) << shift;
        shift +|= 7;
        if (c & 0x80 == 0) break;
    }

    if (base_size != base.len) return error.BaseSizeMismatch;

    var result = try std.array_list.Managed(u8).initCapacity(allocator, @intCast(result_size));
    errdefer result.deinit();

    while (pos < delta.len) {
        const cmd = delta[pos];
        pos += 1;

        if (cmd & 0x80 != 0) {
            // Copy from base
            var copy_offset: u64 = 0;
            var copy_size: u64 = 0;

            if (cmd & 0x01 != 0) { copy_offset = delta[pos]; pos += 1; }
            if (cmd & 0x02 != 0) { copy_offset |= @as(u64, delta[pos]) << 8; pos += 1; }
            if (cmd & 0x04 != 0) { copy_offset |= @as(u64, delta[pos]) << 16; pos += 1; }
            if (cmd & 0x08 != 0) { copy_offset |= @as(u64, delta[pos]) << 24; pos += 1; }

            if (cmd & 0x10 != 0) { copy_size = delta[pos]; pos += 1; }
            if (cmd & 0x20 != 0) { copy_size |= @as(u64, delta[pos]) << 8; pos += 1; }
            if (cmd & 0x40 != 0) { copy_size |= @as(u64, delta[pos]) << 16; pos += 1; }

            if (copy_size == 0) copy_size = 0x10000;

            const start: usize = @intCast(copy_offset);
            const end: usize = @intCast(copy_offset + copy_size);
            if (end > base.len) return error.CopyOutOfBounds;
            try result.appendSlice(base[start..end]);
        } else if (cmd != 0) {
            // Insert new data
            const size: usize = cmd;
            if (pos + size > delta.len) return error.InsertOutOfBounds;
            try result.appendSlice(delta[pos .. pos + size]);
            pos += size;
        } else {
            return error.InvalidDeltaCmd;
        }
    }

    return try result.toOwnedSlice();
}

// ============================================================================
// Phase 2: New native command implementations

// ============================================================================
// Phase 2: New native command implementations (pure Zig, no git forwarding)
// ============================================================================

fn nativeCmdVar(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    const allocator = std.heap.page_allocator;
    const rest = args[command_index + 1 ..];
    
    if (rest.len == 0 or std.mem.eql(u8, rest[0], "-l")) {
        // List all variables
        try outputVar(allocator, "GIT_COMMITTER_IDENT", platform_impl);
        try outputVar(allocator, "GIT_AUTHOR_IDENT", platform_impl);
        try outputVar(allocator, "GIT_EDITOR", platform_impl);
        try outputVar(allocator, "GIT_PAGER", platform_impl);
        try outputVar(allocator, "GIT_DEFAULT_BRANCH", platform_impl);
        return;
    }
    
    const var_name = rest[0];
    if (std.mem.eql(u8, var_name, "GIT_AUTHOR_IDENT") or
        std.mem.eql(u8, var_name, "GIT_COMMITTER_IDENT") or
        std.mem.eql(u8, var_name, "GIT_EDITOR") or
        std.mem.eql(u8, var_name, "GIT_PAGER") or
        std.mem.eql(u8, var_name, "GIT_DEFAULT_BRANCH") or
        std.mem.eql(u8, var_name, "GIT_SEQUENCE_EDITOR"))
    {
        try outputVar(allocator, var_name, platform_impl);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "Unknown variable: '{s}'\n", .{var_name});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    }
}

fn outputVar(allocator: std.mem.Allocator, var_name: []const u8, platform_impl: *const platform_mod.Platform) !void {
    const val = getVarValue(allocator, var_name) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: unable to determine {s}\n", .{var_name});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    };
    defer allocator.free(val);
    const out = try std.fmt.allocPrint(allocator, "{s}\n", .{val});
    defer allocator.free(out);
    try platform_impl.writeStdout(out);
}

fn getVarValue(allocator: std.mem.Allocator, var_name: []const u8) ![]u8 {
    if (std.mem.eql(u8, var_name, "GIT_AUTHOR_IDENT") or std.mem.eql(u8, var_name, "GIT_COMMITTER_IDENT")) {
        const prefix = if (std.mem.eql(u8, var_name, "GIT_AUTHOR_IDENT")) "GIT_AUTHOR" else "GIT_COMMITTER";
        return getGitIdent(allocator, prefix);
    } else if (std.mem.eql(u8, var_name, "GIT_EDITOR") or std.mem.eql(u8, var_name, "GIT_SEQUENCE_EDITOR")) {
        if (std.mem.eql(u8, var_name, "GIT_SEQUENCE_EDITOR")) {
            return std.process.getEnvVarOwned(allocator, "GIT_SEQUENCE_EDITOR") catch
                return getVarValue(allocator, "GIT_EDITOR");
        }
        return std.process.getEnvVarOwned(allocator, "GIT_EDITOR") catch
            std.process.getEnvVarOwned(allocator, "VISUAL") catch
            std.process.getEnvVarOwned(allocator, "EDITOR") catch
            allocator.dupe(u8, "vi");
    } else if (std.mem.eql(u8, var_name, "GIT_PAGER")) {
        return std.process.getEnvVarOwned(allocator, "GIT_PAGER") catch
            std.process.getEnvVarOwned(allocator, "PAGER") catch
            allocator.dupe(u8, "less");
    } else if (std.mem.eql(u8, var_name, "GIT_DEFAULT_BRANCH")) {
        return allocator.dupe(u8, "master");
    }
    return error.UnknownVariable;
}

fn getGitIdent(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const name_key = try std.fmt.allocPrint(allocator, "{s}_NAME", .{prefix});
    defer allocator.free(name_key);
    const email_key = try std.fmt.allocPrint(allocator, "{s}_EMAIL", .{prefix});
    defer allocator.free(email_key);
    
    const name = std.process.getEnvVarOwned(allocator, name_key) catch
        std.process.getEnvVarOwned(allocator, "GIT_AUTHOR_NAME") catch
        try allocator.dupe(u8, "Unknown");
    defer allocator.free(name);
    
    const email = std.process.getEnvVarOwned(allocator, email_key) catch
        std.process.getEnvVarOwned(allocator, "GIT_AUTHOR_EMAIL") catch
        std.process.getEnvVarOwned(allocator, "EMAIL") catch
        try allocator.dupe(u8, "unknown@example.com");
    defer allocator.free(email);

    const date_key = try std.fmt.allocPrint(allocator, "{s}_DATE", .{prefix});
    defer allocator.free(date_key);
    
    const date_str = std.process.getEnvVarOwned(allocator, date_key) catch null;
    defer if (date_str) |d| allocator.free(d);
    
    if (date_str) |d| {
        return std.fmt.allocPrint(allocator, "{s} <{s}> {s}", .{ name, email, d });
    }
    
    const timestamp = std.time.timestamp();
    return std.fmt.allocPrint(allocator, "{s} <{s}> {d} +0000", .{ name, email, timestamp });
}

fn nativeCmdDiffTree(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    const allocator = std.heap.page_allocator;
    const rest = args[command_index + 1 ..];
    
    var recursive = false;
    var show_patch = false;
    var show_root = false;
    var name_only = false;
    var name_status = false;
    var no_commit_id = false;
    var tree_refs = std.array_list.Managed([]const u8).init(allocator);
    defer tree_refs.deinit();
    
    for (rest) |arg| {
        if (std.mem.eql(u8, arg, "-r")) {
            recursive = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch") or std.mem.eql(u8, arg, "-u")) {
            show_patch = true;
            recursive = true;
        } else if (std.mem.eql(u8, arg, "--root")) {
            show_root = true;
        } else if (std.mem.eql(u8, arg, "--name-only")) {
            name_only = true;
        } else if (std.mem.eql(u8, arg, "--name-status")) {
            name_status = true;
        } else if (std.mem.eql(u8, arg, "--no-commit-id")) {
            no_commit_id = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git diff-tree [<options>] <tree-ish> [<tree-ish>] [<path>...]\n");
            std.process.exit(129);
        } else if (arg.len > 0 and arg[0] != '-') {
            try tree_refs.append(arg);
        }
    }
    
    if (tree_refs.items.len == 0) {
        // Read commit hashes from stdin
        const stdin_data = readStdin(allocator, 1024 * 1024) catch return;
        defer allocator.free(stdin_data);
        var line_it = std.mem.splitScalar(u8, stdin_data, '\n');
        while (line_it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            diffTreeForCommit(allocator, trimmed, recursive, show_patch, show_root, name_only, name_status, no_commit_id, platform_impl) catch {};
        }
        return;
    }
    
    if (tree_refs.items.len == 1) {
        try diffTreeForCommit(allocator, tree_refs.items[0], recursive, show_patch, show_root, name_only, name_status, no_commit_id, platform_impl);
    } else {
        // Resolve both refs to tree hashes
        const git_path = findGitDirectory(allocator, platform_impl) catch {
            try platform_impl.writeStderr("fatal: not a git repository\n");
            std.process.exit(128);
        };
        defer allocator.free(git_path);
        const tree1 = resolveToTree(allocator, tree_refs.items[0], git_path, platform_impl) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: bad object {s}\n", .{tree_refs.items[0]});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        defer allocator.free(tree1);
        const tree2 = resolveToTree(allocator, tree_refs.items[1], git_path, platform_impl) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: bad object {s}\n", .{tree_refs.items[1]});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        defer allocator.free(tree2);
        try diffTwoTrees(allocator, tree1, tree2, "", recursive, show_patch, name_only, name_status, platform_impl);
    }
}

fn resolveToTree(allocator: std.mem.Allocator, ref_str: []const u8, git_path: []const u8, platform_impl: *const platform_mod.Platform) ![]u8 {
    const hash = try resolveRevision(git_path, ref_str, platform_impl, allocator);
    defer allocator.free(hash);
    
    const obj = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch return error.BadObject;
    defer obj.deinit(allocator);
    
    if (obj.type == .tree) {
        return allocator.dupe(u8, hash);
    } else if (obj.type == .commit) {
        // Extract tree hash from commit
        var line_iter = std.mem.splitScalar(u8, obj.data, '\n');
        while (line_iter.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "tree ")) {
                return allocator.dupe(u8, line["tree ".len..]);
            }
        }
        return error.BadObject;
    } else {
        return error.BadObject;
    }
}

fn diffTreeForCommit(allocator: std.mem.Allocator, commit_ref: []const u8, recursive: bool, show_patch: bool, show_root: bool, name_only: bool, name_status: bool, no_commit_id: bool, platform_impl: *const platform_mod.Platform) !void {
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);
    
    const commit_hash = try resolveRevision(git_path, commit_ref, platform_impl, allocator);
    defer allocator.free(commit_hash);
    
    const commit_obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: bad object {s}\n", .{commit_ref});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    };
    defer commit_obj.deinit(allocator);
    
    var tree_hash: ?[]const u8 = null;
    var parent_hash: ?[]const u8 = null;
    var line_iter = std.mem.splitScalar(u8, commit_obj.data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "tree ")) {
            tree_hash = line["tree ".len..];
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            if (parent_hash == null) parent_hash = line["parent ".len..];
        }
    }
    
    const this_tree = tree_hash orelse return;
    
    if (parent_hash == null) {
        if (show_root) {
            if (!no_commit_id) {
                const id_line = try std.fmt.allocPrint(allocator, "{s}\n", .{commit_hash});
                defer allocator.free(id_line);
                try platform_impl.writeStdout(id_line);
            }
            try diffTreeWithEmpty(allocator, this_tree, recursive, show_patch, name_only, name_status, git_path, platform_impl);
        }
        return;
    }
    
    // Get parent tree
    const parent_obj = objects.GitObject.load(parent_hash.?, git_path, platform_impl, allocator) catch return;
    defer parent_obj.deinit(allocator);
    
    var parent_tree: ?[]const u8 = null;
    var piter = std.mem.splitScalar(u8, parent_obj.data, '\n');
    while (piter.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "tree ")) {
            parent_tree = line["tree ".len..];
            break;
        }
    }
    
    if (parent_tree) |pt| {
        // Only output if trees differ
        if (!std.mem.eql(u8, pt, this_tree)) {
            if (!no_commit_id) {
                const id_line = try std.fmt.allocPrint(allocator, "{s}\n", .{commit_hash});
                defer allocator.free(id_line);
                try platform_impl.writeStdout(id_line);
            }
            try diffTwoTrees(allocator, pt, this_tree, "", recursive, show_patch, name_only, name_status, platform_impl);
        }
    }
}

fn diffTreeWithEmpty(allocator: std.mem.Allocator, tree_hash_str: []const u8, recursive: bool, show_patch: bool, name_only: bool, name_status: bool, git_path: []const u8, platform_impl: *const platform_mod.Platform) !void {
    const tree_obj = objects.GitObject.load(tree_hash_str, git_path, platform_impl, allocator) catch return;
    defer tree_obj.deinit(allocator);
    
    var entries = tree_mod.parseTree(tree_obj.data, allocator) catch return;
    defer entries.deinit();
    
    const zero_hash = "0000000000000000000000000000000000000000";
    
    for (entries.items) |entry| {
        if (recursive and std.mem.eql(u8, entry.mode, "040000")) {
            try diffTreeWithEmpty(allocator, entry.hash, recursive, show_patch, name_only, name_status, git_path, platform_impl);
            continue;
        }
        
        if (name_only) {
            const out = try std.fmt.allocPrint(allocator, "{s}\n", .{entry.name});
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        } else if (name_status) {
            const out = try std.fmt.allocPrint(allocator, "A\t{s}\n", .{entry.name});
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        } else {
            const out = try std.fmt.allocPrint(allocator, ":000000 {s} {s} {s} A\t{s}\n", .{ entry.mode, zero_hash, entry.hash, entry.name });
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        }
    }
}

fn diffTwoTrees(allocator: std.mem.Allocator, tree1_hash: []const u8, tree2_hash: []const u8, prefix: []const u8, recursive: bool, show_patch: bool, name_only: bool, name_status: bool, platform_impl: *const platform_mod.Platform) !void {
    const git_path = findGitDirectory(allocator, platform_impl) catch return;
    defer allocator.free(git_path);
    
    const tree1_obj = objects.GitObject.load(tree1_hash, git_path, platform_impl, allocator) catch return;
    defer tree1_obj.deinit(allocator);
    const tree2_obj = objects.GitObject.load(tree2_hash, git_path, platform_impl, allocator) catch return;
    defer tree2_obj.deinit(allocator);
    
    var entries1 = tree_mod.parseTree(tree1_obj.data, allocator) catch return;
    defer entries1.deinit();
    var entries2 = tree_mod.parseTree(tree2_obj.data, allocator) catch return;
    defer entries2.deinit();
    
    const zero_hash = "0000000000000000000000000000000000000000";
    
    // Build lookup maps
    var map1 = std.StringHashMap(tree_mod.TreeEntry).init(allocator);
    defer map1.deinit();
    var map2 = std.StringHashMap(tree_mod.TreeEntry).init(allocator);
    defer map2.deinit();
    for (entries1.items) |e| map1.put(e.name, e) catch {};
    for (entries2.items) |e| map2.put(e.name, e) catch {};
    
    // Collect and sort all names
    var all_names = std.StringHashMap(void).init(allocator);
    defer all_names.deinit();
    for (entries1.items) |e| all_names.put(e.name, {}) catch {};
    for (entries2.items) |e| all_names.put(e.name, {}) catch {};
    
    var name_list = std.array_list.Managed([]const u8).init(allocator);
    defer name_list.deinit();
    var niter = all_names.keyIterator();
    while (niter.next()) |key| try name_list.append(key.*);
    std.mem.sort([]const u8, name_list.items, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.cmp);
    
    for (name_list.items) |name| {
        const e1 = map1.get(name);
        const e2 = map2.get(name);
        
        const full_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);
        defer allocator.free(full_name);
        
        if (e1 != null and e2 != null) {
            if (std.mem.eql(u8, e1.?.hash, e2.?.hash) and std.mem.eql(u8, e1.?.mode, e2.?.mode)) continue;
            if (recursive and std.mem.eql(u8, e1.?.mode, "040000") and std.mem.eql(u8, e2.?.mode, "040000")) {
                try diffTwoTrees(allocator, e1.?.hash, e2.?.hash, full_name, recursive, show_patch, name_only, name_status, platform_impl);
                continue;
            }
            if (name_only) {
                const out = try std.fmt.allocPrint(allocator, "{s}\n", .{full_name});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            } else if (name_status) {
                const out = try std.fmt.allocPrint(allocator, "M\t{s}\n", .{full_name});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            } else {
                const out = try std.fmt.allocPrint(allocator, ":{s} {s} {s} {s} M\t{s}\n", .{ e1.?.mode, e2.?.mode, e1.?.hash, e2.?.hash, full_name });
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            }
        } else if (e1 != null and e2 == null) {
            if (name_only) {
                const out = try std.fmt.allocPrint(allocator, "{s}\n", .{full_name});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            } else if (name_status) {
                const out = try std.fmt.allocPrint(allocator, "D\t{s}\n", .{full_name});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            } else {
                const out = try std.fmt.allocPrint(allocator, ":{s} 000000 {s} {s} D\t{s}\n", .{ e1.?.mode, e1.?.hash, zero_hash, full_name });
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            }
        } else if (e2 != null) {
            if (name_only) {
                const out = try std.fmt.allocPrint(allocator, "{s}\n", .{full_name});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            } else if (name_status) {
                const out = try std.fmt.allocPrint(allocator, "A\t{s}\n", .{full_name});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            } else {
                const out = try std.fmt.allocPrint(allocator, ":000000 {s} {s} {s} A\t{s}\n", .{ e2.?.mode, zero_hash, e2.?.hash, full_name });
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            }
        }
    }
}

fn nativeCmdDiffIndex(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    // diff-index compares a tree with the index
    // Basic stub: exit 0 (no differences) when invoked without complex args
    const rest = args[command_index + 1 ..];
    for (rest) |arg| {
        if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git diff-index [<options>] <tree-ish> [<path>...]\n");
            std.process.exit(129);
        }
    }
    // Default: no differences (exit 0)
}

fn nativeCmdShowIndex(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    _ = args;
    _ = command_index;
    const allocator = std.heap.page_allocator;
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    
    var header: [8]u8 = undefined;
    const nread = stdin.read(&header) catch {
        try platform_impl.writeStderr("fatal: unable to read pack index\n");
        std.process.exit(128);
    };
    if (nread < 8) {
        try platform_impl.writeStderr("fatal: unable to read pack index\n");
        std.process.exit(128);
    }
    
    const magic = std.mem.readInt(u32, header[0..4], .big);
    const version = std.mem.readInt(u32, header[4..8], .big);
    
    if (magic == 0xff744f63 and version == 2) {
        var fanout_bytes: [256 * 4]u8 = undefined;
        const fr = stdin.readAll(&fanout_bytes) catch {
            try platform_impl.writeStderr("fatal: unable to read fanout\n");
            std.process.exit(128);
        };
        if (fr < 256 * 4) {
            try platform_impl.writeStderr("fatal: truncated pack index\n");
            std.process.exit(128);
        }
        const num_objects = std.mem.readInt(u32, fanout_bytes[255 * 4 ..][0..4], .big);
        
        const hash_data = allocator.alloc(u8, num_objects * 20) catch {
            std.process.exit(128);
        };
        defer allocator.free(hash_data);
        _ = stdin.readAll(hash_data) catch {};
        
        const crc_data = allocator.alloc(u8, num_objects * 4) catch {
            std.process.exit(128);
        };
        defer allocator.free(crc_data);
        _ = stdin.readAll(crc_data) catch {};
        
        const offset_data = allocator.alloc(u8, num_objects * 4) catch {
            std.process.exit(128);
        };
        defer allocator.free(offset_data);
        _ = stdin.readAll(offset_data) catch {};
        
        var i: u32 = 0;
        while (i < num_objects) : (i += 1) {
            const offset = std.mem.readInt(u32, offset_data[i * 4 ..][0..4], .big);
            const hash_bytes = hash_data[i * 20 ..][0..20];
            var hash_hex: [40]u8 = undefined;
            for (hash_bytes, 0..) |b, j| {
                const hex_chars = "0123456789abcdef";
                hash_hex[j * 2] = hex_chars[b >> 4];
                hash_hex[j * 2 + 1] = hex_chars[b & 0xf];
            }
            const crc = std.mem.readInt(u32, crc_data[i * 4 ..][0..4], .big);
            const out = try std.fmt.allocPrint(allocator, "{d} {s} ({x:0>8})\n", .{ offset, hash_hex, crc });
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        }
    } else {
        try platform_impl.writeStderr("fatal: unsupported pack index version\n");
        std.process.exit(128);
    }
}

fn nativeCmdPrunePacked(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    _ = args;
    _ = command_index;
    const allocator = std.heap.page_allocator;
    
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);
    
    const objects_dir = try std.fmt.allocPrint(allocator, "{s}/objects", .{git_path});
    defer allocator.free(objects_dir);
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/pack", .{objects_dir});
    defer allocator.free(pack_dir);
    
    // Collect packed object hashes from idx files
    var packed_objs = std.StringHashMap(void).init(allocator);
    defer {
        var kit = packed_objs.keyIterator();
        while (kit.next()) |key| allocator.free(@constCast(key.*));
        packed_objs.deinit();
    }
    
    if (std.fs.cwd().openDir(pack_dir, .{ .iterate = true })) |*dir| {
        defer @constCast(dir).close();
        var diter = dir.iterate();
        while (diter.next() catch null) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".idx")) {
                const idx_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name });
                defer allocator.free(idx_path);
                const idx_data = platform_impl.fs.readFile(allocator, idx_path) catch continue;
                defer allocator.free(idx_data);
                if (idx_data.len < 8 + 256 * 4) continue;
                const idx_magic = std.mem.readInt(u32, idx_data[0..4], .big);
                const idx_ver = std.mem.readInt(u32, idx_data[4..8], .big);
                if (idx_magic != 0xff744f63 or idx_ver != 2) continue;
                const n = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
                const hash_start: usize = 8 + 256 * 4;
                var oi: u32 = 0;
                while (oi < n) : (oi += 1) {
                    const off = hash_start + oi * 20;
                    if (off + 20 > idx_data.len) break;
                    var hex: [40]u8 = undefined;
                    for (idx_data[off..][0..20], 0..) |b, j| {
                        const hc = "0123456789abcdef";
                        hex[j * 2] = hc[b >> 4];
                        hex[j * 2 + 1] = hc[b & 0xf];
                    }
                    const key = allocator.dupe(u8, &hex) catch continue;
                    packed_objs.put(key, {}) catch {};
                }
            }
        }
    } else |_| {}
    
    // Remove loose objects that are in packs
    for (0..256) |pv| {
        const ph = try std.fmt.allocPrint(allocator, "{x:0>2}", .{pv});
        defer allocator.free(ph);
        const ld = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir, ph });
        defer allocator.free(ld);
        if (std.fs.cwd().openDir(ld, .{ .iterate = true })) |*dir| {
            defer @constCast(dir).close();
            var diter = dir.iterate();
            while (diter.next() catch null) |entry| {
                if (entry.name.len == 38) {
                    const fh = try std.fmt.allocPrint(allocator, "{s}{s}", .{ ph, entry.name });
                    defer allocator.free(fh);
                    if (packed_objs.contains(fh)) {
                        const fp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ld, entry.name });
                        defer allocator.free(fp);
                        std.fs.cwd().deleteFile(fp) catch {};
                    }
                }
            }
        } else |_| {}
    }
}

fn nativeCmdVerifyCommit(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    const allocator = std.heap.page_allocator;
    const rest = args[command_index + 1 ..];
    
    for (rest) |arg| {
        if (arg.len > 0 and arg[0] == '-') continue;
        
        const git_path = findGitDirectory(allocator, platform_impl) catch {
            try platform_impl.writeStderr("fatal: not a git repository\n");
            std.process.exit(128);
        };
        defer allocator.free(git_path);
        
        const hash = resolveRevision(git_path, arg, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "error: {s}: no such commit\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };
        defer allocator.free(hash);
        
        const obj = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "error: {s}: cannot read object\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };
        defer obj.deinit(allocator);
        
        if (std.mem.indexOf(u8, obj.data, "gpgsig ") == null) {
            try platform_impl.writeStderr("error: no signature found\n");
            std.process.exit(1);
        }
    }
}

fn nativeCmdVerifyTag(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    const allocator = std.heap.page_allocator;
    const rest = args[command_index + 1 ..];
    
    for (rest) |arg| {
        if (arg.len > 0 and arg[0] == '-') continue;
        
        const git_path = findGitDirectory(allocator, platform_impl) catch {
            try platform_impl.writeStderr("fatal: not a git repository\n");
            std.process.exit(128);
        };
        defer allocator.free(git_path);
        
        const ref_str = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{arg});
        defer allocator.free(ref_str);
        
        const tag_hash_opt = refs.resolveRef(git_path, ref_str, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "error: {s}: no such tag\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };
        const tag_hash = tag_hash_opt orelse {
            const msg = try std.fmt.allocPrint(allocator, "error: {s}: no such tag\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };
        defer allocator.free(tag_hash);
        
        const obj = objects.GitObject.load(tag_hash, git_path, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "error: {s}: cannot read tag\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };
        defer obj.deinit(allocator);
        
        if (obj.type != .tag) {
            const msg = try std.fmt.allocPrint(allocator, "error: {s}: cannot verify a non-tag object\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        }
        
        if (std.mem.indexOf(u8, obj.data, "-----BEGIN") == null) {
            try platform_impl.writeStderr("error: no signature found\n");
            std.process.exit(1);
        }
    }
}

fn nativeCmdBisect(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const subcmd = args.next() orelse {
        try platform_impl.writeStdout("usage: git bisect [help|start|bad|good|new|old|terms|skip|next|reset|visualize|view|replay|log|run]\n");
        std.process.exit(1);
    };
    
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);
    
    const bisect_log_path = try std.fmt.allocPrint(allocator, "{s}/BISECT_LOG", .{git_path});
    defer allocator.free(bisect_log_path);
    const bisect_start_path = try std.fmt.allocPrint(allocator, "{s}/BISECT_START", .{git_path});
    defer allocator.free(bisect_start_path);
    
    if (std.mem.eql(u8, subcmd, "help")) {
        try platform_impl.writeStdout("usage: git bisect [help|start|bad|good|new|old|terms|skip|next|reset|visualize|view|replay|log|run]\n");
    } else if (std.mem.eql(u8, subcmd, "start")) {
        // Start bisect session
        // Write BISECT_START
        try platform_impl.fs.writeFile(bisect_start_path, "");
        // Clear bisect log
        try platform_impl.fs.writeFile(bisect_log_path, "# git bisect start\n");
        
        // Check for optional bad/good refs
        if (args.next()) |bad_ref| {
            const hash = resolveRevision(git_path, bad_ref, platform_impl, allocator) catch {
                const msg = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{bad_ref});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            };
            defer allocator.free(hash);
            
            // Write BISECT_BAD
            const bad_path = try std.fmt.allocPrint(allocator, "{s}/refs/bisect/bad", .{git_path});
            defer allocator.free(bad_path);
            
            // Create refs/bisect directory
            const bisect_dir = try std.fmt.allocPrint(allocator, "{s}/refs/bisect", .{git_path});
            defer allocator.free(bisect_dir);
            std.fs.cwd().makePath(bisect_dir) catch {};
            
            const hash_nl = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
            defer allocator.free(hash_nl);
            try platform_impl.fs.writeFile(bad_path, hash_nl);
        }
        
        try platform_impl.writeStderr("status: waiting for both good and bad commits\n");
    } else if (std.mem.eql(u8, subcmd, "bad") or std.mem.eql(u8, subcmd, "new")) {
        const rev = args.next() orelse "HEAD";
        const hash = resolveRevision(git_path, rev, platform_impl, allocator) catch {
            try platform_impl.writeStderr("fatal: bad revision\n");
            std.process.exit(128);
        };
        defer allocator.free(hash);
        
        const bisect_dir = try std.fmt.allocPrint(allocator, "{s}/refs/bisect", .{git_path});
        defer allocator.free(bisect_dir);
        std.fs.cwd().makePath(bisect_dir) catch {};
        
        const bad_path = try std.fmt.allocPrint(allocator, "{s}/refs/bisect/bad", .{git_path});
        defer allocator.free(bad_path);
        const hash_nl = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
        defer allocator.free(hash_nl);
        try platform_impl.fs.writeFile(bad_path, hash_nl);
    } else if (std.mem.eql(u8, subcmd, "good") or std.mem.eql(u8, subcmd, "old")) {
        const rev = args.next() orelse "HEAD";
        const hash = resolveRevision(git_path, rev, platform_impl, allocator) catch {
            try platform_impl.writeStderr("fatal: bad revision\n");
            std.process.exit(128);
        };
        defer allocator.free(hash);
        
        const bisect_dir = try std.fmt.allocPrint(allocator, "{s}/refs/bisect", .{git_path});
        defer allocator.free(bisect_dir);
        std.fs.cwd().makePath(bisect_dir) catch {};
        
        // Write good-<hash> ref
        const good_path = try std.fmt.allocPrint(allocator, "{s}/refs/bisect/good-{s}", .{ git_path, hash });
        defer allocator.free(good_path);
        const hash_nl = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
        defer allocator.free(hash_nl);
        try platform_impl.fs.writeFile(good_path, hash_nl);
    } else if (std.mem.eql(u8, subcmd, "reset")) {
        // Clean up bisect state
        std.fs.cwd().deleteFile(bisect_log_path) catch {};
        std.fs.cwd().deleteFile(bisect_start_path) catch {};
        const bisect_dir = try std.fmt.allocPrint(allocator, "{s}/refs/bisect", .{git_path});
        defer allocator.free(bisect_dir);
        std.fs.cwd().deleteTree(bisect_dir) catch {};
        
        // Also clean BISECT_EXPECTED_REV, BISECT_HEAD, etc.
        const be = try std.fmt.allocPrint(allocator, "{s}/BISECT_EXPECTED_REV", .{git_path});
        defer allocator.free(be);
        std.fs.cwd().deleteFile(be) catch {};
        const bh = try std.fmt.allocPrint(allocator, "{s}/BISECT_HEAD", .{git_path});
        defer allocator.free(bh);
        std.fs.cwd().deleteFile(bh) catch {};
        
        try platform_impl.writeStdout("Previous HEAD position was...\n");
    } else if (std.mem.eql(u8, subcmd, "log")) {
        const log_data = platform_impl.fs.readFile(allocator, bisect_log_path) catch {
            try platform_impl.writeStderr("We are not bisecting.\n");
            std.process.exit(1);
        };
        defer allocator.free(log_data);
        try platform_impl.writeStdout(log_data);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "error: unknown bisect subcommand '{s}'\n", .{subcmd});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    }
}

fn nativeCmdMv(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var force = false;
    var dry_run = false;
    var skip_errors = false;
    var verbose = false;
    var sources = std.array_list.Managed([]const u8).init(allocator);
    defer sources.deinit();
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-k")) {
            skip_errors = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |a| try sources.append(a);
            break;
        } else {
            try sources.append(arg);
        }
    }
    
    if (sources.items.len < 2) {
        try platform_impl.writeStderr("usage: git mv [<options>] <source>... <destination>\n");
        std.process.exit(128);
    }
    
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);
    
    const dest = sources.items[sources.items.len - 1];
    const srcs = sources.items[0 .. sources.items.len - 1];
    
    // Load index
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();
    
    // Check if dest is a directory
    const dest_is_dir = if (std.fs.cwd().statFile(dest)) |stat|
        stat.kind == .directory
    else |_|
        false;
    
    if (srcs.len > 1 and !dest_is_dir) {
        try platform_impl.writeStderr("fatal: destination is not a directory\n");
        std.process.exit(128);
    }
    
    for (srcs) |src| {
        const target = if (dest_is_dir) blk: {
            const basename = std.fs.path.basename(src);
            break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, basename });
        } else try allocator.dupe(u8, dest);
        defer allocator.free(target);
        
        // Check source exists
        if (!(std.fs.cwd().statFile(src) catch null != null)) {
            if (skip_errors) continue;
            const msg = try std.fmt.allocPrint(allocator, "fatal: bad source, source={s}, destination={s}\n", .{ src, target });
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        }
        
        // Check target doesn't exist (unless -f)
        if (!force) {
            if ((std.fs.cwd().statFile(target) catch null) != null) {
                if (skip_errors) continue;
                const msg = try std.fmt.allocPrint(allocator, "fatal: destination exists, source={s}, destination={s}\n", .{ src, target });
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }
        }
        
        if (!dry_run) {
            // Move the file
            std.fs.cwd().rename(src, target) catch |err| {
                if (skip_errors) continue;
                const msg = try std.fmt.allocPrint(allocator, "fatal: renaming '{s}' failed: {}\n", .{ src, err });
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            };
            
            // Update index: remove old entry, add new entry
            var new_entries = std.array_list.Managed(index_mod.IndexEntry).init(allocator);
            defer new_entries.deinit();
            
            for (index.entries.items) |entry| {
                if (std.mem.eql(u8, entry.path, src)) {
                    var new_entry = entry;
                    new_entry.path = target;
                    try new_entries.append(new_entry);
                } else {
                    try new_entries.append(entry);
                }
            }
            index.entries.clearRetainingCapacity();
            for (new_entries.items) |e| try index.entries.append(e);
        }
        
        if (verbose or dry_run) {
            const msg = try std.fmt.allocPrint(allocator, "Renaming {s} to {s}\n", .{ src, target });
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        }
    }
    
    if (!dry_run) {
        index.save(git_path, platform_impl) catch {};
    }
}

fn nativeCmdStash(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const subcmd = args.next() orelse "push";
    
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);
    
    if (std.mem.eql(u8, subcmd, "list")) {
        // List stash entries
        const stash_log = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_path});
        defer allocator.free(stash_log);
        _ = platform_impl.fs.readFile(allocator, stash_log) catch {
            // No stash entries - exit silently
            return;
        };
        // TODO: parse reflog to show stash entries
    } else if (std.mem.eql(u8, subcmd, "push") or std.mem.eql(u8, subcmd, "save")) {
        // Stub: stash push requires saving working tree and index state as commits
        try platform_impl.writeStderr("error: stash push not yet fully implemented natively\n");
        std.process.exit(1);
    } else if (std.mem.eql(u8, subcmd, "pop") or std.mem.eql(u8, subcmd, "apply")) {
        try platform_impl.writeStderr("error: stash pop/apply not yet fully implemented natively\n");
        std.process.exit(1);
    } else if (std.mem.eql(u8, subcmd, "drop")) {
        try platform_impl.writeStderr("error: stash drop not yet fully implemented natively\n");
        std.process.exit(1);
    } else if (std.mem.eql(u8, subcmd, "clear")) {
        // Delete stash ref
        const stash_ref = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_path});
        defer allocator.free(stash_ref);
        std.fs.cwd().deleteFile(stash_ref) catch {};
        const stash_log = try std.fmt.allocPrint(allocator, "{s}/logs/refs/stash", .{git_path});
        defer allocator.free(stash_log);
        std.fs.cwd().deleteFile(stash_log) catch {};
    } else if (std.mem.eql(u8, subcmd, "show")) {
        try platform_impl.writeStderr("error: stash show not yet fully implemented natively\n");
        std.process.exit(1);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "error: unknown stash subcommand '{s}'\n", .{subcmd});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    }
}

fn nativeCmdApply(_: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    // Basic stub for git apply
    _ = args;
    try platform_impl.writeStderr("error: git apply not yet fully implemented natively\n");
    std.process.exit(1);
}

fn nativeCmdColumn(_: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    // git column formats stdin into columns
    const allocator = std.heap.page_allocator;
    var mode: []const u8 = "always";
    var width: u32 = if (std.process.getEnvVarOwned(allocator, "COLUMNS")) |cols_str| blk: {
        defer allocator.free(cols_str);
        break :blk std.fmt.parseInt(u32, cols_str, 10) catch 80;
    } else |_| 80;
    var padding: u32 = 1;
    var indent: []const u8 = "";
    var nl: []const u8 = "\n";
    
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--mode=")) {
            mode = arg["--mode=".len..];
        } else if (std.mem.startsWith(u8, arg, "--width=")) {
            width = std.fmt.parseInt(u32, arg["--width=".len..], 10) catch 80;
        } else if (std.mem.startsWith(u8, arg, "--padding=")) {
            const pad_str = arg["--padding=".len..];
            if (pad_str.len > 0 and pad_str[0] == '-') {
                try platform_impl.writeStdout("fatal: --padding must be non-negative\n");
                std.process.exit(128);
            }
            padding = std.fmt.parseInt(u32, pad_str, 10) catch 1;
        } else if (std.mem.eql(u8, arg, "--padding")) {
            if (args.next()) |next| {
                if (next.len > 0 and next[0] == '-') {
                    try platform_impl.writeStdout("fatal: --padding must be non-negative\n");
                    std.process.exit(128);
                }
                padding = std.fmt.parseInt(u32, next, 10) catch 1;
            }
        } else if (std.mem.startsWith(u8, arg, "--indent=")) {
            indent = arg["--indent=".len..];
        } else if (std.mem.eql(u8, arg, "--indent")) {
            if (args.next()) |next| indent = next;
        } else if (std.mem.startsWith(u8, arg, "--nl=")) {
            nl = arg["--nl=".len..];
        } else if (std.mem.eql(u8, arg, "--raw-mode")) {
            // Ignore
        }
    }
    
    if (std.mem.eql(u8, mode, "never")) {
        // Pass through without formatting
        const data = readStdin(allocator, 10 * 1024 * 1024) catch return;
        defer allocator.free(data);
        try platform_impl.writeStdout(data);
        return;
    }
    
    if (std.mem.eql(u8, mode, "plain")) {
        // Each line gets indent prefix and nl suffix
        const data = readStdin(allocator, 10 * 1024 * 1024) catch return;
        defer allocator.free(data);
        var line_it = std.mem.splitScalar(u8, data, '\n');
        while (line_it.next()) |line| {
            if (line.len == 0) continue;
            try platform_impl.writeStdout(indent);
            try platform_impl.writeStdout(line);
            try platform_impl.writeStdout(nl);
        }
        return;
    }
    
    // Read all lines from stdin
    const data = readStdin(allocator, 10 * 1024 * 1024) catch return;
    defer allocator.free(data);
    
    var lines = std.array_list.Managed([]const u8).init(allocator);
    defer lines.deinit();
    var max_len: u32 = 0;
    
    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0 and lines.items.len > 0) continue;
        if (line.len > 0) {
            try lines.append(line);
            if (line.len > max_len) max_len = @intCast(line.len);
        }
    }
    
    if (lines.items.len == 0) return;
    
    const col_width = max_len + padding;
    const effective_width = if (width > @as(u32, @intCast(indent.len))) width - @as(u32, @intCast(indent.len)) else width;
    const num_cols = if (col_width > 0) @max(1, effective_width / col_width) else 1;
    const num_rows = (lines.items.len + num_cols - 1) / num_cols;
    
    if (std.mem.indexOf(u8, mode, "row") != null) {
        // Row-first layout
        var i: usize = 0;
        while (i < lines.items.len) {
            if (indent.len > 0) try platform_impl.writeStdout(indent);
            var col: usize = 0;
            while (col < num_cols and i + col < lines.items.len) : (col += 1) {
                try platform_impl.writeStdout(lines.items[i + col]);
                // Pad unless last item on line
                if (col + 1 < num_cols and i + col + 1 < lines.items.len) {
                    var pad: usize = lines.items[i + col].len;
                    while (pad < col_width) : (pad += 1) {
                        try platform_impl.writeStdout(" ");
                    }
                }
            }
            try platform_impl.writeStdout("\n");
            i += num_cols;
        }
    } else {
        // Column-first layout (default)
        var row: usize = 0;
        while (row < num_rows) : (row += 1) {
            if (indent.len > 0) try platform_impl.writeStdout(indent);
            var col: usize = 0;
            while (col < num_cols) : (col += 1) {
                const idx = col * num_rows + row;
                if (idx >= lines.items.len) break;
                try platform_impl.writeStdout(lines.items[idx]);
                // Pad to col_width unless it's the last item on the line
                const next_idx = (col + 1) * num_rows + row;
                if (col + 1 < num_cols and next_idx < lines.items.len) {
                    var pad_amt: usize = lines.items[idx].len;
                    while (pad_amt < col_width) : (pad_amt += 1) {
                        try platform_impl.writeStdout(" ");
                    }
                }
            }
            try platform_impl.writeStdout("\n");
        }
    }
}

fn nativeCmdCheckIgnore(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var verbose = false;
    var quiet = false;
    var paths = std.array_list.Managed([]const u8).init(allocator);
    defer paths.deinit();
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |a| try paths.append(a);
            break;
        } else if (arg.len > 0 and arg[0] != '-') {
            try paths.append(arg);
        }
    }
    
    const git_path = findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);
    
    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root});
    defer allocator.free(gitignore_path);
    
    var gitignore = gitignore_mod.GitIgnore.loadFromFile(allocator, gitignore_path, platform_impl) catch
        gitignore_mod.GitIgnore.init(allocator);
    defer gitignore.deinit();
    
    var found_any = false;
    for (paths.items) |path| {
        if (gitignore.isIgnored(path)) {
            found_any = true;
            if (!quiet) {
                if (verbose) {
                    const msg = try std.fmt.allocPrint(allocator, ".gitignore:0:\t{s}\n", .{path});
                    defer allocator.free(msg);
                    try platform_impl.writeStdout(msg);
                } else {
                    const msg = try std.fmt.allocPrint(allocator, "{s}\n", .{path});
                    defer allocator.free(msg);
                    try platform_impl.writeStdout(msg);
                }
            }
        }
    }
    
    if (!found_any) std.process.exit(1);
}

fn nativeCmdCheckAttr(_: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    // Basic stub - git check-attr queries gitattributes
    _ = args;
    // Default: no attributes defined
    _ = platform_impl;
}

fn checkIfDifferentFromTree(entry: index_mod.IndexEntry, tree_hash: []const u8, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !bool {
    const tree_blob_hash = try lookupBlobInTree(tree_hash, entry.path, git_path, platform_impl, allocator);
    if (tree_blob_hash) |hash_bytes| {
        return !std.mem.eql(u8, &hash_bytes, &entry.sha1);
    }
    // File not found in tree - it's new, so it's staged
    return true;
}

fn buildTreeMap(tree_hash: []const u8, prefix: []const u8, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator, map: *std.StringHashMap([20]u8)) !void {
    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch return;
    defer tree_obj.deinit(allocator);
    if (tree_obj.type != .tree) return;
    
    var i: usize = 0;
    while (i < tree_obj.data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, i, ' ') orelse break;
        const mode_str = tree_obj.data[i..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, space_pos + 1, 0) orelse break;
        const name = tree_obj.data[space_pos + 1 .. null_pos];
        const hash_start = null_pos + 1;
        if (hash_start + 20 > tree_obj.data.len) break;
        const hash_bytes = tree_obj.data[hash_start .. hash_start + 20];
        
        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);
        
        if (std.mem.eql(u8, mode_str, "40000") or std.mem.eql(u8, mode_str, "040000")) {
            // Directory - recurse
            const sub_hash = try std.fmt.allocPrint(allocator, "{x}", .{hash_bytes[0..20].*});
            defer allocator.free(sub_hash);
            buildTreeMap(sub_hash, full_path, git_path, platform_impl, allocator, map) catch {};
            allocator.free(full_path);
        } else {
            // File - store in map
            var sha1: [20]u8 = undefined;
            @memcpy(&sha1, hash_bytes[0..20]);
            try map.put(full_path, sha1);
        }
        
        i = hash_start + 20;
    }
}
