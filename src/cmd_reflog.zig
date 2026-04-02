// Auto-generated from main_common.zig - cmd_reflog
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const succinct_mod = @import("succinct.zig");

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

pub fn nativeCmdReflog(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var subcmd: []const u8 = "show";
    var ref_name: []const u8 = "HEAD";
    var ref_name_set = false;
    var end_of_options = false;
    var format: ?[]const u8 = null;
    var max_count: ?usize = null;
    var grep_pattern: ?[]const u8 = null;
    var fixed_strings = false;
    var fixed_strings_explicit = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (end_of_options) {
            ref_name = arg;
            ref_name_set = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--") or std.mem.eql(u8, arg, "--end-of-options")) {
            end_of_options = true;
        } else if (std.mem.eql(u8, arg, "show") or std.mem.eql(u8, arg, "expire") or
            std.mem.eql(u8, arg, "delete") or std.mem.eql(u8, arg, "exists"))
        {
            subcmd = arg;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git reflog [show|expire|delete|exists] [<ref>]\n");
            std.process.exit(129);
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            format = arg["--format=".len..];
        } else if (std.mem.startsWith(u8, arg, "--grep=")) {
            grep_pattern = arg["--grep=".len..];
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings")) {
            fixed_strings = true;
            fixed_strings_explicit = true;
        } else if (std.mem.eql(u8, arg, "-G") or std.mem.eql(u8, arg, "--basic-regexp") or std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--extended-regexp") or std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--perl-regexp")) {
            fixed_strings = false;
            fixed_strings_explicit = true;
        } else if (std.mem.eql(u8, arg, "-n")) {
            if (i + 1 < args.len) {
                i += 1;
                max_count = std.fmt.parseInt(usize, args[i], 10) catch null;
            }
        } else if (arg.len >= 2 and arg[0] == '-' and arg[1] >= '0' and arg[1] <= '9') {
            // -N shorthand for -n N
            max_count = std.fmt.parseInt(usize, arg[1..], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--all") or
            std.mem.startsWith(u8, arg, "--expire=") or std.mem.eql(u8, arg, "--verbose") or
            std.mem.eql(u8, arg, "--rewrite") or std.mem.eql(u8, arg, "--updateref") or
            std.mem.eql(u8, arg, "--stale-fix") or std.mem.eql(u8, arg, "--dry-run"))
        {
            // Accepted flags
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // helpers.Unknown option
            if (std.mem.eql(u8, subcmd, "exists")) {
                const emsg = try std.fmt.allocPrint(allocator, "error: unknown option '{s}'\nusage: git reflog exists <ref>\n", .{arg});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(129);
            }
        } else {
            ref_name = arg;
            ref_name_set = true;
        }
    }

    // "exists" with no ref should exit 129
    if (std.mem.eql(u8, subcmd, "exists") and !ref_name_set) {
        try platform_impl.writeStderr("usage: git reflog exists <ref>\n");
        std.process.exit(129);
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // Read grep.patternType from config
    if (!fixed_strings_explicit) {
        if (helpers.getConfigValueByKey(git_dir, "grep.patterntype", allocator)) |pt_val| {
            if (std.ascii.eqlIgnoreCase(pt_val, "fixed")) {
                fixed_strings = true;
            }
            allocator.free(pt_val);
        }
    }

    if (std.mem.eql(u8, subcmd, "show")) {
        // helpers.Read reflog file
        var reflog_path: []const u8 = undefined;
        if (std.mem.eql(u8, ref_name, "HEAD")) {
            reflog_path = std.fmt.allocPrint(allocator, "{s}/logs/HEAD", .{git_dir}) catch unreachable;
        } else if (std.mem.startsWith(u8, ref_name, "refs/")) {
            reflog_path = std.fmt.allocPrint(allocator, "{s}/logs/{s}", .{ git_dir, ref_name }) catch unreachable;
        } else {
            // Try refs/<name> first (for stash, bisect, etc.), then refs/heads/<name>
            const try_ref = std.fmt.allocPrint(allocator, "{s}/logs/refs/{s}", .{ git_dir, ref_name }) catch unreachable;
            if (std.fs.cwd().access(try_ref, .{})) |_| {
                reflog_path = try_ref;
            } else |_| {
                allocator.free(try_ref);
                reflog_path = std.fmt.allocPrint(allocator, "{s}/logs/refs/heads/{s}", .{ git_dir, ref_name }) catch unreachable;
            }
        }
        defer allocator.free(reflog_path);

        const content = std.fs.cwd().readFileAlloc(allocator, reflog_path, 10 * 1024 * 1024) catch {
            // helpers.No reflog
            return;
        };
        defer allocator.free(content);

        // helpers.Parse and display reflog entries in reverse order
        var entries = std.array_list.Managed([]const u8).init(allocator);
        defer entries.deinit();
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) {
                try entries.append(line);
            }
        }

        // helpers.Output in reverse order using buffered writer
        var entry_idx: usize = entries.items.len;
        var seq: usize = 0;
        var output_count: usize = 0;
        // Pre-allocate output buffer to avoid per-line allocations
        var out_buf = std.array_list.Managed(u8).init(allocator);
        defer out_buf.deinit();
        try out_buf.ensureTotalCapacity(entries.items.len * 80); // estimate ~80 bytes per line
        var buf_writer = out_buf.writer();
        while (entry_idx > 0) {
            if (max_count) |mc| {
                if (output_count >= mc) break;
            }
            entry_idx -= 1;
            const line = entries.items[entry_idx];
            // Format: <old-sha1> <new-sha1> <author> <timestamp> <tz>\t<message>
            if (std.mem.indexOfScalar(u8, line, '\t')) |tab| {
                const msg = line[tab + 1..];
                // helpers.Extract new sha and old sha
                if (line.len >= 82) {
                    const new_sha = line[41..81];

                    // Apply --grep filtering
                    if (grep_pattern) |gp| {
                        // Load commit to get message for filtering
                        const grep_obj = objects.GitObject.load(new_sha, git_dir, platform_impl, allocator) catch null;
                        defer if (grep_obj) |o| o.deinit(allocator);
                        const grep_msg = if (grep_obj) |o| blk: {
                            if (std.mem.indexOf(u8, o.data, "\n\n")) |pos| break :blk o.data[pos + 2 ..];
                            break :blk "";
                        } else "";
                        const matched = if (fixed_strings)
                            std.mem.indexOf(u8, grep_msg, gp) != null
                        else
                            simpleGrepMatch(grep_msg, gp);
                        if (!matched) {
                            seq += 1;
                            continue;
                        }
                    }

                    if (format) |fmt| {
                        // Simple format string handling
                        var fi: usize = 0;
                        while (fi < fmt.len) {
                            if (fmt[fi] == '%' and fi + 1 < fmt.len) {
                                switch (fmt[fi + 1]) {
                                    'H' => buf_writer.writeAll(new_sha) catch {},
                                    'h' => buf_writer.writeAll(new_sha[0..@min(7, new_sha.len)]) catch {},
                                    's' => buf_writer.writeAll(msg) catch {},
                                    'n' => buf_writer.writeByte('\n') catch {},
                                    else => {
                                        buf_writer.writeByte('%') catch {};
                                        buf_writer.writeByte(fmt[fi + 1]) catch {};
                                    },
                                }
                                fi += 2;
                            } else {
                                buf_writer.writeByte(fmt[fi]) catch {};
                                fi += 1;
                            }
                        }
                        buf_writer.writeByte('\n') catch {};
                    } else {
                        if (succinct_mod.isEnabled()) {
                            // Succinct format: "HASH action (relative-date)"
                            buf_writer.writeAll(new_sha[0..@min(7, new_sha.len)]) catch continue;
                            buf_writer.writeByte(' ') catch continue;
                            buf_writer.writeAll(msg) catch continue;
                            buf_writer.writeAll(" (") catch continue;
                            
                            // Parse timestamp from line format: <old-sha1> <new-sha1> <author> <timestamp> <tz>
                            const header = line[0..tab];
                            var parts = std.mem.splitScalar(u8, header, ' ');
                            _ = parts.next(); // old-sha1
                            _ = parts.next(); // new-sha1
                            // Skip author (name and email)
                            var timestamp_str: ?[]const u8 = null;
                            var part_count: usize = 0;
                            while (parts.next()) |part| {
                                part_count += 1;
                                // Timestamp is usually the last or second-to-last space-separated part before tab
                                // Look for a numeric timestamp (all digits)
                                if (part.len > 0 and std.ascii.isDigit(part[0])) {
                                    var all_digits = true;
                                    for (part) |c| {
                                        if (!std.ascii.isDigit(c)) {
                                            all_digits = false;
                                            break;
                                        }
                                    }
                                    if (all_digits and part.len > 8) { // timestamps are long numbers
                                        timestamp_str = part;
                                    }
                                }
                            }
                            
                            if (timestamp_str) |ts| {
                                const timestamp = std.fmt.parseInt(i64, ts, 10) catch 0;
                                if (timestamp > 0) {
                                    const now = std.time.timestamp();
                                    const diff = now - timestamp;
                                    if (diff < 60) {
                                        buf_writer.print("{d} seconds ago", .{diff}) catch continue;
                                    } else if (diff < 3600) {
                                        buf_writer.print("{d} minutes ago", .{diff / 60}) catch continue;
                                    } else if (diff < 86400) {
                                        buf_writer.print("{d} hours ago", .{diff / 3600}) catch continue;
                                    } else {
                                        buf_writer.print("{d} days ago", .{diff / 86400}) catch continue;
                                    }
                                } else {
                                    buf_writer.writeAll("unknown time") catch continue;
                                }
                            } else {
                                buf_writer.writeAll("unknown time") catch continue;
                            }
                            buf_writer.writeByte(')') catch continue;
                            buf_writer.writeByte('\n') catch continue;
                        } else {
                            // Write directly: "<short_sha> <ref>@{<seq>}: <msg>\n"
                            buf_writer.writeAll(new_sha[0..@min(7, new_sha.len)]) catch continue;
                            buf_writer.writeByte(' ') catch continue;
                            buf_writer.writeAll(ref_name) catch continue;
                            buf_writer.print("@{{{d}}}: ", .{seq}) catch continue;
                            buf_writer.writeAll(msg) catch continue;
                            buf_writer.writeByte('\n') catch continue;
                        }
                    }
                    output_count += 1;
                }
            }
            seq += 1;
        }
        // Flush all output at once
        if (out_buf.items.len > 0) {
            try platform_impl.writeStdout(out_buf.items);
        }
    } else if (std.mem.eql(u8, subcmd, "expire")) {
        // Expire old reflog entries - for now, no-op
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        // helpers.Delete specific reflog entries - for now, no-op
    } else if (std.mem.eql(u8, subcmd, "exists")) {
        // helpers.Check if a reflog exists - try multiple paths
        var found_reflog = false;
        const p1 = std.fmt.allocPrint(allocator, "{s}/logs/{s}", .{ git_dir, ref_name }) catch unreachable;
        defer allocator.free(p1);
        if (std.fs.cwd().statFile(p1)) |_| { found_reflog = true; } else |_| {}
        if (!found_reflog and std.mem.startsWith(u8, ref_name, "refs/heads/")) {
            const branch = ref_name["refs/heads/".len..];
            const p2 = std.fmt.allocPrint(allocator, "{s}/logs/{s}", .{ git_dir, branch }) catch unreachable;
            defer allocator.free(p2);
            if (std.fs.cwd().statFile(p2)) |_| { found_reflog = true; } else |_| {}
        }
        if (!found_reflog and !std.mem.startsWith(u8, ref_name, "refs/")) {
            const p3 = std.fmt.allocPrint(allocator, "{s}/logs/refs/heads/{s}", .{ git_dir, ref_name }) catch unreachable;
            defer allocator.free(p3);
            if (std.fs.cwd().statFile(p3)) |_| { found_reflog = true; } else |_| {}
        }
        if (!found_reflog) std.process.exit(1);
    }
}


