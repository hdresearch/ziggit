// Auto-generated from main_common.zig - cmd_cat_file
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_show = @import("cmd_show.zig");

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

pub fn cmdCatFile(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("cat-file: not supported in freestanding mode\n");
        return;
    }

    var show_type = false;
    var show_size = false;
    var show_pretty = false;
    var show_exists = false;
    var batch_mode = false;
    var batch_check = false;
    var batch_all = false;
    var batch_format: ?[]const u8 = null;
    var follow_symlinks = false;
    var textconv = false;
    var filters = false;
    var path_opt: ?[]const u8 = null;
    var object_ref: ?[]const u8 = null;
    // helpers.Track cmdmode order for conflict reporting
    var cmdmode_first: ?[]const u8 = null;
    var cmdmode_second: ?[]const u8 = null;

    // helpers.Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-t")) {
            show_type = true;
            if (cmdmode_first == null) { cmdmode_first = "-t"; } else if (cmdmode_second == null) { cmdmode_second = "-t"; }
        } else if (std.mem.eql(u8, arg, "-s")) {
            show_size = true;
            if (cmdmode_first == null) { cmdmode_first = "-s"; } else if (cmdmode_second == null) { cmdmode_second = "-s"; }
        } else if (std.mem.eql(u8, arg, "-p")) {
            show_pretty = true;
            if (cmdmode_first == null) { cmdmode_first = "-p"; } else if (cmdmode_second == null) { cmdmode_second = "-p"; }
        } else if (std.mem.eql(u8, arg, "-e")) {
            show_exists = true;
            if (cmdmode_first == null) { cmdmode_first = "-e"; } else if (cmdmode_second == null) { cmdmode_second = "-e"; }
        } else if (std.mem.eql(u8, arg, "--batch")) {
            batch_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--batch=")) {
            batch_mode = true;
            batch_format = arg["--batch=".len..];
        } else if (std.mem.eql(u8, arg, "--batch-check")) {
            batch_check = true;
        } else if (std.mem.startsWith(u8, arg, "--batch-check=")) {
            batch_check = true;
            batch_format = arg["--batch-check=".len..];
        } else if (std.mem.eql(u8, arg, "--batch-all-objects")) {
            batch_all = true;
        } else if (std.mem.eql(u8, arg, "--follow-symlinks")) {
            follow_symlinks = true;
        } else if (std.mem.eql(u8, arg, "--textconv")) {
            textconv = true;
            if (cmdmode_first == null) { cmdmode_first = "--textconv"; } else if (cmdmode_second == null) { cmdmode_second = "--textconv"; }
        } else if (std.mem.eql(u8, arg, "--filters")) {
            filters = true;
            if (cmdmode_first == null) { cmdmode_first = "--filters"; } else if (cmdmode_second == null) { cmdmode_second = "--filters"; }
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            path_opt = arg["--path=".len..];
        } else if (std.mem.eql(u8, arg, "--path")) {
            path_opt = args.next();
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            object_ref = arg;
        }
    }

    // helpers.Count cmdmode options (mutually exclusive: -e, -p, -t, -s, --textconv, --filters)
    var cmdmode_count: u32 = 0;
    if (show_type) cmdmode_count += 1;
    if (show_size) cmdmode_count += 1;
    if (show_pretty) cmdmode_count += 1;
    if (show_exists) cmdmode_count += 1;
    if (textconv) cmdmode_count += 1;
    if (filters) cmdmode_count += 1;

    // helpers.Check for incompatible cmdmode combinations
    if (cmdmode_count > 1) {
        const first = cmdmode_first orelse "-e";
        const second = cmdmode_second orelse "-e";
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: {s} cannot be used together with {s}\n", .{ second, first }) catch "error: options cannot be used together\n";
        try platform_impl.writeStderr(msg);
        std.process.exit(129);
    }

    // --batch-all-helpers.objects with -e requires batch mode
    if (batch_all and (show_exists or show_type or show_size or show_pretty)) {
        const mode_name = if (show_exists) "-e" else if (show_type) "-t" else if (show_size) "-s" else "-p";
        var buf2: [256]u8 = undefined;
        const msg2 = std.fmt.bufPrint(&buf2, "error: --batch-all-helpers.objects cannot be used together with {s}\n", .{mode_name}) catch "error: options cannot be used together\n";
        try platform_impl.writeStderr(msg2);
        std.process.exit(129);
    }

    // -e/-p/-t/-s are incompatible with --batch/--batch-check
    if ((batch_mode or batch_check) and (show_exists or show_type or show_size or show_pretty)) {
        const mode_name = if (show_exists) "-e" else if (show_type) "-t" else if (show_size) "-s" else "-p";
        const batch_name = if (batch_mode) "--batch" else "--batch-check";
        var buf3: [256]u8 = undefined;
        const msg3 = std.fmt.bufPrint(&buf3, "error: {s} is incompatible with {s}\n", .{ mode_name, batch_name }) catch "fatal: options are incompatible\n";
        try platform_impl.writeStderr(msg3);
        std.process.exit(129);
    }

    // -e/-p/-t/-s are incompatible with --follow-symlinks
    if (follow_symlinks and (show_exists or show_type or show_size or show_pretty)) {
        const mode_name = if (show_exists) "-e" else if (show_type) "-t" else if (show_size) "-s" else "-p";
        var buf4: [256]u8 = undefined;
        const msg4 = std.fmt.bufPrint(&buf4, "error: {s} is incompatible with --follow-symlinks\n", .{mode_name}) catch "fatal: options are incompatible\n";
        try platform_impl.writeStderr(msg4);
        std.process.exit(129);
    }

    // --path is incompatible with --batch/--batch-check
    if (path_opt != null and (batch_mode or batch_check)) {
        const batch_name = if (batch_mode) "--batch" else "--batch-check";
        var buf5: [256]u8 = undefined;
        const msg5 = std.fmt.bufPrint(&buf5, "fatal: --path is incompatible with {s}\n", .{batch_name}) catch "fatal: --path is incompatible with --batch\n";
        try platform_impl.writeStderr(msg5);
        std.process.exit(129);
    }

    // -e/-p/-t/-s with --path and positional arg (HEAD:path form) is incompatible
    if (path_opt != null and (show_exists or show_type or show_size or show_pretty) and object_ref != null) {
        if (std.mem.indexOf(u8, object_ref.?, ":") != null) {
            const mode_name = if (show_exists) "-e" else if (show_type) "-t" else if (show_size) "-s" else "-p";
            var buf6: [256]u8 = undefined;
            const msg6 = std.fmt.bufPrint(&buf6, "error: --path=foo is incompatible with {s} HEAD:some-path.txt\n", .{mode_name}) catch "fatal: options are incompatible\n";
            try platform_impl.writeStderr(msg6);
            std.process.exit(129);
        }
    }

    // --textconv/--filters require an object when not in batch mode
    if (!batch_mode and !batch_check and !batch_all) {
        if (textconv and object_ref == null) {
            try platform_impl.writeStderr("fatal: <object> required with --textconv\n");
            std.process.exit(129);
        }
        if (filters and object_ref == null) {
            try platform_impl.writeStderr("fatal: <object> required with --filters\n");
            std.process.exit(129);
        }
        if (show_exists and object_ref == null) {
            try platform_impl.writeStderr("fatal: <object> required with -e\n");
            std.process.exit(129);
        }
        if (show_type and object_ref == null) {
            try platform_impl.writeStderr("fatal: <object> required with -t\n");
            std.process.exit(129);
        }
        if (show_size and object_ref == null) {
            try platform_impl.writeStderr("fatal: <object> required with -s\n");
            std.process.exit(129);
        }
        if (show_pretty and object_ref == null) {
            try platform_impl.writeStderr("fatal: <object> required with -p\n");
            std.process.exit(129);
        }
    }

    // --textconv/--filters incompatible with --batch/--batch-check (when also a cmdmode)
    if ((batch_mode or batch_check) and (textconv or filters)) {
        const cw_name = if (textconv) "--textconv" else "--filters";
        const batch_name = if (batch_mode) "--batch" else "--batch-check";
        var buf7: [256]u8 = undefined;
        const msg7 = std.fmt.bufPrint(&buf7, "error: {s} is incompatible with {s}\n", .{ cw_name, batch_name }) catch "fatal: options are incompatible\n";
        try platform_impl.writeStderr(msg7);
        std.process.exit(129);
    }

    // --follow-symlinks incompatible with --textconv/--filters
    if (follow_symlinks and (textconv or filters)) {
        const cw_name = if (textconv) "--textconv" else "--filters";
        var buf8: [256]u8 = undefined;
        const msg8 = std.fmt.bufPrint(&buf8, "error: {s} is incompatible with --follow-symlinks\n", .{cw_name}) catch "fatal: options are incompatible\n";
        try platform_impl.writeStderr(msg8);
        std.process.exit(129);
    }

    // helpers.Find .git directory (after argument validation)
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    if (batch_mode or batch_check) {
        // Batch mode: read object names from stdin
        try catFileBatch(allocator, git_path, batch_mode, batch_format, platform_impl);
        return;
    }

    if (object_ref == null) {
        try platform_impl.writeStderr("usage: git cat-file <type> <object>\n   or: git cat-file (-e | -p) <object>\n   or: git cat-file (-t | -s) [--allow-unknown-type] <object>\n   or: git cat-file (--batch | --batch-check) [--batch-all-objects]\n                    [--buffer] [--follow-symlinks] [--unordered]\n                    [--textconv | --filters]\n");
        std.process.exit(129);
    }
    
    // helpers.Handle -e (exists check)
    if (show_exists) {
        var obj_hash: []u8 = undefined;
        if (helpers.isValidHashPrefix(object_ref.?)) {
            obj_hash = helpers.resolveCommitHash(git_path, object_ref.?, platform_impl, allocator) catch {
                std.process.exit(1);
            };
        } else {
            obj_hash = helpers.resolveCommittish(git_path, object_ref.?, platform_impl, allocator) catch {
                std.process.exit(1);
            };
        }
        defer allocator.free(obj_hash);
        _ = objects.GitObject.load(obj_hash, git_path, platform_impl, allocator) catch {
            std.process.exit(1);
        };
        return; // exists - exit 0
    }

    // helpers.For --textconv and --filters, handle rev:path format with better error messages
    if ((textconv or filters) and object_ref != null) {
        if (std.mem.indexOf(u8, object_ref.?, ":")) |colon_pos| {
            const rev_part = object_ref.?[0..colon_pos];
            const path_part = object_ref.?[colon_pos + 1 ..];
            if (rev_part.len == 0) {
                // :path - read from helpers.HEAD tree
                const head_hash = refs.getCurrentCommit(git_path, platform_impl, allocator) catch { try platform_impl.writeStderr("fatal: no commits\n"); std.process.exit(128); unreachable; };
                if (head_hash) |hh| {
                    defer allocator.free(hh);
                    const blob_hash = helpers.getTreeEntryHashFromCommit(git_path, hh, path_part, allocator) catch { const msg = try std.fmt.allocPrint(allocator, "fatal: path '{s}' does not exist in the index\n", .{path_part}); defer allocator.free(msg); try platform_impl.writeStderr(msg); std.process.exit(128); unreachable; };
                    defer allocator.free(blob_hash);
                    const blob_obj = objects.GitObject.load(blob_hash, git_path, platform_impl, allocator) catch { try platform_impl.writeStderr("fatal: bad object\n"); std.process.exit(128); unreachable; };
                    defer blob_obj.deinit(allocator);
                    try platform_impl.writeStdout(blob_obj.data);
                    return;
                }
            }
            const rev_hash = helpers.resolveRevision(git_path, rev_part, platform_impl, allocator) catch { const msg = try std.fmt.allocPrint(allocator, "fatal: invalid object name '{s}'.\n", .{rev_part}); defer allocator.free(msg); try platform_impl.writeStderr(msg); std.process.exit(128); unreachable; };
            defer allocator.free(rev_hash);
            const blob_hash = helpers.getTreeEntryHashFromCommit(git_path, rev_hash, path_part, allocator) catch { const msg = try std.fmt.allocPrint(allocator, "fatal: path '{s}' does not exist in '{s}'\n", .{ path_part, rev_part }); defer allocator.free(msg); try platform_impl.writeStderr(msg); std.process.exit(128); unreachable; };
            defer allocator.free(blob_hash);
            const blob_obj = objects.GitObject.load(blob_hash, git_path, platform_impl, allocator) catch { try platform_impl.writeStderr("fatal: bad object\n"); std.process.exit(128); unreachable; };
            defer blob_obj.deinit(allocator);
            try platform_impl.writeStdout(blob_obj.data);
            return;
        } else if (textconv) {
            const rev_valid = helpers.resolveRevision(git_path, object_ref.?, platform_impl, allocator) catch null;
            if (rev_valid) |v| {
                allocator.free(v);
                const msg = try std.fmt.allocPrint(allocator, "fatal: <object>:<path> required, only <object> '{s}' given\n", .{object_ref.?});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            } else {
                const msg = try std.fmt.allocPrint(allocator, "fatal: helpers.Not a valid object name {s}\n", .{object_ref.?});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            }
            std.process.exit(128);
        }
    }

    // helpers.Resolve the object reference to a hash
    var object_hash: []u8 = undefined;
    if (helpers.isValidHashPrefix(object_ref.?)) {
        // helpers.Try to resolve as a partial hash
        object_hash = helpers.resolveCommitHash(git_path, object_ref.?, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: helpers.Not a valid object name {s}\n", .{object_ref.?});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
    } else {
        // helpers.Try to resolve as a committish
        object_hash = helpers.resolveCommittish(git_path, object_ref.?, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: helpers.Not a valid object name {s}\n", .{object_ref.?});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
    }
    defer allocator.free(object_hash);

    // helpers.Load the git object
    const git_object = objects.GitObject.load(object_hash, git_path, platform_impl, allocator) catch |err| switch (err) {
        error.ObjectNotFound => {
            const msg = try std.fmt.allocPrint(allocator, "fatal: helpers.Not a valid object name {s}\n", .{object_ref.?});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        },
        else => return err,
    };
    defer git_object.deinit(allocator);

    if (show_type) {
        // helpers.Show object type
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
        // helpers.Show object size
        const size_output = try std.fmt.allocPrint(allocator, "{d}\n", .{git_object.data.len});
        defer allocator.free(size_output);
        try platform_impl.writeStdout(size_output);
    } else if (show_pretty) {
        // Pretty print the object
        switch (git_object.type) {
            .blob => {
                // helpers.For blobs, just output the content
                try platform_impl.writeStdout(git_object.data);
            },
            .tree => {
                // helpers.For trees, show formatted tree entries
                try cmd_show.showTreeObjectFormatted(git_object, platform_impl, allocator);
            },
            .commit => {
                // helpers.For commits, show formatted commit data
                try platform_impl.writeStdout(git_object.data);
            },
            .tag => {
                // helpers.For tags, show formatted tag data
                try platform_impl.writeStdout(git_object.data);
            },
        }
    } else {
        // Default: show raw object content
        try platform_impl.writeStdout(git_object.data);
    }
}


pub fn catFileBatch(allocator: std.mem.Allocator, git_path: []const u8, full_content: bool, custom_format: ?[]const u8, platform_impl: *const platform_mod.Platform) !void {
    const stdin_data = helpers.readStdin(allocator, 10 * 1024 * 1024) catch return;
    defer allocator.free(stdin_data);
    
    var lines = std.mem.splitScalar(u8, stdin_data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        
        // helpers.Resolve object
        var obj_hash: []u8 = undefined;
        if (helpers.isValidHashPrefix(trimmed)) {
            obj_hash = helpers.resolveCommitHash(git_path, trimmed, platform_impl, allocator) catch {
                const msg = try std.fmt.allocPrint(allocator, "{s} missing\n", .{trimmed});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
                continue;
            };
        } else {
            obj_hash = helpers.resolveCommittish(git_path, trimmed, platform_impl, allocator) catch {
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
        
        if (custom_format) |fmt| {
            const formatted = try formatCatFileOutput(allocator, fmt, obj_hash, type_str, git_object.data.len);
            defer allocator.free(formatted);
            try platform_impl.writeStdout(formatted);
            try platform_impl.writeStdout("\n");
            if (full_content) {
                try platform_impl.writeStdout(git_object.data);
                try platform_impl.writeStdout("\n");
            }
        } else if (full_content) {
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


pub fn formatCatFileOutput(allocator: std.mem.Allocator, fmt: []const u8, obj_hash: []const u8, type_str: []const u8, size: usize) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '%' and i + 1 < fmt.len and fmt[i + 1] == '(') {
            const close = std.mem.indexOf(u8, fmt[i + 2 ..], ")") orelse {
                try result.append(fmt[i]);
                i += 1;
                continue;
            };
            const field = fmt[i + 2 .. i + 2 + close];
            i = i + 2 + close + 1;

            if (std.mem.eql(u8, field, "objectname")) {
                try result.appendSlice(obj_hash);
            } else if (std.mem.eql(u8, field, "objecttype")) {
                try result.appendSlice(type_str);
            } else if (std.mem.eql(u8, field, "objectsize")) {
                const s = try std.fmt.allocPrint(allocator, "{d}", .{size});
                defer allocator.free(s);
                try result.appendSlice(s);
            } else if (std.mem.eql(u8, field, "objectsize:disk")) {
                try result.append('0'); // placeholder
            } else if (std.mem.eql(u8, field, "rest")) {
                // rest of input line - empty for now
            }
        } else if (fmt[i] == '%' and i + 1 < fmt.len and fmt[i + 1] == '%') {
            try result.append('%');
            i += 2;
            continue;
        } else {
            try result.append(fmt[i]);
            i += 1;
            continue;
        }
    }

    return result.toOwnedSlice();
}
