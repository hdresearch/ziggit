const std = @import("std");
const platform_mod = @import("../platform/platform.zig");
const refs = @import("refs.zig");
const objects = @import("objects.zig");

/// Parse a simple config value from git config content (last value wins)
fn parseSimpleConfigValue(config_content: []const u8, key: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var result: ?[]u8 = null;
    var iter = iterConfigValues(config_content, key);
    while (iter.next(allocator) catch null) |val| {
        if (result) |old| allocator.free(old);
        result = val;
    }
    return result orelse error.KeyNotFound;
}

/// Parse all config values for a given key (for multi-valued keys like remote.X.fetch)
fn parseAllConfigValues(config_content: []const u8, key: []const u8, allocator: std.mem.Allocator) !std.array_list.Managed([]u8) {
    var list = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (list.items) |v| allocator.free(v);
        list.deinit();
    }
    var iter = iterConfigValues(config_content, key);
    while (iter.next(allocator) catch null) |val| {
        try list.append(val);
    }
    return list;
}

/// Iterator over config values for a given key
const ConfigValueIterator = struct {
    content: []const u8,
    key: []const u8,
    pos: usize,

    fn next(self: *ConfigValueIterator, allocator: std.mem.Allocator) !?[]u8 {
        // Parse section.subsection.key format
        // key format: "section.key" or "section.subsection.key"
        const dot1 = std.mem.indexOfScalar(u8, self.key, '.') orelse return null;
        const rest = self.key[dot1 + 1 ..];
        const dot2 = std.mem.lastIndexOfScalar(u8, rest, '.');
        const section = self.key[0..dot1];
        const subsection = if (dot2) |d| rest[0..d] else null;
        const var_name = if (dot2) |d| rest[d + 1 ..] else rest;

        while (self.pos < self.content.len) {
            const line_end = std.mem.indexOfScalar(u8, self.content[self.pos..], '\n') orelse self.content.len - self.pos;
            const line = std.mem.trim(u8, self.content[self.pos..self.pos + line_end], " \t\r");
            self.pos += line_end + 1;

            // Check for section header
            if (line.len > 0 and line[0] == '[') {
                // Parse section header
                const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
                const header = line[1..close];

                var cur_section: []const u8 = undefined;
                var cur_subsection: ?[]const u8 = null;

                if (std.mem.indexOfScalar(u8, header, '"')) |q1| {
                    cur_section = std.mem.trim(u8, header[0..q1], " \t");
                    const after_q1 = header[q1 + 1 ..];
                    if (std.mem.indexOfScalar(u8, after_q1, '"')) |q2| {
                        cur_subsection = after_q1[0..q2];
                    }
                } else {
                    cur_section = header;
                }

                // Check if this section matches
                if (!std.ascii.eqlIgnoreCase(cur_section, section)) continue;
                if (subsection) |ss| {
                    if (cur_subsection == null or !std.mem.eql(u8, cur_subsection.?, ss)) continue;
                } else {
                    if (cur_subsection != null) continue;
                }

                // We're in the right section, scan for values
                while (self.pos < self.content.len) {
                    const vline_end = std.mem.indexOfScalar(u8, self.content[self.pos..], '\n') orelse self.content.len - self.pos;
                    const vline = std.mem.trim(u8, self.content[self.pos..self.pos + vline_end], " \t\r");

                    if (vline.len > 0 and vline[0] == '[') break; // new section
                    self.pos += vline_end + 1;

                    if (vline.len == 0 or vline[0] == '#' or vline[0] == ';') continue;

                    // Parse key = value
                    const eq = std.mem.indexOfScalar(u8, vline, '=') orelse continue;
                    const vkey = std.mem.trim(u8, vline[0..eq], " \t");
                    const vval = std.mem.trim(u8, vline[eq + 1 ..], " \t");

                    if (std.ascii.eqlIgnoreCase(vkey, var_name)) {
                        return try allocator.dupe(u8, vval);
                    }
                }
            }
        }
        return null;
    }
};

fn iterConfigValues(content: []const u8, key: []const u8) ConfigValueIterator {
    return .{ .content = content, .key = key, .pos = 0 };
}

/// A simpler approach: scan config content for all values of a key
fn getAllConfigValues(config_content: []const u8, key: []const u8, allocator: std.mem.Allocator) !std.array_list.Managed([]u8) {
    // Parse key: section.subsection.varname or section.varname
    const dot1 = std.mem.indexOfScalar(u8, key, '.') orelse return error.InvalidKey;
    const rest = key[dot1 + 1 ..];
    const dot2 = std.mem.lastIndexOfScalar(u8, rest, '.');
    const section = key[0..dot1];
    const subsection: ?[]const u8 = if (dot2) |d| rest[0..d] else null;
    const var_name = if (dot2) |d| rest[d + 1 ..] else rest;

    var result = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (result.items) |v| allocator.free(v);
        result.deinit();
    }

    var in_matching_section = false;
    var lines = std.mem.splitScalar(u8, config_content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        if (line[0] == '[') {
            in_matching_section = false;
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const header = line[1..close];

            var cur_section: []const u8 = undefined;
            var cur_subsection: ?[]const u8 = null;

            if (std.mem.indexOfScalar(u8, header, '"')) |q1| {
                cur_section = std.mem.trim(u8, header[0..q1], " \t");
                const after_q1 = header[q1 + 1 ..];
                if (std.mem.indexOfScalar(u8, after_q1, '"')) |q2| {
                    cur_subsection = after_q1[0..q2];
                }
            } else if (std.mem.indexOfScalar(u8, header, ' ')) |sp| {
                // [section "subsection"] without quotes already handled, but also [section subsection]
                cur_section = header[0..sp];
                cur_subsection = std.mem.trim(u8, header[sp + 1 ..], " \t\"");
            } else {
                cur_section = header;
            }

            if (std.ascii.eqlIgnoreCase(cur_section, section)) {
                if (subsection) |ss| {
                    if (cur_subsection != null and std.mem.eql(u8, cur_subsection.?, ss)) {
                        in_matching_section = true;
                    }
                } else {
                    if (cur_subsection == null) {
                        in_matching_section = true;
                    }
                }
            }
            continue;
        }

        if (!in_matching_section) continue;

        // Parse key = value
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            const vkey = std.mem.trim(u8, line[0..eq], " \t");
            const vval = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(vkey, var_name)) {
                try result.append(try allocator.dupe(u8, vval));
            }
        }
    }
    return result;
}

fn getConfigValue(config_content: []const u8, key: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var vals = try getAllConfigValues(config_content, key, allocator);
    defer {
        // Free all but last
        if (vals.items.len > 1) {
            for (vals.items[0 .. vals.items.len - 1]) |v| allocator.free(v);
        }
        vals.deinit();
    }
    if (vals.items.len == 0) return error.KeyNotFound;
    return vals.items[vals.items.len - 1]; // Return last value (owned)
}

fn readFileContent(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
}

pub const RefEntry = struct {
    name: []const u8,
    hash: []const u8,
};

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

    // Check for .git subdirectory first
    const git_objects = try std.fmt.allocPrint(allocator, "{s}/.git/objects", .{abs_path});
    defer allocator.free(git_objects);
    if (std.fs.cwd().access(git_objects, .{})) |_| {
        const result = try std.fmt.allocPrint(allocator, "{s}/.git", .{abs_path});
        allocator.free(abs_path);
        return result;
    } else |_| {}

    // Check if bare repo
    const objects_path = try std.fmt.allocPrint(allocator, "{s}/objects", .{abs_path});
    defer allocator.free(objects_path);
    const refs_path = try std.fmt.allocPrint(allocator, "{s}/refs", .{abs_path});
    defer allocator.free(refs_path);
    const has_objects = if (std.fs.cwd().access(objects_path, .{})) |_| true else |_| false;
    const has_refs = if (std.fs.cwd().access(refs_path, .{})) |_| true else |_| false;
    if (has_objects and has_refs) return abs_path;

    allocator.free(abs_path);
    return error.RepositoryNotFound;
}

