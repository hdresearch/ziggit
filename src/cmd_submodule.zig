// Submodule command implementation
const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const objects = helpers.objects;
const index_mod = helpers.index_mod;
const refs = helpers.refs;


const submodule_usage = "usage: git submodule [--quiet] [--cached]\n   or: git submodule [--quiet] add [-b <branch>] [-f|--force] [--name <name>] [--reference <repository>] [--] <repository> [<path>]\n   or: git submodule [--quiet] status [--cached] [--recursive] [<path>...]\n   or: git submodule [--quiet] init [--] [<path>...]\n   or: git submodule [--quiet] deinit [-f|--force] (--all| [--] <path>...)\n   or: git submodule [--quiet] update [--init [--filter=<filter-spec>]] [--remote] [-N|--no-fetch] [-f|--force] [--checkout|--merge|--rebase] [--[no-]recommend-shallow] [--reference <repository>] [--recursive] [--[no-]single-branch] [--] [<path>...]\n   or: git submodule [--quiet] set-branch (--default|--branch <branch>) [--] <path>\n   or: git submodule [--quiet] set-url [--] <path> <newurl>\n   or: git submodule [--quiet] summary [--cached|--files] [--summary-limit <n>] [commit] [--] [<path>...]\n   or: git submodule [--quiet] foreach [--recursive] <command>\n   or: git submodule [--quiet] sync [--recursive] [--] [<path>...]\n   or: git submodule [--quiet] absorbgitdirs [--] [<path>...]\n";

pub fn cmdSubmodule(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var quiet = false;
    var subcmd: ?[]const u8 = null;
    var sub_args = std.ArrayList([]const u8).init(allocator);
    defer sub_args.deinit();

    while (args.next()) |arg| {
        if (subcmd == null) {
            if (std.mem.eql(u8, arg, "-h")) {
                try platform_impl.writeStdout(submodule_usage);
                std.process.exit(129);
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
                quiet = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                subcmd = arg;
            }
        } else {
            try sub_args.append(arg);
        }
    }

    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    const effective_subcmd = subcmd orelse "status";

    if (std.mem.eql(u8, effective_subcmd, "status")) {
        try submoduleStatus(allocator, git_path, sub_args.items, quiet, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "init")) {
        try submoduleInit(allocator, git_path, sub_args.items, quiet, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "update")) {
        try submoduleUpdate(allocator, git_path, sub_args.items, quiet, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "add")) {
        try submoduleAdd(allocator, git_path, sub_args.items, quiet, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "foreach")) {
        try submoduleForeach(allocator, git_path, sub_args.items, quiet, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "sync")) {
        try submoduleSync(allocator, git_path, sub_args.items, quiet, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "deinit")) {
        try submoduleDeinit(allocator, git_path, sub_args.items, quiet, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "summary")) {
        // summary - not yet implemented
    } else if (std.mem.eql(u8, effective_subcmd, "absorbgitdirs")) {
        // absorbgitdirs - not yet implemented
    } else if (std.mem.eql(u8, effective_subcmd, "set-branch") or std.mem.eql(u8, effective_subcmd, "set-url")) {
        // set-branch/set-url - not yet implemented
    } else {
        const msg = try std.fmt.allocPrint(allocator, "error: unknown subcommand: {s}\n", .{effective_subcmd});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        try platform_impl.writeStderr(submodule_usage);
        std.process.exit(1);
    }
}

fn getConfigValueSimple(allocator: std.mem.Allocator, content: []const u8, key: []const u8) ![]u8 {
    // Simple config value lookup: key = "section.subsection.name"
    // Look for the value in INI-style config
    const dot1 = std.mem.indexOf(u8, key, ".") orelse return error.NotFound;
    const rest = key[dot1 + 1 ..];
    const dot2 = std.mem.indexOf(u8, rest, ".");
    const name = if (dot2) |d| rest[d + 1 ..] else rest;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, name)) {
            const after_name = trimmed[name.len..];
            const stripped = std.mem.trimLeft(u8, after_name, " \t");
            if (stripped.len > 0 and stripped[0] == '=') {
                const value = std.mem.trim(u8, stripped[1..], " \t");
                return try allocator.dupe(u8, value);
            }
        }
    }
    return error.NotFound;
}

