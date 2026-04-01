const git_helpers_mod = @import("../git_helpers.zig");
const std = @import("std");
const platform_mod = @import("../platform/platform.zig");
const succinct_mod = @import("../succinct.zig");
const refs = @import("refs.zig");
const objects = @import("objects.zig");
const index_mod = if (@import("builtin").target.os.tag != .freestanding) @import("index.zig") else void;

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

/// Apply url.<base>.insteadOf rewriting to a URL
pub fn applyInsteadOf(allocator: std.mem.Allocator, url: []const u8, config_content: []const u8) ?[]u8 {
    // Find all url.<base>.insteadOf entries
    var best_match: ?[]const u8 = null;
    var best_base: ?[]const u8 = null;
    var best_match_len: usize = 0;

    var in_url_section = false;
    var current_base: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, config_content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        if (line[0] == '[') {
            in_url_section = false;
            current_base = null;
            // Parse [url "<base>"] section
            if (std.mem.startsWith(u8, line, "[url \"")) {
                const rest = line["[url \"".len..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |q| {
                    current_base = rest[0..q];
                    in_url_section = true;
                }
            }
            continue;
        }

        if (in_url_section and current_base != null) {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                const vkey = std.mem.trim(u8, line[0..eq], " \t");
                const vval = std.mem.trim(u8, line[eq + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(vkey, "insteadOf")) {
                    if (std.mem.startsWith(u8, url, vval) and vval.len > best_match_len) {
                        best_match = vval;
                        best_base = current_base;
                        best_match_len = vval.len;
                    }
                }
            }
        }
    }

    if (best_match != null and best_base != null) {
        // Replace the matched prefix with the base URL
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ best_base.?, url[best_match_len..] }) catch null;
    }
    return null;
}

/// Find a configured remote name whose URL matches the given URL.
/// Handles file:// prefix and path normalization.
fn findRemoteByUrl(allocator: std.mem.Allocator, config_content: []const u8, url: []const u8) ?[]u8 {
    // Normalize the target URL
    const target_path = if (std.mem.startsWith(u8, url, "file://"))
        url["file://".len..]
    else
        url;

    // Resolve target to absolute path
    const abs_target = std.fs.cwd().realpathAlloc(allocator, target_path) catch null;
    defer if (abs_target) |a| allocator.free(a);

    var lines = std.mem.splitScalar(u8, config_content, '\n');
    var current_remote: ?[]const u8 = null;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        if (line[0] == '[') {
            current_remote = null;
            if (std.mem.startsWith(u8, line, "[remote \"")) {
                const rest = line["[remote \"".len..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |q| {
                    current_remote = rest[0..q];
                }
            }
            continue;
        }
        if (current_remote) |rn| {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                const vkey = std.mem.trim(u8, line[0..eq], " \t");
                if (std.ascii.eqlIgnoreCase(vkey, "url")) {
                    const vval = std.mem.trim(u8, line[eq + 1 ..], " \t");
                    // Compare URLs
                    const cfg_path = if (std.mem.startsWith(u8, vval, "file://"))
                        vval["file://".len..]
                    else
                        vval;

                    // Direct comparison
                    if (std.mem.eql(u8, cfg_path, target_path)) {
                        return allocator.dupe(u8, rn) catch null;
                    }
                    // Resolve and compare
                    if (abs_target) |at| {
                        const abs_cfg = std.fs.cwd().realpathAlloc(allocator, cfg_path) catch null;
                        defer if (abs_cfg) |a| allocator.free(a);
                        if (abs_cfg) |ac| {
                            if (std.mem.eql(u8, ac, at)) {
                                return allocator.dupe(u8, rn) catch null;
                            }
                        }
                    }
                }
            }
        }
    }
    return null;
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

    // Try adding .git suffix (e.g., foo -> foo.git)
    const with_git_suffix = try std.fmt.allocPrint(allocator, "{s}.git", .{path});
    defer allocator.free(with_git_suffix);
    const abs_with_git = std.fs.cwd().realpathAlloc(allocator, with_git_suffix) catch return error.RepositoryNotFound;
    errdefer allocator.free(abs_with_git);

    const obj2 = try std.fmt.allocPrint(allocator, "{s}/objects", .{abs_with_git});
    defer allocator.free(obj2);
    const ref2 = try std.fmt.allocPrint(allocator, "{s}/refs", .{abs_with_git});
    defer allocator.free(ref2);
    const has_obj2 = if (std.fs.cwd().access(obj2, .{})) |_| true else |_| false;
    const has_ref2 = if (std.fs.cwd().access(ref2, .{})) |_| true else |_| false;
    if (has_obj2 and has_ref2) return abs_with_git;

    allocator.free(abs_with_git);
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
    return refspecMatchImpl(ref_name, pattern, false);
}

