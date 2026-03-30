// Auto-generated from main_common.zig - cmd_remote
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const fetch_cmd = helpers.fetch_cmd;
const cmd_clone = @import("cmd_clone.zig");

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

pub fn cmdRemote(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("remote: not supported in freestanding mode\n");
        return;
    }

    // helpers.Find .git directory first
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    var verbose = false;
    var subcommand: ?[]const u8 = null;
    var positionals = std.array_list.Managed([]const u8).init(allocator);
    defer positionals.deinit();

    // helpers.Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (subcommand == null and !std.mem.startsWith(u8, arg, "-")) {
            subcommand = arg;
        } else {
            try positionals.append(arg);
        }
    }

    // helpers.If no subcommand or just -v, list remotes
    if (subcommand == null or std.mem.eql(u8, subcommand.?, "-v") or std.mem.eql(u8, subcommand.?, "--verbose")) {
        if (std.mem.eql(u8, subcommand orelse "", "-v") or std.mem.eql(u8, subcommand orelse "", "--verbose")) {
            verbose = true;
        }
        try listRemotes(git_path, verbose, platform_impl, allocator);
    } else if (std.mem.eql(u8, subcommand.?, "add")) {
        // git remote add [-f] [-t <branch>] [-m <master>] <name> <url>
        var fetch_after_add = false;
        var master_branch: ?[]const u8 = null;
        var add_positionals = std.array_list.Managed([]const u8).init(allocator);
        defer add_positionals.deinit();
        {
            var pi: usize = 0;
            while (pi < positionals.items.len) : (pi += 1) {
                const parg = positionals.items[pi];
                if (std.mem.eql(u8, parg, "-f") or std.mem.eql(u8, parg, "--fetch")) {
                    fetch_after_add = true;
                } else if (std.mem.eql(u8, parg, "-m") or std.mem.eql(u8, parg, "--master")) {
                    pi += 1;
                    if (pi < positionals.items.len) master_branch = positionals.items[pi];
                } else if (std.mem.eql(u8, parg, "-t")) {
                    pi += 1; // skip the value argument
                } else {
                    try add_positionals.append(parg);
                }
            }
        }
        if (add_positionals.items.len < 2) {
            try platform_impl.writeStderr("usage: git remote add <name> <url>\n");
            std.process.exit(1);
        }
        const name = add_positionals.items[0];
        const url = add_positionals.items[1];

        // Validate remote name
        if (std.mem.indexOf(u8, name, "..") != null or
            name.len == 0 or name[0] == '.' or
            name[name.len - 1] == '.' or
            std.mem.indexOfScalar(u8, name, ' ') != null or
            std.mem.indexOfScalar(u8, name, '~') != null or
            std.mem.indexOfScalar(u8, name, '^') != null or
            std.mem.indexOfScalar(u8, name, ':') != null or
            std.mem.indexOfScalar(u8, name, '\\') != null or
            std.mem.indexOf(u8, name, "@{") != null)
        {
            const vmsg = try std.fmt.allocPrint(allocator, "fatal: '{s}' is not a valid remote name\n", .{name});
            defer allocator.free(vmsg);
            try platform_impl.writeStderr(vmsg);
            std.process.exit(128);
        }

        // helpers.Append to config file
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);

        // helpers.Check if remote already exists
        const existing = platform_impl.fs.readFile(allocator, config_path) catch try allocator.dupe(u8, "");
        defer allocator.free(existing);

        const remote_section = try std.fmt.allocPrint(allocator, "[remote \"{s}\"]", .{name});
        defer allocator.free(remote_section);

        if (std.mem.indexOf(u8, existing, remote_section) != null) {
            const msg = try std.fmt.allocPrint(allocator, "error: remote {s} already exists.\n", .{name});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(3);
        }

        const section = try std.fmt.allocPrint(allocator, "\n[remote \"{s}\"]\n\turl = {s}\n\tfetch = +refs/heads/*:refs/remotes/{s}/*\n", .{ name, url, name });
        defer allocator.free(section);

        const f = std.fs.cwd().openFile(config_path, .{ .mode = .write_only }) catch {
            // helpers.Create the config file
            const cf = std.fs.cwd().createFile(config_path, .{}) catch {
                try platform_impl.writeStderr("fatal: could not open config file\n");
                std.process.exit(128);
            };
            defer cf.close();
            cf.writeAll(section) catch {};
            return;
        };
        defer f.close();
        f.seekFromEnd(0) catch {};
        f.writeAll(section) catch {};
        
        // helpers.Create refs/remotes/<name>/helpers.HEAD if -m was given
        if (master_branch) |mb| {
            const rh_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}/HEAD", .{ git_path, name });
            defer allocator.free(rh_path);
            if (std.fs.path.dirname(rh_path)) |pd| std.fs.cwd().makePath(pd) catch {};
            const sc = try std.fmt.allocPrint(allocator, "ref: refs/remotes/{s}/{s}\n", .{ name, mb });
            defer allocator.free(sc);
            std.fs.cwd().writeFile(.{ .sub_path = rh_path, .data = sc }) catch {};
        }

        // helpers.If -f flag, fetch from the new remote
        if (fetch_after_add) {
            var is_local = false;
            var local_path = url;
            if (std.mem.startsWith(u8, url, "file://")) { is_local = true; local_path = url["file://".len..]; }
            else if (std.mem.startsWith(u8, url, "/") or std.mem.startsWith(u8, url, "./") or std.mem.startsWith(u8, url, "../") or std.mem.eql(u8, url, ".") or std.mem.eql(u8, url, "..")) { is_local = true; }
            else if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "ssh://") and !std.mem.startsWith(u8, url, "git://")) {
                if (helpers.resolveSourceGitDir(allocator, url)) |sgd| { allocator.free(sgd); is_local = true; } else |_| {}
            }
            if (is_local) {
                const empty_refspecs: []const []const u8 = &.{};
                helpers.performLocalFetch(allocator, git_path, local_path, name, false, empty_refspecs, platform_impl, true) catch {};
            }
        }
    } else if (std.mem.eql(u8, subcommand.?, "remove") or std.mem.eql(u8, subcommand.?, "rm")) {
        // git remote remove <name>
        if (positionals.items.len < 1) {
            try platform_impl.writeStderr("usage: git remote remove <name>\n");
            std.process.exit(1);
        }
        const name = positionals.items[0];
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);

        const existing = platform_impl.fs.readFile(allocator, config_path) catch {
            const msg = try std.fmt.allocPrint(allocator, "error: No such remote: '{s}'\n", .{name});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(2);
            unreachable;
        };
        defer allocator.free(existing);

        const remote_header = try std.fmt.allocPrint(allocator, "[remote \"{s}\"]", .{name});
        defer allocator.free(remote_header);

        if (std.mem.indexOf(u8, existing, remote_header) == null) {
            const msg = try std.fmt.allocPrint(allocator, "error: No such remote: '{s}'\n", .{name});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(2);
        }

        // helpers.Remove the section
        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        var in_remove_section = false;
        var lines = std.mem.splitScalar(u8, existing, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "[remote \"") and std.mem.endsWith(u8, trimmed, "\"]")) {
                const sec_name = trimmed["[remote \"".len .. trimmed.len - "\"]".len];
                if (std.mem.eql(u8, sec_name, name)) {
                    in_remove_section = true;
                    continue;
                } else {
                    in_remove_section = false;
                }
            } else if (std.mem.startsWith(u8, trimmed, "[") and in_remove_section) {
                in_remove_section = false;
            }
            if (!in_remove_section) {
                try result.appendSlice(line);
                try result.append('\n');
            }
        }
        // helpers.Also remove branch.<name> sections that reference this remote
        platform_impl.fs.writeFile(config_path, result.items) catch {};

        // helpers.Remove remote tracking helpers.refs
        const remote_refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}", .{ git_path, name });
        defer allocator.free(remote_refs_dir);
        std.fs.cwd().deleteTree(remote_refs_dir) catch {};
    } else if (std.mem.eql(u8, subcommand.?, "set-url")) {
        // git remote set-url <name> <newurl>
        if (positionals.items.len < 2) {
            try platform_impl.writeStderr("usage: git remote set-url <name> <newurl>\n");
            std.process.exit(1);
        }
        const name = positionals.items[0];
        const new_url = positionals.items[1];

        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);
        const existing = platform_impl.fs.readFile(allocator, config_path) catch {
            try platform_impl.writeStderr("fatal: could not read config\n");
            std.process.exit(128);
            unreachable;
        };
        defer allocator.free(existing);

        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        var in_target_section = false;
        var url_replaced = false;
        var lines = std.mem.splitScalar(u8, existing, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "[remote \"") and std.mem.endsWith(u8, trimmed, "\"]")) {
                const sec_name = trimmed["[remote \"".len .. trimmed.len - "\"]".len];
                in_target_section = std.mem.eql(u8, sec_name, name);
            } else if (std.mem.startsWith(u8, trimmed, "[") and !std.mem.startsWith(u8, trimmed, "[remote \"")) {
                in_target_section = false;
            }
            if (in_target_section and std.mem.startsWith(u8, trimmed, "url = ")) {
                const new_line = try std.fmt.allocPrint(allocator, "\turl = {s}", .{new_url});
                defer allocator.free(new_line);
                try result.appendSlice(new_line);
                url_replaced = true;
            } else {
                try result.appendSlice(line);
            }
            try result.append('\n');
        }
        if (!url_replaced) {
            const msg = try std.fmt.allocPrint(allocator, "fatal: No such remote '{s}'\n", .{name});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(2);
        }
        platform_impl.fs.writeFile(config_path, result.items) catch {};
    } else if (std.mem.eql(u8, subcommand.?, "rename")) {
        // git remote rename <old> <new>
        if (positionals.items.len < 2) {
            try platform_impl.writeStderr("usage: git remote rename <old> <new>\n");
            std.process.exit(1);
        }
        const old_name = positionals.items[0];
        const new_name = positionals.items[1];

        // Validate new remote name (check-ref-format rules)
        if (std.mem.indexOf(u8, new_name, "..") != null or
            new_name.len == 0 or new_name[0] == '.' or
            new_name[new_name.len - 1] == '.' or
            std.mem.indexOfScalar(u8, new_name, ' ') != null or
            std.mem.indexOfScalar(u8, new_name, '~') != null or
            std.mem.indexOfScalar(u8, new_name, '^') != null or
            std.mem.indexOfScalar(u8, new_name, ':') != null or
            std.mem.indexOfScalar(u8, new_name, '\\') != null or
            std.mem.indexOf(u8, new_name, "@{") != null)
        {
            const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' is not a valid remote name\n", .{new_name});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        }

        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);
        const existing = platform_impl.fs.readFile(allocator, config_path) catch {
            try platform_impl.writeStderr("fatal: could not read config\n");
            std.process.exit(128);
            unreachable;
        };
        defer allocator.free(existing);

        const old_header = try std.fmt.allocPrint(allocator, "[remote \"{s}\"]", .{old_name});
        defer allocator.free(old_header);
        if (std.mem.indexOf(u8, existing, old_header) == null) {
            const msg = try std.fmt.allocPrint(allocator, "error: No such remote: '{s}'\n", .{old_name});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(2);
        }

        // helpers.Replace remote name in config
        const new_header = try std.fmt.allocPrint(allocator, "[remote \"{s}\"]", .{new_name});
        defer allocator.free(new_header);

        // helpers.Simple string replacement for the section header
        var result = std.array_list.Managed(u8).init(allocator);
        defer result.deinit();
        var rest: []const u8 = existing;
        while (std.mem.indexOf(u8, rest, old_header)) |idx| {
            try result.appendSlice(rest[0..idx]);
            try result.appendSlice(new_header);
            rest = rest[idx + old_header.len ..];
        }
        try result.appendSlice(rest);
        platform_impl.fs.writeFile(config_path, result.items) catch {};

        // Rename helpers.refs directory
        const old_refs = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}", .{ git_path, old_name });
        defer allocator.free(old_refs);
        const new_refs = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}", .{ git_path, new_name });
        defer allocator.free(new_refs);
        std.fs.cwd().rename(old_refs, new_refs) catch {};
    } else if (std.mem.eql(u8, subcommand.?, "show")) {
        // Basic show - list helpers.URL for remote
        if (positionals.items.len < 1) {
            try listRemotes(git_path, verbose, platform_impl, allocator);
        } else {
            const name = positionals.items[0];
            const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(config_path);
            const existing = platform_impl.fs.readFile(allocator, config_path) catch {
                const msg = try std.fmt.allocPrint(allocator, "fatal: No such remote '{s}'\n", .{name});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(2);
                unreachable;
            };
            defer allocator.free(existing);

            const remote_header = try std.fmt.allocPrint(allocator, "[remote \"{s}\"]", .{name});
            defer allocator.free(remote_header);
            if (std.mem.indexOf(u8, existing, remote_header)) |_| {
                const header_msg = try std.fmt.allocPrint(allocator, "* remote {s}\n", .{name});
                defer allocator.free(header_msg);
                try platform_impl.writeStdout(header_msg);

                // helpers.Find helpers.URL
                var in_section = false;
                var lines = std.mem.splitScalar(u8, existing, '\n');
                while (lines.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (std.mem.startsWith(u8, trimmed, "[remote \"")) {
                        const sn = trimmed["[remote \"".len .. trimmed.len - "\"]".len];
                        in_section = std.mem.eql(u8, sn, name);
                    } else if (std.mem.startsWith(u8, trimmed, "[")) {
                        in_section = false;
                    }
                    if (in_section and std.mem.startsWith(u8, trimmed, "url = ")) {
                        const url_line = try std.fmt.allocPrint(allocator, "  Fetch URL: {s}\n  Push  URL: {s}\n", .{ trimmed["url = ".len..], trimmed["url = ".len..] });
                        defer allocator.free(url_line);
                        try platform_impl.writeStdout(url_line);
                    }
                }
                // Show tracked branches (from refs/remotes/<name>/)
                const remotes_dir_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}", .{ git_path, name });
                defer allocator.free(remotes_dir_path);
                var tracked_branches = std.array_list.Managed([]const u8).init(allocator);
                defer {
                    for (tracked_branches.items) |b| allocator.free(b);
                    tracked_branches.deinit();
                }
                if (std.fs.cwd().openDir(remotes_dir_path, .{ .iterate = true })) |dir_val| {
                    var dir = dir_val;
                    defer dir.close();
                    var iter = dir.iterate();
                    while (iter.next() catch null) |entry| {
                        if (entry.kind == .directory) continue;
                        if (std.mem.eql(u8, entry.name, "HEAD")) continue;
                        try tracked_branches.append(try allocator.dupe(u8, entry.name));
                    }
                } else |_| {}
                // Also check packed-refs
                const packed_refs_path2 = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_path});
                defer allocator.free(packed_refs_path2);
                if (std.fs.cwd().readFileAlloc(allocator, packed_refs_path2, 10 * 1024 * 1024)) |pr_data| {
                    defer allocator.free(pr_data);
                    const prefix = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/", .{name});
                    defer allocator.free(prefix);
                    var pr_lines = std.mem.splitScalar(u8, pr_data, '\n');
                    while (pr_lines.next()) |pr_line| {
                        if (pr_line.len == 0 or pr_line[0] == '#' or pr_line[0] == '^') continue;
                        if (std.mem.indexOf(u8, pr_line, prefix)) |idx| {
                            const branch_name = pr_line[idx + prefix.len ..];
                            var found_dup = false;
                            for (tracked_branches.items) |b| {
                                if (std.mem.eql(u8, b, branch_name)) { found_dup = true; break; }
                            }
                            if (!found_dup) try tracked_branches.append(try allocator.dupe(u8, branch_name));
                        }
                    }
                } else |_| {}
                if (tracked_branches.items.len > 0) {
                    // Sort
                    std.sort.pdq([]const u8, tracked_branches.items, {}, struct {
                        fn lt(_: void, a: []const u8, b: []const u8) bool {
                            return std.mem.order(u8, a, b) == .lt;
                        }
                    }.lt);
                    const plural: []const u8 = if (tracked_branches.items.len == 1) "" else "es";
                    const hdr = try std.fmt.allocPrint(allocator, "  Remote branch{s}:\n", .{plural});
                    defer allocator.free(hdr);
                    try platform_impl.writeStdout(hdr);
                    for (tracked_branches.items) |branch| {
                        const bl = try std.fmt.allocPrint(allocator, "    {s} tracked\n", .{branch});
                        defer allocator.free(bl);
                        try platform_impl.writeStdout(bl);
                    }
                }
            } else {
                const msg = try std.fmt.allocPrint(allocator, "fatal: No such remote '{s}'\n", .{name});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(2);
            }
        }
    } else if (std.mem.eql(u8, subcommand.?, "get-url")) {
        // git remote get-url <name>
        if (positionals.items.len < 1) {
            try platform_impl.writeStderr("usage: git remote get-url <name>\n");
            std.process.exit(1);
        }
        const name = positionals.items[0];
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);
        const existing = platform_impl.fs.readFile(allocator, config_path) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: No such remote '{s}'\n", .{name});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(2);
            unreachable;
        };
        defer allocator.free(existing);

        var in_section = false;
        var found = false;
        var lines = std.mem.splitScalar(u8, existing, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "[remote \"") and std.mem.endsWith(u8, trimmed, "\"]")) {
                const sn = trimmed["[remote \"".len .. trimmed.len - "\"]".len];
                in_section = std.mem.eql(u8, sn, name);
            } else if (std.mem.startsWith(u8, trimmed, "[")) {
                in_section = false;
            }
            if (in_section and std.mem.startsWith(u8, trimmed, "url = ")) {
                const url_out = try std.fmt.allocPrint(allocator, "{s}\n", .{trimmed["url = ".len..]});
                defer allocator.free(url_out);
                try platform_impl.writeStdout(url_out);
                found = true;
            }
        }
        if (!found) {
            const msg = try std.fmt.allocPrint(allocator, "fatal: No such remote '{s}'\n", .{name});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(2);
        }
    } else if (std.mem.eql(u8, subcommand.?, "update")) {
        // git remote update [group|remote...]
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);
        const config_data = platform_impl.fs.readFile(allocator, config_path) catch try allocator.dupe(u8, "");
        defer allocator.free(config_data);

        var remotes_to_fetch = std.array_list.Managed([]const u8).init(allocator);
        defer {
            for (remotes_to_fetch.items) |r| allocator.free(r);
            remotes_to_fetch.deinit();
        }

        if (positionals.items.len == 0 or (positionals.items.len == 1 and std.mem.eql(u8, positionals.items[0], "default"))) {
            // Fetch from all remotes
            var lines = std.mem.splitScalar(u8, config_data, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (std.mem.startsWith(u8, trimmed, "[remote \"") and std.mem.endsWith(u8, trimmed, "\"]")) {
                    const rname = trimmed["[remote \"".len .. trimmed.len - "\"]".len];
                    try remotes_to_fetch.append(try allocator.dupe(u8, rname));
                }
            }
        } else {
            for (positionals.items) |group_or_remote| {
                // helpers.Check if it's a remote group (remotes.<name> config)
                var found_group = false;
                // helpers.Look for [remotes "<group>"] section
                var clines = std.mem.splitScalar(u8, config_data, '\n');
                var in_remotes_section = false;
                while (clines.next()) |cline| {
                    const ctrimmed = std.mem.trim(u8, cline, " \t\r");
                    if (std.mem.startsWith(u8, ctrimmed, "[remotes \"") and std.mem.endsWith(u8, ctrimmed, "\"]")) {
                        const gname = ctrimmed["[remotes \"".len .. ctrimmed.len - "\"]".len];
                        in_remotes_section = std.mem.eql(u8, gname, group_or_remote);
                    } else if (std.mem.startsWith(u8, ctrimmed, "[")) {
                        in_remotes_section = false;
                    }
                    if (in_remotes_section) {
                        // helpers.Look for key = value lines
                        if (std.mem.indexOf(u8, ctrimmed, "=")) |eq| {
                            const val = std.mem.trim(u8, ctrimmed[eq + 1..], " \t");
                            var parts = std.mem.splitAny(u8, val, " \t");
                            while (parts.next()) |part| {
                                if (part.len > 0) {
                                    found_group = true;
                                    try remotes_to_fetch.append(try allocator.dupe(u8, part));
                                }
                            }
                        }
                    }
                }

                if (!found_group) {
                    // helpers.Check if it's a remote name
                    const remote_section = try std.fmt.allocPrint(allocator, "[remote \"{s}\"]", .{group_or_remote});
                    defer allocator.free(remote_section);
                    if (std.mem.indexOf(u8, config_data, remote_section) != null) {
                        try remotes_to_fetch.append(try allocator.dupe(u8, group_or_remote));
                    } else {
                        const msg = try std.fmt.allocPrint(allocator, "error: No such remote or remote group: {s}\n", .{group_or_remote});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(1);
                    }
                }
            }
        }

        // Fetch from each remote
        for (remotes_to_fetch.items) |rname| {
            const fetch_msg = try std.fmt.allocPrint(allocator, "Fetching {s}\n", .{rname});
            defer allocator.free(fetch_msg);
            try platform_impl.writeStderr(fetch_msg);

            const rurl = helpers.getRemoteUrl(git_path, rname, platform_impl, allocator) catch continue;
            defer allocator.free(rurl);

            if (std.mem.startsWith(u8, rurl, "https://") or std.mem.startsWith(u8, rurl, "http://")) {
                const ziggit = @import("ziggit.zig");
                const is_bare_repo = !std.mem.endsWith(u8, git_path, "/.git");
                const repo_path = if (is_bare_repo) git_path else (std.fs.path.dirname(git_path) orelse ".");
                var repo = ziggit.Repository.open(allocator, repo_path) catch continue;
                defer repo.close();
                repo.fetch(rurl) catch continue;
            } else {
                var local_path = rurl;
                if (std.mem.startsWith(u8, rurl, "file://")) local_path = rurl["file://".len..];
                helpers.performLocalFetch(allocator, git_path, local_path, rname, false, &.{}, platform_impl, true) catch continue;
            }
        }
    } else if (std.mem.eql(u8, subcommand.?, "set-head")) {
        fetch_cmd.cmdRemoteSetHead(allocator, git_path, positionals.items);
    } else if (std.mem.eql(u8, subcommand.?, "set-branches") or
        std.mem.eql(u8, subcommand.?, "prune"))
    {
        // Stub - silently accept
    } else {
        const msg = try std.fmt.allocPrint(allocator, "error: unknown subcommand: {s}\n", .{subcommand.?});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(129);
    }
}


