// Auto-generated from main_common.zig - cmd_commit
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");

const helpers = @import("git_helpers.zig");
const cmd_reflog = @import("cmd_reflog.zig");
const cmd_add = @import("cmd_add.zig");
const hooks = @import("git/hooks.zig");
const succinct_mod = @import("succinct.zig");

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

/// Strip trailing whitespace from each line, strip leading/trailing empty lines
fn cleanupWhitespace(allocator: std.mem.Allocator, msg: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    var lines = std.mem.splitScalar(u8, msg, '\n');
    // Collect all lines, trimming trailing whitespace
    var all_lines = std.array_list.Managed([]const u8).init(allocator);
    defer all_lines.deinit();
    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        try all_lines.append(trimmed);
    }
    // Strip leading empty lines
    var start: usize = 0;
    while (start < all_lines.items.len and all_lines.items[start].len == 0) {
        start += 1;
    }
    // Strip trailing empty lines
    var end: usize = all_lines.items.len;
    while (end > start and all_lines.items[end - 1].len == 0) {
        end -= 1;
    }
    // Build result
    var first = true;
    for (all_lines.items[start..end]) |line| {
        if (!first) try result.append('\n');
        first = false;
        try result.appendSlice(line);
    }
    try result.append('\n');
    return try allocator.dupe(u8, result.items);
}

/// Strip comment lines (starting with #), trailing whitespace, leading/trailing empty lines
fn cleanupStripWithChar(allocator: std.mem.Allocator, msg: []const u8, comment_char: u8) ![]const u8 {
    var all_lines = std.array_list.Managed([]const u8).init(allocator);
    defer all_lines.deinit();
    var lines = std.mem.splitScalar(u8, msg, '\n');
    while (lines.next()) |line| {
        // Strip lines starting with comment char
        if (line.len > 0 and line[0] == comment_char) continue;
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        try all_lines.append(trimmed);
    }
    // Strip leading empty lines
    var start: usize = 0;
    while (start < all_lines.items.len and all_lines.items[start].len == 0) {
        start += 1;
    }
    // Strip trailing empty lines
    var end: usize = all_lines.items.len;
    while (end > start and all_lines.items[end - 1].len == 0) {
        end -= 1;
    }
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    var first = true;
    for (all_lines.items[start..end]) |line| {
        if (!first) try result.append('\n');
        first = false;
        try result.appendSlice(line);
    }
    try result.append('\n');
    return try allocator.dupe(u8, result.items);
}