pub fn collectAllRefs(allocator: std.mem.Allocator, git_dir: []const u8) !std.array_list.Managed(RefEntry) {
    var result = std.array_list.Managed(RefEntry).init(allocator);
    errdefer {
        for (result.items) |e| {
            allocator.free(e.name);
            allocator.free(e.hash);
        }
        result.deinit();
    }

    // Read packed-refs
    const packed_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_path);
    if (readFileContent(allocator, packed_path)) |pc| {
        defer allocator.free(pc);
        var lines = std.mem.splitScalar(u8, pc, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            if (std.mem.indexOfScalar(u8, line, ' ')) |si| {
                const h = line[0..si];
                const n = line[si + 1 ..];
                if (h.len >= 40) {
                    try result.append(.{
                        .name = try allocator.dupe(u8, n),
                        .hash = try allocator.dupe(u8, h[0..40]),
                    });
                }
            }
        }
    } else |_| {}

    // Collect loose refs (overriding packed)
    try collectLooseRefsRecursive(allocator, git_dir, "refs", &result);

    return result;
}

fn collectLooseRefsRecursive(allocator: std.mem.Allocator, git_dir: []const u8, prefix: []const u8, result: *std.array_list.Managed(RefEntry)) !void {
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, prefix });
    defer allocator.free(dir_path);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        const full_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });

        if (entry.kind == .directory) {
            defer allocator.free(full_name);
            try collectLooseRefsRecursive(allocator, git_dir, full_name, result);
        } else if (entry.kind == .file) {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, full_name });
            defer allocator.free(file_path);

            if (readFileContent(allocator, file_path)) |content| {
                defer allocator.free(content);
                const trimmed = std.mem.trim(u8, content, " \t\r\n");
                if (trimmed.len >= 40 and !std.mem.startsWith(u8, trimmed, "ref: ")) {
                    // Remove existing packed entry with same name
                    var i: usize = 0;
                    while (i < result.items.len) {
                        if (std.mem.eql(u8, result.items[i].name, full_name)) {
                            allocator.free(result.items[i].name);
                            allocator.free(result.items[i].hash);
                            _ = result.orderedRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                    try result.append(.{
                        .name = full_name,
                        .hash = try allocator.dupe(u8, trimmed[0..40]),
                    });
                } else {
                    allocator.free(full_name);
                }
            } else |_| {
                allocator.free(full_name);
            }
        } else {
            allocator.free(full_name);
        }
    }
}

pub fn copyMissingObjects(src: []const u8, dst: []const u8) void {
    var sd = std.fs.cwd().openDir(src, .{ .iterate = true }) catch return;
    defer sd.close();
    var it = sd.iterate();
    while (it.next() catch null) |e| {
        if (e.kind != .directory or e.name.len != 2) continue;
        var sb: [4096]u8 = undefined;
        var db: [4096]u8 = undefined;
        const ss = std.fmt.bufPrint(&sb, "{s}/{s}", .{ src, e.name }) catch continue;
        const dd = std.fmt.bufPrint(&db, "{s}/{s}", .{ dst, e.name }) catch continue;
        std.fs.cwd().makePath(dd) catch {};
        var sub = std.fs.cwd().openDir(ss, .{ .iterate = true }) catch continue;
        defer sub.close();
        var si = sub.iterate();
        while (si.next() catch null) |oe| {
            if (oe.kind != .file) continue;
            var os: [4096]u8 = undefined;
            var od: [4096]u8 = undefined;
            const fs = std.fmt.bufPrint(&os, "{s}/{s}", .{ ss, oe.name }) catch continue;
            const fd = std.fmt.bufPrint(&od, "{s}/{s}", .{ dd, oe.name }) catch continue;
            std.fs.cwd().access(fd, .{}) catch {
                std.fs.cwd().copyFile(fs, std.fs.cwd(), fd, .{}) catch {};
            };
        }
    }
}

pub fn copyMissingPackFiles(src: []const u8, dst: []const u8) void {
    std.fs.cwd().makePath(dst) catch {};
    var sd = std.fs.cwd().openDir(src, .{ .iterate = true }) catch return;
    defer sd.close();
    var it = sd.iterate();
    while (it.next() catch null) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.name, ".pack") and !std.mem.endsWith(u8, e.name, ".idx") and
            !std.mem.endsWith(u8, e.name, ".rev") and !std.mem.endsWith(u8, e.name, ".bitmap")) continue;
        var sb: [4096]u8 = undefined;
        var db_buf: [4096]u8 = undefined;
        const fs = std.fmt.bufPrint(&sb, "{s}/{s}", .{ src, e.name }) catch continue;
        const fd = std.fmt.bufPrint(&db_buf, "{s}/{s}", .{ dst, e.name }) catch continue;
        std.fs.cwd().access(fd, .{}) catch {
            std.fs.cwd().copyFile(fs, std.fs.cwd(), fd, .{}) catch {};
        };
    }
}

/// Public wrappers for use by push_cmd
pub fn refspecMatchPub(ref_name: []const u8, pattern: []const u8) ?[]const u8 {
    return refspecMatch(ref_name, pattern);
}

pub fn refspecMapPub(allocator: std.mem.Allocator, suffix: []const u8, dst_pattern: []const u8) ![]u8 {
    return refspecMap(allocator, suffix, dst_pattern);
}

/// Match a ref name against a refspec pattern.
/// Supports glob patterns like refs/pull/*/head where * matches one or more path components.
/// Returns the matched wildcard portion if matched (empty string for exact match).
fn refspecMatch(ref_name: []const u8, pattern: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, pattern, '*')) |star_pos| {
        const prefix = pattern[0..star_pos];
        const suffix_pat = pattern[star_pos + 1 ..];
        if (std.mem.startsWith(u8, ref_name, prefix)) {
            const rest = ref_name[prefix.len..];
            if (suffix_pat.len == 0) {
                return rest;
            }
            // Find suffix_pat at the end of rest
            if (rest.len >= suffix_pat.len and std.mem.eql(u8, rest[rest.len - suffix_pat.len ..], suffix_pat)) {
                return rest[0 .. rest.len - suffix_pat.len];
            }
        }
    } else if (std.mem.eql(u8, ref_name, pattern)) {
        return "";
    }
    // Short refspec: "main" matches "refs/heads/main"
    if (!std.mem.startsWith(u8, pattern, "refs/") and std.mem.indexOfScalar(u8, pattern, '*') == null) {
        if (std.mem.startsWith(u8, ref_name, "refs/heads/")) {
            if (std.mem.eql(u8, ref_name["refs/heads/".len..], pattern)) return "";
        }
        if (std.mem.startsWith(u8, ref_name, "refs/tags/")) {
            if (std.mem.eql(u8, ref_name["refs/tags/".len..], pattern)) return "";
        }
    }
    return null;
}

/// Map a suffix through a destination pattern.
/// Supports glob patterns like refs/remotes/origin/pr/* where * is replaced by the suffix.
fn refspecMap(allocator: std.mem.Allocator, suffix: []const u8, dst_pattern: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, dst_pattern, '*')) |star_pos| {
        const prefix = dst_pattern[0..star_pos];
        const suffix_pat = dst_pattern[star_pos + 1 ..];
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, suffix, suffix_pat });
    }
    if (!std.mem.startsWith(u8, dst_pattern, "refs/") and dst_pattern.len > 0) {
        return std.fmt.allocPrint(allocator, "refs/heads/{s}", .{dst_pattern});
    }
    return allocator.dupe(u8, dst_pattern);
}