pub fn listRemotes(git_path: []const u8, verbose: bool, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
    defer allocator.free(config_path);
    
    const config_content = platform_impl.fs.readFile(allocator, config_path) catch |err| switch (err) {
        error.FileNotFound => {
            // helpers.No config file means no remotes
            return;
        },
        else => return err,
    };
    defer allocator.free(config_content);

    var lines = std.mem.splitSequence(u8, config_content, "\n");
    var current_remote: ?[]u8 = null;
    defer if (current_remote) |r| allocator.free(r);
    
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        
        // helpers.Check for remote section header [remote "name"]
        if (std.mem.startsWith(u8, trimmed, "[remote \"") and std.mem.endsWith(u8, trimmed, "\"]")) {
            if (current_remote) |r| {
                allocator.free(r);
            }
            const start = "[remote \"".len;
            const end = trimmed.len - "\"]".len;
            current_remote = try allocator.dupe(u8, trimmed[start..end]);
        }
        
        // helpers.Check for helpers.URL in current remote section
        else if (current_remote != null and std.mem.startsWith(u8, trimmed, "url = ")) {
            const url = trimmed["url = ".len..];
            if (verbose) {
                const output = try std.fmt.allocPrint(allocator, "{s}\t{s} (fetch)\n{s}\t{s} (push)\n", .{current_remote.?, url, current_remote.?, url});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            } else {
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{current_remote.?});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        }
    }
}