/// Simple grep match: supports '.' as wildcard (single char) in non-fixed mode
fn simpleGrepMatch(text: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;
    // Check each line
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len >= pattern.len) {
            var si: usize = 0;
            while (si + pattern.len <= line.len) : (si += 1) {
                var match = true;
                for (0..pattern.len) |pi| {
                    if (pattern[pi] != '.' and pattern[pi] != line[si + pi]) {
                        match = false;
                        break;
                    }
                }
                if (match) return true;
            }
        }
    }
    return false;
}

pub fn shouldLogRef(git_dir: []const u8, ref_name: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) bool {
    // helpers.Check core.logAllRefUpdates config
    const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_dir}) catch return false;
    defer allocator.free(config_path);
    const config_data = platform_impl.fs.readFile(allocator, config_path) catch return false;
    defer allocator.free(config_data);
    
    if (helpers.parseConfigValue(config_data, "core.logallrefupdates", allocator) catch null) |val| {
        defer allocator.free(val);
        if (std.ascii.eqlIgnoreCase(val, "always")) return true;
        if (std.ascii.eqlIgnoreCase(val, "true")) {
            // helpers.Only log refs/heads/* and helpers.HEAD
            return std.mem.startsWith(u8, ref_name, "refs/heads/") or std.mem.eql(u8, ref_name, "HEAD");
        }
    }
    return false;
}
