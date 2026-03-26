const std = @import("std");
const builtin = @import("builtin");

// Import git modules directly (avoiding main_common.zig which uses std.process.changeCurDir)
const Repository = @import("git/repository.zig").Repository;
const objects = @import("git/objects.zig");
const platform_mod = @import("platform/platform.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const platform_impl = platform_mod.getCurrentPlatform();

    var args_iter = try platform_impl.getArgs(allocator);
    defer args_iter.deinit();

    const args = args_iter.args;

    // Skip program name
    if (args.len < 2) {
        try platform_impl.writeStdout("ziggit: a modern version control system written in Zig (WASI)\n");
        try platform_impl.writeStdout("usage: ziggit <command> [<args>]\n\n");
        try platform_impl.writeStdout("Commands: init, status, log, add, commit, rev-parse, cat-file\n");
        try platform_impl.writeStdout("         clone, branch, checkout, tag, diff, show, config\n");
        try platform_impl.writeStdout("\nNote: Running in WASI mode. Some features may be limited.\n");
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try platform_impl.writeStdout("ziggit version 0.1.0 (WASI)\n");
        return;
    }

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        try platform_impl.writeStdout("ziggit: a modern version control system written in Zig (WASI)\n");
        try platform_impl.writeStdout("usage: ziggit <command> [<args>]\n\n");
        try platform_impl.writeStdout("Available commands:\n");
        try platform_impl.writeStdout("  init       Create an empty repository\n");
        try platform_impl.writeStdout("  status     Show the working tree status\n");
        try platform_impl.writeStdout("  log        Show commit logs\n");
        try platform_impl.writeStdout("  add        Add file contents to the index\n");
        try platform_impl.writeStdout("  commit     Record changes to the repository\n");
        try platform_impl.writeStdout("  rev-parse  Pick out and massage parameters\n");
        try platform_impl.writeStdout("  cat-file   Show object content or type\n");
        try platform_impl.writeStdout("  branch     List, create, or delete branches\n");
        try platform_impl.writeStdout("  checkout   Switch branches or restore files\n");
        try platform_impl.writeStdout("  clone      Clone a repository\n");
        try platform_impl.writeStdout("  config     Get and set repository or global options\n");
        try platform_impl.writeStdout("  diff       Show changes between commits\n");
        try platform_impl.writeStdout("  show       Show various types of objects\n");
        try platform_impl.writeStdout("  tag        Create, list, delete or verify a tag\n");
        return;
    }

    if (std.mem.eql(u8, command, "init")) {
        try cmdInit(allocator, args[2..], platform_impl);
    } else if (std.mem.eql(u8, command, "rev-parse")) {
        try cmdRevParse(allocator, args[2..], platform_impl);
    } else if (std.mem.eql(u8, command, "cat-file")) {
        try cmdCatFile(allocator, args[2..], platform_impl);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "ziggit: '{s}' is not yet fully implemented in WASI mode\n", .{command});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
    }
}

fn cmdInit(allocator: std.mem.Allocator, args: []const []const u8, platform_impl: platform_mod.Platform) !void {
    const path = if (args.len > 0) args[0] else ".";
    var repo = Repository.init(allocator, path, platform_impl);
    repo.initRepository() catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "error: failed to initialize repository: {}\n", .{err});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        return;
    };
    const msg = try std.fmt.allocPrint(allocator, "Initialized empty Git repository in {s}/.git/\n", .{path});
    defer allocator.free(msg);
    try platform_impl.writeStdout(msg);
}

fn cmdRevParse(allocator: std.mem.Allocator, args: []const []const u8, platform_impl: platform_mod.Platform) !void {
    if (args.len == 0) {
        try platform_impl.writeStderr("error: rev-parse requires arguments\n");
        return;
    }
    var repo = Repository.init(allocator, ".", platform_impl);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "HEAD")) {
            const head = repo.getHeadCommit() catch {
                try platform_impl.writeStderr("fatal: HEAD not found\n");
                return;
            };
            if (head) |h| {
                defer allocator.free(h);
                try platform_impl.writeStdout(h);
                try platform_impl.writeStdout("\n");
            } else {
                try platform_impl.writeStderr("fatal: HEAD not found\n");
            }
        } else if (std.mem.eql(u8, arg, "--git-dir")) {
            try platform_impl.writeStdout(".git\n");
        } else if (std.mem.eql(u8, arg, "--is-inside-work-tree")) {
            const exists = repo.exists() catch false;
            if (exists) {
                try platform_impl.writeStdout("true\n");
            } else {
                try platform_impl.writeStdout("false\n");
            }
        }
    }
}

fn cmdCatFile(allocator: std.mem.Allocator, args: []const []const u8, platform_impl: platform_mod.Platform) !void {
    if (args.len < 2) {
        try platform_impl.writeStderr("usage: ziggit cat-file <type> <object>\n");
        return;
    }

    const flag = args[0];
    const object_id = args[1];

    if (std.mem.eql(u8, flag, "-t") or std.mem.eql(u8, flag, "-p") or std.mem.eql(u8, flag, "-s")) {
        if (object_id.len != 40) {
            try platform_impl.writeStderr("fatal: invalid object name\n");
            return;
        }

        var hash: [20]u8 = undefined;
        _ = std.fmt.hexToBytes(&hash, object_id) catch {
            try platform_impl.writeStderr("fatal: invalid object name\n");
            return;
        };

        const hex = std.fmt.bytesToHex(hash, .lower);
        const obj = objects.GitObject.load(&hex, ".git", platform_impl, allocator) catch {
            try platform_impl.writeStderr("fatal: object not found\n");
            return;
        };
        defer obj.deinit(allocator);

        if (std.mem.eql(u8, flag, "-t")) {
            try platform_impl.writeStdout(@tagName(obj.type));
            try platform_impl.writeStdout("\n");
        } else if (std.mem.eql(u8, flag, "-s")) {
            const size_str = try std.fmt.allocPrint(allocator, "{d}\n", .{obj.data.len});
            defer allocator.free(size_str);
            try platform_impl.writeStdout(size_str);
        } else {
            try platform_impl.writeStdout(obj.data);
        }
    }
}
