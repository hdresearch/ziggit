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

const FANOUT_THRESHOLD: usize = 256;

const NoteEntry = struct { name: []const u8, hash: [20]u8 };
const SubEntry = struct { rest: []const u8, hash: [20]u8 };

fn hexFromBytes(bytes: [20]u8) [40]u8 {
    const hc = "0123456789abcdef";
    var hex: [40]u8 = undefined;
    for (bytes, 0..) |b, i| {
        hex[i * 2] = hc[b >> 4];
        hex[i * 2 + 1] = hc[b & 0xf];
    }
    return hex;
}

fn bytesFromHex(hex: []const u8) [20]u8 {
    var result: [20]u8 = undefined;
    for (0..20) |i| {
        result[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch 0;
    }
    return result;
}

/// A map of note_name (40-char hex) -> blob_hash (20 bytes)
const NotesMap = std.StringHashMap([20]u8);

/// Load all notes from a tree object, handling both flat and fanned-out layouts.
/// For flat: entries are "100644 <40char_hex>\0<20bytes>"
/// For fanned-out: entries are "40000 <2char_hex>\0<20bytes>" pointing to subtrees
///   containing "100644 <38char_hex>\0<20bytes>"
fn loadNotesFromTree(tree_data: []const u8, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !NotesMap {
    var map = NotesMap.init(allocator);
    errdefer {
        var it = map.iterator();
        while (it.next()) |kv| allocator.free(kv.key_ptr.*);
        map.deinit();
    }

    var pos: usize = 0;
    while (pos < tree_data.len) {
        const space_pos = std.mem.indexOfPos(u8, tree_data, pos, " ") orelse break;
        const null_pos = std.mem.indexOfPos(u8, tree_data, space_pos, &[_]u8{0}) orelse break;
        const mode = tree_data[pos..space_pos];
        const entry_name = tree_data[space_pos + 1 .. null_pos];
        const hash_start = null_pos + 1;
        if (hash_start + 20 > tree_data.len) break;
        const entry_hash: [20]u8 = tree_data[hash_start..][0..20].*;
        pos = hash_start + 20;

        if (std.mem.eql(u8, mode, "40000") and entry_name.len == 2) {
            // This is a fanout subtree - load its entries
            const subtree_hex = hexFromBytes(entry_hash);
            const subtree_obj = objects.GitObject.load(&subtree_hex, git_path, platform_impl, allocator) catch continue;
            defer subtree_obj.deinit(allocator);
            if (subtree_obj.type != .tree) continue;

            var sub_pos: usize = 0;
            while (sub_pos < subtree_obj.data.len) {
                const sub_space = std.mem.indexOfPos(u8, subtree_obj.data, sub_pos, " ") orelse break;
                const sub_null = std.mem.indexOfPos(u8, subtree_obj.data, sub_space, &[_]u8{0}) orelse break;
                const sub_name = subtree_obj.data[sub_space + 1 .. sub_null];
                const sub_hash_start = sub_null + 1;
                if (sub_hash_start + 20 > subtree_obj.data.len) break;
                const sub_hash: [20]u8 = subtree_obj.data[sub_hash_start..][0..20].*;
                sub_pos = sub_hash_start + 20;

                // Reconstruct full name: prefix + rest
                const full_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ entry_name, sub_name });
                try map.put(full_name, sub_hash);
            }
        } else {
            // Flat entry
            const name_copy = try allocator.dupe(u8, entry_name);
            try map.put(name_copy, entry_hash);
        }
    }
    return map;
}

fn freeNotesMap(map: *NotesMap, allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |kv| allocator.free(kv.key_ptr.*);
    map.deinit();
}

