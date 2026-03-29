// Auto-generated from main_common.zig - cmd_push_impl
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_merge_base = @import("cmd_merge_base.zig");
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

pub fn cmdPush(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("push: not supported in freestanding mode\n");
        return;
    }

    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // helpers.Parse arguments
    var remote_name: ?[]const u8 = null;
    var refspecs = std.ArrayList([]const u8).init(allocator);
    defer refspecs.deinit();
    var force_push = false;
    var push_all = false;
    var push_tags = false;
    var push_delete = false;
    var push_mirror = false;
    var set_upstream = false;
    var dry_run = false;
    var verbose = false;
    var quiet = false;
    var follow_tags = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
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
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--follow-tags")) {
            follow_tags = true;
        } else if (std.mem.eql(u8, arg, "--follow-tags")) {
            follow_tags = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git push [<options>] [<repository> [<refspec>...]]\n");
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // helpers.Skip unknown options
        } else {
            if (remote_name == null) {
                remote_name = arg;
            } else {
                try refspecs.append(arg);
            }
        }
    }

    const remote = remote_name orelse "origin";

    if (remote.len == 0) {
        try platform_impl.writeStderr("fatal: bad repository ''\n");
        std.process.exit(128);
    }

    // helpers.Check for conflicting options
    if (push_all and refspecs.items.len > 0) {
        try platform_impl.writeStderr("error: --all/--branches can't be combined with refspecs\n");
        std.process.exit(1);
    }
    if (push_all and push_tags) {
        try platform_impl.writeStderr("error: --all/--branches and --tags cannot be used together\n");
        std.process.exit(1);
    }
    if (push_all and push_delete) {
        try platform_impl.writeStderr("error: --all/--branches and --delete cannot be used together\n");
        std.process.exit(1);
    }
    if (push_mirror and (push_all or push_tags or push_delete)) {
        try platform_impl.writeStderr("error: --mirror and --all/--branches/--tags/--delete cannot be used together\n");
        std.process.exit(1);
    }
    if (push_mirror) push_all = true;

    // helpers.Resolve remote helpers.URL
    var remote_url: []const u8 = undefined;
    var remote_url_allocated = false;

    // helpers.Check if remote is actually a path/helpers.URL
    if (std.mem.startsWith(u8, remote, "/") or std.mem.startsWith(u8, remote, "./") or std.mem.startsWith(u8, remote, "../") or std.mem.eql(u8, remote, ".") or std.mem.eql(u8, remote, "..") or std.mem.startsWith(u8, remote, "file://")) {
        remote_url = remote;
    } else {
        // helpers.Look up remote helpers.URL from config first
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);
        const config_content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' does not appear to be a git repository\n", .{remote});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        defer allocator.free(config_content);

        const remote_section = try std.fmt.allocPrint(allocator, "[remote \"{s}\"]", .{remote});
        defer allocator.free(remote_section);

        if (std.mem.indexOf(u8, config_content, remote_section)) |section_start| {
            const after_section = config_content[section_start + remote_section.len..];
            var lines = std.mem.splitScalar(u8, after_section, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len > 0 and trimmed[0] == '[') break;
                if (std.mem.startsWith(u8, trimmed, "url = ")) {
                    remote_url = try allocator.dupe(u8, trimmed["url = ".len..]);
                    remote_url_allocated = true;
                    break;
                }
            }
        }

        if (!remote_url_allocated) {
            // Fall back to trying as a local git repo path
            if (helpers.resolveSourceGitDir(allocator, remote)) |rgd| {
                allocator.free(rgd);
                remote_url = remote;
            } else |_| {
                const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' does not appear to be a git repository\nfatal: helpers.Could not read from remote repository.\n", .{remote});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }
        }
    }
    defer if (remote_url_allocated) allocator.free(remote_url);

    // helpers.Resolve file:// URLs
    const actual_url = if (std.mem.startsWith(u8, remote_url, "file://"))
        remote_url["file://".len..]
    else
        remote_url;

    // helpers.Check if this is an SSH or HTTP helpers.URL - not supported
    if (std.mem.startsWith(u8, actual_url, "http://") or std.mem.startsWith(u8, actual_url, "https://") or
        std.mem.startsWith(u8, actual_url, "ssh://") or std.mem.startsWith(u8, actual_url, "git://") or
        std.mem.indexOf(u8, actual_url, ":") != null)
    {
        // helpers.Check if it looks like a path with colon (e.g., C:\path on windows) or SSH
        if (!std.mem.startsWith(u8, actual_url, "/") and !std.mem.startsWith(u8, actual_url, ".")) {
            try platform_impl.writeStderr("fatal: remote transport not supported\n");
            std.process.exit(128);
        }
    }

    // helpers.Resolve the remote git directory
    const remote_git_dir = helpers.resolveSourceGitDir(allocator, actual_url) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' does not appear to be a git repository\nfatal: helpers.Could not read from remote repository.\n", .{actual_url});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    };
    defer allocator.free(remote_git_dir);

    // helpers.If no refspecs given, figure out what to push
    var had_push_error = false;
    if (refspecs.items.len == 0 and !push_all and !push_tags) {
        // Default: push current branch with matching remote
        const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch {
            try platform_impl.writeStderr("fatal: not on a branch\n");
            std.process.exit(128);
        };
        defer allocator.free(current_branch);

        // Push current branch to same-named remote branch
        const refspec = try std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ current_branch, current_branch });
        defer allocator.free(refspec);
        try pushRefspec(allocator, git_path, remote_git_dir, refspec, force_push, dry_run, quiet, platform_impl);
    } else if (push_all) {
        // Push all branches
        const heads_dir = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{git_path});
        defer allocator.free(heads_dir);
        var dir = std.fs.cwd().openDir(heads_dir, .{ .iterate = true }) catch return;
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            const rs = try std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ entry.name, entry.name });
            defer allocator.free(rs);
            try pushRefspec(allocator, git_path, remote_git_dir, rs, force_push, dry_run, quiet, platform_impl);
        }
    } else {
        for (refspecs.items) |refspec_raw| {
            var rs = refspec_raw;
            var force_this = force_push;

            // helpers.Handle +refspec (force) prefix
            if (rs.len > 0 and rs[0] == '+') {
                force_this = true;
                rs = rs[1..];
            }

            // helpers.Handle delete refspec  :branch
            if (rs.len > 0 and rs[0] == ':') {
                // helpers.Empty `:` means push matching (all branches that exist on both sides)
                if (rs.len == 1) {
                    const heads_dir2 = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{git_path});
                    defer allocator.free(heads_dir2);
                    var dir2 = std.fs.cwd().openDir(heads_dir2, .{ .iterate = true }) catch continue;
                    defer dir2.close();
                    var iter2 = dir2.iterate();
                    while (iter2.next() catch null) |entry2| {
                        if (entry2.kind != .file) continue;
                        const remote_ref_check = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ remote_git_dir, entry2.name });
                        defer allocator.free(remote_ref_check);
                        if (std.fs.cwd().access(remote_ref_check, .{})) {
                            const rspec = try std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ entry2.name, entry2.name });
                            defer allocator.free(rspec);
                            pushRefspec(allocator, git_path, remote_git_dir, rspec, force_this, dry_run, quiet, platform_impl) catch { had_push_error = true; };
                        } else |_| {}
                    }
                    continue;
                }
                // helpers.Delete remote ref
                const remote_ref_name = rs[1..];
                const full_ref = if (std.mem.startsWith(u8, remote_ref_name, "refs/"))
                    try allocator.dupe(u8, remote_ref_name)
                else
                    try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{remote_ref_name});
                defer allocator.free(full_ref);

                if (!dry_run) {
                    const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_git_dir, full_ref });
                    defer allocator.free(ref_path);
                    std.fs.cwd().deleteFile(ref_path) catch {
                        const msg = try std.fmt.allocPrint(allocator, "error: unable to delete '{s}': remote ref does not exist\n", .{full_ref});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                    };
                    if (std.mem.startsWith(u8, full_ref, "refs/heads/")) {
                        const del_branch = full_ref["refs/heads/".len..];
                        const del_track = std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}/{s}", .{ git_path, remote, del_branch }) catch null;
                        defer if (del_track) |dtr| allocator.free(dtr);
                        if (del_track) |dtr| std.fs.cwd().deleteFile(dtr) catch {};
                    }
                }
                if (!quiet) {
                    const msg = try std.fmt.allocPrint(allocator, " - [deleted]         {s}\n", .{remote_ref_name});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                }
                continue;
            }

            // helpers.Handle push --delete
            if (push_delete) {
                const full_ref = if (std.mem.startsWith(u8, rs, "refs/"))
                    try allocator.dupe(u8, rs)
                else
                    try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{rs});
                defer allocator.free(full_ref);

                if (!dry_run) {
                    const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_git_dir, full_ref });
                    defer allocator.free(ref_path);
                    std.fs.cwd().deleteFile(ref_path) catch {};
                }
                continue;
            }

            // helpers.Normal refspec: src:dst or just src
            if (std.mem.indexOf(u8, rs, ":")) |_| {
                const full_refspec = try std.fmt.allocPrint(allocator, "{s}", .{rs});
                defer allocator.free(full_refspec);
                try pushRefspec(allocator, git_path, remote_git_dir, full_refspec, force_this, dry_run, quiet, platform_impl);
            } else {
                // helpers.Just src - push to same-named ref on remote
                var push_src = rs;
                var push_dst = rs;
                var resolved_branch: ?[]u8 = null;
                // helpers.If src is helpers.HEAD, resolve to current branch
                if (std.mem.eql(u8, rs, "HEAD")) {
                    if (refs.getCurrentBranch(git_path, platform_impl, allocator)) |branch| {
                        resolved_branch = branch;
                        push_src = branch;
                        push_dst = branch;
                    } else |_| {}
                }
                defer if (resolved_branch) |b| allocator.free(b);
                // Check for ambiguous refspec (both branch and tag exist)
                if (!std.mem.startsWith(u8, push_src, "refs/") and !std.mem.eql(u8, push_src, "HEAD")) {
                    const ambig_branch = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, push_src });
                    defer allocator.free(ambig_branch);
                    const ambig_tag = try std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{ git_path, push_src });
                    defer allocator.free(ambig_tag);
                    const ab = if (std.fs.cwd().access(ambig_branch, .{})) true else |_| false;
                    const at = if (std.fs.cwd().access(ambig_tag, .{})) true else |_| false;
                    if (ab and at) {
                        const amsg = try std.fmt.allocPrint(allocator, "error: src refspec {s} matches more than one\nerror: failed to push some refs to '{s}'\n", .{ push_src, actual_url });
                        defer allocator.free(amsg);
                        try platform_impl.writeStderr(amsg);
                        std.process.exit(1);
                    }
                }
                const full_refspec = if (std.mem.startsWith(u8, push_src, "refs/"))
                    try std.fmt.allocPrint(allocator, "{s}:{s}", .{ push_src, push_dst })
                else
                    try std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ push_src, push_dst });
                defer allocator.free(full_refspec);
                try pushRefspec(allocator, git_path, remote_git_dir, full_refspec, force_this, dry_run, quiet, platform_impl);
            }
        }
    }

    // helpers.Handle --follow-tags: push annotated tags
    if (follow_tags) {
        const ftags_dir = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_path});
        defer allocator.free(ftags_dir);
        if (std.fs.cwd().openDir(ftags_dir, .{ .iterate = true })) |ftd_val| {
            var ftd = ftd_val;
            defer ftd.close();
            var ftiter = ftd.iterate();
            while (ftiter.next() catch null) |ftentry| {
                if (ftentry.kind != .file) continue;
                const ft_ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ ftags_dir, ftentry.name }) catch continue;
                defer allocator.free(ft_ref_path);
                const ft_hash_raw = std.fs.cwd().readFileAlloc(allocator, ft_ref_path, 256) catch continue;
                defer allocator.free(ft_hash_raw);
                const ft_hash = std.mem.trim(u8, ft_hash_raw, " \t\r\n");
                const ft_remote_path = std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{ remote_git_dir, ftentry.name }) catch continue;
                defer allocator.free(ft_remote_path);
                if (std.fs.cwd().access(ft_remote_path, .{})) {
                    continue;
                } else |_| {}
                const ft_obj = objects.GitObject.load(ft_hash, git_path, platform_impl, allocator) catch continue;
                defer ft_obj.deinit(allocator);
                if (ft_obj.type != .tag) continue;
                const ft_refspec = std.fmt.allocPrint(allocator, "refs/tags/{s}:refs/tags/{s}", .{ ftentry.name, ftentry.name }) catch continue;
                defer allocator.free(ft_refspec);
                pushRefspec(allocator, git_path, remote_git_dir, ft_refspec, false, dry_run, quiet, platform_impl) catch {};
            }
        } else |_| {}
    }

    // helpers.Handle --follow-tags: push annotated tags
    if (follow_tags) {
        const ftags_dir = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_path});
        defer allocator.free(ftags_dir);
        if (std.fs.cwd().openDir(ftags_dir, .{ .iterate = true })) |ftd_val| {
            var ftd = ftd_val;
            defer ftd.close();
            var ftiter = ftd.iterate();
            while (ftiter.next() catch null) |ftentry| {
                if (ftentry.kind != .file) continue;
                const ft_ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ ftags_dir, ftentry.name }) catch continue;
                defer allocator.free(ft_ref_path);
                const ft_hash_raw = std.fs.cwd().readFileAlloc(allocator, ft_ref_path, 256) catch continue;
                defer allocator.free(ft_hash_raw);
                const ft_hash = std.mem.trim(u8, ft_hash_raw, " \t\r\n");
                const ft_remote_path = std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{ remote_git_dir, ftentry.name }) catch continue;
                defer allocator.free(ft_remote_path);
                if (std.fs.cwd().access(ft_remote_path, .{})) {
                    continue;
                } else |_| {}
                const ft_obj = objects.GitObject.load(ft_hash, git_path, platform_impl, allocator) catch continue;
                defer ft_obj.deinit(allocator);
                if (ft_obj.type != .tag) continue;
                const ft_refspec = std.fmt.allocPrint(allocator, "refs/tags/{s}:refs/tags/{s}", .{ ftentry.name, ftentry.name }) catch continue;
                defer allocator.free(ft_refspec);
                pushRefspec(allocator, git_path, remote_git_dir, ft_refspec, false, dry_run, quiet, platform_impl) catch {};
            }
        } else |_| {}
    }

    // helpers.Update remote tracking helpers.refs - sync refs/remotes/<remote>/* with what remote has
    if (!dry_run and remote_url_allocated) {
        const remote_heads_dir = std.fmt.allocPrint(allocator, "{s}/refs/heads", .{remote_git_dir}) catch null;
        defer if (remote_heads_dir) |d| allocator.free(d);
        if (remote_heads_dir) |rhd| {
            if (std.fs.cwd().openDir(rhd, .{ .iterate = true })) |rd_val| {
                var rd = rd_val;
                defer rd.close();
                var riter = rd.iterate();
                while (riter.next() catch null) |rentry| {
                    if (rentry.kind != .file) continue;
                    const rref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ rhd, rentry.name }) catch continue;
                    defer allocator.free(rref_path);
                    if (std.fs.cwd().readFileAlloc(allocator, rref_path, 256)) |rval| {
                        defer allocator.free(rval);
                        const rh = std.mem.trim(u8, rval, " \t\r\n");
                        const tracking_path = std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}/{s}", .{ git_path, remote, rentry.name }) catch continue;
                        defer allocator.free(tracking_path);
                        if (std.fs.path.dirname(tracking_path)) |dir| std.fs.cwd().makePath(dir) catch {};
                        const tf = std.fs.cwd().createFile(tracking_path, .{}) catch continue;
                        defer tf.close();
                        const thl = std.fmt.allocPrint(allocator, "{s}\n", .{rh}) catch continue;
                        defer allocator.free(thl);
                        tf.writeAll(thl) catch {};
                    } else |_| {}
                }
            } else |_| {}
        }
    }

    if (set_upstream) {
        // TODO: update branch.<name>.remote and branch.<name>.merge
    }
    
    if (had_push_error) {
        std.process.exit(1);
    }
}


