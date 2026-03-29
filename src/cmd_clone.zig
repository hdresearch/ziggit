// Auto-generated from main_common.zig - cmd_clone
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const fetch_cmd = helpers.fetch_cmd;
const cmd_checkout = @import("cmd_checkout.zig");

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

pub fn cmdClone(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform, _: [][]const u8) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("clone: not supported in freestanding mode\n");
        return;
    }

    // helpers.Collect all arguments first
    var all_args = std.ArrayList([]const u8).init(allocator);
    defer all_args.deinit();
    
    while (args.next()) |arg| {
        try all_args.append(arg);
    }

    // helpers.Check flags
    var is_bare = false;
    var is_no_checkout = false;
    var is_shared = false;
    var is_mirror = false;
    var clone_depth: u32 = 0;
    {
        var i: usize = 0;
        while (i < all_args.items.len) : (i += 1) {
            const arg = all_args.items[i];
            if (std.mem.eql(u8, arg, "--bare")) is_bare = true;
            if (std.mem.eql(u8, arg, "--mirror")) { is_mirror = true; is_bare = true; }
            if (std.mem.eql(u8, arg, "--no-checkout") or std.mem.eql(u8, arg, "-n")) is_no_checkout = true;
            if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--shared")) is_shared = true;
            if (std.mem.eql(u8, arg, "--depth")) {
                if (i + 1 < all_args.items.len) {
                    clone_depth = std.fmt.parseInt(u32, all_args.items[i + 1], 10) catch 0;
                    i += 1; // skip the value
                }
            } else if (std.mem.startsWith(u8, arg, "--depth=")) {
                clone_depth = std.fmt.parseInt(u32, arg["--depth=".len..], 10) catch 0;
            }
        }
    }

    // helpers.For --bare with HTTPS URLs, use our native smart HTTP clone
    if (is_bare) {
        // helpers.Find the helpers.URL in args (skip flags and their values)
        var clone_url: ?[]const u8 = null;
        var clone_target: ?[]const u8 = null;
        {
            var i: usize = 0;
            while (i < all_args.items.len) : (i += 1) {
                const arg = all_args.items[i];
                if (std.mem.eql(u8, arg, "--depth") or std.mem.eql(u8, arg, "-b") or
                    std.mem.eql(u8, arg, "--branch") or std.mem.eql(u8, arg, "--origin") or
                    std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--reference") or
                    std.mem.eql(u8, arg, "--separate-git-dir"))
                {
                    i += 1; // skip the next arg (value)
                    continue;
                }
                if (std.mem.startsWith(u8, arg, "-")) continue;
                if (clone_url == null) {
                    clone_url = arg;
                } else if (clone_target == null) {
                    clone_target = arg;
                }
            }
        }

        if (clone_url) |url_val| {
            if (std.mem.startsWith(u8, url_val, "https://") or std.mem.startsWith(u8, url_val, "http://")) {
                const final_target = clone_target orelse blk: {
                    if (std.mem.lastIndexOfScalar(u8, url_val, '/')) |last_slash| {
                        const repo_name = url_val[last_slash + 1..];
                        if (std.mem.endsWith(u8, repo_name, ".git")) {
                            break :blk repo_name[0..repo_name.len - 4];
                        } else {
                            break :blk repo_name;
                        }
                    } else {
                        break :blk "repository";
                    }
                };

                const clone_msg = try std.fmt.allocPrint(allocator, "Cloning into bare repository '{s}'...\n", .{final_target});
                defer allocator.free(clone_msg);
                try platform_impl.writeStderr(clone_msg);

                const ziggit = @import("ziggit.zig");
                var repo = if (clone_depth > 0)
                    ziggit.Repository.cloneBareShallow(allocator, url_val, final_target, clone_depth) catch |err| {
                        const emsg = try std.fmt.allocPrint(allocator, "fatal: {}\n", .{err});
                        defer allocator.free(emsg);
                        try platform_impl.writeStderr(emsg);
                        std.process.exit(128);
                    }
                else
                    ziggit.Repository.cloneBare(allocator, url_val, final_target) catch |err| {
                        const emsg = try std.fmt.allocPrint(allocator, "fatal: {}\n", .{err});
                        defer allocator.free(emsg);
                        try platform_impl.writeStderr(emsg);
                        std.process.exit(128);
                    };
                repo.close();
                return;
            }
        }
    }

    // helpers.Handle --no-checkout with HTTPS URLs natively
    if (is_no_checkout) {
        var clone_url: ?[]const u8 = null;
        var clone_target: ?[]const u8 = null;
        for (all_args.items) |arg| {
            if (std.mem.startsWith(u8, arg, "-")) continue;
            if (clone_url == null) {
                clone_url = arg;
            } else if (clone_target == null) {
                clone_target = arg;
            }
        }

        if (clone_url) |url_val| {
            if (std.mem.startsWith(u8, url_val, "https://") or std.mem.startsWith(u8, url_val, "http://")) {
                const final_target = clone_target orelse blk: {
                    if (std.mem.lastIndexOfScalar(u8, url_val, '/')) |last_slash| {
                        const repo_name = url_val[last_slash + 1..];
                        if (std.mem.endsWith(u8, repo_name, ".git")) {
                            break :blk repo_name[0..repo_name.len - 4];
                        } else {
                            break :blk repo_name;
                        }
                    } else {
                        break :blk "repository";
                    }
                };

                const clone_msg = try std.fmt.allocPrint(allocator, "Cloning into '{s}'...\n", .{final_target});
                defer allocator.free(clone_msg);
                try platform_impl.writeStderr(clone_msg);

                // helpers.Use cloneBare to download everything into a temp bare dir, then convert to non-bare
                const ziggit = @import("ziggit.zig");
                const bare_target = try std.fmt.allocPrint(allocator, "{s}/.git", .{final_target});
                defer allocator.free(bare_target);

                // helpers.Create the worktree directory first
                std.fs.cwd().makePath(final_target) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        const msg = try std.fmt.allocPrint(allocator, "fatal: destination path '{s}' already exists and is not an empty directory.\n", .{final_target});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(128);
                    },
                    else => return err,
                };

                // Clone bare into .git subdirectory
                var repo = ziggit.Repository.cloneBare(allocator, url_val, bare_target) catch |err| {
                    // helpers.Clean up on failure
                    std.fs.cwd().deleteTree(final_target) catch {};
                    const emsg = try std.fmt.allocPrint(allocator, "fatal: {}\n", .{err});
                    defer allocator.free(emsg);
                    try platform_impl.writeStderr(emsg);
                    std.process.exit(128);
                };
                repo.close();

                // helpers.Convert bare repo to non-bare: update config to set bare = false
                const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{bare_target});
                defer allocator.free(config_path);
                const config_content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| {
                    const emsg = try std.fmt.allocPrint(allocator, "fatal: failed to read config: {}\n", .{err});
                    defer allocator.free(emsg);
                    try platform_impl.writeStderr(emsg);
                    std.process.exit(128);
                };
                defer allocator.free(config_content);

                // helpers.Replace bare = true with bare = false
                var new_config = std.ArrayList(u8).init(allocator);
                defer new_config.deinit();
                var config_lines = std.mem.splitSequence(u8, config_content, "\n");
                var first = true;
                while (config_lines.next()) |cline| {
                    if (!first) try new_config.appendSlice("\n");
                    first = false;
                    const trimmed = std.mem.trim(u8, cline, " \t\r");
                    if (std.mem.eql(u8, trimmed, "bare = true")) {
                        // Preserve leading whitespace
                        for (cline) |c| {
                            if (c == ' ' or c == '\t') {
                                try new_config.append(c);
                            } else break;
                        }
                        try new_config.appendSlice("bare = false");
                    } else {
                        try new_config.appendSlice(cline);
                    }
                }

                const cf = try std.fs.cwd().createFile(config_path, .{});
                defer cf.close();
                try cf.writeAll(new_config.items);

                return; // --no-checkout means skip checkout
            }
        }

        // Non-HTTPS --no-checkout: fall through to git
    }

    // helpers.For non-HTTPS --bare, handle locally
    if (is_bare) {
        // helpers.Find helpers.URL and target for bare clone
        var bare_url: ?[]const u8 = null;
        var bare_target: ?[]const u8 = null;
        {
            var i: usize = 0;
            while (i < all_args.items.len) : (i += 1) {
                const arg = all_args.items[i];
                if (std.mem.eql(u8, arg, "--depth") or std.mem.eql(u8, arg, "-b") or
                    std.mem.eql(u8, arg, "--branch") or std.mem.eql(u8, arg, "--origin") or
                    std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--reference") or
                    std.mem.eql(u8, arg, "--separate-git-dir"))
                {
                    i += 1;
                    continue;
                }
                if (std.mem.startsWith(u8, arg, "-")) continue;
                if (bare_url == null) {
                    bare_url = arg;
                } else if (bare_target == null) {
                    bare_target = arg;
                }
            }
        }
        if (bare_url) |burl| {
            if (!(std.mem.startsWith(u8, burl, "https://") or std.mem.startsWith(u8, burl, "http://") or
                std.mem.startsWith(u8, burl, "ssh://") or std.mem.startsWith(u8, burl, "git://")))
            {
                const bfinal_target = bare_target orelse bt: {
                    if (std.mem.lastIndexOfScalar(u8, burl, '/')) |ls| {
                        const rn = burl[ls + 1..];
                        if (std.mem.endsWith(u8, rn, ".git")) break :bt rn else {
                            const bn = try std.fmt.allocPrint(allocator, "{s}.git", .{rn});
                            break :bt bn;
                        }
                    } else break :bt "repository.git";
                };

                const bare_msg = try std.fmt.allocPrint(allocator, "Cloning into bare repository '{s}'...\n", .{bfinal_target});
                defer allocator.free(bare_msg);
                try platform_impl.writeStderr(bare_msg);

                performLocalClone(allocator, burl, bfinal_target, true, false, null, null, platform_impl, false, is_mirror) catch {
                    try platform_impl.writeStderr("fatal: repository does not exist\n");
                    std.process.exit(128);
                };
                return;
            }
        }
    }

    // helpers.Parse arguments for our internal implementation
    var url: ?[]const u8 = null;
    var target_dir: ?[]const u8 = null;

    {
        var i: usize = 0;
        while (i < all_args.items.len) : (i += 1) {
            const arg = all_args.items[i];
            // helpers.Skip flags that take a value argument
            if (std.mem.eql(u8, arg, "--depth") or std.mem.eql(u8, arg, "-b") or
                std.mem.eql(u8, arg, "--branch") or std.mem.eql(u8, arg, "--origin") or
                std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--reference") or
                std.mem.eql(u8, arg, "--separate-git-dir") or std.mem.eql(u8, arg, "-j") or
                std.mem.eql(u8, arg, "--jobs") or std.mem.eql(u8, arg, "--filter"))
            {
                i += 1; // skip value
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-")) continue;
            if (url == null) {
                url = arg;
            } else if (target_dir == null) {
                target_dir = arg;
            } else {
                const emsg = try std.fmt.allocPrint(allocator, "fatal: helpers.Too many arguments.\n\nusage: git clone [<options>] [--] <repo> [<dir>]\n", .{});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(128);
            }
        }
    }

    if (url == null) {
        try platform_impl.writeStderr("fatal: helpers.You must specify a repository to clone.\n");
        std.process.exit(128);
    }

    const raw_target_dir = target_dir orelse blk: {
        // helpers.Extract directory name from helpers.URL
        if (std.mem.lastIndexOfScalar(u8, url.?, '/')) |last_slash| {
            const repo_name = url.?[last_slash + 1..];
            if (std.mem.endsWith(u8, repo_name, ".git")) {
                break :blk repo_name[0..repo_name.len - 4];
            } else {
                break :blk repo_name;
            }
        } else {
            break :blk "repository";
        }
    };
    
    // helpers.Strip trailing slashes from target directory
    const final_target_dir = std.mem.trimRight(u8, raw_target_dir, "/");
    
    // helpers.For non-HTTP URLs (local paths, ssh://, git://), handle local clone natively
    if (!(std.mem.startsWith(u8, url.?, "https://") or std.mem.startsWith(u8, url.?, "http://"))) {
        // helpers.Parse --branch and --origin flags
        var clone_branch: ?[]const u8 = null;
        var clone_origin: ?[]const u8 = null;
        {
            var i: usize = 0;
            while (i < all_args.items.len) : (i += 1) {
                const arg = all_args.items[i];
                if ((std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--branch")) and i + 1 < all_args.items.len) {
                    clone_branch = all_args.items[i + 1];
                    i += 1;
                } else if (std.mem.startsWith(u8, arg, "--branch=")) {
                    clone_branch = arg["--branch=".len..];
                } else if ((std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--origin")) and i + 1 < all_args.items.len) {
                    clone_origin = all_args.items[i + 1];
                    i += 1;
                } else if (std.mem.startsWith(u8, arg, "--origin=")) {
                    clone_origin = arg["--origin=".len..];
                }
            }
        }

        // helpers.Validate origin name
        if (clone_origin) |origin| {
            if (!helpers.isValidRemoteName(origin)) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' is not a valid remote name\n", .{origin});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }
        }

        // helpers.For SSH and git:// protocols, show error (SSH transport not yet fully integrated into clone)
        if (std.mem.startsWith(u8, url.?, "ssh://") or std.mem.startsWith(u8, url.?, "git://") or
            (std.mem.indexOf(u8, url.?, ":") != null and std.mem.indexOf(u8, url.?, "/") != null and
             (std.mem.indexOf(u8, url.?, ":").? < std.mem.indexOf(u8, url.?, "/").?) and !std.mem.startsWith(u8, url.?, "/") and !std.mem.startsWith(u8, url.?, "file://")))
        {
            try platform_impl.writeStderr("fatal: SSH/git:// clone not yet supported natively\n");
            std.process.exit(128);
        }

        // helpers.Check if target directory already exists and is non-empty
        if (platform_impl.fs.exists(final_target_dir) catch false) {
            // helpers.Check if it's a directory
            const is_dir = blk: {
                var dir = std.fs.cwd().openDir(final_target_dir, .{ .iterate = true }) catch break :blk false;
                defer dir.close();
                // helpers.Check if empty
                var iter = dir.iterate();
                if (iter.next() catch null) |_| break :blk false; // has entries = not empty
                break :blk true; // empty dir is OK
            };
            if (!is_dir) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: destination path '{s}' already exists and is not an empty directory.\n", .{final_target_dir});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }
        }

        const clone_msg = try std.fmt.allocPrint(allocator, "Cloning into '{s}'...\n", .{final_target_dir});
        defer allocator.free(clone_msg);
        try platform_impl.writeStderr(clone_msg);

        performLocalClone(allocator, url.?, final_target_dir, false, is_no_checkout, clone_branch, clone_origin, platform_impl, is_shared, is_mirror) catch |err| {
            // helpers.Clean up on failure
            std.fs.cwd().deleteTree(final_target_dir) catch {};
            const emsg = try std.fmt.allocPrint(allocator, "fatal: {}\n", .{err});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(128);
        };
        return;
    }

    // helpers.Check if target directory already exists
    if (platform_impl.fs.exists(final_target_dir) catch false) {
        const msg = try std.fmt.allocPrint(allocator, "fatal: destination path '{s}' already exists and is not an empty directory.\n", .{final_target_dir});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    }
    
    const clone_msg = try std.fmt.allocPrint(allocator, "Cloning into '{s}'...\n", .{final_target_dir});
    defer allocator.free(clone_msg);
    try platform_impl.writeStderr(clone_msg);
    
    // helpers.For HTTPS URLs, use native smart HTTP clone + checkout
    if (std.mem.startsWith(u8, url.?, "https://") or std.mem.startsWith(u8, url.?, "http://")) {
        const ziggit = @import("ziggit.zig");
        const bare_target = try std.fmt.allocPrint(allocator, "{s}/.git", .{final_target_dir});
        defer allocator.free(bare_target);

        // helpers.Create the worktree directory first
        std.fs.cwd().makePath(final_target_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const msg = try std.fmt.allocPrint(allocator, "fatal: destination path '{s}' already exists and is not an empty directory.\n", .{final_target_dir});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            },
            else => return err,
        };

        // Clone bare into .git subdirectory (with optional shallow depth)
        var repo = if (clone_depth > 0)
            ziggit.Repository.cloneBareShallow(allocator, url.?, bare_target, clone_depth) catch |err| {
                std.fs.cwd().deleteTree(final_target_dir) catch {};
                const emsg = try std.fmt.allocPrint(allocator, "fatal: {}\n", .{err});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(128);
            }
        else
            ziggit.Repository.cloneBare(allocator, url.?, bare_target) catch |err| {
                std.fs.cwd().deleteTree(final_target_dir) catch {};
                const emsg = try std.fmt.allocPrint(allocator, "fatal: {}\n", .{err});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(128);
            };
        repo.close();

        // helpers.Convert bare repo to non-bare: update config to set bare = false
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{bare_target});
        defer allocator.free(config_path);
        const config_content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| {
            const emsg = try std.fmt.allocPrint(allocator, "fatal: failed to read config: {}\n", .{err});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(128);
        };
        defer allocator.free(config_content);

        // helpers.Replace bare = true with bare = false
        var new_config = std.ArrayList(u8).init(allocator);
        defer new_config.deinit();
        var config_lines = std.mem.splitSequence(u8, config_content, "\n");
        var first = true;
        while (config_lines.next()) |cline| {
            if (!first) try new_config.appendSlice("\n");
            first = false;
            const trimmed = std.mem.trim(u8, cline, " \t\r");
            if (std.mem.eql(u8, trimmed, "bare = true")) {
                for (cline) |c| {
                    if (c == ' ' or c == '\t') {
                        try new_config.append(c);
                    } else break;
                }
                try new_config.appendSlice("bare = false");
            } else {
                try new_config.appendSlice(cline);
            }
        }

        {
            const cf = try std.fs.cwd().createFile(config_path, .{});
            defer cf.close();
            try cf.writeAll(new_config.items);
        }

        // helpers.Checkout helpers.HEAD into worktree
        const head_commit = refs.getCurrentCommit(bare_target, platform_impl, allocator) catch {
            // helpers.Empty repository - no checkout needed
            return;
        };
        if (head_commit) |commit_hash| {
            defer allocator.free(commit_hash);
            helpers.checkoutCommitTree(bare_target, commit_hash, allocator, platform_impl) catch |err| {
                const emsg = try std.fmt.allocPrint(allocator, "warning: checkout failed: {}, repository cloned but working tree not populated\n", .{err});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
            };
        }

        return;
    }

    // helpers.Perform clone using dumb HTTP protocol (non-HTTPS fallback)
    network.cloneRepository(allocator, url.?, final_target_dir, platform_impl) catch |err| switch (err) {
        error.RepositoryNotFound => {
            try platform_impl.writeStderr("fatal: repository not found\n");
            std.process.exit(128);
        },
        error.InvalidUrl => {
            try platform_impl.writeStderr("fatal: invalid repository URL\n");
            std.process.exit(128);
        },
        error.HttpError => {
            try platform_impl.writeStderr("fatal: unable to access remote repository\n");
            std.process.exit(128);
        },
        error.NoValidBranch => {
            try platform_impl.writeStderr("warning: remote helpers.HEAD refers to nonexistent ref, unable to checkout.\n");
            std.process.exit(128);
        },
        error.AlreadyExists => {
            try platform_impl.writeStderr("fatal: destination path already exists\n");
            std.process.exit(128);
        },
        else => return err,
    };
}


