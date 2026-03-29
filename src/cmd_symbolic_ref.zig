// Auto-generated from main_common.zig - cmd_symbolic_ref
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

pub fn cmdSymbolicRef(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var quiet = false;
    var short = false;
    var delete = false;
    var positional = std.ArrayList([]const u8).init(allocator);
    defer positional.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--short")) {
            short = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delete")) {
            delete = true;
        } else if (std.mem.eql(u8, arg, "-m")) {
            // helpers.Skip the message argument (reflog message, we ignore for now)
            _ = args.next();
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try positional.append(arg);
        }
    }

    if (positional.items.len == 0) {
        try platform_impl.writeStderr("usage: git symbolic-ref [-m <reason>] <name> <ref>\n       git symbolic-ref [-q] [--short] <name>\n       git symbolic-ref --delete [-q] <name>\n");
        std.process.exit(1);
    }

    const git_dir = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    const ref_name = positional.items[0];

    if (delete) {
        // helpers.Delete the symbolic ref
        if (std.mem.eql(u8, ref_name, "HEAD")) {
            const msg = try std.fmt.allocPrint(allocator, "fatal: Cannot delete HEAD\n", .{});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
            unreachable;
        }
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name });
        defer allocator.free(ref_path);
        // helpers.Check if it exists and is a symbolic ref
        const content = platform_impl.fs.readFile(allocator, ref_path) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: Cannot delete {s}, not a symbolic ref\n", .{ref_name});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
            unreachable;
        };
        defer allocator.free(content);
        if (!std.mem.startsWith(u8, content, "ref: ")) {
            const msg = try std.fmt.allocPrint(allocator, "fatal: Cannot delete {s}, not a symbolic ref\n", .{ref_name});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
            unreachable;
        }
        std.fs.cwd().deleteFile(ref_path) catch {
            if (!quiet) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: Cannot delete {s}\n", .{ref_name});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            }
            std.process.exit(1);
            unreachable;
        };
        return;
    }

    if (positional.items.len >= 2) {
        // helpers.Write mode: symbolic-ref <name> <ref>
        const target = positional.items[1];
        
        // helpers.Validate target
        if (std.mem.eql(u8, ref_name, "HEAD")) {
            if (!std.mem.startsWith(u8, target, "refs/")) {
                try platform_impl.writeStderr("fatal: Refusing to point helpers.HEAD outside of refs/\n");
                std.process.exit(1);
                unreachable;
            }
        } else {
            // helpers.For non-helpers.HEAD, validate that target is a valid ref name
            if (false) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: Refusing to set '{s}' to invalid ref '{s}'\n", .{ ref_name, target });
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
                unreachable;
            }
        }
        
        const ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name }) catch {
            std.process.exit(128);
            unreachable;
        };
        defer allocator.free(ref_path);

        const content = std.fmt.allocPrint(allocator, "ref: {s}\n", .{target}) catch {
            std.process.exit(128);
            unreachable;
        };
        defer allocator.free(content);

        // Ensure parent directories exist
        if (std.fs.path.dirname(ref_path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        const file = std.fs.cwd().createFile(ref_path, .{}) catch {
            const msg = std.fmt.allocPrint(allocator, "fatal: Cannot create {s}\n", .{ref_path}) catch "fatal: Cannot create ref\n";
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
            unreachable;
        };
        defer file.close();
        file.writeAll(content) catch {
            std.process.exit(128);
            unreachable;
        };
        return;
    }

    // helpers.Read mode: symbolic-ref <name>
    const ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name }) catch {
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(ref_path);

    const content = std.fs.cwd().readFileAlloc(allocator, ref_path, 4096) catch {
        if (!quiet) {
            const msg = std.fmt.allocPrint(allocator, "fatal: ref {s} is not a symbolic ref\n", .{ref_name}) catch "fatal: not a symbolic ref\n";
            try platform_impl.writeStderr(msg);
        }
        std.process.exit(1);
        unreachable;
    };
    defer allocator.free(content);

    const trimmed = std.mem.trimRight(u8, content, "\n\r ");
    if (!std.mem.startsWith(u8, trimmed, "ref: ")) {
        if (!quiet) {
            const msg = std.fmt.allocPrint(allocator, "fatal: ref {s} is not a symbolic ref\n", .{ref_name}) catch "fatal: not a symbolic ref\n";
            try platform_impl.writeStderr(msg);
        }
        std.process.exit(1);
        unreachable;
    }

    const target = trimmed["ref: ".len..];
    var output: []const u8 = undefined;
    if (short) {
        // helpers.Strip refs/heads/ or refs/tags/ or refs/remotes/ prefix
        if (std.mem.startsWith(u8, target, "refs/heads/")) {
            output = target["refs/heads/".len..];
        } else if (std.mem.startsWith(u8, target, "refs/tags/")) {
            output = target["refs/tags/".len..];
        } else if (std.mem.startsWith(u8, target, "refs/remotes/")) {
            const rest = target["refs/remotes/".len..];
            // helpers.For refs/remotes/X/helpers.HEAD, shorten to X
            if (std.mem.endsWith(u8, rest, "/HEAD")) {
                output = rest[0 .. rest.len - "/HEAD".len];
            } else {
                output = rest;
            }
        } else if (std.mem.startsWith(u8, target, "refs/")) {
            output = target["refs/".len..];
        } else {
            output = target;
        }
    } else {
        output = target;
    }

    const out_line = std.fmt.allocPrint(allocator, "{s}\n", .{output}) catch {
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(out_line);
    try platform_impl.writeStdout(out_line);
}