pub fn pushRefspec(allocator: std.mem.Allocator, local_git_dir: []const u8, remote_git_dir: []const u8, refspec: []const u8, force: bool, dry_run: bool, quiet: bool, platform_impl: *const platform_mod.Platform) !void {
    const colon_pos = std.mem.indexOf(u8, refspec, ":") orelse return;
    const src_ref = refspec[0..colon_pos];
    const dst_ref = refspec[colon_pos + 1..];

    // helpers.Resolve source ref to hash
    const full_src = if (std.mem.startsWith(u8, src_ref, "refs/"))
        try allocator.dupe(u8, src_ref)
    else
        try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{src_ref});
    defer allocator.free(full_src);

    const src_hash = helpers.resolveRevision(local_git_dir, full_src, platform_impl, allocator) catch
        helpers.resolveRevision(local_git_dir, src_ref, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "error: src refspec {s} does not match any\n", .{src_ref});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };
    defer allocator.free(src_hash);

    try pushRefspecInner(allocator, local_git_dir, remote_git_dir, src_hash, dst_ref, force, dry_run, quiet, platform_impl);
}


pub fn pushRefspecInner(allocator: std.mem.Allocator, local_git_dir: []const u8, remote_git_dir: []const u8, src_hash: []const u8, dst_ref: []const u8, force: bool, dry_run: bool, quiet: bool, platform_impl: *const platform_mod.Platform) !void {
    // helpers.Check the current value of the remote ref
    const full_dst = if (std.mem.startsWith(u8, dst_ref, "refs/"))
        try allocator.dupe(u8, dst_ref)
    else
        try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{dst_ref});
    defer allocator.free(full_dst);

    // helpers.Check receive.denyCurrentBranch for non-bare repos
    {
        const remote_head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{remote_git_dir});
        defer allocator.free(remote_head_path);
        if (std.fs.cwd().readFileAlloc(allocator, remote_head_path, 4096)) |head_content| {
            defer allocator.free(head_content);
            const trimmed_head = std.mem.trim(u8, head_content, " \t\r\n");
            if (std.mem.startsWith(u8, trimmed_head, "ref: ")) {
                const remote_current_ref = trimmed_head["ref: ".len..];
                // helpers.Check if this is a non-bare repo (has a working directory)
                const is_bare = blk: {
                    const remote_config_path = std.fmt.allocPrint(allocator, "{s}/config", .{remote_git_dir}) catch break :blk false;
                    defer allocator.free(remote_config_path);
                    const rcfg = std.fs.cwd().readFileAlloc(allocator, remote_config_path, 1024 * 1024) catch break :blk false;
                    defer allocator.free(rcfg);
                    if (std.mem.indexOf(u8, rcfg, "bare = true")) |_| break :blk true;
                    break :blk false;
                };
                if (!is_bare and std.mem.eql(u8, full_dst, remote_current_ref)) {
                    // helpers.Check receive.denyCurrentBranch config
                    const remote_config_path = std.fmt.allocPrint(allocator, "{s}/config", .{remote_git_dir}) catch "";
                    defer if (remote_config_path.len > 0) allocator.free(remote_config_path);
                    var deny = true; // default is refuse
                    if (remote_config_path.len > 0) {
                        if (std.fs.cwd().readFileAlloc(allocator, remote_config_path, 1024 * 1024)) |rcfg| {
                            defer allocator.free(rcfg);
                            if (helpers.parseConfigValue(rcfg, "receive.denycurrentbranch", allocator) catch null) |val| {
                                defer allocator.free(val);
                                if (std.ascii.eqlIgnoreCase(val, "false") or std.ascii.eqlIgnoreCase(val, "warn") or std.ascii.eqlIgnoreCase(val, "ignore")) deny = false;
                            }
                        } else |_| {}
                    }
                    if (deny) {
                        const branch_short = if (std.mem.startsWith(u8, full_dst, "refs/heads/")) full_dst["refs/heads/".len..] else full_dst;
                        const msg = try std.fmt.allocPrint(allocator, " ! [remote rejected] {s} -> {s} (branch is currently checked out)\nremote: error: refusing to update checked out branch: {s}\nremote: error: By default, updating the current branch in a non-bare repository\nremote: is denied.\nerror: failed to push some refs\n", .{ branch_short, branch_short, full_dst });
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        return error.ObjectNotFound; // Signal denial
                    }
                }
            }
        } else |_| {}
    }

    const dst_ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_git_dir, full_dst });
    defer allocator.free(dst_ref_path);

    // helpers.Read current remote ref value
    var old_hash: ?[]const u8 = null;
    if (std.fs.cwd().readFileAlloc(allocator, dst_ref_path, 256)) |content| {
        old_hash = std.mem.trim(u8, content, " \t\r\n");
    } else |_| {
        // helpers.Check packed-helpers.refs
        const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{remote_git_dir});
        defer allocator.free(packed_refs_path);
        if (std.fs.cwd().readFileAlloc(allocator, packed_refs_path, 1024 * 1024)) |packed_content| {
            defer allocator.free(packed_content);
            var lines = std.mem.splitScalar(u8, packed_content, '\n');
            while (lines.next()) |line| {
                if (line.len > 0 and line[0] == '#') continue;
                if (line.len > 0 and line[0] == '^') continue;
                if (std.mem.indexOf(u8, line, " ")) |sp| {
                    const hash = line[0..sp];
                    const ref_name = line[sp + 1 ..];
                    if (std.mem.eql(u8, ref_name, full_dst)) {
                        old_hash = try allocator.dupe(u8, hash);
                        break;
                    }
                }
            }
        } else |_| {}
    }

    // helpers.Check fast-forward (unless force)
    if (old_hash) |oh| {
        if (std.mem.eql(u8, oh, src_hash)) {
            // Already up to date
            if (!quiet) {
                const msg = try std.fmt.allocPrint(allocator, "Everything up-to-date\n", .{});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            }
            return;
        }

        if (!force) {
            // helpers.Check if src_hash is a descendant of old_hash (fast-forward check)
            const is_ff = helpers.isAncestor(local_git_dir, oh, src_hash, allocator, platform_impl) catch false;
            if (!is_ff) {
                const msg = try std.fmt.allocPrint(allocator, " ! [rejected]        {s} -> {s} (non-fast-forward)\nerror: failed to push some helpers.refs to '{s}'\nhint: Updates were rejected because the tip of your current branch is behind\nhint: its remote counterpart.\n", .{ dst_ref, dst_ref, remote_git_dir });
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                return error.ObjectNotFound; // Signal non-FF failure
            }
        }
    }

    if (dry_run) return;

    // helpers.Copy helpers.objects from local to remote
    try copyObjectsForPush(allocator, local_git_dir, remote_git_dir, src_hash, platform_impl);

    // helpers.Write the ref
    const ref_dir = std.fs.path.dirname(dst_ref_path) orelse ".";
    std.fs.cwd().makePath(ref_dir) catch {};
    const f = try std.fs.cwd().createFile(dst_ref_path, .{});
    defer f.close();
    const hash_line = try std.fmt.allocPrint(allocator, "{s}\n", .{src_hash});
    defer allocator.free(hash_line);
    try f.writeAll(hash_line);

    if (!quiet) {
        if (old_hash == null) {
            const msg = try std.fmt.allocPrint(allocator, " * [new branch]      {s} -> {s}\n", .{ dst_ref, dst_ref });
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
        }
    }
}


