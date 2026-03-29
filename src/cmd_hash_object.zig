// Auto-generated from main_common.zig - cmd_hash_object
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
const cmd_check_attr = @import("cmd_check_attr.zig");

pub fn cmdHashObject(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var write_object = false;
    var stdin_mode = false;
    var stdin_paths = false;
    var obj_type: []const u8 = "blob";
    var files = std.ArrayList([]const u8).init(allocator);
    defer files.deinit();
    var literally = false;
    var path_opt: ?[]const u8 = null;
    var stdin_count: u32 = 0;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-w")) {
            write_object = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            stdin_mode = true;
            stdin_count += 1;
        } else if (std.mem.eql(u8, arg, "--stdin-paths")) {
            stdin_paths = true;
        } else if (std.mem.eql(u8, arg, "--literally")) {
            literally = true;
        } else if (std.mem.eql(u8, arg, "--path")) {
            path_opt = args.next();
        } else if (std.mem.startsWith(u8, arg, "--path=")) {
            path_opt = arg["--path=".len..];
        } else if (std.mem.eql(u8, arg, "-t")) {
            obj_type = args.next() orelse {
                try platform_impl.writeStderr("fatal: option '-t' requires a value\n");
                std.process.exit(128);
                unreachable;
            };
        } else if (std.mem.startsWith(u8, arg, "-t")) {
            obj_type = arg[2..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try files.append(arg);
        }
    }

    // helpers.Validate mutually exclusive options
    if (stdin_count > 1) {
        try platform_impl.writeStderr("fatal: --stdin given twice\n");
        std.process.exit(128);
    }
    if (stdin_mode and stdin_paths) {
        try platform_impl.writeStderr("fatal: --stdin and --stdin-paths are mutually exclusive\n");
        std.process.exit(128);
    }
    if (stdin_paths and files.items.len > 0) {
        try platform_impl.writeStderr("fatal: Can't use --stdin-paths with file arguments\n");
        std.process.exit(128);
    }
    if (path_opt != null and stdin_paths) {
        try platform_impl.writeStderr("fatal: Can't use --path with --stdin-paths\n");
        std.process.exit(128);
    }

    const git_dir_for_write = if (write_object) (helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    }) else null;
    defer if (git_dir_for_write) |gd| allocator.free(gd);

    // Try to find git dir for CRLF conversion even when not writing
    const git_dir_for_crlf = if (git_dir_for_write) |gd| gd else (helpers.findGitDirectory(allocator, platform_impl) catch null);
    defer if (git_dir_for_write == null) { if (git_dir_for_crlf) |gd| allocator.free(gd); };
    const git_dir = git_dir_for_write;

    if (stdin_paths) {
        // helpers.Read file paths from stdin, one per line
        const stdin_data = helpers.readStdin(allocator, 10 * 1024 * 1024) catch {
            std.process.exit(128);
            unreachable;
        };
        defer allocator.free(stdin_data);
        var lines = std.mem.splitScalar(u8, stdin_data, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) continue;
            try hashOneFile(allocator, trimmed, obj_type, write_object, literally, git_dir, platform_impl, git_dir_for_crlf, path_opt);
        }
    } else if (stdin_mode) {
        // helpers.Read data from stdin first
        var data = helpers.readStdin(allocator, 100 * 1024 * 1024) catch {
            std.process.exit(128);
            unreachable;
        };
        defer allocator.free(data);
        const effective_path = path_opt;
        if (effective_path) |ep| {
            const converted = try applyCrlfConversion(allocator, data, ep, git_dir_for_crlf, platform_impl);
            if (converted) |c| {
                defer allocator.free(c);
                try helpers.hashData(allocator, c, obj_type, write_object, literally, git_dir, platform_impl);
            } else {
                try helpers.hashData(allocator, data, obj_type, write_object, literally, git_dir, platform_impl);
            }
        } else {
            try helpers.hashData(allocator, data, obj_type, write_object, literally, git_dir, platform_impl);
        }
        // Then process any file arguments
        for (files.items) |file_path| {
            try hashOneFile(allocator, file_path, obj_type, write_object, literally, git_dir, platform_impl, git_dir_for_crlf, path_opt);
        }
    } else if (files.items.len > 0) {
        for (files.items) |file_path| {
            try hashOneFile(allocator, file_path, obj_type, write_object, literally, git_dir, platform_impl, git_dir_for_crlf, path_opt);
        }
    } else {
        try platform_impl.writeStderr("usage: git hash-object [-t <type>] [-w] [--stdin | --stdin-paths | <file>...]\n");
        std.process.exit(128);
    }
}


