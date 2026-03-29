// Auto-generated from main_common.zig - cmd_notes
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

pub fn cmdNotes(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    const subcmd = args.next() orelse {
        // list notes
        try platform_impl.writeStdout("");
        return;
    };

    if (std.mem.eql(u8, subcmd, "add")) {
        var message: ?[]const u8 = null;
        var target: ?[]const u8 = null;
        var force = false;

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-m")) {
                message = args.next();
            } else if (std.mem.startsWith(u8, arg, "-m") and arg.len > 2) {
                message = arg[2..];
            } else if (std.mem.eql(u8, arg, "-f")) {
                force = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                target = arg;
            }
        }

        const msg = message orelse {
            try platform_impl.writeStderr("error: no message given\n");
            std.process.exit(1);
        };

        // helpers.Resolve target (default to helpers.HEAD)
        const target_hash = if (target) |t|
            helpers.resolveRevision(git_path, t, platform_impl, allocator) catch {
                try platform_impl.writeStderr("fatal: failed to resolve target\n");
                std.process.exit(1);
            }
        else blk: {
            const h = refs.getCurrentCommit(git_path, platform_impl, allocator) catch {
                try platform_impl.writeStderr("fatal: failed to resolve HEAD\n");
                std.process.exit(1);
            };
            break :blk h orelse {
                try platform_impl.writeStderr("fatal: failed to resolve HEAD\n");
                std.process.exit(1);
            };
        };
        defer allocator.free(target_hash);

        // helpers.Create blob object with the note message
        const blob_content = try std.fmt.allocPrint(allocator, "{s}\n", .{msg});
        defer allocator.free(blob_content);
        const blob_obj = objects.GitObject.init(.blob, blob_content);
        const blob_hash = try blob_obj.store(git_path, platform_impl, allocator);
        defer allocator.free(blob_hash);

        // helpers.Read existing notes tree (if any)
        const notes_ref = "refs/notes/commits";
        const existing_commit = refs.getRef(git_path, notes_ref, platform_impl, allocator) catch null;
        defer if (existing_commit) |ec| allocator.free(ec);

        var tree_entries = std.ArrayList(u8).init(allocator);
        defer tree_entries.deinit();

        if (existing_commit) |ec| {
            // helpers.Load existing tree
            const commit_obj = objects.GitObject.load(ec, git_path, platform_impl, allocator) catch null;
            defer if (commit_obj) |co| co.deinit(allocator);
            if (commit_obj) |co| {
                const tree_hash = helpers.extractHeaderField(co.data, "tree");
                if (tree_hash.len > 0) {
                    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch null;
                    defer if (tree_obj) |to| to.deinit(allocator);
                    if (tree_obj) |to| {
                        // helpers.Copy existing entries, skipping the target if force
                        var pos: usize = 0;
                        while (pos < to.data.len) {
                            // tree entry format: mode<space>name<null>hash(20 bytes)
                            const space_pos = std.mem.indexOfPos(u8, to.data, pos, " ") orelse break;
                            const null_pos = std.mem.indexOfPos(u8, to.data, space_pos, &[_]u8{0}) orelse break;
                            const entry_name = to.data[space_pos + 1 .. null_pos];
                            const entry_end = null_pos + 1 + 20;
                            if (entry_end > to.data.len) break;

                            if (!force or !std.mem.eql(u8, entry_name, target_hash)) {
                                try tree_entries.appendSlice(to.data[pos..entry_end]);
                            }
                            pos = entry_end;
                        }
                    }
                }
            }
        }

        // helpers.Add new note entry: "100644 <target_hash>\0<blob_hash_binary>"
        var blob_hash_bin: [20]u8 = undefined;
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            blob_hash_bin[i] = std.fmt.parseInt(u8, blob_hash[i * 2 .. i * 2 + 2], 16) catch 0;
        }
        try tree_entries.appendSlice("100644 ");
        try tree_entries.appendSlice(target_hash);
        try tree_entries.append(0);
        try tree_entries.appendSlice(&blob_hash_bin);

        // helpers.Create tree object
        const tree_obj = objects.GitObject.init(.tree, tree_entries.items);
        const tree_hash = try tree_obj.store(git_path, platform_impl, allocator);
        defer allocator.free(tree_hash);

        // helpers.Create commit object for notes
        const author_str = helpers.getAuthorString(allocator) catch try allocator.dupe(u8, "helpers.Unknown <unknown@unknown>");
        defer allocator.free(author_str);
        const committer_str = helpers.getCommitterString(allocator) catch try allocator.dupe(u8, "helpers.Unknown <unknown@unknown>");
        defer allocator.free(committer_str);

        if (existing_commit) |ec| {
            const parents = [_][]const u8{ec};
            const notes_commit = try objects.createCommitObject(tree_hash, &parents, author_str, committer_str, "helpers.Notes added by 'git notes add'", allocator);
            defer notes_commit.deinit(allocator);
            const notes_hash = try notes_commit.store(git_path, platform_impl, allocator);
            defer allocator.free(notes_hash);
            try refs.updateRef(git_path, "refs/notes/commits", notes_hash, platform_impl, allocator);
        } else {
            const empty_parents: []const []const u8 = &.{};
            const notes_commit = try objects.createCommitObject(tree_hash, empty_parents, author_str, committer_str, "helpers.Notes added by 'git notes add'", allocator);
            defer notes_commit.deinit(allocator);
            const notes_hash = try notes_commit.store(git_path, platform_impl, allocator);
            defer allocator.free(notes_hash);
            try refs.updateRef(git_path, "refs/notes/commits", notes_hash, platform_impl, allocator);
        }
    } else if (std.mem.eql(u8, subcmd, "show")) {
        var show_target: ?[]const u8 = null;
        while (args.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) show_target = arg;
        }
        const show_hash = if (show_target) |t|
            helpers.resolveRevision(git_path, t, platform_impl, allocator) catch {
                try platform_impl.writeStderr("error: no note found for object\n");
                std.process.exit(1);
            }
        else blk: {
            const h = refs.getCurrentCommit(git_path, platform_impl, allocator) catch {
                try platform_impl.writeStderr("error: no note found\n");
                std.process.exit(1);
            };
            break :blk h orelse { try platform_impl.writeStderr("error: no note found\n"); std.process.exit(1); };
        };
        defer allocator.free(show_hash);
        const notes_ref = "refs/notes/commits";
        const notes_commit_hash = refs.getRef(git_path, notes_ref, platform_impl, allocator) catch {
            try platform_impl.writeStderr("error: no note found for object\n");
            std.process.exit(1);
        };
        defer allocator.free(notes_commit_hash);
        const notes_commit_obj = objects.GitObject.load(notes_commit_hash, git_path, platform_impl, allocator) catch {
            try platform_impl.writeStderr("error: no note found\n");
            std.process.exit(1);
        };
        defer notes_commit_obj.deinit(allocator);
        const notes_tree_hash_str = helpers.extractHeaderField(notes_commit_obj.data, "tree");
        if (notes_tree_hash_str.len == 0) { try platform_impl.writeStderr("error: no note found\n"); std.process.exit(1); }
        const notes_tree_obj = objects.GitObject.load(notes_tree_hash_str, git_path, platform_impl, allocator) catch {
            try platform_impl.writeStderr("error: no note found\n");
            std.process.exit(1);
        };
        defer notes_tree_obj.deinit(allocator);
        var found_blob_hash: ?[40]u8 = null;
        {
            var pos: usize = 0;
            while (pos < notes_tree_obj.data.len) {
                const space_pos = std.mem.indexOfPos(u8, notes_tree_obj.data, pos, " ") orelse break;
                const null_pos = std.mem.indexOfPos(u8, notes_tree_obj.data, space_pos, &[_]u8{0}) orelse break;
                const entry_name = notes_tree_obj.data[space_pos + 1 .. null_pos];
                const hash_start = null_pos + 1;
                if (hash_start + 20 > notes_tree_obj.data.len) break;
                const hash_bytes = notes_tree_obj.data[hash_start .. hash_start + 20];
                if (std.mem.eql(u8, entry_name, show_hash)) {
                    var hex: [40]u8 = undefined;
                    for (hash_bytes, 0..) |b, bi| {
                        const hc = "0123456789abcdef";
                        hex[bi * 2] = hc[b >> 4];
                        hex[bi * 2 + 1] = hc[b & 0xf];
                    }
                    found_blob_hash = hex;
                    break;
                }
                pos = hash_start + 20;
            }
        }
        if (found_blob_hash) |bh| {
            const blob_obj = objects.GitObject.load(&bh, git_path, platform_impl, allocator) catch {
                try platform_impl.writeStderr("error: no note found\n");
                std.process.exit(1);
            };
            defer blob_obj.deinit(allocator);
            if (blob_obj.type == .blob) try platform_impl.writeStdout(blob_obj.data);
        } else {
            try platform_impl.writeStderr("error: no note found for object\n");
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        // no-op for now
    } else if (std.mem.eql(u8, subcmd, "list")) {
        // no-op for now
    } else {
        const emsg = try std.fmt.allocPrint(allocator, "error: unknown notes subcommand: {s}\n", .{subcmd});
        defer allocator.free(emsg);
        try platform_impl.writeStderr(emsg);
        std.process.exit(1);
    }
}
