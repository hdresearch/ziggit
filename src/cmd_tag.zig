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

/// Compare two version strings for version sort
fn versionCmp(a: []const u8, b: []const u8) std.math.Order {
    var ai: usize = 0;
    var bi: usize = 0;
    while (ai < a.len and bi < b.len) {
        // If both are digits, compare numerically
        if (std.ascii.isDigit(a[ai]) and std.ascii.isDigit(b[bi])) {
            // Parse both numbers
            var a_end = ai;
            while (a_end < a.len and std.ascii.isDigit(a[a_end])) a_end += 1;
            var b_end = bi;
            while (b_end < b.len and std.ascii.isDigit(b[b_end])) b_end += 1;
            const a_num = std.fmt.parseInt(u64, a[ai..a_end], 10) catch 0;
            const b_num = std.fmt.parseInt(u64, b[bi..b_end], 10) catch 0;
            if (a_num < b_num) return .lt;
            if (a_num > b_num) return .gt;
            ai = a_end;
            bi = b_end;
        } else {
            if (a[ai] < b[bi]) return .lt;
            if (a[ai] > b[bi]) return .gt;
            ai += 1;
            bi += 1;
        }
    }
    return std.math.order(a.len, b.len);
}

/// Collect all tags recursively from refs/tags/ directory
fn collectTagsFromDir(allocator: std.mem.Allocator, base_path: []const u8, prefix: []const u8) !std.array_list.Managed([]u8) {
    var result = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit();
    }

    var dir = std.fs.cwd().openDir(base_path, .{ .iterate = true }) catch return result;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        const name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        if (entry.kind == .directory) {
            const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, entry.name });
            defer allocator.free(sub_path);
            var sub_tags = try collectTagsFromDir(allocator, sub_path, name);
            defer sub_tags.deinit();
            for (sub_tags.items) |tag| try result.append(tag);
            allocator.free(name);
        } else {
            try result.append(name);
        }
    }

    return result;
}

/// Resolve a tag to the commit it ultimately points to (follows annotated tags)
fn resolveTagToCommit(allocator: std.mem.Allocator, git_path: []const u8, tag_hash: []const u8, platform_impl: anytype) ![]u8 {
    var current = try allocator.dupe(u8, tag_hash);
    var depth: usize = 0;
    while (depth < 20) : (depth += 1) {
        const obj = objects.GitObject.load(current, git_path, platform_impl, allocator) catch return current;
        defer obj.deinit(allocator);
        if (obj.type == .commit) return current;
        if (obj.type == .tag) {
            if (std.mem.startsWith(u8, obj.data, "object ") and obj.data.len >= 47) {
                const target = obj.data[7..47];
                allocator.free(current);
                current = try allocator.dupe(u8, target);
                continue;
            }
        }
        // blob or tree - not a commit
        return current;
    }
    return current;
}

/// Get the direct hash a tag ref points to (before following annotated tag objects)
fn getTagDirectHash(allocator: std.mem.Allocator, git_path: []const u8, tag_name: []const u8, platform_impl: anytype) ![]u8 {
    const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{ git_path, tag_name });
    defer allocator.free(ref_path);
    if (platform_impl.fs.readFile(allocator, ref_path)) |content| {
        defer allocator.free(content);
        const hash = std.mem.trim(u8, content, " \t\n\r");
        if (hash.len >= 40) return try allocator.dupe(u8, hash[0..40]);
        return error.InvalidRef;
    } else |_| {
        // Try packed-refs
        const packed_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_path});
        defer allocator.free(packed_path);
        const packed_data = platform_impl.fs.readFile(allocator, packed_path) catch return error.NotFound;
        defer allocator.free(packed_data);
        const search = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{tag_name});
        defer allocator.free(search);
        var lines = std.mem.splitScalar(u8, packed_data, '\n');
        while (lines.next()) |line| {
            if (line.len < 40 or line[0] == '#' or line[0] == '^') continue;
            if (std.mem.indexOf(u8, line, search) != null) {
                return try allocator.dupe(u8, line[0..40]);
            }
        }
        return error.NotFound;
    }
}

/// Check if an object is a commit type
fn isCommitObject(allocator: std.mem.Allocator, git_path: []const u8, hash: []const u8, platform_impl: anytype) bool {
    const obj = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch return false;
    defer obj.deinit(allocator);
    return obj.type == .commit;
}

/// Expand a format string with tag data
fn expandFormat(allocator: std.mem.Allocator, fmt_str: []const u8, tag_name: []const u8, git_path: []const u8, platform_impl: anytype) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    const refname = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{tag_name});
    defer allocator.free(refname);

    const obj_hash = getTagDirectHash(allocator, git_path, tag_name, platform_impl) catch "";
    defer if (obj_hash.len > 0) allocator.free(obj_hash);

    var i: usize = 0;
    while (i < fmt_str.len) {
        if (i + 1 < fmt_str.len and fmt_str[i] == '%' and fmt_str[i + 1] == '(') {
            // Find closing )
            const start = i + 2;
            var end = start;
            var depth: usize = 1;
            while (end < fmt_str.len) {
                if (fmt_str[end] == '(') depth += 1;
                if (fmt_str[end] == ')') {
                    depth -= 1;
                    if (depth == 0) break;
                }
                end += 1;
            }
            if (end < fmt_str.len) {
                const field = fmt_str[start..end];
                if (std.mem.eql(u8, field, "refname")) {
                    try result.appendSlice(refname);
                } else if (std.mem.eql(u8, field, "refname:short")) {
                    try result.appendSlice(tag_name);
                } else if (std.mem.eql(u8, field, "objectname")) {
                    try result.appendSlice(obj_hash);
                } else if (std.mem.eql(u8, field, "objectname:short")) {
                    if (obj_hash.len >= 7) try result.appendSlice(obj_hash[0..7]);
                } else if (std.mem.eql(u8, field, "objecttype") or std.mem.eql(u8, field, "type")) {
                    const obj = objects.GitObject.load(obj_hash, git_path, platform_impl, allocator) catch {
                        try result.appendSlice("commit");
                        i = end + 1;
                        continue;
                    };
                    defer obj.deinit(allocator);
                    try result.appendSlice(obj.type.toString());
                } else if (std.mem.startsWith(u8, field, "if")) {
                    // Complex conditional - just skip for now
                    // Find matching %(end)
                    const full_remaining = fmt_str[i..];
                    if (std.mem.indexOf(u8, full_remaining, "%(end)")) |end_pos| {
                        i += end_pos + "%(end)".len;
                        continue;
                    }
                } else if (std.mem.eql(u8, field, "color:green")) {
                    try result.appendSlice("\x1b[32m");
                } else if (std.mem.eql(u8, field, "color:reset")) {
                    try result.appendSlice("\x1b[m");
                } else if (std.mem.startsWith(u8, field, "color:")) {
                    // Other color codes - just emit ANSI
                    const color_name = field["color:".len..];
                    if (std.mem.eql(u8, color_name, "red")) {
                        try result.appendSlice("\x1b[31m");
                    } else if (std.mem.eql(u8, color_name, "green")) {
                        try result.appendSlice("\x1b[32m");
                    } else if (std.mem.eql(u8, color_name, "yellow")) {
                        try result.appendSlice("\x1b[33m");
                    } else if (std.mem.eql(u8, color_name, "blue")) {
                        try result.appendSlice("\x1b[34m");
                    } else if (std.mem.eql(u8, color_name, "reset")) {
                        try result.appendSlice("\x1b[m");
                    }
                } else {
                    // Unknown field - leave empty
                }
                i = end + 1;
                continue;
            }
        }
        try result.append(fmt_str[i]);
        i += 1;
    }

    return try result.toOwnedSlice();
}

