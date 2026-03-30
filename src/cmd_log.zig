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
    var exclude_refs = std.array_list.Managed([]const u8).init(allocator);
    defer exclude_refs.deinit();
    var include_refs = std.array_list.Managed([]const u8).init(allocator);
    defer include_refs.deinit();
    var walk_reflog = false;
    var pretty_alias: ?[]const u8 = null; // unresolved pretty.<name> alias
    var author_filters = std.array_list.Managed([]const u8).init(allocator);
    defer author_filters.deinit();
    var committer_filters = std.array_list.Managed([]const u8).init(allocator);
    defer committer_filters.deinit();
    var grep_filters = std.array_list.Managed([]const u8).init(allocator);
    defer grep_filters.deinit();
    var all_match = false;
    var fixed_strings = false;
    var grep_reflog = false;
    var invert_grep = false;
    var output_encoding: ?[]const u8 = null;

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
            // Could be a pretty.<name> alias from config — resolve after git_path is known
            const fmt_val = arg["--pretty=".len..];
            if (fmt_val.len > 0) {
                pretty_alias = fmt_val;
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
        } else if (std.mem.startsWith(u8, arg, "--author=")) {
            try author_filters.append(arg["--author=".len..]);
        } else if (std.mem.eql(u8, arg, "--author")) {
            if (args.next()) |val| try author_filters.append(val);
        } else if (std.mem.startsWith(u8, arg, "--committer=")) {
            try committer_filters.append(arg["--committer=".len..]);
        } else if (std.mem.eql(u8, arg, "--committer")) {
            if (args.next()) |val| try committer_filters.append(val);
        } else if (std.mem.startsWith(u8, arg, "--grep=")) {
            try grep_filters.append(arg["--grep=".len..]);
        } else if (std.mem.eql(u8, arg, "--grep")) {
            if (args.next()) |val| try grep_filters.append(val);
        } else if (std.mem.eql(u8, arg, "--all-match")) {
            all_match = true;
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings")) {
            fixed_strings = true;
        } else if (std.mem.eql(u8, arg, "--grep-reflog")) {
            grep_reflog = true;
        } else if (std.mem.eql(u8, arg, "--invert-grep")) {
            invert_grep = true;
        } else if (std.mem.startsWith(u8, arg, "--encoding=")) {
            output_encoding = arg["--encoding=".len..];
        } else if (std.mem.eql(u8, arg, "--")) {
            // Everything after -- is a path, ignore for now
            break;
        } else if (std.mem.startsWith(u8, arg, "^") and arg.len > 1) {
            // ^ref means exclude commits reachable from ref
            try exclude_refs.append(arg[1..]);
        } else if (std.mem.indexOf(u8, arg, "..")) |dot_pos| {
            // A..B means ^A B
            if (dot_pos > 0) try exclude_refs.append(arg[0..dot_pos]);
            if (dot_pos + 2 < arg.len) committish = arg[dot_pos + 2..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // helpers.This is likely a committish (commit hash, branch name, etc.)
            if (committish == null) {
                committish = arg;
            } else {
                // Multiple include refs - use the last one as committish
                try include_refs.append(committish.?);
                committish = arg;
            }
        }
    }

    // --grep-reflog can only be used with -g
    if (grep_reflog and !walk_reflog) {
        try platform_impl.writeStderr("fatal: --grep-reflog can only be used under -g\n");
        std.process.exit(1);
    }

    // helpers.Find .git directory
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Resolve pretty.<alias> from config if needed
    if (pretty_alias) |alias_name| {
        const config_key = std.fmt.allocPrint(allocator, "pretty.{s}", .{alias_name}) catch null;
        const resolved = if (config_key) |key| helpers.getConfigValueByKey(git_path, key, allocator) else null;
        if (config_key) |key| allocator.free(key);
        if (resolved) |value| {
            // Resolved alias — parse the value
            if (std.mem.startsWith(u8, value, "format:")) {
                format_string = value["format:".len..];
                format_is_separator = true;
            } else if (std.mem.startsWith(u8, value, "tformat:")) {
                format_string = value["tformat:".len..];
                format_is_separator = false;
            } else if (std.mem.eql(u8, value, "oneline") or std.mem.eql(u8, value, "short")) {
                oneline = true;
            } else if (std.mem.eql(u8, value, "medium") or std.mem.eql(u8, value, "full") or std.mem.eql(u8, value, "fuller") or std.mem.eql(u8, value, "email") or std.mem.eql(u8, value, "raw") or std.mem.eql(u8, value, "reference") or std.mem.eql(u8, value, "mboxrd")) {
                // Named builtin format from alias
            } else {
                // Treat as tformat string
                format_string = value;
                format_is_separator = false;
            }
        } else {
            // Not a known alias — treat as format string directly (git compat)
            format_string = alias_name;
            format_is_separator = false;
        }
    }

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

    // Build excluded commit set from ^ref arguments
    var excluded = std.StringHashMap(void).init(allocator);
    defer {
        var exc_it = excluded.iterator();
        while (exc_it.next()) |entry| allocator.free(entry.key_ptr.*);
        excluded.deinit();
    }
    for (exclude_refs.items) |exc_ref| {
        const exc_hash = helpers.resolveCommittish(git_path, exc_ref, platform_impl, allocator) catch continue;
        defer allocator.free(exc_hash);
        // Walk excluded ref's ancestors
        var exc_queue = std.array_list.Managed([]const u8).init(allocator);
        defer exc_queue.deinit();
        try exc_queue.append(try allocator.dupe(u8, exc_hash));
        while (exc_queue.items.len > 0) {
            const h = exc_queue.pop();
            if (excluded.contains(h)) { allocator.free(h); continue; }
            try excluded.put(h, {});
            // Get parents
            const obj = objects.GitObject.load(h, git_path, platform_impl, allocator) catch continue;
            defer obj.deinit(allocator);
            var lit = std.mem.splitSequence(u8, obj.data, "\n");
            while (lit.next()) |line| {
                if (line.len == 0) break;
                if (std.mem.startsWith(u8, line, "parent ")) {
                    try exc_queue.append(try allocator.dupe(u8, line["parent ".len..]));
                }
            }
        }
    }

    // Seed the queue with the start commit (and any additional include refs)
    const start_ts = helpers.getCommitTimestamp(start_commit, git_path, platform_impl, allocator);
    try queue.append(.{ .hash = try allocator.dupe(u8, start_commit), .timestamp = start_ts });
    try visited.put(try allocator.dupe(u8, start_commit), {});
    // Add additional include refs
    for (include_refs.items) |inc_ref| {
        const inc_hash = helpers.resolveCommittish(git_path, inc_ref, platform_impl, allocator) catch continue;
        if (!visited.contains(inc_hash)) {
            const inc_ts = helpers.getCommitTimestamp(inc_hash, git_path, platform_impl, allocator);
            try queue.append(.{ .hash = try allocator.dupe(u8, inc_hash), .timestamp = inc_ts });
            try visited.put(try allocator.dupe(u8, inc_hash), {});
        }
        allocator.free(inc_hash);
    }

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

        // Skip excluded commits (from ^ref arguments)
        if (excluded.contains(cur_hash)) continue;

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

        // Re-encode message if --encoding is specified and differs from commit encoding
        var reencoded_msg: ?[]u8 = null;
        defer if (reencoded_msg) |rm| allocator.free(rm);
        if (output_encoding) |out_enc| {
            const commit_enc = blk: {
                const enc_field = helpers.extractHeaderField(commit_data, "encoding");
                if (enc_field.len > 0) break :blk enc_field;
                break :blk "utf-8"; // default
            };
            // Check if we need to convert
            const out_is_utf8 = std.ascii.eqlIgnoreCase(out_enc, "utf8") or std.ascii.eqlIgnoreCase(out_enc, "utf-8");
            const src_is_latin1 = std.ascii.eqlIgnoreCase(commit_enc, "ISO-8859-1") or std.ascii.eqlIgnoreCase(commit_enc, "latin1") or std.ascii.eqlIgnoreCase(commit_enc, "latin-1");
            const src_is_utf8 = std.ascii.eqlIgnoreCase(commit_enc, "utf8") or std.ascii.eqlIgnoreCase(commit_enc, "utf-8");
            const out_is_latin1 = std.ascii.eqlIgnoreCase(out_enc, "ISO-8859-1") or std.ascii.eqlIgnoreCase(out_enc, "latin1") or std.ascii.eqlIgnoreCase(out_enc, "latin-1");
            if (out_is_utf8 and src_is_latin1) {
                // Convert ISO-8859-1 to UTF-8
                var buf = std.array_list.Managed(u8).init(allocator);
                for (message.items) |byte| {
                    if (byte < 0x80) {
                        buf.append(byte) catch break;
                    } else {
                        buf.append(0xC0 | (byte >> 6)) catch break;
                        buf.append(0x80 | (byte & 0x3F)) catch break;
                    }
                }
                reencoded_msg = buf.toOwnedSlice() catch null;
            } else if (out_is_latin1 and src_is_utf8) {
                // Convert UTF-8 to ISO-8859-1
                var buf = std.array_list.Managed(u8).init(allocator);
                var i: usize = 0;
                const src = message.items;
                while (i < src.len) {
                    if (src[i] < 0x80) {
                        buf.append(src[i]) catch break;
                        i += 1;
                    } else if (i + 1 < src.len and (src[i] & 0xE0) == 0xC0) {
                        const cp = (@as(u16, src[i] & 0x1F) << 6) | @as(u16, src[i + 1] & 0x3F);
                        if (cp <= 0xFF) {
                            buf.append(@intCast(cp)) catch break;
                        } else {
                            buf.append('?') catch break;
                        }
                        i += 2;
                    } else {
                        buf.append('?') catch break;
                        i += 1;
                    }
                }
                reencoded_msg = buf.toOwnedSlice() catch null;
            }
        }

        // Apply commit filters (--author, --committer, --grep)
        const msg_text = if (reencoded_msg) |rm| rm else message.items;
        const committer_line = helpers.extractHeaderField(commit_data, "committer");
        const should_show = filterCommit: {
            const has_author_filter = author_filters.items.len > 0;
            const has_committer_filter = committer_filters.items.len > 0;
            const has_grep_filter = grep_filters.items.len > 0;

            if (!has_author_filter and !has_committer_filter and !has_grep_filter) break :filterCommit true;

            if (all_match) {
                // --all-match: ALL grep filters must match, AND author/committer must match
                // But multiple --author still uses union (any author matches)
                if (has_author_filter) {
                    var any_author = false;
                    for (author_filters.items) |af| {
                        if (matchesFilter(author_line orelse "", af, fixed_strings)) {
                            any_author = true;
                            break;
                        }
                    }
                    if (!any_author) break :filterCommit false;
                }
                if (has_committer_filter) {
                    var any_committer = false;
                    for (committer_filters.items) |cf| {
                        if (matchesFilter(committer_line, cf, fixed_strings)) {
                            any_committer = true;
                            break;
                        }
                    }
                    if (!any_committer) break :filterCommit false;
                }
                if (has_grep_filter) {
                    for (grep_filters.items) |gf| {
                        if (!matchesFilter(msg_text, gf, fixed_strings)) break :filterCommit false;
                    }
                }
                break :filterCommit true;
            } else {
                // Default: --grep filters use union, --author uses union
                // But --grep + --author uses intersection (both must match)
                var grep_match = !has_grep_filter;
                var author_match = !has_author_filter;
                var committer_match = !has_committer_filter;

                if (has_grep_filter) {
                    for (grep_filters.items) |gf| {
                        if (matchesFilter(msg_text, gf, fixed_strings)) {
                            grep_match = true;
                            break;
                        }
                    }
                }
                if (has_author_filter) {
                    for (author_filters.items) |af| {
                        if (matchesFilter(author_line orelse "", af, fixed_strings)) {
                            author_match = true;
                            break;
                        }
                    }
                }
                if (has_committer_filter) {
                    for (committer_filters.items) |cf| {
                        if (matchesFilter(committer_line, cf, fixed_strings)) {
                            committer_match = true;
                            break;
                        }
                    }
                }
                break :filterCommit grep_match and author_match and committer_match;
            }
        };

        if (invert_grep) {
            if (should_show) {
                // Add parents to queue and continue without displaying
                for (parent_hashes.items) |ph| {
                    if (!visited.contains(ph)) {
                        const ts = helpers.getCommitTimestamp(ph, git_path, platform_impl, allocator);
                        try queue.append(.{ .hash = try allocator.dupe(u8, ph), .timestamp = ts });
                        try visited.put(try allocator.dupe(u8, ph), {});
                    }
                }
                continue;
            }
        } else {
            if (!should_show) {
                // Add parents to queue and continue without displaying
                for (parent_hashes.items) |ph| {
                    if (!visited.contains(ph)) {
                        const ts = helpers.getCommitTimestamp(ph, git_path, platform_impl, allocator);
                        try queue.append(.{ .hash = try allocator.dupe(u8, ph), .timestamp = ts });
                        try visited.put(try allocator.dupe(u8, ph), {});
                    }
                }
                continue;
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

            // Display notes if any

            if (displayNote(git_path, cur_hash, allocator, platform_impl)) |note_content| {
                defer allocator.free(note_content);
                try platform_impl.writeStdout("Notes:\n");
                const trimmed_note = std.mem.trimRight(u8, note_content, "\n");
                var note_iter = std.mem.splitScalar(u8, trimmed_note, '\n');
                while (note_iter.next()) |nline| {
                    const indented_note = try std.fmt.allocPrint(allocator, "    {s}\n", .{nline});
                    defer allocator.free(indented_note);
                    try platform_impl.writeStdout(indented_note);
                }
                try platform_impl.writeStdout("\n");
            } else |_| {}
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

fn getNotesRef(git_path: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) []const u8 {
    // Check GIT_NOTES_REF env var
    if (std.process.getEnvVarOwned(allocator, "GIT_NOTES_REF")) |env_val| {
        return env_val;
    } else |_| {}

    // Check core.notesRef config
    const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch return allocator.dupe(u8, "refs/notes/commits") catch "refs/notes/commits";
    defer allocator.free(config_path);
    if (platform_impl.fs.readFile(allocator, config_path)) |config_content| {
        defer allocator.free(config_content);
        var line_iter = std.mem.splitScalar(u8, config_content, '\n');
        var in_core = false;
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len > 0 and trimmed[0] == '[') {
                in_core = std.ascii.eqlIgnoreCase(std.mem.trim(u8, trimmed[1 .. trimmed.len - @as(usize, if (trimmed[trimmed.len - 1] == ']') 1 else 0)], " \t"), "core");
            } else if (in_core) {
                if (std.mem.indexOf(u8, trimmed, "=")) |eq| {
                    const key = std.mem.trim(u8, trimmed[0..eq], " \t");
                    if (std.ascii.eqlIgnoreCase(key, "notesRef")) {
                        const val = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
                        return allocator.dupe(u8, val) catch "refs/notes/commits";
                    }
                }
            }
        }
    } else |_| {}

    return allocator.dupe(u8, "refs/notes/commits") catch "refs/notes/commits";
}

