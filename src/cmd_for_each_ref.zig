// Auto-generated from main_common.zig - cmd_for_each_ref
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_show_ref = @import("cmd_show_ref.zig");
const cmd_push_impl = @import("cmd_push_impl.zig");

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

pub fn nativeCmdForEachRef(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var format: []const u8 = "%(objectname) %(objecttype)\t%(refname)";
    var sort_key: ?[]const u8 = null;
    var sort_reverse = false;
    var count_limit: ?usize = null;
    var quoting_style: enum { none, shell, perl, python, tcl } = .none;
    var patterns = std.array_list.Managed([]const u8).init(allocator);
    defer patterns.deinit();
    var exclude_patterns = std.array_list.Managed([]const u8).init(allocator);
    defer exclude_patterns.deinit();
    var omit_empty = false;
    var ignore_case = false;
    var use_stdin = false;
    var positional_count: usize = 0;

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
            const sk = arg["--sort=".len..];
            if (sk.len > 0 and sk[0] == '-') {
                sort_key = sk[1..];
                sort_reverse = true;
            } else {
                sort_key = sk;
                sort_reverse = false;
            }
        } else if (std.mem.eql(u8, arg, "--sort")) {
            i += 1;
            if (i < args.len) {
                const sk = args[i];
                if (sk.len > 0 and sk[0] == '-') {
                    sort_key = sk[1..];
                    sort_reverse = true;
                } else {
                    sort_key = sk;
                    sort_reverse = false;
                }
            }
        } else if (std.mem.startsWith(u8, arg, "--count=")) {
            count_limit = std.fmt.parseInt(usize, arg["--count=".len..], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--count")) {
            i += 1;
            if (i < args.len) count_limit = std.fmt.parseInt(usize, args[i], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--shell") or std.mem.eql(u8, arg, "-s")) {
            if (quoting_style != .none) {
                try platform_impl.writeStderr("error: more than one quoting style?\n");
                std.process.exit(1);
            }
            quoting_style = .shell;
        } else if (std.mem.eql(u8, arg, "--perl") or std.mem.eql(u8, arg, "-p")) {
            if (quoting_style != .none) {
                try platform_impl.writeStderr("error: more than one quoting style?\n");
                std.process.exit(1);
            }
            quoting_style = .perl;
        } else if (std.mem.eql(u8, arg, "--python")) {
            if (quoting_style != .none) {
                try platform_impl.writeStderr("error: more than one quoting style?\n");
                std.process.exit(1);
            }
            quoting_style = .python;
        } else if (std.mem.eql(u8, arg, "--tcl")) {
            if (quoting_style != .none) {
                try platform_impl.writeStderr("error: more than one quoting style?\n");
                std.process.exit(1);
            }
            quoting_style = .tcl;
        } else if (std.mem.startsWith(u8, arg, "--exclude=")) {
            try exclude_patterns.append(arg["--exclude=".len..]);
        } else if (std.mem.eql(u8, arg, "--exclude")) {
            i += 1;
            if (i < args.len) try exclude_patterns.append(args[i]);
        } else if (std.mem.eql(u8, arg, "--ignore-case")) {
            ignore_case = true;
        } else if (std.mem.eql(u8, arg, "--omit-empty")) {
            omit_empty = true;
        } else if (std.mem.eql(u8, arg, "--no-sort")) {
            sort_key = null;
            sort_reverse = false;
        } else if (std.mem.eql(u8, arg, "--color") or std.mem.startsWith(u8, arg, "--color=")) {
            // Accept silently
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            use_stdin = true;
            // helpers.Read patterns from stdin
            const stdin_data = read_stdin_blk: {
                var buf2 = std.array_list.Managed(u8).init(allocator);
                var tmp2: [4096]u8 = undefined;
                while (true) {
                    const n2 = std.posix.read(0, &tmp2) catch break;
                    if (n2 == 0) break;
                    buf2.appendSlice(tmp2[0..n2]) catch break;
                }
                break :read_stdin_blk buf2.toOwnedSlice() catch "";
            };
            defer if (stdin_data.len > 0) allocator.free(stdin_data);
            var stdin_lines = std.mem.splitScalar(u8, stdin_data, '\n');
            while (stdin_lines.next()) |line| {
                const trimmed2 = std.mem.trim(u8, line, " \t\r");
                if (trimmed2.len > 0) try patterns.append(trimmed2);
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try patterns.append(arg);
            positional_count += 1;
        }
    }

    // Validate --stdin + extra args
    if (use_stdin and positional_count > 0) {
        try platform_impl.writeStderr("fatal: unknown arguments supplied with --stdin\n");
        std.process.exit(129);
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // helpers.Validate format atoms
    {
        var vidx: usize = 0;
        while (vidx < format.len) {
            if (format[vidx] == '%' and vidx + 1 < format.len and format[vidx + 1] == '%') {
                vidx += 2;
                continue;
            }
            if (format[vidx] == '%' and vidx + 1 < format.len and format[vidx + 1] == '(') {
                if (std.mem.indexOfScalar(u8, format[vidx..], ')')) |close| {
                    const field = format[vidx + 2 .. vidx + close];
                    const validation = validateFormatAtom(field, allocator);
                    if (!validation.valid) {
                        if (validation.err_msg) |err_msg| {
                            defer allocator.free(err_msg);
                            try platform_impl.writeStderr(err_msg);
                        } else {
                            const msg = try std.fmt.allocPrint(allocator, "fatal: unknown field name: {s}\n", .{field});
                            defer allocator.free(msg);
                            try platform_impl.writeStderr(msg);
                        }
                        std.process.exit(1);
                    }
                    if (validation.err_msg) |err_msg| allocator.free(err_msg);
                    vidx += close + 1;
                    continue;
                }
            }
            vidx += 1;
        }
    }

    // helpers.Collect all helpers.refs
    var ref_list = std.array_list.Managed(helpers.RefEntry).init(allocator);
    defer {
        for (ref_list.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.hash);
        }
        ref_list.deinit();
    }

    // helpers.Read packed-helpers.refs
    const packed_refs_path = std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir}) catch unreachable;
    defer allocator.free(packed_refs_path);
    if (std.fs.cwd().readFileAlloc(allocator, packed_refs_path, 10 * 1024 * 1024)) |packed_content| {
        defer allocator.free(packed_content);
        // helpers.Check for unterminated last line
        if (packed_content.len > 0 and packed_content[packed_content.len - 1] != '\n') {
            // helpers.Find the last line
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
                if (hash.len < 40 or !helpers.isValidHexString(hash[0..@min(40, hash.len)])) {
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

    try helpers.collectLooseRefs(allocator, git_dir, "refs", &ref_list, platform_impl);

    // helpers.Sort
    if (sort_reverse) {
        std.mem.sort(helpers.RefEntry, ref_list.items, {}, struct {
            fn lessThan(_: void, a: helpers.RefEntry, b: helpers.RefEntry) bool {
                return std.mem.order(u8, a.name, b.name).compare(.gt);
            }
        }.lessThan);
    } else {
        std.mem.sort(helpers.RefEntry, ref_list.items, {}, struct {
            fn lessThan(_: void, a: helpers.RefEntry, b: helpers.RefEntry) bool {
                return std.mem.order(u8, a.name, b.name).compare(.lt);
            }
        }.lessThan);
    }

    // Filter and format output using buffered writes
    var output_count: usize = 0;
    var out_buf = std.array_list.Managed(u8).init(allocator);
    defer out_buf.deinit();
    for (ref_list.items) |entry| {
        if (count_limit) |limit| {
            if (output_count >= limit) break;
        }

        // helpers.Handle broken helpers.refs - emit warning and skip
        if (entry.broken) {
            const warn_msg = std.fmt.allocPrint(allocator, "warning: ignoring broken ref {s}\n", .{entry.name}) catch continue;
            defer allocator.free(warn_msg);
            try platform_impl.writeStderr(warn_msg);
            continue;
        }

        // helpers.Apply patterns (prefix match, with glob support for * and ?)
        if (patterns.items.len > 0) {
            var matches = false;
            for (patterns.items) |pattern| {
                const match = if (ignore_case)
                    refPatternMatchIgnoreCase(entry.name, pattern)
                else
                    helpers.refPatternMatch(entry.name, pattern);
                if (match) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
        }

        // helpers.Check exclude patterns
        if (exclude_patterns.items.len > 0) {
            var excluded = false;
            for (exclude_patterns.items) |excl_pattern| {
                const excl_match = if (ignore_case)
                    refPatternMatchIgnoreCase(entry.name, excl_pattern)
                else
                    helpers.refPatternMatch(entry.name, excl_pattern);
                if (excl_match) {
                    excluded = true;
                    break;
                }
            }
            if (excluded) continue;
        }

        // helpers.Determine object type
        var obj_type: []const u8 = "commit";
        var obj_data: []const u8 = "";
        var obj_loaded: ?objects.GitObject = null;
        defer if (obj_loaded) |ol| ol.deinit(allocator);

        // Fast path: infer type from ref path to avoid object loading
        // when the format only needs objectname/objecttype/refname
        const needs_data = formatNeedsObjectData(format);
        if (!needs_data) {
            // For branches, type is always commit
            if (std.mem.startsWith(u8, entry.name, "refs/heads/") or std.mem.startsWith(u8, entry.name, "refs/remotes/")) {
                obj_type = "commit";
            } else {
                // Use fast type-only lookup (reads pack header without decompression)
                if (objects.getObjectTypeOnly(entry.hash, git_dir, allocator)) |t| {
                    obj_type = t.toString();
                } else {
                    // Fall back to full load
                    if (objects.GitObject.load(entry.hash, git_dir, platform_impl, allocator)) |obj| {
                        obj_loaded = obj;
                        obj_type = obj.type.toString();
                        obj_data = obj.data;
                    } else |_| {}
                }
            }
        } else {
            if (objects.GitObject.load(entry.hash, git_dir, platform_impl, allocator)) |obj| {
                obj_loaded = obj;
                obj_type = obj.type.toString();
                obj_data = obj.data;
            } else |_| {}
        }

        {
            const formatted = try formatRefOutput(allocator, format, entry.name, entry.hash, obj_type, obj_data, quoting_style, entry.symref_target);
            defer allocator.free(formatted);
            if (omit_empty and formatted.len == 0) continue;
            try out_buf.appendSlice(formatted);
            try out_buf.append('\n');
        }
        output_count += 1;

        // Flush periodically to avoid excessive memory use
        if (out_buf.items.len > 64 * 1024) {
            try platform_impl.writeStdout(out_buf.items);
            out_buf.clearRetainingCapacity();
        }
    }
    // Flush remaining output
    if (out_buf.items.len > 0) {
        try platform_impl.writeStdout(out_buf.items);
    }
}


pub fn getRefField(field: []const u8, refname: []const u8, objectname: []const u8, objecttype: []const u8, data: []const u8, allocator: std.mem.Allocator, symref_target: ?[]const u8) []const u8 {
    // refname and refname: (trailing colon = same as bare refname)
    if (std.mem.eql(u8, field, "refname") or std.mem.eql(u8, field, "refname:")) return refname;
    if (std.mem.eql(u8, field, "refname:short")) {
        if (std.mem.startsWith(u8, refname, "refs/heads/")) return refname["refs/heads/".len..];
        if (std.mem.startsWith(u8, refname, "refs/tags/")) return refname["refs/tags/".len..];
        if (std.mem.startsWith(u8, refname, "refs/remotes/")) return refname["refs/remotes/".len..];
        return refname;
    }
    if (std.mem.startsWith(u8, field, "refname:lstrip=") or std.mem.startsWith(u8, field, "refname:strip=")) {
        const eq_pos = std.mem.indexOfScalar(u8, field, '=') orelse return refname;
        return helpers.applyLstrip(refname, field[eq_pos + 1 ..]);
    }
    if (std.mem.startsWith(u8, field, "refname:rstrip=")) {
        return helpers.applyRstrip(refname, field["refname:rstrip=".len..]);
    }

    if (std.mem.eql(u8, field, "objectname") or std.mem.eql(u8, field, "objectname:")) return objectname;
    if (std.mem.eql(u8, field, "objectname:short")) return if (objectname.len >= 7) objectname[0..7] else objectname;
    if (std.mem.startsWith(u8, field, "objectname:short=")) {
        const n = std.fmt.parseInt(usize, field["objectname:short=".len..], 10) catch return objectname;
        const len = @max(n, 1);
        return objectname[0..@min(len, objectname.len)];
    }
    if (std.mem.eql(u8, field, "objecttype")) return objecttype;

    if (std.mem.eql(u8, field, "objectsize")) {
        return std.fmt.allocPrint(allocator, "{d}", .{data.len}) catch return "";
    }
    if (std.mem.eql(u8, field, "objectsize:disk")) {
        return std.fmt.allocPrint(allocator, "{d}", .{data.len}) catch return "";
    }

    if (std.mem.eql(u8, field, "deltabase") or std.mem.eql(u8, field, "*deltabase")) {
        return "0000000000000000000000000000000000000000";
    }

    // tree field
    if (std.mem.startsWith(u8, field, "tree")) {
        if (!std.mem.eql(u8, objecttype, "commit")) return "";
        const tree_hash = helpers.extractHeaderField(data, "tree");
        if (tree_hash.len == 0) return "";
        if (std.mem.eql(u8, field, "tree") or std.mem.eql(u8, field, "tree:")) return tree_hash;
        if (std.mem.eql(u8, field, "tree:short")) return if (tree_hash.len >= 7) tree_hash[0..7] else tree_hash;
        if (std.mem.startsWith(u8, field, "tree:short=")) {
            const n = std.fmt.parseInt(usize, field["tree:short=".len..], 10) catch return tree_hash;
            return tree_hash[0..@min(@max(n, 1), tree_hash.len)];
        }
        return tree_hash;
    }

    // parent field
    if (std.mem.startsWith(u8, field, "parent")) {
        if (!std.mem.eql(u8, objecttype, "commit")) return "";
        const first_parent = helpers.extractHeaderField(data, "parent");
        if (std.mem.eql(u8, field, "parent") or std.mem.eql(u8, field, "parent:")) return first_parent;
        if (std.mem.eql(u8, field, "parent:short")) return if (first_parent.len >= 7) first_parent[0..7] else first_parent;
        if (std.mem.startsWith(u8, field, "parent:short=")) {
            const n = std.fmt.parseInt(usize, field["parent:short=".len..], 10) catch return first_parent;
            if (first_parent.len == 0) return first_parent;
            return first_parent[0..@min(@max(n, 1), first_parent.len)];
        }
        return first_parent;
    }

    if (std.mem.eql(u8, field, "numparent")) {
        if (!std.mem.eql(u8, objecttype, "commit")) return "";
        var count: usize = 0;
        var lines_iter = std.mem.splitScalar(u8, data, '\n');
        while (lines_iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) count += 1
            else if (line.len == 0) break;
        }
        return std.fmt.allocPrint(allocator, "{d}", .{count}) catch return "0";
    }

    // author fields
    if (std.mem.startsWith(u8, field, "author")) {
        if (!std.mem.eql(u8, objecttype, "commit")) return "";
        return helpers.extractPersonField(field["author".len..], helpers.extractHeaderField(data, "author"), allocator);
    }

    // committer fields
    if (std.mem.startsWith(u8, field, "committer")) {
        if (!std.mem.eql(u8, objecttype, "commit")) return "";
        return helpers.extractPersonField(field["committer".len..], helpers.extractHeaderField(data, "committer"), allocator);
    }

    // tagger fields
    if (std.mem.startsWith(u8, field, "tagger")) {
        if (!std.mem.eql(u8, objecttype, "tag")) return "";
        return helpers.extractPersonField(field["tagger".len..], helpers.extractHeaderField(data, "tagger"), allocator);
    }

    if (std.mem.eql(u8, field, "tag")) {
        if (!std.mem.eql(u8, objecttype, "tag")) return "";
        return helpers.extractHeaderField(data, "tag");
    }
    if (std.mem.eql(u8, field, "type")) {
        if (!std.mem.eql(u8, objecttype, "tag")) return "";
        return helpers.extractHeaderField(data, "type");
    }
    if (std.mem.eql(u8, field, "object")) {
        if (!std.mem.eql(u8, objecttype, "tag")) return "";
        return helpers.extractHeaderField(data, "object");
    }
    if (std.mem.eql(u8, field, "*objectname")) {
        if (!std.mem.eql(u8, objecttype, "tag")) return "";
        return helpers.extractHeaderField(data, "object");
    }
    if (std.mem.eql(u8, field, "*objecttype")) {
        if (!std.mem.eql(u8, objecttype, "tag")) return "";
        return helpers.extractHeaderField(data, "type");
    }

    if (std.mem.eql(u8, field, "raw")) return data;
    if (std.mem.eql(u8, field, "*raw")) return "";

    if (std.mem.eql(u8, field, "creator")) {
        if (std.mem.eql(u8, objecttype, "commit")) return helpers.extractHeaderField(data, "committer")
        else if (std.mem.eql(u8, objecttype, "tag")) return helpers.extractHeaderField(data, "tagger");
        return "";
    }
    if (std.mem.eql(u8, field, "creatordate")) {
        const pl = if (std.mem.eql(u8, objecttype, "commit")) helpers.extractHeaderField(data, "committer")
        else if (std.mem.eql(u8, objecttype, "tag")) helpers.extractHeaderField(data, "tagger")
        else "";
        if (pl.len == 0) return "";
        return helpers.formatPersonDate(pl, allocator);
    }

    if (std.mem.eql(u8, field, "subject")) {
        const message = helpers.extractObjectMessage(data);
        const without_sig = helpers.extractMessageWithoutSignature(message);
        const clean_msg = helpers.stripCR(allocator, without_sig) catch without_sig;
        return helpers.joinLines(allocator, helpers.extractSubject(clean_msg)) catch helpers.extractSubject(clean_msg);
    }
    if (std.mem.eql(u8, field, "subject:sanitize")) {
        const message = helpers.extractObjectMessage(data);
        const without_sig = helpers.extractMessageWithoutSignature(message);
        const clean_msg = helpers.stripCR(allocator, without_sig) catch without_sig;
        const joined = helpers.joinLines(allocator, helpers.extractSubject(clean_msg)) catch helpers.extractSubject(clean_msg);
        return helpers.sanitizeSubject(allocator, joined) catch joined;
    }

    if (std.mem.eql(u8, field, "body")) {
        const message = helpers.extractObjectMessage(data);
        return helpers.extractBody(message);
    }

    if (std.mem.eql(u8, field, "HEAD")) {
        const git_dir = helpers.findGitDir() catch return " ";
        const head_path = std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir}) catch return " ";
        defer allocator.free(head_path);
        const head_content = std.fs.cwd().readFileAlloc(allocator, head_path, 4096) catch return " ";
        defer allocator.free(head_content);
        const trimmed = std.mem.trimRight(u8, head_content, "\n\r ");
        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            if (std.mem.eql(u8, trimmed["ref: ".len..], refname)) return "*" else return " ";
        }
        return " ";
    }

    if (std.mem.startsWith(u8, field, "upstream")) {
        const upstream_ref = helpers.resolveUpstreamRef(refname, allocator) catch return "";
        if (upstream_ref.len == 0) return "";
        if (std.mem.eql(u8, field, "upstream")) return upstream_ref;
        if (std.mem.eql(u8, field, "upstream:short")) {
            if (std.mem.startsWith(u8, upstream_ref, "refs/remotes/")) return upstream_ref["refs/remotes/".len..];
            return upstream_ref;
        }
        if (std.mem.startsWith(u8, field, "upstream:lstrip=") or std.mem.startsWith(u8, field, "upstream:strip=")) {
            const eq = std.mem.indexOfScalar(u8, field, '=') orelse return upstream_ref;
            return helpers.applyLstrip(upstream_ref, field[eq + 1 ..]);
        }
        if (std.mem.startsWith(u8, field, "upstream:rstrip=")) {
            return helpers.applyRstrip(upstream_ref, field["upstream:rstrip=".len..]);
        }
        // track/trackshort/nobracket - return empty for now
        return "";
    }
    if (std.mem.startsWith(u8, field, "push")) {
        const push_ref = cmd_push_impl.resolvePushRef(refname, allocator) catch return "";
        if (push_ref.len == 0) return "";
        if (std.mem.eql(u8, field, "push")) return push_ref;
        if (std.mem.eql(u8, field, "push:short")) {
            if (std.mem.startsWith(u8, push_ref, "refs/remotes/")) return push_ref["refs/remotes/".len..];
            return push_ref;
        }
        if (std.mem.startsWith(u8, field, "push:lstrip=") or std.mem.startsWith(u8, field, "push:strip=")) {
            const eq = std.mem.indexOfScalar(u8, field, '=') orelse return push_ref;
            return helpers.applyLstrip(push_ref, field[eq + 1 ..]);
        }
        if (std.mem.startsWith(u8, field, "push:rstrip=")) {
            return helpers.applyRstrip(push_ref, field["push:rstrip=".len..]);
        }
        return "";
    }

    // Handle trailers atom
    if (std.mem.eql(u8, field, "trailers") or std.mem.startsWith(u8, field, "trailers:")) {
        const message = helpers.extractObjectMessage(data);
        const raw_trailers = helpers.extractTrailers(message);
        if (raw_trailers.len == 0) return "";
        const options = if (std.mem.startsWith(u8, field, "trailers:")) field["trailers:".len..] else "";
        return helpers.formatTrailers(allocator, raw_trailers, options) catch return "";
    }

    if (std.mem.startsWith(u8, field, "contents")) {
        // contents atoms only apply to commits and tags
        if (!std.mem.eql(u8, objecttype, "commit") and !std.mem.eql(u8, objecttype, "tag")) return "";
        const message = helpers.extractObjectMessage(data);
        if (std.mem.eql(u8, field, "contents")) return message
        else if (std.mem.eql(u8, field, "contents:subject")) {
            const without_sig = helpers.extractMessageWithoutSignature(message);
            const clean_msg = helpers.stripCR(allocator, without_sig) catch without_sig;
            return helpers.joinLines(allocator, helpers.extractSubject(clean_msg)) catch helpers.extractSubject(clean_msg);
        } else if (std.mem.eql(u8, field, "contents:body")) {
            // contents:body is the body WITHOUT the signature
            const without_sig = helpers.extractMessageWithoutSignature(message);
            return helpers.extractBody(without_sig);
        } else if (std.mem.eql(u8, field, "contents:signature")) {
            return helpers.extractSignature(message);
        } else if (std.mem.eql(u8, field, "contents:size")) {
            return std.fmt.allocPrint(allocator, "{d}", .{message.len}) catch return "0";
        } else if (std.mem.eql(u8, field, "contents:trailers") or std.mem.startsWith(u8, field, "contents:trailers:")) {
            const raw_trailers = helpers.extractTrailers(message);
            if (raw_trailers.len == 0) return "";
            const options = if (std.mem.startsWith(u8, field, "contents:trailers:")) field["contents:trailers:".len..] else "";
            return helpers.formatTrailers(allocator, raw_trailers, options) catch return "";
        }
    }

    // Handle symref atom
    if (std.mem.eql(u8, field, "symref")) {
        return symref_target orelse "";
    }
    if (std.mem.eql(u8, field, "symref:short")) {
        const target = symref_target orelse return "";
        if (std.mem.startsWith(u8, target, "refs/heads/")) return target["refs/heads/".len..];
        if (std.mem.startsWith(u8, target, "refs/tags/")) return target["refs/tags/".len..];
        if (std.mem.startsWith(u8, target, "refs/remotes/")) return target["refs/remotes/".len..];
        return target;
    }
    if (std.mem.startsWith(u8, field, "symref:lstrip=") or std.mem.startsWith(u8, field, "symref:strip=")) {
        const target = symref_target orelse return "";
        const eq_pos = std.mem.indexOfScalar(u8, field, '=') orelse return target;
        return helpers.applyLstrip(target, field[eq_pos + 1 ..]);
    }
    if (std.mem.startsWith(u8, field, "symref:rstrip=")) {
        const target = symref_target orelse return "";
        return helpers.applyRstrip(target, field["symref:rstrip=".len..]);
    }

    return "";
}