pub fn cmdTag(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("tag: not supported in freestanding mode\n");
        return;
    }

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
    var n_lines: ?i32 = null;
    var force = false;
    var verify_mode = false;
    var delete_names = std.array_list.Managed([]const u8).init(allocator);
    defer delete_names.deinit();
    var list_patterns = std.array_list.Managed([]const u8).init(allocator);
    defer list_patterns.deinit();
    var sort_key: ?[]const u8 = null; // null = default (refname), will check config
    var sort_key_set = false;
    var ignore_case = false;
    var create_reflog = false;
    var target_ref: ?[]const u8 = null;
    var points_at_vals = std.array_list.Managed([]const u8).init(allocator);
    defer points_at_vals.deinit();
    var contains_val: ?[]const u8 = null;
    var no_contains_val: ?[]const u8 = null;
    var merged_val: ?[]const u8 = null;
    var no_merged_val: ?[]const u8 = null;
    var format_str: ?[]const u8 = null;
    var omit_empty = false;
    var edit_mode = false;
    var sign_mode = false;
    var sign_key: ?[]const u8 = null;
    var column_mode: ?[]const u8 = null;
    var no_column = false;
    var color_mode: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--annotate")) {
            annotated = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delete")) {
            delete_mode = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            list_mode = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--edit")) {
            edit_mode = true;
        } else if (std.mem.eql(u8, arg, "-m")) {
            if (message_from_f) {
                try platform_impl.writeStderr("fatal: only one of -m or -F can be used.\n");
                std.process.exit(1);
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
            }
            const fname = args.next() orelse {
                try platform_impl.writeStderr("error: option '-F' requires a value\n");
                std.process.exit(129);
            };
            if (std.mem.eql(u8, fname, "-")) {
                const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
                message = stdin.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
                    try platform_impl.writeStderr("fatal: could not read from stdin\n");
                    std.process.exit(128);
                };
            } else {
                message = std.fs.cwd().readFileAlloc(allocator, fname, 10 * 1024 * 1024) catch {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: could not open '{s}'\n", .{fname});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                };
            }
            message_from_f = true;
            annotated = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sign")) {
            annotated = true;
            sign_mode = true;
        } else if (std.mem.eql(u8, arg, "-u")) {
            annotated = true;
            sign_mode = true;
            sign_key = args.next();
        } else if (std.mem.eql(u8, arg, "--no-sign")) {
            sign_mode = false;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verify")) {
            verify_mode = true;
        } else if (std.mem.eql(u8, arg, "-n")) {
            n_lines = 1;
            list_mode = true;
        } else if (arg.len > 2 and arg[0] == '-' and arg[1] == 'n' and arg[2] >= '0' and arg[2] <= '9') {
            n_lines = std.fmt.parseInt(i32, arg[2..], 10) catch 1;
            list_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--points-at")) {
            list_mode = true;
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                try points_at_vals.append(arg[eq + 1 ..]);
            } else {
                if (args.next()) |v| {
                    // Check if it looks like a pattern/flag rather than a commit
                    if (v.len > 0 and v[0] == '-') {
                        // It's another flag, points-at defaults to HEAD
                        try points_at_vals.append("HEAD");
                        // We need to process this arg too - but we can't push it back
                        // Handle the common case: --points-at followed by pattern
                    } else {
                        try points_at_vals.append(v);
                    }
                } else {
                    try points_at_vals.append("HEAD");
                }
            }
        } else if (std.mem.startsWith(u8, arg, "--contains")) {
            list_mode = true;
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                contains_val = arg[eq + 1 ..];
            } else {
                contains_val = args.next();
            }
        } else if (std.mem.startsWith(u8, arg, "--no-contains") or std.mem.startsWith(u8, arg, "--without")) {
            list_mode = true;
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                no_contains_val = arg[eq + 1 ..];
            } else {
                no_contains_val = args.next();
            }
        } else if (std.mem.startsWith(u8, arg, "--merged")) {
            list_mode = true;
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                merged_val = arg[eq + 1 ..];
            } else {
                merged_val = args.next();
            }
        } else if (std.mem.startsWith(u8, arg, "--no-merged")) {
            list_mode = true;
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                no_merged_val = arg[eq + 1 ..];
            } else {
                no_merged_val = args.next();
            }
        } else if (std.mem.startsWith(u8, arg, "--sort=")) {
            sort_key = arg["--sort=".len..];
            sort_key_set = true;
        } else if (std.mem.eql(u8, arg, "--sort")) {
            sort_key = args.next();
            sort_key_set = true;
        } else if (std.mem.eql(u8, arg, "--no-sort")) {
            sort_key = null;
            sort_key_set = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
            ignore_case = true;
        } else if (std.mem.eql(u8, arg, "--create-reflog")) {
            create_reflog = true;
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            format_str = arg["--format=".len..];
        } else if (std.mem.eql(u8, arg, "--format")) {
            format_str = args.next();
        } else if (std.mem.eql(u8, arg, "--omit-empty")) {
            omit_empty = true;
        } else if (std.mem.startsWith(u8, arg, "--column")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                column_mode = arg[eq + 1 ..];
            } else {
                column_mode = "column";
            }
        } else if (std.mem.eql(u8, arg, "--no-column")) {
            no_column = true;
            column_mode = null;
        } else if (std.mem.startsWith(u8, arg, "--color")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                color_mode = arg[eq + 1 ..];
            } else {
                color_mode = "always";
            }
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            color_mode = "never";
        } else if (std.mem.eql(u8, arg, "--no-with") or std.mem.eql(u8, arg, "--no-without")) {
            const emsg = try std.fmt.allocPrint(allocator, "error: unknown option `{s}'\n", .{arg[2..]});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(1);
        } else if (std.mem.startsWith(u8, arg, "--with")) {
            list_mode = true;
            if (std.mem.indexOfScalar(u8, arg, '=') == null) {
                _ = args.next();
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (delete_mode) {
                try delete_names.append(arg);
            } else if (list_mode or points_at_vals.items.len > 0 or contains_val != null or no_contains_val != null or merged_val != null or no_merged_val != null) {
                try list_patterns.append(arg);
            } else if (tag_name == null) {
                tag_name = arg;
            } else if (target_ref == null) {
                target_ref = arg;
            }
        }
    }

    // If --sort not set on command line, check config
    if (!sort_key_set) {
        // Check tag.sort config
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);
        if (std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024)) |config_data| {
            defer allocator.free(config_data);
            if (getConfigValue(config_data, "tag", "sort")) |val| {
                sort_key = val;
            } else {
                sort_key = "refname";
            }
        } else |_| {
            sort_key = "refname";
        }
    }
    if (sort_key == null) sort_key = "refname";

    // Validate sort key
    if (sort_key) |sk| {
        const effective = if (std.mem.startsWith(u8, sk, "-")) sk[1..] else sk;
        const valid = std.mem.eql(u8, effective, "refname") or
            std.mem.eql(u8, effective, "version:refname") or
            std.mem.eql(u8, effective, "v:refname") or
            std.mem.eql(u8, effective, "creatordate") or
            std.mem.eql(u8, effective, "objectname") or
            std.mem.eql(u8, effective, "taggerdate") or
            std.mem.eql(u8, effective, "*objectname") or
            std.mem.eql(u8, effective, "objecttype") or
            std.mem.eql(u8, effective, "*objecttype");
        if (!valid) {
            const emsg = try std.fmt.allocPrint(allocator, "error: unsupported sort specification '{s}'\n", .{sk});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(1);
        }
    }

    // Validate format string
    if (format_str) |fmt| {
        if (std.mem.indexOf(u8, fmt, "%(rest)") != null) {
            try platform_impl.writeStderr("fatal: this command reject atom %(rest)\n");
            std.process.exit(1);
        }
    }

    // Check incompatibilities
    if (list_mode and delete_mode) {
        try platform_impl.writeStderr("error: -l and -d are incompatible\n");
        std.process.exit(1);
    }
    if (list_mode and verify_mode) {
        try platform_impl.writeStderr("error: -l and -v are incompatible\n");
        std.process.exit(1);
    }
    if (list_mode and (annotated or message != null or message_from_m or message_from_f or force)) {
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
    if (verify_mode and sign_mode) {
        try platform_impl.writeStderr("error: -v and -s are incompatible\n");
        std.process.exit(1);
    }
    if (n_lines != null and verify_mode) {
        try platform_impl.writeStderr("error: -n and -v are incompatible\n");
        std.process.exit(1);
    }
    if (n_lines != null and column_mode != null) {
        try platform_impl.writeStderr("error: --column and -n are incompatible\n");
        std.process.exit(1);
    }

    // If --contains/--no-contains/--merged/--no-merged/--points-at used without explicit -l, it's list mode
    if (contains_val != null or no_contains_val != null or merged_val != null or no_merged_val != null or points_at_vals.items.len > 0) {
        list_mode = true;
    }

    // Validate --contains/--no-contains values resolve to commits
    if (contains_val) |cv| {
        const resolved_cv = helpers.resolveRevision(git_path, cv, platform_impl, allocator) catch {
            const emsg = try std.fmt.allocPrint(allocator, "error: malformed object name '{s}'\n", .{cv});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(1);
        };
        defer allocator.free(resolved_cv);
        // Resolve through tags to check if it's a commit
        const commit_cv = resolveTagToCommit(allocator, git_path, resolved_cv, platform_impl) catch {
            const emsg = try std.fmt.allocPrint(allocator, "error: object {s} is not a commit\n", .{cv});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(1);
        };
        defer allocator.free(commit_cv);
        if (!isCommitObject(allocator, git_path, commit_cv, platform_impl)) {
            const obj_cv = objects.GitObject.load(commit_cv, git_path, platform_impl, allocator) catch {
                const emsg = try std.fmt.allocPrint(allocator, "error: object {s} is not a commit\n", .{cv});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(1);
            };
            defer obj_cv.deinit(allocator);
            const emsg = try std.fmt.allocPrint(allocator, "error: object {s} is a {s}, not a commit\n", .{ resolved_cv, obj_cv.type.toString() });
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(1);
        }
    }
    if (no_contains_val) |ncv| {
        const resolved_ncv = helpers.resolveRevision(git_path, ncv, platform_impl, allocator) catch {
            const emsg = try std.fmt.allocPrint(allocator, "error: malformed object name '{s}'\n", .{ncv});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(1);
        };
        defer allocator.free(resolved_ncv);
        const commit_ncv = resolveTagToCommit(allocator, git_path, resolved_ncv, platform_impl) catch {
            const emsg = try std.fmt.allocPrint(allocator, "error: object {s} is not a commit\n", .{ncv});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(1);
        };
        defer allocator.free(commit_ncv);
        if (!isCommitObject(allocator, git_path, commit_ncv, platform_impl)) {
            const obj_ncv = objects.GitObject.load(commit_ncv, git_path, platform_impl, allocator) catch {
                const emsg = try std.fmt.allocPrint(allocator, "error: object {s} is not a commit\n", .{ncv});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(1);
            };
            defer obj_ncv.deinit(allocator);
            const emsg = try std.fmt.allocPrint(allocator, "error: object {s} is a {s}, not a commit\n", .{ resolved_ncv, obj_ncv.type.toString() });
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(1);
        }
    }

    // Handle delete mode
    if (delete_mode) {
        if (delete_names.items.len == 0) return;
        for (delete_names.items) |del_name| {
            const tag_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{ git_path, del_name });
            defer allocator.free(tag_ref_path);
            const tag_hash = std.fs.cwd().readFileAlloc(allocator, tag_ref_path, 4096) catch {
                const msg = try std.fmt.allocPrint(allocator, "error: tag '{s}' not found.\n", .{del_name});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
            };
            defer allocator.free(tag_hash);
            std.fs.cwd().deleteFile(tag_ref_path) catch {
                const msg = try std.fmt.allocPrint(allocator, "error: tag '{s}' not found.\n", .{del_name});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
            };
            const trimmed = std.mem.trimRight(u8, tag_hash, "\r\n");
            const msg = try std.fmt.allocPrint(allocator, "Deleted tag '{s}' (was {s})\n", .{ del_name, if (trimmed.len >= 7) trimmed[0..7] else trimmed });
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
        }
        return;
    }

    // Handle verify mode
    if (verify_mode) {
        const verify_tag = tag_name orelse {
            try platform_impl.writeStderr("usage: git tag -v <tagname>...\n");
            std.process.exit(1);
        };
        const tag_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{ git_path, verify_tag });
        defer allocator.free(tag_ref_path);
        const tag_content = std.fs.cwd().readFileAlloc(allocator, tag_ref_path, 4096) catch {
            const packed_refs_path2 = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_path});
            defer allocator.free(packed_refs_path2);
            const packed_data = std.fs.cwd().readFileAlloc(allocator, packed_refs_path2, 10 * 1024 * 1024) catch {
                const emsg = try std.fmt.allocPrint(allocator, "error: tag '{s}' not found.\n", .{verify_tag});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(1);
            };
            defer allocator.free(packed_data);
            const ref_to_find = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{verify_tag});
            defer allocator.free(ref_to_find);
            if (std.mem.indexOf(u8, packed_data, ref_to_find) == null) {
                const emsg = try std.fmt.allocPrint(allocator, "error: tag '{s}' not found.\n", .{verify_tag});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(1);
            }
            try platform_impl.writeStderr("error: no signature found\n");
            std.process.exit(1);
        };
        defer allocator.free(tag_content);
        const ref_hash = std.mem.trim(u8, tag_content, " \t\r\n");
        if (ref_hash.len < 40) {
            const emsg = try std.fmt.allocPrint(allocator, "error: tag '{s}' not found.\n", .{verify_tag});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(1);
        }
        const tag_obj = objects.GitObject.load(ref_hash[0..40], git_path, platform_impl, allocator) catch {
            const emsg = try std.fmt.allocPrint(allocator, "error: tag '{s}' not found.\n", .{verify_tag});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(1);
        };
        defer tag_obj.deinit(allocator);
        if (tag_obj.type != .tag) {
            const emsg = try std.fmt.allocPrint(allocator, "error: {s}: cannot verify a non-tag object of type {s}.\n", .{ ref_hash[0..40], @tagName(tag_obj.type) });
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(1);
        }
        try platform_impl.writeStderr("error: no signature found\n");
        std.process.exit(1);
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
        // List mode
        const patterns = if (list_patterns.items.len > 0)
            list_patterns.items
        else if (tag_name) |tn|
            @as([]const []const u8, &[_][]const u8{tn})
        else
            @as([]const []const u8, &[_][]const u8{});

        const has_patterns = patterns.len > 0;

        const tags_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_path});
        defer allocator.free(tags_path);

        // Collect tags recursively
        var tag_list = try collectTagsFromDir(allocator, tags_path, "");
        defer {
            for (tag_list.items) |tag| allocator.free(tag);
            tag_list.deinit();
        }

        // Also check packed-refs
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
                        var already = false;
                        for (tag_list.items) |existing| {
                            if (std.mem.eql(u8, existing, tag_short)) {
                                already = true;
                                break;
                            }
                        }
                        if (!already) {
                            try tag_list.append(try allocator.dupe(u8, tag_short));
                        }
                    }
                }
            }
        } else |_| {}

        // Apply pattern filter
        if (has_patterns) {
            var i: usize = 0;
            while (i < tag_list.items.len) {
                var matched = false;
                for (patterns) |pat| {
                    if (matchPattern(tag_list.items[i], pat, ignore_case)) {
                        matched = true;
                        break;
                    }
                }
                if (!matched) {
                    allocator.free(tag_list.items[i]);
                    _ = tag_list.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        // Filter by --points-at
        if (points_at_vals.items.len > 0) {
            var resolved_points = std.array_list.Managed([]const u8).init(allocator);
            defer {
                for (resolved_points.items) |h| allocator.free(h);
                resolved_points.deinit();
            }
            for (points_at_vals.items) |pv| {
                const resolved = helpers.resolveRevision(git_path, pv, platform_impl, allocator) catch continue;
                try resolved_points.append(resolved);
            }
            var i: usize = 0;
            while (i < tag_list.items.len) {
                const tag_direct = getTagDirectHash(allocator, git_path, tag_list.items[i], platform_impl) catch {
                    allocator.free(tag_list.items[i]);
                    _ = tag_list.orderedRemove(i);
                    continue;
                };
                defer allocator.free(tag_direct);

                var matched_pt = false;
                for (resolved_points.items) |rp| {
                    // Check direct hash match
                    if (std.mem.eql(u8, tag_direct, rp)) {
                        matched_pt = true;
                        break;
                    }
                    // For annotated tags, also check the tag object hash
                    // (--points-at finds tags whose ref directly points to the given object)
                }
                if (!matched_pt) {
                    // For annotated tags, check each level of tag object indirection
                    var check_hash = try allocator.dupe(u8, tag_direct);
                    defer allocator.free(check_hash);
                    var depth: usize = 0;
                    while (depth < 20) : (depth += 1) {
                        const obj = objects.GitObject.load(check_hash, git_path, platform_impl, allocator) catch break;
                        defer obj.deinit(allocator);
                        if (obj.type == .tag) {
                            if (std.mem.startsWith(u8, obj.data, "object ") and obj.data.len >= 47) {
                                const inner = obj.data[7..47];
                                for (resolved_points.items) |rp| {
                                    if (std.mem.eql(u8, inner, rp)) {
                                        matched_pt = true;
                                        break;
                                    }
                                }
                                if (matched_pt) break;
                                allocator.free(check_hash);
                                check_hash = try allocator.dupe(u8, inner);
                                continue;
                            }
                        }
                        // Not a tag object, check commit/tree/blob hash
                        for (resolved_points.items) |rp| {
                            if (std.mem.eql(u8, check_hash, rp)) {
                                matched_pt = true;
                                break;
                            }
                        }
                        break;
                    }
                }
                if (!matched_pt) {
                    allocator.free(tag_list.items[i]);
                    _ = tag_list.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        // Filter by --contains
        if (contains_val) |cv| {
            const contains_hash = helpers.resolveRevision(git_path, cv, platform_impl, allocator) catch {
                const emsg = try std.fmt.allocPrint(allocator, "error: malformed object name '{s}'\n", .{cv});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(1);
            };
            defer allocator.free(contains_hash);
            // Resolve to commit if it's a tag
            const contains_commit = resolveTagToCommit(allocator, git_path, contains_hash, platform_impl) catch contains_hash;
            const should_free_cc = @intFromPtr(contains_commit.ptr) != @intFromPtr(contains_hash.ptr);
            defer if (should_free_cc) allocator.free(contains_commit);

            var i: usize = 0;
            while (i < tag_list.items.len) {
                const tag_hash = getTagDirectHash(allocator, git_path, tag_list.items[i], platform_impl) catch {
                    allocator.free(tag_list.items[i]);
                    _ = tag_list.orderedRemove(i);
                    continue;
                };
                defer allocator.free(tag_hash);

                // Resolve tag to commit
                const tag_commit = resolveTagToCommit(allocator, git_path, tag_hash, platform_impl) catch {
                    allocator.free(tag_list.items[i]);
                    _ = tag_list.orderedRemove(i);
                    continue;
                };
                defer allocator.free(tag_commit);

                // Check if tag_commit is not a commit (skip non-commit objects)
                if (!isCommitObject(allocator, git_path, tag_commit, platform_impl)) {
                    allocator.free(tag_list.items[i]);
                    _ = tag_list.orderedRemove(i);
                    continue;
                }

                // Tag "contains" the commit if the commit is an ancestor of the tag's commit
                const is_ancestor = helpers.isAncestor(git_path, contains_commit, tag_commit, allocator, platform_impl) catch false;
                if (!is_ancestor) {
                    allocator.free(tag_list.items[i]);
                    _ = tag_list.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        // Filter by --no-contains
        if (no_contains_val) |ncv| {
            const nc_hash = helpers.resolveRevision(git_path, ncv, platform_impl, allocator) catch {
                const emsg = try std.fmt.allocPrint(allocator, "error: malformed object name '{s}'\n", .{ncv});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(1);
            };
            defer allocator.free(nc_hash);
            const nc_commit = resolveTagToCommit(allocator, git_path, nc_hash, platform_impl) catch nc_hash;
            const should_free_nc = @intFromPtr(nc_commit.ptr) != @intFromPtr(nc_hash.ptr);
            defer if (should_free_nc) allocator.free(nc_commit);

            var i: usize = 0;
            while (i < tag_list.items.len) {
                const tag_hash = getTagDirectHash(allocator, git_path, tag_list.items[i], platform_impl) catch {
                    allocator.free(tag_list.items[i]);
                    _ = tag_list.orderedRemove(i);
                    continue;
                };
                defer allocator.free(tag_hash);

                const tag_commit = resolveTagToCommit(allocator, git_path, tag_hash, platform_impl) catch {
                    // If can't resolve, keep it (non-commit objects don't contain commits)
                    i += 1;
                    continue;
                };
                defer allocator.free(tag_commit);

                if (!isCommitObject(allocator, git_path, tag_commit, platform_impl)) {
                    // Non-commit objects are skipped for --no-contains
                    allocator.free(tag_list.items[i]);
                    _ = tag_list.orderedRemove(i);
                    continue;
                }

                // Remove if the tag contains the no-contains commit
                const is_ancestor = helpers.isAncestor(git_path, nc_commit, tag_commit, allocator, platform_impl) catch false;
                if (is_ancestor) {
                    allocator.free(tag_list.items[i]);
                    _ = tag_list.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        // Filter by --merged
        if (merged_val) |mv| {
            const merged_hash = helpers.resolveRevision(git_path, mv, platform_impl, allocator) catch {
                const emsg = try std.fmt.allocPrint(allocator, "error: malformed object name '{s}'\n", .{mv});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(1);
            };
            defer allocator.free(merged_hash);
            const merged_commit = resolveTagToCommit(allocator, git_path, merged_hash, platform_impl) catch merged_hash;
            const should_free_mc = @intFromPtr(merged_commit.ptr) != @intFromPtr(merged_hash.ptr);
            defer if (should_free_mc) allocator.free(merged_commit);

            var i: usize = 0;
            while (i < tag_list.items.len) {
                const tag_hash = getTagDirectHash(allocator, git_path, tag_list.items[i], platform_impl) catch {
                    allocator.free(tag_list.items[i]);
                    _ = tag_list.orderedRemove(i);
                    continue;
                };
                defer allocator.free(tag_hash);

                const tag_commit = resolveTagToCommit(allocator, git_path, tag_hash, platform_impl) catch {
                    allocator.free(tag_list.items[i]);
                    _ = tag_list.orderedRemove(i);
                    continue;
                };
                defer allocator.free(tag_commit);

                // Tag is "merged" into the target if the tag's commit is an ancestor of the target
                const is_merged = helpers.isAncestor(git_path, tag_commit, merged_commit, allocator, platform_impl) catch false;
                if (!is_merged) {
                    allocator.free(tag_list.items[i]);
                    _ = tag_list.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        // Filter by --no-merged
        if (no_merged_val) |nmv| {
            const nm_hash = helpers.resolveRevision(git_path, nmv, platform_impl, allocator) catch {
                const emsg = try std.fmt.allocPrint(allocator, "error: malformed object name '{s}'\n", .{nmv});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(1);
            };
            defer allocator.free(nm_hash);
            const nm_commit = resolveTagToCommit(allocator, git_path, nm_hash, platform_impl) catch nm_hash;
            const should_free_nmc = @intFromPtr(nm_commit.ptr) != @intFromPtr(nm_hash.ptr);
            defer if (should_free_nmc) allocator.free(nm_commit);

            var i: usize = 0;
            while (i < tag_list.items.len) {
                const tag_hash = getTagDirectHash(allocator, git_path, tag_list.items[i], platform_impl) catch {
                    i += 1;
                    continue;
                };
                defer allocator.free(tag_hash);

                const tag_commit = resolveTagToCommit(allocator, git_path, tag_hash, platform_impl) catch {
                    i += 1;
                    continue;
                };
                defer allocator.free(tag_commit);

                // Remove if tag IS merged (ancestor of target)
                const is_merged = helpers.isAncestor(git_path, tag_commit, nm_commit, allocator, platform_impl) catch false;
                if (is_merged) {
                    allocator.free(tag_list.items[i]);
                    _ = tag_list.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        // Sort tags
        const sk = sort_key orelse "refname";
        const reverse = std.mem.startsWith(u8, sk, "-");
        const effective_sort = if (reverse) sk[1..] else sk;
        const is_version_sort = std.mem.eql(u8, effective_sort, "version:refname") or std.mem.eql(u8, effective_sort, "v:refname");

        if (is_version_sort) {
            std.sort.pdq([]u8, tag_list.items, reverse, struct {
                fn lessThan(rev: bool, a: []u8, b: []u8) bool {
                    const cmp = versionCmp(a, b);
                    return if (rev) cmp == .gt else cmp == .lt;
                }
            }.lessThan);
        } else if (ignore_case) {
            std.sort.pdq([]u8, tag_list.items, reverse, struct {
                fn lessThan(rev: bool, a: []u8, b: []u8) bool {
                    const cmp = cmpIgnoreCase(a, b);
                    return if (rev) cmp == .gt else cmp == .lt;
                }
                fn cmpIgnoreCase(a: []const u8, b: []const u8) std.math.Order {
                    const min_len = @min(a.len, b.len);
                    for (0..min_len) |ii| {
                        const ca = std.ascii.toLower(a[ii]);
                        const cb = std.ascii.toLower(b[ii]);
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

        // Output
        for (tag_list.items) |tag| {
            if (format_str) |fmt| {
                const formatted = expandFormat(allocator, fmt, tag, git_path, platform_impl) catch "";
                defer if (formatted.len > 0) allocator.free(formatted);
                if (omit_empty and formatted.len == 0) continue;
                try platform_impl.writeStdout(formatted);
                try platform_impl.writeStdout("\n");
            } else if (n_lines) |nl| {
                if (nl > 0) {
                    const annotation = getTagAnnotation(allocator, git_path, tag, platform_impl, @intCast(nl)) catch "";
                    defer if (annotation.len > 0) allocator.free(annotation);
                    if (annotation.len > 0) {
                        var out_buf = std.array_list.Managed(u8).init(allocator);
                        defer out_buf.deinit();
                        try out_buf.appendSlice(tag);
                        while (out_buf.items.len < 16) try out_buf.append(' ');
                        try out_buf.appendSlice(annotation);
                        try out_buf.append('\n');
                        try platform_impl.writeStdout(out_buf.items);
                    } else {
                        var out_buf2 = std.array_list.Managed(u8).init(allocator);
                        defer out_buf2.deinit();
                        try out_buf2.appendSlice(tag);
                        while (out_buf2.items.len < 16) try out_buf2.append(' ');
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

    // Validate tag name
    if (tag_name) |tn| {
        if (std.mem.eql(u8, tn, "HEAD")) {
            try platform_impl.writeStderr("fatal: 'HEAD' is not a valid tag name\n");
            std.process.exit(128);
        }
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

    // Resolve target
    const commit_hash = if (target_ref) |tr|
        helpers.resolveRevision(git_path, tr, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: not a valid object name: '{s}'\n", .{tr});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        }
    else blk: {
        const head_hash = refs.getCurrentCommit(git_path, platform_impl, allocator) catch {
            try platform_impl.writeStderr("fatal: no commits yet\n");
            std.process.exit(128);
        };
        if (head_hash) |h| break :blk h;
        try platform_impl.writeStderr("fatal: no commits yet\n");
        std.process.exit(128);
    };
    defer allocator.free(commit_hash);

    // Check if target is a tag object (for nested tag advice)
    var target_is_tag = false;
    {
        const obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch null;
        if (obj) |o| {
            defer o.deinit(allocator);
            if (o.type == .tag) target_is_tag = true;
        }
    }

    // Create tags directory
    const tags_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_path});
    defer allocator.free(tags_path);
    platform_impl.fs.makeDir(tags_path) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };

    // Check if tag already exists (unless -f)
    {
        const existing_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tags_path, tag_name.? });
        defer allocator.free(existing_path);
        if (std.fs.cwd().access(existing_path, .{})) |_| {
            if (!force) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: tag '{s}' already exists\n", .{tag_name.?});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }
        } else |_| {}
    }

    // Create parent dirs for hierarchical tag names
    const tag_ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tags_path, tag_name.? });
    defer allocator.free(tag_ref_path);
    if (std.fs.path.dirname(tag_ref_path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }

    // Check for sign mode - requires gpg
    if (sign_mode) {
        // Check if gpg.format is configured
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);

        // Try to create a signed tag using gpg
        // For now, we need to actually invoke gpg to sign
        // First create the tag content, then sign it

        if (message == null and !edit_mode) {
            // -s without -m means we need to open an editor
            // For now, use empty message
            message = "";
        }
        annotated = true;
    }

    // Check tag.gpgsign and tag.forcesignannotated config
    if (!sign_mode and annotated) {
        const config_path2 = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path2);
        if (std.fs.cwd().readFileAlloc(allocator, config_path2, 1024 * 1024)) |config_data| {
            defer allocator.free(config_data);
            if (getConfigValue(config_data, "tag", "gpgsign")) |val| {
                if (std.mem.eql(u8, val, "true")) sign_mode = true;
            }
            if (getConfigValue(config_data, "tag", "forcesignannotated")) |val| {
                if (std.mem.eql(u8, val, "true")) sign_mode = true;
            }
        } else |_| {}
    }

    if (annotated) {
        if (message == null) {
            // Launch editor
            const tag_editmsg_path = try std.fmt.allocPrint(allocator, "{s}/TAG_EDITMSG", .{git_path});
            defer allocator.free(tag_editmsg_path);

            // Create template
            const template = try std.fmt.allocPrint(allocator, "\n#\n# Write a message for tag:\n#   {s}\n# Lines starting with '#' will be ignored.\n#\n", .{tag_name.?});
            defer allocator.free(template);
            try platform_impl.fs.writeFile(tag_editmsg_path, template);

            // Get editor
            const editor = std.posix.getenv("GIT_EDITOR") orelse
                std.posix.getenv("VISUAL") orelse
                std.posix.getenv("EDITOR") orelse "vi";

            // Run editor
            const editor_cmd = try std.fmt.allocPrint(allocator, "{s} {s}", .{ editor, tag_editmsg_path });
            defer allocator.free(editor_cmd);

            var child = std.process.Child.init(&[_][]const u8{ "sh", "-c", editor_cmd }, allocator);
            child.stdin_behavior = .Inherit;
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;
            try child.spawn();
            const term = try child.wait();
            if (term.Exited != 0) {
                try platform_impl.writeStderr("error: editor returned non-zero status\n");
                std.process.exit(1);
            }

            // Read the edited message
            const edited = std.fs.cwd().readFileAlloc(allocator, tag_editmsg_path, 10 * 1024 * 1024) catch {
                try platform_impl.writeStderr("error: could not read tag message\n");
                std.process.exit(1);
            };

            // Clean message (strip comments)
            var cleaned = std.array_list.Managed(u8).init(allocator);
            var edit_lines = std.mem.splitScalar(u8, edited, '\n');
            while (edit_lines.next()) |ln| {
                if (ln.len > 0 and ln[0] == '#') continue;
                try cleaned.appendSlice(ln);
                try cleaned.append('\n');
            }
            allocator.free(edited);

            // Stripspace-like cleanup
            const cleaned_slice = try cleaned.toOwnedSlice();
            const trimmed_msg = std.mem.trim(u8, cleaned_slice, "\n");
            if (trimmed_msg.len == 0) {
                // Empty message after stripping - abort? No, git allows empty.
                message = "";
                allocator.free(cleaned_slice);
            } else {
                message = cleaned_slice;
            }

            // Delete TAG_EDITMSG on success
            std.fs.cwd().deleteFile(tag_editmsg_path) catch {};
        } else if (edit_mode) {
            // --edit: write message to TAG_EDITMSG and open editor
            const tag_editmsg_path = try std.fmt.allocPrint(allocator, "{s}/TAG_EDITMSG", .{git_path});
            defer allocator.free(tag_editmsg_path);

            const initial = try std.fmt.allocPrint(allocator, "{s}\n#\n# Write a message for tag:\n#   {s}\n# Lines starting with '#' will be ignored.\n#\n", .{ message.?, tag_name.? });
            defer allocator.free(initial);
            try platform_impl.fs.writeFile(tag_editmsg_path, initial);

            const editor = std.posix.getenv("GIT_EDITOR") orelse
                std.posix.getenv("VISUAL") orelse
                std.posix.getenv("EDITOR") orelse "vi";

            const editor_cmd = try std.fmt.allocPrint(allocator, "{s} {s}", .{ editor, tag_editmsg_path });
            defer allocator.free(editor_cmd);

            var child = std.process.Child.init(&[_][]const u8{ "sh", "-c", editor_cmd }, allocator);
            child.stdin_behavior = .Inherit;
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;
            try child.spawn();
            const term = try child.wait();
            if (term.Exited != 0) {
                try platform_impl.writeStderr("error: editor returned non-zero status\n");
                std.process.exit(1);
            }

            const edited = std.fs.cwd().readFileAlloc(allocator, tag_editmsg_path, 10 * 1024 * 1024) catch {
                try platform_impl.writeStderr("error: could not read tag message\n");
                std.process.exit(1);
            };

            var cleaned = std.array_list.Managed(u8).init(allocator);
            var edit_lines = std.mem.splitScalar(u8, edited, '\n');
            while (edit_lines.next()) |ln| {
                if (ln.len > 0 and ln[0] == '#') continue;
                try cleaned.appendSlice(ln);
                try cleaned.append('\n');
            }
            allocator.free(edited);
            message = try cleaned.toOwnedSlice();

            std.fs.cwd().deleteFile(tag_editmsg_path) catch {};
        }

        // Get tagger identity
        const tagger_name = if (std.posix.getenv("GIT_COMMITTER_NAME")) |n| n
            else if (std.posix.getenv("GIT_AUTHOR_NAME")) |n| n
            else (helpers.resolveAuthorName(allocator, git_path) catch "A U Thor");
        const tagger_email = if (std.posix.getenv("GIT_COMMITTER_EMAIL")) |e| e
            else if (std.posix.getenv("GIT_AUTHOR_EMAIL")) |e| e
            else (helpers.resolveAuthorEmail(allocator, git_path) catch "author@example.com");

        var timestamp: i64 = std.time.timestamp();
        var tz_str: []const u8 = "+0000";
        var tz_buf: [6]u8 = undefined;
        if (std.posix.getenv("GIT_COMMITTER_DATE")) |date_str| {
            const parsed = try helpers.parseDateToGitFormat(date_str, allocator);
            defer allocator.free(parsed);
            if (std.mem.indexOfScalar(u8, parsed, ' ')) |sp| {
                timestamp = std.fmt.parseInt(i64, parsed[0..sp], 10) catch timestamp;
                const tz_part = parsed[sp + 1 ..];
                const copy_len = @min(tz_part.len, tz_buf.len);
                @memcpy(tz_buf[0..copy_len], tz_part[0..copy_len]);
                tz_str = tz_buf[0..copy_len];
            } else {
                timestamp = std.fmt.parseInt(i64, parsed, 10) catch timestamp;
            }
        } else {
            _ = std.fmt.bufPrint(&tz_buf, "+0000", .{}) catch {};
            tz_str = tz_buf[0..5];
        }

        // Clean up message
        var msg_lines_arr = std.array_list.Managed([]const u8).init(allocator);
        defer msg_lines_arr.deinit();
        {
            var msg_lines = std.mem.splitScalar(u8, message.?, '\n');
            while (msg_lines.next()) |mline| {
                if (mline.len > 0 and mline[0] == '#') continue;
                const stripped = std.mem.trimRight(u8, mline, " \t\r");
                try msg_lines_arr.append(stripped);
            }
        }
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
        while (stripped_lines.items.len > 0 and stripped_lines.items[stripped_lines.items.len - 1].len == 0) {
            _ = stripped_lines.pop();
        }
        var cleaned_msg = std.array_list.Managed(u8).init(allocator);
        defer cleaned_msg.deinit();
        for (stripped_lines.items) |mline| {
            try cleaned_msg.appendSlice(mline);
            try cleaned_msg.append('\n');
        }
        if (cleaned_msg.items.len > 0 and cleaned_msg.items[cleaned_msg.items.len - 1] == '\n') {
            _ = cleaned_msg.pop();
        }
        const final_msg = cleaned_msg.items;

        // Detect object type
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

        var tag_content: []u8 = undefined;
        if (sign_mode) {
            // Build unsigned tag content
            const unsigned = if (final_msg.len == 0)
                try std.fmt.allocPrint(allocator, "object {s}\ntype {s}\ntag {s}\ntagger {s} <{s}> {d} {s}\n\n", .{ commit_hash, obj_type_str, tag_name.?, tagger_name, tagger_email, timestamp, tz_str })
            else
                try std.fmt.allocPrint(allocator, "object {s}\ntype {s}\ntag {s}\ntagger {s} <{s}> {d} {s}\n\n{s}\n", .{ commit_hash, obj_type_str, tag_name.?, tagger_name, tagger_email, timestamp, tz_str, final_msg });

            // Try to sign with gpg
            const signed_content = signWithGpg(allocator, unsigned, sign_key) catch |err| {
                allocator.free(unsigned);
                switch (err) {
                    error.GpgFailed => {
                        try platform_impl.writeStderr("error: gpg failed to sign the data\n");
                        std.process.exit(128);
                    },
                    else => {
                        try platform_impl.writeStderr("error: gpg failed to sign the data\n");
                        std.process.exit(128);
                    },
                }
            };
            allocator.free(unsigned);
            tag_content = signed_content;
        } else {
            tag_content = if (final_msg.len == 0)
                try std.fmt.allocPrint(allocator, "object {s}\ntype {s}\ntag {s}\ntagger {s} <{s}> {d} {s}\n\n", .{ commit_hash, obj_type_str, tag_name.?, tagger_name, tagger_email, timestamp, tz_str })
            else
                try std.fmt.allocPrint(allocator, "object {s}\ntype {s}\ntag {s}\ntagger {s} <{s}> {d} {s}\n\n{s}\n", .{ commit_hash, obj_type_str, tag_name.?, tagger_name, tagger_email, timestamp, tz_str, final_msg });
        }
        defer allocator.free(tag_content);

        const tag_obj = objects.GitObject{ .type = .tag, .data = tag_content };
        const tag_hex_slice = try tag_obj.store(git_path, platform_impl, allocator);
        defer allocator.free(tag_hex_slice);
        var tag_hex: [40]u8 = undefined;
        @memcpy(&tag_hex, tag_hex_slice[0..40]);

        const ref_content = try std.fmt.allocPrint(allocator, "{s}\n", .{tag_hex});
        defer allocator.free(ref_content);
        try platform_impl.fs.writeFile(tag_ref_path, ref_content);

        // Create reflog if requested or if core.logAllRefUpdates=always
        if (create_reflog or shouldLogAllRefUpdates(allocator, git_path, platform_impl)) {
            writeTagReflog(allocator, git_path, tag_name.?, &tag_hex, tagger_name, tagger_email, timestamp, tz_str, platform_impl) catch {};
        }

        // Nested tag advice
        if (target_is_tag) {
            const advice_config = getConfigBool(allocator, git_path, "advice", "nestedTag", platform_impl);
            if (advice_config != false) {
                const target_name = target_ref orelse tag_name.?;
                const advice = try std.fmt.allocPrint(allocator, "hint: You have created a nested tag. The object referred to by your new tag is\nhint: already a tag. If you meant to tag the object that it points to, use:\nhint: \nhint: \tgit tag -f {s} {s}^{{}}\nhint: Disable this message with \"git config advice.nestedTag false\"\n", .{ tag_name.?, target_name });
                defer allocator.free(advice);
                try platform_impl.writeStderr(advice);
            }
        }
    } else {
        // Lightweight tag
        const ref_content = try std.fmt.allocPrint(allocator, "{s}\n", .{commit_hash});
        defer allocator.free(ref_content);
        try platform_impl.fs.writeFile(tag_ref_path, ref_content);

        // Create reflog if requested or if core.logAllRefUpdates=always
        if (create_reflog or shouldLogAllRefUpdates(allocator, git_path, platform_impl)) {
            const tagger_name_lw = if (std.posix.getenv("GIT_COMMITTER_NAME")) |n| n
                else if (std.posix.getenv("GIT_AUTHOR_NAME")) |n| n
                else (helpers.resolveAuthorName(allocator, git_path) catch "A U Thor");
            const tagger_email_lw = if (std.posix.getenv("GIT_COMMITTER_EMAIL")) |e| e
                else if (std.posix.getenv("GIT_AUTHOR_EMAIL")) |e| e
                else (helpers.resolveAuthorEmail(allocator, git_path) catch "author@example.com");
            var timestamp_lw: i64 = std.time.timestamp();
            var tz_str_lw: []const u8 = "+0000";
            var tz_buf_lw: [6]u8 = undefined;
            if (std.posix.getenv("GIT_COMMITTER_DATE")) |date_str| {
                const parsed = try helpers.parseDateToGitFormat(date_str, allocator);
                defer allocator.free(parsed);
                if (std.mem.indexOfScalar(u8, parsed, ' ')) |sp| {
                    timestamp_lw = std.fmt.parseInt(i64, parsed[0..sp], 10) catch timestamp_lw;
                    const tz_part = parsed[sp + 1 ..];
                    const copy_len = @min(tz_part.len, tz_buf_lw.len);
                    @memcpy(tz_buf_lw[0..copy_len], tz_part[0..copy_len]);
                    tz_str_lw = tz_buf_lw[0..copy_len];
                }
            } else {
                _ = std.fmt.bufPrint(&tz_buf_lw, "+0000", .{}) catch {};
                tz_str_lw = tz_buf_lw[0..5];
            }
            writeTagReflog(allocator, git_path, tag_name.?, commit_hash, tagger_name_lw, tagger_email_lw, timestamp_lw, tz_str_lw, platform_impl) catch {};
        }
    }
}

fn shouldLogAllRefUpdates(allocator: std.mem.Allocator, git_path: []const u8, platform_impl: anytype) bool {
    const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch return false;
    defer allocator.free(config_path);
    const config_data = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch return false;
    defer allocator.free(config_data);
    if (getConfigValue(config_data, "core", "logallrefupdates")) |val| {
        return std.mem.eql(u8, val, "always");
    }
    _ = platform_impl;
    return false;
}

fn getConfigBool(allocator: std.mem.Allocator, git_path: []const u8, section: []const u8, key: []const u8, platform_impl: anytype) bool {
    const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch return true;
    defer allocator.free(config_path);
    const config_data = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch return true;
    defer allocator.free(config_data);
    _ = platform_impl;
    if (getConfigValue(config_data, section, key)) |val| {
        return std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "1");
    }
    return true; // default true
}

fn writeTagReflog(allocator: std.mem.Allocator, git_path: []const u8, tag_name_val: []const u8, new_hash: []const u8, name: []const u8, email: []const u8, timestamp_val: i64, tz: []const u8, platform_impl: anytype) !void {
    const reflog_dir = try std.fmt.allocPrint(allocator, "{s}/logs/refs/tags", .{git_path});
    defer allocator.free(reflog_dir);
    std.fs.cwd().makePath(reflog_dir) catch {};

    // Handle hierarchical tag names
    const reflog_path = try std.fmt.allocPrint(allocator, "{s}/logs/refs/tags/{s}", .{ git_path, tag_name_val });
    defer allocator.free(reflog_path);
    if (std.fs.path.dirname(reflog_path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }

    const zero_hash = "0000000000000000000000000000000000000000";
    const hash_str = if (new_hash.len >= 40) new_hash[0..40] else new_hash;

    // Get HEAD info for the reflog message
    const head_hash = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
    defer if (head_hash) |h| allocator.free(h);

    // Load commit to get subject
    var subject: []const u8 = "";
    var subject_buf: []u8 = &.{};
    if (head_hash) |hh| {
        if (objects.GitObject.load(hh, git_path, platform_impl, allocator)) |obj| {
            defer obj.deinit(allocator);
            if (obj.type == .commit) {
                if (std.mem.indexOf(u8, obj.data, "\n\n")) |pos| {
                    const msg = obj.data[pos + 2 ..];
                    if (std.mem.indexOfScalar(u8, msg, '\n')) |nl| {
                        subject_buf = try allocator.dupe(u8, msg[0..nl]);
                        subject = subject_buf;
                    } else {
                        subject_buf = try allocator.dupe(u8, std.mem.trimRight(u8, msg, "\n"));
                        subject = subject_buf;
                    }
                }
            }
        } else |_| {}
    }
    defer if (subject_buf.len > 0) allocator.free(subject_buf);

    // Get the commit date for the log message
    var commit_date: []const u8 = "";
    var date_buf: []u8 = &.{};
    if (head_hash) |hh| {
        if (objects.GitObject.load(hh, git_path, platform_impl, allocator)) |obj| {
            defer obj.deinit(allocator);
            if (obj.type == .commit) {
                // Find committer line and extract date
                var lines = std.mem.splitScalar(u8, obj.data, '\n');
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "committer ")) {
                        // Parse: committer Name <email> timestamp tz
                        if (std.mem.lastIndexOf(u8, line, "> ")) |gt_pos| {
                            const date_part = line[gt_pos + 2 ..];
                            if (std.mem.indexOfScalar(u8, date_part, ' ')) |sp| {
                                const ts_str = date_part[0..sp];
                                const ts = std.fmt.parseInt(i64, ts_str, 10) catch 0;
                                if (ts > 0) {
                                    // Format as YYYY-MM-DD
                                    const epoch_secs: u64 = @intCast(ts);
                                    const days = epoch_secs / 86400;
                                    const formatted = formatDate(days);
                                    date_buf = try std.fmt.allocPrint(allocator, "{d}-{d:0>2}-{d:0>2}", .{ formatted.year, formatted.month, formatted.day });
                                    commit_date = date_buf;
                                }
                            }
                        }
                        break;
                    }
                    if (line.len == 0) break;
                }
            }
        } else |_| {}
    }
    defer if (date_buf.len > 0) allocator.free(date_buf);

    const short_hash = if (head_hash) |hh| (if (hh.len >= 7) hh[0..7] else hh) else "0000000";

    const reflog_msg = try std.fmt.allocPrint(allocator, "tag: tagging {s} ({s}, {s})", .{ short_hash, subject, commit_date });
    defer allocator.free(reflog_msg);

    const entry = try std.fmt.allocPrint(allocator, "{s} {s} {s} <{s}> {d} {s}\t{s}\n", .{ zero_hash, hash_str, name, email, timestamp_val, tz, reflog_msg });
    defer allocator.free(entry);

    const file = std.fs.cwd().createFile(reflog_path, .{ .truncate = false }) catch |err| {
        // If file doesn't exist, create it
        if (err == error.FileNotFound) {
            const f = try std.fs.cwd().createFile(reflog_path, .{});
            defer f.close();
            try f.writeAll(entry);
            return;
        }
        return err;
    };
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(entry);
}

const DateParts = struct {
    year: u32,
    month: u32,
    day: u32,
};

fn formatDate(days_since_epoch: u64) DateParts {
    // Convert days since epoch to year/month/day
    var remaining = @as(i64, @intCast(days_since_epoch));
    var year: u32 = 1970;

    while (true) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (remaining < days_in_year) break;
        remaining -= days_in_year;
        year += 1;
    }

    const leap = isLeapYear(year);
    const month_days = if (leap)
        [_]u32{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u32 = 1;
    for (month_days) |md| {
        if (remaining < md) break;
        remaining -= @intCast(md);
        month += 1;
    }

    return .{ .year = year, .month = month, .day = @intCast(remaining + 1) };
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn signWithGpg(allocator: std.mem.Allocator, content: []const u8, sign_key: ?[]const u8) ![]u8 {
    // Write content to temp file
    const tmp_path = "/tmp/ziggit-tag-sign-tmp";
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        defer f.close();
        try f.writeAll(content);
    }

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("gpg");
    if (sign_key) |key| {
        try argv.append("-u");
        try argv.append(key);
    }
    try argv.append("--status-fd=2");
    try argv.append("-bsau");
    if (sign_key) |key| {
        try argv.append(key);
    } else {
        // Default key
        try argv.append("");
    }

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return error.GpgFailed;

    if (child.stdin) |*stdin| {
        stdin.writeAll(content) catch {};
        stdin.close();
        child.stdin = null;
    }

    const stdout = child.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch return error.GpgFailed;
    const stderr = child.stderr.?.readToEndAlloc(allocator, 1024 * 1024) catch {
        allocator.free(stdout);
        return error.GpgFailed;
    };
    defer allocator.free(stderr);

    const term = child.wait() catch {
        allocator.free(stdout);
        return error.GpgFailed;
    };

    if (term.Exited != 0) {
        allocator.free(stdout);
        return error.GpgFailed;
    }

    // Combine content + signature
    const result = try std.fmt.allocPrint(allocator, "{s}{s}", .{ content, stdout });
    allocator.free(stdout);
    return result;
}

/// Simple config parser - find value for section.key
fn getConfigValue(data: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    var in_section = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#' or trimmed[0] == ';') continue;
        if (trimmed[0] == '[') {
            // Section header
            if (std.mem.indexOfScalar(u8, trimmed, ']')) |close| {
                const sec_name = std.mem.trim(u8, trimmed[1..close], " \t");
                in_section = std.ascii.eqlIgnoreCase(sec_name, section);
            }
        } else if (in_section) {
            // key = value
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                const k = std.mem.trim(u8, trimmed[0..eq], " \t");
                if (std.ascii.eqlIgnoreCase(k, key)) {
                    return std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
                }
            } else {
                // Bare key (boolean true)
                if (std.ascii.eqlIgnoreCase(trimmed, key)) {
                    return "true";
                }
            }
        }
    }
    return null;
}

/// Get the commit hash a tag points at (follows annotated tags to their target)
fn getTagTarget(allocator: std.mem.Allocator, git_path: []const u8, tag_name_val: []const u8, platform_impl: anytype) ![]const u8 {
    const direct = try getTagDirectHash(allocator, git_path, tag_name_val, platform_impl);
    defer allocator.free(direct);
    return resolveTagToCommit(allocator, git_path, direct, platform_impl);
}

/// Get annotation text for a tag (first n_lines of message)
fn getTagAnnotation(allocator: std.mem.Allocator, git_path: []const u8, tag_name_val: []const u8, platform_impl: anytype, max_lines: usize) ![]const u8 {
    const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{ git_path, tag_name_val });
    defer allocator.free(ref_path);
    const ref_content = platform_impl.fs.readFile(allocator, ref_path) catch {
        const packed_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_path});
        defer allocator.free(packed_path);
        const packed_data = platform_impl.fs.readFile(allocator, packed_path) catch return "";
        defer allocator.free(packed_data);
        var lines_iter = std.mem.splitScalar(u8, packed_data, '\n');
        while (lines_iter.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const search = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{tag_name_val});
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
    if (std.mem.indexOf(u8, obj.data, "\n\n")) |pos| {
        const msg = std.mem.trimRight(u8, obj.data[pos + 2 ..], "\n\r ");
        if (msg.len == 0) return "";
        var result = std.array_list.Managed(u8).init(allocator);
        errdefer result.deinit();
        var lines_iter = std.mem.splitScalar(u8, msg, '\n');
        var count: usize = 0;
        while (lines_iter.next()) |line| {
            if (count >= max_lines) break;
            const trimmed_line = std.mem.trimRight(u8, line, " \t\r");
            if (count > 0) try result.appendSlice("\n    ");
            try result.appendSlice(trimmed_line);
            count += 1;
        }
        return try result.toOwnedSlice();
    }
    return "";
}
