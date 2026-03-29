// Auto-generated from main_common.zig - cmd_describe
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_merge_base = @import("cmd_merge_base.zig");
const cmd_tag = @import("cmd_tag.zig");

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

pub fn cmdDescribe(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("describe: not supported in freestanding mode\n");
        return;
    }

    // helpers.Parse arguments
    var tags = false;
    var abbrev_zero = false;
    var exact_match = false;
    var target_rev: ?[]const u8 = null;
    var contains_mode = false;
    var all_mode = false;
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--tags")) {
            tags = true;
        } else if (std.mem.eql(u8, arg, "--abbrev=0")) {
            abbrev_zero = true;
        } else if (std.mem.eql(u8, arg, "--exact-match")) {
            exact_match = true;
        } else if (std.mem.eql(u8, arg, "--contains")) {
            tags = true;
            contains_mode = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            all_mode = true;
            tags = true;
        } else if (std.mem.eql(u8, arg, "--long") or std.mem.eql(u8, arg, "--always") or
            std.mem.eql(u8, arg, "--dirty")) {
            // accept silently
        } else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
            if (std.mem.eql(u8, arg, "--abbrev=0")) abbrev_zero = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            target_rev = arg;
        }
    }

    // helpers.Find .git directory first
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // helpers.Get target commit
    const head_hash: []u8 = blk: {
        if (target_rev) |r| {
            const resolved = helpers.resolveRevision(git_path, r, platform_impl, allocator) catch {
                const resolved2 = refs.resolveRef(git_path, r, platform_impl, allocator) catch {
                    try platform_impl.writeStderr("fatal: not a valid object name\n");
                    std.process.exit(128);
                    unreachable;
                };
                break :blk resolved2 orelse {
                    try platform_impl.writeStderr("fatal: not a valid object name\n");
                    std.process.exit(128);
                    unreachable;
                };
            };
            break :blk resolved;
        } else {
            const h = refs.getCurrentCommit(git_path, platform_impl, allocator) catch {
                try platform_impl.writeStderr("fatal: no commits yet\n");
                std.process.exit(128);
                unreachable;
            };
            break :blk h orelse {
                try platform_impl.writeStderr("fatal: no commits yet\n");
                std.process.exit(128);
                unreachable;
            };
        }
    };
    defer allocator.free(head_hash);

    // helpers.Read all tags from refs/tags/*
    const tags_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_path});
    defer allocator.free(tags_path);
    
    var tag_map = std.StringHashMap([]u8).init(allocator);
    defer {
        var iterator = tag_map.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        tag_map.deinit();
    }
    
    // helpers.Read tags directory if it exists
    var tags_dir = std.fs.cwd().openDir(tags_path, .{ .iterate = true }) catch {
        try platform_impl.writeStderr("fatal: helpers.No names found, cannot describe anything.\n");
        std.process.exit(128);
    };
    defer tags_dir.close();
    
    var iterator = tags_dir.iterate();
    while (iterator.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        
        // helpers.Read tag file to get the commit hash it points to
        const tag_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{tags_path, entry.name});
        defer allocator.free(tag_file_path);
        
        const tag_content = platform_impl.fs.readFile(allocator, tag_file_path) catch continue;
        defer allocator.free(tag_content);
        
        const tag_hash = std.mem.trim(u8, tag_content, " \t\n\r");
        
        // helpers.Check if this is an annotated tag (tag object) or lightweight tag (direct commit reference)
        const commit_hash = blk: {
            if (tag_hash.len == 40) {
                // helpers.Try to load as object to see what type it is
                const tag_obj = objects.GitObject.load(tag_hash, git_path, platform_impl, allocator) catch {
                    break :blk try allocator.dupe(u8, tag_hash);
                };
                defer tag_obj.deinit(allocator);
                
                if (tag_obj.type == .tag) {
                    // It's an annotated tag, parse it to get the object it points to
                    const object_hash = helpers.parseTagObject(tag_obj.data, allocator) catch {
                        break :blk try allocator.dupe(u8, tag_hash);
                    };
                    break :blk object_hash;
                } else if (tag_obj.type == .commit) {
                    // It's a lightweight tag - only include if --tags
                    if (!tags) continue;
                    break :blk try allocator.dupe(u8, tag_hash);
                } else {
                    continue; // helpers.Skip tags pointing to non-commit helpers.objects for now
                }
            } else {
                continue; // Invalid hash
            }
        };
        
        try tag_map.put(try allocator.dupe(u8, entry.name), commit_hash);
    }
    
    if (tag_map.count() == 0) {
        try platform_impl.writeStderr("fatal: helpers.No names found, cannot describe anything.\n");
        std.process.exit(128);
    }
    
    // helpers.Walk helpers.HEAD commit chain backward looking for a match with any tag
    // helpers.Also check packed-helpers.refs for tags
    const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_path});
    defer allocator.free(packed_refs_path);
    if (platform_impl.fs.readFile(allocator, packed_refs_path)) |packed_content| {
        defer allocator.free(packed_content);
        var plines = std.mem.splitScalar(u8, packed_content, '\n');
        while (plines.next()) |pline| {
            if (pline.len == 0 or pline[0] == '#' or pline[0] == '^') continue;
            if (pline.len >= 41 and pline[40] == ' ') {
                const ref_name = pline[41..];
                if (std.mem.startsWith(u8, ref_name, "refs/tags/")) {
                    const tag_name = ref_name["refs/tags/".len..];
                    if (tag_map.contains(tag_name)) continue;
                    const tag_hash = pline[0..40];
                    const commit_hash2 = resolve_blk: {
                        const tag_obj = objects.GitObject.load(tag_hash, git_path, platform_impl, allocator) catch { break :resolve_blk allocator.dupe(u8, tag_hash) catch continue; };
                        defer tag_obj.deinit(allocator);
                        if (tag_obj.type == .tag) { break :resolve_blk helpers.parseTagObject(tag_obj.data, allocator) catch { break :resolve_blk allocator.dupe(u8, tag_hash) catch continue; }; }
                        else if (tag_obj.type == .commit) { if (!tags) continue; break :resolve_blk allocator.dupe(u8, tag_hash) catch continue; }
                        else continue;
                    };
                    tag_map.put(allocator.dupe(u8, tag_name) catch continue, commit_hash2) catch continue;
                }
            }
        }
    } else |_| {}

    var result: ?helpers.TagWithDistance = null;
    
    if (contains_mode) {
        // --contains mode: find the nearest tag that has helpers.HEAD as ancestor
        var tag_iter = tag_map.iterator();
        while (tag_iter.next()) |entry| {
            const tag_name = entry.key_ptr.*;
            const tag_commit = entry.value_ptr.*;
            // helpers.Check if head_hash is an ancestor of tag_commit
            if (std.mem.eql(u8, tag_commit, head_hash)) {
                // helpers.Exact match
                const n = try allocator.dupe(u8, tag_name);
                if (result == null or 0 < result.?.distance) {
                    if (result) |old| allocator.free(old.tag_name);
                    result = helpers.TagWithDistance{ .tag_name = n, .distance = 0 };
                } else {
                    allocator.free(n);
                }
            } else if (helpers.isAncestor(git_path, head_hash, tag_commit, allocator, platform_impl) catch false) {
                // head_hash is ancestor of tag_commit - compute distance
                const dist = helpers.computeDistance(git_path, head_hash, tag_commit, allocator, platform_impl) catch continue;
                const n = try allocator.dupe(u8, tag_name);
                if (result == null or dist < result.?.distance) {
                    if (result) |old| allocator.free(old.tag_name);
                    result = helpers.TagWithDistance{ .tag_name = n, .distance = dist };
                } else {
                    allocator.free(n);
                }
            }
        }
    } else {
        result = findTagInHistoryWithDistance(git_path, head_hash, &tag_map, tags, allocator, platform_impl) catch null;
    }

    if (result) |r| {
        defer allocator.free(r.tag_name);
        if (exact_match and r.distance != 0) {
            try platform_impl.writeStderr("fatal: no tag exactly matches '");
            try platform_impl.writeStderr(head_hash[0..@min(7, head_hash.len)]);
            try platform_impl.writeStderr("'\n");
            std.process.exit(128);
        }
        if (contains_mode) {
            // --contains output: tag~N or tags/tag~N (with --all)
            const prefix = if (all_mode) "tags/" else "";
            if (r.distance == 0) {
                const output = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{prefix, r.tag_name});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            } else {
                const output = try std.fmt.allocPrint(allocator, "{s}{s}~{d}\n", .{prefix, r.tag_name, r.distance});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        } else if (r.distance == 0) {
            const output = try std.fmt.allocPrint(allocator, "{s}\n", .{r.tag_name});
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else if (abbrev_zero) {
            const output = try std.fmt.allocPrint(allocator, "{s}-{d}\n", .{ r.tag_name, r.distance });
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else {
            const short_hash = head_hash[0..@min(7, head_hash.len)];
            const output = try std.fmt.allocPrint(allocator, "{s}-{d}-g{s}\n", .{ r.tag_name, r.distance, short_hash });
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        }
    } else {
        if (exact_match) {
            try platform_impl.writeStderr("fatal: no tag exactly matches '");
            try platform_impl.writeStderr(head_hash[0..@min(7, head_hash.len)]);
            try platform_impl.writeStderr("'\n");
            std.process.exit(128);
        }
        try platform_impl.writeStderr("fatal: helpers.No names found, cannot describe anything.\n");
        std.process.exit(128);
    }
}


pub fn findTagInHistory(git_path: []const u8, start_hash: []const u8, tag_map: *const std.StringHashMap([]u8), allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !?[]u8 {
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var iterator = visited.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        visited.deinit();
    }
    
    var commit_stack = std.ArrayList([]u8).init(allocator);
    defer {
        for (commit_stack.items) |hash| {
            allocator.free(hash);
        }
        commit_stack.deinit();
    }
    
    try commit_stack.append(try allocator.dupe(u8, start_hash));
    
    while (commit_stack.items.len > 0) {
        const current_hash = commit_stack.pop() orelse break;
        defer allocator.free(current_hash);
        
        // helpers.Avoid infinite loops
        if (visited.contains(current_hash)) continue;
        try visited.put(try allocator.dupe(u8, current_hash), {});
        
        // helpers.Check if this commit matches any tag
        var tag_iterator = tag_map.iterator();
        while (tag_iterator.next()) |entry| {
            const tag_name = entry.key_ptr.*;
            const tag_commit = entry.value_ptr.*;
            
            if (std.mem.eql(u8, current_hash, tag_commit)) {
                return try allocator.dupe(u8, tag_name);
            }
        }
        
        // helpers.Load commit object to get parents
        const commit_obj = objects.GitObject.load(current_hash, git_path, platform_impl, allocator) catch continue;
        defer commit_obj.deinit(allocator);
        
        if (commit_obj.type != .commit) continue;
        
        // helpers.Parse commit data to find parents
        var lines = std.mem.splitSequence(u8, commit_obj.data, "\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                const parent_hash = line["parent ".len..];
                if (parent_hash.len >= 40 and !visited.contains(parent_hash[0..40])) {
                    try commit_stack.append(try allocator.dupe(u8, parent_hash[0..40]));
                }
            } else if (line.len == 0) {
                break; // helpers.End of headers
            }
        }
    }
    
    return null; // helpers.No tag found in history
}


