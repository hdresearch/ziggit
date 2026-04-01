const git_helpers_mod = @import("../git_helpers.zig");
const std = @import("std");
const platform_mod = @import("../platform/platform.zig");
const succinct_mod = @import("../succinct.zig");
const refs = @import("refs.zig");
const objects = @import("objects.zig");
const fetch_cmd = @import("fetch_cmd.zig");
const hooks = @import("../git/hooks.zig");

fn readFileContent(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
}

/// Simple config value reader (last value wins)
fn getSimpleConfigValue(config_content: []const u8, key: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const dot1 = std.mem.indexOfScalar(u8, key, '.') orelse return error.InvalidKey;
    const rest = key[dot1 + 1 ..];
    const dot2 = std.mem.lastIndexOfScalar(u8, rest, '.');
    const section = key[0..dot1];
    const subsection: ?[]const u8 = if (dot2) |d| rest[0..d] else null;
    const var_name = if (dot2) |d| rest[d + 1 ..] else rest;

    var result: ?[]u8 = null;
    var in_matching_section = false;
    var lines = std.mem.splitScalar(u8, config_content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            in_matching_section = false;
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const header = line[1..close];
            var cur_section: []const u8 = undefined;
            var cur_subsection: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, header, '"')) |q1| {
                cur_section = std.mem.trim(u8, header[0..q1], " \t");
                const after = header[q1 + 1 ..];
                if (std.mem.indexOfScalar(u8, after, '"')) |q2| cur_subsection = after[0..q2];
            } else if (std.mem.indexOfScalar(u8, header, ' ')) |sp| {
                cur_section = header[0..sp];
                cur_subsection = std.mem.trim(u8, header[sp + 1 ..], " \t\"");
            } else {
                cur_section = header;
            }
            if (std.ascii.eqlIgnoreCase(cur_section, section)) {
                if (subsection) |ss| {
                    if (cur_subsection != null and std.mem.eql(u8, cur_subsection.?, ss)) in_matching_section = true;
                } else {
                    if (cur_subsection == null) in_matching_section = true;
                }
            }
            continue;
        }
        if (!in_matching_section) continue;
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            const vkey = std.mem.trim(u8, line[0..eq], " \t");
            const vval = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(vkey, var_name)) {
                if (result) |old| allocator.free(old);
                result = try allocator.dupe(u8, vval);
            }
        }
    }
    return result orelse error.KeyNotFound;
}

fn resolveSourceGitDir(allocator: std.mem.Allocator, source_path: []const u8) ![]u8 {
    const path = if (std.mem.startsWith(u8, source_path, "file://"))
        try allocator.dupe(u8, source_path["file://".len..])
    else
        try allocator.dupe(u8, source_path);
    defer allocator.free(path);

    const abs_path = std.fs.cwd().realpathAlloc(allocator, path) catch blk: {
        const with_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{path});
        defer allocator.free(with_git);
        break :blk std.fs.cwd().realpathAlloc(allocator, with_git) catch blk2: {
            const with_git_sfx = try std.fmt.allocPrint(allocator, "{s}.git", .{path});
            defer allocator.free(with_git_sfx);
            break :blk2 std.fs.cwd().realpathAlloc(allocator, with_git_sfx) catch return error.RepositoryNotFound;
        };
    };
    errdefer allocator.free(abs_path);

    const git_objects = try std.fmt.allocPrint(allocator, "{s}/.git/objects", .{abs_path});
    defer allocator.free(git_objects);
    if (std.fs.cwd().access(git_objects, .{})) |_| {
        const result = try std.fmt.allocPrint(allocator, "{s}/.git", .{abs_path});
        allocator.free(abs_path);
        return result;
    } else |_| {}

    const objects_path = try std.fmt.allocPrint(allocator, "{s}/objects", .{abs_path});
    defer allocator.free(objects_path);
    const has_objects = if (std.fs.cwd().access(objects_path, .{})) |_| true else |_| false;
    if (has_objects) return abs_path;

    allocator.free(abs_path);
    return error.RepositoryNotFound;
}

/// Push a wildcard refspec by iterating matching local refs
fn pushWildcardRefspec(
    allocator: std.mem.Allocator,
    local_git_dir: []const u8,
    remote_git_dir: []const u8,
    src_pattern: []const u8,
    dst_pattern: []const u8,
    force: bool,
    dry_run: bool,
    quiet: bool,
    platform_impl: *const platform_mod.Platform,
) !void {
    // Both patterns must contain *
    if (std.mem.indexOfScalar(u8, src_pattern, '*') == null) return;
    if (std.mem.indexOfScalar(u8, dst_pattern, '*') == null) return;

    // Collect all local refs matching src_prefix
    var local_refs = fetch_cmd.collectAllRefs(allocator, local_git_dir) catch return;
    defer {
        for (local_refs.items) |e| {
            allocator.free(e.name);
            allocator.free(e.hash);
        }
        local_refs.deinit();
    }

    // Copy objects first
    const src_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{local_git_dir});
    defer allocator.free(src_objects);
    const dst_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{remote_git_dir});
    defer allocator.free(dst_objects);
    fetch_cmd.copyMissingObjects(src_objects, dst_objects);

    const src_packs = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{local_git_dir});
    defer allocator.free(src_packs);
    const dst_packs = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{remote_git_dir});
    defer allocator.free(dst_packs);
    fetch_cmd.copyMissingPackFiles(src_packs, dst_packs);

    var had_rejection = false;
    for (local_refs.items) |entry| {
        const suffix = fetch_cmd.refspecMatchPub(entry.name, src_pattern) orelse continue;
        const dst_ref = fetch_cmd.refspecMapPub(allocator, suffix, dst_pattern) catch continue;
        defer allocator.free(dst_ref);

        // Write the ref to the remote
        if (!dry_run) {
            const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_git_dir, dst_ref });
            defer allocator.free(ref_path);
            if (std.mem.lastIndexOfScalar(u8, ref_path, '/')) |ls| std.fs.cwd().makePath(ref_path[0..ls]) catch {};

            if (!force) {
                // Check fast-forward / tag rejection
                if (readFileContent(allocator, ref_path)) |old| {
                    defer allocator.free(old);
                    const old_h = std.mem.trim(u8, old, " \t\r\n");
                    if (old_h.len >= 40 and !std.mem.eql(u8, old_h[0..40], entry.hash)) {
                        if (std.mem.startsWith(u8, dst_ref, "refs/tags/")) {
                            if (!quiet) {
                                const tag_name = dst_ref["refs/tags/".len..];
                                const msg = try std.fmt.allocPrint(allocator, " ! [rejected]        {s} -> {s} (already exists)\nerror: failed to push some refs\n", .{ tag_name, tag_name });
                                defer allocator.free(msg);
                                try platform_impl.writeStderr(msg);
                            }
                            had_rejection = true;
                            continue;
                        }
                        if (!fetch_cmd.isAncestor(local_git_dir, old_h[0..40], entry.hash, allocator, platform_impl)) {
                            if (!quiet) {
                                const msg = try std.fmt.allocPrint(allocator, " ! [rejected]        {s} -> {s} (non-fast-forward)\n", .{ entry.name, dst_ref });
                                defer allocator.free(msg);
                                try platform_impl.writeStderr(msg);
                            }
                            had_rejection = true;
                            continue;
                        }
                    }
                } else |_| {}
            }

            const data = try std.fmt.allocPrint(allocator, "{s}\n", .{entry.hash});
            defer allocator.free(data);
            std.fs.cwd().writeFile(.{ .sub_path = ref_path, .data = data }) catch {};
        }
    }
    if (had_rejection) {
        std.process.exit(1);
    }
}