fn getRepoRoot(allocator: std.mem.Allocator, git_path: []const u8) ![]u8 {
    if (std.fs.path.dirname(git_path)) |parent| {
        return try allocator.dupe(u8, parent);
    }
    return try allocator.dupe(u8, ".");
}

/// Read .gitmodules and return a list of submodule entries
const SubmoduleEntry = struct {
    name: []u8,
    path: []u8,
    url: ?[]u8,
};

fn readGitmodules(allocator: std.mem.Allocator, repo_root: []const u8) !std.ArrayList(SubmoduleEntry) {
    var entries = std.ArrayList(SubmoduleEntry).init(allocator);
    const gm_path = try std.fmt.allocPrint(allocator, "{s}/.gitmodules", .{repo_root});
    defer allocator.free(gm_path);
    const content = std.fs.cwd().readFileAlloc(allocator, gm_path, 10 * 1024 * 1024) catch return entries;
    defer allocator.free(content);

    var current_name: ?[]u8 = null;
    var current_path: ?[]u8 = null;
    var current_url: ?[]u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "[submodule \"")) {
            // Save previous entry
            if (current_name != null and current_path != null) {
                try entries.append(.{
                    .name = current_name.?,
                    .path = current_path.?,
                    .url = current_url,
                });
                current_name = null;
                current_path = null;
                current_url = null;
            } else {
                if (current_name) |n| allocator.free(n);
                if (current_path) |p| allocator.free(p);
                if (current_url) |u| allocator.free(u);
            }
            const end = std.mem.indexOf(u8, trimmed, "\"]") orelse continue;
            current_name = try allocator.dupe(u8, trimmed["[submodule \"".len..end]);
            current_path = null;
            current_url = null;
        } else if (std.mem.startsWith(u8, trimmed, "path = ")) {
            if (current_path) |p| allocator.free(p);
            current_path = try allocator.dupe(u8, trimmed["path = ".len..]);
        } else if (std.mem.startsWith(u8, trimmed, "url = ")) {
            if (current_url) |u| allocator.free(u);
            current_url = try allocator.dupe(u8, trimmed["url = ".len..]);
        }
    }
    // Save last entry
    if (current_name != null and current_path != null) {
        try entries.append(.{
            .name = current_name.?,
            .path = current_path.?,
            .url = current_url,
        });
    } else {
        if (current_name) |n| allocator.free(n);
        if (current_path) |p| allocator.free(p);
        if (current_url) |u| allocator.free(u);
    }

    return entries;
}

fn freeSubmoduleEntries(entries: *std.ArrayList(SubmoduleEntry), allocator: std.mem.Allocator) void {
    for (entries.items) |e| {
        allocator.free(e.name);
        allocator.free(e.path);
        if (e.url) |u| allocator.free(u);
    }
    entries.deinit();
}

// ============= submodule status =============

fn submoduleStatus(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    quiet: bool,
    platform_impl: *const platform_mod.Platform,
) !void {
    _ = quiet;
    _ = sub_args;

    const repo_root = try getRepoRoot(allocator, git_path);
    defer allocator.free(repo_root);

    var entries = try readGitmodules(allocator, repo_root);
    defer freeSubmoduleEntries(&entries, allocator);

    // Load index to get gitlink entries
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
    defer idx.deinit();

    for (entries.items) |entry| {
        // Find the gitlink entry in index
        var found = false;
        for (idx.entries.items) |ie| {
            if (std.mem.eql(u8, ie.path, entry.path)) {
                var hash_hex: [40]u8 = undefined;
                _ = std.fmt.bufPrint(&hash_hex, "{}", .{std.fmt.fmtSliceHexLower(&ie.sha1)}) catch continue;

                // Check if the submodule is initialized (has .git dir/file)
                const sm_git = try std.fmt.allocPrint(allocator, "{s}/{s}/.git", .{ repo_root, entry.path });
                defer allocator.free(sm_git);
                const initialized = if (std.fs.cwd().access(sm_git, .{})) true else |_| false;

                const prefix: u8 = if (!initialized) '-' else ' ';
                const line = try std.fmt.allocPrint(allocator, "{c}{s} {s}\n", .{ prefix, &hash_hex, entry.path });
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
                found = true;
                break;
            }
        }
        if (!found) {
            const line = try std.fmt.allocPrint(allocator, "-{s} {s}\n", .{ "0000000000000000000000000000000000000000", entry.path });
            defer allocator.free(line);
            try platform_impl.writeStdout(line);
        }
    }
}