pub fn findTagInHistoryWithDistance(git_path: []const u8, start_hash: []const u8, tag_map: *const std.StringHashMap([]u8), include_lightweight: bool, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !?helpers.TagWithDistance {
    // helpers.BFS to find closest tagged ancestor
    var queue = std.ArrayList(struct { hash: []u8, depth: u32 }).init(allocator);
    defer {
        for (queue.items) |item| allocator.free(item.hash);
        queue.deinit();
    }
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var it = visited.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        visited.deinit();
    }

    try queue.append(.{ .hash = try allocator.dupe(u8, start_hash), .depth = 0 });

    while (queue.items.len > 0) {
        const item = queue.orderedRemove(0);
        defer allocator.free(item.hash);

        if (visited.contains(item.hash)) continue;
        try visited.put(try allocator.dupe(u8, item.hash), {});

        // helpers.Check if any tag points to this commit
        var tag_iter = tag_map.iterator();
        while (tag_iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*, item.hash)) {
                _ = include_lightweight; // TODO: filter by annotated vs lightweight
                return helpers.TagWithDistance{
                    .tag_name = try allocator.dupe(u8, entry.key_ptr.*),
                    .distance = item.depth,
                };
            }
        }

        // Don't search too deep
        if (item.depth > 1000) continue;

        // helpers.Add parents
        const obj = objects.GitObject.load(item.hash, git_path, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);
        if (obj.type != .commit) continue;

        var lines = std.mem.splitScalar(u8, obj.data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "parent ")) {
                const parent_hash = line["parent ".len..];
                if (!visited.contains(parent_hash)) {
                    try queue.append(.{ .hash = try allocator.dupe(u8, parent_hash), .depth = item.depth + 1 });
                }
            }
        }
    }

    return null;
}
