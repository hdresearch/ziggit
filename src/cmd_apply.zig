// Auto-generated from main_common.zig - cmd_apply
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

pub fn nativeCmdApply(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var check_only = false;
    var stat_only = false;
    var summary_only = false;
    var numstat_flag = false;
    var reverse = false;
    var cached = false;
    var index_flag = false;
    var apply_flag = true; // default is to apply
    var recount = false;
    var allow_empty = false;
    var verbose = false;
    var p_value: u32 = 1;
    var patch_files = std.ArrayList([]const u8).init(allocator);
    defer patch_files.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        } else if (std.mem.eql(u8, arg, "--stat")) {
            stat_only = true;
            apply_flag = false;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            summary_only = true;
            apply_flag = false;
        } else if (std.mem.eql(u8, arg, "--numstat")) {
            numstat_flag = true;
            apply_flag = false;
        } else if (std.mem.eql(u8, arg, "-R") or std.mem.eql(u8, arg, "--reverse")) {
            reverse = true;
        } else if (std.mem.eql(u8, arg, "--cached")) {
            cached = true;
        } else if (std.mem.eql(u8, arg, "--index")) {
            index_flag = true;
        } else if (std.mem.eql(u8, arg, "--apply")) {
            apply_flag = true;
        } else if (std.mem.eql(u8, arg, "--recount")) {
            recount = true;
        } else if (std.mem.eql(u8, arg, "--allow-empty")) {
            allow_empty = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.startsWith(u8, arg, "-p")) {
            if (arg.len > 2) {
                p_value = std.fmt.parseInt(u32, arg[2..], 10) catch 1;
            } else if (args.next()) |next| {
                p_value = std.fmt.parseInt(u32, next, 10) catch 1;
            }
        } else if (std.mem.eql(u8, arg, "--no-add") or
            std.mem.eql(u8, arg, "--binary") or
            std.mem.eql(u8, arg, "--3way") or std.mem.eql(u8, arg, "-3") or
            std.mem.eql(u8, arg, "--reject") or
            std.mem.eql(u8, arg, "--unidiff-zero") or
            std.mem.eql(u8, arg, "--allow-overlap") or
            std.mem.eql(u8, arg, "--inaccurate-eof") or
            std.mem.eql(u8, arg, "--unsafe-paths"))
        {
            // Accept known flags
        } else if (std.mem.startsWith(u8, arg, "--whitespace=") or
            std.mem.startsWith(u8, arg, "--directory=") or
            std.mem.startsWith(u8, arg, "--exclude=") or
            std.mem.startsWith(u8, arg, "--include="))
        {
            // Accept known flags with values
        } else if (std.mem.eql(u8, arg, "--whitespace") or
            std.mem.eql(u8, arg, "--directory") or
            std.mem.eql(u8, arg, "--exclude") or
            std.mem.eql(u8, arg, "--include"))
        {
            _ = args.next();
        } else if (std.mem.eql(u8, arg, "-")) {
            // helpers.Read from stdin
            try patch_files.append("-");
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try patch_files.append(arg);
        }
    }

    _ = &cached;
    _ = &index_flag;
    _ = &recount;

    // helpers.Read patch content
    var all_patch_data = std.ArrayList(u8).init(allocator);
    defer all_patch_data.deinit();

    if (patch_files.items.len == 0) {
        // helpers.Read from stdin
        const stdin_data = helpers.readStdin(allocator, 100 * 1024 * 1024) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "error: reading stdin: {}\n", .{err});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        defer allocator.free(stdin_data);
        try all_patch_data.appendSlice(stdin_data);
    } else {
        for (patch_files.items) |pf| {
            if (std.mem.eql(u8, pf, "-")) {
                const stdin_data = helpers.readStdin(allocator, 100 * 1024 * 1024) catch continue;
                defer allocator.free(stdin_data);
                try all_patch_data.appendSlice(stdin_data);
            } else {
                const data = platform_impl.fs.readFile(allocator, pf) catch |err| {
                    const msg = try std.fmt.allocPrint(allocator, "error: can't open patch '{s}': {}\n", .{ pf, err });
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                };
                defer allocator.free(data);
                try all_patch_data.appendSlice(data);
            }
        }
    }

    // helpers.Parse patches
    var corrupt_line: usize = 0;
    var patches = parsePatchSet(allocator, all_patch_data.items, p_value, &corrupt_line) catch |err| {
        if (err == error.InvalidPatch) {
            try platform_impl.writeStderr("error: invalid combination in patch header\n");
            std.process.exit(128);
        }
        if (err == error.CorruptPatch) {
            const msg = try std.fmt.allocPrint(allocator, "error: corrupt patch at line {d}\n", .{corrupt_line});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        }
        const msg = try std.fmt.allocPrint(allocator, "error: patch parsing failed: {}\n", .{err});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    };
    defer {
        for (patches.items) |*p| p.deinit(allocator);
        patches.deinit();
    }

    if (patches.items.len == 0 and !stat_only and !numstat_flag and !summary_only) {
        if (allow_empty) return; // --allow-empty: empty patch is OK
        // helpers.No patches found - could be unrecognized input
        try platform_impl.writeStderr("error: unrecognized input\n");
        std.process.exit(128);
    }

    // helpers.Validate patches
    for (patches.items) |*p| {
        // helpers.Check for invalid combinations
        if (p.is_new_file) {
            // new file + copy/rename is invalid - check if it was parsed as such
            // (handled during parsing but verify here for edge cases)
        }

        // helpers.Check for no-op patches (only context, no adds/removes) unless --recount
        if (!recount) {
            var has_changes = false;
            for (p.hunks.items) |h| {
                for (h.lines.items) |l| {
                    if (l.line_type == .add or l.line_type == .remove) {
                        has_changes = true;
                        break;
                    }
                }
                if (has_changes) break;
            }
            if (!has_changes and p.hunks.items.len > 0 and !p.is_new_file and !p.is_delete) {
                const path = p.new_path orelse p.old_path orelse "unknown";
                const msg = try std.fmt.allocPrint(allocator, "error: helpers.No changes in patch for {s}\n", .{path});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }
        }
    }

    // helpers.Handle stat/numstat/summary output modes (collect all then output)
    if (stat_only or numstat_flag or summary_only) {
        if (stat_only) {
            try helpers.outputAllPatchStats(allocator, patches.items, platform_impl);
        }
        if (numstat_flag) {
            for (patches.items) |*patch| {
                try helpers.outputPatchNumstat(allocator, patch, platform_impl);
            }
        }
        if (summary_only or stat_only) {
            for (patches.items) |*patch| {
                try helpers.outputPatchSummary(allocator, patch, platform_impl);
            }
        }
        return;
    }

    // helpers.Apply or check each patch
    for (patches.items) |*patch| {

        if (check_only) {
            // helpers.Just verify the patch can apply
            _ = helpers.applyOnePatch(allocator, patch, reverse, true, platform_impl) catch |err| {
                if (err == error.PatchAlreadyApplied and recount) {
                    // --recount allows no-op patches
                    continue;
                }
                const msg = try std.fmt.allocPrint(allocator, "error: patch failed: {s}: {}\n", .{ patch.new_path orelse patch.old_path orelse "unknown", err });
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
            };
        } else if (apply_flag) {
            _ = helpers.applyOnePatch(allocator, patch, reverse, false, platform_impl) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "error: patch failed: {s}: {}\n", .{ patch.new_path orelse patch.old_path orelse "unknown", err });
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
            };
            if (verbose) {
                const path = patch.new_path orelse patch.old_path orelse "unknown";
                const msg = try std.fmt.allocPrint(allocator, "Applying: {s}\n", .{path});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            }
        }
    }
}