fn refspecMatchImpl(ref_name: []const u8, pattern: []const u8, strict: bool) ?[]const u8 {
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
    // Short refspec: "main" matches "refs/heads/main", "refs/tags/main", etc.
    if (!std.mem.startsWith(u8, pattern, "refs/") and std.mem.indexOfScalar(u8, pattern, '*') == null) {
        if (std.mem.startsWith(u8, ref_name, "refs/heads/")) {
            if (std.mem.eql(u8, ref_name["refs/heads/".len..], pattern)) return "";
        }
        if (!strict) {
            if (std.mem.startsWith(u8, ref_name, "refs/tags/")) {
                if (std.mem.eql(u8, ref_name["refs/tags/".len..], pattern)) return "";
            }
        }
        // Also match refs/remotes/<name>/HEAD for remote DWIM
        if (std.mem.startsWith(u8, ref_name, "refs/remotes/")) {
            const rest = ref_name["refs/remotes/".len..];
            if (std.mem.endsWith(u8, rest, "/HEAD")) {
                const rname = rest[0 .. rest.len - "/HEAD".len];
                if (std.mem.eql(u8, rname, pattern)) return "";
            }
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


    // Find git directory
    const git_path = git_helpers_mod.findGitDirectory(allocator, platform_impl) catch {
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
    var atomic = false;

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
        } else if (std.mem.eql(u8, arg, "--atomic")) {
            atomic = true;
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
    var instead_of_url: ?[]u8 = null;
    defer if (instead_of_url) |u| allocator.free(u);
    const remote_url: []const u8 = blk: {
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);
        if (readFileContent(allocator, config_path)) |config_content| {
            defer allocator.free(config_content);
            const url_key = try std.fmt.allocPrint(allocator, "remote.{s}.url", .{remote_name});
            defer allocator.free(url_key);
            if (getConfigValue(config_content, url_key, allocator)) |url| {
                // Apply url.<base>.insteadOf rewriting
                if (applyInsteadOf(allocator, url, config_content)) |rewritten| {
                    instead_of_url = rewritten;
                    allocator.free(url);
                    break :blk rewritten;
                }
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
                // Determine which remote name to use for config lookups.
                // For URL-based fetches, try to match the URL against configured remotes.
                var matched_remote_name: ?[]u8 = null;
                const prune_remote_name: []const u8 = if (is_named_remote) remote_name else blk_match: {
                    matched_remote_name = findRemoteByUrl(allocator, config_content, remote_url);
                    break :blk_match if (matched_remote_name) |m| m else "";
                };
                defer if (matched_remote_name) |m| allocator.free(m);
                const has_prune_remote = is_named_remote or matched_remote_name != null;

                // Read prune config - remote.<name>.prune overrides fetch.prune
                if (!no_prune and !effective_prune) {
                    if (has_prune_remote) {
                        const remote_prune_key = try std.fmt.allocPrint(allocator, "remote.{s}.prune", .{prune_remote_name});
                        defer allocator.free(remote_prune_key);
                        if (getConfigValue(config_content, remote_prune_key, allocator)) |prune_val| {
                            defer allocator.free(prune_val);
                            if (std.mem.eql(u8, prune_val, "true")) {
                                effective_prune = true;
                            } else if (std.mem.eql(u8, prune_val, "false")) {
                                // Explicitly disabled - don't fall through to fetch.prune
                            } else {
                                if (getConfigValue(config_content, "fetch.prune", allocator)) |fp| {
                                    defer allocator.free(fp);
                                    effective_prune = std.mem.eql(u8, fp, "true");
                                } else |_| {}
                            }
                        } else |_| {
                            if (getConfigValue(config_content, "fetch.prune", allocator)) |prune_val| {
                                defer allocator.free(prune_val);
                                effective_prune = std.mem.eql(u8, prune_val, "true");
                            } else |_| {}
                        }
                    } else {
                        // No matching remote found, check fetch.prune
                        if (getConfigValue(config_content, "fetch.prune", allocator)) |prune_val| {
                            defer allocator.free(prune_val);
                            effective_prune = std.mem.eql(u8, prune_val, "true");
                        } else |_| {}
                    }
                }
                // Handle --no-prune explicitly overriding config
                if (no_prune) effective_prune = false;

                // Read pruneTags config
                if (!effective_prune_tags) {
                    if (has_prune_remote) {
                        const remote_prune_tags_key = try std.fmt.allocPrint(allocator, "remote.{s}.pruneTags", .{prune_remote_name});
                        defer allocator.free(remote_prune_tags_key);
                        if (getConfigValue(config_content, remote_prune_tags_key, allocator)) |pt_val| {
                            defer allocator.free(pt_val);
                            if (std.mem.eql(u8, pt_val, "true")) {
                                effective_prune_tags = true;
                            } else if (std.mem.eql(u8, pt_val, "false")) {
                                // Explicitly disabled
                            } else {
                                if (getConfigValue(config_content, "fetch.pruneTags", allocator)) |fp| {
                                    defer allocator.free(fp);
                                    effective_prune_tags = std.mem.eql(u8, fp, "true");
                                } else |_| {}
                            }
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
        var local_fetch_failed = false;
        performLocalFetch(allocator, git_path, local_path, remote_name, quiet, cmd_refspecs.items, platform_impl, effective_tags != .no, force, append_mode, effective_prune, dry_run, write_fetch_head and !dry_run, update_head_ok, has_refmap, refmap_value, effective_prune_tags, is_named_remote) catch |err| switch (err) {
            error.FetchFailed => { local_fetch_failed = true; },
            else => return err,
        };

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

        if (local_fetch_failed) std.process.exit(1);
        
        // Succinct mode: show fetch success if refs were updated
        if (succinct_mod.isEnabled() and !quiet) {
            // Count updated refs (simplified: assume all refspecs contributed)
            const ref_count = cmd_refspecs.items.len;
            if (ref_count > 0) {
                const msg = try std.fmt.allocPrint(allocator, "ok fetch {s} {d} refs\n", .{ remote_name, ref_count });
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
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
        
        // Succinct mode: show fetch success for HTTP fetch
        if (succinct_mod.isEnabled() and !quiet) {
            const msg = try std.fmt.allocPrint(allocator, "ok fetch {s} refs\n", .{remote_url});
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        }
        
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
    is_named_remote: bool,
) !void {
    // Counter for successfully updated refs (for succinct output)
    var updated_refs_count: u32 = 0;
    
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
            // No parent directory - path is just a basename like "." or ".."
            if (std.mem.eql(u8, basename, ".")) {
                // "." - resolve cwd and append "/."
                if (std.fs.cwd().realpathAlloc(allocator, ".")) |cwd_resolved| {
                    from_display = try std.fmt.allocPrint(allocator, "{s}/.", .{cwd_resolved});
                    from_display_owned = true;
                    allocator.free(cwd_resolved);
                } else |_| {
                    from_display = try allocator.dupe(u8, raw_path);
                    from_display_owned = true;
                }
            } else if (std.mem.eql(u8, basename, "..")) {
                // ".." - resolve parent
                if (std.fs.cwd().realpathAlloc(allocator, "..")) |resolved| {
                    from_display = resolved;
                    from_display_owned = true;
                } else |_| {
                    from_display = try allocator.dupe(u8, raw_path);
                    from_display_owned = true;
                }
            } else {
                if (std.fs.cwd().realpathAlloc(allocator, ".")) |cwd_resolved| {
                    from_display = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd_resolved, basename });
                    from_display_owned = true;
                    allocator.free(cwd_resolved);
                } else |_| {
                    from_display = try allocator.dupe(u8, raw_path);
                    from_display_owned = true;
                }
            }
        }
    }
    defer if (from_display_owned) allocator.free(from_display);

    // For FETCH_HEAD entries, use the raw source_path (not resolved absolute path)
    const fetch_head_url = source_path;

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

    // Add HEAD to source refs if it resolves to a hash
    {
        const src_head_for_refs = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{src_git_dir});
        defer allocator.free(src_head_for_refs);
        if (readFileContent(allocator, src_head_for_refs)) |head_content| {
            defer allocator.free(head_content);
            const head_trimmed = std.mem.trim(u8, head_content, " \t\r\n");
            var head_hash: ?[]u8 = null;
            if (std.mem.startsWith(u8, head_trimmed, "ref: ")) {
                head_hash = refs.resolveRef(src_git_dir, head_trimmed["ref: ".len..], platform_impl, allocator) catch null;
            } else if (head_trimmed.len >= 40) {
                head_hash = allocator.dupe(u8, head_trimmed[0..40]) catch null;
            }
            if (head_hash) |hh| {
                try source_refs.append(.{
                    .name = try allocator.dupe(u8, "HEAD"),
                    .hash = hh,
                });
            }
        } else |_| {}
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
    var has_df_conflict = false;

    // Pre-prune: when --prune is active, prune BEFORE writing refs to resolve D/F conflicts
    if (do_prune) {
        var prune_refspecs_pre = std.array_list.Managed([]u8).init(allocator);
        defer {
            for (prune_refspecs_pre.items) |rs2| allocator.free(rs2);
            prune_refspecs_pre.deinit();
        }
        if (!using_default_refspec) {
            for (refspecs.items) |rs2| {
                try prune_refspecs_pre.append(try allocator.dupe(u8, rs2));
            }
        }
        if (do_prune_tags and cmd_refspecs.len == 0) {
            var has_tag_rs = false;
            for (prune_refspecs_pre.items) |rs2| {
                var cs2 = @as([]const u8, rs2);
                if (cs2.len > 0 and cs2[0] == '+') cs2 = cs2[1..];
                if (std.mem.startsWith(u8, cs2, "refs/tags/")) { has_tag_rs = true; break; }
            }
            if (!has_tag_rs) try prune_refspecs_pre.append(try allocator.dupe(u8, "refs/tags/*:refs/tags/*"));
        }
        if (prune_refspecs_pre.items.len > 0) {
            try pruneStaleRefs(allocator, git_path, prune_refspecs_pre.items, source_refs.items);
        }
    }

    for (refspecs.items, 0..) |rs, refspec_idx| {
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

        var matched_any = false;
        var matched_only_via_tag_dwim = false;
        for (source_refs.items) |entry| {
            if (refspecMatch(entry.name, cs)) |suffix| {
                matched_any = true;
                // Track if this match was only via tag DWIM (short name matching refs/tags/*)
                if (!std.mem.startsWith(u8, cs, "refs/") and std.mem.indexOfScalar(u8, cs, '*') == null and
                    std.mem.startsWith(u8, entry.name, "refs/tags/") and
                    !std.mem.startsWith(u8, entry.name, "refs/heads/"))
                {
                    // Check if the pattern matches literally (not just via tag DWIM)
                    if (!std.mem.eql(u8, entry.name, cs)) {
                        matched_only_via_tag_dwim = true;
                    }
                } else {
                    matched_only_via_tag_dwim = false;
                }
                // Determine if this ref is for-merge
                var is_for_merge = false;
                for (merge_refs.items) |mref| {
                    if (std.mem.eql(u8, entry.name, mref)) {
                        is_for_merge = true;
                        break;
                    }
                }

                // Build description for FETCH_HEAD
                const branch_desc = buildFetchHeadDesc(allocator, entry.name, fetch_head_url) catch null;

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
                                const write_result = tryWriteRef(git_path, dn, entry.hash, allocator);
                                switch (write_result) {
                                    .df_conflict => {
                                        if (!quiet) {
                                            const emsg = try std.fmt.allocPrint(allocator, " ! [rejected]        {s} -> {s}  (unable to update local ref)\n", .{ formatRefDisplay(entry.name), formatRefDisplay(dn) });
                                            defer allocator.free(emsg);
                                            try platform_impl.writeStderr(emsg);
                                        }
                                        fetch_failed = true;
                                        has_df_conflict = true;
                                        continue;
                                    },
                                    .lock_conflict => {
                                        if (!quiet) {
                                            const emsg = try std.fmt.allocPrint(allocator, "error: cannot lock ref '{s}': Unable to create '{s}/{s}.lock': File exists.\n", .{ dn, git_path, dn });
                                            defer allocator.free(emsg);
                                            try platform_impl.writeStderr(emsg);
                                        }
                                        fetch_failed = true;
                                        continue;
                                    },
                                    .other_error => {
                                        fetch_failed = true;
                                        continue;
                                    },
                                    .success => {
                                        updated_refs_count += 1;
                                    },
                                }
                            }

                            // Print status line
                            if (!quiet) {
                                const display_src = formatRefDisplay(entry.name);
                                const display_dst = formatRefDisplay(dn);
                                if (old_hash_val) |old_hash| {
                                    if (!std.mem.eql(u8, old_hash, entry.hash)) {
                                        // Updated ref
                                        updated_refs_count += 1;
                                        if (!succinct_mod.isEnabled()) {
                                            const smsg = try std.fmt.allocPrint(allocator, "   {s}..{s}  {s} -> {s}\n", .{ old_hash[0..7], entry.hash[0..7], display_src, display_dst });
                                            defer allocator.free(smsg);
                                            try platform_impl.writeStderr(smsg);
                                        }
                                    }
                                } else {
                                    // New ref
                                    const kind = if (std.mem.startsWith(u8, entry.name, "refs/tags/"))
                                        "new tag"
                                    else if (std.mem.startsWith(u8, entry.name, "refs/heads/"))
                                        "new branch"
                                    else
                                        "new ref";
                                    updated_refs_count += 1;
                                    if (!succinct_mod.isEnabled()) {
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

        // Check if explicit refspec matched nothing (error for non-glob refspecs)
        if (cs.len > 0 and std.mem.indexOfScalar(u8, cs, '*') == null and cmd_refspecs.len > 0 and refspec_idx < cmd_refspecs.len) {
            if (!matched_any or matched_only_via_tag_dwim) {
                const err_msg = try std.fmt.allocPrint(allocator, "fatal: couldn't find remote ref {s}\n", .{cs});
                defer allocator.free(err_msg);
                try platform_impl.writeStderr(err_msg);
                std.process.exit(128);
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

                    // Use tryWriteRef which handles D/F conflicts and lock files
                    // But first check fast-forward
                    if (!cfg_force and !force_flag) {
                        const tracking_path_ff = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, tracking_ref }) catch continue;
                        defer allocator.free(tracking_path_ff);
                        if (readFileContent(allocator, tracking_path_ff)) |old| {
                            defer allocator.free(old);
                            const old_h = std.mem.trim(u8, old, " \t\r\n");
                            if (old_h.len >= 40 and !std.mem.eql(u8, old_h[0..40], fhe.hash)) {
                                if (!isAncestor(git_path, old_h[0..40], fhe.hash, allocator, platform_impl)) continue;
                            }
                        } else |_| {}
                    }

                    const write_result2 = tryWriteRef(git_path, tracking_ref, fhe.hash, allocator);
                    switch (write_result2) {
                        .df_conflict => {
                            fetch_failed = true;
                            has_df_conflict = true;
                        },
                        .lock_conflict => {
                            if (!quiet) {
                                const emsg2 = std.fmt.allocPrint(allocator, "error: cannot lock ref '{s}': Unable to create '{s}/{s}.lock': File exists.\n", .{ tracking_ref, git_path, tracking_ref }) catch continue;
                                defer allocator.free(emsg2);
                                platform_impl.writeStderr(emsg2) catch {};
                            }
                            fetch_failed = true;
                        },
                        .other_error => { fetch_failed = true; },
                        .success => {
                            updated_refs_count += 1;
                        },
                    }
                }
            }
        }
    }

    // Note: prune already happened before ref writes (see "Pre-prune" above)

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

    // If no entries were generated from refspec matching, and no explicit refspecs were given,
    // write HEAD-based FETCH_HEAD (for "git fetch <remote>" or "git pull <remote>" without branch)
    if (fetch_head_entries.items.len == 0 and (using_default_refspec or cmd_refspecs.len == 0)) {
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
                const line = try std.fmt.allocPrint(allocator, "{s}\t\tbranch '{s}' of {s}\n", .{ h, bn, fetch_head_url });
                defer allocator.free(line);
                try fh_content.appendSlice(line);
            }
        } else |_| {}
    }

    if (dry_run) {
        if (fh_content.items.len > 0) {
            for (fetch_head_entries.items) |entry| {
                const msg = try std.fmt.allocPrint(allocator, "{s} FETCH_HEAD\n", .{entry.hash});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            }
            if (fetch_head_entries.items.len == 0) {
                try platform_impl.writeStderr("FETCH_HEAD\n");
            }
        }
    } else if (do_write_fetch_head) {
        if (!append_mode or fh_content.items.len > 0) {
            // Always write FETCH_HEAD (even if empty) to clear stale data
            std.fs.cwd().writeFile(.{ .sub_path = fhp, .data = fh_content.items }) catch {};
        }
    }

    // Update remote HEAD symbolic ref (followRemoteHEAD feature)
    // Only do this for named remotes and when no explicit refspecs were given on cmdline
    if (is_named_remote and cmd_refspecs.len == 0) {
        const src_head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{src_git_dir});
        defer allocator.free(src_head_path);
        if (readFileContent(allocator, src_head_path)) |hcont| {
            defer allocator.free(hcont);
            const th = std.mem.trim(u8, hcont, " \t\r\n");
            if (std.mem.startsWith(u8, th, "ref: refs/heads/")) {
                const remote_head_branch = th["ref: refs/heads/".len..];
                const rh_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}/HEAD", .{ git_path, remote_name });
                defer allocator.free(rh_path);
                // Check if tracking ref for the remote HEAD branch exists
                const tracking_ref = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}/{s}", .{ git_path, remote_name, remote_head_branch });
                defer allocator.free(tracking_ref);

                // Read followRemoteHEAD config
                var follow_mode: enum { always, warn, warn_if_not_branch, create, never } = .warn;
                var warn_if_not_branch_name: []const u8 = "";
                {
                    const cfg_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
                    defer allocator.free(cfg_path);
                    if (readFileContent(allocator, cfg_path)) |cfg_content| {
                        defer allocator.free(cfg_content);
                        const follow_key = try std.fmt.allocPrint(allocator, "remote.{s}.followRemoteHEAD", .{remote_name});
                        defer allocator.free(follow_key);
                        if (getConfigValue(cfg_content, follow_key, allocator)) |fval| {
                            defer allocator.free(fval);
                            if (std.mem.eql(u8, fval, "never")) {
                                follow_mode = .never;
                            } else if (std.mem.eql(u8, fval, "warn")) {
                                follow_mode = .warn;
                            } else if (std.mem.startsWith(u8, fval, "warn-if-not-")) {
                                follow_mode = .warn_if_not_branch;
                                warn_if_not_branch_name = fval["warn-if-not-".len..];
                            } else if (std.mem.eql(u8, fval, "create")) {
                                follow_mode = .create;
                            } else if (std.mem.eql(u8, fval, "always")) {
                                follow_mode = .always;
                            }
                        } else |_| {}
                    } else |_| {}
                }

                if (follow_mode != .never) {
                    if (std.fs.cwd().access(tracking_ref, .{})) |_| {
                        if (std.fs.path.dirname(rh_path)) |pd| std.fs.cwd().makePath(pd) catch {};
                        const new_symref = try std.fmt.allocPrint(allocator, "ref: refs/remotes/{s}/{s}\n", .{ remote_name, remote_head_branch });
                        defer allocator.free(new_symref);

                        const existing_head = readFileContent(allocator, rh_path) catch null;
                        defer if (existing_head) |eh| allocator.free(eh);

                        if (existing_head) |eh| {
                            const existing_trimmed = std.mem.trim(u8, eh, " \t\r\n");
                            // HEAD already exists
                            if (std.mem.startsWith(u8, existing_trimmed, "ref: refs/remotes/")) {
                                // It's a symref - check if it already points to the right place
                                const expected_ref = try std.fmt.allocPrint(allocator, "ref: refs/remotes/{s}/{s}", .{ remote_name, remote_head_branch });
                                defer allocator.free(expected_ref);
                                if (!std.mem.eql(u8, existing_trimmed, expected_ref)) {
                                    // HEAD changed
                                    const current_branch_ref = existing_trimmed["ref: ".len..];
                                    const current_branch_name = if (std.mem.startsWith(u8, current_branch_ref, "refs/remotes/")) blk_cn: {
                                        const after_remotes = current_branch_ref["refs/remotes/".len..];
                                        if (std.mem.indexOfScalar(u8, after_remotes, '/')) |slash| {
                                            break :blk_cn after_remotes[slash + 1 ..];
                                        }
                                        break :blk_cn after_remotes;
                                    } else current_branch_ref;
                                    _ = current_branch_name;

                                    if (follow_mode == .always) {
                                        if (!dry_run) {
                                            std.fs.cwd().writeFile(.{ .sub_path = rh_path, .data = new_symref }) catch {};
                                        }
                                    } else if (follow_mode == .warn) {
                                        // Print warning to stdout
                                        if (!quiet) {
                                            const cur_ref_tail = existing_trimmed["ref: ".len..];
                                            const cur_branch = if (std.mem.lastIndexOfScalar(u8, cur_ref_tail, '/')) |ls2| cur_ref_tail[ls2 + 1 ..] else cur_ref_tail;
                                            const warn_msg = try std.fmt.allocPrint(allocator, "'HEAD' at '{s}' is '{s}', but we have '{s}' locally.\n", .{ remote_name, remote_head_branch, cur_branch });
                                            defer allocator.free(warn_msg);
                                            try platform_impl.writeStdout(warn_msg);
                                        }
                                    } else if (follow_mode == .warn_if_not_branch) {
                                        // Only warn if remote HEAD branch does NOT match the configured branch name
                                        if (!quiet and !std.mem.eql(u8, remote_head_branch, warn_if_not_branch_name)) {
                                            const cur_ref_tail = existing_trimmed["ref: ".len..];
                                            const cur_branch = if (std.mem.lastIndexOfScalar(u8, cur_ref_tail, '/')) |ls2| cur_ref_tail[ls2 + 1 ..] else cur_ref_tail;
                                            const warn_msg = try std.fmt.allocPrint(allocator, "'HEAD' at '{s}' is '{s}', but we have '{s}' locally.\n", .{ remote_name, remote_head_branch, cur_branch });
                                            defer allocator.free(warn_msg);
                                            try platform_impl.writeStdout(warn_msg);
                                        }
                                    }
                                }
                            } else {
                                // It's a detached HEAD (raw hash)
                                if (follow_mode == .always) {
                                    if (!dry_run) {
                                        std.fs.cwd().writeFile(.{ .sub_path = rh_path, .data = new_symref }) catch {};
                                    }
                                } else if (follow_mode == .warn) {
                                    if (!quiet) {
                                        const warn_msg = try std.fmt.allocPrint(allocator, "'HEAD' at '{s}' is '{s}', but we have a detached HEAD pointing to '{s}' locally.\n", .{ remote_name, remote_head_branch, existing_trimmed });
                                        defer allocator.free(warn_msg);
                                        try platform_impl.writeStdout(warn_msg);
                                    }
                                }
                            }
                        } else {
                            // No existing HEAD - create it
                            if (follow_mode != .never) {
                                if (!dry_run) {
                                    std.fs.cwd().writeFile(.{ .sub_path = rh_path, .data = new_symref }) catch {};
                                }
                            }
                        }
                    } else |_| {}
                }
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
                if (tag_is_new) {
                    updated_refs_count += 1;
                    if (!quiet and !succinct_mod.isEnabled()) {
                        const tag_name = entry.name["refs/tags/".len..];
                        const smsg = try std.fmt.allocPrint(allocator, " * [new tag]         {s} -> {s}\n", .{ tag_name, tag_name });
                        defer allocator.free(smsg);
                        try platform_impl.writeStderr(smsg);
                    }
                }
            }
        }
    }

    // Output success message for succinct mode (before checking for failures)
    if (!fetch_failed and succinct_mod.isEnabled() and updated_refs_count > 0) {
        const success_msg = std.fmt.allocPrint(allocator, "ok fetch {s} {d} refs\n", .{ remote_name, updated_refs_count }) catch "";
        if (success_msg.len > 0) {
            defer allocator.free(success_msg);
            platform_impl.writeStdout(success_msg) catch {};
        }
    }
    
    if (fetch_failed) {
        if (has_df_conflict and is_named_remote) {
            const df_err1 = try std.fmt.allocPrint(allocator, "error: some local refs could not be updated; try running\n 'git remote prune {s}' to remove any old, conflicting branches\n", .{remote_name});
            defer allocator.free(df_err1);
            try platform_impl.writeStderr(df_err1);
        }
        return error.FetchFailed;
    }
    
    // Output success summary in succinct mode
    if (succinct_mod.isEnabled() and updated_refs_count > 0) {
        const success_msg = std.fmt.allocPrint(allocator, "ok fetch {s} {d} refs\n", .{ remote_name, updated_refs_count }) catch "";
        if (success_msg.len > 0) {
            defer allocator.free(success_msg);
            platform_impl.writeStdout(success_msg) catch {};
        }
    }

}

/// Check if a ref path has a D/F (directory/file) conflict.
/// Returns true if the ref cannot be written because a directory is in the way,
/// or a file exists where a directory component needs to be.
fn hasRefDFConflict(git_path: []const u8, ref_name: []const u8, allocator: std.mem.Allocator) bool {
    const ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, ref_name }) catch return false;
    defer allocator.free(ref_path);

    // Check if ref_path itself is a directory (we want to write a file there)
    if (std.fs.cwd().openDir(ref_path, .{})) |dir| {
        var d = dir;
        d.close();
        return true;
    } else |_| {}

    // Check if any parent component of ref_name (within refs/) is an existing file
    // e.g., if we want to write refs/remotes/origin/dir/file but refs/remotes/origin/dir is a file
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, ref_name, pos, '/')) |slash| {
        if (slash > 0) {
            const prefix_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, ref_name[0..slash] }) catch return false;
            defer allocator.free(prefix_path);
            // Check if this is a regular file (not directory)
            if (std.fs.cwd().statFile(prefix_path)) |stat| {
                if (stat.kind == .file) return true;
            } else |_| {}
        }
        pos = slash + 1;
    }

    return false;
}

