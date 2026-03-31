// Auto-generated from main_common.zig - cmd_commit
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");

const helpers = @import("git_helpers.zig");
const cmd_reflog = @import("cmd_reflog.zig");
const cmd_add = @import("cmd_add.zig");

fn isTrailerLine(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, ": ")) |colon_pos| {
        if (colon_pos == 0) return false;
        for (line[0..colon_pos]) |c| {
            if (c == ' ' or c == '\t') return false;
        }
        return true;
    }
    return false;
}

// Re-export commonly used types from helpers
const objects = helpers.objects;
const index_mod = helpers.index_mod;
const refs = helpers.refs;
const tree_mod = helpers.tree_mod;
const gitignore_mod = helpers.gitignore_mod;
const config_mod = helpers.config_mod;
const config_helpers_mod = helpers.config_helpers_mod;
const diff_mod = helpers.diff_mod;
const diff_stats_mod = helpers.diff_stats_mod;
const network = helpers.network;
const zlib_compat_mod = helpers.zlib_compat_mod;
const build_options = @import("build_options");
const version_mod = @import("version.zig");
const wildmatch_mod = @import("wildmatch.zig");

/// Extract "Name <email>" portion from a git author/committer string
/// (strips trailing timestamp like " 1234567890 +0000")
fn extractNameEmail(info: []const u8) []const u8 {
    // Find the last '>' which ends the email
    if (std.mem.lastIndexOfScalar(u8, info, '>')) |gt| {
        return info[0 .. gt + 1];
    }
    return info;
}