/// Build a notes tree (with automatic fanout) and return its hash.
fn buildNotesTree(map: *NotesMap, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) ![]u8 {
    const count = map.count();
    const use_fanout = count >= FANOUT_THRESHOLD;

    if (!use_fanout) {
        // Build flat tree
        // Collect and sort entries for deterministic output
        var entries_list = std.ArrayList(NoteEntry).init(allocator);
        defer entries_list.deinit();
        var it = map.iterator();
        while (it.next()) |kv| {
            try entries_list.append(.{ .name = kv.key_ptr.*, .hash = kv.value_ptr.* });
        }
        std.mem.sort(NoteEntry, entries_list.items, {}, struct {
            fn lessThan(_: void, a: NoteEntry, b: NoteEntry) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);

        var tree_buf = std.ArrayList(u8).init(allocator);
        defer tree_buf.deinit();
        for (entries_list.items) |entry| {
            try tree_buf.appendSlice("100644 ");
            try tree_buf.appendSlice(entry.name);
            try tree_buf.append(0);
            try tree_buf.appendSlice(&entry.hash);
        }
        const tree_obj = objects.GitObject.init(.tree, tree_buf.items);
        return try tree_obj.store(git_path, platform_impl, allocator);
    } else {
        // Build fanned-out tree: group by first 2 chars
        var prefix_map = std.StringHashMap(std.ArrayList(SubEntry)).init(allocator);
        defer {
            var pit = prefix_map.iterator();
            while (pit.next()) |kv| {
                kv.value_ptr.deinit();
            }
            prefix_map.deinit();
        }

        var it = map.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            if (name.len < 2) continue;
            const prefix = name[0..2];
            const rest = name[2..];
            const gop = try prefix_map.getOrPut(prefix);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(SubEntry).init(allocator);
            }
            try gop.value_ptr.append(.{ .rest = rest, .hash = kv.value_ptr.* });
        }

        // Build subtrees for each prefix, then build top-level tree
        // Collect prefixes and sort
        var prefixes = std.ArrayList([]const u8).init(allocator);
        defer prefixes.deinit();
        var pit2 = prefix_map.iterator();
        while (pit2.next()) |kv| {
            try prefixes.append(kv.key_ptr.*);
        }
        std.mem.sort([]const u8, prefixes.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        var top_tree = std.ArrayList(u8).init(allocator);
        defer top_tree.deinit();

        for (prefixes.items) |prefix| {
            const entries = prefix_map.getPtr(prefix).?;
            // Sort entries within prefix
            std.mem.sort(SubEntry, entries.items, {}, struct {
                fn lessThan(_: void, a: SubEntry, b: SubEntry) bool {
                    return std.mem.lessThan(u8, a.rest, b.rest);
                }
            }.lessThan);

            var sub_buf = std.ArrayList(u8).init(allocator);
            defer sub_buf.deinit();
            for (entries.items) |entry| {
                try sub_buf.appendSlice("100644 ");
                try sub_buf.appendSlice(entry.rest);
                try sub_buf.append(0);
                try sub_buf.appendSlice(&entry.hash);
            }
            const sub_tree_obj = objects.GitObject.init(.tree, sub_buf.items);
            const sub_tree_hash = try sub_tree_obj.store(git_path, platform_impl, allocator);
            defer allocator.free(sub_tree_hash);
            const sub_hash_bin = bytesFromHex(sub_tree_hash);

            try top_tree.appendSlice("40000 ");
            try top_tree.appendSlice(prefix);
            try top_tree.append(0);
            try top_tree.appendSlice(&sub_hash_bin);
        }

        const tree_obj = objects.GitObject.init(.tree, top_tree.items);
        return try tree_obj.store(git_path, platform_impl, allocator);
    }
}

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

        // Resolve target (default to HEAD)
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

        // Create blob object with the note message
        const blob_content = try std.fmt.allocPrint(allocator, "{s}\n", .{msg});
        defer allocator.free(blob_content);
        const blob_obj = objects.GitObject.init(.blob, blob_content);
        const blob_hash = try blob_obj.store(git_path, platform_impl, allocator);
        defer allocator.free(blob_hash);

        // Read existing notes
        const notes_ref = "refs/notes/commits";
        const existing_commit = refs.getRef(git_path, notes_ref, platform_impl, allocator) catch null;
        defer if (existing_commit) |ec| allocator.free(ec);

        var notes_map = NotesMap.init(allocator);
        defer freeNotesMap(&notes_map, allocator);

        if (existing_commit) |ec| {
            const commit_obj = objects.GitObject.load(ec, git_path, platform_impl, allocator) catch null;
            defer if (commit_obj) |co| co.deinit(allocator);
            if (commit_obj) |co| {
                const tree_hash_str = helpers.extractHeaderField(co.data, "tree");
                if (tree_hash_str.len > 0) {
                    const tree_obj = objects.GitObject.load(tree_hash_str, git_path, platform_impl, allocator) catch null;
                    defer if (tree_obj) |to| to.deinit(allocator);
                    if (tree_obj) |to| {
                        var loaded = loadNotesFromTree(to.data, git_path, platform_impl, allocator) catch NotesMap.init(allocator);
                        // Move entries to notes_map
                        var lit = loaded.iterator();
                        while (lit.next()) |kv| {
                            notes_map.put(kv.key_ptr.*, kv.value_ptr.*) catch {};
                        }
                        // Don't free keys since they're moved to notes_map
                        loaded.deinit();
                    }
                }
            }
        }

        // Check if note already exists
        if (notes_map.contains(target_hash)) {
            if (!force) {
                const err_msg = try std.fmt.allocPrint(allocator, "error: Cannot add notes. Found existing notes for object {s}. Use '-f' to overwrite existing notes\n", .{target_hash});
                defer allocator.free(err_msg);
                try platform_impl.writeStderr(err_msg);
                std.process.exit(1);
            }
            // Remove old entry (key already allocated, will be replaced)
            if (notes_map.fetchRemove(target_hash)) |kv| {
                allocator.free(kv.key);
            }
        }

        // Add new note
        const target_key = try allocator.dupe(u8, target_hash);
        const blob_hash_bin = bytesFromHex(blob_hash);
        try notes_map.put(target_key, blob_hash_bin);

        // Build tree
        const tree_hash = try buildNotesTree(&notes_map, git_path, platform_impl, allocator);
        defer allocator.free(tree_hash);

        // Create commit
        const author_str = helpers.getAuthorString(allocator) catch try allocator.dupe(u8, "Unknown <unknown@unknown>");
        defer allocator.free(author_str);
        const committer_str = helpers.getCommitterString(allocator) catch try allocator.dupe(u8, "Unknown <unknown@unknown>");
        defer allocator.free(committer_str);

        if (existing_commit) |ec| {
            const parents = [_][]const u8{ec};
            const notes_commit = try objects.createCommitObject(tree_hash, &parents, author_str, committer_str, "Notes added by 'git notes add'", allocator);
            defer notes_commit.deinit(allocator);
            const notes_hash = try notes_commit.store(git_path, platform_impl, allocator);
            defer allocator.free(notes_hash);
            try refs.updateRef(git_path, "refs/notes/commits", notes_hash, platform_impl, allocator);
        } else {
            const empty_parents: []const []const u8 = &.{};
            const notes_commit = try objects.createCommitObject(tree_hash, empty_parents, author_str, committer_str, "Notes added by 'git notes add'", allocator);
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

        // Load notes map (handles both flat and fanned-out)
        var notes_map = loadNotesFromTree(notes_tree_obj.data, git_path, platform_impl, allocator) catch {
            try platform_impl.writeStderr("error: no note found\n");
            std.process.exit(1);
        };
        defer freeNotesMap(&notes_map, allocator);

        if (notes_map.get(show_hash)) |blob_hash_bin| {
            const bh = hexFromBytes(blob_hash_bin);
            const blob_obj2 = objects.GitObject.load(&bh, git_path, platform_impl, allocator) catch {
                try platform_impl.writeStderr("error: no note found\n");
                std.process.exit(1);
            };
            defer blob_obj2.deinit(allocator);
            if (blob_obj2.type == .blob) try platform_impl.writeStdout(blob_obj2.data);
        } else {
            try platform_impl.writeStderr("error: no note found for object\n");
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        var rm_target: ?[]const u8 = null;
        while (args.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) rm_target = arg;
        }
        const rm_hash = if (rm_target) |t|
            helpers.resolveRevision(git_path, t, platform_impl, allocator) catch {
                try platform_impl.writeStderr("error: failed to resolve target\n");
                std.process.exit(1);
            }
        else blk: {
            const h = refs.getCurrentCommit(git_path, platform_impl, allocator) catch { std.process.exit(1); };
            break :blk h orelse { std.process.exit(1); };
        };
        defer allocator.free(rm_hash);

        const notes_ref_rm = "refs/notes/commits";
        const nc_hash = refs.getRef(git_path, notes_ref_rm, platform_impl, allocator) catch {
            try platform_impl.writeStderr("error: no note found\n");
            std.process.exit(1);
        };
        defer allocator.free(nc_hash);
        const nc_obj = objects.GitObject.load(nc_hash, git_path, platform_impl, allocator) catch {
            try platform_impl.writeStderr("error: no note found\n");
            std.process.exit(1);
        };
        defer nc_obj.deinit(allocator);
        const nt_hash = helpers.extractHeaderField(nc_obj.data, "tree");
        if (nt_hash.len == 0) { try platform_impl.writeStderr("error: no note found\n"); std.process.exit(1); }
        const nt_obj = objects.GitObject.load(nt_hash, git_path, platform_impl, allocator) catch {
            try platform_impl.writeStderr("error: no note found\n");
            std.process.exit(1);
        };
        defer nt_obj.deinit(allocator);

        // Load notes map
        var notes_map = loadNotesFromTree(nt_obj.data, git_path, platform_impl, allocator) catch {
            try platform_impl.writeStderr("error: no note found\n");
            std.process.exit(1);
        };
        defer freeNotesMap(&notes_map, allocator);

        if (notes_map.fetchRemove(rm_hash)) |kv| {
            allocator.free(kv.key);
        } else {
            try platform_impl.writeStderr("error: no note found for object\n");
            std.process.exit(1);
        }

        // Build new tree
        const rm_tree_hash = try buildNotesTree(&notes_map, git_path, platform_impl, allocator);
        defer allocator.free(rm_tree_hash);

        const rm_author = helpers.getAuthorString(allocator) catch try allocator.dupe(u8, "Unknown <unknown@unknown>");
        defer allocator.free(rm_author);
        const rm_committer = helpers.getCommitterString(allocator) catch try allocator.dupe(u8, "Unknown <unknown@unknown>");
        defer allocator.free(rm_committer);
        const rm_parents = [_][]const u8{nc_hash};
        const rm_commit = try objects.createCommitObject(rm_tree_hash, &rm_parents, rm_author, rm_committer, "Notes removed by 'git notes remove'", allocator);
        defer rm_commit.deinit(allocator);
        const rm_commit_hash = try rm_commit.store(git_path, platform_impl, allocator);
        defer allocator.free(rm_commit_hash);
        try refs.updateRef(git_path, "refs/notes/commits", rm_commit_hash, platform_impl, allocator);
        const rm_msg = try std.fmt.allocPrint(allocator, "Removing note for object {s}\n", .{rm_hash});
        defer allocator.free(rm_msg);
        try platform_impl.writeStdout(rm_msg);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        var list_target: ?[]const u8 = null;
        while (args.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) list_target = arg;
        }

        const notes_ref_list = "refs/notes/commits";
        const nc_hash_l = refs.getRef(git_path, notes_ref_list, platform_impl, allocator) catch return;
        defer allocator.free(nc_hash_l);
        const nc_obj_l = objects.GitObject.load(nc_hash_l, git_path, platform_impl, allocator) catch return;
        defer nc_obj_l.deinit(allocator);
        const nt_hash_l = helpers.extractHeaderField(nc_obj_l.data, "tree");
        if (nt_hash_l.len == 0) return;
        const nt_obj_l = objects.GitObject.load(nt_hash_l, git_path, platform_impl, allocator) catch return;
        defer nt_obj_l.deinit(allocator);

        // Load notes map
        var notes_map = loadNotesFromTree(nt_obj_l.data, git_path, platform_impl, allocator) catch return;
        defer freeNotesMap(&notes_map, allocator);

        const filter_hash: ?[]const u8 = if (list_target) |t|
            helpers.resolveRevision(git_path, t, platform_impl, allocator) catch null
        else
            null;
        defer if (filter_hash) |fh| allocator.free(fh);

        if (filter_hash) |fh| {
            if (notes_map.get(fh)) |blob_hash_bin| {
                const hex = hexFromBytes(blob_hash_bin);
                const out = try std.fmt.allocPrint(allocator, "{s}\n", .{hex});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
                return;
            }
            try platform_impl.writeStderr("error: no note found for object\n");
            std.process.exit(1);
        }

        // Collect and sort for deterministic output
        var entries_list = std.ArrayList(NoteEntry).init(allocator);
        defer entries_list.deinit();
        var it = notes_map.iterator();
        while (it.next()) |kv| {
            try entries_list.append(.{ .name = kv.key_ptr.*, .hash = kv.value_ptr.* });
        }
        std.mem.sort(NoteEntry, entries_list.items, {}, struct {
            fn lessThan(_: void, a: NoteEntry, b: NoteEntry) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);

        for (entries_list.items) |entry| {
            const hex = hexFromBytes(entry.hash);
            const out = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ hex, entry.name });
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        }
    } else {
        const emsg = try std.fmt.allocPrint(allocator, "error: unknown notes subcommand: {s}\n", .{subcmd});
        defer allocator.free(emsg);
        try platform_impl.writeStderr(emsg);
        std.process.exit(1);
    }
}