// ============= submodule init =============

fn submoduleInit(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    quiet: bool,
    platform_impl: *const platform_mod.Platform,
) !void {
    const repo_root = try getRepoRoot(allocator, git_path);
    defer allocator.free(repo_root);

    var entries = try readGitmodules(allocator, repo_root);
    defer freeSubmoduleEntries(&entries, allocator);

    for (entries.items) |entry| {
        // Check path filter
        if (sub_args.len > 0) {
            var matches = false;
            for (sub_args) |arg| {
                if (std.mem.eql(u8, arg, "--") or std.mem.startsWith(u8, arg, "-")) continue;
                if (std.mem.eql(u8, arg, entry.path) or std.mem.eql(u8, arg, entry.name)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
        }

        if (entry.url) |url| {
            // Set submodule.<name>.url in local config
            const config_key = try std.fmt.allocPrint(allocator, "submodule.{s}.url", .{entry.name});
            defer allocator.free(config_key);

            // Check if already set
            const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(config_path);
            // Check if already set by reading config file
            const config_content = std.fs.cwd().readFileAlloc(allocator, config_path, 10 * 1024 * 1024) catch try allocator.dupe(u8, "");
            defer allocator.free(config_content);
            if (std.mem.indexOf(u8, config_content, config_key) != null) {
                continue; // Already initialized
            }

            // Resolve relative URLs
            const resolved_url = url;

            // Append to config file
            const new_section = try std.fmt.allocPrint(allocator, "[submodule \"{s}\"]\n\tactive = true\n\turl = {s}\n", .{ entry.name, resolved_url });
            defer allocator.free(new_section);
            const new_config = try std.fmt.allocPrint(allocator, "{s}{s}", .{ config_content, new_section });
            defer allocator.free(new_config);
            const cf = std.fs.cwd().createFile(config_path, .{}) catch continue;
            defer cf.close();
            cf.writeAll(new_config) catch {};

            if (!quiet) {
                const msg = try std.fmt.allocPrint(allocator, "Submodule '{s}' ({s}) registered for path '{s}'\n", .{ entry.name, resolved_url, entry.path });
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
        } else {
            if (!quiet) {
                const msg = try std.fmt.allocPrint(allocator, "No url found for submodule path '{s}' in .gitmodules\n", .{entry.path});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            }
        }
    }
}

// ============= submodule update =============

fn submoduleUpdate(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    quiet: bool,
    platform_impl: *const platform_mod.Platform,
) !void {
    var do_init = false;
    for (sub_args) |arg| {
        if (std.mem.eql(u8, arg, "--init")) do_init = true;
    }

    if (do_init) {
        try submoduleInit(allocator, git_path, sub_args, quiet, platform_impl);
    }

    const repo_root = try getRepoRoot(allocator, git_path);
    defer allocator.free(repo_root);

    var entries = try readGitmodules(allocator, repo_root);
    defer freeSubmoduleEntries(&entries, allocator);

    // Load index to get expected commit hashes
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
    defer idx.deinit();

    for (entries.items) |entry| {
        // Get the URL from config
        const config_key = try std.fmt.allocPrint(allocator, "submodule.{s}.url", .{entry.name});
        defer allocator.free(config_key);
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);
        // Read URL from config
        const cfg_content = std.fs.cwd().readFileAlloc(allocator, config_path, 10 * 1024 * 1024) catch continue;
        defer allocator.free(cfg_content);
        const url = getConfigValueSimple(allocator, cfg_content, config_key) catch null;
        if (url == null) continue; // Not initialized
        defer allocator.free(url.?);

        // Find the expected commit hash from index
        var expected_hash: ?[40]u8 = null;
        for (idx.entries.items) |ie| {
            if (std.mem.eql(u8, ie.path, entry.path)) {
                var hh: [40]u8 = undefined;
                _ = std.fmt.bufPrint(&hh, "{}", .{std.fmt.fmtSliceHexLower(&ie.sha1)}) catch continue;
                expected_hash = hh;
                break;
            }
        }

        const sm_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
        defer allocator.free(sm_path);

        // Check if already cloned
        const sm_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{sm_path});
        defer allocator.free(sm_git);
        const already_cloned = if (std.fs.cwd().access(sm_git, .{})) true else |_| false;

        if (!already_cloned) {
            // Clone the submodule
            if (!quiet) {
                const msg = try std.fmt.allocPrint(allocator, "Cloning into '{s}'...\n", .{entry.path});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            }

            // Use git clone
            const result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "git", "clone", "--no-checkout", url.?, sm_path },
            }) catch continue;
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        // Checkout the expected commit
        if (expected_hash) |eh| {
            if (!quiet) {
                const msg = try std.fmt.allocPrint(allocator, "Submodule path '{s}': checked out '{s}'\n", .{ entry.path, &eh });
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
            // Run git checkout in the submodule
            const result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "git", "-C", sm_path, "checkout", &eh },
            }) catch continue;
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
    }
}