pub fn cmdPush(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("push: not supported in freestanding mode\n");
        return;
    }

    // Touch trace files
    fetch_cmd.touchTraceFiles();


    const git_path = git_helpers_mod.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Parse arguments
    var remote_name: ?[]const u8 = null;
    var refspecs_list = std.array_list.Managed([]const u8).init(allocator);
    defer refspecs_list.deinit();
    var force_push = false;
    var push_all = false;
    var push_tags = false;
    var push_delete = false;
    var push_mirror = false;
    var set_upstream = false;
    var dry_run = false;

    var quiet = false;
    var follow_tags = false;
    var push_prune = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--prune")) {
            push_prune = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force_push = true;
        } else if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "--branches")) {
            push_all = true;
        } else if (std.mem.eql(u8, arg, "--tags")) {
            push_tags = true;
        } else if (std.mem.eql(u8, arg, "--mirror")) {
            push_mirror = true;
            force_push = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delete")) {
            push_delete = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--set-upstream")) {
            set_upstream = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            // verbose mode (ignored for now)
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--follow-tags")) {
            follow_tags = true;
        } else if (std.mem.eql(u8, arg, "--no-ipv4") or std.mem.eql(u8, arg, "--no-ipv6")) {
            const msg = try std.fmt.allocPrint(allocator, "error: unknown option `{s}'\n", .{arg[2..]});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git push [<options>] [<repository> [<refspec>...]]\n");
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // Skip other unknown options
        } else {
            if (remote_name == null) {
                remote_name = arg;
            } else if (std.mem.eql(u8, arg, "tag")) {
                // "tag <name>" is shorthand for "refs/tags/<name>:refs/tags/<name>"
                if (args.next()) |tag_name| {
                    if (push_delete) {
                        // For --delete, just use the tag ref name
                        const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{tag_name});
                        try refspecs_list.append(tag_ref);
                    } else {
                        const tag_refspec = try std.fmt.allocPrint(allocator, "refs/tags/{s}:refs/tags/{s}", .{ tag_name, tag_name });
                        try refspecs_list.append(tag_refspec);
                    }
                }
            } else {
                try refspecs_list.append(arg);
            }
        }
    }

    // Resolve default remote for push
    var remote_owned: ?[]u8 = null;
    defer if (remote_owned) |ro| allocator.free(ro);
    const remote: []const u8 = if (remote_name) |rn| rn else blk: {
        // Check branch.<current>.pushRemote, then remote.pushDefault, then branch.<current>.remote
        const config_path_r = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch break :blk "origin";
        defer allocator.free(config_path_r);
        const config_content_r = readFileContent(allocator, config_path_r) catch break :blk "origin";
        defer allocator.free(config_content_r);

        if (refs.getCurrentBranch(git_path, platform_impl, allocator)) |branch| {
            defer allocator.free(branch);
            // Check branch.<name>.pushRemote
            const push_remote_key = std.fmt.allocPrint(allocator, "branch.{s}.pushRemote", .{branch}) catch break :blk "origin";
            defer allocator.free(push_remote_key);
            if (getSimpleConfigValue(config_content_r, push_remote_key, allocator)) |pr| {
                remote_owned = pr;
                break :blk pr;
            } else |_| {}
            // Check remote.pushDefault
            if (getSimpleConfigValue(config_content_r, "remote.pushDefault", allocator)) |pd| {
                remote_owned = pd;
                break :blk pd;
            } else |_| {}
            // Check branch.<name>.remote
            const remote_key = std.fmt.allocPrint(allocator, "branch.{s}.remote", .{branch}) catch break :blk "origin";
            defer allocator.free(remote_key);
            if (getSimpleConfigValue(config_content_r, remote_key, allocator)) |r| {
                remote_owned = r;
                break :blk r;
            } else |_| {}
        } else |_| {}
        break :blk "origin";
    };

    if (remote.len == 0) {
        try platform_impl.writeStderr("fatal: bad repository ''\n");
        std.process.exit(128);
    }

    // Resolve remote URL
    var remote_url: []const u8 = undefined;
    var remote_url_allocated = false;

    if (std.mem.startsWith(u8, remote, "/") or std.mem.startsWith(u8, remote, "./") or
        std.mem.startsWith(u8, remote, "../") or std.mem.eql(u8, remote, ".") or
        std.mem.eql(u8, remote, "..") or std.mem.startsWith(u8, remote, "file://"))
    {
        remote_url = remote;
    } else {
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);
        const config_content = readFileContent(allocator, config_path) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' does not appear to be a git repository\n", .{remote});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        defer allocator.free(config_content);

        const remote_section = try std.fmt.allocPrint(allocator, "[remote \"{s}\"]", .{remote});
        defer allocator.free(remote_section);

        // Use config value parser for pushurl and url
        var has_explicit_pushurl = false;
        {
            const pushurl_key = try std.fmt.allocPrint(allocator, "remote.{s}.pushurl", .{remote});
            defer allocator.free(pushurl_key);
            if (getSimpleConfigValue(config_content, pushurl_key, allocator)) |pu| {
                remote_url = pu;
                remote_url_allocated = true;
                has_explicit_pushurl = true;
            } else |_| {
                const url_key = try std.fmt.allocPrint(allocator, "remote.{s}.url", .{remote});
                defer allocator.free(url_key);
                if (getSimpleConfigValue(config_content, url_key, allocator)) |u| {
                    remote_url = u;
                    remote_url_allocated = true;
                } else |_| {}
            }
        }

        // Apply url.<base>.pushInsteadOf or url.<base>.insteadOf rewriting
        // But NOT when an explicit pushurl is configured (pushurl is used as-is)
        if (remote_url_allocated and !has_explicit_pushurl) {
            if (applyPushInsteadOf(allocator, remote_url, config_content)) |rewritten| {
                if (remote_url_allocated) allocator.free(remote_url);
                remote_url = rewritten;
                remote_url_allocated = true;
            } else if (fetch_cmd.applyInsteadOf(allocator, remote_url, config_content)) |rewritten| {
                if (remote_url_allocated) allocator.free(remote_url);
                remote_url = rewritten;
                remote_url_allocated = true;
            }
        }

        if (!remote_url_allocated) {
            // Try applying insteadOf/pushInsteadOf to the raw remote name
            if (applyPushInsteadOf(allocator, remote, config_content)) |rewritten| {
                remote_url = rewritten;
                remote_url_allocated = true;
            } else if (fetch_cmd.applyInsteadOf(allocator, remote, config_content)) |rewritten| {
                remote_url = rewritten;
                remote_url_allocated = true;
            } else if (resolveSourceGitDir(allocator, remote)) |rgd| {
                allocator.free(rgd);
                remote_url = remote;
            } else |_| {
                const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' does not appear to be a git repository\nfatal: Could not read from remote repository.\n", .{remote});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }
        }
    }
    defer if (remote_url_allocated) allocator.free(remote_url);

    const actual_url = if (std.mem.startsWith(u8, remote_url, "file://"))
        remote_url["file://".len..]
    else
        remote_url;

    // Check for network protocols - not supported
    if (std.mem.startsWith(u8, actual_url, "http://") or std.mem.startsWith(u8, actual_url, "https://") or
        std.mem.startsWith(u8, actual_url, "ssh://") or std.mem.startsWith(u8, actual_url, "git://"))
    {
        try platform_impl.writeStderr("fatal: remote transport not supported\n");
        std.process.exit(128);
    }

    // Resolve remote git dir
    const remote_git_dir = resolveSourceGitDir(allocator, actual_url) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' does not appear to be a git repository\nfatal: Could not read from remote repository.\n", .{actual_url});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    };
    defer allocator.free(remote_git_dir);

    // Check for invalid branch config (empty subsection like "branch..remote")
    {
        const cfg_path_chk = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(cfg_path_chk);
        if (readFileContent(allocator, cfg_path_chk)) |cfg_chk| {
            defer allocator.free(cfg_chk);
            var cfg_lines = std.mem.splitScalar(u8, cfg_chk, '\n');
            var line_nr: usize = 0;
            var in_empty_branch = false;
            while (cfg_lines.next()) |raw_line| {
                line_nr += 1;
                const tl = std.mem.trim(u8, raw_line, " \t\r");
                if (tl.len > 0 and tl[0] == '[') {
                    in_empty_branch = std.mem.startsWith(u8, tl, "[branch \"\"]");
                    continue;
                }
                if (in_empty_branch and tl.len > 0 and tl[0] != '#' and tl[0] != ';') {
                    // Found a variable in [branch ""] - report error
                    const eq = std.mem.indexOfScalar(u8, tl, '=') orelse continue;
                    const var_name = std.mem.trim(u8, tl[0..eq], " \t");
                    const emsg = try std.fmt.allocPrint(allocator, "fatal: bad config variable 'branch..{s}' in file '.git/config' at line {d}\n", .{ var_name, line_nr });
                    defer allocator.free(emsg);
                    try platform_impl.writeStderr(emsg);
                    std.process.exit(128);
                }
            }
        } else |_| {}
    }

    // Run pre-push hook: args are remote name and URL, refs on stdin
    // stdin format: <local ref> <local sha1> <remote ref> <remote sha1>\n
    {
        // Build stdin data from refspecs
        var stdin_buf = std.array_list.Managed(u8).init(allocator);
        defer stdin_buf.deinit();
        const zero_hash = "0000000000000000000000000000000000000000";

        // Resolve refspecs to build ref info for the hook
        var effective_refspecs = std.array_list.Managed([]const u8).init(allocator);
        defer effective_refspecs.deinit();

        if (refspecs_list.items.len > 0) {
            for (refspecs_list.items) |rs| try effective_refspecs.append(rs);
        } else if (!push_all and !push_tags and !push_mirror) {
            // Default push: current branch
            if (refs.getCurrentBranch(git_path, platform_impl, allocator)) |branch| {
                const rs = std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ branch, branch }) catch null;
                allocator.free(branch);
                if (rs) |r| try effective_refspecs.append(r);
            } else |_| {}
        }

        for (effective_refspecs.items) |rs_raw| {
            var rs = rs_raw;
            if (rs.len > 0 and rs[0] == '+') rs = rs[1..];
            if (rs.len > 0 and rs[0] == ':') continue; // delete ref

            var local_ref: []const u8 = rs;
            var remote_ref: []const u8 = rs;
            if (std.mem.indexOf(u8, rs, ":")) |colon| {
                local_ref = rs[0..colon];
                remote_ref = rs[colon + 1 ..];
            }

            // Resolve local ref to hash
            const local_hash = (refs.resolveRef(git_path, local_ref, platform_impl, allocator) catch null) orelse continue;
            defer allocator.free(local_hash);

            // Resolve remote ref to hash (may not exist)
            const remote_hash = (refs.resolveRef(remote_git_dir, remote_ref, platform_impl, allocator) catch null) orelse
                try allocator.dupe(u8, zero_hash);
            defer allocator.free(remote_hash);

            stdin_buf.appendSlice(local_ref) catch {};
            stdin_buf.append(' ') catch {};
            stdin_buf.appendSlice(local_hash) catch {};
            stdin_buf.append(' ') catch {};
            stdin_buf.appendSlice(remote_ref) catch {};
            stdin_buf.append(' ') catch {};
            stdin_buf.appendSlice(remote_hash) catch {};
            stdin_buf.append('\n') catch {};
        }

        const stdin_data: ?[]const u8 = if (stdin_buf.items.len > 0) stdin_buf.items else null;
        const hook_args = [_][]const u8{ remote, remote_url };
        const hook_result = hooks.runHook(allocator, git_path, "pre-push", &hook_args, stdin_data, platform_impl) catch hooks.HookResult{ .exit_code = 0, .skipped = true };
        if (!hook_result.skipped and hook_result.exit_code != 0) {
            try platform_impl.writeStderr("error: failed to push some refs (pre-push hook declined)\n");
            std.process.exit(1);
        }
    }

    // Copy objects first
    const src_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{git_path});
    defer allocator.free(src_objects);
    const dst_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{remote_git_dir});
    defer allocator.free(dst_objects);
    fetch_cmd.copyMissingObjects(src_objects, dst_objects);

    const src_packs = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_path});
    defer allocator.free(src_packs);
    const dst_packs = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{remote_git_dir});
    defer allocator.free(dst_packs);
    fetch_cmd.copyMissingPackFiles(src_packs, dst_packs);

    // Validate --delete usage
    if (push_delete) {
        if (refspecs_list.items.len == 0) {
            try platform_impl.writeStderr("fatal: --delete requires at least one argument\n");
            std.process.exit(1);
        }
        for (refspecs_list.items) |rs| {
            if (std.mem.indexOf(u8, rs, ":") != null) {
                try platform_impl.writeStderr("fatal: --delete doesn't accept src:dest refspecs\n");
                std.process.exit(1);
            }
            if (rs.len == 0) {
                try platform_impl.writeStderr("fatal: --delete requires at least one argument\n");
                std.process.exit(1);
            }
        }
    }

    // Determine what to push
    if (push_tags) {
        try pushWildcardRefspec(allocator, git_path, remote_git_dir, "refs/tags/*", "refs/tags/*", force_push, dry_run, quiet, platform_impl);
    }

    if (push_mirror) {
        // Mirror: push all refs
        try pushWildcardRefspec(allocator, git_path, remote_git_dir, "refs/*", "refs/*", true, dry_run, quiet, platform_impl);
    } else if (refspecs_list.items.len == 0 and !push_all and !push_tags) {
        // Default push: check remote.<name>.push config first
        var used_config_push = false;
        blk_cfg_push: {
            const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch break :blk_cfg_push;
            defer allocator.free(config_path);
            const config_content = readFileContent(allocator, config_path) catch break :blk_cfg_push;
            defer allocator.free(config_content);

            // Find the actual remote name used for this push
            const push_remote_name: []const u8 = remote;
            // Check if we resolved via config
            if (std.mem.startsWith(u8, remote, "/") or std.mem.startsWith(u8, remote, ".") or
                std.mem.startsWith(u8, remote, "file://"))
            {
                break :blk_cfg_push; // URL, not named remote
            }

            // Look for remote.<name>.push
            const push_key = std.fmt.allocPrint(allocator, "remote.{s}.push", .{push_remote_name}) catch break :blk_cfg_push;
            defer allocator.free(push_key);
            const push_val = getSimpleConfigValue(config_content, push_key, allocator) catch break :blk_cfg_push;
            defer allocator.free(push_val);

            if (push_val.len > 0) {
                // Resolve shorthand refspecs like "HEAD" or "@"
                var resolved_push_val: ?[]u8 = null;
                if (std.mem.indexOf(u8, push_val, ":") == null) {
                    // No colon - push src to same-named dst
                    const src_ref = push_val;
                    if (std.mem.eql(u8, push_val, "HEAD") or std.mem.eql(u8, push_val, "@")) {
                        if (refs.getCurrentBranch(git_path, platform_impl, allocator)) |branch| {
                            resolved_push_val = std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ branch, branch }) catch null;
                            allocator.free(branch);
                        } else |_| {}
                    } else if (!std.mem.startsWith(u8, src_ref, "refs/")) {
                        resolved_push_val = std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ src_ref, src_ref }) catch null;
                    } else {
                        resolved_push_val = std.fmt.allocPrint(allocator, "{s}:{s}", .{ src_ref, src_ref }) catch null;
                    }
                }
                defer if (resolved_push_val) |rpv| allocator.free(rpv);
                const final_push_val = resolved_push_val orelse push_val;

                pushSingleRefspec(allocator, git_path, remote_git_dir, final_push_val, force_push, dry_run, quiet, platform_impl) catch {
                    std.process.exit(1);
                };
                used_config_push = true;
            }
        }
        if (!used_config_push) {
            // Check push.default
            var push_default: []const u8 = "simple";
            var push_default_owned = false;
            {
                const cfg_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch "";
                defer if (cfg_path.len > 0) allocator.free(cfg_path);
                if (cfg_path.len > 0) {
                    if (readFileContent(allocator, cfg_path)) |cfg| {
                        defer allocator.free(cfg);
                        if (getSimpleConfigValue(cfg, "push.default", allocator)) |pd| {
                            push_default = pd;
                            push_default_owned = true;
                        } else |_| {}
                    } else |_| {}
                }
            }
            defer if (push_default_owned) allocator.free(push_default);

            if (std.mem.eql(u8, push_default, "matching")) {
                try pushMatching(allocator, git_path, remote_git_dir, force_push, dry_run, quiet, platform_impl);
            } else {
                // simple/current: push current branch
                const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch {
                    try platform_impl.writeStderr("fatal: not on a branch\n");
                    std.process.exit(128);
                };
                defer allocator.free(current_branch);

                const refspec = try std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ current_branch, current_branch });
                defer allocator.free(refspec);
                pushSingleRefspec(allocator, git_path, remote_git_dir, refspec, force_push, dry_run, quiet, platform_impl) catch {
                    std.process.exit(1);
                };
            }
        }
    } else if (push_all) {
        // Push all branches using wildcard
        try pushWildcardRefspec(allocator, git_path, remote_git_dir, "refs/heads/*", "refs/heads/*", force_push, dry_run, quiet, platform_impl);
    } else {
        for (refspecs_list.items) |refspec_raw| {
            var rs = refspec_raw;
            var force_this = force_push;

            if (rs.len > 0 and rs[0] == '+') {
                force_this = true;
                rs = rs[1..];
            }

            // Handle delete refspec :branch
            if (rs.len > 0 and rs[0] == ':') {
                if (rs.len == 1) {
                    // Bare ":" means push matching - push all branches that exist on both sides
                    try pushMatching(allocator, git_path, remote_git_dir, force_this, dry_run, quiet, platform_impl);
                    continue;
                }
                const remote_ref_name = rs[1..];
                const full_ref = if (std.mem.startsWith(u8, remote_ref_name, "refs/"))
                    try allocator.dupe(u8, remote_ref_name)
                else
                    try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{remote_ref_name});
                defer allocator.free(full_ref);

                if (!dry_run) {
                    const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_git_dir, full_ref });
                    defer allocator.free(ref_path);
                    std.fs.cwd().deleteFile(ref_path) catch {};
                }
                if (!quiet) {
                    const msg = try std.fmt.allocPrint(allocator, " - [deleted]         {s}\n", .{remote_ref_name});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                }
                continue;
            }

            // Handle --delete
            if (push_delete) {
                const full_ref = if (std.mem.startsWith(u8, rs, "refs/"))
                    try allocator.dupe(u8, rs)
                else blk_del: {
                    // DWIM: check tags, heads, etc. on remote
                    const del_candidates = [_][]const u8{ "refs/tags/", "refs/heads/" };
                    var del_found: ?[]u8 = null;
                    for (del_candidates) |prefix| {
                        const cp = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ remote_git_dir, prefix, rs });
                        defer allocator.free(cp);
                        if (std.fs.cwd().access(cp, .{})) |_| {
                            del_found = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, rs });
                            break;
                        } else |_| {}
                    }
                    break :blk_del del_found orelse try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{rs});
                };
                defer allocator.free(full_ref);
                if (!dry_run) {
                    const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_git_dir, full_ref });
                    defer allocator.free(ref_path);
                    std.fs.cwd().deleteFile(ref_path) catch {};
                }
                continue;
            }

            // Check for wildcard refspec
            if (std.mem.indexOf(u8, rs, ":")) |colon| {
                const src = rs[0..colon];
                const dst_part = rs[colon + 1 ..];
                if (std.mem.indexOfScalar(u8, src, '*') != null and std.mem.indexOfScalar(u8, dst_part, '*') != null) {
                    try pushWildcardRefspec(allocator, git_path, remote_git_dir, src, dst_part, force_this, dry_run, quiet, platform_impl);
                    continue;
                }
            }

            // Normal refspec
            if (std.mem.indexOf(u8, rs, ":")) |_| {
                pushSingleRefspec(allocator, git_path, remote_git_dir, rs, force_this, dry_run, quiet, platform_impl) catch {
                    
                    std.process.exit(1);
                };
            } else {
                // Just src - push to same-named ref
                var push_src = rs;
                var push_dst = rs;
                var resolved_branch: ?[]u8 = null;
                if (std.mem.eql(u8, rs, "HEAD") or std.mem.eql(u8, rs, "@")) {
                    if (refs.getCurrentBranch(git_path, platform_impl, allocator)) |branch| {
                        resolved_branch = branch;
                        push_src = branch;
                        push_dst = branch;
                    } else |_| {}
                }
                defer if (resolved_branch) |b| allocator.free(b);
                // Check for ambiguous refspec (both branch and tag exist)
                if (!std.mem.startsWith(u8, push_src, "refs/") and !std.mem.eql(u8, push_src, "HEAD") and !std.mem.eql(u8, push_src, "@")) {
                    const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{push_src});
                    defer allocator.free(branch_ref);
                    const tag_ref_chk = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{push_src});
                    defer allocator.free(tag_ref_chk);
                    const has_branch = if (refs.resolveRef(git_path, branch_ref, platform_impl, allocator) catch null) |h| blk2: {
                        allocator.free(h);
                        break :blk2 true;
                    } else false;
                    const has_tag = if (refs.resolveRef(git_path, tag_ref_chk, platform_impl, allocator) catch null) |h| blk2: {
                        allocator.free(h);
                        break :blk2 true;
                    } else false;
                    if (has_branch and has_tag) {
                        const amsg = try std.fmt.allocPrint(allocator, "error: src refspec {s} matches more than one\nerror: failed to push some refs to '{s}'\n", .{ push_src, actual_url });
                        defer allocator.free(amsg);
                        try platform_impl.writeStderr(amsg);
                        std.process.exit(1);
                    }
                }
                const full_refspec = if (std.mem.startsWith(u8, push_src, "refs/"))
                    try std.fmt.allocPrint(allocator, "{s}:{s}", .{ push_src, push_dst })
                else blk: {
                    // DWIM: check if it's a tag first, then branch
                    const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{push_src});
                    defer allocator.free(tag_ref);
                    if (refs.resolveRef(git_path, tag_ref, platform_impl, allocator) catch null) |h| {
                        allocator.free(h);
                        break :blk try std.fmt.allocPrint(allocator, "refs/tags/{s}:refs/tags/{s}", .{ push_src, push_dst });
                    }
                    break :blk try std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ push_src, push_dst });
                };
                defer allocator.free(full_refspec);
                pushSingleRefspec(allocator, git_path, remote_git_dir, full_refspec, force_this, dry_run, quiet, platform_impl) catch {
                    
                    std.process.exit(1);
                };
            }
        }
    }

    // Handle --prune: delete remote refs that don't exist locally
    if (push_prune and !dry_run) {
        var remote_all_refs = fetch_cmd.collectAllRefs(allocator, remote_git_dir) catch std.array_list.Managed(fetch_cmd.RefEntry).init(allocator);
        defer {
            for (remote_all_refs.items) |e| {
                allocator.free(e.name);
                allocator.free(e.hash);
            }
            remote_all_refs.deinit();
        }
        var local_all_refs = fetch_cmd.collectAllRefs(allocator, git_path) catch std.array_list.Managed(fetch_cmd.RefEntry).init(allocator);
        defer {
            for (local_all_refs.items) |e| {
                allocator.free(e.name);
                allocator.free(e.hash);
            }
            local_all_refs.deinit();
        }

        // Determine which refspecs to use for pruning
        // Check if we have a bare ":" refspec - treat it as matching push (refs/heads/*:refs/heads/*)
        var has_bare_colon = false;
        for (refspecs_list.items) |rs_raw| {
            var rs2 = rs_raw;
            if (rs2.len > 0 and rs2[0] == '+') rs2 = rs2[1..];
            if (rs2.len == 1 and rs2[0] == ':') { has_bare_colon = true; break; }
        }
        if (has_bare_colon or refspecs_list.items.len == 0) {
            // Default: prune refs/heads/* that don't exist locally
            for (remote_all_refs.items) |remote_entry| {
                if (!std.mem.startsWith(u8, remote_entry.name, "refs/heads/")) continue;
                var exists_locally2 = false;
                for (local_all_refs.items) |local_entry| {
                    if (std.mem.eql(u8, local_entry.name, remote_entry.name)) {
                        exists_locally2 = true;
                        break;
                    }
                }
                if (!exists_locally2) {
                    const ref_path2 = std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_git_dir, remote_entry.name }) catch continue;
                    defer allocator.free(ref_path2);
                    std.fs.cwd().deleteFile(ref_path2) catch {};
                }
            }
        } else if (refspecs_list.items.len > 0) {
            // Use explicit refspecs to determine what to prune
            for (refspecs_list.items) |rs_raw| {
                var rs = rs_raw;
                if (rs.len > 0 and rs[0] == '+') rs = rs[1..];
                const colon = std.mem.indexOf(u8, rs, ":") orelse continue;
                const src_pat = rs[0..colon];
                const dst_pat = rs[colon + 1 ..];
                if (std.mem.indexOfScalar(u8, src_pat, '*') == null or std.mem.indexOfScalar(u8, dst_pat, '*') == null) continue;

                // For each remote ref matching dst_pat, check if there's a local ref matching src_pat
                for (remote_all_refs.items) |remote_entry| {
                    const suffix = fetch_cmd.refspecMatchPub(remote_entry.name, dst_pat) orelse continue;
                    // Map back to src pattern
                    const expected_local = fetch_cmd.refspecMapPub(allocator, suffix, src_pat) catch continue;
                    defer allocator.free(expected_local);
                    var found = false;
                    for (local_all_refs.items) |local_entry| {
                        if (std.mem.eql(u8, local_entry.name, expected_local)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        const ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_git_dir, remote_entry.name }) catch continue;
                        defer allocator.free(ref_path);
                        std.fs.cwd().deleteFile(ref_path) catch {};
                    }
                }
            }
        }
    }

    // Handle --follow-tags
    if (follow_tags) {
        try pushFollowTags(allocator, git_path, remote_git_dir, dry_run, quiet, platform_impl);
    }

    // Handle --set-upstream
    if (set_upstream) {
        if (refs.getCurrentBranch(git_path, platform_impl, allocator)) |branch| {
            defer allocator.free(branch);
            // Set branch.<name>.remote and branch.<name>.merge
            const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(config_path);
            // Simple config write - read, modify, write
            setUpstreamConfig(allocator, config_path, branch, remote);
        } else |_| {}
    }

}

