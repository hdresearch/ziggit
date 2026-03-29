// Auto-generated from main_common.zig - cmd_log
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");

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

pub fn cmdLog(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("log: not supported in freestanding mode\n");
        return;
    }

    var oneline = false;
    var format_string: ?[]const u8 = null;
    var format_is_separator = false; // true for "format:", false for "tformat:" / "--format="
    var max_count: ?u32 = null;
    var committish: ?[]const u8 = null;
    var walk_reflog = false;
    
    // helpers.Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--oneline")) {
            oneline = true;
        } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--walk-reflogs")) {
            walk_reflog = true;
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            format_string = arg["--format=".len..]; 
        } else if (std.mem.startsWith(u8, arg, "--pretty=format:")) {
            format_string = arg["--pretty=format:".len..];
            format_is_separator = true;
        } else if (std.mem.startsWith(u8, arg, "--pretty=tformat:")) {
            format_string = arg["--pretty=tformat:".len..];
            format_is_separator = false;
        } else if (std.mem.eql(u8, arg, "--pretty=oneline") or std.mem.eql(u8, arg, "--pretty=short")) {
            oneline = true;
        } else if (std.mem.eql(u8, arg, "--pretty=medium") or std.mem.eql(u8, arg, "--pretty=full") or std.mem.eql(u8, arg, "--pretty=fuller") or std.mem.eql(u8, arg, "--pretty=email") or std.mem.eql(u8, arg, "--pretty=raw") or std.mem.eql(u8, arg, "--pretty=reference") or std.mem.eql(u8, arg, "--pretty=mboxrd")) {
            // Named formats - use default for now
        } else if (std.mem.startsWith(u8, arg, "--pretty=")) {
            // Custom format string without "format:" prefix - treat as tformat
            const fmt_val = arg["--pretty=".len..];
            if (fmt_val.len > 0) {
                format_string = fmt_val;
                format_is_separator = false;
            }
        } else if (std.mem.eql(u8, arg, "--first-parent")) {
            // first-parent flag - already the default behavior (we only follow first parent)
        } else if (std.mem.eql(u8, arg, "-S")) {
            // -S requires an argument
            try platform_impl.writeStderr("error: switch `S' requires a value\n");
            std.process.exit(1);
        } else if (std.mem.startsWith(u8, arg, "-S")) {
            // -Sstring - pickaxe search, ignore for now
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and std.ascii.isDigit(arg[1])) {
            // helpers.Parse -n format like -1, -5, etc.
            const count_str = arg[1..];
            max_count = std.fmt.parseInt(u32, count_str, 10) catch null;
        } else if (std.mem.eql(u8, arg, "-n")) {
            // helpers.Parse -n followed by number
            if (args.next()) |count_str| {
                max_count = std.fmt.parseInt(u32, count_str, 10) catch null;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // helpers.This is likely a committish (commit hash, branch name, etc.)
            committish = arg;
        }
    }

    // helpers.Find .git directory
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // helpers.Resolve starting commit
    var start_commit: []u8 = undefined;
    if (committish) |commit_ref| {
        // helpers.Try to resolve committish (branch, tag, or commit hash)
        start_commit = helpers.resolveCommittish(git_path, commit_ref, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: ambiguous argument '{s}': unknown revision or path not in the working tree.\n", .{commit_ref});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
    } else {
        // helpers.Get current helpers.HEAD commit
        const current_commit = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
        if (current_commit == null) {
            try platform_impl.writeStderr("fatal: your current branch does not have any commits yet\n");
            std.process.exit(128);
        }
        start_commit = current_commit.?;
    }
    defer allocator.free(start_commit);

    // Fast path for common case: log --format=%H -1 (just output helpers.HEAD commit hash)
    if (format_string != null and std.mem.eql(u8, format_string.?, "%H") and 
        (max_count == 1) and committish == null and !walk_reflog) {
        const output = try std.fmt.allocPrint(allocator, "{s}\n", .{start_commit});
        defer allocator.free(output);
        try platform_impl.writeStdout(output);
        return;
    }

    // Reflog walking mode (-g)
    if (walk_reflog) {
        // helpers.Determine which reflog to read
        const ref_name = committish orelse "HEAD";
        // helpers.Build reflog path - for branch names, check refs/heads/ path first (canonical location)
        var reflog_content: ?[]u8 = null;
        var reflog_path2: ?[]u8 = null;
        defer if (reflog_path2) |p2| allocator.free(p2);
        if (!std.mem.eql(u8, ref_name, "HEAD") and !std.mem.startsWith(u8, ref_name, "refs/")) {
            reflog_path2 = try std.fmt.allocPrint(allocator, "{s}/logs/refs/heads/{s}", .{ git_path, ref_name });
            reflog_content = platform_impl.fs.readFile(allocator, reflog_path2.?) catch null;
        }
        const reflog_path = try std.fmt.allocPrint(allocator, "{s}/logs/{s}", .{ git_path, ref_name });
        defer allocator.free(reflog_path);
        if (reflog_content == null) {
            reflog_content = platform_impl.fs.readFile(allocator, reflog_path) catch null;
        }
        if (reflog_content) |content| {
            defer allocator.free(content);
            // helpers.Parse reflog entries (newest first)
            var reflog_entries = std.array_list.Managed(helpers.ReflogEntry).init(allocator);
            defer {
                for (reflog_entries.items) |*e| {
                    allocator.free(e.old_hash);
                    allocator.free(e.new_hash);
                    allocator.free(e.who);
                    allocator.free(e.message);
                }
                reflog_entries.deinit();
            }
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                // Format: <old_hash> <new_hash> <who> <timestamp> <tz>\t<message>
                if (line.len < 82) continue; // minimum: 40 + 1 + 40 + 1 = 82
                const old_h = line[0..40];
                const new_h = line[41..81];
                // Rest after space is: "name <email> timestamp tz\tmessage"
                const rest = line[82..];
                var msg: []const u8 = "";
                var who: []const u8 = rest;
                if (std.mem.indexOf(u8, rest, "\t")) |tab_pos| {
                    who = rest[0..tab_pos];
                    msg = rest[tab_pos + 1 ..];
                }
                try reflog_entries.append(.{
                    .old_hash = try allocator.dupe(u8, old_h),
                    .new_hash = try allocator.dupe(u8, new_h),
                    .who = try allocator.dupe(u8, who),
                    .message = try allocator.dupe(u8, msg),
                });
            }
            // helpers.Walk in reverse (newest first)
            var count: u32 = 0;
            var entry_idx: usize = reflog_entries.items.len;
            while (entry_idx > 0 and (max_count == null or count < max_count.?)) {
                entry_idx -= 1;
                const entry = reflog_entries.items[entry_idx];
                const ref_for_selector = if (committish != null) ref_name else "HEAD";
                const selector = try std.fmt.allocPrint(allocator, "{s}@{{{d}}}", .{ ref_for_selector, reflog_entries.items.len - 1 - entry_idx });
                defer allocator.free(selector);
                if (format_string) |fmt| {
                    if (format_is_separator and count > 0) {
                        try platform_impl.writeStdout("\n");
                    }
                    try helpers.outputFormattedCommitWithReflog(fmt, entry.new_hash, selector, entry.message, entry.who, allocator, platform_impl);
                    if (!format_is_separator) {
                        try platform_impl.writeStdout("\n");
                    }
                } else if (oneline) {
                    const short_hash = if (entry.new_hash.len >= 7) entry.new_hash[0..7] else entry.new_hash;
                    const out_line = try std.fmt.allocPrint(allocator, "{s} {s}: {s}\n", .{ short_hash, selector, entry.message });
                    defer allocator.free(out_line);
                    try platform_impl.writeStdout(out_line);
                } else {
                    // helpers.Default format
                    const out_hdr = try std.fmt.allocPrint(allocator, "commit {s} ({s})\n", .{ entry.new_hash, selector });
                    defer allocator.free(out_hdr);
                    try platform_impl.writeStdout(out_hdr);
                    // helpers.Load commit for author/date/message
                    if (objects.GitObject.load(entry.new_hash, git_path, platform_impl, allocator) catch null) |commit_obj| {
                        defer commit_obj.deinit(allocator);
                        const cdata = commit_obj.data;
                        if (helpers.extractHeaderField(cdata, "author").len > 0) {
                            const al = helpers.extractHeaderField(cdata, "author");
                            const out_author = try std.fmt.allocPrint(allocator, "Reflog: {s} ({s})\nReflog message: {s}\nAuthor: {s}\n", .{ selector, helpers.getPersonName(al), entry.message, al });
                            defer allocator.free(out_author);
                            try platform_impl.writeStdout(out_author);
                        }
                        const cmsg = helpers.extractObjectMessage(cdata);
                        try platform_impl.writeStdout("\n");
                        var msg_iter = std.mem.splitScalar(u8, std.mem.trimRight(u8, cmsg, "\n"), '\n');
                        while (msg_iter.next()) |ml| {
                            if (ml.len == 0) {
                                try platform_impl.writeStdout("\n");
                            } else {
                                const indented = try std.fmt.allocPrint(allocator, "    {s}\n", .{ml});
                                defer allocator.free(indented);
                                try platform_impl.writeStdout(indented);
                            }
                        }
                        try platform_impl.writeStdout("\n");
                    }
                }
                count += 1;
            }
        }
        return;
    }
    
    // helpers.Walk the commit history using priority queue (sorted by committer date)
    const CommitQueueEntry = struct {
        hash: []const u8,
        timestamp: i64,
    };
    var queue = std.array_list.Managed(CommitQueueEntry).init(allocator);
    defer {
        for (queue.items) |entry| allocator.free(@constCast(entry.hash));
        queue.deinit();
    }

    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var iterator = visited.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        visited.deinit();
    }

    // Seed the queue with the start commit
    const start_ts = helpers.getCommitTimestamp(start_commit, git_path, platform_impl, allocator);
    try queue.append(.{ .hash = try allocator.dupe(u8, start_commit), .timestamp = start_ts });
    try visited.put(try allocator.dupe(u8, start_commit), {});

    var count: u32 = 0;
    while (queue.items.len > 0 and (max_count == null or count < max_count.?)) {
        // helpers.Find the entry with the highest timestamp (most recent commit)
        var best_idx: usize = 0;
        for (queue.items, 0..) |entry, i| {
            if (entry.timestamp > queue.items[best_idx].timestamp) {
                best_idx = i;
            }
        }
        const current = queue.orderedRemove(best_idx);
        const cur_hash = current.hash;
        defer allocator.free(@constCast(cur_hash));

        // helpers.Load commit object
        const commit_object = objects.GitObject.load(cur_hash, git_path, platform_impl, allocator) catch |err| switch (err) {
            error.ObjectNotFound => {
                const msg = try std.fmt.allocPrint(allocator, "fatal: bad object {s}\n", .{cur_hash});
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

        // helpers.Parse commit data
        const commit_data = commit_object.data;
        
        // helpers.Extract commit message and author
        var lines_it = std.mem.splitSequence(u8, commit_data, "\n");
        var parent_hashes = std.array_list.Managed([]const u8).init(allocator);
        defer parent_hashes.deinit();
        var author_line: ?[]const u8 = null;
        var empty_line_found = false;
        var message = std.array_list.Managed(u8).init(allocator);
        defer message.deinit();

        while (lines_it.next()) |line| {
            if (empty_line_found) {
                try message.appendSlice(line);
                try message.append('\n');
            } else if (line.len == 0) {
                empty_line_found = true;
            } else if (std.mem.startsWith(u8, line, "parent ")) {
                try parent_hashes.append(line["parent ".len..]);
            } else if (std.mem.startsWith(u8, line, "author ")) {
                author_line = line["author ".len..];
            }
        }

        // Display commit based on format
        if (format_string) |fmt| {
            if (format_is_separator and count > 0) {
                try platform_impl.writeStdout("\n");
            }
            try helpers.outputFormattedCommit(fmt, cur_hash, allocator, platform_impl);
            if (!format_is_separator) {
                try platform_impl.writeStdout("\n");
            }
        } else if (oneline) {
            const short_hash = cur_hash[0..@min(7, cur_hash.len)];
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
            const commit_header = try std.fmt.allocPrint(allocator, "commit {s}\n", .{cur_hash});
            defer allocator.free(commit_header);
            try platform_impl.writeStdout(commit_header);

            // helpers.Show helpers.Merge line for merge commits (commits with 2+ parents)
            if (parent_hashes.items.len > 1) {
                var merge_line = std.array_list.Managed(u8).init(allocator);
                defer merge_line.deinit();
                try merge_line.appendSlice("Merge:");
                for (parent_hashes.items) |ph| {
                    try merge_line.appendSlice(" ");
                    try merge_line.appendSlice(ph[0..@min(7, ph.len)]);
                }
                try merge_line.appendSlice("\n");
                try platform_impl.writeStdout(merge_line.items);
            }

            if (author_line) |author| {
                // helpers.Parse author into name <email> and date
                const a_name = helpers.parseAuthorName(author);
                const a_email = helpers.parseAuthorEmail(author);
                const author_output = try std.fmt.allocPrint(allocator, "Author: {s} <{s}>\n", .{ a_name, a_email });
                defer allocator.free(author_output);
                try platform_impl.writeStdout(author_output);
                
                // Date line
                const date_str = helpers.parseAuthorDateGitFmt(author, allocator);
                defer if (date_str) |d| allocator.free(d);
                if (date_str) |d| {
                    const date_output = try std.fmt.allocPrint(allocator, "Date:   {s}\n", .{d});
                    defer allocator.free(date_output);
                    try platform_impl.writeStdout(date_output);
                }
            }

            try platform_impl.writeStdout("\n");
            // helpers.Output message with 4-space indent, handling multi-line messages
            const trimmed_msg = std.mem.trimRight(u8, message.items, "\n");
            var msg_iter = std.mem.splitScalar(u8, trimmed_msg, '\n');
            while (msg_iter.next()) |line| {
                if (line.len == 0) {
                    try platform_impl.writeStdout("\n");
                } else {
                    const indented = try std.fmt.allocPrint(allocator, "    {s}\n", .{line});
                    defer allocator.free(indented);
                    try platform_impl.writeStdout(indented);
                }
            }
            try platform_impl.writeStdout("\n");
        }

        count += 1;

        // helpers.Add all parents to the queue
        for (parent_hashes.items) |parent| {
            if (!visited.contains(parent)) {
                try visited.put(try allocator.dupe(u8, parent), {});
                const pts = helpers.getCommitTimestamp(parent, git_path, platform_impl, allocator);
                try queue.append(.{ .hash = try allocator.dupe(u8, parent), .timestamp = pts });
            }
        }
    }
}