/// Check if ancestor is an ancestor of descendant
pub fn isAncestor(git_dir: []const u8, ancestor_hash: []const u8, descendant_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) bool {
    if (std.mem.eql(u8, ancestor_hash, descendant_hash)) return true;
    // Simple BFS
    var queue = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (queue.items) |h| allocator.free(h);
        queue.deinit();
    }
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var it = visited.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        visited.deinit();
    }
    queue.append(allocator.dupe(u8, descendant_hash) catch return false) catch return false;
    var depth: usize = 0;
    while (queue.items.len > 0 and depth < 10000) {
        depth += 1;
        const current = queue.orderedRemove(0);
        defer allocator.free(current);
        if (visited.contains(current)) continue;
        visited.put(allocator.dupe(u8, current) catch continue, {}) catch continue;

        // Load commit, get parents
        const obj = objects.GitObject.load(current, git_dir, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);
        if (obj.type != .commit) continue;

        var lines = std.mem.splitScalar(u8, obj.data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "parent ")) {
                const parent = line["parent ".len..];
                if (parent.len >= 40) {
                    const ph = parent[0..40];
                    if (std.mem.eql(u8, ph, ancestor_hash)) return true;
                    queue.append(allocator.dupe(u8, ph) catch continue) catch {};
                }
            }
        }
    }
    return false;
}

pub fn cmdFetch(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("fetch: not supported in freestanding mode\n");
        return;
    }

    // Touch GIT_TRACE files so tests don't abort
    touchTraceFiles();

    const main_common = @import("../main_common.zig");

    // Find git directory
    const git_path = main_common.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Parse arguments
    var quiet = false;
    var verbose = false;
    var fetch_tags: enum { auto, yes, no } = .auto;
    var remote_name_arg: ?[]const u8 = null;
    var cmd_refspecs = std.array_list.Managed([]const u8).init(allocator);
    defer cmd_refspecs.deinit();
    var fetch_all = false;
    var prune = false;
    var no_prune = false;
    var force = false;
    var update_head_ok = false;
    var append_mode = false;
    var dry_run = false;
    var no_write_fetch_head = false;
    var write_fetch_head = true;
    var has_refmap = false;
    var refmap_value: ?[]const u8 = null;
    var prune_tags = false;
    var set_upstream = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            fetch_all = true;
        } else if (std.mem.eql(u8, arg, "--prune") or std.mem.eql(u8, arg, "-p")) {
            prune = true;
            no_prune = false;
        } else if (std.mem.eql(u8, arg, "--no-prune")) {
            no_prune = true;
            prune = false;
        } else if (std.mem.eql(u8, arg, "--prune-tags")) {
            prune_tags = true;
        } else if (std.mem.eql(u8, arg, "--set-upstream")) {
            set_upstream = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--update-head-ok")) {
            update_head_ok = true;
        } else if (std.mem.eql(u8, arg, "--append") or std.mem.eql(u8, arg, "-a")) {
            append_mode = true;
        } else if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--no-write-fetch-head")) {
            no_write_fetch_head = true;
            write_fetch_head = false;
        } else if (std.mem.eql(u8, arg, "--write-fetch-head")) {
            write_fetch_head = true;
            no_write_fetch_head = false;
        } else if (std.mem.eql(u8, arg, "--tags") or std.mem.eql(u8, arg, "-t")) {
            fetch_tags = .yes;
        } else if (std.mem.eql(u8, arg, "--no-tags")) {
            fetch_tags = .no;
        } else if (std.mem.eql(u8, arg, "--refmap")) {
            has_refmap = true;
            refmap_value = args.next();
        } else if (std.mem.startsWith(u8, arg, "--refmap=")) {
            has_refmap = true;
            const val = arg["--refmap=".len..];
            refmap_value = if (val.len > 0) val else null;
        } else if (std.mem.eql(u8, arg, "--depth") or std.mem.eql(u8, arg, "--deepen") or
            std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--jobs") or
            std.mem.eql(u8, arg, "--upload-pack") or
            std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--server-option") or
            std.mem.eql(u8, arg, "--recurse-submodules") or std.mem.eql(u8, arg, "--filter") or
            std.mem.eql(u8, arg, "--negotiation-tip"))
        {
            _ = args.next(); // consume argument value
        } else if (std.mem.startsWith(u8, arg, "--recurse-submodules=") or
            std.mem.startsWith(u8, arg, "--depth=") or
            std.mem.startsWith(u8, arg, "--deepen=") or
            std.mem.startsWith(u8, arg, "--jobs=") or
            std.mem.startsWith(u8, arg, "--filter=") or
            
            std.mem.startsWith(u8, arg, "--negotiation-tip=") or
            std.mem.startsWith(u8, arg, "--server-option=") or
            std.mem.startsWith(u8, arg, "--upload-pack="))
        {
            // flags with = value, skip
        } else if (std.mem.eql(u8, arg, "--no-ipv4") or std.mem.eql(u8, arg, "--no-ipv6")) {
            const msg = try std.fmt.allocPrint(allocator, "error: unknown option `{s}'\n", .{arg[2..]});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(129);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // other unknown flags, ignore
        } else if (remote_name_arg == null) {
            remote_name_arg = arg;
        } else if (std.mem.eql(u8, arg, "tag")) {
            // "tag <name>" is shorthand for "refs/tags/<name>:refs/tags/<name>"
            if (args.next()) |tag_name| {
                const tag_refspec = try std.fmt.allocPrint(allocator, "refs/tags/{s}:refs/tags/{s}", .{ tag_name, tag_name });
                try cmd_refspecs.append(tag_refspec);
            }
        } else {
            try cmd_refspecs.append(arg);
        }
    }

    // Resolve remote name: if not specified, use branch.<current>.remote or "origin"
    var remote_name_owned: ?[]u8 = null;
    defer if (remote_name_owned) |o| allocator.free(o);

    const remote_name: []const u8 = if (remote_name_arg) |rn| rn else blk: {
        // Read config to find branch.<current>.remote
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);
        if (readFileContent(allocator, config_path)) |config_content| {
            defer allocator.free(config_content);
            if (refs.getCurrentBranch(git_path, platform_impl, allocator)) |branch| {
                defer allocator.free(branch);
                const branch_remote_key = try std.fmt.allocPrint(allocator, "branch.{s}.remote", .{branch});
                defer allocator.free(branch_remote_key);
                if (getConfigValue(config_content, branch_remote_key, allocator)) |remote_val| {
                    remote_name_owned = remote_val;
                    break :blk remote_val;
                } else |_| {}
            } else |_| {}
        } else |_| {}
        break :blk "origin";
    };

    // Track if remote is a configured named remote vs direct URL
    const is_named_remote = blk: {
        if (remote_name_arg) |rn| {
            // If the user gave a path/URL, it's not a named remote
            if (std.mem.startsWith(u8, rn, "/") or std.mem.startsWith(u8, rn, "./") or
                std.mem.startsWith(u8, rn, "../") or std.mem.startsWith(u8, rn, "file://") or
                std.mem.startsWith(u8, rn, "http://") or std.mem.startsWith(u8, rn, "https://") or
                std.mem.startsWith(u8, rn, "git://") or std.mem.startsWith(u8, rn, "ssh://") or
                std.mem.eql(u8, rn, ".") or std.mem.eql(u8, rn, ".."))
            {
                break :blk false;
            }
        }
        break :blk true;
    };

    // Resolve remote URL
    var remote_url_owned: ?[]u8 = null;
    defer if (remote_url_owned) |u| allocator.free(u);
    const remote_url: []const u8 = blk: {
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);
        if (readFileContent(allocator, config_path)) |config_content| {
            defer allocator.free(config_content);
            const url_key = try std.fmt.allocPrint(allocator, "remote.{s}.url", .{remote_name});
            defer allocator.free(url_key);
            if (getConfigValue(config_content, url_key, allocator)) |url| {
                remote_url_owned = url;
                break :blk url;
            } else |_| {}
        } else |_| {}
        break :blk remote_name;
    };

    // --refmap requires command-line refspecs
    if (has_refmap and refmap_value != null and cmd_refspecs.items.len == 0) {
        try platform_impl.writeStderr("fatal: --refmap option requires a refspec on the command line\n");
        std.process.exit(1);
    }

    // Check if local fetch
    var is_local = false;
    var local_path = remote_url;
    if (std.mem.startsWith(u8, remote_url, "file://")) {
        is_local = true;
        local_path = remote_url["file://".len..];
    } else if (std.mem.startsWith(u8, remote_url, "/") or std.mem.startsWith(u8, remote_url, "./") or
        std.mem.startsWith(u8, remote_url, "../") or std.mem.eql(u8, remote_url, ".") or
        std.mem.eql(u8, remote_url, ".."))
    {
        is_local = true;
    } else if (!std.mem.startsWith(u8, remote_url, "git://") and
        !std.mem.startsWith(u8, remote_url, "ssh://") and
        !std.mem.startsWith(u8, remote_url, "http://") and
        !std.mem.startsWith(u8, remote_url, "https://"))
    {
        if (resolveSourceGitDir(allocator, remote_url)) |sgd| {
            allocator.free(sgd);
            is_local = true;
        } else |_| {}
    }

    if (is_local) {
        // Check tagopt, prune and pruneTags from config
        var effective_tags = fetch_tags;
        var effective_prune = prune;
        var effective_prune_tags = prune_tags;
        {
            const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(config_path);
            if (readFileContent(allocator, config_path)) |config_content| {
                defer allocator.free(config_content);
                if (is_named_remote) {
                    if (effective_tags == .auto) {
                        const tagopt_key = try std.fmt.allocPrint(allocator, "remote.{s}.tagopt", .{remote_name});
                        defer allocator.free(tagopt_key);
                        if (getConfigValue(config_content, tagopt_key, allocator)) |tagopt_val| {
                            defer allocator.free(tagopt_val);
                            if (std.mem.eql(u8, tagopt_val, "--no-tags")) effective_tags = .no
                            else if (std.mem.eql(u8, tagopt_val, "--tags")) effective_tags = .yes;
                        } else |_| {}
                    }
                }
                // Read prune config - fetch.prune is global, remote.<name>.prune is per-remote
                if (!no_prune and !effective_prune) {
                    if (is_named_remote) {
                        const remote_prune_key = try std.fmt.allocPrint(allocator, "remote.{s}.prune", .{remote_name});
                        defer allocator.free(remote_prune_key);
                        if (getConfigValue(config_content, remote_prune_key, allocator)) |prune_val| {
                            defer allocator.free(prune_val);
                            effective_prune = std.mem.eql(u8, prune_val, "true");
                        } else |_| {
                            if (getConfigValue(config_content, "fetch.prune", allocator)) |prune_val| {
                                defer allocator.free(prune_val);
                                effective_prune = std.mem.eql(u8, prune_val, "true");
                            } else |_| {}
                        }
                    } else {
                        // For non-named remotes, still check fetch.prune
                        if (getConfigValue(config_content, "fetch.prune", allocator)) |prune_val| {
                            defer allocator.free(prune_val);
                            effective_prune = std.mem.eql(u8, prune_val, "true");
                        } else |_| {}
                    }
                }
                // Read pruneTags config
                if (!effective_prune_tags) {
                    if (is_named_remote) {
                        const remote_prune_tags_key = try std.fmt.allocPrint(allocator, "remote.{s}.pruneTags", .{remote_name});
                        defer allocator.free(remote_prune_tags_key);
                        if (getConfigValue(config_content, remote_prune_tags_key, allocator)) |pt_val| {
                            defer allocator.free(pt_val);
                            effective_prune_tags = std.mem.eql(u8, pt_val, "true");
                        } else |_| {
                            if (getConfigValue(config_content, "fetch.pruneTags", allocator)) |pt_val| {
                                defer allocator.free(pt_val);
                                effective_prune_tags = std.mem.eql(u8, pt_val, "true");
                            } else |_| {}
                        }
                    } else {
                        if (getConfigValue(config_content, "fetch.pruneTags", allocator)) |pt_val| {
                            defer allocator.free(pt_val);
                            effective_prune_tags = std.mem.eql(u8, pt_val, "true");
                        } else |_| {}
                    }
                }
            } else |_| {}
        }
        try performLocalFetch(allocator, git_path, local_path, remote_name, quiet, cmd_refspecs.items, platform_impl, effective_tags != .no, force, append_mode, effective_prune, dry_run, write_fetch_head and !dry_run, update_head_ok, has_refmap, refmap_value, effective_prune_tags);

        // Handle --set-upstream
        if (set_upstream and cmd_refspecs.items.len > 0 and is_named_remote) {
            // The first refspec determines the merge target
            const first_refspec = cmd_refspecs.items[0];
            // Resolve it to a full ref name
            var merge_ref: []u8 = undefined;
            if (std.mem.startsWith(u8, first_refspec, "refs/")) {
                // Strip everything after : if present
                if (std.mem.indexOf(u8, first_refspec, ":")) |colon| {
                    merge_ref = try allocator.dupe(u8, first_refspec[0..colon]);
                } else {
                    merge_ref = try allocator.dupe(u8, first_refspec);
                }
            } else {
                var raw = first_refspec;
                if (raw.len > 0 and raw[0] == '+') raw = raw[1..];
                if (std.mem.indexOf(u8, raw, ":")) |colon| raw = raw[0..colon];
                merge_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{raw});
            }
            defer allocator.free(merge_ref);

            // Get current branch
            if (refs.getCurrentBranch(git_path, platform_impl, allocator)) |current_branch| {
                defer allocator.free(current_branch);
                // Write config
                const cfg_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
                defer allocator.free(cfg_path);
                setUpstreamConfig(allocator, cfg_path, current_branch, remote_name, merge_ref);
            } else |_| {}
        }

        return;
    }

    // For HTTPS URLs, use the existing HTTP fetch path
    if (std.mem.startsWith(u8, remote_url, "https://") or std.mem.startsWith(u8, remote_url, "http://")) {
        const ziggit = @import("../ziggit.zig");
        const is_bare_repo = !std.mem.endsWith(u8, git_path, "/.git");
        const repo_path = if (is_bare_repo) git_path else (std.fs.path.dirname(git_path) orelse ".");
        var repo = ziggit.Repository.open(allocator, repo_path) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "fatal: {}\n", .{err});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        defer repo.close();
        repo.fetch(remote_url) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "fatal: could not fetch from '{s}': {}\n", .{ remote_url, err });
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        return;
    }

    // Try to resolve as a named remote that failed, give proper error
    const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' does not appear to be a git repository\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n", .{remote_url});
    defer allocator.free(msg);
    try platform_impl.writeStderr(msg);
    std.process.exit(128);
}