/// Apply url.<base>.pushInsteadOf rewriting to a URL
fn applyPushInsteadOf(allocator: std.mem.Allocator, url: []const u8, config_content: []const u8) ?[]u8 {
    var best_match: ?[]const u8 = null;
    var best_base: ?[]const u8 = null;
    var best_match_len: usize = 0;

    var in_url_section = false;
    var current_base: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, config_content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        if (line[0] == '[') {
            in_url_section = false;
            current_base = null;
            if (std.mem.startsWith(u8, line, "[url \"")) {
                const rest = line["[url \"".len..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |q| {
                    current_base = rest[0..q];
                    in_url_section = true;
                }
            }
            continue;
        }

        if (in_url_section and current_base != null) {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                const vkey = std.mem.trim(u8, line[0..eq], " \t");
                const vval = std.mem.trim(u8, line[eq + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(vkey, "pushInsteadOf")) {
                    if (std.mem.startsWith(u8, url, vval) and vval.len > best_match_len) {
                        best_match = vval;
                        best_base = current_base;
                        best_match_len = vval.len;
                    }
                }
            }
        }
    }

    if (best_match != null and best_base != null) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ best_base.?, url[best_match_len..] }) catch null;
    }
    return null;
}

fn formatRefDisplay(ref_name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, ref_name, "refs/heads/")) return ref_name["refs/heads/".len..];
    if (std.mem.startsWith(u8, ref_name, "refs/tags/")) return ref_name["refs/tags/".len..];
    if (std.mem.startsWith(u8, ref_name, "refs/remotes/")) return ref_name["refs/remotes/".len..];
    return ref_name;
}

