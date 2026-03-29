// Auto-generated from main_common.zig - cmd_init
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

pub fn cmdInit(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform, global_bare: bool) !void {
    var bare = global_bare;
    var template_dir: ?[]const u8 = null;
    var template_dir_set = false;
    var work_dir: ?[]const u8 = null;
    var initial_branch: ?[]const u8 = null;
    var quiet = false;
    var separate_git_dir: ?[]const u8 = null;
    var shared: ?[]const u8 = null;
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bare")) {
            bare = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.startsWith(u8, arg, "--template=")) {
            template_dir = arg["--template=".len..];
            template_dir_set = true;
        } else if (std.mem.eql(u8, arg, "--template")) {
            template_dir = args.next();
            template_dir_set = true;
        } else if (std.mem.startsWith(u8, arg, "--initial-branch=")) {
            initial_branch = arg["--initial-branch=".len..];
        } else if (std.mem.eql(u8, arg, "--initial-branch") or std.mem.eql(u8, arg, "-b")) {
            initial_branch = args.next();
        } else if (std.mem.startsWith(u8, arg, "--separate-git-dir=")) {
            separate_git_dir = arg["--separate-git-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--separate-git-dir")) {
            separate_git_dir = args.next();
        } else if (std.mem.startsWith(u8, arg, "--shared=")) {
            shared = arg["--shared=".len..];
        } else if (std.mem.eql(u8, arg, "--shared")) {
            shared = args.next();
        } else if (std.mem.startsWith(u8, arg, "--object-format=") or
                   std.mem.startsWith(u8, arg, "--ref-format=")) {
            // Silently accept for now (only sha1/files supported)
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            work_dir = arg;
        }
    }
    
    // helpers.Check GIT_WORK_TREE
    const env_work_tree = std.process.getEnvVarOwned(allocator, "GIT_WORK_TREE") catch null;
    defer if (env_work_tree) |w| allocator.free(w);
    
    // helpers.Check helpers.GIT_DIR environment variable — also respect --git-dir= global override
    const env_git_dir_raw = std.process.getEnvVarOwned(allocator, "GIT_DIR") catch null;
    defer if (env_git_dir_raw) |g| allocator.free(g);
    const env_git_dir: ?[]const u8 = if (helpers.global_git_dir_override) |gd| gd else env_git_dir_raw;
    
    if (env_work_tree != null) {
        if (bare) {
            try platform_impl.writeStderr("fatal: GIT_WORK_TREE (or --work-tree=<directory>) not allowed in combination with '--(bare|shared)'\n");
            std.process.exit(128);
        }
        // GIT_WORK_TREE + helpers.GIT_DIR together is OK (sets up worktree in separate location)
        // But GIT_WORK_TREE without helpers.GIT_DIR during init should fail
        if (env_git_dir == null) {
            try platform_impl.writeStderr("fatal: GIT_WORK_TREE (or --work-tree=<directory>) not allowed without helpers.GIT_DIR being set\n");
            std.process.exit(128);
        }
    }
    
    // helpers.Check --separate-git-dir + --bare incompatibility
    if (separate_git_dir != null and bare) {
        try platform_impl.writeStderr("fatal: options '--separate-git-dir' and '--bare' cannot be used together\n");
        std.process.exit(128);
    }
    
    // helpers.Check --separate-git-dir + implicit bare (GIT_DIR=.) incompatibility 
    if (separate_git_dir != null and env_git_dir != null and helpers.global_git_dir_override == null) {
        // helpers.When helpers.GIT_DIR is set, it's implicitly bare-like, incompatible with --separate-git-dir
        try platform_impl.writeStderr("fatal: --separate-git-dir incompatible with bare repository\n");
        std.process.exit(128);
    }
    
    // helpers.If helpers.GIT_DIR is set, use it as the git directory instead of default
    const target_dir = work_dir orelse ".";
    
    if (env_git_dir) |git_dir_env| {
        // helpers.When --bare and a positional directory is given, the positional arg overrides helpers.GIT_DIR
        if (bare and work_dir != null) {
            try initRepository(target_dir, bare, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
        } else {
            // helpers.Use helpers.GIT_DIR as the git directory
            try initRepositoryWithGitDir(target_dir, git_dir_env, bare, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
        }
    } else if (separate_git_dir) |sep_dir| {
        // helpers.Create repo with separate git dir
        try initRepositoryWithSeparateGitDir(target_dir, sep_dir, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
    } else {
        try initRepository(target_dir, bare, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
    }
}


pub fn initRepository(path: []const u8, bare: bool, template_dir: ?[]const u8, template_dir_set: bool, initial_branch: ?[]const u8, quiet: bool, shared: ?[]const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // helpers.Create the target directory if it doesn't exist (recursively)
    helpers.createDirectoryRecursive(path, platform_impl, allocator) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };
    
    const git_dir = if (bare) 
        try allocator.dupe(u8, path)
    else 
        try std.fmt.allocPrint(allocator, "{s}/.git", .{path});
    defer allocator.free(git_dir);
    
    try initRepositoryInDir(git_dir, bare, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
}


pub fn initRepositoryInDir(git_dir: []const u8, bare: bool, template_dir: ?[]const u8, template_dir_set: bool, initial_branch: ?[]const u8, quiet: bool, shared: ?[]const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // helpers.Create the directory structure
    helpers.createDirectoryRecursive(git_dir, platform_impl, allocator) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };
    
    // helpers.Check if already exists
    const head_check_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_check_path);
    
    if (platform_impl.fs.exists(head_check_path) catch false) {
        const abs_path = std.fs.cwd().realpathAlloc(allocator, git_dir) catch try allocator.dupe(u8, git_dir);
        defer allocator.free(abs_path);
        if (initial_branch != null) {
            const warn_msg = try std.fmt.allocPrint(allocator, "warning: re-init: ignored --initial-branch={s}\n", .{initial_branch.?});
            defer allocator.free(warn_msg);
            try platform_impl.writeStderr(warn_msg);
        }
        if (!quiet) {
            const msg = try std.fmt.allocPrint(allocator, "Reinitialized existing helpers.Git repository in {s}/\n", .{abs_path});
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        }
        return;
    }
    
    // helpers.Determine effective template to decide which dirs to create
    const env_template_dir = std.process.getEnvVarOwned(allocator, "GIT_TEMPLATE_DIR") catch null;
    defer if (env_template_dir) |et| allocator.free(et);
    const use_templates = if (template_dir_set)
        (template_dir != null and template_dir.?.len > 0)
    else if (env_template_dir) |et|
        et.len > 0
    else
        true; // default: use templates

    // helpers.Create core subdirectories (always created)
    const core_subdirs = [_][]const u8{
        "objects", "objects/info", "objects/pack", "refs", "refs/heads", "refs/tags",
    };
    for (core_subdirs) |subdir| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, subdir });
        defer allocator.free(full_path);
        std.fs.cwd().makePath(full_path) catch {};
    }
    // helpers.Create template-dependent subdirectories only when templates are in use
    if (use_templates) {
        const template_subdirs = [_][]const u8{ "hooks", "info" };
        for (template_subdirs) |subdir| {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, subdir });
            defer allocator.free(full_path);
            std.fs.cwd().makePath(full_path) catch {};
        }
    }
    
    // helpers.Create helpers.HEAD
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    const default_branch = if (initial_branch) |ib|
        try allocator.dupe(u8, ib)
    else blk: {
        // helpers.Check GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME (non-empty means use it)
        if (std.process.getEnvVarOwned(allocator, "GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME") catch null) |env_val| {
            if (env_val.len > 0) break :blk env_val;
            allocator.free(env_val);
        }
        // helpers.Check init.defaultBranch from global config
        const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch null;
        defer if (home_dir) |h| allocator.free(h);
        if (home_dir) |home| {
            const global_config_path2 = try std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{home});
            defer allocator.free(global_config_path2);
            if (platform_impl.fs.readFile(allocator, global_config_path2)) |gcfg| {
                defer allocator.free(gcfg);
                if (helpers.parseConfigValue(gcfg, "init.defaultbranch", allocator) catch null) |db_val| {
                    if (db_val.len > 0) break :blk db_val;
                    allocator.free(db_val);
                }
            } else |_| {}
            // helpers.Also check XDG config
            const xdg_config = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null;
            defer if (xdg_config) |x| allocator.free(x);
            const xdg_base = xdg_config orelse home;
            const xdg_git_config = if (xdg_config != null)
                try std.fmt.allocPrint(allocator, "{s}/git/config", .{xdg_base})
            else
                try std.fmt.allocPrint(allocator, "{s}/.config/git/config", .{xdg_base});
            defer allocator.free(xdg_git_config);
            if (platform_impl.fs.readFile(allocator, xdg_git_config)) |xcfg| {
                defer allocator.free(xcfg);
                if (helpers.parseConfigValue(xcfg, "init.defaultbranch", allocator) catch null) |db_val2| {
                    if (db_val2.len > 0) break :blk db_val2;
                    allocator.free(db_val2);
                }
            } else |_| {}
        }
        break :blk try allocator.dupe(u8, "master");
    };
    defer allocator.free(default_branch);

    // helpers.Validate branch name
    if (!helpers.isValidBranchName(default_branch)) {
        const msg = try std.fmt.allocPrint(allocator, "fatal: invalid branch name: '{s}'\n", .{default_branch});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    }

    const head_content = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{default_branch});
    defer allocator.free(head_content);
    try platform_impl.fs.writeFile(head_path, head_content);
    
    // helpers.Create config
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
    defer allocator.free(config_path);
    
    // helpers.Determine object format and ref format from environment
    const env_obj_fmt = std.process.getEnvVarOwned(allocator, "GIT_DEFAULT_HASH") catch null;
    defer if (env_obj_fmt) |v| allocator.free(v);
    const env_ref_fmt = std.process.getEnvVarOwned(allocator, "GIT_DEFAULT_REF_FORMAT") catch null;
    defer if (env_ref_fmt) |v| allocator.free(v);
    // helpers.Also check _ZIGGIT_INIT_OBJECT_FORMAT and _ZIGGIT_INIT_REF_FORMAT for explicit --object-format/--ref-format
    const explicit_obj_fmt = std.process.getEnvVarOwned(allocator, "_ZIGGIT_INIT_OBJECT_FORMAT") catch null;
    defer if (explicit_obj_fmt) |v| allocator.free(v);
    const explicit_ref_fmt = std.process.getEnvVarOwned(allocator, "_ZIGGIT_INIT_REF_FORMAT") catch null;
    defer if (explicit_ref_fmt) |v| allocator.free(v);
    
    const effective_obj_fmt = explicit_obj_fmt orelse env_obj_fmt;
    const effective_ref_fmt = explicit_ref_fmt orelse env_ref_fmt;
    
    const use_sha256 = if (effective_obj_fmt) |of| std.ascii.eqlIgnoreCase(of, "sha256") else false;
    const use_reftable = if (effective_ref_fmt) |rf| std.ascii.eqlIgnoreCase(rf, "reftable") else false;
    const needs_extensions = use_sha256 or use_reftable;
    
    var config_buf = std.ArrayList(u8).init(allocator);
    defer config_buf.deinit();
    try config_buf.appendSlice("[core]\n");
    if (needs_extensions) {
        try config_buf.appendSlice("\trepositoryformatversion = 1\n");
    } else {
        try config_buf.appendSlice("\trepositoryformatversion = 0\n");
    }
    try config_buf.appendSlice("\tfilemode = true\n");
    if (bare) {
        try config_buf.appendSlice("\tbare = true\n");
    } else {
        try config_buf.appendSlice("\tbare = false\n");
    }
    try config_buf.appendSlice("\tlogallrefupdates = true\n");
    if (shared) |s| {
        const shared_line = try std.fmt.allocPrint(allocator, "\tsharedRepository = {s}\n", .{s});
        defer allocator.free(shared_line);
        try config_buf.appendSlice(shared_line);
    }
    if (needs_extensions) {
        try config_buf.appendSlice("[extensions]\n");
        if (use_sha256) {
            try config_buf.appendSlice("\tobjectformat = sha256\n");
        }
        if (use_reftable) {
            try config_buf.appendSlice("\trefstorage = reftable\n");
        }
    }
    try platform_impl.fs.writeFile(config_path, config_buf.items);
    
    // helpers.Create description (only when templates are in use, or as default)
    if (use_templates) {
        const desc_path = try std.fmt.allocPrint(allocator, "{s}/description", .{git_dir});
        defer allocator.free(desc_path);
        try platform_impl.fs.writeFile(desc_path, "Unnamed repository; edit this file 'description' to name the repository.\n");
    }
    
    // helpers.Copy template directory contents (unless --template= was set to empty)
    if (!template_dir_set or (template_dir != null and template_dir.?.len > 0)) {
        var effective_template: ?[]const u8 = null;
        var template_needs_free = false;
        
        if (template_dir) |td| {
            effective_template = td;
        } else {
            // helpers.Check GIT_TEMPLATE_DIR env
            effective_template = std.process.getEnvVarOwned(allocator, "GIT_TEMPLATE_DIR") catch null;
            if (effective_template != null) {
                template_needs_free = true;
            } else {
                // helpers.Check init.templatedir from global config
                const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch null;
                defer if (home_dir) |h| allocator.free(h);
                if (home_dir) |home| {
                    const global_config_path = try std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{home});
                    defer allocator.free(global_config_path);
                    if (platform_impl.fs.readFile(allocator, global_config_path)) |gcfg| {
                        defer allocator.free(gcfg);
                        if (helpers.parseConfigValue(gcfg, "init.templatedir", allocator) catch null) |tmpl_val| {
                            // helpers.Handle ~ expansion
                            if (tmpl_val.len > 0 and tmpl_val[0] == '~') {
                                const expanded = try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, tmpl_val[1..] });
                                allocator.free(tmpl_val);
                                effective_template = expanded;
                            } else {
                                effective_template = tmpl_val;
                            }
                            template_needs_free = true;
                        }
                    } else |_| {}
                }
            }
        }
        defer if (template_needs_free) if (effective_template) |et| allocator.free(et);
        
        if (effective_template) |tmpl_dir| {
            if (tmpl_dir.len > 0) {
                copyTemplateDir(git_dir, tmpl_dir, allocator) catch {};
            }
        }
    }
    
    // helpers.Create info/exclude if not provided by template (only when templates are in use)
    if (use_templates) {
        const exclude_path = try std.fmt.allocPrint(allocator, "{s}/info/exclude", .{git_dir});
        defer allocator.free(exclude_path);
        if (!(std.fs.cwd().access(exclude_path, .{}) catch null != null)) {
            platform_impl.fs.writeFile(exclude_path, "# git ls-files --others --exclude-from=.git/info/exclude\n# Lines that start with '#' are comments.\n") catch {};
        }
    }
    
    // Print success
    const abs_path = std.fs.cwd().realpathAlloc(allocator, git_dir) catch try allocator.dupe(u8, git_dir);
    defer allocator.free(abs_path);
    if (!quiet) {
        const msg = try std.fmt.allocPrint(allocator, "Initialized empty helpers.Git repository in {s}/\n", .{abs_path});
        defer allocator.free(msg);
        try platform_impl.writeStdout(msg);
    }
}