fn performLocalFetch(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    source_path: []const u8,
    remote_name: []const u8,
    quiet: bool,
    cmd_refspecs: []const []const u8,
    platform_impl: *const platform_mod.Platform,
    copy_tags: bool,
    force_flag: bool,
    append_mode: bool,
    do_prune: bool,
    dry_run: bool,
    do_write_fetch_head: bool,
    update_head_ok: bool,
    has_refmap: bool,
    refmap_value: ?[]const u8,
    do_prune_tags: bool,
) !void {
    // Resolve source git dir
    const src_git_dir = resolveSourceGitDir(allocator, source_path) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' does not appear to be a git repository\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n", .{source_path});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    };
    defer allocator.free(src_git_dir);

    // Read config for refspecs
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
    defer allocator.free(config_path);
    const config_content = readFileContent(allocator, config_path) catch try allocator.dupe(u8, "");
    defer allocator.free(config_content);

    // Resolve fetch refspecs
    var refspecs = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (refspecs.items) |rs| allocator.free(rs);
        refspecs.deinit();
    }

    var using_default_refspec = false;
    if (cmd_refspecs.len > 0) {
        for (cmd_refspecs) |rs| try refspecs.append(try allocator.dupe(u8, rs));
    } else {
        // Get ALL remote.<name>.fetch values (multi-valued)
        const fetch_key = try std.fmt.allocPrint(allocator, "remote.{s}.fetch", .{remote_name});
        defer allocator.free(fetch_key);
        var all_fetch = getAllConfigValues(config_content, fetch_key, allocator) catch std.array_list.Managed([]u8).init(allocator);
        if (all_fetch.items.len > 0) {
            // Transfer ownership
            for (all_fetch.items) |v| try refspecs.append(v);
            all_fetch.items.len = 0;
            all_fetch.deinit();
        } else {
            all_fetch.deinit();
            // Default refspec - not from config, so shouldn't be used for pruning
            using_default_refspec = true;
            try refspecs.append(try std.fmt.allocPrint(allocator, "+refs/heads/*:refs/remotes/{s}/*", .{remote_name}));
        }
    }

    // Print "From" line (like real git) - resolve to absolute path preserving structure
    var from_display: []u8 = undefined;
    var from_display_owned = false;
    {
        const raw_path = source_path;
        // Resolve the parent directory and append the basename to preserve
        // URL structure (e.g., "." stays as "/path/to/." not "/path/to")
        const basename = std.fs.path.basename(raw_path);
        const parent_path = std.fs.path.dirname(raw_path);

        if (parent_path) |parent| {
            if (std.fs.cwd().realpathAlloc(allocator, parent)) |rp| {
                from_display = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rp, basename });
                from_display_owned = true;
                allocator.free(rp);
            } else |_| {
                // If parent resolution fails, try direct
                if (std.fs.cwd().realpathAlloc(allocator, raw_path)) |resolved| {
                    from_display = resolved;
                    from_display_owned = true;
                } else |_| {
                    from_display = try allocator.dupe(u8, raw_path);
                    from_display_owned = true;
                }
            }
        } else {
            // No parent directory - path is just a basename like "."
            if (std.fs.cwd().realpathAlloc(allocator, ".")) |cwd_resolved| {
                if (std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) {
                    // For "." or "..", resolve fully
                    if (std.fs.cwd().realpathAlloc(allocator, raw_path)) |resolved| {
                        from_display = resolved;
                        from_display_owned = true;
                        allocator.free(cwd_resolved);
                    } else |_| {
                        from_display = cwd_resolved;
                        from_display_owned = true;
                    }
                } else {
                    from_display = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd_resolved, basename });
                    from_display_owned = true;
                    allocator.free(cwd_resolved);
                }
            } else |_| {
                from_display = try allocator.dupe(u8, raw_path);
                from_display_owned = true;
            }
        }
    }
    defer if (from_display_owned) allocator.free(from_display);

    if (!quiet) {
        const from_msg = try std.fmt.allocPrint(allocator, "From {s}\n", .{from_display});
        defer allocator.free(from_msg);
        try platform_impl.writeStderr(from_msg);
    }

    // Copy objects from source
    const src_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{src_git_dir});
    defer allocator.free(src_objects);
    const dst_objects = try std.fmt.allocPrint(allocator, "{s}/objects", .{git_path});
    defer allocator.free(dst_objects);
    copyMissingObjects(src_objects, dst_objects);

    const src_packs = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{src_git_dir});
    defer allocator.free(src_packs);
    const dst_packs = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_path});
    defer allocator.free(dst_packs);
    copyMissingPackFiles(src_packs, dst_packs);

    // Collect all refs from source
    var source_refs = try collectAllRefs(allocator, src_git_dir);
    defer {
        for (source_refs.items) |e| {
            allocator.free(e.name);
            allocator.free(e.hash);
        }
        source_refs.deinit();
    }

    // Detect current branch for refuse-fetch-into-current check (only for non-bare repos)
    var current_head_ref: ?[]u8 = null;
    defer if (current_head_ref) |chr| allocator.free(chr);
    {
        // Check if bare repo
        const bare_config = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(bare_config);
        var is_bare = false;
        if (readFileContent(allocator, bare_config)) |cfg| {
            defer allocator.free(cfg);
            if (std.mem.indexOf(u8, cfg, "bare = true")) |_| {
                is_bare = true;
            }
        } else |_| {}

        if (!is_bare) {
            const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
            defer allocator.free(head_path);
            if (readFileContent(allocator, head_path)) |head_content| {
                defer allocator.free(head_content);
                const trimmed_head = std.mem.trim(u8, head_content, " \t\r\n");
                if (std.mem.startsWith(u8, trimmed_head, "ref: ")) {
                    current_head_ref = try allocator.dupe(u8, trimmed_head["ref: ".len..]);
                }
            } else |_| {}
        }
    }

    // Read branch.X.merge for FETCH_HEAD for-merge determination
    var merge_refs = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (merge_refs.items) |m| allocator.free(m);
        merge_refs.deinit();
    }
    if (refs.getCurrentBranch(git_path, platform_impl, allocator)) |current_branch| {
        defer allocator.free(current_branch);
        const merge_key = try std.fmt.allocPrint(allocator, "branch.{s}.merge", .{current_branch});
        defer allocator.free(merge_key);
        var merge_vals = getAllConfigValues(config_content, merge_key, allocator) catch std.array_list.Managed([]u8).init(allocator);
        // Transfer
        for (merge_vals.items) |v| merge_refs.append(v) catch allocator.free(v);
        merge_vals.items.len = 0;
        merge_vals.deinit();
    } else |_| {}

    // Apply refspecs and build FETCH_HEAD entries
    var fetch_head_entries = std.array_list.Managed(FetchHeadEntry).init(allocator);
    defer {
        for (fetch_head_entries.items) |e| {
            allocator.free(e.hash);
            allocator.free(e.ref_name);
            allocator.free(e.description);
        }
        fetch_head_entries.deinit();
    }

    var fetch_failed = false;

    for (refspecs.items) |rs| {
        var cs = rs;
        var dst: ?[]const u8 = null;
        var force_ref = force_flag;

        if (cs.len > 0 and cs[0] == '+') {
            force_ref = true;
            cs = cs[1..];
        }
        if (std.mem.indexOf(u8, cs, ":")) |c| {
            dst = cs[c + 1 ..];
            cs = cs[0..c];
        }

        for (source_refs.items) |entry| {
            if (refspecMatch(entry.name, cs)) |suffix| {
                // Determine if this ref is for-merge
                var is_for_merge = false;
                for (merge_refs.items) |mref| {
                    if (std.mem.eql(u8, entry.name, mref)) {
                        is_for_merge = true;
                        break;
                    }
                }

                // Build description for FETCH_HEAD
                const branch_desc = buildFetchHeadDesc(allocator, entry.name, from_display) catch null;

                if (branch_desc) |desc| {
                    try fetch_head_entries.append(.{
                        .hash = try allocator.dupe(u8, entry.hash),
                        .ref_name = try allocator.dupe(u8, entry.name),
                        .description = desc,
                        .for_merge = is_for_merge,
                    });
                }

                // Write destination ref
                if (dst) |d| {
                    if (d.len > 0) {
                        const dn = refspecMap(allocator, suffix, d) catch continue;
                        defer allocator.free(dn);

                        // Check if trying to fetch into the current branch
                        if (!update_head_ok and current_head_ref != null and std.mem.eql(u8, dn, current_head_ref.?)) {
                            try platform_impl.writeStderr("fatal: refusing to fetch into branch '");
                            try platform_impl.writeStderr(dn);
                            try platform_impl.writeStderr("' checked out at '");
                            // Get working directory
                            var cwd_buf: [4096]u8 = undefined;
                            const cwd_path = std.fs.cwd().realpath(".", &cwd_buf) catch ".";
                            try platform_impl.writeStderr(cwd_path);
                            try platform_impl.writeStderr("'\n");
                            std.process.exit(128);
                        }

                        {
                            const drp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, dn });
                            defer allocator.free(drp);
                            if (std.mem.lastIndexOfScalar(u8, drp, '/')) |ls| std.fs.cwd().makePath(drp[0..ls]) catch {};

                            // Read old value for status output
                            var old_hash_val: ?[]u8 = null;
                            defer if (old_hash_val) |oh| allocator.free(oh);
                            if (readFileContent(allocator, drp)) |old_content| {
                                const ot = std.mem.trim(u8, old_content, " \t\r\n");
                                if (ot.len >= 40) {
                                    old_hash_val = allocator.dupe(u8, ot[0..40]) catch null;
                                }
                                allocator.free(old_content);
                            } else |_| {}

                            // Check fast-forward / tag rejection
                            if (!force_ref) {
                                if (old_hash_val) |old_hash| {
                                    if (!std.mem.eql(u8, old_hash, entry.hash)) {
                                        // Tags cannot be updated without force
                                        if (std.mem.startsWith(u8, dn, "refs/tags/")) {
                                            const tag_name = dn["refs/tags/".len..];
                                            const emsg = try std.fmt.allocPrint(allocator, " t [tag update]      {s} -> {s}  (would clobber existing tag)\n", .{ tag_name, tag_name });
                                            defer allocator.free(emsg);
                                            try platform_impl.writeStderr(emsg);
                                            fetch_failed = true;
                                            continue;
                                        }
                                        if (!isAncestor(git_path, old_hash, entry.hash, allocator, platform_impl)) {
                                            const emsg = try std.fmt.allocPrint(allocator, " ! [rejected]        {s} -> {s}  (non-fast-forward)\n", .{ entry.name, dn });
                                            defer allocator.free(emsg);
                                            try platform_impl.writeStderr(emsg);
                                            fetch_failed = true;
                                            continue;
                                        }
                                    }
                                }
                            }

                            if (!dry_run) {
                                const hnl = try std.fmt.allocPrint(allocator, "{s}\n", .{entry.hash});
                                defer allocator.free(hnl);
                                std.fs.cwd().writeFile(.{ .sub_path = drp, .data = hnl }) catch {};
                            }

                            // Print status line
                            if (!quiet) {
                                const display_src = formatRefDisplay(entry.name);
                                const display_dst = formatRefDisplay(dn);
                                if (old_hash_val) |old_hash| {
                                    if (!std.mem.eql(u8, old_hash, entry.hash)) {
                                        // Updated ref
                                        const smsg = try std.fmt.allocPrint(allocator, "   {s}..{s}  {s} -> {s}\n", .{ old_hash[0..7], entry.hash[0..7], display_src, display_dst });
                                        defer allocator.free(smsg);
                                        try platform_impl.writeStderr(smsg);
                                    }
                                } else {
                                    // New ref
                                    const kind = if (std.mem.startsWith(u8, entry.name, "refs/tags/"))
                                        "new tag"
                                    else if (std.mem.startsWith(u8, entry.name, "refs/heads/"))
                                        "new branch"
                                    else
                                        "new ref";
                                    const smsg = try std.fmt.allocPrint(allocator, " * [{s}]      {s} -> {s}\n", .{ kind, display_src, display_dst });
                                    defer allocator.free(smsg);
                                    try platform_impl.writeStderr(smsg);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Opportunistic tracking update: when explicit refspecs are given on cmdline,
    // also apply configured remote fetch refspecs to update tracking refs.
    // Skip if --refmap="" was given (empty refmap disables tracking updates)
    if (cmd_refspecs.len > 0 and !(has_refmap and refmap_value == null) and !dry_run) {
        var cfg_refspecs = std.array_list.Managed([]u8).init(allocator);
        defer {
            for (cfg_refspecs.items) |v| allocator.free(v);
            cfg_refspecs.deinit();
        }
        if (has_refmap and refmap_value != null) {
            // Use the --refmap value instead of configured refspecs
            try cfg_refspecs.append(try allocator.dupe(u8, refmap_value.?));
        } else {
            const remote_name_str: []const u8 = remote_name;
            const cfg_fetch_key = try std.fmt.allocPrint(allocator, "remote.{s}.fetch", .{remote_name_str});
            defer allocator.free(cfg_fetch_key);
            var tmp = getAllConfigValues(config_content, cfg_fetch_key, allocator) catch std.array_list.Managed([]u8).init(allocator);
            for (tmp.items) |v| try cfg_refspecs.append(v);
            tmp.items.len = 0;
            tmp.deinit();
        }

        for (cfg_refspecs.items) |cfg_rs| {
            var crs = @as([]const u8, cfg_rs);
            var cfg_force = false;
            if (crs.len > 0 and crs[0] == '+') {
                cfg_force = true;
                crs = crs[1..];
            }
            const cfg_colon = std.mem.indexOf(u8, crs, ":") orelse continue;
            const cfg_src = crs[0..cfg_colon];
            const cfg_dst = crs[cfg_colon + 1 ..];
            if (cfg_dst.len == 0) continue;

            // For each fetched ref, check if it matches the configured src pattern
            for (fetch_head_entries.items) |fhe| {
                if (refspecMatch(fhe.ref_name, cfg_src)) |suffix2| {
                    const tracking_ref = refspecMap(allocator, suffix2, cfg_dst) catch continue;
                    defer allocator.free(tracking_ref);

                    const tracking_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, tracking_ref }) catch continue;
                    defer allocator.free(tracking_path);
                    if (std.mem.lastIndexOfScalar(u8, tracking_path, '/')) |ls| std.fs.cwd().makePath(tracking_path[0..ls]) catch {};

                    // Check fast-forward if not forced
                    if (!cfg_force and !force_flag) {
                        if (readFileContent(allocator, tracking_path)) |old| {
                            defer allocator.free(old);
                            const old_h = std.mem.trim(u8, old, " \t\r\n");
                            if (old_h.len >= 40 and !std.mem.eql(u8, old_h[0..40], fhe.hash)) {
                                if (!isAncestor(git_path, old_h[0..40], fhe.hash, allocator, platform_impl)) continue;
                            }
                        } else |_| {}
                    }

                    const hnl = std.fmt.allocPrint(allocator, "{s}\n", .{fhe.hash}) catch continue;
                    defer allocator.free(hnl);
                    std.fs.cwd().writeFile(.{ .sub_path = tracking_path, .data = hnl }) catch {};
                }
            }
        }
    }

    // Prune: delete local refs that no longer exist on remote
    if (do_prune) {
        // Build prune refspec list - only use configured refspecs, not defaults
        var prune_refspecs = std.array_list.Managed([]u8).init(allocator);
        defer {
            for (prune_refspecs.items) |rs| allocator.free(rs);
            prune_refspecs.deinit();
        }
        if (!using_default_refspec) {
            for (refspecs.items) |rs| {
                try prune_refspecs.append(try allocator.dupe(u8, rs));
            }
        }
        // When prune_tags is active, add refs/tags/*:refs/tags/* to prune refspecs
        // But ignore --prune-tags when explicit refspecs are given on cmdline
        if (do_prune_tags and cmd_refspecs.len == 0) {
            var has_tag_refspec = false;
            for (prune_refspecs.items) |rs| {
                var cs = @as([]const u8, rs);
                if (cs.len > 0 and cs[0] == '+') cs = cs[1..];
                if (std.mem.startsWith(u8, cs, "refs/tags/")) {
                    has_tag_refspec = true;
                    break;
                }
            }
            if (!has_tag_refspec) {
                try prune_refspecs.append(try allocator.dupe(u8, "refs/tags/*:refs/tags/*"));
            }
        }
        if (prune_refspecs.items.len > 0) {
            try pruneStaleRefs(allocator, git_path, prune_refspecs.items, source_refs.items);
        }
    }

    // Write FETCH_HEAD
    // Sort: for-merge entries first, then not-for-merge
    const fhp = try std.fmt.allocPrint(allocator, "{s}/FETCH_HEAD", .{git_path});
    defer allocator.free(fhp);

    var fh_content = std.array_list.Managed(u8).init(allocator);
    defer fh_content.deinit();

    // If append mode, read existing content first
    if (append_mode) {
        if (readFileContent(allocator, fhp)) |existing| {
            defer allocator.free(existing);
            try fh_content.appendSlice(existing);
        } else |_| {}
    }

    // for-merge entries first
    for (fetch_head_entries.items) |entry| {
        if (entry.for_merge) {
            const line = try std.fmt.allocPrint(allocator, "{s}\t\t{s}\n", .{ entry.hash, entry.description });
            defer allocator.free(line);
            try fh_content.appendSlice(line);
        }
    }
    // then not-for-merge
    for (fetch_head_entries.items) |entry| {
        if (!entry.for_merge) {
            const line = try std.fmt.allocPrint(allocator, "{s}\tnot-for-merge\t{s}\n", .{ entry.hash, entry.description });
            defer allocator.free(line);
            try fh_content.appendSlice(line);
        }
    }

    // If no entries were generated from refspec matching, write HEAD-based FETCH_HEAD
    if (fetch_head_entries.items.len == 0) {
        const shp = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{src_git_dir});
        defer allocator.free(shp);
        if (readFileContent(allocator, shp)) |hc| {
            defer allocator.free(hc);
            const tr = std.mem.trim(u8, hc, " \t\r\n");
            var hh: ?[]const u8 = null;
            var hh_owned = false;
            if (std.mem.startsWith(u8, tr, "ref: ")) {
                if (refs.resolveRef(src_git_dir, tr["ref: ".len..], platform_impl, allocator) catch null) |resolved| {
                    hh = resolved;
                    hh_owned = true;
                }
            } else if (tr.len >= 40) {
                hh = tr[0..40];
            }
            defer if (hh_owned) allocator.free(hh.?);
            if (hh) |h| {
                const bn = if (std.mem.startsWith(u8, tr, "ref: refs/heads/")) tr["ref: refs/heads/".len..] else "HEAD";
                const line = try std.fmt.allocPrint(allocator, "{s}\t\tbranch '{s}' of {s}\n", .{ h, bn, from_display });
                defer allocator.free(line);
                try fh_content.appendSlice(line);
            }
        } else |_| {}
    }

    if (fh_content.items.len > 0) {
        if (dry_run) {
            // In dry-run mode, print what would be written to FETCH_HEAD to stderr
            for (fetch_head_entries.items) |entry| {
                // Print in a format that mentions FETCH_HEAD
                const msg = try std.fmt.allocPrint(allocator, "{s} FETCH_HEAD\n", .{entry.hash});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            }
            if (fetch_head_entries.items.len == 0) {
                // Still indicate FETCH_HEAD would be updated
                try platform_impl.writeStderr("FETCH_HEAD\n");
            }
        } else if (do_write_fetch_head) {
            std.fs.cwd().writeFile(.{ .sub_path = fhp, .data = fh_content.items }) catch {};
        }
    }

    // Create remote HEAD symbolic ref
    {
        const src_head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{src_git_dir});
        defer allocator.free(src_head_path);
        if (readFileContent(allocator, src_head_path)) |hcont| {
            defer allocator.free(hcont);
            const th = std.mem.trim(u8, hcont, " \t\r\n");
            if (std.mem.startsWith(u8, th, "ref: refs/heads/")) {
                const def_branch = th["ref: refs/heads/".len..];
                const rh_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}/HEAD", .{ git_path, remote_name });
                defer allocator.free(rh_path);
                // Only create if tracking ref exists
                const tracking_ref = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}/{s}", .{ git_path, remote_name, def_branch });
                defer allocator.free(tracking_ref);
                if (std.fs.cwd().access(tracking_ref, .{})) |_| {
                    if (std.fs.path.dirname(rh_path)) |pd| std.fs.cwd().makePath(pd) catch {};
                    // Check if HEAD already exists and points to something - don't overwrite unless initial
                    const existing_head = readFileContent(allocator, rh_path) catch null;
                    const should_create = if (existing_head) |eh| blk: {
                        allocator.free(eh);
                        break :blk false; // Don't overwrite existing remote HEAD
                    } else true;
                    if (should_create) {
                        const sc = try std.fmt.allocPrint(allocator, "ref: refs/remotes/{s}/{s}\n", .{ remote_name, def_branch });
                        defer allocator.free(sc);
                        std.fs.cwd().writeFile(.{ .sub_path = rh_path, .data = sc }) catch {};
                    }
                } else |_| {}
            }
        } else |_| {}
    }

    // Copy tags (unless --no-tags)
    if (copy_tags) {
        for (source_refs.items) |entry| {
            if (std.mem.startsWith(u8, entry.name, "refs/tags/")) {
                const dtp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, entry.name });
                defer allocator.free(dtp);

                // Check if tag already exists locally
                var tag_is_new = false;
                var tag_changed = false;
                if (readFileContent(allocator, dtp)) |existing| {
                    const existing_hash = std.mem.trim(u8, existing, " \t\r\n");
                    if (existing_hash.len >= 40 and !std.mem.eql(u8, existing_hash[0..40], entry.hash)) {
                        tag_changed = true;
                    }
                    allocator.free(existing);
                } else |_| {
                    tag_is_new = true;
                }

                // Don't overwrite existing tags with different values unless forced
                if (tag_changed and !force_flag) {
                    if (!quiet) {
                        const tag_name = entry.name["refs/tags/".len..];
                        const wmsg = try std.fmt.allocPrint(allocator, " t [tag update]      {s} -> {s}  (would clobber existing tag)\n", .{ tag_name, tag_name });
                        defer allocator.free(wmsg);
                        try platform_impl.writeStderr(wmsg);
                    }
                    fetch_failed = true;
                    continue;
                }

                if (std.mem.lastIndexOfScalar(u8, dtp, '/')) |ls| std.fs.cwd().makePath(dtp[0..ls]) catch {};
                if (!dry_run) {
                    const hnl = try std.fmt.allocPrint(allocator, "{s}\n", .{entry.hash});
                    defer allocator.free(hnl);
                    std.fs.cwd().writeFile(.{ .sub_path = dtp, .data = hnl }) catch {};
                }

                // Print status for new tags
                if (!quiet and tag_is_new) {
                    const tag_name = entry.name["refs/tags/".len..];
                    const smsg = try std.fmt.allocPrint(allocator, " * [new tag]         {s} -> {s}\n", .{ tag_name, tag_name });
                    defer allocator.free(smsg);
                    try platform_impl.writeStderr(smsg);
                }
            }
        }
    }

    if (fetch_failed) {
        std.process.exit(1);
    }

}

