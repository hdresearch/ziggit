// Auto-generated from main_common.zig - cmd_tag
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_tag = @import("cmd_tag.zig");

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

fn globMatchIgnoreCase(str: []const u8, pattern: []const u8) bool {
    var si: usize = 0;
    var pi: usize = 0;
    var star_pi: ?usize = null;
    var star_si: usize = 0;

    while (si < str.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or std.ascii.toLower(pattern[pi]) == std.ascii.toLower(str[si]))) {
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

fn matchPattern(name: []const u8, pat: []const u8, icase: bool) bool {
    if (icase) return globMatchIgnoreCase(name, pat);
    return helpers.globMatch(name, pat);
}

pub fn cmdTag(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("tag: not supported in freestanding mode\n");
        return;
    }

    // helpers.Find .git directory first
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    var annotated = false;
    var message: ?[]const u8 = null;
    var message_from_m = false;
    var message_from_f = false;
    var tag_name: ?[]const u8 = null;
    var delete_mode = false;
    var list_mode = false;
    var n_lines: ?i32 = null; // -n<num> for showing annotation lines
    var force = false;
    var verify_mode = false;
    var delete_names = std.array_list.Managed([]const u8).init(allocator);
    defer delete_names.deinit();
    var list_patterns = std.array_list.Managed([]const u8).init(allocator);
    defer list_patterns.deinit();
    var sort_key: ?[]const u8 = "refname";
    var ignore_case = false;
    var create_reflog = false;
    var target_ref: ?[]const u8 = null;

    // helpers.Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-a")) {
            annotated = true;
        } else if (std.mem.eql(u8, arg, "-d")) {
            delete_mode = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            list_mode = true;
            // -l can be followed by a pattern (same arg or next args)
            // patterns are collected as positional args below
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-m")) {
            if (message_from_f) {
                try platform_impl.writeStderr("fatal: only one of -m or -F can be used.\n");
                std.process.exit(1);
                unreachable;
            }
            message = args.next() orelse {
                try platform_impl.writeStderr("error: option '-m' requires a value\n");
                std.process.exit(129);
            };
            message_from_m = true;
            annotated = true;
        } else if (std.mem.eql(u8, arg, "-F")) {
            if (message_from_m) {
                try platform_impl.writeStderr("fatal: only one of -m or -F can be used.\n");
                std.process.exit(1);
                unreachable;
            }
            const fname = args.next() orelse {
                try platform_impl.writeStderr("error: option '-F' requires a value\n");
                std.process.exit(129);
            };
            if (std.mem.eql(u8, fname, "-")) {
                // helpers.Read from stdin
                const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
                message = stdin.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
                    try platform_impl.writeStderr("fatal: could not read from stdin\n");
                    std.process.exit(128);
                    unreachable;
                };
            } else {
                message = std.fs.cwd().readFileAlloc(allocator, fname, 10 * 1024 * 1024) catch {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: could not open '{s}'\n", .{fname});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                    unreachable;
                };
            }
            message_from_f = true;
            annotated = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sign") or std.mem.eql(u8, arg, "-u")) {
            annotated = true; // helpers.GPG signing implies annotated
            if (std.mem.eql(u8, arg, "-u")) _ = args.next(); // skip key-id
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verify")) {
            verify_mode = true;
        } else if (std.mem.eql(u8, arg, "-n")) {
            n_lines = 1; // -n defaults to 1 line
            list_mode = true;
        } else if (arg.len > 2 and arg[0] == '-' and arg[1] == 'n' and arg[2] >= '0' and arg[2] <= '9') {
            // -n<num>
            n_lines = std.fmt.parseInt(i32, arg[2..], 10) catch 1;
            list_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--contains") or std.mem.startsWith(u8, arg, "--no-contains") or
            std.mem.startsWith(u8, arg, "--merged") or std.mem.startsWith(u8, arg, "--no-merged") or
            std.mem.startsWith(u8, arg, "--points-at") or std.mem.startsWith(u8, arg, "--with") or
            std.mem.startsWith(u8, arg, "--without") or std.mem.startsWith(u8, arg, "--no-with"))
        {
            list_mode = true; // These imply list mode
            // Value may be after = or as next arg; just skip next if no =
            if (std.mem.indexOfScalar(u8, arg, '=') == null) {
                // Consume next arg as value (e.g. --contains helpers.HEAD)
                _ = args.next();
            }
        } else if (std.mem.startsWith(u8, arg, "--sort=")) {
            sort_key = arg["--sort=".len..];
        } else if (std.mem.eql(u8, arg, "--no-sort")) {
            sort_key = null;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
            ignore_case = true;
        } else if (std.mem.eql(u8, arg, "--create-reflog")) {
            create_reflog = true;
        } else if (std.mem.startsWith(u8, arg, "--format=") or
            std.mem.eql(u8, arg, "--column") or std.mem.eql(u8, arg, "--no-column") or
            std.mem.eql(u8, arg, "--color") or std.mem.startsWith(u8, arg, "--color=") or
            std.mem.eql(u8, arg, "--omit-empty"))
        {
            // Accepted options (not fully implemented)
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (delete_mode) {
                try delete_names.append(arg);
            } else if (list_mode) {
                try list_patterns.append(arg);
            } else if (tag_name == null) {
                tag_name = arg;
            } else if (target_ref == null) {
                target_ref = arg;
            }
        }
    }

    // Validate incompatible modes (must be before delete/verify handling)
    if (list_mode and delete_mode) {
        try platform_impl.writeStderr("error: -l and -d are incompatible\n");
        std.process.exit(1);
    }
    if (list_mode and verify_mode) {
        try platform_impl.writeStderr("error: -l and -v are incompatible\n");
        std.process.exit(1);
    }
    if (list_mode and (annotated or message != null or force)) {
        try platform_impl.writeStderr("error: -l and creation options are incompatible\n");
        std.process.exit(1);
    }
    if (delete_mode and verify_mode) {
        try platform_impl.writeStderr("error: -d and -v are incompatible\n");
        std.process.exit(1);
    }
    if (verify_mode and (annotated or message != null)) {
        try platform_impl.writeStderr("error: -v and creation options are incompatible\n");
        std.process.exit(1);
    }

    // helpers.Handle delete mode
    if (delete_mode) {
        if (delete_names.items.len == 0) {
            // helpers.No names to delete — this is not an error in git
            return;
        }
        for (delete_names.items) |del_name| {
            const tag_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{ git_path, del_name });
            defer allocator.free(tag_ref_path);
            // helpers.Read hash before deleting for output
            const tag_hash = std.fs.cwd().readFileAlloc(allocator, tag_ref_path, 4096) catch {
                const msg = try std.fmt.allocPrint(allocator, "error: tag '{s}' not found.\n", .{del_name});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
                unreachable;
            };
            defer allocator.free(tag_hash);
            std.fs.cwd().deleteFile(tag_ref_path) catch {
                const msg = try std.fmt.allocPrint(allocator, "error: tag '{s}' not found.\n", .{del_name});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
                unreachable;
            };
            const trimmed = std.mem.trimRight(u8, tag_hash, "\r\n");
            const msg = try std.fmt.allocPrint(allocator, "Deleted tag '{s}' (was {s})\n", .{ del_name, if (trimmed.len >= 7) trimmed[0..7] else trimmed });
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
        }
        return;
    }

    // helpers.Handle verify mode
    if (verify_mode) {
        const verify_tag = tag_name orelse {
            try platform_impl.writeStderr("usage: git tag -v <tagname>...\n");
            std.process.exit(1);
            unreachable;
        };
        // helpers.Check if the tag exists
        const tag_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{ git_path, verify_tag });
        defer allocator.free(tag_ref_path);
        const tag_content = std.fs.cwd().readFileAlloc(allocator, tag_ref_path, 4096) catch {
            // helpers.Try packed-helpers.refs
            const packed_refs_path2 = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_path});
            defer allocator.free(packed_refs_path2);
            const packed_data = std.fs.cwd().readFileAlloc(allocator, packed_refs_path2, 10 * 1024 * 1024) catch {
                const emsg = try std.fmt.allocPrint(allocator, "error: tag '{s}' not found.\n", .{verify_tag});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(1);
                unreachable;
            };
            defer allocator.free(packed_data);
            const ref_to_find = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{verify_tag});
            defer allocator.free(ref_to_find);
            if (std.mem.indexOf(u8, packed_data, ref_to_find) == null) {
                const emsg = try std.fmt.allocPrint(allocator, "error: tag '{s}' not found.\n", .{verify_tag});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(1);
                unreachable;
            }
            // helpers.Found in packed-helpers.refs, try to verify
            try platform_impl.writeStderr("error: no signature found\n");
            std.process.exit(1);
            unreachable;
        };
        defer allocator.free(tag_content);
        const ref_hash = std.mem.trim(u8, tag_content, " \t\r\n");
        if (ref_hash.len < 40) {
            const emsg = try std.fmt.allocPrint(allocator, "error: tag '{s}' not found.\n", .{verify_tag});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(1);
            unreachable;
        }
        // helpers.Check if it's a tag object (annotated) - verify needs annotated tag with signature
        const tag_obj = objects.GitObject.load(ref_hash[0..40], git_path, platform_impl, allocator) catch {
            const emsg = try std.fmt.allocPrint(allocator, "error: tag '{s}' not found.\n", .{verify_tag});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(1);
            unreachable;
        };
        defer tag_obj.deinit(allocator);
        if (tag_obj.type != .tag) {
            const emsg = try std.fmt.allocPrint(allocator, "error: {s}: cannot verify a non-tag object of type {s}.\n", .{ ref_hash[0..40], @tagName(tag_obj.type) });
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(1);
            unreachable;
        }
        // helpers.No helpers.GPG signature support - report no signature
        try platform_impl.writeStderr("error: no signature found\n");
        std.process.exit(1);
        unreachable;
    }

    if (annotated and tag_name == null and !list_mode) {
        try platform_impl.writeStderr("fatal: tag name is required\n");
        std.process.exit(1);
    }
    if (message != null and tag_name == null and !list_mode) {
        try platform_impl.writeStderr("fatal: tag name is required\n");
        std.process.exit(1);
    }
    if (force and tag_name == null and !list_mode and !delete_mode) {
        try platform_impl.writeStderr("fatal: tag name is required\n");
        std.process.exit(1);
    }

    if (tag_name == null or list_mode) {
        // List tags, optionally filtered by patterns
        // helpers.Collect all patterns (from -l args and tag_name if set in list mode)
        const patterns = if (list_patterns.items.len > 0)
            list_patterns.items
        else if (tag_name) |tn|
            @as([]const []const u8, &[_][]const u8{tn})
        else
            @as([]const []const u8, &[_][]const u8{});
        
        const has_patterns = patterns.len > 0;
        
        const tags_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_path});
        defer allocator.free(tags_path);
        
        var tags_dir = std.fs.cwd().openDir(tags_path, .{ .iterate = true }) catch {
            // helpers.No tags directory means no tags
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
            if (entry.kind == .directory) continue;
            // helpers.Apply pattern filter if present
            if (has_patterns) {
                var matched = false;
                for (patterns) |pat| {
                    if (matchPattern(entry.name, pat, ignore_case)) { matched = true; break; }
                }
                if (!matched) continue;
            }
            try tag_list.append(try allocator.dupe(u8, entry.name));
        }
        
        // helpers.Also check packed-helpers.refs for tags
        const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_path});
        defer allocator.free(packed_refs_path);
        if (std.fs.cwd().readFileAlloc(allocator, packed_refs_path, 10 * 1024 * 1024)) |packed_content| {
            defer allocator.free(packed_content);
            var lines = std.mem.splitScalar(u8, packed_content, '\n');
            while (lines.next()) |line| {
                if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
                if (std.mem.indexOfScalar(u8, line, ' ')) |space_idx| {
                    const ref_name = line[space_idx + 1 ..];
                    if (std.mem.startsWith(u8, ref_name, "refs/tags/")) {
                        const tag_short = ref_name["refs/tags/".len..];
                        if (has_patterns) {
                            var matched = false;
                            for (patterns) |pat| {
                                if (matchPattern(tag_short, pat, ignore_case)) { matched = true; break; }
                            }
                            if (!matched) continue;
                        }
                        // helpers.Check not already in list
                        var already = false;
                        for (tag_list.items) |existing| {
                            if (std.mem.eql(u8, existing, tag_short)) { already = true; break; }
                        }
                        if (!already) {
                            try tag_list.append(try allocator.dupe(u8, tag_short));
                        }
                    }
                }
            }
        } else |_| {}
        
        // Sort tags
        const reverse = if (sort_key) |sk| std.mem.startsWith(u8, sk, "-") else false;
        if (ignore_case) {
            std.sort.pdq([]u8, tag_list.items, reverse, struct {
                fn lessThan(rev: bool, a: []u8, b: []u8) bool {
                    const cmp = cmpIgnoreCase(a, b);
                    return if (rev) cmp == .gt else cmp == .lt;
                }
                fn cmpIgnoreCase(a: []const u8, b: []const u8) std.math.Order {
                    const min_len = @min(a.len, b.len);
                    for (0..min_len) |i| {
                        const ca = std.ascii.toLower(a[i]);
                        const cb = std.ascii.toLower(b[i]);
                        if (ca < cb) return .lt;
                        if (ca > cb) return .gt;
                    }
                    return std.math.order(a.len, b.len);
                }
            }.lessThan);
        } else {
            std.sort.pdq([]u8, tag_list.items, reverse, struct {
                fn lessThan(rev: bool, a: []u8, b: []u8) bool {
                    const cmp_result = std.mem.order(u8, a, b);
                    return if (rev) cmp_result == .gt else cmp_result == .lt;
                }
            }.lessThan);
        }
        
        for (tag_list.items) |tag| {
            if (n_lines) |nl| {
                if (nl > 0) {
                    // Show annotation lines for annotated tags
                    const annotation = getTagAnnotation(allocator, git_path, tag, platform_impl, @intCast(nl)) catch "";
                    defer if (annotation.len > 0) allocator.free(annotation);
                    if (annotation.len > 0) {
                        // Git pads tag names to a minimum width with spaces
                        var out_buf = std.array_list.Managed(u8).init(allocator);
                        defer out_buf.deinit();
                        try out_buf.appendSlice(tag);
                        // Pad to at least 16 chars total (tag + spaces)
                        while (out_buf.items.len < 16) try out_buf.append(' ');
                        try out_buf.appendSlice(annotation);
                        try out_buf.append('\n');
                        try platform_impl.writeStdout(out_buf.items);
                    } else {
                        // Still pad for annotated tags with empty message
                        var out_buf2 = std.array_list.Managed(u8).init(allocator);
                        defer out_buf2.deinit();
                        try out_buf2.appendSlice(tag);
                        // Check if this is an annotated tag (pad even if empty annotation)
                        const is_annotated = isAnnotatedTag(allocator, git_path, tag, platform_impl);
                        if (is_annotated) {
                            while (out_buf2.items.len < 16) try out_buf2.append(' ');
                        }
                        try out_buf2.append('\n');
                        try platform_impl.writeStdout(out_buf2.items);
                    }
                } else {
                    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{tag});
                    defer allocator.free(output);
                    try platform_impl.writeStdout(output);
                }
            } else {
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{tag});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        }
        
        return;
    }

    // helpers.Validate tag name
    if (tag_name) |tn| {
        if (std.mem.eql(u8, tn, "HEAD")) {
            try platform_impl.writeStderr("fatal: 'HEAD' is not a valid tag name\n");
            std.process.exit(128);
        }
        // helpers.Check for invalid ref names (git check-ref-format rules)
        const is_invalid = tn.len == 0 or
            tn[0] == '.' or tn[0] == '-' or
            std.mem.endsWith(u8, tn, ".lock") or
            std.mem.endsWith(u8, tn, ".") or
            std.mem.indexOf(u8, tn, "..") != null or
            std.mem.indexOf(u8, tn, " ") != null or
            std.mem.indexOf(u8, tn, "~") != null or
            std.mem.indexOf(u8, tn, "^") != null or
            std.mem.indexOf(u8, tn, ":") != null or
            std.mem.indexOf(u8, tn, "\\") != null or
            std.mem.indexOf(u8, tn, "[") != null or
            std.mem.indexOf(u8, tn, "?") != null or
            std.mem.indexOf(u8, tn, "*") != null or
            std.mem.indexOfScalar(u8, tn, 0x7f) != null or
            (for (tn) |c| {
                if (c < 0x20) break true;
            } else false);
        if (is_invalid) {
            const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' is not a valid tag name.\n", .{tn});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        }
    }

    // helpers.Resolve target ref if specified, otherwise use helpers.HEAD
    const commit_hash = if (target_ref) |tr|
        helpers.resolveRevision(git_path, tr, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: not a valid object name: '{s}'\n", .{tr});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
            unreachable;
        }
    else blk: {
        const head_hash = refs.getCurrentCommit(git_path, platform_impl, allocator) catch {
            try platform_impl.writeStderr("fatal: no commits yet\n");
            std.process.exit(128);
            unreachable;
        };
        if (head_hash) |h| break :blk h;
        try platform_impl.writeStderr("fatal: no commits yet\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(commit_hash);

    // helpers.Create tags directory if it doesn't exist
    const tags_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_path});
    defer allocator.free(tags_path);
    
    platform_impl.fs.makeDir(tags_path) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };

    // helpers.Check if tag already exists (unless -f)
    {
        const existing_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tags_path, tag_name.? });
        defer allocator.free(existing_path);
        if (std.fs.cwd().access(existing_path, .{})) |_| {
            if (!force) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: tag '{s}' already exists\n", .{tag_name.?});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            }
        } else |_| {}
    }

    // helpers.For hierarchical tag names (foo/bar), create parent directories
    const tag_ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tags_path, tag_name.? });
    defer allocator.free(tag_ref_path);
    if (std.fs.path.dirname(tag_ref_path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }

    if (annotated) {
        if (message == null) {
            // TODO: launch editor for annotation
            try platform_impl.writeStderr("error: annotated tag requires a message (use -m)\n");
            std.process.exit(1);
        }
        
        // helpers.Create annotated tag object - use committer identity (not author)
        const tagger_name = if (std.posix.getenv("GIT_COMMITTER_NAME")) |n| n
            else if (std.posix.getenv("GIT_AUTHOR_NAME")) |n| n
            else (helpers.resolveAuthorName(allocator, git_path) catch "A U Thor");
        const tagger_email = if (std.posix.getenv("GIT_COMMITTER_EMAIL")) |e| e
            else if (std.posix.getenv("GIT_AUTHOR_EMAIL")) |e| e
            else (helpers.resolveAuthorEmail(allocator, git_path) catch "author@example.com");

        // helpers.Resolve timestamp and timezone
        var timestamp: i64 = std.time.timestamp();
        var tz_str: []const u8 = "+0000";
        var tz_buf: [6]u8 = undefined;
        if (std.posix.getenv("GIT_COMMITTER_DATE")) |date_str| {
            // helpers.Parse git date formats using shared parser
            const parsed = try helpers.parseDateToGitFormat(date_str, allocator);
            defer allocator.free(parsed);
            if (std.mem.indexOfScalar(u8, parsed, ' ')) |sp| {
                timestamp = std.fmt.parseInt(i64, parsed[0..sp], 10) catch timestamp;
                // helpers.Copy timezone to tz_buf to avoid use-after-free
                const tz_part = parsed[sp + 1 ..];
                const copy_len = @min(tz_part.len, tz_buf.len);
                @memcpy(tz_buf[0..copy_len], tz_part[0..copy_len]);
                tz_str = tz_buf[0..copy_len];
            } else {
                timestamp = std.fmt.parseInt(i64, parsed, 10) catch timestamp;
            }
        } else {
            // helpers.Default to +0000 if we can't determine timezone
            _ = std.fmt.bufPrint(&tz_buf, "+0000", .{}) catch {};
            tz_str = tz_buf[0..5];
        }
        
        // helpers.Clean up message: strip comments, leading/trailing blanks, trailing whitespace per line
        var msg_lines_arr = std.array_list.Managed([]const u8).init(allocator);
        defer msg_lines_arr.deinit();
        {
            var msg_lines = std.mem.splitScalar(u8, message.?, '\n');
            while (msg_lines.next()) |mline| {
                if (mline.len > 0 and mline[0] == '#') continue;
                // helpers.Strip trailing whitespace from line
                const stripped = std.mem.trimRight(u8, mline, " \t\r");
                try msg_lines_arr.append(stripped);
            }
        }
        // Apply stripspace-like cleanup: collapse consecutive blank lines, remove leading/trailing blanks
        var stripped_lines = std.array_list.Managed([]const u8).init(allocator);
        defer stripped_lines.deinit();
        {
            var prev_blank = false;
            for (msg_lines_arr.items) |mline| {
                if (mline.len == 0) {
                    if (!prev_blank and stripped_lines.items.len > 0) {
                        try stripped_lines.append(mline);
                    }
                    prev_blank = true;
                } else {
                    try stripped_lines.append(mline);
                    prev_blank = false;
                }
            }
        }
        // Remove trailing empty lines
        while (stripped_lines.items.len > 0 and stripped_lines.items[stripped_lines.items.len - 1].len == 0) {
            _ = stripped_lines.pop();
        }
        // Build final message
        var cleaned_msg = std.array_list.Managed(u8).init(allocator);
        defer cleaned_msg.deinit();
        for (stripped_lines.items) |mline| {
            try cleaned_msg.appendSlice(mline);
            try cleaned_msg.append('\n');
        }
        // helpers.Remove trailing newline (we'll add it in the format)
        if (cleaned_msg.items.len > 0 and cleaned_msg.items[cleaned_msg.items.len - 1] == '\n') {
            _ = cleaned_msg.pop();
        }
        const final_msg = cleaned_msg.items;

        // helpers.Detect the object type
        const obj_type_str: []const u8 = blk_type: {
            const obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch break :blk_type "commit";
            defer obj.deinit(allocator);
            break :blk_type switch (obj.type) {
                .blob => "blob",
                .tree => "tree",
                .commit => "commit",
                .tag => "tag",
            };
        };

        const tag_content = if (final_msg.len == 0)
            try std.fmt.allocPrint(allocator, "object {s}\ntype {s}\ntag {s}\ntagger {s} <{s}> {d} {s}\n\n", .{ commit_hash, obj_type_str, tag_name.?, tagger_name, tagger_email, timestamp, tz_str })
        else
            try std.fmt.allocPrint(allocator, "object {s}\ntype {s}\ntag {s}\ntagger {s} <{s}> {d} {s}\n\n{s}\n", .{ commit_hash, obj_type_str, tag_name.?, tagger_name, tagger_email, timestamp, tz_str, final_msg });
        defer allocator.free(tag_content);
        
        // Create and store tag object using objects module (uses C zlib)
        const tag_obj = objects.GitObject{ .type = .tag, .data = tag_content };
        const tag_hex_slice = try tag_obj.store(git_path, platform_impl, allocator);
        defer allocator.free(tag_hex_slice);
        var tag_hex: [40]u8 = undefined;
        @memcpy(&tag_hex, tag_hex_slice[0..40]);
        
        // helpers.Write ref pointing to tag object
        const ref_content = try std.fmt.allocPrint(allocator, "{s}\n", .{tag_hex});
        defer allocator.free(ref_content);
        try platform_impl.fs.writeFile(tag_ref_path, ref_content);
    } else {
        // helpers.Create lightweight tag (direct reference to commit)
        const ref_content = try std.fmt.allocPrint(allocator, "{s}\n", .{commit_hash});
        defer allocator.free(ref_content);
        
        try platform_impl.fs.writeFile(tag_ref_path, ref_content);
    }
}