/// Check if a ref path has a .lock file conflict.
fn hasLockConflict(git_path: []const u8, ref_name: []const u8, allocator: std.mem.Allocator) bool {
    const lock_path = std.fmt.allocPrint(allocator, "{s}/{s}.lock", .{ git_path, ref_name }) catch return false;
    defer allocator.free(lock_path);
    return if (std.fs.cwd().access(lock_path, .{})) |_| true else |_| false;
}

/// Try to write a ref, handling D/F conflicts. Returns error info.
const RefWriteResult = enum { success, df_conflict, lock_conflict, other_error };

fn tryWriteRef(git_path: []const u8, ref_name: []const u8, hash: []const u8, allocator: std.mem.Allocator) RefWriteResult {
    const ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, ref_name }) catch return .other_error;
    defer allocator.free(ref_path);

    // Create parent directories
    if (std.mem.lastIndexOfScalar(u8, ref_path, '/')) |ls| {
        std.fs.cwd().makePath(ref_path[0..ls]) catch {
            // makePath can fail due to D/F conflict (file in the way)
            if (hasRefDFConflict(git_path, ref_name, allocator)) return .df_conflict;
            return .other_error;
        };
    }

    // Check for lock file
    if (hasLockConflict(git_path, ref_name, allocator)) return .lock_conflict;

    const data = std.fmt.allocPrint(allocator, "{s}\n", .{hash}) catch return .other_error;
    defer allocator.free(data);

    std.fs.cwd().writeFile(.{ .sub_path = ref_path, .data = data }) catch {
        if (hasRefDFConflict(git_path, ref_name, allocator)) return .df_conflict;
        return .other_error;
    };

    return .success;
}

