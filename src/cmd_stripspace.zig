// Auto-generated from main_common.zig - cmd_stripspace
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

pub fn cmdStripspace(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var strip_comments = false;
    var comment_lines = false;
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--strip-comments")) {
            strip_comments = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--comment-lines")) {
            comment_lines = true;
        }
    }
    
    // helpers.Resolve comment character
    var cc: []const u8 = "#";
    var cc_needs_free = false;
    
    // helpers.Check -c overrides first
    if (helpers.getConfigOverride("core.commentchar") orelse helpers.getConfigOverride("core.commentChar")) |override_val| {
        if (override_val.len == 0) {
            try platform_impl.writeStderr("fatal: core.commentchar must have at least one character\n");
            std.process.exit(128);
        }
        if (std.mem.indexOfScalar(u8, override_val, '\n') != null) {
            try platform_impl.writeStderr("fatal: core.commentchar cannot contain newline\n");
            std.process.exit(128);
        }
        cc = override_val;
    } else {
        // helpers.Check .git/config
        const git_dir_result = helpers.findGitDirectory(allocator, platform_impl) catch null;
        if (git_dir_result) |gd| {
            defer allocator.free(gd);
            const config_path = std.fs.path.join(allocator, &.{ gd, "config" }) catch null;
            if (config_path) |cp| {
                defer allocator.free(cp);
                const config_data = std.fs.cwd().readFileAlloc(allocator, cp, 1024 * 1024) catch null;
                if (config_data) |cd| {
                    defer allocator.free(cd);
                    if (helpers.parseConfigValue(cd, "core.commentchar", allocator) catch null) |val| {
                        if (val.len > 0) {
                            cc = val;
                            cc_needs_free = true;
                        } else {
                            allocator.free(val);
                        }
                    }
                }
            }
        }
    }
    defer if (cc_needs_free) allocator.free(cc);
    
    const stdin_data = helpers.readStdin(allocator, 10 * 1024 * 1024) catch {
        return;
    };
    defer allocator.free(stdin_data);
    
    if (comment_lines) {
        // Prefix each line with comment char + space
        var data = stdin_data;
        // helpers.Remove trailing newline for splitting
        if (data.len > 0 and data[data.len - 1] == '\n') {
            data = data[0 .. data.len - 1];
        }
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) {
                try platform_impl.writeStdout(cc);
                try platform_impl.writeStdout("\n");
            } else if (line[0] == '\t') {
                // helpers.Avoid SP-HT sequence: use commentchar+tab directly
                try platform_impl.writeStdout(cc);
                const out = try std.fmt.allocPrint(allocator, "{s}\n", .{line});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            } else {
                const out = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ cc, line });
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            }
        }
        return;
    }
    
    // helpers.Strip trailing whitespace, collapse blank lines, strip comments
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    var blank_count: u32 = 0;
    var lines = std.mem.splitScalar(u8, stdin_data, '\n');
    var has_content = false;
    
    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        
        if (strip_comments and trimmed.len >= cc.len and std.mem.startsWith(u8, trimmed, cc)) {
            continue; // skip comment lines
        }
        
        if (trimmed.len == 0) {
            blank_count += 1;
            continue;
        }
        
        // helpers.Add at most one blank line between content
        if (has_content and blank_count > 0) {
            try result.append('\n');
        }
        blank_count = 0;
        has_content = true;
        
        try result.appendSlice(trimmed);
        try result.append('\n');
    }
    
    try platform_impl.writeStdout(result.items);
}