fn displayNote(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) ![]u8 {
    const notes_ref = getNotesRef(git_path, allocator, platform_impl);
    defer allocator.free(notes_ref);

    // Resolve notes ref to a commit hash
    const notes_commit = refs.resolveRef(git_path, notes_ref, platform_impl, allocator) catch return error.NotFound;
    defer allocator.free(notes_commit);

    // Try flat path first (full hash as filename)
    if (helpers.getTreeEntryHashFromCommit(git_path, notes_commit, commit_hash, allocator)) |blob_hash| {
        defer allocator.free(blob_hash);
        return helpers.readGitObjectContent(git_path, blob_hash, allocator) catch return error.NotFound;
    } else |_| {}

    // Try fan-out: first2/rest38
    if (commit_hash.len >= 3) {
        const fanout_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ commit_hash[0..2], commit_hash[2..] }) catch return error.NotFound;
        defer allocator.free(fanout_path);
        if (helpers.getTreeEntryHashFromCommit(git_path, notes_commit, fanout_path, allocator)) |blob_hash| {
            defer allocator.free(blob_hash);
            return helpers.readGitObjectContent(git_path, blob_hash, allocator) catch return error.NotFound;
        } else |_| {}
    }

    return error.NotFound;
}

/// Check if text matches a filter pattern (substring or fixed-string match)
fn matchesFilter(text: []const u8, pattern: []const u8, fixed: bool) bool {
    if (pattern.len == 0) return true;
    if (text.len == 0) return false;
    if (fixed) {
        return std.mem.indexOf(u8, text, pattern) != null;
    }
    // For non-fixed, do case-sensitive substring match (basic regex would be better but substring is the common case)
    // Check for simple regex patterns
    if (pattern.len > 0 and pattern[0] == '^') {
        // Anchored at start of line - check each line
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, pattern[1..])) return true;
        }
        return false;
    }
    if (pattern.len > 0 and pattern[pattern.len - 1] == '$') {
        // Anchored at end of line
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len >= pattern.len - 1 and std.mem.endsWith(u8, line, pattern[0 .. pattern.len - 1])) return true;
        }
        return false;
    }
    // Check for regex special chars: . * + ? [ ( | \
    // If pattern has special chars that require regex, for now treat as literal
    var has_regex = false;
    for (pattern) |c| {
        if (c == '.' or c == '*' or c == '+' or c == '?' or c == '[' or c == '(' or c == '|' or c == '\\') {
            has_regex = true;
            break;
        }
    }
    if (has_regex) {
        // Special case: " * " pattern (used in test) - treat as literal since -F flag should be used
        // For now, just do substring match ignoring regex
        // Try substring match of the literal pattern
        return std.mem.indexOf(u8, text, pattern) != null;
    }
    return std.mem.indexOf(u8, text, pattern) != null;
}