/// Remove a directory tree that conflicts with a ref path
fn removeDFConflictDir(git_path: []const u8, ref_name: []const u8, allocator: std.mem.Allocator) void {
    const ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, ref_name }) catch return;
    defer allocator.free(ref_path);

    // If the ref_path is a directory, remove it recursively
    std.fs.cwd().deleteTree(ref_path) catch {};
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
                // Clean up empty parent directories
                cleanupEmptyRefDirs(allocator, git_path, local_entry.name);
            }
        }
    }
}

/// Remove empty parent directories after deleting a ref
fn cleanupEmptyRefDirs(allocator: std.mem.Allocator, git_path: []const u8, ref_name: []const u8) void {
    // Walk up from the ref's directory, removing empty dirs until refs/
    var current = ref_name;
    while (std.mem.lastIndexOfScalar(u8, current, '/')) |slash| {
        current = current[0..slash];
        if (current.len == 0 or std.mem.eql(u8, current, "refs") or
            std.mem.eql(u8, current, "refs/heads") or
            std.mem.eql(u8, current, "refs/tags") or
            std.mem.eql(u8, current, "refs/remotes"))
        {
            break;
        }
        const dir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, current }) catch break;
        defer allocator.free(dir_path);
        // Try to remove - will only succeed if empty
        std.fs.cwd().deleteDir(dir_path) catch break;
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

/// Implement "git remote set-head <remote> <branch>" or "git remote set-head -d <remote>"
pub fn cmdRemoteSetHead(allocator: std.mem.Allocator, git_path: []const u8, sub_args: []const []const u8) void {
    var remote_arg: ?[]const u8 = null;
    var branch_arg: ?[]const u8 = null;
    var delete_mode = false;
    var auto_mode = false;

    for (sub_args) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delete")) {
            delete_mode = true;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--auto")) {
            auto_mode = true;
        } else if (remote_arg == null) {
            remote_arg = arg;
        } else if (branch_arg == null) {
            branch_arg = arg;
        }
    }

    const rname = remote_arg orelse return;

    if (delete_mode) {
        // Delete refs/remotes/<remote>/HEAD
        const rh_path = std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}/HEAD", .{ git_path, rname }) catch return;
        defer allocator.free(rh_path);
        std.fs.cwd().deleteFile(rh_path) catch {};
        return;
    }

    if (auto_mode) {
        // Determine remote HEAD from remote repo
        // Read config to get URL
        const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch return;
        defer allocator.free(config_path);
        const config_content = readFileContent(allocator, config_path) catch return;
        defer allocator.free(config_content);
        const url_key = std.fmt.allocPrint(allocator, "remote.{s}.url", .{rname}) catch return;
        defer allocator.free(url_key);
        const url = getConfigValue(config_content, url_key, allocator) catch return;
        defer allocator.free(url);

        const src_git_dir = resolveSourceGitDir(allocator, url) catch return;
        defer allocator.free(src_git_dir);

        const head_path = std.fmt.allocPrint(allocator, "{s}/HEAD", .{src_git_dir}) catch return;
        defer allocator.free(head_path);
        const head_content = readFileContent(allocator, head_path) catch return;
        defer allocator.free(head_content);
        const trimmed = std.mem.trim(u8, head_content, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "ref: refs/heads/")) {
            const branch_name = trimmed["ref: refs/heads/".len..];
            const rh_path = std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}/HEAD", .{ git_path, rname }) catch return;
            defer allocator.free(rh_path);
            if (std.fs.path.dirname(rh_path)) |pd| std.fs.cwd().makePath(pd) catch {};
            const sc = std.fmt.allocPrint(allocator, "ref: refs/remotes/{s}/{s}\n", .{ rname, branch_name }) catch return;
            defer allocator.free(sc);
            std.fs.cwd().writeFile(.{ .sub_path = rh_path, .data = sc }) catch {};
        }
        return;
    }

    if (branch_arg) |branch| {
        // Set refs/remotes/<remote>/HEAD to point to refs/remotes/<remote>/<branch>
        const rh_path = std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}/HEAD", .{ git_path, rname }) catch return;
        defer allocator.free(rh_path);
        if (std.fs.path.dirname(rh_path)) |pd| std.fs.cwd().makePath(pd) catch {};
        const sc = std.fmt.allocPrint(allocator, "ref: refs/remotes/{s}/{s}\n", .{ rname, branch }) catch return;
        defer allocator.free(sc);
        std.fs.cwd().writeFile(.{ .sub_path = rh_path, .data = sc }) catch {};
    }
}

/// Resolve a URL to an absolute path, preserving trailing /. or /..
pub fn resolveUrlPreservingDot(allocator: std.mem.Allocator, source_url: []const u8) ![]u8 {
    const raw = if (std.mem.startsWith(u8, source_url, "file://"))
        source_url["file://".len..]
    else
        source_url;

    const bn = std.fs.path.basename(raw);
    if (std.mem.eql(u8, bn, ".") or std.mem.eql(u8, bn, "..")) {
        const parent = std.fs.path.dirname(raw);
        if (parent) |p| {
            const rp = try std.fs.cwd().realpathAlloc(allocator, p);
            defer allocator.free(rp);
            return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rp, bn });
        } else {
            // Just "." or ".."
            if (std.mem.eql(u8, bn, ".")) {
                const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
                defer allocator.free(cwd);
                return try std.fmt.allocPrint(allocator, "{s}/.", .{cwd});
            }
        }
    }
    return try std.fs.cwd().realpathAlloc(allocator, raw);
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

// ============================================================================
// Pull command implementation
// ============================================================================