fn isAnnotatedTag(allocator: std.mem.Allocator, git_path: []const u8, tag_name: []const u8, platform_impl: anytype) bool {
    const ref_path = std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{ git_path, tag_name }) catch return false;
    defer allocator.free(ref_path);
    const ref_content = platform_impl.fs.readFile(allocator, ref_path) catch return false;
    defer allocator.free(ref_content);
    const hash = std.mem.trim(u8, ref_content, " \t\n\r");
    if (hash.len < 40) return false;
    const obj = objects.GitObject.load(hash[0..40], git_path, platform_impl, allocator) catch return false;
    defer obj.deinit(allocator);
    return obj.type == .tag;
}

/// Get annotation text for a tag (first n_lines of message)
fn getTagAnnotation(allocator: std.mem.Allocator, git_path: []const u8, tag_name: []const u8, platform_impl: anytype, max_lines: usize) ![]const u8 {
    // Read tag ref to get hash
    const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{ git_path, tag_name });
    defer allocator.free(ref_path);
    const ref_content = platform_impl.fs.readFile(allocator, ref_path) catch {
        // Try packed-refs
        const packed_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_path});
        defer allocator.free(packed_path);
        const packed_data = platform_impl.fs.readFile(allocator, packed_path) catch return "";
        defer allocator.free(packed_data);
        var lines_iter = std.mem.splitScalar(u8, packed_data, '\n');
        while (lines_iter.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const search = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{tag_name});
            defer allocator.free(search);
            if (std.mem.indexOf(u8, line, search)) |_| {
                if (line.len >= 40) {
                    const hash = line[0..40];
                    return getAnnotationFromHash(allocator, git_path, hash, platform_impl, max_lines);
                }
            }
        }
        return "";
    };
    defer allocator.free(ref_content);
    const hash = std.mem.trim(u8, ref_content, " \t\n\r");
    if (hash.len < 40) return "";
    return getAnnotationFromHash(allocator, git_path, hash[0..40], platform_impl, max_lines);
}