fn pushSingleRefspec(
    allocator: std.mem.Allocator,
    local_git_dir: []const u8,
    remote_git_dir: []const u8,
    refspec: []const u8,
    force: bool,
    dry_run: bool,
    quiet: bool,
    platform_impl: *const platform_mod.Platform,
) !void {
    const colon_pos = std.mem.indexOf(u8, refspec, ":") orelse return;
    const src_ref_raw = refspec[0..colon_pos];
    // Translate @ to HEAD
    const src_ref = if (std.mem.eql(u8, src_ref_raw, "@")) "HEAD" else src_ref_raw;
    const dst_ref = refspec[colon_pos + 1 ..];

    // Resolve source ref to hash and determine its type
    var src_is_tag = false;
    var src_is_head = false;
    const hash = blk: {
        if (std.mem.startsWith(u8, src_ref, "refs/tags/")) {
            src_is_tag = true;
            if (refs.resolveRef(local_git_dir, src_ref, platform_impl, allocator) catch null) |h| break :blk h;
        } else if (std.mem.startsWith(u8, src_ref, "refs/heads/")) {
            src_is_head = true;
            if (refs.resolveRef(local_git_dir, src_ref, platform_impl, allocator) catch null) |h| break :blk h;
        } else if (std.mem.eql(u8, src_ref, "HEAD")) {
            src_is_head = true;
            if (refs.resolveRef(local_git_dir, src_ref, platform_impl, allocator) catch null) |h| break :blk h;
        } else if (!std.mem.startsWith(u8, src_ref, "refs/")) {
            // Short ref: try heads first, then tags
            const full_head = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{src_ref});
            defer allocator.free(full_head);
            if (refs.resolveRef(local_git_dir, full_head, platform_impl, allocator) catch null) |h| {
                src_is_head = true;
                break :blk h;
            }
            const full_tag = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{src_ref});
            defer allocator.free(full_tag);
            if (refs.resolveRef(local_git_dir, full_tag, platform_impl, allocator) catch null) |h| {
                src_is_tag = true;
                break :blk h;
            }
            // Try direct resolution as fallback
            if (refs.resolveRef(local_git_dir, src_ref, platform_impl, allocator) catch null) |h| break :blk h;
        } else {
            // Other refs/ prefix
            if (refs.resolveRef(local_git_dir, src_ref, platform_impl, allocator) catch null) |h| break :blk h;
        }
        // Try as raw hash
        if (src_ref.len == 40) {
            break :blk try allocator.dupe(u8, src_ref);
        }
        const msg = try std.fmt.allocPrint(allocator, "error: src refspec {s} does not match any\nerror: failed to push some refs\n", .{src_ref});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        return error.RefNotFound;
    };
    defer allocator.free(hash);

    const full_dst = if (std.mem.startsWith(u8, dst_ref, "refs/"))
        try allocator.dupe(u8, dst_ref)
    else blk: {
        // DWIM: check if the ref exists on remote under various prefixes
        const candidates = [_][]const u8{ "refs/heads/", "refs/tags/", "refs/remotes/" };
        var found: ?[]u8 = null;
        var match_count: usize = 0;
        for (candidates) |prefix| {
            const candidate_path = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ remote_git_dir, prefix, dst_ref });
            defer allocator.free(candidate_path);
            if (std.fs.cwd().access(candidate_path, .{})) |_| {
                match_count += 1;
                if (found == null) {
                    found = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, dst_ref });
                }
            } else |_| {}
        }
        if (match_count > 1) {
            // Ambiguous destination ref
            if (found) |f| allocator.free(f);
            const msg = try std.fmt.allocPrint(allocator, "error: dst refspec {s} matches more than one\nerror: failed to push some refs\n", .{dst_ref});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            return error.AmbiguousRef;
        }
        // When no match on remote, use source ref type to determine prefix
        if (!src_is_tag and !src_is_head) {
            // Can't determine type (e.g., raw OID) - reject
            if (found) |f| allocator.free(f);
            const emsg = try std.fmt.allocPrint(allocator, "error: unable to push to unqualified destination: {s}\nerror: failed to push some refs\n", .{dst_ref});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            return error.InvalidRef;
        }
        const default_prefix: []const u8 = if (src_is_tag) "refs/tags/" else "refs/heads/";
        break :blk found orelse try std.fmt.allocPrint(allocator, "{s}{s}", .{ default_prefix, dst_ref });
    };
    defer allocator.free(full_dst);

    // Reject one-level refs (must be at least refs/X/Y)
    if (std.mem.startsWith(u8, full_dst, "refs/")) {
        const rest = full_dst["refs/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/') == null) {
            const msg = try std.fmt.allocPrint(allocator, "error: unable to push to unqualified destination: {s}\nerror: failed to push some refs\n", .{dst_ref});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            return error.InvalidRef;
        }
    }

    // Check receive.denyCurrentBranch on the remote
    if (std.mem.startsWith(u8, full_dst, "refs/heads/")) {
        const remote_head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{remote_git_dir});
        defer allocator.free(remote_head_path);
        if (readFileContent(allocator, remote_head_path)) |head_content| {
            defer allocator.free(head_content);
            const trimmed_head = std.mem.trim(u8, head_content, " \t\r\n");
            if (std.mem.startsWith(u8, trimmed_head, "ref: ")) {
                const remote_current = trimmed_head["ref: ".len..];
                if (std.mem.eql(u8, remote_current, full_dst)) {
                    // Check if remote is non-bare
                    const remote_config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{remote_git_dir});
                    defer allocator.free(remote_config_path);
                    var is_bare_remote = false;
                    var deny_policy: []const u8 = "refuse";
                    var deny_policy_owned = false;
                    if (readFileContent(allocator, remote_config_path)) |rcfg| {
                        defer allocator.free(rcfg);
                        if (std.mem.indexOf(u8, rcfg, "bare = true")) |_| is_bare_remote = true;
                        if (getSimpleConfigValue(rcfg, "receive.denyCurrentBranch", allocator)) |dcb| {
                            deny_policy = dcb;
                            deny_policy_owned = true;
                        } else |_| {}
                    } else |_| {}
                    defer if (deny_policy_owned) allocator.free(deny_policy);

                    if (!is_bare_remote) {
                        if (std.ascii.eqlIgnoreCase(deny_policy, "refuse") or std.ascii.eqlIgnoreCase(deny_policy, "true")) {
                            const branch_short = if (std.mem.startsWith(u8, full_dst, "refs/heads/")) full_dst["refs/heads/".len..] else full_dst;
                            const emsg = try std.fmt.allocPrint(allocator, " ! [remote rejected] {s} -> {s} (branch is currently checked out)\nremote: error: refusing to update checked out branch: {s}\nremote: error: By default, updating the current branch in a non-bare repository\nremote: is denied, because it will make the index and work tree inconsistent\nerror: failed to push some refs\n", .{ branch_short, branch_short, full_dst });
                            defer allocator.free(emsg);
                            try platform_impl.writeStderr(emsg);
                            return error.DenyCurrentBranch;
                        } else if (std.ascii.eqlIgnoreCase(deny_policy, "warn")) {
                            const wmsg = try std.fmt.allocPrint(allocator, "warning: updating the current branch\n", .{});
                            defer allocator.free(wmsg);
                            try platform_impl.writeStderr(wmsg);
                        }
                        // "ignore" or other values: proceed silently
                    }
                }
            }
        } else |_| {}
    }

    // Validate that we're not pushing non-commit objects to branch refs
    if (std.mem.startsWith(u8, full_dst, "refs/heads/")) {
        if (objects.GitObject.load(hash, local_git_dir, platform_impl, allocator)) |obj| {
            defer obj.deinit(allocator);
            if (obj.type != .commit) {
                const emsg = try std.fmt.allocPrint(allocator, "error: trying to write non-commit object {s} to branch '{s}'\n ! [remote rejected] {s} -> {s} (invalid new value provided)\nerror: failed to push some refs\n", .{ hash, full_dst, formatRefDisplay(full_dst), formatRefDisplay(full_dst) });
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                return error.NonCommitObject;
            }
        } else |_| {}
    }

    if (!dry_run) {
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_git_dir, full_dst });
        defer allocator.free(ref_path);
        if (std.mem.lastIndexOfScalar(u8, ref_path, '/')) |ls| std.fs.cwd().makePath(ref_path[0..ls]) catch {};

        // Check if this will be an actual update (for succinct output)
        var is_update_for_succinct = true;
        if (readFileContent(allocator, ref_path)) |existing_content| {
            defer allocator.free(existing_content);
            const existing_hash = std.mem.trim(u8, existing_content, " \t\r\n");
            if (existing_hash.len >= 40 and std.mem.eql(u8, existing_hash[0..40], hash)) {
                is_update_for_succinct = false; // up-to-date
            }
        } else |_| {}

        // Check fast-forward / tag update rejection
        if (!force) {
            if (readFileContent(allocator, ref_path)) |old| {
                defer allocator.free(old);
                const old_h = std.mem.trim(u8, old, " \t\r\n");
                if (old_h.len >= 40 and !std.mem.eql(u8, old_h[0..40], hash)) {
                    // Tags cannot be updated without --force
                    if (std.mem.startsWith(u8, full_dst, "refs/tags/")) {
                        const tag_name = full_dst["refs/tags/".len..];
                        const emsg = try std.fmt.allocPrint(allocator, " ! [rejected]        {s} -> {s} (already exists)\nerror: failed to push some refs\n", .{ tag_name, tag_name });
                        defer allocator.free(emsg);
                        try platform_impl.writeStderr(emsg);
                        return error.NonFastForward;
                    }
                    if (!fetch_cmd.isAncestor(local_git_dir, old_h[0..40], hash, allocator, platform_impl)) {
                        const emsg = try std.fmt.allocPrint(allocator, " ! [rejected]        {s} -> {s} (non-fast-forward)\nerror: failed to push some refs\n", .{ formatRefDisplay(full_dst), formatRefDisplay(full_dst) });
                        defer allocator.free(emsg);
                        try platform_impl.writeStderr(emsg);
                        return error.NonFastForward;
                    }
                }
            } else |_| {}
        }

        // Check if remote ref is already up-to-date
        var was_up_to_date = false;
        if (readFileContent(allocator, ref_path)) |existing| {
            defer allocator.free(existing);
            const existing_hash = std.mem.trim(u8, existing, " \t\r\n");
            if (std.mem.eql(u8, existing_hash, hash)) {
                was_up_to_date = true;
            }
        } else |_| {}

        const data = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
        defer allocator.free(data);
        
        // Check if ref is already up-to-date
        var is_up_to_date = false;
        if (readFileContent(allocator, ref_path)) |existing_data| {
            defer allocator.free(existing_data);
            const existing_hash = std.mem.trim(u8, existing_data, " \t\r\n");
            if (existing_hash.len >= 40 and std.mem.eql(u8, existing_hash[0..40], hash)) {
                is_up_to_date = true;
            }
        } else |_| {}
        
        std.fs.cwd().writeFile(.{ .sub_path = ref_path, .data = data }) catch {};
        
        // Output success message (succinct mode)
        if (!is_up_to_date and succinct_mod.isEnabled()) {
            const branch_name = if (std.mem.startsWith(u8, full_dst, "refs/heads/"))
                full_dst["refs/heads/".len..]
            else if (std.mem.startsWith(u8, full_dst, "refs/tags/"))
                full_dst["refs/tags/".len..]
            else
                full_dst;
            const short_hash = if (hash.len >= 7) hash[0..7] else hash;
            const success_msg = std.fmt.allocPrint(allocator, "ok push {s} {s}\n", .{ branch_name, short_hash }) catch "";
            if (success_msg.len > 0) {
                defer allocator.free(success_msg);
                platform_impl.writeStdout(success_msg) catch {};
            }
        }
        
        // Output success message in succinct mode (silent on up-to-date)
        if (succinct_mod.isEnabled() and !was_up_to_date) {
            const branch_name = if (std.mem.startsWith(u8, full_dst, "refs/heads/"))
                full_dst["refs/heads/".len..]
            else if (std.mem.startsWith(u8, full_dst, "refs/tags/"))
                full_dst["refs/tags/".len..]
            else
                full_dst;
            const short_hash = if (hash.len >= 7) hash[0..7] else hash;
            const success_msg = std.fmt.allocPrint(allocator, "ok push {s} {s}\n", .{ branch_name, short_hash }) catch "";
            if (success_msg.len > 0) {
                defer allocator.free(success_msg);
                platform_impl.writeStdout(success_msg) catch {};
            }
        }
        
        // Succinct mode: output success message
        if (succinct_mod.isEnabled()) {
            const branch_name = if (std.mem.startsWith(u8, full_dst, "refs/heads/"))
                full_dst["refs/heads/".len..]
            else if (std.mem.startsWith(u8, full_dst, "refs/tags/"))
                full_dst["refs/tags/".len..]
            else
                full_dst;
            const short_hash = if (hash.len >= 7) hash[0..7] else hash;
            const success_msg = try std.fmt.allocPrint(allocator, "ok push {s} {s}\n", .{ branch_name, short_hash });
            defer allocator.free(success_msg);
            try platform_impl.writeStdout(success_msg);
        }

        // Update local tracking ref (only if value changed)
        if (std.mem.startsWith(u8, full_dst, "refs/heads/")) {
            const pushed_branch = full_dst["refs/heads/".len..];
            const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{local_git_dir}) catch unreachable;
            defer allocator.free(config_path);
            if (readFileContent(allocator, config_path)) |config_content| {
                defer allocator.free(config_content);
                // Find remote name by matching URL
                if (findRemoteNameByGitDir(allocator, config_content, remote_git_dir)) |rn| {
                    defer allocator.free(rn);
                    const tracking_ref_name = std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ rn, pushed_branch }) catch unreachable;
                    defer allocator.free(tracking_ref_name);
                    // Check current value (loose or packed)
                    const current_val = refs.resolveRef(local_git_dir, tracking_ref_name, platform_impl, allocator) catch null;
                    defer if (current_val) |cv| allocator.free(cv);
                    const needs_update = if (current_val) |cv| !std.mem.eql(u8, cv, hash) else true;
                    if (needs_update) {
                        const tracking_ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ local_git_dir, tracking_ref_name }) catch unreachable;
                        defer allocator.free(tracking_ref_path);
                        if (std.mem.lastIndexOfScalar(u8, tracking_ref_path, '/')) |ls2| std.fs.cwd().makePath(tracking_ref_path[0..ls2]) catch {};
                        std.fs.cwd().writeFile(.{ .sub_path = tracking_ref_path, .data = data }) catch {};
                    }
                }
            } else |_| {}
        }
    }


    _ = quiet;
}