pub fn formatRefOutput(allocator: std.mem.Allocator, format: []const u8, refname: []const u8, objectname: []const u8, objecttype: []const u8, data: []const u8, quoting: anytype, symref_target: ?[]const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    var idx: usize = 0;
    while (idx < format.len) {
        if (format[idx] == '%' and idx + 1 < format.len and format[idx + 1] == '(') {
            if (std.mem.indexOfScalar(u8, format[idx..], ')')) |close| {
                const field = format[idx + 2 .. idx + close];
                const value = getRefField(field, refname, objectname, objecttype, data, allocator, symref_target);
                // helpers.Apply quoting
                switch (quoting) {
                    .shell => {
                        try result.append('\'');
                        for (value) |c| {
                            if (c == '\'') {
                                try result.appendSlice("'\\''");
                            } else {
                                try result.append(c);
                            }
                        }
                        try result.append('\'');
                    },
                    .perl => {
                        try result.append('\'');
                        for (value) |c| {
                            if (c == '\'') {
                                try result.appendSlice("'\\''");
                            } else {
                                try result.append(c);
                            }
                        }
                        try result.append('\'');
                    },
                    .python => {
                        try result.append('\'');
                        for (value) |c| {
                            if (c == '\'') {
                                try result.appendSlice("'\\''");
                            } else {
                                try result.append(c);
                            }
                        }
                        try result.append('\'');
                    },
                    .tcl => {
                        try result.append('"');
                        for (value) |c| {
                            if (c == '"' or c == '\\' or c == '$' or c == '[' or c == ']' or c == '{' or c == '}') {
                                try result.append('\\');
                            }
                            try result.append(c);
                        }
                        try result.append('"');
                    },
                    .none => {
                        try result.appendSlice(value);
                    },
                }
                idx += close + 1;
                continue;
            }
        }
        if (format[idx] == '%' and idx + 1 < format.len and format[idx + 1] == '%') {
            try result.append('%');
            idx += 2;
        } else {
            try result.append(format[idx]);
            idx += 1;
        }
    }
    return result.toOwnedSlice();
}