// Restored from original main_common.zig
pub fn parsePatchSet(allocator: std.mem.Allocator, data: []const u8, p_value: u32, corrupt_line: *usize) !std.ArrayList(helpers.Patch) {
    var patches = std.ArrayList(helpers.Patch).init(allocator);
    var lines_iter = std.mem.splitScalar(u8, data, '\n');
    var lines = std.ArrayList([]const u8).init(allocator);
    defer lines.deinit();
    while (lines_iter.next()) |line| try lines.append(line);

    var i: usize = 0;
    while (i < lines.items.len) {
        // Look for "diff --git" or "---" header
        const line = lines.items[i];
        if (std.mem.startsWith(u8, line, "diff --git ") or std.mem.startsWith(u8, line, "diff -")) {
            const saved_i = i;
            var patch = parseSinglePatch(allocator, lines.items, &i, p_value) catch |err| {
                if (err == error.CorruptPatch) {
                    corrupt_line.* = i + 1; // 1-indexed
                }
                return err;
            };
            _ = saved_i;
            _ = &patch;
            try patches.append(patch);
        } else if (std.mem.startsWith(u8, line, "--- ") and i + 1 < lines.items.len and std.mem.startsWith(u8, lines.items[i + 1], "+++ ")) {
            // Traditional diff format without "diff --git" header
            var patch = parseTraditionalPatch(allocator, lines.items, &i, p_value) catch |err| {
                if (err == error.CorruptPatch) {
                    corrupt_line.* = i + 1;
                }
                return err;
            };
            _ = &patch;
            try patches.append(patch);
        } else {
            i += 1;
        }
    }
    return patches;
}