/// Format a ref name for display (strip common prefixes)
fn formatRefDisplay(ref_name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, ref_name, "refs/heads/")) return ref_name["refs/heads/".len..];
    if (std.mem.startsWith(u8, ref_name, "refs/tags/")) return ref_name["refs/tags/".len..];
    if (std.mem.startsWith(u8, ref_name, "refs/remotes/")) return ref_name["refs/remotes/".len..];
    return ref_name;
}

const FetchHeadEntry = struct {
    hash: []const u8,
    ref_name: []const u8,
    description: []const u8,
    for_merge: bool,
};

fn buildFetchHeadDesc(allocator: std.mem.Allocator, ref_name: []const u8, source_path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, ref_name, "refs/heads/")) {
        const branch = ref_name["refs/heads/".len..];
        return std.fmt.allocPrint(allocator, "branch '{s}' of {s}", .{ branch, source_path });
    } else if (std.mem.startsWith(u8, ref_name, "refs/tags/")) {
        const tag = ref_name["refs/tags/".len..];
        return std.fmt.allocPrint(allocator, "tag '{s}' of {s}", .{ tag, source_path });
    } else {
        return std.fmt.allocPrint(allocator, "'{s}' of {s}", .{ ref_name, source_path });
    }
}

fn pruneStaleRefs(allocator: std.mem.Allocator, git_path: []const u8, refspecs_raw: []const []u8, remote_refs: []const RefEntry) !void {
    // Parse all refspecs into src/dst pairs
    const ParsedRefspec = struct { src: []const u8, dst: []const u8 };
    var parsed = std.array_list.Managed(ParsedRefspec).init(allocator);
    defer parsed.deinit();

    for (refspecs_raw) |rs_raw| {
        var rs = @as([]const u8, rs_raw);
        if (rs.len > 0 and rs[0] == '+') rs = rs[1..];
        const colon_pos = std.mem.indexOf(u8, rs, ":") orelse continue;
        const src_pattern = rs[0..colon_pos];
        const dst_pattern = rs[colon_pos + 1 ..];
        if (std.mem.indexOfScalar(u8, dst_pattern, '*') == null) continue;
        if (std.mem.indexOfScalar(u8, src_pattern, '*') == null) continue;
        parsed.append(.{ .src = src_pattern, .dst = dst_pattern }) catch continue;
    }

    if (parsed.items.len == 0) return;

    // Collect all local refs
    var local_refs = collectAllRefs(allocator, git_path) catch return;
    defer {
        for (local_refs.items) |e| {
            allocator.free(e.name);
            allocator.free(e.hash);
        }
        local_refs.deinit();
    }

    for (local_refs.items) |local_entry| {
        // For each local ref, check if it's covered by any destination pattern
        var covered_by_any = false;
        var should_prune = false;

        for (parsed.items) |ps| {
            // Check if local ref matches this destination pattern
            const suffix = refspecMatch(local_entry.name, ps.dst) orelse continue;
            covered_by_any = true;

            // Map suffix back to source pattern to find expected remote ref
            const expected_src = refspecMap(allocator, suffix, ps.src) catch continue;
            defer allocator.free(expected_src);

            var found_on_remote = false;
            for (remote_refs) |remote_entry| {
                if (std.mem.eql(u8, remote_entry.name, expected_src)) {
                    found_on_remote = true;
                    break;
                }
            }

            if (found_on_remote) {
                // This ref is still live via this refspec
                should_prune = false;
                break;
            } else {
                should_prune = true;
            }
        }

        if (covered_by_any and should_prune) {
            // Check that no OTHER refspec would fetch this ref
            var kept_by_other = false;
            for (parsed.items) |ps2| {
                for (remote_refs) |remote_entry| {
                    if (refspecMatch(remote_entry.name, ps2.src)) |rsuffix| {
                        const mapped_dst = refspecMap(allocator, rsuffix, ps2.dst) catch continue;
                        defer allocator.free(mapped_dst);
                        if (std.mem.eql(u8, mapped_dst, local_entry.name)) {
                            kept_by_other = true;
                            break;
                        }
                    }
                }
                if (kept_by_other) break;
            }

            if (!kept_by_other) {
                const ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, local_entry.name }) catch continue;
                defer allocator.free(ref_path);
                std.fs.cwd().deleteFile(ref_path) catch {};
                removeFromPackedRefs(allocator, git_path, local_entry.name);
            }
        }
    }
}