pub fn validateFormatAtom(field: []const u8, allocator: std.mem.Allocator) helpers.FormatAtomError {
    const valid_atoms = [_][]const u8{
        "refname", "objectname", "objecttype", "objectsize", "deltabase",
        "tree", "parent", "numparent", "object", "type", "tag",
        "author", "authorname", "authoremail", "authordate",
        "committer", "committername", "committeremail", "committerdate",
        "tagger", "taggername", "taggeremail", "taggerdate",
        "creator", "creatordate",
        "subject", "body", "contents", "raw", "HEAD",
        "upstream", "push", "*objectname", "*objecttype", "*raw", "*deltabase",
        "*objectsize", "if", "then", "else", "end", "align", "color",
        "ahead-behind", "describe", "rest", "trailers", "signature",
        "symref", "worktreepath", "flag", "path",
    };
    var matched_atom: ?[]const u8 = null;
    for (valid_atoms) |atom| {
        if (std.mem.eql(u8, field, atom)) {
            // rest atom is only valid in cat-file --batch context, not for-each-ref
            if (std.mem.eql(u8, field, "rest")) {
                const msg = std.fmt.allocPrint(allocator, "fatal: %(rest) atom used in --format option is not allowed in this context\n", .{}) catch return .{ .valid = false };
                return .{ .valid = false, .err_msg = msg };
            }
            return .{ .valid = true };
        }
        if (std.mem.startsWith(u8, field, atom) and field.len > atom.len and field[atom.len] == ':') {
            matched_atom = atom;
            break;
        }
    }
    if (matched_atom == null) return .{ .valid = false };
    const atom = matched_atom.?;
    const options = field[atom.len + 1 ..];
    const email_atoms = [_][]const u8{ "authoremail", "committeremail", "taggeremail" };
    for (email_atoms) |ea| {
        if (std.mem.eql(u8, atom, ea)) return helpers.validateEmailOptions(ea, options, allocator);
    }
    const date_atoms = [_][]const u8{ "authordate", "committerdate", "taggerdate", "creatordate" };
    for (date_atoms) |da| {
        if (std.mem.eql(u8, atom, da)) return helpers.validateDateOptions(options);
    }
    if (std.mem.eql(u8, atom, "objectname") or std.mem.eql(u8, atom, "*objectname")) return helpers.validateObjectnameOptions(options);
    if (std.mem.eql(u8, atom, "refname")) {
        const rv = helpers.validateRefnameOptions(options);
        if (!rv.valid) {
            const msg = std.fmt.allocPrint(allocator, "fatal: unrecognized %(refname) argument: {s}\n", .{options}) catch return .{ .valid = false };
            return .{ .valid = false, .err_msg = msg };
        }
        return rv;
    }
    if (std.mem.eql(u8, atom, "trailers")) return validateTrailerOptions(options, allocator);
    if (std.mem.eql(u8, atom, "contents")) {
        // Validate contents sub-options
        if (std.mem.startsWith(u8, options, "trailers:")) {
            return validateTrailerOptions(options["trailers:".len..], allocator);
        }
        if (std.mem.eql(u8, options, "trailers") or
            std.mem.eql(u8, options, "subject") or
            std.mem.eql(u8, options, "body") or
            std.mem.eql(u8, options, "signature") or
            std.mem.eql(u8, options, "size"))
        {
            return .{ .valid = true };
        }
        // Unknown contents option
        const msg = std.fmt.allocPrint(allocator, "fatal: unrecognized %(contents) argument: {s}\n", .{options}) catch return .{ .valid = false };
        return .{ .valid = false, .err_msg = msg };
    }
    if (std.mem.eql(u8, atom, "subject")) {
        if (std.mem.eql(u8, options, "sanitize")) return .{ .valid = true };
        const msg = std.fmt.allocPrint(allocator, "fatal: unrecognized %(subject) argument: {s}\n", .{options}) catch return .{ .valid = false };
        return .{ .valid = false, .err_msg = msg };
    }
    if (std.mem.eql(u8, atom, "HEAD")) {
        const msg = std.fmt.allocPrint(allocator, "fatal: %(HEAD) does not take arguments\n", .{}) catch return .{ .valid = false };
        return .{ .valid = false, .err_msg = msg };
    }
    if (std.mem.eql(u8, atom, "rest")) {
        const msg = std.fmt.allocPrint(allocator, "fatal: %(rest) does not take arguments, use %(trailers) instead\n", .{}) catch return .{ .valid = false };
        return .{ .valid = false, .err_msg = msg };
    }
    return .{ .valid = true };
}

