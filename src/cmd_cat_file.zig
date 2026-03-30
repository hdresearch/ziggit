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
    var extra_args: u32 = 0;
    var buffer_mode = false;
    var nul_terminated = false;
    var batch_command = false;
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
        } else if (std.mem.eql(u8, arg, "--batch-command")) {
            batch_command = true;
            batch_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--batch-command=")) {
            batch_command = true;
            batch_mode = true;
            batch_format = arg["--batch-command=".len..];
        } else if (std.mem.eql(u8, arg, "--buffer")) {
            buffer_mode = true;
        } else if (std.mem.eql(u8, arg, "--no-buffer")) {
            buffer_mode = false;
        } else if (std.mem.eql(u8, arg, "--follow-symlinks")) {
            follow_symlinks = true;
        } else if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "-Z")) {
            nul_terminated = true;
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
            if (object_ref != null) {
                extra_args += 1;
            }
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
        const msg = std.fmt.bufPrint(&buf, "error: {s} is incompatible with {s}\n", .{ second, first }) catch "error: options are incompatible\n";
        try platform_impl.writeStderr(msg);
        std.process.exit(129);
    }

    // --batch-all-helpers.objects with -e requires batch mode
    if (batch_all and (show_exists or show_type or show_size or show_pretty)) {
        const mode_name = if (show_exists) "-e" else if (show_type) "-t" else if (show_size) "-s" else "-p";
        var buf2: [256]u8 = undefined;
        const msg2 = std.fmt.bufPrint(&buf2, "error: --batch-all-objects is incompatible with {s}\n", .{mode_name}) catch "error: options are incompatible\n";
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

    // Too many positional arguments for cmdmode options
    if (extra_args > 0 and cmdmode_count > 0) {
        const emsg = "fatal: too many arguments\n";
        try platform_impl.writeStderr(emsg);
        std.process.exit(129);
    }

    // --buffer is incompatible with cmdmode options
    if (buffer_mode and cmdmode_count > 0) {
        const mode_name: []const u8 = if (show_exists) "-e" else if (show_type) "-t" else if (show_size) "-s" else if (show_pretty) "-p" else if (textconv) "--textconv" else "--filters";
        var bbuf: [256]u8 = undefined;
        const bmsg = std.fmt.bufPrint(&bbuf, "error: {s} is incompatible with --buffer\n", .{mode_name}) catch "error: options are incompatible\n";
        try platform_impl.writeStderr(bmsg);
        std.process.exit(129);
    }

    // --follow-symlinks is incompatible with --textconv/--filters
    if (follow_symlinks and (textconv or filters)) {
        const cw_name = if (textconv) "--textconv" else "--filters";
        var fsbuf: [256]u8 = undefined;
        const fsmsg = std.fmt.bufPrint(&fsbuf, "error: {s} is incompatible with --follow-symlinks\n", .{cw_name}) catch "error: options are incompatible\n";
        try platform_impl.writeStderr(fsmsg);
        std.process.exit(129);
    }

    // --buffer/--follow-symlinks/--batch-all-objects/-z/-Z require batch mode
    if (!batch_mode and !batch_check) {
        if (buffer_mode) {
            try platform_impl.writeStderr("fatal: --buffer requires a batch mode\n");
            std.process.exit(129);
        }
        if (follow_symlinks and !show_exists and !show_type and !show_size and !show_pretty and !textconv and !filters) {
            try platform_impl.writeStderr("fatal: --follow-symlinks requires a batch mode\n");
            std.process.exit(129);
        }
        if (batch_all) {
            try platform_impl.writeStderr("fatal: --batch-all-objects requires a batch mode\n");
            std.process.exit(129);
        }
        if (nul_terminated) {
            try platform_impl.writeStderr("fatal: -z requires a batch mode\n");
            std.process.exit(129);
        }
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
        try catFileBatch(allocator, git_path, batch_mode, batch_format, platform_impl, batch_command);
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
                // :path - read from HEAD tree
                const head_hash = refs.getCurrentCommit(git_path, platform_impl, allocator) catch { try platform_impl.writeStderr("fatal: no commits\n"); std.process.exit(128); unreachable; };
                if (head_hash) |hh| {
                    defer allocator.free(hh);
                    const blob_hash = helpers.getTreeEntryHashFromCommit(git_path, hh, path_part, allocator) catch { const msg = try std.fmt.allocPrint(allocator, "fatal: path '{s}' does not exist in the index\n", .{path_part}); defer allocator.free(msg); try platform_impl.writeStderr(msg); std.process.exit(128); unreachable; };
                    defer allocator.free(blob_hash);
                    const blob_obj = objects.GitObject.load(blob_hash, git_path, platform_impl, allocator) catch { try platform_impl.writeStderr("fatal: bad object\n"); std.process.exit(128); unreachable; };
                    defer blob_obj.deinit(allocator);
                    if (textconv) {
                        try runTextconv(git_path, path_part, blob_obj.data, platform_impl, allocator);
                    } else {
                        try platform_impl.writeStdout(blob_obj.data);
                    }
                    return;
                }
            }
            const rev_hash = helpers.resolveRevision(git_path, rev_part, platform_impl, allocator) catch { const msg = try std.fmt.allocPrint(allocator, "fatal: invalid object name '{s}'.\n", .{rev_part}); defer allocator.free(msg); try platform_impl.writeStderr(msg); std.process.exit(128); unreachable; };
            defer allocator.free(rev_hash);
            const blob_hash = helpers.getTreeEntryHashFromCommit(git_path, rev_hash, path_part, allocator) catch { const msg = try std.fmt.allocPrint(allocator, "fatal: path '{s}' does not exist in '{s}'\n", .{ path_part, rev_part }); defer allocator.free(msg); try platform_impl.writeStderr(msg); std.process.exit(128); unreachable; };
            defer allocator.free(blob_hash);
            const blob_obj = objects.GitObject.load(blob_hash, git_path, platform_impl, allocator) catch { try platform_impl.writeStderr("fatal: bad object\n"); std.process.exit(128); unreachable; };
            defer blob_obj.deinit(allocator);
            if (textconv) {
                try runTextconv(git_path, path_part, blob_obj.data, platform_impl, allocator);
            } else {
                try platform_impl.writeStdout(blob_obj.data);
            }
            return;
        } else if (textconv) {
            const rev_valid = helpers.resolveRevision(git_path, object_ref.?, platform_impl, allocator) catch null;
            if (rev_valid) |v| {
                allocator.free(v);
                const msg = try std.fmt.allocPrint(allocator, "fatal: <object>:<path> required, only <object> '{s}' given\n", .{object_ref.?});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            } else {
                const msg = try std.fmt.allocPrint(allocator, "fatal: Not a valid object name {s}\n", .{object_ref.?});
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
            const msg = try std.fmt.allocPrint(allocator, "fatal: Not a valid object name {s}\n", .{object_ref.?});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
    } else {
        // helpers.Try to resolve as a committish
        object_hash = helpers.resolveCommittish(git_path, object_ref.?, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: Not a valid object name {s}\n", .{object_ref.?});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
    }
    defer allocator.free(object_hash);

    // helpers.Load the git object
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


pub fn catFileBatch(allocator: std.mem.Allocator, git_path: []const u8, full_content: bool, custom_format: ?[]const u8, platform_impl: *const platform_mod.Platform, is_batch_command: bool) !void {
    const stdin_data = helpers.readStdin(allocator, 10 * 1024 * 1024) catch return;
    defer allocator.free(stdin_data);
    
    var lines = std.mem.splitScalar(u8, stdin_data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // In --batch-command mode, parse command prefix
        var object_name = trimmed;
        var cmd_is_contents = full_content; // default behavior
        var cmd_is_info = !full_content;
        if (is_batch_command) {
            if (std.mem.eql(u8, trimmed, "flush")) {
                continue;
            } else if (std.mem.startsWith(u8, trimmed, "contents ")) {
                object_name = std.mem.trim(u8, trimmed["contents ".len..], " \t");
                cmd_is_contents = true;
                cmd_is_info = false;
            } else if (std.mem.startsWith(u8, trimmed, "info ")) {
                object_name = std.mem.trim(u8, trimmed["info ".len..], " \t");
                cmd_is_contents = false;
                cmd_is_info = true;
            } else {
                const msg = try std.fmt.allocPrint(allocator, "{s} missing\n", .{trimmed});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
                continue;
            }
        }
        
        // helpers.Resolve object
        var obj_hash: []u8 = undefined;
        if (helpers.isValidHashPrefix(object_name)) {
            obj_hash = helpers.resolveCommitHash(git_path, object_name, platform_impl, allocator) catch {
                const msg = try std.fmt.allocPrint(allocator, "{s} missing\n", .{object_name});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
                continue;
            };
        } else {
            obj_hash = helpers.resolveCommittish(git_path, object_name, platform_impl, allocator) catch {
                const msg = try std.fmt.allocPrint(allocator, "{s} missing\n", .{object_name});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
                continue;
            };
        }
        defer allocator.free(obj_hash);
        
        const git_object = objects.GitObject.load(obj_hash, git_path, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "{s} missing\n", .{object_name});
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
            if (cmd_is_contents) {
                try platform_impl.writeStdout(git_object.data);
                try platform_impl.writeStdout("\n");
            }
        } else if (cmd_is_contents) {
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

fn runTextconv(git_path: []const u8, file_path: []const u8, blob_data: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // Find the diff driver from gitattributes
    const driver_name = findDiffDriver(git_path, file_path, platform_impl, allocator) orelse {
        // No textconv filter, output raw data
        try platform_impl.writeStdout(blob_data);
        return;
    };
    defer allocator.free(driver_name);

    // Look up diff.<driver>.textconv in config
    const textconv_key = std.fmt.allocPrint(allocator, "diff.{s}.textconv", .{driver_name}) catch return;
    defer allocator.free(textconv_key);

    const cmd_maybe = helpers.getConfigValueByKey(git_path, textconv_key, allocator);
    const cmd = cmd_maybe orelse {
        try platform_impl.writeStdout(blob_data);
        return;
    };
    defer allocator.free(cmd);

    // Write blob to temp file
    const tmp_path = std.fmt.allocPrint(allocator, "/tmp/.git-textconv-{d}", .{std.time.milliTimestamp()}) catch return;
    defer allocator.free(tmp_path);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    const tmp_file = std.fs.cwd().createFile(tmp_path, .{}) catch return;
    tmp_file.writeAll(blob_data) catch { tmp_file.close(); return; };
    tmp_file.close();

    // Run textconv command
    const full_cmd = std.fmt.allocPrint(allocator, "{s} {s}", .{ cmd, tmp_path }) catch return;
    defer allocator.free(full_cmd);
    const argv = [_][]const u8{ "/bin/sh", "-c", full_cmd };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch {
        try platform_impl.writeStdout(blob_data);
        return;
    };
    const output = child.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch {
        _ = child.wait() catch {};
        try platform_impl.writeStdout(blob_data);
        return;
    };
    defer allocator.free(output);
    const term = child.wait() catch {
        try platform_impl.writeStdout(blob_data);
        return;
    };
    if (term.Exited != 0) {
        // textconv command failed (e.g., for symlinks), output raw data
        try platform_impl.writeStdout(blob_data);
        return;
    }
    try platform_impl.writeStdout(output);
}

fn findDiffDriver(git_path: []const u8, file_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) ?[]u8 {
    // Get repo root from git_path
    const repo_root = if (std.mem.endsWith(u8, git_path, "/.git"))
        git_path[0 .. git_path.len - 5]
    else
        git_path;

    // Read .gitattributes
    const attr_path = std.fmt.allocPrint(allocator, "{s}/.gitattributes", .{repo_root}) catch return null;
    defer allocator.free(attr_path);
    const content = platform_impl.fs.readFile(allocator, attr_path) catch return null;
    defer allocator.free(content);

    // Parse gitattributes: look for patterns matching file_path with diff=<driver>
    var lines = std.mem.splitScalar(u8, content, '\n');
    var result: ?[]u8 = null;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        // Format: pattern attr1 attr2 ...
        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
        const pattern = parts.next() orelse continue;
        while (parts.next()) |attr| {
            if (std.mem.startsWith(u8, attr, "diff=")) {
                const basename = std.fs.path.basename(file_path);
                if (matchGlob(pattern, basename) or matchGlob(pattern, file_path)) {
                    if (result) |prev| allocator.free(prev);
                    result = allocator.dupe(u8, attr[5..]) catch null;
                }
            }
        }
    }
    return result;
}

fn matchGlob(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    while (pi < pattern.len and ni < name.len) {
        if (pattern[pi] == '*') {
            pi += 1;
            if (pi >= pattern.len) return true;
            while (ni < name.len) {
                if (matchGlob(pattern[pi..], name[ni..])) return true;
                ni += 1;
            }
            return matchGlob(pattern[pi..], name[ni..]);
        } else if (pattern[pi] == '?') {
            pi += 1;
            ni += 1;
        } else if (pattern[pi] == name[ni]) {
            pi += 1;
            ni += 1;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi >= pattern.len and ni >= name.len;
}