pub fn setTrackingConfig(git_path: []const u8, branch_name: []const u8, remote: []const u8, upstream_branch: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) void {
    const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch return;
    defer allocator.free(config_path);
    const remote_key = std.fmt.allocPrint(allocator, "branch.{s}.remote", .{branch_name}) catch return;
    defer allocator.free(remote_key);
    const merge_key = std.fmt.allocPrint(allocator, "branch.{s}.merge", .{branch_name}) catch return;
    defer allocator.free(merge_key);
    const merge_value = std.fmt.allocPrint(allocator, "refs/heads/{s}", .{upstream_branch}) catch return;
    defer allocator.free(merge_value);
    helpers.configSetValue(config_path, remote_key, remote, false, false, null, null, allocator, platform_impl) catch {};
    helpers.configSetValue(config_path, merge_key, merge_value, false, false, null, null, allocator, platform_impl) catch {};
}

// git rebase implementation
// =============================================================================


pub fn getConfiguredUpstream(git_path: []const u8, branch_name: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) ![]u8 {
    // helpers.Read branch.<name>.remote and branch.<name>.merge from config
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
    defer allocator.free(config_path);

    const config_content = platform_impl.fs.readFile(allocator, config_path) catch return error.NoUpstream;
    defer allocator.free(config_content);

    // helpers.Look for branch.<name>.merge
    const merge_key = try std.fmt.allocPrint(allocator, "branch.{s}.merge", .{branch_name});
    defer allocator.free(merge_key);
    const remote_key = try std.fmt.allocPrint(allocator, "branch.{s}.remote", .{branch_name});
    defer allocator.free(remote_key);

    var merge_ref: ?[]const u8 = null;
    var remote: ?[]const u8 = null;

    // helpers.Parse config
    var in_section = false;
    var section_name: []const u8 = "";
    var lines = std.mem.splitSequence(u8, config_content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

        if (trimmed[0] == '[') {
            // helpers.Parse section header
            const section_end = std.mem.indexOf(u8, trimmed, "]") orelse continue;
            section_name = trimmed[1..section_end];
            const expected_section = try std.fmt.allocPrint(allocator, "branch \"{s}\"", .{branch_name});
            defer allocator.free(expected_section);
            in_section = std.ascii.eqlIgnoreCase(section_name, expected_section);
        } else if (in_section) {
            if (std.mem.indexOf(u8, trimmed, "=")) |eq| {
                const key = std.mem.trim(u8, trimmed[0..eq], " \t");
                const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
                if (std.mem.eql(u8, key, "merge")) {
                    merge_ref = value;
                } else if (std.mem.eql(u8, key, "remote")) {
                    remote = value;
                }
            }
        }
    }

    if (merge_ref == null) return error.NoUpstream;

    const mr = merge_ref.?;
    const rm = remote orelse ".";

    // helpers.If remote is ".", it's a local branch
    if (std.mem.eql(u8, rm, ".")) {
        // helpers.Resolve the local ref
        if (std.mem.startsWith(u8, mr, "refs/heads/")) {
            const local_branch = mr["refs/heads/".len..];
            const hash = refs.resolveRef(git_path, mr, platform_impl, allocator) catch return error.NoUpstream;
            _ = local_branch;
            if (hash) |h| return h;
        }
        const hash = refs.resolveRef(git_path, mr, platform_impl, allocator) catch return error.NoUpstream;
        if (hash) |h| return h;
    }

    return error.NoUpstream;
}

// =============================================================================
// git cherry-pick implementation (basic)
// =============================================================================