fn validateTrailerOptions(options: []const u8, allocator: std.mem.Allocator) helpers.FormatAtomError {
    const valid_trailer_opts = [_][]const u8{ "unfold", "only", "valueonly", "key", "separator", "key_value_separator" };
    var opts_iter = std.mem.splitScalar(u8, options, ',');
    while (opts_iter.next()) |opt| {
        const trimmed = std.mem.trim(u8, opt, " \t");
        if (trimmed.len == 0) continue;
        // Extract the option name (before =)
        const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=');
        const opt_name = if (eq_pos) |p| trimmed[0..p] else trimmed;
        var found = false;
        for (valid_trailer_opts) |valid_opt| {
            if (std.mem.eql(u8, opt_name, valid_opt)) {
                found = true;
                break;
            }
        }
        if (!found) {
            const msg = std.fmt.allocPrint(allocator, "fatal: unknown %(trailers) argument: {s}\n", .{opt_name}) catch return .{ .valid = false };
            return .{ .valid = false, .err_msg = msg };
        }
        // Check that 'key' has a value
        if (std.mem.eql(u8, opt_name, "key") and eq_pos == null) {
            const msg = std.fmt.allocPrint(allocator, "fatal: expected %(trailers:key=<value>)\n", .{}) catch return .{ .valid = false };
            return .{ .valid = false, .err_msg = msg };
        }
    }
    return .{ .valid = true };
}


