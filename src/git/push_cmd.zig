const std = @import("std");
const platform_mod = @import("../platform/platform.zig");
const refs = @import("refs.zig");
const objects = @import("objects.zig");
const fetch_cmd = @import("fetch_cmd.zig");

fn readFileContent(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
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
    // src_pattern should end with *
    if (!std.mem.endsWith(u8, src_pattern, "*")) return;
    if (!std.mem.endsWith(u8, dst_pattern, "*")) return;

    const src_prefix = src_pattern[0 .. src_pattern.len - 1];
    const dst_prefix = dst_pattern[0 .. dst_pattern.len - 1];

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

    for (local_refs.items) |entry| {
        if (!std.mem.startsWith(u8, entry.name, src_prefix)) continue;
        const suffix = entry.name[src_prefix.len..];
        const dst_ref = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dst_prefix, suffix });
        defer allocator.free(dst_ref);

        // Write the ref to the remote
        if (!dry_run) {
            const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_git_dir, dst_ref });
            defer allocator.free(ref_path);
            if (std.mem.lastIndexOfScalar(u8, ref_path, '/')) |ls| std.fs.cwd().makePath(ref_path[0..ls]) catch {};

            if (!force) {
                // Check fast-forward
                if (readFileContent(allocator, ref_path)) |old| {
                    defer allocator.free(old);
                    const old_h = std.mem.trim(u8, old, " \t\r\n");
                    if (old_h.len >= 40 and !std.mem.eql(u8, old_h[0..40], entry.hash)) {
                        if (!fetch_cmd.isAncestor(local_git_dir, old_h[0..40], entry.hash, allocator, platform_impl)) {
                            if (!quiet) {
                                const msg = try std.fmt.allocPrint(allocator, " ! [rejected]        {s} -> {s} (non-fast-forward)\n", .{ entry.name, dst_ref });
                                defer allocator.free(msg);
                                try platform_impl.writeStderr(msg);
                            }
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
}

pub fn cmdPush(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("push: not supported in freestanding mode\n");
        return;
    }

    // Touch trace files
    fetch_cmd.touchTraceFiles();

    const main_common = @import("../main_common.zig");

    const git_path = main_common.findGitDirectory(allocator, platform_impl) catch {
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
            } else {
                try refspecs_list.append(arg);
            }
        }
    }

    const remote = remote_name orelse "origin";

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

        if (std.mem.indexOf(u8, config_content, remote_section)) |section_start| {
            const after_section = config_content[section_start + remote_section.len ..];
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
            if (resolveSourceGitDir(allocator, remote)) |rgd| {
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

    // Determine what to push
    if (push_tags) {
        try pushWildcardRefspec(allocator, git_path, remote_git_dir, "refs/tags/*", "refs/tags/*", force_push, dry_run, quiet, platform_impl);
    }

    if (push_mirror) {
        // Mirror: push all refs
        try pushWildcardRefspec(allocator, git_path, remote_git_dir, "refs/*", "refs/*", true, dry_run, quiet, platform_impl);
    } else if (refspecs_list.items.len == 0 and !push_all and !push_tags) {
        // Default push
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

            // Check for wildcard refspec
            if (std.mem.indexOf(u8, rs, ":")) |colon| {
                const src = rs[0..colon];
                const dst_part = rs[colon + 1 ..];
                if (std.mem.endsWith(u8, src, "*") and std.mem.endsWith(u8, dst_part, "*")) {
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
                if (std.mem.eql(u8, rs, "HEAD")) {
                    if (refs.getCurrentBranch(git_path, platform_impl, allocator)) |branch| {
                        resolved_branch = branch;
                        push_src = branch;
                        push_dst = branch;
                    } else |_| {}
                }
                defer if (resolved_branch) |b| allocator.free(b);
                const full_refspec = if (std.mem.startsWith(u8, push_src, "refs/"))
                    try std.fmt.allocPrint(allocator, "{s}:{s}", .{ push_src, push_dst })
                else
                    try std.fmt.allocPrint(allocator, "refs/heads/{s}:refs/heads/{s}", .{ push_src, push_dst });
                defer allocator.free(full_refspec);
                pushSingleRefspec(allocator, git_path, remote_git_dir, full_refspec, force_this, dry_run, quiet, platform_impl) catch {
                    
                    std.process.exit(1);
                };
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
    const src_ref = refspec[0..colon_pos];
    const dst_ref = refspec[colon_pos + 1 ..];

    // Resolve source ref to hash
    const hash = blk: {
        // Try direct resolution
        if (refs.resolveRef(local_git_dir, src_ref, platform_impl, allocator) catch null) |h| break :blk h;
        // Try with refs/heads/ prefix
        if (!std.mem.startsWith(u8, src_ref, "refs/")) {
            const full = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{src_ref});
            defer allocator.free(full);
            if (refs.resolveRef(local_git_dir, full, platform_impl, allocator) catch null) |h| break :blk h;
            const full_tag = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{src_ref});
            defer allocator.free(full_tag);
            if (refs.resolveRef(local_git_dir, full_tag, platform_impl, allocator) catch null) |h| break :blk h;
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
    else
        try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{dst_ref});
    defer allocator.free(full_dst);

    if (!dry_run) {
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_git_dir, full_dst });
        defer allocator.free(ref_path);
        if (std.mem.lastIndexOfScalar(u8, ref_path, '/')) |ls| std.fs.cwd().makePath(ref_path[0..ls]) catch {};

        // Check fast-forward
        if (!force) {
            if (readFileContent(allocator, ref_path)) |old| {
                defer allocator.free(old);
                const old_h = std.mem.trim(u8, old, " \t\r\n");
                if (old_h.len >= 40 and !std.mem.eql(u8, old_h[0..40], hash)) {
                    if (!fetch_cmd.isAncestor(local_git_dir, old_h[0..40], hash, allocator, platform_impl)) {
                        const emsg = try std.fmt.allocPrint(allocator, "error: failed to push some refs to ''\n", .{});
                        defer allocator.free(emsg);
                        try platform_impl.writeStderr(emsg);
                        return error.NonFastForward;
                    }
                }
            } else |_| {}
        }

        const data = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
        defer allocator.free(data);
        std.fs.cwd().writeFile(.{ .sub_path = ref_path, .data = data }) catch {};
    }

    _ = quiet;
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