/// Strip everything below scissors line (only when it starts at column 0), then apply whitespace cleanup (not comment stripping)
fn cleanupScissors(allocator: std.mem.Allocator, msg: []const u8, comment_char: u8) ![]const u8 {
    // Build the scissors marker: "{comment_char} ------------------------ >8 ------------------------"
    var scissors_buf: [64]u8 = undefined;
    const scissors_marker = blk: {
        var i: usize = 0;
        scissors_buf[i] = comment_char;
        i += 1;
        const rest = " ------------------------ >8 ------------------------";
        @memcpy(scissors_buf[i .. i + rest.len], rest);
        i += rest.len;
        break :blk scissors_buf[0..i];
    };
    // Find scissors line that starts at column 0 (beginning of line)
    var truncated = msg;
    var search_pos: usize = 0;
    while (search_pos < msg.len) {
        if (std.mem.indexOfPos(u8, msg, search_pos, scissors_marker)) |pos| {
            // Check if this is at the start of a line
            if (pos == 0 or msg[pos - 1] == '\n') {
                truncated = msg[0..if (pos > 0 and msg[pos - 1] == '\n') pos else pos];
                break;
            }
            search_pos = pos + 1;
        } else break;
    }
    return cleanupWhitespace(allocator, truncated);
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
    var allow_empty_message = false;
    var amend = false;
    var add_all = false;
    var quiet = false;
    var signoff = false;
    var no_verify = false;
    var no_edit = false;
    var force_edit = false;
    var status_option: enum { default, yes, no } = .default;
    var trailers = std.array_list.Managed([]const u8).init(allocator);
    defer trailers.deinit();
    var cleanup_mode: enum { default, verbatim, whitespace, strip, scissors } = .default;
    var cleanup_explicit = false;
    var author_override: ?[]const u8 = null;
    var msg_source: enum { none, m_flag, f_flag, c_flag } = .none;
    var template_message: ?[]const u8 = null;
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
        } else if (std.mem.startsWith(u8, arg, "--cleanup=")) {
            cleanup_explicit = true;
            const mode_str = arg["--cleanup=".len..];
            if (std.mem.eql(u8, mode_str, "verbatim")) {
                cleanup_mode = .verbatim;
            } else if (std.mem.eql(u8, mode_str, "whitespace")) {
                cleanup_mode = .whitespace;
            } else if (std.mem.eql(u8, mode_str, "strip")) {
                cleanup_mode = .strip;
            } else if (std.mem.eql(u8, mode_str, "scissors")) {
                cleanup_mode = .scissors;
            } else if (std.mem.eql(u8, mode_str, "default")) {
                cleanup_mode = .default;
            } else {
                const err_msg = try std.fmt.allocPrint(allocator, "fatal: Invalid cleanup mode {s}\n", .{mode_str});
                defer allocator.free(err_msg);
                try platform_impl.writeStderr(err_msg);
                std.process.exit(128);
            }
        } else if (std.mem.eql(u8, arg, "--no-verify") or std.mem.eql(u8, arg, "-n")) {
            no_verify = true;
        } else if (std.mem.eql(u8, arg, "--signoff") or std.mem.eql(u8, arg, "-s")) {
            signoff = true;
        } else if (std.mem.eql(u8, arg, "--edit") or std.mem.eql(u8, arg, "-e")) {
            force_edit = true;
        } else if (std.mem.eql(u8, arg, "--no-edit")) {
            no_edit = true;
        } else if (std.mem.eql(u8, arg, "--trailer")) {
            if (args.next()) |trailer_val| {
                try trailers.append(trailer_val);
            }
        } else if (std.mem.startsWith(u8, arg, "--trailer=")) {
            try trailers.append(arg["--trailer=".len..]);
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
            allow_empty_message = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            seen_dashdash = true;
            while (args.next()) |farg| try commit_files.append(farg);
            break;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--template")) {
            // Template file — read it as the initial content for editor (not same as -F)
            const template_path = args.next() orelse {
                try platform_impl.writeStderr("error: option '-t' requires a value\n");
                std.process.exit(129);
            };
            template_message = platform_impl.fs.readFile(allocator, template_path) catch {
                const err_msg = try std.fmt.allocPrint(allocator, "fatal: could not read file '{s}'\n", .{template_path});
                defer allocator.free(err_msg);
                try platform_impl.writeStderr(err_msg);
                std.process.exit(128);
            };
        } else if (std.mem.startsWith(u8, arg, "--template=")) {
            const template_path = arg["--template=".len..];
            template_message = platform_impl.fs.readFile(allocator, template_path) catch {
                const err_msg = try std.fmt.allocPrint(allocator, "fatal: could not read file '{s}'\n", .{template_path});
                defer allocator.free(err_msg);
                try platform_impl.writeStderr(err_msg);
                std.process.exit(128);
            };
        } else if (std.mem.eql(u8, arg, "--status")) {
            status_option = .yes;
        } else if (std.mem.eql(u8, arg, "--no-status")) {
            status_option = .no;
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

    // Read commit.cleanup config if no explicit --cleanup was given
    if (!cleanup_explicit) {
        if (helpers.getConfigValueByKey(git_path, "commit.cleanup", allocator)) |cleanup_cfg| {
            defer allocator.free(cleanup_cfg);
            if (std.ascii.eqlIgnoreCase(cleanup_cfg, "verbatim")) {
                cleanup_mode = .verbatim;
            } else if (std.ascii.eqlIgnoreCase(cleanup_cfg, "whitespace")) {
                cleanup_mode = .whitespace;
            } else if (std.ascii.eqlIgnoreCase(cleanup_cfg, "strip")) {
                cleanup_mode = .strip;
            } else if (std.ascii.eqlIgnoreCase(cleanup_cfg, "scissors")) {
                cleanup_mode = .scissors;
            }
        }
    }

    // Determine if we need to launch an editor
    // -t/--template sets initial content for editor but still requires editor
    const need_editor = (message == null and msg_source == .none) or force_edit or template_message != null;
    if (need_editor and !no_edit) {
        // Write COMMIT_EDITMSG and launch editor
        const editmsg_path = try std.fmt.allocPrint(allocator, "{s}/COMMIT_EDITMSG", .{git_path});
        defer allocator.free(editmsg_path);

        // Determine comment char early for editor template
        const ed_comment_char: u8 = ed_cc_blk: {
            if (helpers.getConfigValueByKey(git_path, "core.commentchar", allocator)) |cc_val| {
                defer allocator.free(cc_val);
                if (std.mem.eql(u8, cc_val, "auto")) {
                    const candidates = "#;@!$%^&|:";
                    if (message) |msg| {
                        for (candidates) |c| {
                            var found = false;
                            var li = std.mem.splitScalar(u8, msg, '\n');
                            while (li.next()) |line| {
                                if (line.len > 0 and line[0] == c) { found = true; break; }
                            }
                            if (!found) break :ed_cc_blk c;
                        }
                        // All candidates used up
                        try platform_impl.writeStderr("error: unable to select a comment character that is not used\nin the current commit message\n");
                        std.process.exit(1);
                    }
                    break :ed_cc_blk '#';
                }
                if (cc_val.len > 0) break :ed_cc_blk cc_val[0];
            }
            break :ed_cc_blk '#';
        };

        // Build COMMIT_EDITMSG content
        var editmsg_buf = std.array_list.Managed(u8).init(allocator);
        defer editmsg_buf.deinit();

        // Add existing message if any (template_message takes precedence for editor initial content)
        const editor_initial_msg = template_message orelse message;
        if (editor_initial_msg) |msg| {
            try editmsg_buf.appendSlice(msg);
            if (msg.len > 0 and msg[msg.len - 1] != '\n') try editmsg_buf.append('\n');
        } else {
            try editmsg_buf.append('\n');
        }

        // Add signoff line to the template if -s was given
        if (signoff) signoff_in_template: {
            const committer_info_for_sob = helpers.getCommitterString(allocator) catch break :signoff_in_template;
            defer allocator.free(committer_info_for_sob);
            const committer_name_email_sob = blk_sob: {
                if (std.mem.lastIndexOf(u8, committer_info_for_sob, ">")) |gt_pos| {
                    break :blk_sob committer_info_for_sob[0..gt_pos + 1];
                }
                break :blk_sob committer_info_for_sob;
            };
            const sob_line = try std.fmt.allocPrint(allocator, "Signed-off-by: {s}", .{committer_name_email_sob});
            defer allocator.free(sob_line);
            // Check if signoff is already in the message
            const already_has = if (message) |msg| std.mem.indexOf(u8, msg, sob_line) != null else false;
            if (!already_has) {
                try editmsg_buf.append('\n');
                try editmsg_buf.appendSlice(sob_line);
                try editmsg_buf.append('\n');
            }
        }

        // Determine whether to show status
        const show_status = switch (status_option) {
            .yes => true,
            .no => false,
            .default => blk_st: {
                // Check commit.status config
                if (helpers.getConfigValueByKey(git_path, "commit.status", allocator)) |csv| {
                    defer allocator.free(csv);
                    if (std.ascii.eqlIgnoreCase(csv, "false") or std.ascii.eqlIgnoreCase(csv, "no")) {
                        break :blk_st false;
                    }
                }
                break :blk_st true;
            },
        };

        // Add comment block based on cleanup mode
        if (cleanup_mode == .scissors) {
            // Scissors mode: add scissors line
            try editmsg_buf.append(ed_comment_char);
            try editmsg_buf.appendSlice(" ------------------------ >8 ------------------------\n");
            try editmsg_buf.append(ed_comment_char);
            try editmsg_buf.appendSlice(" Do not modify or remove the line above.\n");
            try editmsg_buf.append(ed_comment_char);
            try editmsg_buf.appendSlice(" Everything below it will be ignored.\n");
        } else if (cleanup_mode == .strip or cleanup_mode == .default) {
            // Add standard comment block (only when comments will be stripped)
            try editmsg_buf.append('\n');
            try editmsg_buf.append(ed_comment_char);
            try editmsg_buf.appendSlice(" Please enter the commit message for your changes. Lines starting\n");
            try editmsg_buf.append(ed_comment_char);
            try editmsg_buf.appendSlice(" with '");
            try editmsg_buf.append(ed_comment_char);
            try editmsg_buf.appendSlice("' will be ignored, and an empty message aborts the commit.\n");
        }

        // Add author/date/committer info as comments if needed
        if (cleanup_mode == .strip or cleanup_mode == .default or cleanup_mode == .scissors) {
            // Show author if different from committer
            const ed_author = if (author_override) |ao| ao else std.posix.getenv("GIT_AUTHOR_NAME");
            const ed_committer_name = std.posix.getenv("GIT_COMMITTER_NAME");
            const ed_author_email = std.posix.getenv("GIT_AUTHOR_EMAIL");
            const ed_committer_email = std.posix.getenv("GIT_COMMITTER_EMAIL");
            const author_differs = blk_ad: {
                if (ed_author != null and ed_committer_name != null) {
                    if (!std.mem.eql(u8, ed_author.?, ed_committer_name.?)) break :blk_ad true;
                }
                if (ed_author_email != null and ed_committer_email != null) {
                    if (!std.mem.eql(u8, ed_author_email.?, ed_committer_email.?)) break :blk_ad true;
                }
                break :blk_ad false;
            };
            if (author_differs) {
                try editmsg_buf.append(ed_comment_char);
                try editmsg_buf.appendSlice(" Author:    ");
                if (ed_author) |a| try editmsg_buf.appendSlice(a);
                try editmsg_buf.appendSlice(" <");
                if (ed_author_email) |e| try editmsg_buf.appendSlice(e);
                try editmsg_buf.appendSlice(">\n");
            }
            // Show date if GIT_AUTHOR_DATE is set
            if (std.posix.getenv("GIT_AUTHOR_DATE")) |date_str| {
                try editmsg_buf.append(ed_comment_char);
                try editmsg_buf.appendSlice(" Date:      ");
                // Try to format the date nicely - parse to epoch+tz then format
                if (helpers.parseDateToGitFormat(date_str, allocator)) |git_date| {
                    defer allocator.free(git_date);
                    if (std.mem.indexOfScalar(u8, git_date, ' ')) |sp| {
                        const epoch_str = git_date[0..sp];
                        const tz_str = std.mem.trim(u8, git_date[sp + 1 ..], " ");
                        if (std.fmt.parseInt(i64, epoch_str, 10)) |epoch| {
                            if (helpers.formatGitDate(epoch, tz_str, allocator)) |formatted| {
                                defer allocator.free(formatted);
                                try editmsg_buf.appendSlice(formatted);
                            } else |_| {
                                try editmsg_buf.appendSlice(date_str);
                            }
                        } else |_| {
                            try editmsg_buf.appendSlice(date_str);
                        }
                    } else {
                        try editmsg_buf.appendSlice(date_str);
                    }
                } else |_| {
                    try editmsg_buf.appendSlice(date_str);
                }
                try editmsg_buf.append('\n');
            }
        }

        // Add status info (Changes to be committed, etc.)
        if (show_status and (cleanup_mode == .strip or cleanup_mode == .default or cleanup_mode == .scissors)) {
            try editmsg_buf.append(ed_comment_char);
            try editmsg_buf.append('\n');

            // Get current branch
            const ed_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch "master";
            defer allocator.free(ed_branch);
            try editmsg_buf.append(ed_comment_char);
            try editmsg_buf.appendSlice(" On branch ");
            try editmsg_buf.appendSlice(ed_branch);
            try editmsg_buf.append('\n');

            // Show staged changes
            try editmsg_buf.append(ed_comment_char);
            try editmsg_buf.appendSlice(" Changes to be committed:\n");
        }

        // Write COMMIT_EDITMSG
        try platform_impl.fs.writeFile(editmsg_path, editmsg_buf.items);

        // Launch editor
        const editor = std.posix.getenv("GIT_EDITOR") orelse
            std.posix.getenv("VISUAL") orelse
            std.posix.getenv("EDITOR") orelse blk_ed: {
                if (helpers.getConfigValueByKey(git_path, "core.editor", allocator)) |ed| {
                    break :blk_ed @as([]const u8, ed);
                }
                break :blk_ed "vi";
            };

        // Build editor command and run via /bin/sh
        const editor_cmd = try std.fmt.allocPrint(allocator, "{s} \"{s}\"", .{ editor, editmsg_path });
        defer allocator.free(editor_cmd);

        const editor_cmd_z = try allocator.dupeZ(u8, editor_cmd);
        defer allocator.free(editor_cmd_z);

        const sh_path: []const u8 = "/bin/sh";
        const sh_z = try allocator.dupeZ(u8, sh_path);
        defer allocator.free(sh_z);
        const dash_c = try allocator.dupeZ(u8, "-c");
        defer allocator.free(dash_c);
        const argv_ptrs = [_][]const u8{ sh_path, "-c", editor_cmd };
        var child = std.process.Child.init(&argv_ptrs, allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        const term = child.spawnAndWait() catch |err| {
            const err_msg = try std.fmt.allocPrint(allocator, "error: could not launch editor: {any}\n", .{err});
            defer allocator.free(err_msg);
            try platform_impl.writeStderr(err_msg);
            std.process.exit(1);
        };
        const editor_exit_ok = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
        if (!editor_exit_ok) {
            try platform_impl.writeStderr("error: There was a problem with the editor.\n");
            std.process.exit(1);
        }

        // Read back the edited message
        message = platform_impl.fs.readFile(allocator, editmsg_path) catch {
            try platform_impl.writeStderr("error: could not read COMMIT_EDITMSG\n");
            std.process.exit(1);
        };
    } else if (message == null) {
        try platform_impl.writeStderr("error: no commit message provided (use -m)\n");
        std.process.exit(1);
    }

    // Write COMMIT_EDITMSG even when not using editor (for tests that check it)
    if (!need_editor or no_edit) {
        const editmsg_path2 = try std.fmt.allocPrint(allocator, "{s}/COMMIT_EDITMSG", .{git_path});
        defer allocator.free(editmsg_path2);
        if (message) |msg| {
            platform_impl.fs.writeFile(editmsg_path2, msg) catch {};
        }
    }

    // Adjust default cleanup mode: --no-edit with message from file/merge uses whitespace cleanup
    if (!cleanup_explicit and cleanup_mode == .default and no_edit and msg_source != .m_flag) {
        cleanup_mode = .whitespace;
    }

    // Determine comment character from config
    const comment_char: u8 = blk_cc: {
        if (helpers.getConfigValueByKey(git_path, "core.commentchar", allocator)) |cc_val| {
            defer allocator.free(cc_val);
            if (std.mem.eql(u8, cc_val, "auto")) {
                // Auto-detect: find a char not used at start of any line in the message
                const candidates = "#;@!$%^&|:";
                if (message) |msg| {
                    for (candidates) |c| {
                        var found = false;
                        var lines_iter = std.mem.splitScalar(u8, msg, '\n');
                        while (lines_iter.next()) |line| {
                            if (line.len > 0 and line[0] == c) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) break :blk_cc c;
                    }
                    // All candidates used up
                    try platform_impl.writeStderr("error: unable to select a comment character that is not used\nin the current commit message\n");
                    std.process.exit(1);
                }
                break :blk_cc '#';
            }
            if (cc_val.len > 0) break :blk_cc cc_val[0];
        }
        break :blk_cc '#';
    };

    // Apply cleanup mode to the message
    if (message) |msg| {
        message = switch (cleanup_mode) {
            .verbatim => msg, // No cleanup
            .whitespace => blk: {
                // Strip trailing whitespace from each line and trailing empty lines
                break :blk cleanupWhitespace(allocator, msg) catch msg;
            },
            .strip, .default => blk: {
                // Strip comments and trailing whitespace
                break :blk cleanupStripWithChar(allocator, msg, comment_char) catch msg;
            },
            .scissors => blk: {
                // Strip everything below scissors line
                break :blk cleanupScissors(allocator, msg, comment_char) catch msg;
            },
        };
    }

    // Check for empty or whitespace-only message (skip in verbatim mode and --allow-empty-message)
    if (cleanup_mode != .verbatim and !allow_empty_message) {
        if (message) |msg| {
            const trimmed = std.mem.trim(u8, msg, " \t\n\r");
            if (trimmed.len == 0) {
                try platform_impl.writeStderr("Aborting commit due to empty commit message.\n");
                std.process.exit(1);
            }
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
        // If message is null, treat as empty for signoff purposes
        if (message == null) {
            message = try std.fmt.allocPrint(allocator, "\n\n{s}\n", .{signoff_line});
        } else if (std.mem.indexOf(u8, message.?, signoff_line) == null) {
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

    // Apply --trailer values
    if (trailers.items.len > 0 and message != null) {
        const old_msg_t = message.?;
        const trimmed_msg_t = std.mem.trimRight(u8, old_msg_t, "\n");
        // Check if message already ends with a trailer-like line
        const has_trailer_t = blk_t: {
            if (std.mem.lastIndexOf(u8, trimmed_msg_t, "\n")) |last_nl| {
                const last_line = trimmed_msg_t[last_nl + 1..];
                break :blk_t std.mem.indexOf(u8, last_line, ": ") != null;
            }
            break :blk_t false;
        };
        var trailer_buf = std.array_list.Managed(u8).init(allocator);
        defer trailer_buf.deinit();
        try trailer_buf.appendSlice(trimmed_msg_t);
        if (!has_trailer_t) {
            try trailer_buf.appendSlice("\n");
        }
        for (trailers.items) |trailer| {
            try trailer_buf.appendSlice("\n");
            // Normalize trailer: "Key=Value" or "Key:Value" -> "Key: Value"
            const trimmed_trailer = std.mem.trimRight(u8, trailer, " \t");
            if (std.mem.indexOfAny(u8, trimmed_trailer, "=:")) |sep_pos| {
                const key = std.mem.trimRight(u8, trimmed_trailer[0..sep_pos], " \t");
                const val_start = sep_pos + 1;
                const val = if (val_start < trimmed_trailer.len)
                    std.mem.trimLeft(u8, trimmed_trailer[val_start..], " \t")
                else
                    "";
                try trailer_buf.appendSlice(key);
                try trailer_buf.appendSlice(": ");
                try trailer_buf.appendSlice(val);
            } else {
                try trailer_buf.appendSlice(trimmed_trailer);
            }
        }
        try trailer_buf.appendSlice("\n");
        message = try allocator.dupe(u8, trailer_buf.items);
    }

    // Run pre-commit hook (or warn about non-executable hook)
    if (!no_verify) {
        const pre_commit_result = hooks.runHook(allocator, git_path, "pre-commit", &.{}, null, platform_impl) catch |err| {
            const err_msg = std.fmt.allocPrint(allocator, "error: failed to run pre-commit hook: {}\n", .{err}) catch null;
            defer if (err_msg) |m| allocator.free(m);
            if (err_msg) |m| platform_impl.writeStderr(m) catch {};
            std.process.exit(1);
        };
        if (pre_commit_result.skipped) {
            // Hook doesn't exist or isn't executable - warn if file exists but not executable
            hooks.warnIgnoredHook(allocator, git_path, "pre-commit", platform_impl);
        } else if (pre_commit_result.exit_code != 0) {
            std.process.exit(1);
        }
    }

    // Run commit-msg hook: write message to temp file, pass path as arg
    if (!no_verify) {
        if (message) |msg| {
            const commit_msg_file = std.fmt.allocPrint(allocator, "{s}/COMMIT_EDITMSG", .{git_path}) catch null;
            defer if (commit_msg_file) |f| allocator.free(f);
            if (commit_msg_file) |cmf| {
                // Only write cleaned message for non-editor path; editor path already has COMMIT_EDITMSG
                if (!need_editor or no_edit) {
                    platform_impl.fs.writeFile(cmf, msg) catch {};
                }
                const cm_result = hooks.runHook(allocator, git_path, "commit-msg", &.{cmf}, null, platform_impl) catch hooks.HookResult{ .exit_code = 0, .skipped = true };
                if (!cm_result.skipped and cm_result.exit_code != 0) {
                    try platform_impl.writeStderr("Aborting commit due to commit-msg hook failure.\n");
                    std.process.exit(1);
                }
                // Re-read the message in case the hook modified it
                if (!cm_result.skipped) {
                    if (platform_impl.fs.readFile(allocator, cmf)) |new_msg| {
                        message = new_msg;
                    } else |_| {}
                }
            }
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
        
        const trimmed_msg = std.mem.trimRight(u8, message.?, "\n");
        // Extract first line of message for succinct mode
        const first_line = if (std.mem.indexOfScalar(u8, trimmed_msg, '\n')) |nl| trimmed_msg[0..nl] else trimmed_msg;
        if (succinct_mod.isEnabled()) {
            const success_msg = try std.fmt.allocPrint(allocator, "ok {s} {s} \"{s}\"\n", .{ current_branch, short_hash, first_line });
            defer allocator.free(success_msg);
            try platform_impl.writeStdout(success_msg);
            return;
        }
        if (is_root) {
            const success_msg = try std.fmt.allocPrint(allocator, "[{s} (root-commit) {s}] {s}\n", .{ current_branch, short_hash, trimmed_msg });
            defer allocator.free(success_msg);
            try platform_impl.writeStdout(success_msg);
        } else {
            const success_msg = try std.fmt.allocPrint(allocator, "[{s} {s}] {s}\n", .{ current_branch, short_hash, trimmed_msg });
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

    // Run post-commit hook
    _ = hooks.runHook(allocator, git_path, "post-commit", &.{}, null, platform_impl) catch {};
}