const Patch = helpers.Patch;
const PatchLine = helpers.PatchLine;
const PatchLineType = helpers.PatchLineType;
const PatchHunk = helpers.PatchHunk;

pub fn parseSinglePatch(allocator: std.mem.Allocator, lines: []const []const u8, pos: *usize, p_value: u32) !Patch {
    var patch = Patch{
        .old_path = null,
        .new_path = null,
        .is_new_file = false,
        .is_delete = false,
        .new_mode = null,
        .old_mode = null,
        .is_binary = false,
        .hunks = std.ArrayList(PatchHunk).init(allocator),
        .added = 0,
        .removed = 0,
    };

    // Parse "diff --git a/path b/path"
    const diff_line = lines[pos.*];
    if (std.mem.startsWith(u8, diff_line, "diff --git ")) {
        const rest = diff_line["diff --git ".len..];
        // Find the separator " b/" - tricky because paths can have spaces
        if (std.mem.indexOf(u8, rest, " b/")) |bpos| {
            const a_path = rest[0..bpos];
            const b_path = rest[bpos + 1 ..];
            patch.old_path = try allocator.dupe(u8, stripPath(a_path, p_value));
            patch.new_path = try allocator.dupe(u8, stripPath(b_path, p_value));
        }
    }
    pos.* += 1;

    // Parse extended header lines
    while (pos.* < lines.len) {
        const line = lines[pos.*];
        if (std.mem.startsWith(u8, line, "new file mode ")) {
            patch.is_new_file = true;
            patch.new_mode = std.fmt.parseInt(u32, std.mem.trim(u8, line["new file mode ".len..], " \t\r"), 8) catch null;
            pos.* += 1;
        } else if (std.mem.startsWith(u8, line, "deleted file mode ")) {
            patch.is_delete = true;
            pos.* += 1;
        } else if (std.mem.startsWith(u8, line, "old mode ")) {
            patch.old_mode = std.fmt.parseInt(u32, std.mem.trim(u8, line["old mode ".len..], " \t\r"), 8) catch null;
            pos.* += 1;
        } else if (std.mem.startsWith(u8, line, "new mode ")) {
            patch.new_mode = std.fmt.parseInt(u32, std.mem.trim(u8, line["new mode ".len..], " \t\r"), 8) catch null;
            pos.* += 1;
        } else if (std.mem.startsWith(u8, line, "index ")) {
            pos.* += 1;
        } else if (std.mem.startsWith(u8, line, "similarity index") or
            std.mem.startsWith(u8, line, "dissimilarity index") or
            std.mem.startsWith(u8, line, "rename from ") or
            std.mem.startsWith(u8, line, "rename to ") or
            std.mem.startsWith(u8, line, "copy from ") or
            std.mem.startsWith(u8, line, "copy to "))
        {
            // Detect invalid combination: new file + copy/rename
            if (patch.is_new_file and (std.mem.startsWith(u8, line, "rename from ") or
                std.mem.startsWith(u8, line, "copy from ") or
                std.mem.startsWith(u8, line, "rename to ") or
                std.mem.startsWith(u8, line, "copy to ")))
            {
                return error.InvalidPatch;
            }
            if (std.mem.startsWith(u8, line, "rename from ")) {
                patch.is_rename = true;
            } else if (std.mem.startsWith(u8, line, "copy from ")) {
                patch.is_copy = true;
            } else if (std.mem.startsWith(u8, line, "similarity index ")) {
                const pct = std.mem.trim(u8, line["similarity index ".len..], " \t\r%");
                patch.similarity = std.fmt.parseInt(u32, pct, 10) catch null;
            } else if (std.mem.startsWith(u8, line, "dissimilarity index ")) {
                const pct = std.mem.trim(u8, line["dissimilarity index ".len..], " \t\r%");
                patch.dissimilarity = std.fmt.parseInt(u32, pct, 10) catch null;
                patch.is_rewrite = true;
            }
            if (std.mem.startsWith(u8, line, "rename to ") or std.mem.startsWith(u8, line, "copy to ")) {
                const new_name = std.mem.trim(u8, line[std.mem.indexOf(u8, line, " to ").? + 4 ..], " \t\r");
                if (patch.new_path) |p| allocator.free(p);
                patch.new_path = try allocator.dupe(u8, new_name);
            }
            pos.* += 1;
        } else if (std.mem.startsWith(u8, line, "Binary files") or std.mem.startsWith(u8, line, "GIT binary patch")) {
            patch.is_binary = true;
            pos.* += 1;
            // Skip binary content
            while (pos.* < lines.len and !std.mem.startsWith(u8, lines[pos.*], "diff --git ")) {
                pos.* += 1;
            }
            break;
        } else if (std.mem.startsWith(u8, line, "--- ")) {
            // Start of actual diff content
            break;
        } else if (std.mem.startsWith(u8, line, "diff --git ")) {
            // Next patch
            break;
        } else {
            pos.* += 1;
        }
    }

    // Parse --- and +++ lines
    if (pos.* < lines.len and std.mem.startsWith(u8, lines[pos.*], "--- ")) {
        const old_line = lines[pos.*]["--- ".len..];
        if (!std.mem.eql(u8, old_line, "/dev/null")) {
            const stripped = stripPath(old_line, p_value);
            if (patch.old_path == null) {
                patch.old_path = try allocator.dupe(u8, stripped);
            }
        }
        pos.* += 1;
    }
    if (pos.* < lines.len and std.mem.startsWith(u8, lines[pos.*], "+++ ")) {
        const new_line = lines[pos.*]["+++ ".len..];
        if (!std.mem.eql(u8, new_line, "/dev/null")) {
            const stripped = stripPath(new_line, p_value);
            if (patch.new_path) |p| allocator.free(p);
            patch.new_path = try allocator.dupe(u8, stripped);
        }
        pos.* += 1;
    }

    // Parse hunks
    while (pos.* < lines.len) {
        const line = lines[pos.*];
        if (std.mem.startsWith(u8, line, "@@ ")) {
            const hunk = try parseHunk(allocator, lines, pos);
            patch.added += hunk.new_count;
            patch.removed += hunk.old_count;
            try patch.hunks.append(hunk);
        } else if (std.mem.startsWith(u8, line, "diff --git ")) {
            break;
        } else {
            pos.* += 1;
        }
    }

    return patch;
}