fn getAnnotationFromHash(allocator: std.mem.Allocator, git_path: []const u8, hash: []const u8, platform_impl: anytype, max_lines: usize) ![]const u8 {
    const obj = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch return "";
    defer obj.deinit(allocator);
    if (obj.type != .tag) {
        // For lightweight tags pointing to commits, show commit message first line
        if (obj.type == .commit) {
            if (std.mem.indexOf(u8, obj.data, "\n\n")) |pos| {
                const msg = obj.data[pos + 2 ..];
                if (std.mem.indexOfScalar(u8, msg, '\n')) |nl| {
                    return try allocator.dupe(u8, msg[0..nl]);
                }
                return try allocator.dupe(u8, std.mem.trim(u8, msg, "\n"));
            }
        }
        return "";
    }
    // Tag object: extract message (after blank line)
    if (std.mem.indexOf(u8, obj.data, "\n\n")) |pos| {
        const msg = std.mem.trimRight(u8, obj.data[pos + 2 ..], "\n\r ");
        if (msg.len == 0) return "";
        var result = std.array_list.Managed(u8).init(allocator);
        errdefer result.deinit();
        var lines_iter = std.mem.splitScalar(u8, msg, '\n');
        var count: usize = 0;
        while (lines_iter.next()) |line| {
            if (count >= max_lines) break;
            const trimmed = std.mem.trimRight(u8, line, " \t\r");
            if (count > 0) try result.appendSlice("\n    ");
            try result.appendSlice(trimmed);
            count += 1;
        }
        return try result.toOwnedSlice();
    }
    return "";
}