pub fn resolvePushRef(refname: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    if (!std.mem.startsWith(u8, refname, "refs/heads/")) return "";
    const branch = refname["refs/heads/".len..];
    const git_dir = helpers.findGitDir() catch return "";
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
    defer allocator.free(config_path);
    const config_data = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch return "";
    defer allocator.free(config_data);

    // helpers.Find remote.pushdefault or branch.<branch>.pushremote
    var push_remote = helpers.findConfigValue(config_data, "branch", branch, "pushremote");
    if (push_remote == null) push_remote = helpers.findConfigValue(config_data, "remote", null, "pushdefault");
    if (push_remote == null) push_remote = helpers.findConfigValue(config_data, "branch", branch, "remote");
    const remote = push_remote orelse return "";

    // push.default=current means push to same branch name
    return try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ remote, branch });
}


pub fn copyObjectsForPush(allocator: std.mem.Allocator, src_git_dir: []const u8, dst_git_dir: []const u8, commit_hash: []const u8, platform_impl: *const platform_mod.Platform) !void {
    // helpers.Walk commit chain and copy all reachable helpers.objects
    var to_visit = std.ArrayList([]const u8).init(allocator);
    defer {
        for (to_visit.items) |item| allocator.free(item);
        to_visit.deinit();
    }
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    try to_visit.append(try allocator.dupe(u8, commit_hash));

    while (to_visit.items.len > 0) {
        const hash = to_visit.orderedRemove(0);
        defer allocator.free(hash);

        if (visited.contains(hash)) continue;
        visited.put(hash, {}) catch continue;

        // helpers.Try to copy the loose object
        const src_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}/{s}", .{ src_git_dir, hash[0..2], hash[2..] });
        defer allocator.free(src_path);
        const dst_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}/{s}", .{ dst_git_dir, hash[0..2], hash[2..] });
        defer allocator.free(dst_path);

        // helpers.Create destination directory
        const dst_dir = try std.fmt.allocPrint(allocator, "{s}/objects/{s}", .{ dst_git_dir, hash[0..2] });
        defer allocator.free(dst_dir);
        std.fs.cwd().makePath(dst_dir) catch {};

        // helpers.Copy the object if it doesn't exist at destination (loose or pack)
        if (std.fs.cwd().access(dst_path, .{})) {
            // Already exists as loose object at destination - skip
        } else |_| {
            std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_path, .{}) catch {
                // helpers.Object might be in pack file - need to extract and write it
                const obj = objects.GitObject.load(hash, src_git_dir, platform_impl, allocator) catch continue;
                defer obj.deinit(allocator);
                _ = obj.store(dst_git_dir, platform_impl, allocator) catch continue;
            };
        }

        // helpers.Parse the object to find referenced helpers.objects
        const obj = objects.GitObject.load(hash, src_git_dir, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);

        switch (obj.type) {
            .commit => {
                var line_iter = std.mem.splitScalar(u8, obj.data, '\n');
                while (line_iter.next()) |line| {
                    if (line.len == 0) break;
                    if (std.mem.startsWith(u8, line, "tree ")) {
                        const tree_hash = line["tree ".len..];
                        if (!visited.contains(tree_hash)) {
                            try to_visit.append(try allocator.dupe(u8, tree_hash));
                        }
                    } else if (std.mem.startsWith(u8, line, "parent ")) {
                        const parent_hash = line["parent ".len..];
                        if (!visited.contains(parent_hash)) {
                            try to_visit.append(try allocator.dupe(u8, parent_hash));
                        }
                    }
                }
            },
            .tree => {
                var entries = tree_mod.parseTree(obj.data, allocator) catch continue;
                defer entries.deinit();
                for (entries.items) |entry| {
                    if (!visited.contains(entry.hash)) {
                        try to_visit.append(try allocator.dupe(u8, entry.hash));
                    }
                }
            },
            .tag => {
                var line_iter = std.mem.splitScalar(u8, obj.data, '\n');
                while (line_iter.next()) |line| {
                    if (std.mem.startsWith(u8, line, "object ")) {
                        const obj_hash = line["object ".len..];
                        if (!visited.contains(obj_hash)) {
                            try to_visit.append(try allocator.dupe(u8, obj_hash));
                        }
                        break;
                    }
                }
            },
            .blob => {},
        }
    }

    // helpers.Also copy pack files if needed
    const src_pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{src_git_dir});
    defer allocator.free(src_pack_dir);
    const dst_pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{dst_git_dir});
    defer allocator.free(dst_pack_dir);
    std.fs.cwd().makePath(dst_pack_dir) catch {};
}