pub fn cmdCommit(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("commit: not supported in freestanding mode\n");
        return;
    }

    var message: ?[]const u8 = null;
    var message_parts = std.array_list.Managed([]const u8).init(allocator);
    defer message_parts.deinit();
    var allow_empty = false;
    var amend = false;
    var add_all = false;
    var quiet = false;
    var signoff = false;
    var no_verify = false;
    var author_override: ?[]const u8 = null;
    var msg_source: enum { none, m_flag, f_flag, c_flag } = .none;
    var commit_files = std.array_list.Managed([]const u8).init(allocator);
    defer commit_files.deinit();
    var seen_dashdash = false;

    // helpers.Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-m")) {
            if (msg_source == .f_flag or msg_source == .c_flag) {
                try platform_impl.writeStderr("fatal: Option -m cannot be combined with -F or -C/-c\n");
                std.process.exit(128);
            }
            msg_source = .m_flag;
            const m_val = args.next() orelse {
                try platform_impl.writeStderr("error: option `-m' requires a value\n");
                std.process.exit(129);
            };
            try message_parts.append(m_val);
        } else if (std.mem.startsWith(u8, arg, "-m")) {
            if (msg_source == .f_flag or msg_source == .c_flag) {
                try platform_impl.writeStderr("fatal: Option -m cannot be combined with -F or -C/-c\n");
                std.process.exit(128);
            }
            msg_source = .m_flag;
            try message_parts.append(arg[2..]);
        } else if (std.mem.eql(u8, arg, "-a")) {
            add_all = true;
        } else if (std.mem.eql(u8, arg, "-am") or std.mem.eql(u8, arg, "-ma")) {
            add_all = true;
            msg_source = .m_flag;
            const m_val = args.next() orelse {
                try platform_impl.writeStderr("error: option `-am' requires a message\n");
                std.process.exit(129);
            };
            try message_parts.append(m_val);
        } else if (std.mem.startsWith(u8, arg, "-am")) {
            add_all = true;
            msg_source = .m_flag;
            try message_parts.append(arg[3..]);
        } else if (std.mem.eql(u8, arg, "--allow-empty")) {
            allow_empty = true;
        } else if (std.mem.eql(u8, arg, "--amend")) {
            amend = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--file")) {
            if (msg_source == .m_flag or msg_source == .c_flag) {
                try platform_impl.writeStderr("fatal: Option -F cannot be combined with -m or -C/-c\n");
                std.process.exit(128);
            }
            msg_source = .f_flag;
            const file_path = args.next() orelse {
                try platform_impl.writeStderr("error: option '-F' requires a value\n");
                std.process.exit(129);
            };
            if (std.mem.eql(u8, file_path, "-")) {
                // helpers.Read from stdin
                const stdin_data = helpers.readStdin(allocator, 1024 * 1024) catch {
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
            if (msg_source == .m_flag or msg_source == .f_flag) {
                try platform_impl.writeStderr("fatal: Option -C cannot be combined with -m or -F\n");
                std.process.exit(128);
            }
            msg_source = .c_flag;
            // Reuse message from another commit
            const commit_ref = args.next() orelse {
                try platform_impl.writeStderr("error: option '-C' requires a value\n");
                std.process.exit(129);
            };
            // helpers.Resolve and read the commit's message
            const gp = helpers.findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStderr("fatal: not a git repository\n");
                std.process.exit(128);
            };
            defer allocator.free(gp);
            const hash = helpers.resolveRevision(gp, commit_ref, platform_impl, allocator) catch {
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
            // helpers.Extract message body (after blank line)
            if (std.mem.indexOf(u8, cobj.data, "\n\n")) |pos| {
                message = try allocator.dupe(u8, cobj.data[pos + 2 ..]);
            }
        } else if (std.mem.eql(u8, arg, "--cleanup=verbatim") or std.mem.eql(u8, arg, "--cleanup=whitespace") or
            std.mem.eql(u8, arg, "--cleanup=strip") or std.mem.eql(u8, arg, "--cleanup=scissors") or
            std.mem.startsWith(u8, arg, "--cleanup="))
        {
            // Accept cleanup modes (ignore for now)
        } else if (std.mem.eql(u8, arg, "--no-verify") or std.mem.eql(u8, arg, "-n")) {
            no_verify = true;
        } else if (std.mem.eql(u8, arg, "--signoff") or std.mem.eql(u8, arg, "-s")) {
            signoff = true;
        } else if (std.mem.eql(u8, arg, "--no-edit")) {
            // helpers.No edit
        } else if (std.mem.eql(u8, arg, "--date")) {
            if (args.next()) |dv| {
                const dv_z = try allocator.dupeZ(u8, dv);
                defer allocator.free(dv_z);
                _ = helpers.cSetenv("GIT_AUTHOR_DATE", dv_z, 1);
            }
        } else if (std.mem.startsWith(u8, arg, "--date=")) {
            const dv = arg["--date=".len..];
            const dv_z = try allocator.dupeZ(u8, dv);
            defer allocator.free(dv_z);
            _ = helpers.cSetenv("GIT_AUTHOR_DATE", dv_z, 1);
        } else if (std.mem.eql(u8, arg, "--author")) {
            if (args.next()) |val| {
                author_override = val;
            }
        } else if (std.mem.startsWith(u8, arg, "--author=")) {
            author_override = arg["--author=".len..];
        } else if (std.mem.eql(u8, arg, "--allow-empty-message")) {
            allow_empty = true; // Close enough
        } else if (std.mem.eql(u8, arg, "--")) {
            seen_dashdash = true;
            while (args.next()) |farg| try commit_files.append(farg);
            break;
        } else if (arg.len > 0 and arg[0] != '-') {
            // Positional argument - could be a file path
            try commit_files.append(arg);
        }
    }

    // Combine multiple -m messages with blank line separators (git behavior)
    if (message_parts.items.len > 0) {
        if (message_parts.items.len == 1) {
            message = message_parts.items[0];
        } else {
            var total_len: usize = 0;
            for (message_parts.items, 0..) |part, idx| {
                total_len += part.len;
                if (idx < message_parts.items.len - 1) total_len += 2; // "\n\n"
            }
            var buf = try allocator.alloc(u8, total_len);
            var pos: usize = 0;
            for (message_parts.items, 0..) |part, idx| {
                @memcpy(buf[pos .. pos + part.len], part);
                pos += part.len;
                if (idx < message_parts.items.len - 1) {
                    buf[pos] = '\n';
                    buf[pos + 1] = '\n';
                    pos += 2;
                }
            }
            message = buf;
        }
    }

    // Validate: -a and paths don't mix
    if (add_all and commit_files.items.len > 0) {
        try platform_impl.writeStderr("fatal: paths 'file ...' with -a does not make sense\n");
        std.process.exit(128);
    }

    // helpers.For --amend without -m, reuse the previous commit's message
    if (message == null and amend) {
        const gp = helpers.findGitDirectory(allocator, platform_impl) catch {
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

    // helpers.Find .git directory (needed for MERGE_MSG check below)
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // helpers.Check for MERGE_MSG or SQUASH_MSG as default message if no message provided
    if (message == null) {
        const merge_msg_path = try std.fmt.allocPrint(allocator, "{s}/MERGE_MSG", .{git_path});
        defer allocator.free(merge_msg_path);
        if (platform_impl.fs.readFile(allocator, merge_msg_path)) |mmsg| {
            message = mmsg;
        } else |_| {}
    }
    if (message == null) {
        const squash_msg_path = try std.fmt.allocPrint(allocator, "{s}/SQUASH_MSG", .{git_path});
        defer allocator.free(squash_msg_path);
        if (platform_impl.fs.readFile(allocator, squash_msg_path)) |smsg| {
            message = smsg;
        } else |_| {}
    }

    if (message == null) {
        try platform_impl.writeStderr("error: no commit message provided (use -m)\n");
        std.process.exit(1);
    }

    // helpers.Check for empty or whitespace-only message (to match git behavior)
    // Also treats messages that are only git trailers (Signed-off-by, etc.) as empty
    if (message) |msg| {
        const trimmed = std.mem.trim(u8, msg, " \t\n\r");
        if (trimmed.len == 0) {
            try platform_impl.writeStderr("Aborting commit due to empty commit message.\n");
            std.process.exit(1);
        }
        // Check if message is only trailers (git considers this as empty)
        var has_non_trailer = false;
        var line_iter = std.mem.splitScalar(u8, trimmed, '\n');
        while (line_iter.next()) |line| {
            const tline = std.mem.trim(u8, line, " \t\r");
            if (tline.len == 0) continue;
            // Skip comment lines
            if (tline[0] == '#') continue;
            // Check if line is a known trailer pattern (Key: value)
            if (isTrailerLine(tline)) continue;
            has_non_trailer = true;
            break;
        }
        if (!has_non_trailer) {
            try platform_impl.writeStderr("Aborting commit due to empty commit message.\n");
            std.process.exit(1);
        }
    }

    // helpers.Load index
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };

    // helpers.If -a flag is set, update all tracked files in the index (pure helpers.Zig, no git CLI)
    if (add_all) {
        const repo_root = std.fs.path.dirname(git_path) orelse ".";
        try cmd_add.stageTrackedChanges(allocator, &index, git_path, repo_root, platform_impl);
    }

    // helpers.If file paths were specified, stage those files before committing
    // In git, `git commit <paths>` re-stages tracked files matching the pathspec
    // from the working tree (like `git add -u <paths>`), NOT adding untracked files.
    if (commit_files.items.len > 0) {
        const cwd = try platform_impl.fs.getCwd(allocator);
        defer allocator.free(cwd);
        const repo_root = std.fs.path.dirname(git_path) orelse ".";
        for (commit_files.items) |file_arg| {
            const full_path = if (std.fs.path.isAbsolute(file_arg))
                try allocator.dupe(u8, file_arg)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, file_arg });
            defer allocator.free(full_path);

            const metadata = std.fs.cwd().statFile(full_path) catch continue;
            if (metadata.kind == .directory) {
                // For directories: re-stage tracked files matching this path prefix
                // (like `git add -u <dir>`), don't add untracked files
                const rel_dir = helpers.makeRelativePath(allocator, repo_root, full_path) catch file_arg;
                for (index.entries.items) |*entry| {
                    // Check if entry path matches the directory pathspec
                    const matches = if (std.mem.eql(u8, rel_dir, ".") or rel_dir.len == 0)
                        true // "." matches everything
                    else
                        std.mem.startsWith(u8, entry.path, rel_dir) and
                            (entry.path.len == rel_dir.len or entry.path[rel_dir.len] == '/');
                    if (matches) {
                        const entry_full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
                        defer allocator.free(entry_full);
                        // Re-stage if file exists in working tree
                        if (std.fs.cwd().statFile(entry_full) catch null) |_| {
                            index.add(entry.path, entry.path, platform_impl, git_path) catch continue;
                        }
                    }
                }
            } else {
                try cmd_add.addSingleFile(allocator, file_arg, full_path, &index, git_path, platform_impl, cwd);
            }
        }
    }
    // seen_dashdash used above
    defer index.deinit();

    // helpers.Check if there's anything to commit - compare index tree to helpers.HEAD tree
    if (!allow_empty) {
        const new_tree = try helpers.buildRecursiveTree(allocator, index.entries.items, "", git_path, platform_impl);
        defer allocator.free(new_tree);
        var has_changes = true;
        if (refs.getCurrentCommit(git_path, platform_impl, allocator) catch null) |head_h| {
            defer allocator.free(head_h);
            if (objects.GitObject.load(head_h, git_path, platform_impl, allocator)) |head_obj| {
                defer head_obj.deinit(allocator);
                const head_tree = helpers.extractHeaderField(head_obj.data, "tree");
                if (std.mem.eql(u8, new_tree, head_tree)) has_changes = false;
            } else |_| {}
        } else {
            // helpers.No helpers.HEAD - has changes if index is not empty
            if (index.entries.items.len == 0) has_changes = false;
        }
        // Allow merge commits even if tree is unchanged (e.g., resolved to one side)
        const merge_head_check_path = try std.fmt.allocPrint(allocator, "{s}/MERGE_HEAD", .{git_path});
        defer allocator.free(merge_head_check_path);
        const has_merge_head = if (platform_impl.fs.readFile(allocator, merge_head_check_path)) |mhd| blk: {
            allocator.free(mhd);
            break :blk true;
        } else |_| false;
        if (!has_changes and !amend and !has_merge_head) {
            const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch "master";
            defer allocator.free(current_branch);
            const branch_msg = try std.fmt.allocPrint(allocator, "On branch {s}\n", .{current_branch});
            defer allocator.free(branch_msg);
            try platform_impl.writeStderr(branch_msg);
            try platform_impl.writeStderr("nothing to commit, working tree clean\n");
            std.process.exit(1);
        }
    }

    // helpers.Create recursive tree helpers.objects from index entries (handles nested directories)
    const tree_hash = try helpers.buildRecursiveTree(allocator, index.entries.items, "", git_path, platform_impl);
    defer allocator.free(tree_hash);

    // helpers.Get parent commit (if any)
    var parent_hashes = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (parent_hashes.items) |hash| {
            allocator.free(hash);
        }
        parent_hashes.deinit();
    }

    if (amend) {
        // helpers.For amend, get the parents of the current commit (grandparents become parents)
        if (refs.getCurrentCommit(git_path, platform_impl, allocator) catch null) |current_hash| {
            defer allocator.free(current_hash);
            
            // helpers.Load current commit to get its parents
            const commit_object = objects.GitObject.load(current_hash, git_path, platform_impl, allocator) catch null;
            if (commit_object) |commit| {
                defer commit.deinit(allocator);
                
                // helpers.Parse commit data to find parent lines
                var lines = std.mem.splitSequence(u8, commit.data, "\n");
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "parent ")) {
                        const parent_hash = line["parent ".len..];
                        try parent_hashes.append(try allocator.dupe(u8, parent_hash));
                    } else if (line.len == 0) {
                        break; // helpers.End of headers
                    }
                }
            }
        }
    } else {
        if (refs.getCurrentCommit(git_path, platform_impl, allocator) catch null) |current_hash| {
            try parent_hashes.append(current_hash);
        }
        
        // helpers.Check for helpers.MERGE_HEAD (merge parents)
        const merge_head_path = try std.fmt.allocPrint(allocator, "{s}/MERGE_HEAD", .{git_path});
        defer allocator.free(merge_head_path);
        if (platform_impl.fs.readFile(allocator, merge_head_path)) |merge_data| {
            defer allocator.free(merge_data);
            var merge_lines = std.mem.splitScalar(u8, merge_data, '\n');
            while (merge_lines.next()) |mline| {
                const mhash = std.mem.trim(u8, mline, " \t\r");
                if (mhash.len == 40 and helpers.isValidHexString(mhash)) {
                    try parent_hashes.append(try allocator.dupe(u8, mhash));
                }
            }
        } else |_| {}
    }

    // Check user.useconfigonly - if set, require user.name and user.email
    if (helpers.getConfigValueByKey(git_path, "user.useconfigonly", allocator)) |uco_val| {
        defer allocator.free(uco_val);
        if (std.ascii.eqlIgnoreCase(uco_val, "true")) {
            const has_author_name = std.posix.getenv("GIT_AUTHOR_NAME") != null or
                (helpers.getConfigValueByKey(git_path, "user.name", allocator) != null);
            const has_author_email = std.posix.getenv("GIT_AUTHOR_EMAIL") != null or
                (helpers.getConfigValueByKey(git_path, "user.email", allocator) != null);
            if (!has_author_name or !has_author_email) {
                try platform_impl.writeStderr(
                    \\Author identity unknown\n
                    \\\n
                    \\*** Please tell me who you are.\n
                    \\\n
                    \\Run\n
                    \\\n
                    \\  git config --global user.email "you@example.com"\n
                    \\  git config --global user.name "Your Name"\n
                    \\\n
                    \\to set your account's default identity.\n
                    \\Omit --global to set the identity only in this repository.\n
                    \\\n
                    \\fatal: no existing author found with 'user.useconfigonly'\n
                );
                std.process.exit(128);
            }
            // Free the config values if we got them
            if (helpers.getConfigValueByKey(git_path, "user.name", allocator)) |v| allocator.free(v);
            if (helpers.getConfigValueByKey(git_path, "user.email", allocator)) |v| allocator.free(v);
        }
    }

    // helpers.Create commit object - use GIT_AUTHOR_DATE/GIT_COMMITTER_DATE if set
    // helpers.For --amend, preserve original commit's author info unless explicitly overridden
    const author_info = if (amend) blk: {
        // helpers.Try to get original author from the commit being amended
        if (refs.getCurrentCommit(git_path, platform_impl, allocator) catch null) |cur_hash| {
            defer allocator.free(cur_hash);
            if (objects.GitObject.load(cur_hash, git_path, platform_impl, allocator) catch null) |cobj| {
                defer cobj.deinit(allocator);
                // helpers.Extract the author line from commit data
                var clines = std.mem.splitSequence(u8, cobj.data, "\n");
                while (clines.next()) |cline| {
                    if (std.mem.startsWith(u8, cline, "author ")) {
                        break :blk try allocator.dupe(u8, cline["author ".len..]);
                    } else if (cline.len == 0) break;
                }
            }
        }
        break :blk helpers.getAuthorString(allocator) catch {
            const timestamp = std.time.timestamp();
            const tz_offset = helpers.getTimezoneOffset(timestamp);
            const tz_sign: u8 = if (tz_offset < 0) '-' else '+';
            const tz_abs: u32 = @intCast(if (tz_offset < 0) -tz_offset else tz_offset);
            const tz_hours = tz_abs / 3600;
            const tz_minutes = (tz_abs % 3600) / 60;
            break :blk try std.fmt.allocPrint(allocator, "Unknown <unknown@unknown> {d} {c}{d:0>2}{d:0>2}", .{ timestamp, tz_sign, tz_hours, tz_minutes });
        };
    } else if (author_override) |auth_str| blk_auth: {
        // --author="Name <email>" format - add timestamp
        const timestamp = std.time.timestamp();
        const auth_date_env = std.posix.getenv("GIT_AUTHOR_DATE");
        if (auth_date_env) |date_str| {
            break :blk_auth try std.fmt.allocPrint(allocator, "{s} {s}", .{ auth_str, date_str });
        }
        const tz_offset = helpers.getTimezoneOffset(timestamp);
        const tz_sign: u8 = if (tz_offset < 0) '-' else '+';
        const tz_abs: u32 = @intCast(if (tz_offset < 0) -tz_offset else tz_offset);
        const tz_hours = tz_abs / 3600;
        const tz_minutes = (tz_abs % 3600) / 60;
        break :blk_auth try std.fmt.allocPrint(allocator, "{s} {d} {c}{d:0>2}{d:0>2}", .{ auth_str, timestamp, tz_sign, tz_hours, tz_minutes });
    } else helpers.getAuthorString(allocator) catch blk: {
        const timestamp = std.time.timestamp();
        const tz_offset = helpers.getTimezoneOffset(timestamp);
        const tz_sign: u8 = if (tz_offset < 0) '-' else '+';
        const tz_abs: u32 = @intCast(if (tz_offset < 0) -tz_offset else tz_offset);
        const tz_hours = tz_abs / 3600;
        const tz_minutes = (tz_abs % 3600) / 60;
        break :blk try std.fmt.allocPrint(allocator, "Unknown <unknown@unknown> {d} {c}{d:0>2}{d:0>2}", .{ timestamp, tz_sign, tz_hours, tz_minutes });
    };
    defer allocator.free(author_info);
    const committer_info = helpers.getCommitterString(allocator) catch blk: {
        const timestamp = std.time.timestamp();
        const tz_offset = helpers.getTimezoneOffset(timestamp);
        const tz_sign: u8 = if (tz_offset < 0) '-' else '+';
        const tz_abs: u32 = @intCast(if (tz_offset < 0) -tz_offset else tz_offset);
        const tz_hours = tz_abs / 3600;
        const tz_minutes = (tz_abs % 3600) / 60;
        break :blk try std.fmt.allocPrint(allocator, "Unknown <unknown@unknown> {d} {c}{d:0>2}{d:0>2}", .{ timestamp, tz_sign, tz_hours, tz_minutes });
    };
    defer allocator.free(committer_info);

    // helpers.Add sign-off line if requested
    if (signoff) {
        // helpers.Extract name and email from committer info (format: "Name <email> timestamp tz")
        const committer_name_email = blk: {
            // helpers.Find the last '>' to get "Name <email>"
            if (std.mem.lastIndexOf(u8, committer_info, ">")) |gt_pos| {
                break :blk committer_info[0..gt_pos + 1];
            }
            break :blk committer_info;
        };
        const signoff_line = try std.fmt.allocPrint(allocator, "Signed-off-by: {s}", .{committer_name_email});
        defer allocator.free(signoff_line);
        // helpers.Only add if not already present
        if (message != null and std.mem.indexOf(u8, message.?, signoff_line) == null) {
            const old_msg = message.?;
            const trimmed_msg = std.mem.trimRight(u8, old_msg, "\n");
            // helpers.Check if message already ends with a trailer (like another Signed-off-by)
            const has_trailer = blk: {
                // helpers.Look at the last line of the trimmed message
                if (std.mem.lastIndexOf(u8, trimmed_msg, "\n")) |last_nl| {
                    const last_line = trimmed_msg[last_nl + 1..];
                    break :blk std.mem.indexOf(u8, last_line, ": ") != null;
                }
                break :blk false;
            };
            if (has_trailer) {
                message = try std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{trimmed_msg, signoff_line});
            } else {
                message = try std.fmt.allocPrint(allocator, "{s}\n\n{s}\n", .{trimmed_msg, signoff_line});
            }
        }
    }

    // Check for ignored hooks (non-executable hook files)
    if (!no_verify) {
        const hook_path = std.fmt.allocPrint(allocator, "{s}/hooks/pre-commit", .{git_path}) catch null;
        defer if (hook_path) |p| allocator.free(p);
        if (hook_path) |hp| {
            if (std.fs.cwd().statFile(hp)) |stat| {
                // File exists - check if executable
                const mode = stat.mode;
                const is_exec = (mode & 0o111) != 0;
                if (!is_exec) {
                    // Check advice.ignoredHook config
                    var show_warning = true;
                    const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch null;
                    defer if (config_path) |cp| allocator.free(cp);
                    if (config_path) |cp| {
                        if (platform_impl.fs.readFile(allocator, cp)) |cfg| {
                            defer allocator.free(cfg);
                            if (std.mem.indexOf(u8, cfg, "ignoredHook = false") != null) {
                                show_warning = false;
                            }
                        } else |_| {}
                    }
                    if (show_warning) {
                        const hint1 = std.fmt.allocPrint(allocator, "hint: The '{s}' hook was ignored because it's not set as executable.\n", .{hp}) catch null;
                        defer if (hint1) |h| allocator.free(h);
                        if (hint1) |h| platform_impl.writeStderr(h) catch {};
                        platform_impl.writeStderr("hint: You can disable this warning with `git config advice.ignoredHook false`.\n") catch {};
                    }
                }
            } else |_| {}
        }
    }

    // Check i18n.commitencoding config
    const commit_encoding: ?[]const u8 = blk_enc: {
        if (helpers.getConfigOverride("i18n.commitencoding")) |enc| {
            // Only add encoding header for non-UTF-8 encodings
            if (!std.ascii.eqlIgnoreCase(enc, "UTF-8") and !std.ascii.eqlIgnoreCase(enc, "utf8")) {
                break :blk_enc enc;
            }
        }
        break :blk_enc null;
    };

    const commit_object = try objects.createCommitObjectWithEncoding(
        tree_hash,
        parent_hashes.items,
        author_info,
        committer_info,
        message.?,
        commit_encoding,
        allocator,
    );
    defer commit_object.deinit(allocator);

    const commit_hash = try commit_object.store(git_path, platform_impl, allocator);
    defer allocator.free(commit_hash);

    // helpers.Update current branch
    const current_branch = try refs.getCurrentBranch(git_path, platform_impl, allocator);
    defer allocator.free(current_branch);
    
    // helpers.Get old hash before updating
    const old_commit_hash = refs.resolveRef(git_path, current_branch, platform_impl, allocator) catch null;
    defer if (old_commit_hash) |h| allocator.free(h);
    
    try refs.updateRef(git_path, current_branch, commit_hash, platform_impl, allocator);
    
    // helpers.Write reflog entries for both the branch and helpers.HEAD
    {
        const zero_h = "0000000000000000000000000000000000000000";
        const old_h = old_commit_hash orelse zero_h;
        
        // helpers.Determine reflog message
        const reflog_msg = if (amend)
            "commit (amend): "
        else if (old_commit_hash == null)
            "commit (initial): "
        else if (parent_hashes.items.len > 1)
            "commit (merge): "
        else
            "commit: ";
        
        const full_reflog_msg = try std.fmt.allocPrint(allocator, "{s}{s}", .{ reflog_msg, std.mem.trim(u8, message orelse "", " \t\n\r") });
        defer allocator.free(full_reflog_msg);
        
        // helpers.Write reflog for branch
        helpers.writeReflogEntry(git_path, current_branch, old_h, commit_hash, full_reflog_msg, allocator, platform_impl) catch {};
        // helpers.Write reflog for helpers.HEAD
        helpers.writeReflogEntry(git_path, "HEAD", old_h, commit_hash, full_reflog_msg, allocator, platform_impl) catch {};
    }

    // helpers.Clean up merge state files after successful commit
    {
        const mh_path = try std.fmt.allocPrint(allocator, "{s}/MERGE_HEAD", .{git_path});
        defer allocator.free(mh_path);
        std.fs.cwd().deleteFile(mh_path) catch {};
        const mm_path = try std.fmt.allocPrint(allocator, "{s}/MERGE_MSG", .{git_path});
        defer allocator.free(mm_path);
        std.fs.cwd().deleteFile(mm_path) catch {};
        const mmode_path = try std.fmt.allocPrint(allocator, "{s}/MERGE_MODE", .{git_path});
        defer allocator.free(mmode_path);
        std.fs.cwd().deleteFile(mmode_path) catch {};
    }
    
    // helpers.After a successful commit, the index should remain but be consistent with the new commit
    // helpers.We don't clear the index, but we save it to ensure it's properly persisted
    try index.save(git_path, platform_impl);

    // helpers.Output success message (unless --quiet was specified)
    if (!quiet) {
        const short_hash = commit_hash[0..7];
        // helpers.Check if this is the first commit (root commit)
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
        // Show author if different from committer (like git does)
        {
            // Extract name <email> portion (before timestamp)
            const author_ne = extractNameEmail(author_info);
            const committer_ne = extractNameEmail(committer_info);
            if (!std.mem.eql(u8, author_ne, committer_ne)) {
                const author_line = try std.fmt.allocPrint(allocator, " Author: {s}\n", .{author_ne});
                defer allocator.free(author_line);
                try platform_impl.writeStdout(author_line);
            }
        }
        
        // helpers.Add diffstat summary: count files changed
        // helpers.Compare current tree with parent tree to get stats
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
            
            if (commit_tree_h) |tree_h| {
                if (is_root) {
                    // Root commit: all files are new
                    const file_count = index.entries.items.len;
                    if (file_count > 0) {
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
                } else if (commit_parent_h) |parent_h| {
                    // Non-root commit: diff current tree vs parent tree
                    const parent_obj = objects.GitObject.load(parent_h, git_path, platform_impl, allocator) catch null;
                    if (parent_obj) |po| {
                        defer po.deinit(allocator);
                        var parent_tree_h: ?[]const u8 = null;
                        var plines = std.mem.splitSequence(u8, po.data, "\n");
                        while (plines.next()) |pline| {
                            if (pline.len == 0) break;
                            if (std.mem.startsWith(u8, pline, "tree ")) {
                                parent_tree_h = pline["tree ".len..];
                                break;
                            }
                        }
                        if (parent_tree_h) |pt_h| {
                            const stat_line = helpers.computeDiffStatSummary(allocator, pt_h, tree_h, git_path, platform_impl) catch null;
                            if (stat_line) |sl| {
                                defer allocator.free(sl);
                                if (sl.len > 0) {
                                    try platform_impl.writeStdout(sl);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