/// Find a remote name whose URL resolves to the same git dir as the target
fn findRemoteNameByGitDir(allocator: std.mem.Allocator, config_content: []const u8, target_git_dir: []const u8) ?[]u8 {
    // Scan for [remote "X"] sections and extract URL
    var lines = std.mem.splitScalar(u8, config_content, '\n');
    var current_remote: ?[]const u8 = null;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        if (line[0] == '[') {
            current_remote = null;
            if (std.mem.startsWith(u8, line, "[remote \"")) {
                const rest = line["[remote \"".len..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |q| {
                    current_remote = rest[0..q];
                }
            }
            continue;
        }
        if (current_remote) |rn| {
            if (std.mem.startsWith(u8, line, "url = ") or std.mem.startsWith(u8, line, "url=")) {
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                const url = std.mem.trim(u8, line[eq + 1 ..], " \t");
                // Try to resolve this URL to a git dir and compare
                const resolved = resolveSourceGitDir(allocator, url) catch continue;
                defer allocator.free(resolved);
                const resolved_target = resolveSourceGitDir(allocator, target_git_dir) catch {
                    if (std.mem.eql(u8, resolved, target_git_dir)) {
                        return allocator.dupe(u8, rn) catch null;
                    }
                    continue;
                };
                defer allocator.free(resolved_target);
                if (std.mem.eql(u8, resolved, resolved_target)) {
                    return allocator.dupe(u8, rn) catch null;
                }
            }
        }
    }
    return null;
}