pub fn hashOneFile(allocator: std.mem.Allocator, file_path: []const u8, obj_type: []const u8, write_object: bool, literally: bool, git_dir: ?[]const u8, platform_impl: *const platform_mod.Platform, git_dir_for_crlf: ?[]const u8, path_opt: ?[]const u8) !void {
    const data = std.fs.cwd().readFileAlloc(allocator, file_path, 100 * 1024 * 1024) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: Cannot open '{s}': helpers.No such file or directory\n", .{file_path});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(data);
    const effective_path = path_opt orelse file_path;
    const converted = try applyCrlfConversion(allocator, data, effective_path, git_dir_for_crlf, platform_impl);
    if (converted) |c| {
        defer allocator.free(c);
        try helpers.hashData(allocator, c, obj_type, write_object, literally, git_dir, platform_impl);
    } else {
        try helpers.hashData(allocator, data, obj_type, write_object, literally, git_dir, platform_impl);
    }
}

/// Check gitattributes and core.autocrlf to determine if CRLF→LF conversion is needed.
/// Returns converted data if conversion was applied, null otherwise.
fn applyCrlfConversion(allocator: std.mem.Allocator, data: []const u8, path: []const u8, git_dir_maybe: ?[]const u8, platform_impl: *const platform_mod.Platform) !?[]u8 {
    const git_dir = git_dir_maybe orelse return null;
    const repo_root = std.fs.path.dirname(git_dir) orelse ".";

    // Check if data contains \r at all
    if (std.mem.indexOf(u8, data, "\r") == null) return null;

    // Load gitattributes
    var attr_rules = std.ArrayList(cmd_check_attr.AttrRule).init(allocator);
    defer {
        for (attr_rules.items) |*rule| rule.deinit(allocator);
        attr_rules.deinit();
    }
    cmd_check_attr.loadAttrFile(allocator, repo_root, "", platform_impl, &attr_rules) catch {};

    // Check crlf attribute for the path
    var crlf_attr: enum { unspecified, set, unset } = .unspecified;
    for (attr_rules.items) |rule| {
        if (cmd_check_attr.attrPatternMatches(rule.pattern, path)) {
            for (rule.attrs.items) |attr| {
                if (std.mem.eql(u8, attr.name, "crlf")) {
                    if (std.mem.eql(u8, attr.value, "set")) {
                        crlf_attr = .set;
                    } else if (std.mem.eql(u8, attr.value, "unset")) {
                        crlf_attr = .unset;
                    }
                }
            }
        }
    }

    // If explicitly unset, no conversion
    if (crlf_attr == .unset) return null;

    // If set, or if core.autocrlf is true and not explicitly unset, convert
    var should_convert = (crlf_attr == .set);
    if (!should_convert and crlf_attr == .unspecified) {
        // Check core.autocrlf
        const config = config_mod.GitConfig.open(allocator, git_dir) catch return null;
        defer config.deinit();
        if (config.get("core", null, "autocrlf")) |val| {
            if (std.mem.eql(u8, val, "true")) {
                should_convert = true;
            }
        }
    }

    if (!should_convert) return null;

    // Convert CRLF to LF
    var result = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    while (i < data.len) {
        if (i + 1 < data.len and data[i] == '\r' and data[i + 1] == '\n') {
            try result.append('\n');
            i += 2;
        } else {
            try result.append(data[i]);
            i += 1;
        }
    }
    return try result.toOwnedSlice();
}