pub fn parseTraditionalPatch(allocator: std.mem.Allocator, lines: []const []const u8, pos: *usize, p_value: u32) !Patch {
    var patch = Patch{
        .old_path = null,
        .new_path = null,
        .is_new_file = false,
        .is_delete = false,
        .new_mode = null,
        .old_mode = null,
        .is_binary = false,
        .hunks = std.ArrayList(PatchHunk).init(allocator),
        .added = 0,
        .removed = 0,
    };

    // Parse --- line
    if (pos.* < lines.len and std.mem.startsWith(u8, lines[pos.*], "--- ")) {
        const old_line = lines[pos.*]["--- ".len..];
        if (!std.mem.eql(u8, old_line, "/dev/null")) {
            patch.old_path = try allocator.dupe(u8, stripPath(old_line, p_value));
        } else {
            patch.is_new_file = true;
        }
        pos.* += 1;
    }
    if (pos.* < lines.len and std.mem.startsWith(u8, lines[pos.*], "+++ ")) {
        const new_line = lines[pos.*]["+++ ".len..];
        if (!std.mem.eql(u8, new_line, "/dev/null")) {
            patch.new_path = try allocator.dupe(u8, stripPath(new_line, p_value));
        } else {
            patch.is_delete = true;
        }
        pos.* += 1;
    }

    // Parse hunks
    while (pos.* < lines.len) {
        const line = lines[pos.*];
        if (std.mem.startsWith(u8, line, "@@ ")) {
            const hunk = try parseHunk(allocator, lines, pos);
            patch.added += hunk.new_count;
            patch.removed += hunk.old_count;
            try patch.hunks.append(hunk);
        } else if (std.mem.startsWith(u8, line, "diff ") or
            std.mem.startsWith(u8, line, "--- "))
        {
            break;
        } else {
            pos.* += 1;
        }
    }

    return patch;
}