fn pushMatching(
    allocator: std.mem.Allocator,
    local_git_dir: []const u8,
    remote_git_dir: []const u8,
    force: bool,
    dry_run: bool,
    quiet: bool,
    platform_impl: *const platform_mod.Platform,
) !void {
    // Push all branches that exist on both local and remote
    const heads_dir = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{local_git_dir});
    defer allocator.free(heads_dir);
    var dir = std.fs.cwd().openDir(heads_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const remote_ref_check = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ remote_git_dir, entry.name });
        defer allocator.free(remote_ref_check);
        if (std.fs.cwd().access(remote_ref_check, .{})) |_| {
            const refspec = try std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ entry.name, entry.name });
            defer allocator.free(refspec);
            pushSingleRefspec(allocator, local_git_dir, remote_git_dir, refspec, force, dry_run, quiet, platform_impl) catch {
                
            };
        } else |_| {}
    }
}

fn pushFollowTags(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    remote_git_dir: []const u8,
    dry_run: bool,
    quiet: bool,
    platform_impl: *const platform_mod.Platform,
) !void {
    const tags_dir = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_path});
    defer allocator.free(tags_dir);

    var dir = std.fs.cwd().openDir(tags_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tags_dir, entry.name });
        defer allocator.free(ref_path);
        const hash_raw = readFileContent(allocator, ref_path) catch continue;
        defer allocator.free(hash_raw);
        const hash = std.mem.trim(u8, hash_raw, " \t\r\n");

        // Check if tag already exists on remote
        const remote_tag = try std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{ remote_git_dir, entry.name });
        defer allocator.free(remote_tag);
        if (std.fs.cwd().access(remote_tag, .{})) |_| continue else |_| {}

        // Check if it's an annotated tag
        const obj = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);
        if (obj.type != .tag) continue;

        if (!dry_run) {
            if (std.mem.lastIndexOfScalar(u8, remote_tag, '/')) |ls| std.fs.cwd().makePath(remote_tag[0..ls]) catch {};
            const data = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
            defer allocator.free(data);
            std.fs.cwd().writeFile(.{ .sub_path = remote_tag, .data = data }) catch {};
        }
    }
    _ = quiet;
}