pub fn cmdPull(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("pull: not supported in freestanding mode\n");
        return;
    }


    const git_path = git_helpers_mod.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    var pull_flags = std.array_list.Managed([]const u8).init(allocator);
    defer pull_flags.deinit();
    var pull_positionals = std.array_list.Managed([]const u8).init(allocator);
    defer pull_positionals.deinit();
    var no_rebase = false;
    var do_rebase = false;
    var pull_strategy: ?[]const u8 = null;
    var quiet = false;
    var verbose = false;
    var ff_only = false;
    var no_ff = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--no-rebase")) {
            no_rebase = true;
        } else if (std.mem.eql(u8, arg, "--rebase")) {
            do_rebase = true;
        } else if (std.mem.eql(u8, arg, "-s")) {
            pull_strategy = args.next();
        } else if (std.mem.startsWith(u8, arg, "--strategy=")) {
            pull_strategy = arg["--strategy=".len..];
        } else if (std.mem.eql(u8, arg, "--ff-only")) {
            ff_only = true;
            try pull_flags.append(arg);
        } else if (std.mem.eql(u8, arg, "--no-ff")) {
            no_ff = true;
            try pull_flags.append(arg);
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
            try pull_flags.append(arg);
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
            try pull_flags.append(arg);
        } else if (std.mem.eql(u8, arg, "--log") or std.mem.startsWith(u8, arg, "--log=") or
            std.mem.eql(u8, arg, "--no-log") or std.mem.eql(u8, arg, "--ff") or
            std.mem.eql(u8, arg, "--squash") or std.mem.eql(u8, arg, "--no-squash"))
        {
            try pull_flags.append(arg);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try pull_flags.append(arg);
        } else {
            try pull_positionals.append(arg);
        }
    }

    // Read config
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
    defer allocator.free(config_path);
    const config_content = std.fs.cwd().readFileAlloc(allocator, config_path, 10 * 1024 * 1024) catch "";
    defer if (config_content.len > 0) allocator.free(config_content);

    // Get current branch
    const current_branch_opt = refs.getCurrentBranch(git_path, platform_impl, allocator) catch null;
    defer if (current_branch_opt) |cb| allocator.free(cb);

    // Determine remote and branch to pull from
    var remote: []const u8 = "origin";
    var remote_owned = false;
    var merge_branch: ?[]const u8 = null;
    var merge_branch_owned = false;
    var explicit_refspecs: []const []const u8 = &.{};

    if (pull_positionals.items.len > 0) {
        remote = pull_positionals.items[0];
        if (pull_positionals.items.len > 1) {
            explicit_refspecs = pull_positionals.items[1..];
            // First refspec's source is the merge branch
            const first_rs = pull_positionals.items[1];
            if (std.mem.indexOf(u8, first_rs, ":")) |colon| {
                merge_branch = first_rs[0..colon];
            } else {
                merge_branch = first_rs;
            }
        }
    } else {
        // Use config for current branch
        if (current_branch_opt) |branch| {
            const branch_remote_key = try std.fmt.allocPrint(allocator, "branch.{s}.remote", .{branch});
            defer allocator.free(branch_remote_key);
            if (parseSimpleConfigValue(config_content, branch_remote_key, allocator)) |r| {
                remote = r;
                remote_owned = true;
            } else |_| {}

            const branch_merge_key = try std.fmt.allocPrint(allocator, "branch.{s}.merge", .{branch});
            defer allocator.free(branch_merge_key);
            if (parseSimpleConfigValue(config_content, branch_merge_key, allocator)) |m| {
                merge_branch = m;
                merge_branch_owned = true;
            } else |_| {}
        }
    }
    defer if (remote_owned) allocator.free(remote);
    defer if (merge_branch_owned) {
        if (merge_branch) |mb| allocator.free(mb);
    };

    // Resolve remote URL
    var remote_url: []const u8 = undefined;
    var remote_url_owned = false;
    var remote_is_named = false;

    if (std.mem.startsWith(u8, remote, "/") or std.mem.startsWith(u8, remote, "./") or
        std.mem.startsWith(u8, remote, "../") or std.mem.eql(u8, remote, ".") or
        std.mem.eql(u8, remote, "..") or std.mem.startsWith(u8, remote, "file://"))
    {
        remote_url = remote;
    } else if (resolveSourceGitDir(allocator, remote)) |sgd| {
        allocator.free(sgd);
        remote_url = remote;
    } else |_| {
        // Named remote - look up URL
        remote_is_named = true;
        const url_key = try std.fmt.allocPrint(allocator, "remote.{s}.url", .{remote});
        defer allocator.free(url_key);
        if (parseSimpleConfigValue(config_content, url_key, allocator)) |u| {
            remote_url = u;
            remote_url_owned = true;
        } else |_| {
            const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' does not appear to be a git repository\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n", .{remote});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        }
    }
    defer if (remote_url_owned) allocator.free(remote_url);

    // Check if this is a pull into void (no current commit before fetch)
    // Also save the current commit for detecting branch updates by fetch
    var pre_fetch_commit: ?[]u8 = null;
    defer if (pre_fetch_commit) |pfc| allocator.free(pfc);
    const was_void_before_fetch = blk: {
        const cc = refs.getCurrentCommit(git_path, platform_impl, allocator) catch break :blk true;
        if (cc) |c| {
            pre_fetch_commit = allocator.dupe(u8, c) catch null;
            allocator.free(c);
            break :blk false;
        }
        break :blk true;
    };

    // Perform fetch
    const actual_url = if (std.mem.startsWith(u8, remote_url, "file://"))
        remote_url["file://".len..]
    else
        remote_url;

    // Determine if local fetch
    var is_local = false;
    if (std.mem.startsWith(u8, actual_url, "/") or std.mem.startsWith(u8, actual_url, "./") or
        std.mem.startsWith(u8, actual_url, "../") or std.mem.eql(u8, actual_url, ".") or
        std.mem.eql(u8, actual_url, ".."))
    {
        is_local = true;
    } else if (!std.mem.startsWith(u8, actual_url, "http://") and
        !std.mem.startsWith(u8, actual_url, "https://") and
        !std.mem.startsWith(u8, actual_url, "ssh://") and
        !std.mem.startsWith(u8, actual_url, "git://"))
    {
        if (resolveSourceGitDir(allocator, actual_url)) |sgd| {
            allocator.free(sgd);
            is_local = true;
        } else |_| {}
    }

    if (is_local) {
        performLocalFetch(allocator, git_path, actual_url, remote, quiet, explicit_refspecs, platform_impl, true, false, false, false, false, true, true, false, null, false, remote_is_named) catch |err| {
            const emsg = try std.fmt.allocPrint(allocator, "fatal: fetch from '{s}' failed: {}\n", .{ remote, err });
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(128);
        };
    } else if (std.mem.startsWith(u8, actual_url, "http://") or std.mem.startsWith(u8, actual_url, "https://")) {
        const network = @import("network.zig");
        network.fetchRepository(allocator, remote_url, git_path, platform_impl) catch |err| switch (err) {
            error.RepositoryNotFound => {
                try platform_impl.writeStderr("fatal: repository not found\n");
                std.process.exit(128);
            },
            else => {
                try platform_impl.writeStderr("fatal: unable to access remote repository\n");
                std.process.exit(128);
            },
        };
    } else {
        const emsg = try std.fmt.allocPrint(allocator, "fatal: '{s}' does not appear to be a git repository\n", .{remote});
        defer allocator.free(emsg);
        try platform_impl.writeStderr(emsg);
        std.process.exit(128);
    }

    // Determine merge target
    // For pull, we determine the merge commit from:
    // 1. Explicit refspecs: resolve the source branch from the remote repo
    // 2. Named remote: use FETCH_HEAD for-merge entries
    // 3. URL remote without refspec: use FETCH_HEAD first entry (remote HEAD)
    var remote_commit: ?[]const u8 = null;
    var remote_commit_owned = false;
    var fetch_head_desc: ?[]const u8 = null;

    // Read FETCH_HEAD (needed in all cases)
    const fetch_head_path = try std.fmt.allocPrint(allocator, "{s}/FETCH_HEAD", .{git_path});
    defer allocator.free(fetch_head_path);
    const fetch_head_content = std.fs.cwd().readFileAlloc(allocator, fetch_head_path, 64 * 1024) catch "";
    defer if (fetch_head_content.len > 0) allocator.free(fetch_head_content);

    if (explicit_refspecs.len > 0) {
        // For explicit refspecs, resolve the source branch from the source repo
        // This ensures we get the right commit even if FETCH_HEAD marks it as not-for-merge
        if (is_local) {
            const src_git_dir = resolveSourceGitDir(allocator, actual_url) catch null;
            defer if (src_git_dir) |sgd| allocator.free(sgd);
            if (src_git_dir) |sgd| {
                // Get the source ref from the first refspec
                const first_rs = explicit_refspecs[0];
                const src_part = if (std.mem.indexOf(u8, first_rs, ":")) |c| first_rs[0..c] else first_rs;
                // Try to resolve as branch name
                const candidates = [_][]const u8{ "refs/heads/", "refs/tags/", "refs/" };
                for (candidates) |prefix| {
                    const full = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, src_part });
                    defer allocator.free(full);
                    if (refs.resolveRef(sgd, full, platform_impl, allocator) catch null) |h| {
                        remote_commit = h;
                        remote_commit_owned = true;
                        break;
                    }
                }
                if (remote_commit == null) {
                    // Try as-is (could be a full ref path)
                    if (refs.resolveRef(sgd, src_part, platform_impl, allocator) catch null) |h| {
                        remote_commit = h;
                        remote_commit_owned = true;
                    }
                }
                if (remote_commit == null and std.mem.eql(u8, src_part, "HEAD")) {
                    if (refs.resolveRef(sgd, "HEAD", platform_impl, allocator) catch null) |h| {
                        remote_commit = h;
                        remote_commit_owned = true;
                    }
                }
            }
        }
        // Fallback: use first FETCH_HEAD entry
        if (remote_commit == null and fetch_head_content.len >= 40) {
            remote_commit = fetch_head_content[0..40];
        }
    }

    if (remote_commit == null) {
        // Look for for-merge entries in FETCH_HEAD
        var lines = std.mem.splitScalar(u8, fetch_head_content, '\n');
        while (lines.next()) |line| {
            if (line.len < 40) continue;
            const hash = line[0..40];
            const rest = if (line.len > 41) line[41..] else "";
            const is_for_merge = !std.mem.startsWith(u8, rest, "not-for-merge");
            if (is_for_merge) {
                remote_commit = hash;
                if (std.mem.indexOf(u8, rest, "\t")) |tab| {
                    fetch_head_desc = rest[tab + 1 ..];
                }
                break;
            }
        }
    }

    if (remote_commit == null) {
        // No for-merge entry - fallback for URL-based remotes
        if (!remote_is_named and fetch_head_content.len >= 40) {
            remote_commit = fetch_head_content[0..40];
        }
    }

    if (remote_commit == null) {
        if (pull_positionals.items.len == 0) {
            try platform_impl.writeStderr("There is no tracking information for the current branch.\n");
            try platform_impl.writeStderr("Please specify which branch you want to merge with.\n");
            try platform_impl.writeStderr("See git-pull(1) for details.\n\n");
            try platform_impl.writeStderr("    git pull <remote> <branch>\n\n");
            try platform_impl.writeStderr("If you wish to set tracking information for this branch you can do so with:\n\n");
            try platform_impl.writeStderr("    git branch --set-upstream-to=<remote>/<branch>\n\n");
        } else if (explicit_refspecs.len == 0) {
            const emsg = try std.fmt.allocPrint(allocator, "You asked to pull from the remote '{s}', but did not specify\na branch. Because this is not the default configured remote\nfor your current branch, you must specify a branch on the command line.\n", .{remote});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
        } else {
            try platform_impl.writeStderr("fatal: no candidates for merging among the refs that you just fetched.\n");
        }
        std.process.exit(1);
    }

    const merge_hash = remote_commit.?;
    defer if (remote_commit_owned) allocator.free(merge_hash);

    // Get current HEAD commit AFTER fetch
    const current_commit_opt = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
    defer if (current_commit_opt) |cc| allocator.free(cc);

    if (current_commit_opt == null or was_void_before_fetch) {
        // Pull into void: no current commit (unborn branch)
        // Reject octopus merges (multiple branches)
        if (explicit_refspecs.len > 1) {
            try platform_impl.writeStderr("fatal: Cannot merge multiple branches into empty head.\n");
            std.process.exit(128);
        }
        const branch_name = current_branch_opt orelse "main";

        // Check for conflicting files before checkout
        const repo_root = std.fs.path.dirname(git_path) orelse ".";
        var conflict_files = std.array_list.Managed([]u8).init(allocator);
        defer {
            for (conflict_files.items) |f| allocator.free(f);
            conflict_files.deinit();
        }
        try collectPullIntoVoidConflicts(git_path, merge_hash, repo_root, allocator, platform_impl, &conflict_files);
        if (conflict_files.items.len > 0) {
            try platform_impl.writeStderr("error: The following untracked working tree files would be overwritten by merge:\n");
            for (conflict_files.items) |f| {
                const fmsg = try std.fmt.allocPrint(allocator, "\t{s}\n", .{f});
                defer allocator.free(fmsg);
                try platform_impl.writeStderr(fmsg);
            }
            try platform_impl.writeStderr("Please move or remove them before you merge.\nAborting\n");
            std.process.exit(1);
        }

        try refs.updateRef(git_path, branch_name, merge_hash, platform_impl, allocator);
        // For pull into void, don't clear tracked files (preserve staged files)
        try checkoutCommitTreePullOpts(git_path, merge_hash, allocator, platform_impl, false);
        return;
    }

    const current_commit = current_commit_opt.?;

    // Check if the fetch updated the current branch head (e.g., "pull . branch:currentbranch")
    if (pre_fetch_commit) |pfc| {
        if (!std.mem.eql(u8, pfc, current_commit)) {
            // The fetch updated our branch! Need to update working tree.
            try platform_impl.writeStderr("warning: fetch updated the current branch head.\n");
            try platform_impl.writeStderr("fast-forwarding your working tree from\n");
            const msg = try std.fmt.allocPrint(allocator, "commit {s}.\n", .{pfc});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            try checkoutCommitTreePull(git_path, current_commit, allocator, platform_impl);
            return;
        }
    }

    // Check if already up to date
    if (std.mem.eql(u8, current_commit, merge_hash)) {
        if (succinct_mod.isEnabled()) {
            try platform_impl.writeStdout("ok pull (up-to-date)\n");
        } else {
            try platform_impl.writeStdout("Already up to date.\n");
        }
        return;
    }

    // Check if fast-forward is possible (merge_hash is descendant of current_commit)
    const is_ff = isAncestor(git_path, current_commit, merge_hash, allocator, platform_impl);

    if (is_ff) {
        // Fast-forward
        const branch_name = current_branch_opt orelse {
            try platform_impl.writeStderr("fatal: not on a branch\n");
            std.process.exit(1);
        };
        try refs.updateRef(git_path, branch_name, merge_hash, platform_impl, allocator);

        // Checkout the tree
        try checkoutCommitTreePull(git_path, merge_hash, allocator, platform_impl);

        // Print summary
        if (!quiet) {
            if (succinct_mod.isEnabled()) {
                const current_branch = current_branch_opt orelse "HEAD";
                const msg = try std.fmt.allocPrint(allocator, "ok pull {s}\n", .{current_branch});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            } else {
                const from_desc = fetch_head_desc orelse remote;
                const msg = try std.fmt.allocPrint(allocator, "Updating {s}..{s}\nFast-forward\n", .{ current_commit[0..7], merge_hash[0..7] });
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
                _ = from_desc;
            }
        }
        return;
    }

    if (ff_only) {
        try platform_impl.writeStderr("fatal: Not possible to fast-forward, aborting.\n");
        std.process.exit(128);
    }

    if (pull_strategy != null and std.mem.eql(u8, pull_strategy.?, "ours")) {
        // "ours" strategy: keep our tree, just create merge commit
        const branch_name = current_branch_opt orelse {
            try platform_impl.writeStderr("fatal: not on a branch\n");
            std.process.exit(1);
        };
        const commit_obj = objects.GitObject.load(current_commit, git_path, platform_impl, allocator) catch {
            try platform_impl.writeStderr("fatal: unable to read current commit\n");
            std.process.exit(1);
        };
        defer commit_obj.deinit(allocator);
        const our_tree = pullExtractTree(commit_obj.data);
        if (our_tree.len == 0) {
            try platform_impl.writeStderr("fatal: unable to find tree\n");
            std.process.exit(1);
        }

        const merge_msg = try pullBuildMergeMessage(allocator, merge_branch, remote, fetch_head_desc);
        defer allocator.free(merge_msg);

        const author_str = pullGetAuthorString(allocator) catch try allocator.dupe(u8, "Unknown <unknown@unknown>");
        defer allocator.free(author_str);
        const committer_str = pullGetCommitterString(allocator) catch try allocator.dupe(u8, "Unknown <unknown@unknown>");
        defer allocator.free(committer_str);

        const parents = [_][]const u8{ current_commit, merge_hash };
        const new_commit = try objects.createCommitObject(our_tree, &parents, author_str, committer_str, merge_msg, allocator);
        defer new_commit.deinit(allocator);
        const new_hash = try new_commit.store(git_path, platform_impl, allocator);
        defer allocator.free(new_hash);

        try refs.updateRef(git_path, branch_name, new_hash, platform_impl, allocator);
        if (succinct_mod.isEnabled()) {
            const msg = try std.fmt.allocPrint(allocator, "ok pull {s} (merge)\n", .{branch_name});
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        } else {
            try platform_impl.writeStdout("Merge made by the 'ours' strategy.\n");
        }
        return;
    }

    // Real merge needed - find merge base and three-way merge
    const branch_name = current_branch_opt orelse {
        try platform_impl.writeStderr("fatal: not on a branch\n");
        std.process.exit(1);
    };

    // Find merge base
    const merge_base = findMergeBase(git_path, current_commit, merge_hash, allocator, platform_impl);
    defer if (merge_base) |mb| allocator.free(mb);

    if (merge_base == null) {
        // No common ancestor - try to merge anyway
        try platform_impl.writeStderr("fatal: refusing to merge unrelated histories\n");
        std.process.exit(128);
    }

    // Load trees for three-way merge
    const base_tree = getCommitTree(git_path, merge_base.?, allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: unable to read merge base tree\n");
        std.process.exit(128);
    };
    defer allocator.free(base_tree);

    const our_tree = getCommitTree(git_path, current_commit, allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: unable to read our tree\n");
        std.process.exit(128);
    };
    defer allocator.free(our_tree);

    const their_tree = getCommitTree(git_path, merge_hash, allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: unable to read their tree\n");
        std.process.exit(128);
    };
    defer allocator.free(their_tree);

    // Perform three-way merge
    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    var has_conflicts = false;
    const result_tree = threeWayMerge(git_path, repo_root, base_tree, our_tree, their_tree, allocator, platform_impl, &has_conflicts) catch {
        try platform_impl.writeStderr("Automatic merge failed; fix conflicts and then commit the result.\n");
        std.process.exit(1);
    };
    defer allocator.free(result_tree);

    if (has_conflicts) {
        // Write MERGE_HEAD and MERGE_MSG for conflict resolution
        const merge_head_path = try std.fmt.allocPrint(allocator, "{s}/MERGE_HEAD", .{git_path});
        defer allocator.free(merge_head_path);
        const merge_head_data = try std.fmt.allocPrint(allocator, "{s}\n", .{merge_hash});
        defer allocator.free(merge_head_data);
        std.fs.cwd().writeFile(.{ .sub_path = merge_head_path, .data = merge_head_data }) catch {};

        const merge_msg_path = try std.fmt.allocPrint(allocator, "{s}/MERGE_MSG", .{git_path});
        defer allocator.free(merge_msg_path);
        const merge_msg = try pullBuildMergeMessage(allocator, merge_branch, remote, fetch_head_desc);
        defer allocator.free(merge_msg);
        std.fs.cwd().writeFile(.{ .sub_path = merge_msg_path, .data = merge_msg }) catch {};

        try platform_impl.writeStderr("Automatic merge failed; fix conflicts and then commit the result.\n");
        std.process.exit(1);
    }

    // Create merge commit
    const merge_msg = try pullBuildMergeMessage(allocator, merge_branch, remote, fetch_head_desc);
    defer allocator.free(merge_msg);

    const author_str = pullGetAuthorString(allocator) catch try allocator.dupe(u8, "Unknown <unknown@unknown>");
    defer allocator.free(author_str);
    const committer_str = pullGetCommitterString(allocator) catch try allocator.dupe(u8, "Unknown <unknown@unknown>");
    defer allocator.free(committer_str);

    const parents = [_][]const u8{ current_commit, merge_hash };
    const new_commit = try objects.createCommitObject(result_tree, &parents, author_str, committer_str, merge_msg, allocator);
    defer new_commit.deinit(allocator);
    const new_hash = try new_commit.store(git_path, platform_impl, allocator);
    defer allocator.free(new_hash);

    try refs.updateRef(git_path, branch_name, new_hash, platform_impl, allocator);

    if (!quiet) {
        if (succinct_mod.isEnabled()) {
            const msg = try std.fmt.allocPrint(allocator, "ok pull {s} (merge)\n", .{branch_name});
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        } else {
            try platform_impl.writeStdout("Merge made by the 'ort' strategy.\n");
        }
    }
}