pub fn initRepositoryWithGitDir(work_dir: []const u8, git_dir_path: []const u8, bare: bool, template_dir: ?[]const u8, template_dir_set: bool, initial_branch: ?[]const u8, quiet: bool, shared: ?[]const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // helpers.Check if GIT_WORK_TREE is also set  
    const env_work_tree = std.process.getEnvVarOwned(allocator, "GIT_WORK_TREE") catch null;
    defer if (env_work_tree) |w| allocator.free(w);
    
    // helpers.When both helpers.GIT_DIR and GIT_WORK_TREE are set, create non-bare repo with worktree
    if (env_work_tree) |wt| {
        _ = work_dir;
        try initRepositoryInDir(git_dir_path, false, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
        // Set core.worktree in config
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir_path});
        defer allocator.free(config_path);
        if (platform_impl.fs.readFile(allocator, config_path)) |existing| {
            defer allocator.free(existing);
            // helpers.Insert worktree before the closing of [core] section
            const abs_wt = std.fs.cwd().realpathAlloc(allocator, wt) catch try allocator.dupe(u8, wt);
            defer allocator.free(abs_wt);
            const new_config = try std.fmt.allocPrint(allocator, "{s}\tworktree = {s}\n", .{ existing, abs_wt });
            defer allocator.free(new_config);
            try platform_impl.fs.writeFile(config_path, new_config);
        } else |_| {}
    } else {
        _ = work_dir;
        // helpers.When helpers.GIT_DIR is set without GIT_WORK_TREE, detect bare
        const ib = !std.mem.eql(u8, git_dir_path, ".git") and !std.mem.endsWith(u8, git_dir_path, "/.git"); try initRepositoryInDir(git_dir_path, bare or ib, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
    }
}


