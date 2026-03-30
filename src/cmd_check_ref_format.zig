// Auto-generated from main_common.zig - cmd_check_ref_format
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_check_ref_format = @import("cmd_check_ref_format.zig");

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

pub fn cmdCheckRefFormat(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var allow_onelevel = false;
    var refspec_pattern = false;
    var normalize = false;
    var no_allow_onelevel = false;
    var branch_mode = false;
    var refname: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--allow-onelevel")) { allow_onelevel = true; }
        else if (std.mem.eql(u8, arg, "--no-allow-onelevel")) { no_allow_onelevel = true; }
        else if (std.mem.eql(u8, arg, "--refspec-pattern")) { refspec_pattern = true; }
        else if (std.mem.eql(u8, arg, "--normalize")) { normalize = true; }
        else if (std.mem.eql(u8, arg, "--branch")) { branch_mode = true; }
        else if (std.mem.eql(u8, arg, "--print")) { normalize = true; }
        else if (arg.len > 0 and arg[0] != '-') { if (refname == null) refname = arg; }
    }
    if (branch_mode) {
        const name = refname orelse { std.process.exit(128); unreachable; };
        if (name.len > 2 and name[0] == '@' and name[1] == '{' and name[name.len - 1] == '}') {
            // Handle @{-N} - find Nth previous branch from reflog
            const inner = name[2 .. name.len - 1];
            if (inner.len > 1 and inner[0] == '-') {
                const n = std.fmt.parseInt(usize, inner[1..], 10) catch {
                    try platform_impl.writeStderr("fatal: no previous branch\n");
                    std.process.exit(128);
                };
                const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
                    try platform_impl.writeStderr("fatal: no previous branch\n");
                    std.process.exit(128);
                };
                defer allocator.free(git_path);
                const reflog_path = std.fmt.allocPrint(allocator, "{s}/logs/HEAD", .{git_path}) catch {
                    try platform_impl.writeStderr("fatal: no previous branch\n");
                    std.process.exit(128);
                };
                defer allocator.free(reflog_path);
                const reflog_content = platform_impl.fs.readFile(allocator, reflog_path) catch {
                    try platform_impl.writeStderr("fatal: no previous branch\n");
                    std.process.exit(128);
                };
                defer allocator.free(reflog_content);
                // Parse reflog entries in reverse order
                var lines = std.array_list.Managed([]const u8).init(allocator);
                defer lines.deinit();
                var line_iter = std.mem.splitScalar(u8, reflog_content, '\n');
                while (line_iter.next()) |line| {
                    if (line.len > 0) lines.append(line) catch {};
                }
                var count: usize = 0;
                var i = lines.items.len;
                while (i > 0) {
                    i -= 1;
                    const line = lines.items[i];
                    // Look for "checkout: moving from X to Y"
                    if (std.mem.indexOf(u8, line, "checkout: moving from ")) |pos| {
                        const rest = line[pos + "checkout: moving from ".len ..];
                        if (std.mem.indexOf(u8, rest, " to ")) |to_pos| {
                            const from_branch = rest[0..to_pos];
                            count += 1;
                            if (count == n) {
                                // If it's a branch name, output it; if it's a hash, output the hash
                                const output = std.fmt.allocPrint(allocator, "{s}\n", .{from_branch}) catch {
                                    try platform_impl.writeStderr("fatal: no previous branch\n");
                                    std.process.exit(128);
                                };
                                defer allocator.free(output);
                                try platform_impl.writeStdout(output);
                                return;
                            }
                        }
                    }
                }
            }
            try platform_impl.writeStderr("fatal: no previous branch\n");
            std.process.exit(128);
        }
        if (name.len > 0 and name[0] == '-') {
            const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' is not a valid branch name\n", .{name});
            defer allocator.free(msg); try platform_impl.writeStderr(msg); std.process.exit(128); unreachable;
        }
        const output = try std.fmt.allocPrint(allocator, "{s}\n", .{name});
        defer allocator.free(output); try platform_impl.writeStdout(output); return;
    }
    const name = refname orelse { std.process.exit(1); unreachable; };
    if (normalize) {
        const nrm = normalizeRefName_crf(allocator, name, allow_onelevel, refspec_pattern) catch { std.process.exit(1); unreachable; };
        defer allocator.free(nrm);
        const output = try std.fmt.allocPrint(allocator, "{s}\n", .{nrm});
        defer allocator.free(output); try platform_impl.writeStdout(output); return;
    }
    if (!checkRefFormatValid_crf(name, allow_onelevel, no_allow_onelevel, refspec_pattern)) { std.process.exit(1); unreachable; }
}


pub fn checkRefFormatValid_crf(name: []const u8, allow_onelevel: bool, no_allow_onelevel: bool, refspec_pattern: bool) bool {
    if (name.len == 0) return false;
    if (name.len == 1 and name[0] == '/') return false;
    const has_slash = std.mem.indexOfScalar(u8, name, '/') != null;
    if (!has_slash and !allow_onelevel) return false;
    if (!has_slash and no_allow_onelevel) return false;
    var star_count: usize = 0;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |component| {
        if (component.len == 0) return false;
        if (component[0] == '.') return false;
        if (std.mem.endsWith(u8, component, ".lock")) return false;
        for (component, 0..) |ch, ci| {
            if (ch < 0x20 or ch == 0x7f) return false;
            if (ch == ' ' or ch == '~' or ch == '^' or ch == ':' or ch == '[' or ch == '\\') return false;
            if (ch == '?') return false;
            if (ch == '*') { if (!refspec_pattern) return false; star_count += 1; if (star_count > 1) return false; }
            if (ch == '@' and ci + 1 < component.len and component[ci + 1] == '{') return false;
        }
        if (std.mem.indexOf(u8, component, "..") != null) return false;
    }
    if (name[name.len - 1] == '/') return false;
    if (name[name.len - 1] == '.') return false;
    return true;
}

const LastModTreeEntry = helpers.LastModTreeEntry;


pub fn normalizeRefName_crf(allocator: std.mem.Allocator, name: []const u8, allow_onelevel: bool, refspec_pattern: bool) ![]u8 {
    if (name.len == 0) return error.InvalidRefName;
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var prev_slash = true;
    for (name) |ch| {
        if (ch == '/') { if (!prev_slash) { if (pos >= buf.len) return error.InvalidRefName; buf[pos] = '/'; pos += 1; } prev_slash = true; }
        else { prev_slash = false; if (pos >= buf.len) return error.InvalidRefName; buf[pos] = ch; pos += 1; }
    }
    while (pos > 0 and buf[pos - 1] == '/') pos -= 1;
    if (pos == 0) return error.InvalidRefName;
    if (!checkRefFormatValid_crf(buf[0..pos], allow_onelevel, false, refspec_pattern)) return error.InvalidRefName;
    return try allocator.dupe(u8, buf[0..pos]);
}