fn pullExtractTree(commit_data: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, commit_data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ") and line.len >= 45) {
            return line[5..45];
        }
    }
    return "";
}

fn pullBuildMergeMessage(allocator: std.mem.Allocator, merge_branch: ?[]const u8, remote: []const u8, fetch_head_desc: ?[]const u8) ![]u8 {
    if (fetch_head_desc) |desc| {
        // Strip " of <remote>" suffix when remote is "." (local repo) — matches git's fmt-merge-msg behavior
        const cleaned_desc = if (std.mem.eql(u8, remote, ".")) blk: {
            // Look for " of ." at the end of the description
            if (std.mem.endsWith(u8, desc, " of .")) {
                break :blk desc[0 .. desc.len - " of .".len];
            }
            break :blk desc;
        } else desc;
        return std.fmt.allocPrint(allocator, "Merge {s}", .{cleaned_desc});
    }
    if (merge_branch) |mb| {
        const branch = if (std.mem.startsWith(u8, mb, "refs/heads/"))
            mb["refs/heads/".len..]
        else
            mb;
        if (std.mem.eql(u8, remote, ".")) {
            return std.fmt.allocPrint(allocator, "Merge branch '{s}'", .{branch});
        }
        return std.fmt.allocPrint(allocator, "Merge branch '{s}' of {s}", .{ branch, remote });
    }
    return std.fmt.allocPrint(allocator, "Merge remote changes", .{});
}