// ============= submodule add =============

fn submoduleAdd(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    quiet: bool,
    platform_impl: *const platform_mod.Platform,
) !void {
    _ = quiet;
    var url: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var name: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i < sub_args.len) name = sub_args[i];
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--branch")) {
            i += 1; // skip branch value
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            // force
        } else if (std.mem.eql(u8, arg, "--")) {
            // skip
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (url == null) {
                url = arg;
            } else if (path == null) {
                path = arg;
            }
        }
    }

    const repo_url = url orelse {
        try platform_impl.writeStderr("usage: git submodule add <url> [<path>]\n");
        std.process.exit(1);
    };

    const repo_root = try getRepoRoot(allocator, git_path);
    defer allocator.free(repo_root);

    // Default path from URL
    const sm_path = path orelse blk: {
        const basename = std.fs.path.basename(repo_url);
        if (std.mem.endsWith(u8, basename, ".git")) {
            break :blk basename[0 .. basename.len - 4];
        }
        break :blk basename;
    };

    const sm_name = name orelse sm_path;

    // Check if path already exists as a file
    const full_sm_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, sm_path });
    defer allocator.free(full_sm_path);

    if (std.fs.cwd().access(full_sm_path, .{})) {
        // Check if it's a directory with .git (already a repo)
        const sm_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{full_sm_path});
        defer allocator.free(sm_git);
        if (std.fs.cwd().access(sm_git, .{})) {
            // Already exists as repo - just register
        } else |_| {
            const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' already exists in the index\n", .{sm_path});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        }
    } else |_| {
        // Clone the repository
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "clone", repo_url, full_sm_path },
        }) catch {
            try platform_impl.writeStderr("fatal: clone failed\n");
            std.process.exit(128);
        };
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    // Add to .gitmodules
    const gm_path = try std.fmt.allocPrint(allocator, "{s}/.gitmodules", .{repo_root});
    defer allocator.free(gm_path);

    // Read existing content
    const existing = std.fs.cwd().readFileAlloc(allocator, gm_path, 10 * 1024 * 1024) catch try allocator.dupe(u8, "");
    defer allocator.free(existing);

    // Append new entry
    const new_entry = try std.fmt.allocPrint(allocator, "{s}[submodule \"{s}\"]\n\tpath = {s}\n\turl = {s}\n", .{ existing, sm_name, sm_path, repo_url });
    defer allocator.free(new_entry);

    const file = try std.fs.cwd().createFile(gm_path, .{});
    defer file.close();
    try file.writeAll(new_entry);

    // Stage .gitmodules and the submodule path
    // The submodule path is added as a gitlink (mode 160000)
    // For now, just add .gitmodules
    try platform_impl.writeStdout(""); // git add for .gitmodules would happen here
}

// ============= submodule foreach =============