pub fn parseHunk(allocator: std.mem.Allocator, lines: []const []const u8, pos: *usize) !PatchHunk {
    const header = lines[pos.*];
    // Parse @@ -old_start,old_count +new_start,new_count @@
    var old_start: u32 = 1;
    var old_count: u32 = 1;
    var new_start: u32 = 1;
    var new_count: u32 = 1;

    if (std.mem.indexOf(u8, header, "-")) |minus_pos| {
        const after_minus = header[minus_pos + 1 ..];
        if (std.mem.indexOf(u8, after_minus, " +")) |plus_pos| {
            const old_part = after_minus[0..plus_pos];
            if (std.mem.indexOf(u8, old_part, ",")) |comma| {
                old_start = std.fmt.parseInt(u32, old_part[0..comma], 10) catch return error.CorruptPatch;
                old_count = std.fmt.parseInt(u32, old_part[comma + 1 ..], 10) catch return error.CorruptPatch;
            } else {
                old_start = std.fmt.parseInt(u32, old_part, 10) catch return error.CorruptPatch;
                old_count = 1;
            }
            const after_plus = after_minus[plus_pos + 2 ..];
            const new_end = std.mem.indexOf(u8, after_plus, " ") orelse std.mem.indexOf(u8, after_plus, "@") orelse after_plus.len;
            const new_part = after_plus[0..new_end];
            if (std.mem.indexOf(u8, new_part, ",")) |comma| {
                new_start = std.fmt.parseInt(u32, new_part[0..comma], 10) catch return error.CorruptPatch;
                new_count = std.fmt.parseInt(u32, new_part[comma + 1 ..], 10) catch return error.CorruptPatch;
            } else {
                new_start = std.fmt.parseInt(u32, new_part, 10) catch 1;
                new_count = 1;
            }
        }
    }

    pos.* += 1;

    var hunk = PatchHunk{
        .old_start = old_start,
        .old_count = old_count,
        .new_start = new_start,
        .new_count = new_count,
        .lines = std.ArrayList(PatchLine).init(allocator),
    };

    while (pos.* < lines.len) {
        const line = lines[pos.*];
        if (line.len == 0) {
            // Empty line could be context (empty line in diff) or end of patch
            // Check if there are more diff lines after this
            var has_more_diff = false;
            var look_ahead = pos.* + 1;
            while (look_ahead < lines.len) : (look_ahead += 1) {
                const la = lines[look_ahead];
                if (la.len == 0) continue;
                if (la[0] == '+' or la[0] == '-' or la[0] == ' ' or la[0] == '@') {
                    has_more_diff = true;
                    break;
                }
                if (std.mem.startsWith(u8, la, "diff ") or std.mem.startsWith(u8, la, "--- ")) {
                    break;
                }
                break;
            }
            if (!has_more_diff) {
                // End of patch/hunk
                pos.* += 1;
                break;
            }
            // Treat empty line as context (empty line in diff output)
            try hunk.lines.append(.{ .line_type = .context, .content = try allocator.dupe(u8, "") });
            pos.* += 1;
        } else if (line[0] == '+') {
            try hunk.lines.append(.{ .line_type = .add, .content = try allocator.dupe(u8, line[1..]) });
            pos.* += 1;
        } else if (line[0] == '-') {
            try hunk.lines.append(.{ .line_type = .remove, .content = try allocator.dupe(u8, line[1..]) });
            pos.* += 1;
        } else if (line[0] == ' ') {
            try hunk.lines.append(.{ .line_type = .context, .content = try allocator.dupe(u8, line[1..]) });
            pos.* += 1;
        } else if (std.mem.startsWith(u8, line, "\\ No newline at end of file")) {
            // Mark last line as having no trailing newline
            if (hunk.lines.items.len > 0) {
                hunk.lines.items[hunk.lines.items.len - 1].no_newline = true;
            }
            pos.* += 1;
        } else if (std.mem.startsWith(u8, line, "@@") or
            std.mem.startsWith(u8, line, "diff ") or
            std.mem.startsWith(u8, line, "--- "))
        {
            break;
        } else {
            pos.* += 1;
        }
    }

    return hunk;
}






pub fn stripPath(path: []const u8, p_value: u32) []const u8 {
    var result = path;
    var strips: u32 = 0;
    while (strips < p_value) {
        if (std.mem.indexOf(u8, result, "/")) |slash| {
            result = result[slash + 1 ..];
            strips += 1;
        } else break;
    }
    return result;
}


pub fn reverseLineType(lt: PatchLineType) PatchLineType {
    return switch (lt) {
        .add => .remove,
        .remove => .add,
        .context => .context,
    };
}




pub fn countDigits(n: u32) u32 {
    if (n == 0) return 1;
    var count: u32 = 0;
    var val = n;
    while (val > 0) : (val /= 10) count += 1;
    return count;
}