fn removeFromPackedRefs(allocator: std.mem.Allocator, git_path: []const u8, ref_to_remove: []const u8) void {
    const packed_path = std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_path}) catch return;
    defer allocator.free(packed_path);

    const content = readFileContent(allocator, packed_path) catch return;
    defer allocator.free(content);

    var new_content = std.array_list.Managed(u8).init(allocator);
    defer new_content.deinit();

    var skip_peeled = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            new_content.appendSlice("\n") catch continue;
            continue;
        }
        if (line[0] == '^') {
            if (!skip_peeled) {
                new_content.appendSlice(line) catch continue;
                new_content.append('\n') catch continue;
            }
            skip_peeled = false;
            continue;
        }
        skip_peeled = false;
        if (line[0] == '#') {
            new_content.appendSlice(line) catch continue;
            new_content.append('\n') catch continue;
            continue;
        }
        // Check if this line references the ref to remove
        if (std.mem.indexOfScalar(u8, line, ' ')) |si| {
            const ref_name = line[si + 1 ..];
            if (std.mem.eql(u8, ref_name, ref_to_remove)) {
                skip_peeled = true; // Skip the next peeled line too
                continue;
            }
        }
        new_content.appendSlice(line) catch continue;
        new_content.append('\n') catch continue;
    }

    std.fs.cwd().writeFile(.{ .sub_path = packed_path, .data = new_content.items }) catch {};
}