/// Check if a format string requires loading the full object data.
/// Fields like objectname, objecttype, refname only need the hash and ref info.
/// Fields like author, committer, subject, body, tree, parent, contents need data.
fn formatNeedsObjectData(format: []const u8) bool {
    var idx: usize = 0;
    while (idx < format.len) {
        if (format[idx] == '%' and idx + 1 < format.len and format[idx + 1] == '(') {
            if (std.mem.indexOfScalar(u8, format[idx..], ')')) |close| {
                const field = format[idx + 2 .. idx + close];
                // These fields don't need object data
                if (std.mem.startsWith(u8, field, "refname") or
                    std.mem.startsWith(u8, field, "objectname") or
                    std.mem.eql(u8, field, "objecttype") or
                    std.mem.startsWith(u8, field, "symref") or
                    std.mem.eql(u8, field, "HEAD") or
                    std.mem.startsWith(u8, field, "upstream") or
                    std.mem.startsWith(u8, field, "push") or
                    std.mem.eql(u8, field, "objectsize") or
                    std.mem.eql(u8, field, "objectsize:disk") or
                    std.mem.eql(u8, field, "deltabase") or
                    std.mem.eql(u8, field, "*deltabase"))
                {
                    idx += close + 1;
                    continue;
                }
                // Any other field needs object data
                return true;
            }
        }
        idx += 1;
    }
    return false;
}

fn refPatternMatchIgnoreCase(name: []const u8, pattern: []const u8) bool {
    // Case-insensitive prefix match (for ref patterns)
    // Convert both to lowercase for comparison
    const name_lower = std.ascii.allocLowerString(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(name_lower);
    const pattern_lower = std.ascii.allocLowerString(std.heap.page_allocator, pattern) catch return false;
    defer std.heap.page_allocator.free(pattern_lower);
    return helpers.refPatternMatch(name_lower, pattern_lower);
}

pub fn isValidFormatAtom(field: []const u8) bool {
    const result = validateFormatAtom(field, std.heap.page_allocator);
    if (result.err_msg) |msg| std.heap.page_allocator.free(msg);
    return result.valid;
}