pub fn initRepositoryWithSeparateGitDir(work_dir: []const u8, git_dir_path: []const u8, template_dir: ?[]const u8, template_dir_set: bool, initial_branch: ?[]const u8, quiet: bool, shared: ?[]const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    // helpers.Create the git directory
    try initRepositoryInDir(git_dir_path, false, template_dir, template_dir_set, initial_branch, quiet, shared, allocator, platform_impl);
    
    // helpers.Create the work tree directory
    helpers.createDirectoryRecursive(work_dir, platform_impl, allocator) catch |err| switch (err) {
        error.AlreadyExists => {},
        else => return err,
    };
    
    // helpers.Write .git file in work_dir pointing to the separate git dir
    const abs_git_dir = std.fs.cwd().realpathAlloc(allocator, git_dir_path) catch try allocator.dupe(u8, git_dir_path);
    defer allocator.free(abs_git_dir);
    
    const git_file_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{work_dir});
    defer allocator.free(git_file_path);
    const git_file_content = try std.fmt.allocPrint(allocator, "gitdir: {s}\n", .{abs_git_dir});
    defer allocator.free(git_file_content);
    try platform_impl.fs.writeFile(git_file_path, git_file_content);
    
    // Set core.worktree in the git dir config
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir_path});
    defer allocator.free(config_path);
    const abs_work = std.fs.cwd().realpathAlloc(allocator, work_dir) catch try allocator.dupe(u8, work_dir);
    defer allocator.free(abs_work);
    
    // helpers.Read existing config and add worktree
    if (platform_impl.fs.readFile(allocator, config_path)) |existing| {
        defer allocator.free(existing);
        // helpers.Add worktree to core section
        const new_config = try std.fmt.allocPrint(allocator, "{s}\tworktree = {s}\n", .{ existing, abs_work });
        defer allocator.free(new_config);
        try platform_impl.fs.writeFile(config_path, new_config);
    } else |_| {}
}


pub fn copyTemplateDir(git_dir: []const u8, template_path: []const u8, allocator: std.mem.Allocator) !void {
    // helpers.Recursively copy template directory contents to git_dir
    var dir = std.fs.cwd().openDir(template_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, entry.path });
        defer allocator.free(dest_path);

        switch (entry.kind) {
            .directory => {
                std.fs.cwd().makePath(dest_path) catch {};
            },
            .file => {
                // helpers.Only copy if destination doesn't exist
                if (std.fs.cwd().access(dest_path, .{})) |_| {
                    continue; // Don't overwrite existing files
                } else |_| {}

                const src_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ template_path, entry.path });
                defer allocator.free(src_path);
                std.fs.cwd().copyFile(src_path, std.fs.cwd(), dest_path, .{}) catch {};
            },
            else => {},
        }
    }
}