fn submoduleForeach(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    quiet: bool,
    platform_impl: *const platform_mod.Platform,
) !void {
    _ = quiet;
    const repo_root = try getRepoRoot(allocator, git_path);
    defer allocator.free(repo_root);

    var entries = try readGitmodules(allocator, repo_root);
    defer freeSubmoduleEntries(&entries, allocator);

    // Combine sub_args into command
    var cmd_parts = std.ArrayList(u8).init(allocator);
    defer cmd_parts.deinit();
    for (sub_args, 0..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--recursive")) {
            continue;
        }
        if (idx > 0 and cmd_parts.items.len > 0) try cmd_parts.append(' ');
        try cmd_parts.appendSlice(arg);
    }

    for (entries.items) |entry| {
        const sm_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
        defer allocator.free(sm_path);

        // Check if submodule is initialized
        const sm_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{sm_path});
        defer allocator.free(sm_git);
        if (std.fs.cwd().access(sm_git, .{})) {} else |_| continue;

        const entering_msg = try std.fmt.allocPrint(allocator, "Entering '{s}'\n", .{entry.path});
        defer allocator.free(entering_msg);
        try platform_impl.writeStdout(entering_msg);

        // Run command in submodule directory
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "sh", "-c", cmd_parts.items },
            .cwd = sm_path,
        }) catch continue;
        if (result.stdout.len > 0) try platform_impl.writeStdout(result.stdout);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
}

// ============= submodule sync =============

fn submoduleSync(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    quiet: bool,
    platform_impl: *const platform_mod.Platform,
) !void {
    _ = sub_args;
    const repo_root = try getRepoRoot(allocator, git_path);
    defer allocator.free(repo_root);

    var entries = try readGitmodules(allocator, repo_root);
    defer freeSubmoduleEntries(&entries, allocator);

    for (entries.items) |entry| {
        if (entry.url) |url| {
            // Update config
            const config_key = try std.fmt.allocPrint(allocator, "submodule.{s}.url", .{entry.name});
            defer allocator.free(config_key);
            // Write to config directly
            const cfg_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(cfg_path);
            const cfg_content = std.fs.cwd().readFileAlloc(allocator, cfg_path, 10 * 1024 * 1024) catch try allocator.dupe(u8, "");
            defer allocator.free(cfg_content);
            if (std.mem.indexOf(u8, cfg_content, config_key) == null) {
                const new_section = try std.fmt.allocPrint(allocator, "[submodule \"{s}\"]\n\turl = {s}\n", .{ entry.name, url });
                defer allocator.free(new_section);
                const new_cfg = try std.fmt.allocPrint(allocator, "{s}{s}", .{ cfg_content, new_section });
                defer allocator.free(new_cfg);
                const cf = std.fs.cwd().createFile(cfg_path, .{}) catch continue;
                defer cf.close();
                cf.writeAll(new_cfg) catch {};
            }

            if (!quiet) {
                const msg = try std.fmt.allocPrint(allocator, "Synchronizing submodule url for '{s}'\n", .{entry.name});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
        }
    }
}

// ============= submodule deinit =============

fn submoduleDeinit(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    quiet: bool,
    platform_impl: *const platform_mod.Platform,
) !void {
    _ = quiet;
    const repo_root = try getRepoRoot(allocator, git_path);
    defer allocator.free(repo_root);

    var deinit_all = false;
    var paths = std.ArrayList([]const u8).init(allocator);
    defer paths.deinit();

    for (sub_args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            deinit_all = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            // force
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try paths.append(arg);
        }
    }


    if (!deinit_all and paths.items.len == 0) {
        try platform_impl.writeStderr("fatal: Use '--all' if you want to deinit all submodules\n");
        std.process.exit(1);
    }

    var entries = try readGitmodules(allocator, repo_root);
    defer freeSubmoduleEntries(&entries, allocator);

    for (entries.items) |entry| {
        if (!deinit_all) {
            var matches = false;
            for (paths.items) |p| {
                if (std.mem.eql(u8, p, entry.path) or std.mem.eql(u8, p, entry.name)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
        }

        // Remove the submodule's working directory contents
        const sm_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
        defer allocator.free(sm_path);
        std.fs.cwd().deleteTree(sm_path) catch {};
        std.fs.cwd().makePath(sm_path) catch {};

        // Remove from config
        const config_key = try std.fmt.allocPrint(allocator, "submodule.{s}.url", .{entry.name});
        defer allocator.free(config_key);
        // TODO: actually remove config section
    }
}