pub fn performLocalClone(
    allocator: std.mem.Allocator,
    source_url: []const u8,
    target_dir: []const u8,
    is_bare: bool,
    is_no_checkout: bool,
    branch: ?[]const u8,
    origin_name: ?[]const u8,
    platform_impl: *const platform_mod.Platform,
    is_shared: bool,
    is_mirror: bool,
) !void {
    // helpers.Resolve source git directory
    const src_git_dir = try helpers.resolveSourceGitDir(allocator, source_url);
    defer allocator.free(src_git_dir);

    const remote_name = origin_name orelse "origin";

    // helpers.Determine the target .git directory
    const dst_git_dir = if (is_bare)
        try allocator.dupe(u8, target_dir)
    else
        try std.fmt.allocPrint(allocator, "{s}/.git", .{target_dir});
    defer allocator.free(dst_git_dir);

    // helpers.Create destination directory structure
    std.fs.cwd().makePath(dst_git_dir) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "fatal: cannot mkdir {s}: {}\n", .{ dst_git_dir, err });
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    };

    // helpers.Create standard git directory structure
    const dirs_to_create = [_][]const u8{
        "objects", "objects/info", "objects/pack", "refs", "refs/heads", "refs/tags", "info", "hooks",
    };
    for (dirs_to_create) |subdir| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst_git_dir, subdir });
        defer allocator.free(full_path);
        std.fs.cwd().makePath(full_path) catch {};
    }

    // helpers.Copy or share helpers.objects (loose helpers.objects + pack files)
    const src_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{src_git_dir});
    defer allocator.free(src_objects);
    const dst_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{dst_git_dir});
    defer allocator.free(dst_objects);

    if (is_shared) {
        // helpers.Create alternates file pointing to source helpers.objects
        const alt_dir = try std.fmt.allocPrint(allocator, "{s}/objects/info", .{dst_git_dir});
        defer allocator.free(alt_dir);
        std.fs.cwd().makePath(alt_dir) catch {};
        const alt_path = try std.fmt.allocPrint(allocator, "{s}/objects/info/alternates", .{dst_git_dir});
        defer allocator.free(alt_path);
        const abs_src_objects = std.fs.cwd().realpathAlloc(allocator, src_objects) catch try allocator.dupe(u8, src_objects);
        defer allocator.free(abs_src_objects);
        {
            const f = try std.fs.cwd().createFile(alt_path, .{});
            defer f.close();
            try f.writeAll(abs_src_objects);
            try f.writeAll("\n");
        }
    } else {
        try helpers.copyDirectoryRecursive(allocator, src_objects, dst_objects);
    }

    // helpers.Copy packed-helpers.refs if it exists
    const src_packed_refs = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{src_git_dir});
    defer allocator.free(src_packed_refs);

    // helpers.Read source helpers.HEAD to determine default branch
    const src_head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{src_git_dir});
    defer allocator.free(src_head_path);
    const src_head_content = std.fs.cwd().readFileAlloc(allocator, src_head_path, 4096) catch "ref: refs/heads/master\n";
    defer if (src_head_content.ptr != @as([*]const u8, "ref: refs/heads/master\n")) allocator.free(src_head_content);

    const src_head_trimmed = std.mem.trim(u8, src_head_content, " \t\r\n");

    // helpers.Determine the default branch from source helpers.HEAD
    var default_branch: []const u8 = "master";
    if (std.mem.startsWith(u8, src_head_trimmed, "ref: refs/heads/")) {
        default_branch = src_head_trimmed["ref: refs/heads/".len..];
    }

    // helpers.If --branch was specified, use that
    const checkout_branch = branch orelse default_branch;

    if (is_bare) {
        // helpers.For bare repos, copy all helpers.refs directly and set helpers.HEAD
        const src_refs = try std.fmt.allocPrint(allocator, "{s}/refs", .{src_git_dir});
        defer allocator.free(src_refs);
        const dst_refs = try std.fmt.allocPrint(allocator, "{s}/refs", .{dst_git_dir});
        defer allocator.free(dst_refs);
        try helpers.copyDirectoryRecursive(allocator, src_refs, dst_refs);

        // helpers.Copy packed-helpers.refs
        const dst_packed_refs = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{dst_git_dir});
        defer allocator.free(dst_packed_refs);
        std.fs.cwd().copyFile(src_packed_refs, std.fs.cwd(), dst_packed_refs, .{}) catch {};

        // Set helpers.HEAD
        const dst_head = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{dst_git_dir});
        defer allocator.free(dst_head);
        {
            const f = try std.fs.cwd().createFile(dst_head, .{});
            defer f.close();
            const head_ref = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{checkout_branch});
            defer allocator.free(head_ref);
            try f.writeAll(head_ref);
        }

        // helpers.Write config
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{dst_git_dir});
        defer allocator.free(config_path);
        {
            const f = try std.fs.cwd().createFile(config_path, .{});
            defer f.close();
            // helpers.Resolve the source helpers.URL to an absolute path for the remote
            const abs_source = fetch_cmd.resolveUrlPreservingDot(allocator, source_url) catch try allocator.dupe(u8, source_url);
            defer allocator.free(abs_source);
            const cfg = if (is_mirror)
                try std.fmt.allocPrint(allocator, "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n[remote \"{s}\"]\n\turl = {s}\n\tfetch = +refs/*:refs/*\n\tmirror = true\n", .{ remote_name, abs_source })
            else
                try std.fmt.allocPrint(allocator, "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n[remote \"{s}\"]\n\turl = {s}\n\tfetch = +refs/heads/*:refs/heads/*\n", .{ remote_name, abs_source });
            defer allocator.free(cfg);
            try f.writeAll(cfg);
        }

        // helpers.Write description
        const desc_path = try std.fmt.allocPrint(allocator, "{s}/description", .{dst_git_dir});
        defer allocator.free(desc_path);
        {
            const f = std.fs.cwd().createFile(desc_path, .{}) catch return;
            defer f.close();
            f.writeAll("Unnamed repository; edit this file 'description' to name the repository.\n") catch {};
        }

    } else {
        // Non-bare clone: source helpers.refs become remote tracking helpers.refs
        // helpers.Map source refs/heads/* to refs/remotes/<origin>/*
        const remote_refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}", .{ dst_git_dir, remote_name });
        defer allocator.free(remote_refs_dir);
        std.fs.cwd().makePath(remote_refs_dir) catch {};

        // helpers.Copy source heads to remote tracking
        const src_heads = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{src_git_dir});
        defer allocator.free(src_heads);

        // helpers.Read all source branch helpers.refs (loose)
        var branch_map = std.StringHashMap([]const u8).init(allocator);
        defer {
            var it = branch_map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            branch_map.deinit();
        }

        if (std.fs.cwd().openDir(src_heads, .{ .iterate = true })) |*dir_handle| {
            var d = dir_handle.*;
            defer d.close();
            var iter = d.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind == .file) {
                    const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_heads, entry.name });
                    defer allocator.free(ref_path);
                    const hash = std.fs.cwd().readFileAlloc(allocator, ref_path, 256) catch continue;
                    const hash_trimmed = std.mem.trim(u8, hash, " \t\r\n");
                    const ht = try allocator.dupe(u8, hash_trimmed);
                    allocator.free(hash);
                    try branch_map.put(try allocator.dupe(u8, entry.name), ht);
                }
            }
        } else |_| {}

        // helpers.Also read packed-helpers.refs from source
        if (std.fs.cwd().readFileAlloc(allocator, src_packed_refs, 10 * 1024 * 1024)) |packed_content| {
            defer allocator.free(packed_content);
            var lines = std.mem.splitScalar(u8, packed_content, '\n');
            while (lines.next()) |line| {
                if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
                // Format: <hash> <refname>
                if (std.mem.indexOfScalar(u8, line, ' ')) |space_idx| {
                    const hash = line[0..space_idx];
                    const refname = line[space_idx + 1..];
                    if (std.mem.startsWith(u8, refname, "refs/heads/")) {
                        const bname = refname["refs/heads/".len..];
                        if (!branch_map.contains(bname)) {
                            try branch_map.put(
                                try allocator.dupe(u8, bname),
                                try allocator.dupe(u8, hash),
                            );
                        }
                    }
                }
            }
        } else |_| {}

        // helpers.Write remote tracking helpers.refs
        var branch_iter = branch_map.iterator();
        while (branch_iter.next()) |entry| {
            const dst_ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_refs_dir, entry.key_ptr.* });
            defer allocator.free(dst_ref_path);
            const f = std.fs.cwd().createFile(dst_ref_path, .{}) catch continue;
            defer f.close();
            f.writeAll(entry.value_ptr.*) catch continue;
            f.writeAll("\n") catch continue;
        }

        // helpers.Copy tags
        const src_tags = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{src_git_dir});
        defer allocator.free(src_tags);
        const dst_tags = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{dst_git_dir});
        defer allocator.free(dst_tags);
        helpers.copyDirectoryRecursive(allocator, src_tags, dst_tags) catch {};

        // helpers.Also copy packed-helpers.refs but rewrite heads to remotes
        if (std.fs.cwd().readFileAlloc(allocator, src_packed_refs, 10 * 1024 * 1024)) |packed_content| {
            defer allocator.free(packed_content);
            var new_packed = std.ArrayList(u8).init(allocator);
            defer new_packed.deinit();
            var lines = std.mem.splitScalar(u8, packed_content, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                if (line[0] == '#') {
                    try new_packed.appendSlice(line);
                    try new_packed.append('\n');
                    continue;
                }
                if (std.mem.indexOf(u8, line, "refs/heads/")) |_| {
                    // Rewrite refs/heads/X to refs/remotes/<origin>/X
                    if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
                        try new_packed.appendSlice(line[0 .. sp + 1]);
                        const refname = line[sp + 1..];
                        if (std.mem.startsWith(u8, refname, "refs/heads/")) {
                            const bname = refname["refs/heads/".len..];
                            const new_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ remote_name, bname });
                            defer allocator.free(new_ref);
                            try new_packed.appendSlice(new_ref);
                        } else {
                            try new_packed.appendSlice(refname);
                        }
                        try new_packed.append('\n');
                    }
                } else if (std.mem.indexOf(u8, line, "refs/tags/")) |_| {
                    try new_packed.appendSlice(line);
                    try new_packed.append('\n');
                } else if (line[0] == '^') {
                    // Peeled tag ref - keep it
                    try new_packed.appendSlice(line);
                    try new_packed.append('\n');
                }
            }
            if (new_packed.items.len > 0) {
                const dst_packed = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{dst_git_dir});
                defer allocator.free(dst_packed);
                const f = std.fs.cwd().createFile(dst_packed, .{}) catch unreachable;
                defer f.close();
                f.writeAll(new_packed.items) catch {};
            }
        } else |_| {}

        // helpers.Create refs/remotes/origin/helpers.HEAD symbolic ref pointing to default branch
        {
            const remote_head_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}/HEAD", .{ dst_git_dir, remote_name });
            defer allocator.free(remote_head_path);
            const remote_head_content = try std.fmt.allocPrint(allocator, "ref: refs/remotes/{s}/{s}\n", .{ remote_name, default_branch });
            defer allocator.free(remote_head_content);
            const rhf = std.fs.cwd().createFile(remote_head_path, .{}) catch null;
            if (rhf) |f| {
                defer f.close();
                f.writeAll(remote_head_content) catch {};
            }
        }

        // helpers.Validate -b branch exists if specified
        if (branch != null) {
            if (branch_map.get(checkout_branch) == null) {
                if (branch_map.count() == 0) {
                    // helpers.Empty repo
                    const msg = try std.fmt.allocPrint(allocator, "fatal: you do not appear to have cloned an empty repository.\nwarning: helpers.You appear to have cloned an empty repository.\n", .{});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    // helpers.Clean up the created directory
                    std.fs.cwd().deleteTree(target_dir) catch {};
                    std.process.exit(128);
                } else {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: Remote branch {s} not found in upstream origin\n", .{checkout_branch});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    // helpers.Clean up the created directory
                    std.fs.cwd().deleteTree(target_dir) catch {};
                    std.process.exit(128);
                }
            }
        }

        // helpers.Create local branch from the checkout branch
        const branch_hash = branch_map.get(checkout_branch) orelse blk: {
            // helpers.Try default_branch if checkout_branch not found
            if (branch_map.get(default_branch)) |h| break :blk h;
            // helpers.Use first available branch
            var first_iter = branch_map.iterator();
            if (first_iter.next()) |entry| break :blk entry.value_ptr.*;
            break :blk null;
        };

        if (branch_hash) |hash| {
            // helpers.Create local branch ref
            const local_ref = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ dst_git_dir, checkout_branch });
            defer allocator.free(local_ref);
            {
                const f = try std.fs.cwd().createFile(local_ref, .{});
                defer f.close();
                try f.writeAll(hash);
                try f.writeAll("\n");
            }

            // Set helpers.HEAD to point to the branch
            const dst_head = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{dst_git_dir});
            defer allocator.free(dst_head);
            {
                const f = try std.fs.cwd().createFile(dst_head, .{});
                defer f.close();
                const head_content = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{checkout_branch});
                defer allocator.free(head_content);
                try f.writeAll(head_content);
            }
        } else {
            // helpers.Empty repository or no branches
            const dst_head = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{dst_git_dir});
            defer allocator.free(dst_head);
            {
                const f = try std.fs.cwd().createFile(dst_head, .{});
                defer f.close();
                try f.writeAll("ref: refs/heads/master\n");
            }
            try platform_impl.writeStderr("warning: helpers.You appear to have cloned an empty repository.\n");
        }

        // helpers.Write config
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{dst_git_dir});
        defer allocator.free(config_path);
        {
            const f = try std.fs.cwd().createFile(config_path, .{});
            defer f.close();
            const abs_source = fetch_cmd.resolveUrlPreservingDot(allocator, source_url) catch try allocator.dupe(u8, source_url);
            defer allocator.free(abs_source);
            const cfg = try std.fmt.allocPrint(allocator, "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n[remote \"{s}\"]\n\turl = {s}\n\tfetch = +refs/heads/*:refs/remotes/{s}/*\n[branch \"{s}\"]\n\tremote = {s}\n\tmerge = refs/heads/{s}\n", .{ remote_name, abs_source, remote_name, checkout_branch, remote_name, checkout_branch });
            defer allocator.free(cfg);
            try f.writeAll(cfg);
        }

        // helpers.Write description
        const desc_path = try std.fmt.allocPrint(allocator, "{s}/description", .{dst_git_dir});
        defer allocator.free(desc_path);
        {
            const f = std.fs.cwd().createFile(desc_path, .{}) catch return;
            defer f.close();
            f.writeAll("Unnamed repository; edit this file 'description' to name the repository.\n") catch {};
        }

        // helpers.Checkout working tree (unless --no-checkout)
        if (!is_no_checkout and branch_hash != null) {
            helpers.checkoutCommitTree(dst_git_dir, branch_hash.?, allocator, platform_impl) catch |err| {
                const emsg = try std.fmt.allocPrint(allocator, "warning: checkout failed: {}, repository cloned but working tree not populated\n", .{err});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
            };
        }
    }
}