fn setUpstreamConfig(allocator: std.mem.Allocator, config_path: []const u8, branch: []const u8, remote: []const u8) void {
    const content = readFileContent(allocator, config_path) catch return;
    defer allocator.free(content);

    const section = std.fmt.allocPrint(allocator, "[branch \"{s}\"]", .{branch}) catch return;
    defer allocator.free(section);

    var new_content = std.array_list.Managed(u8).init(allocator);
    defer new_content.deinit();

    var found_section = false;
    var wrote_remote = false;
    var wrote_merge = false;
    var in_branch_section = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len > 0 and trimmed[0] == '[') {
            if (in_branch_section and !wrote_remote) {
                const r_line = std.fmt.allocPrint(allocator, "\tremote = {s}\n", .{remote}) catch continue;
                defer allocator.free(r_line);
                new_content.appendSlice(r_line) catch {};
                wrote_remote = true;
            }
            if (in_branch_section and !wrote_merge) {
                const m_line = std.fmt.allocPrint(allocator, "\tmerge = refs/heads/{s}\n", .{branch}) catch continue;
                defer allocator.free(m_line);
                new_content.appendSlice(m_line) catch {};
                wrote_merge = true;
            }
            in_branch_section = false;

            if (std.mem.indexOf(u8, line, section)) |_| {
                found_section = true;
                in_branch_section = true;
            }
        }

        if (in_branch_section) {
            if (std.mem.startsWith(u8, trimmed, "remote =") or std.mem.startsWith(u8, trimmed, "remote=")) {
                const r_line = std.fmt.allocPrint(allocator, "\tremote = {s}\n", .{remote}) catch continue;
                defer allocator.free(r_line);
                new_content.appendSlice(r_line) catch {};
                wrote_remote = true;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "merge =") or std.mem.startsWith(u8, trimmed, "merge=")) {
                const m_line = std.fmt.allocPrint(allocator, "\tmerge = refs/heads/{s}\n", .{branch}) catch continue;
                defer allocator.free(m_line);
                new_content.appendSlice(m_line) catch {};
                wrote_merge = true;
                continue;
            }
        }

        new_content.appendSlice(line) catch {};
        new_content.append('\n') catch {};
    }

    if (!found_section) {
        const new_section = std.fmt.allocPrint(allocator, "{s}\n\tremote = {s}\n\tmerge = refs/heads/{s}\n", .{ section, remote, branch }) catch return;
        defer allocator.free(new_section);
        new_content.appendSlice(new_section) catch {};
    }

    std.fs.cwd().writeFile(.{ .sub_path = config_path, .data = new_content.items }) catch {};
}