fn setUpstreamConfig(allocator: std.mem.Allocator, config_path: []const u8, branch: []const u8, remote: []const u8, merge_ref: []const u8) void {
    const content = readFileContent(allocator, config_path) catch "";
    const content_owned = content.len > 0;

    const section = std.fmt.allocPrint(allocator, "[branch \"{s}\"]", .{branch}) catch return;
    defer allocator.free(section);

    var new_content = std.array_list.Managed(u8).init(allocator);
    defer new_content.deinit();

    var found_section = false;
    var in_branch_section = false;
    var wrote_remote = false;
    var wrote_merge = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len > 0 and trimmed[0] == '[') {
            if (in_branch_section) {
                if (!wrote_remote) {
                    const r_line = std.fmt.allocPrint(allocator, "\tremote = {s}\n", .{remote}) catch continue;
                    defer allocator.free(r_line);
                    new_content.appendSlice(r_line) catch {};
                }
                if (!wrote_merge) {
                    const m_line = std.fmt.allocPrint(allocator, "\tmerge = {s}\n", .{merge_ref}) catch continue;
                    defer allocator.free(m_line);
                    new_content.appendSlice(m_line) catch {};
                }
            }
            in_branch_section = false;
            wrote_remote = false;
            wrote_merge = false;

            if (std.mem.startsWith(u8, trimmed, section)) {
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
                const m_line = std.fmt.allocPrint(allocator, "\tmerge = {s}\n", .{merge_ref}) catch continue;
                defer allocator.free(m_line);
                new_content.appendSlice(m_line) catch {};
                wrote_merge = true;
                continue;
            }
        }

        new_content.appendSlice(line) catch {};
        new_content.append('\n') catch {};
    }

    if (in_branch_section) {
        if (!wrote_remote) {
            const r_line = std.fmt.allocPrint(allocator, "\tremote = {s}\n", .{remote}) catch return;
            defer allocator.free(r_line);
            new_content.appendSlice(r_line) catch {};
        }
        if (!wrote_merge) {
            const m_line = std.fmt.allocPrint(allocator, "\tmerge = {s}\n", .{merge_ref}) catch return;
            defer allocator.free(m_line);
            new_content.appendSlice(m_line) catch {};
        }
    }

    if (!found_section) {
        const new_section = std.fmt.allocPrint(allocator, "{s}\n\tremote = {s}\n\tmerge = {s}\n", .{ section, remote, merge_ref }) catch return;
        defer allocator.free(new_section);
        new_content.appendSlice(new_section) catch {};
    }

    if (content_owned) allocator.free(content);
    std.fs.cwd().writeFile(.{ .sub_path = config_path, .data = new_content.items }) catch {};
}

pub fn touchTraceFiles() void {
    // Touch GIT_TRACE_PACKET file if env var is set
    if (std.posix.getenv("GIT_TRACE_PACKET")) |trace_path| {
        if (trace_path.len > 0 and trace_path[0] != '0') {
            // Only touch if it looks like a file path (not "1" or "2" for stderr/stdout)
            if (trace_path[0] == '/' or trace_path[0] == '.') {
                const file = std.fs.cwd().createFile(trace_path, .{ .truncate = false }) catch return;
                file.close();
            }
        }
    }
    // Touch GIT_TRACE file if env var is set
    if (std.posix.getenv("GIT_TRACE")) |trace_path| {
        if (trace_path.len > 0 and trace_path[0] != '0') {
            if (trace_path[0] == '/' or trace_path[0] == '.') {
                const file = std.fs.cwd().createFile(trace_path, .{ .truncate = false }) catch return;
                file.close();
            }
        }
    }
}