fn pullGetAuthorString(allocator: std.mem.Allocator) ![]u8 {
    const name = std.posix.getenv("GIT_AUTHOR_NAME") orelse std.posix.getenv("GIT_COMMITTER_NAME") orelse "Unknown";
    const email = std.posix.getenv("GIT_AUTHOR_EMAIL") orelse std.posix.getenv("GIT_COMMITTER_EMAIL") orelse "unknown@unknown";
    const raw_date = std.posix.getenv("GIT_AUTHOR_DATE") orelse blk: {
        const ts = std.time.timestamp();
        const buf = try allocator.alloc(u8, 32);
        const len = std.fmt.bufPrint(buf, "{d} +0000", .{ts}) catch return error.FormatError;
        break :blk len;
    };
    const date = git_helpers_mod.parseDateToGitFormat(raw_date, allocator) catch try allocator.dupe(u8, raw_date);
    defer allocator.free(date);
    return std.fmt.allocPrint(allocator, "{s} <{s}> {s}", .{ name, email, date });
}

fn pullGetCommitterString(allocator: std.mem.Allocator) ![]u8 {
    const name = std.posix.getenv("GIT_COMMITTER_NAME") orelse std.posix.getenv("GIT_AUTHOR_NAME") orelse "Unknown";
    const email = std.posix.getenv("GIT_COMMITTER_EMAIL") orelse std.posix.getenv("GIT_AUTHOR_EMAIL") orelse "unknown@unknown";
    const raw_date = std.posix.getenv("GIT_COMMITTER_DATE") orelse blk: {
        const ts = std.time.timestamp();
        const buf = try allocator.alloc(u8, 32);
        const len = std.fmt.bufPrint(buf, "{d} +0000", .{ts}) catch return error.FormatError;
        break :blk len;
    };
    const date = git_helpers_mod.parseDateToGitFormat(raw_date, allocator) catch try allocator.dupe(u8, raw_date);
    defer allocator.free(date);
    return std.fmt.allocPrint(allocator, "{s} <{s}> {s}", .{ name, email, date });
}

fn getCommitTree(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) ![]u8 {
    const commit_obj = try objects.GitObject.load(commit_hash, git_path, platform_impl, allocator);
    defer commit_obj.deinit(allocator);
    const tree_hash = pullExtractTree(commit_obj.data);
    if (tree_hash.len == 0) return error.NoTree;
    return allocator.dupe(u8, tree_hash);
}

fn findMergeBase(git_path: []const u8, hash1: []const u8, hash2: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) ?[]u8 {
    // Simple merge-base: find common ancestor by walking both histories
    // Collect ancestors of hash1
    var ancestors1 = std.StringHashMap(void).init(allocator);
    defer ancestors1.deinit();

    var queue1 = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (queue1.items) |item| allocator.free(item);
        queue1.deinit();
    }

    queue1.append(allocator.dupe(u8, hash1) catch return null) catch return null;
    var depth: usize = 0;
    while (queue1.items.len > 0 and depth < 10000) : (depth += 1) {
        const current = queue1.orderedRemove(0);
        defer allocator.free(current);
        if (ancestors1.contains(current)) continue;
        ancestors1.put(allocator.dupe(u8, current) catch continue, {}) catch continue;
        // Get parents
        const obj = objects.GitObject.load(current, git_path, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);
        if (obj.type != .commit) continue;
        var lines = std.mem.splitScalar(u8, obj.data, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ") and line.len >= 47) {
                queue1.append(allocator.dupe(u8, line[7..47]) catch continue) catch {};
            }
            if (line.len == 0) break; // End of headers
        }
    }

    // Walk hash2's history and find first common ancestor
    var queue2 = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (queue2.items) |item| allocator.free(item);
        queue2.deinit();
    }
    var visited2 = std.StringHashMap(void).init(allocator);
    defer visited2.deinit();

    queue2.append(allocator.dupe(u8, hash2) catch return null) catch return null;
    depth = 0;
    while (queue2.items.len > 0 and depth < 10000) : (depth += 1) {
        const current = queue2.orderedRemove(0);
        if (visited2.contains(current)) {
            allocator.free(current);
            continue;
        }
        if (ancestors1.contains(current)) {
            // Found merge base - duplicate since current will be freed
            return allocator.dupe(u8, current) catch null;
        }
        visited2.put(allocator.dupe(u8, current) catch {
            allocator.free(current);
            continue;
        }, {}) catch {};
        // Get parents
        const obj = objects.GitObject.load(current, git_path, platform_impl, allocator) catch {
            allocator.free(current);
            continue;
        };
        defer obj.deinit(allocator);
        if (obj.type != .commit) {
            allocator.free(current);
            continue;
        }
        var lines = std.mem.splitScalar(u8, obj.data, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ") and line.len >= 47) {
                queue2.append(allocator.dupe(u8, line[7..47]) catch continue) catch {};
            }
            if (line.len == 0) break;
        }
        allocator.free(current);
    }

    return null;
}

/// Collect conflicting files when pulling into void
fn collectPullIntoVoidConflicts(git_path: []const u8, commit_hash: []const u8, repo_root: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform, conflicts: *std.array_list.Managed([]u8)) !void {
    const commit_obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch return;
    defer commit_obj.deinit(allocator);
    if (commit_obj.type != .commit) return;

    const tree_hash = pullExtractTree(commit_obj.data);
    if (tree_hash.len == 0) return;

    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch return;
    defer tree_obj.deinit(allocator);
    if (tree_obj.type != .tree) return;

    if (@import("builtin").target.os.tag == .freestanding) return;

    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch index_mod.Index.init(allocator);
    defer idx.deinit();

    try collectTreeConflicts(git_path, tree_obj.data, repo_root, "", &idx, allocator, platform_impl, conflicts);
}

fn collectTreeConflicts(git_path: []const u8, tree_data: []const u8, repo_root: []const u8, prefix: []const u8, idx: *index_mod.Index, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform, conflicts: *std.array_list.Managed([]u8)) !void {
    var i: usize = 0;
    while (i < tree_data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, tree_data, i, ' ') orelse break;
        const mode_str = tree_data[i..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, tree_data, space_pos + 1, 0) orelse break;
        const name = tree_data[space_pos + 1 .. null_pos];
        if (null_pos + 20 > tree_data.len) break;
        const raw_hash = tree_data[null_pos + 1 .. null_pos + 21];

        var hash_buf: [40]u8 = undefined;
        for (raw_hash, 0..) |byte, bi| {
            const hex = "0123456789abcdef";
            hash_buf[bi * 2] = hex[byte >> 4];
            hash_buf[bi * 2 + 1] = hex[byte & 0xf];
        }

        const full_path = if (prefix.len > 0)
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name }) catch {
                i = null_pos + 21;
                continue;
            }
        else
            allocator.dupe(u8, name) catch {
                i = null_pos + 21;
                continue;
            };

        if (std.mem.eql(u8, mode_str, "40000")) {
            defer allocator.free(full_path);
            const sub_tree = objects.GitObject.load(hash_buf[0..40], git_path, platform_impl, allocator) catch {
                i = null_pos + 21;
                continue;
            };
            defer sub_tree.deinit(allocator);
            if (sub_tree.type == .tree) {
                try collectTreeConflicts(git_path, sub_tree.data, repo_root, full_path, idx, allocator, platform_impl, conflicts);
            }
        } else {
            const fs_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, full_path }) catch {
                allocator.free(full_path);
                i = null_pos + 21;
                continue;
            };
            defer allocator.free(fs_path);

            if (std.fs.cwd().access(fs_path, .{})) |_| {
                // File exists - conflict (either untracked or staged with different content)
                try conflicts.append(full_path);
            } else |_| {
                allocator.free(full_path);
            }
        }

        i = null_pos + 21;
    }
}

/// Checkout a commit's tree to the working directory
fn checkoutCommitTreePull(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    try checkoutCommitTreePullOpts(git_path, commit_hash, allocator, platform_impl, true);
}

fn checkoutCommitTreePullOpts(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform, clear_tracked: bool) !void {
    const commit_obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch return error.InvalidCommit;
    defer commit_obj.deinit(allocator);
    if (commit_obj.type != .commit) return error.NotACommit;

    const tree_hash = pullExtractTree(commit_obj.data);
    if (tree_hash.len == 0) return error.NoTree;

    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch return error.InvalidTree;
    defer tree_obj.deinit(allocator);
    if (tree_obj.type != .tree) return error.NotATree;

    const repo_root = std.fs.path.dirname(git_path) orelse ".";

    // Clear existing tracked files (skip for pull-into-void to preserve staged files)
    if (clear_tracked) {
        clearTrackedFiles(git_path, repo_root, allocator, platform_impl);
    }

    // Checkout tree recursively
    try checkoutTreeRec(git_path, tree_obj.data, repo_root, "", allocator, platform_impl);

    // Update index - preserve existing entries not in the tree
    try updateIndexFromTreeHashMerge(git_path, tree_hash, allocator, platform_impl, !clear_tracked);
}

fn clearTrackedFiles(git_path: []const u8, repo_root: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) void {
    if (@import("builtin").target.os.tag == .freestanding) return;
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
    defer idx.deinit();

    var dir = std.fs.cwd().openDir(repo_root, .{}) catch return;
    defer dir.close();

    // Collect parent dirs
    var parent_dirs = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (parent_dirs.items) |p| allocator.free(p);
        parent_dirs.deinit();
    }

    for (idx.entries.items) |entry| {
        dir.deleteFile(entry.path) catch {};
        if (std.fs.path.dirname(entry.path)) |parent| {
            parent_dirs.append(allocator.dupe(u8, parent) catch continue) catch {};
        }
    }

    // Remove empty parent directories
    var pass: u32 = 0;
    while (pass < 10) : (pass += 1) {
        var removed = false;
        for (parent_dirs.items) |parent| {
            dir.deleteDir(parent) catch continue;
            removed = true;
        }
        if (!removed) break;
    }
}

fn checkoutTreeRec(git_path: []const u8, tree_data: []const u8, repo_root: []const u8, current_path: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    var i: usize = 0;
    while (i < tree_data.len) {
        // Parse "<mode> <name>\0<20-byte-hash>"
        const space_pos = std.mem.indexOfScalarPos(u8, tree_data, i, ' ') orelse break;
        const mode_str = tree_data[i..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, tree_data, space_pos + 1, 0) orelse break;
        const name = tree_data[space_pos + 1 .. null_pos];
        if (null_pos + 20 > tree_data.len) break;
        const raw_hash = tree_data[null_pos + 1 .. null_pos + 21];

        // Convert binary hash to hex
        var hash_buf: [40]u8 = undefined;
        for (raw_hash, 0..) |byte, idx| {
            const hex = "0123456789abcdef";
            hash_buf[idx * 2] = hex[byte >> 4];
            hash_buf[idx * 2 + 1] = hex[byte & 0xf];
        }
        const hash = hash_buf[0..40];

        const full_path = if (current_path.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_path, name })
        else
            try allocator.dupe(u8, name);
        defer allocator.free(full_path);

        const fs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, full_path });
        defer allocator.free(fs_path);

        if (std.mem.eql(u8, mode_str, "40000")) {
            // Directory - recurse
            const sub_tree = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch continue;
            defer sub_tree.deinit(allocator);
            if (sub_tree.type == .tree) {
                std.fs.cwd().makePath(fs_path) catch {};
                try checkoutTreeRec(git_path, sub_tree.data, repo_root, full_path, allocator, platform_impl);
            }
        } else {
            // File - write blob
            const blob = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch continue;
            defer blob.deinit(allocator);
            if (blob.type == .blob) {
                // Ensure parent dir exists
                if (std.fs.path.dirname(fs_path)) |parent| {
                    std.fs.cwd().makePath(parent) catch {};
                }
                std.fs.cwd().writeFile(.{ .sub_path = fs_path, .data = blob.data }) catch {};

                // Set executable bit if mode is 100755
                if (std.mem.eql(u8, mode_str, "100755")) {
                    const file = std.fs.cwd().openFile(fs_path, .{}) catch continue;
                    defer file.close();
                    file.chmod(0o755) catch {};
                }
            }
        }

        i = null_pos + 21;
    }
}

fn updateIndexFromTreeHash(git_path: []const u8, tree_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    try updateIndexFromTreeHashMerge(git_path, tree_hash, allocator, platform_impl, false);
}

fn updateIndexFromTreeHashMerge(git_path: []const u8, tree_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform, preserve_existing: bool) !void {
    if (@import("builtin").target.os.tag == .freestanding) return;

    var idx: index_mod.Index = undefined;
    if (preserve_existing) {
        // Load existing index and merge with tree entries
        idx = index_mod.Index.load(git_path, platform_impl, allocator) catch index_mod.Index.init(allocator);
    } else {
        idx = index_mod.Index.init(allocator);
    }
    defer idx.deinit();

    // Walk tree recursively and add all entries
    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch return;
    defer tree_obj.deinit(allocator);
    if (tree_obj.type != .tree) return;

    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    try addTreeToIndex(&idx, git_path, repo_root, tree_obj.data, "", allocator, platform_impl);

    idx.save(git_path, platform_impl) catch {};
}

fn addTreeToIndex(idx: *index_mod.Index, git_path: []const u8, repo_root: []const u8, tree_data: []const u8, prefix: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    var i: usize = 0;
    while (i < tree_data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, tree_data, i, ' ') orelse break;
        const mode_str = tree_data[i..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, tree_data, space_pos + 1, 0) orelse break;
        const name = tree_data[space_pos + 1 .. null_pos];
        if (null_pos + 20 > tree_data.len) break;
        const raw_hash = tree_data[null_pos + 1 .. null_pos + 21];

        var hash_buf: [40]u8 = undefined;
        for (raw_hash, 0..) |byte, bidx| {
            const hex = "0123456789abcdef";
            hash_buf[bidx * 2] = hex[byte >> 4];
            hash_buf[bidx * 2 + 1] = hex[byte & 0xf];
        }

        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);
        defer allocator.free(full_path);

        if (std.mem.eql(u8, mode_str, "40000")) {
            // Recurse into subtree
            const sub_tree = objects.GitObject.load(hash_buf[0..40], git_path, platform_impl, allocator) catch {
                i = null_pos + 21;
                continue;
            };
            defer sub_tree.deinit(allocator);
            if (sub_tree.type == .tree) {
                try addTreeToIndex(idx, git_path, repo_root, sub_tree.data, full_path, allocator, platform_impl);
            }
        } else {
            // Add file entry to index
            const fs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, full_path });
            defer allocator.free(fs_path);
            idx.add(full_path, fs_path, platform_impl, git_path) catch {};
        }

        i = null_pos + 21;
    }
}

/// Three-way merge of tree hashes, returns result tree hash
fn threeWayMerge(
    git_path: []const u8,
    repo_root: []const u8,
    base_tree: []const u8,
    _: []const u8,
    their_tree: []const u8,
    allocator: std.mem.Allocator,
    platform_impl: *const platform_mod.Platform,
    has_conflicts: *bool,
) ![]u8 {
    _ = base_tree;
    // Simplified: just use "their" tree for now (like a fast-forward)
    // For a real three-way merge, we'd need to compare all three trees
    // and handle conflicts. This is a placeholder.
    _ = repo_root;
    _ = has_conflicts;

    // Checkout their tree
    try checkoutCommitTreePull(git_path, their_tree, allocator, platform_impl);

    // For the merge commit, use their tree
    const their_commit = objects.GitObject.load(their_tree, git_path, platform_impl, allocator) catch {
        return allocator.dupe(u8, their_tree);
    };
    defer their_commit.deinit(allocator);
    if (their_commit.type == .commit) {
        return allocator.dupe(u8, pullExtractTree(their_commit.data));
    }
    return allocator.dupe(u8, their_tree);
}
