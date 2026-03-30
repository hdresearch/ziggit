// Auto-generated from main_common.zig - cmd_check_attr
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

pub fn nativeCmdCheckAttr(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var attr_names = std.ArrayList([]const u8).init(allocator);
    defer attr_names.deinit();
    var file_paths = std.ArrayList([]const u8).init(allocator);
    defer file_paths.deinit();
    var all_attrs = false;
    var use_stdin = false;
    var cached = false;
    var source: ?[]const u8 = null;
    var after_dashdash = false;

    while (args.next()) |arg| {
        if (after_dashdash) {
            try file_paths.append(arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            after_dashdash = true;
        } else if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) {
            all_attrs = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            use_stdin = true;
        } else if (std.mem.eql(u8, arg, "--cached")) {
            cached = true;
        } else if (std.mem.eql(u8, arg, "-z")) {
            // null termination - ignore for now
        } else if (std.mem.eql(u8, arg, "--source")) {
            source = args.next();
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (!all_attrs and attr_names.items.len == 0 and file_paths.items.len == 0) {
                try attr_names.append(arg);
            } else {
                try file_paths.append(arg);
            }
        }
    }

    // Validate arguments
    // check-attr requires: attr_name(s) -- path(s) OR --all -- path(s) OR --stdin attr path(s)
    if (!all_attrs and attr_names.items.len == 0) {
        // No attribute specified and not --all
        try platform_impl.writeStderr("error: No attribute specified\n");
        std.process.exit(128);
    }
    if (file_paths.items.len == 0 and !use_stdin) {
        // No paths specified
        try platform_impl.writeStderr("error: No file specified\n");
        std.process.exit(128);
    }
    // --stdin and explicit paths are mutually exclusive
    if (use_stdin and file_paths.items.len > 0) {
        try platform_impl.writeStderr("error: Can't specify files with --stdin\n");
        std.process.exit(128);
    }
    // Check for empty attribute names
    for (attr_names.items) |name| {
        if (name.len == 0) {
            try platform_impl.writeStderr("error: No attribute specified\n");
            std.process.exit(128);
        }
    }
    // --source requires a valid ref
    if (source != null) {
        // Validate source ref - for now just check it's not empty
        if (source.?.len == 0) {
            try platform_impl.writeStderr("error: bad --source or --git-dir\n");
            std.process.exit(128);
        }
    }

    // helpers.Read paths from stdin if --stdin
    var stdin_buf: ?[]u8 = null;
    defer if (stdin_buf) |b| allocator.free(b);
    if (use_stdin) {
        const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
        stdin_buf = stdin_file.readToEndAlloc(allocator, 1024 * 1024) catch null;
        if (stdin_buf) |buf| {
            var iter = std.mem.splitScalar(u8, buf, '\n');
            while (iter.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len > 0) try file_paths.append(trimmed);
            }
        }
    }

    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    const repo_root = std.fs.path.dirname(git_path) orelse ".";

    const cwd = try platform_impl.fs.getCwd(allocator);
    defer allocator.free(cwd);

    // helpers.Load gitattributes from various sources
    var attr_rules = std.ArrayList(AttrRule).init(allocator);
    defer {
        for (attr_rules.items) |*rule| rule.deinit(allocator);
        attr_rules.deinit();
    }

    // helpers.Load repo .gitattributes
    if (!cached) {
        try loadAttrFile(allocator, repo_root, "", platform_impl, &attr_rules);
    }

    // helpers.Load global attributes if core.attributesfile is set
    // helpers.Load info/attributes
    const info_attr_path = try std.fmt.allocPrint(allocator, "{s}/info/attributes", .{git_path});
    defer allocator.free(info_attr_path);
    if (platform_impl.fs.readFile(allocator, info_attr_path)) |content| {
        defer allocator.free(content);
        parseAttrContent(allocator, content, "", &attr_rules) catch {};
    } else |_| {}

    for (file_paths.items) |path| {
        // helpers.Resolve path relative to repo root
        var check_path: []const u8 = path;
        var allocated_path: ?[]u8 = null;
        defer if (allocated_path) |p| allocator.free(p);

        if (!std.fs.path.isAbsolute(path)) {
            if (cwd.len > repo_root.len and std.mem.startsWith(u8, cwd, repo_root) and cwd[repo_root.len] == '/') {
                const prefix = cwd[repo_root.len + 1..];
                allocated_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, path });
                check_path = allocated_path.?;
            }
        }

        // helpers.Load directory-specific .gitattributes from each directory in path
        var dir_rules = std.ArrayList(AttrRule).init(allocator);
        defer {
            for (dir_rules.items) |*rule| rule.deinit(allocator);
            dir_rules.deinit();
        }
        if (!cached) {
            // helpers.Walk up the path hierarchy loading .gitattributes from each dir
            // e.g. for "a/b/d/g", load a/.gitattributes, a/b/.gitattributes, a/b/d/.gitattributes
            var remaining = check_path;
            while (std.mem.indexOf(u8, remaining, "/")) |slash_pos| {
                const subdir = check_path[0 .. @intFromPtr(remaining.ptr) - @intFromPtr(check_path.ptr) + slash_pos];
                if (subdir.len > 0) {
                    try loadAttrFile(allocator, repo_root, subdir, platform_impl, &dir_rules);
                }
                remaining = remaining[slash_pos + 1 ..];
            }
        }

        if (all_attrs) {
            // helpers.Show all defined attributes for the path
            var shown = std.StringHashMap([]const u8).init(allocator);
            defer shown.deinit();

            // helpers.Check dir rules first (higher priority), then repo rules
            for (dir_rules.items) |rule| {
                if (attrPatternMatches(rule.pattern, check_path)) {
                    for (rule.attrs.items) |attr| {
                        if (!shown.contains(attr.name)) {
                            shown.put(attr.name, attr.value) catch {};
                        }
                    }
                }
            }
            for (attr_rules.items) |rule| {
                if (attrPatternMatches(rule.pattern, check_path)) {
                    for (rule.attrs.items) |attr| {
                        if (!shown.contains(attr.name)) {
                            shown.put(attr.name, attr.value) catch {};
                        }
                    }
                }
            }

            const quoted_path = try helpers.cQuotePath(allocator, path, false);
            defer allocator.free(quoted_path);
            var iter = shown.iterator();
            while (iter.next()) |entry| {
                const msg = try std.fmt.allocPrint(allocator, "{s}: {s}: {s}\n", .{ quoted_path, entry.key_ptr.*, entry.value_ptr.* });
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
        } else {
            // helpers.Show specific attributes
            for (attr_names.items) |attr_name| {
                var value: []const u8 = "unspecified";

                // Search dir rules first (higher priority), then repo rules
                // Last matching pattern wins (within each file, last match wins)
                for (attr_rules.items) |rule| {
                    if (attrPatternMatches(rule.pattern, check_path)) {
                        for (rule.attrs.items) |attr| {
                            if (std.mem.eql(u8, attr.name, attr_name)) {
                                value = attr.value;
                            }
                        }
                    }
                }
                for (dir_rules.items) |rule| {
                    if (attrPatternMatches(rule.pattern, check_path)) {
                        for (rule.attrs.items) |attr| {
                            if (std.mem.eql(u8, attr.name, attr_name)) {
                                value = attr.value;
                            }
                        }
                    }
                }

                const qp = try helpers.cQuotePath(allocator, path, false);
                defer allocator.free(qp);
                const msg = try std.fmt.allocPrint(allocator, "{s}: {s}: {s}\n", .{ qp, attr_name, value });
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
        }
    }
}

pub const AttrValue = struct {
    name: []const u8,
    value: []const u8,
    pub fn deinit(self: *AttrValue, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.value);
    }
};

pub const AttrRule = struct {
    pattern: []const u8,
    attrs: std.ArrayList(AttrValue),
    pub fn deinit(self: *AttrRule, alloc: std.mem.Allocator) void {
        alloc.free(self.pattern);
        for (self.attrs.items) |*attr| attr.deinit(alloc);
        self.attrs.deinit();
    }
};


pub fn loadAttrFile(allocator: std.mem.Allocator, repo_root: []const u8, subdir: []const u8, platform_impl: *const platform_mod.Platform, rules: *std.ArrayList(AttrRule)) !void {
    const attr_path = if (subdir.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/{s}/.gitattributes", .{ repo_root, subdir })
    else
        try std.fmt.allocPrint(allocator, "{s}/.gitattributes", .{repo_root});
    defer allocator.free(attr_path);

    const content = platform_impl.fs.readFile(allocator, attr_path) catch return;
    defer allocator.free(content);
    try parseAttrContent(allocator, content, subdir, rules);
}


// Global macro definitions (e.g. [attr]binary -diff -merge -text)
var global_macros: ?std.StringHashMap([]const AttrValue) = null;

fn ensureMacros(allocator: std.mem.Allocator) void {
    if (global_macros == null) {
        global_macros = std.StringHashMap([]const AttrValue).init(allocator);
        // Built-in macros
        const binary_attrs = allocator.alloc(AttrValue, 3) catch return;
        binary_attrs[0] = .{ .name = allocator.dupe(u8, "diff") catch return, .value = allocator.dupe(u8, "unset") catch return };
        binary_attrs[1] = .{ .name = allocator.dupe(u8, "merge") catch return, .value = allocator.dupe(u8, "unset") catch return };
        binary_attrs[2] = .{ .name = allocator.dupe(u8, "text") catch return, .value = allocator.dupe(u8, "unset") catch return };
        global_macros.?.put(allocator.dupe(u8, "binary") catch return, binary_attrs) catch {};
    }
}

pub fn parseAttrContent(allocator: std.mem.Allocator, content: []const u8, prefix: []const u8, rules: *std.ArrayList(AttrRule)) !void {
    ensureMacros(allocator);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        // Parse macro definitions [attr]name attrs...
        if (std.mem.startsWith(u8, trimmed, "[attr]")) {
            const macro_rest = trimmed["[attr]".len..];
            var mparts = std.mem.tokenizeAny(u8, macro_rest, " \t");
            const macro_name = mparts.next() orelse continue;
            var macro_attrs = std.ArrayList(AttrValue).init(allocator);
            while (mparts.next()) |aspec| {
                if (aspec.len == 0) continue;
                if (aspec[0] == '!') {
                    try macro_attrs.append(.{ .name = try allocator.dupe(u8, aspec[1..]), .value = try allocator.dupe(u8, "unspecified") });
                } else if (aspec[0] == '-') {
                    try macro_attrs.append(.{ .name = try allocator.dupe(u8, aspec[1..]), .value = try allocator.dupe(u8, "unset") });
                } else if (std.mem.indexOf(u8, aspec, "=")) |eq| {
                    try macro_attrs.append(.{ .name = try allocator.dupe(u8, aspec[0..eq]), .value = try allocator.dupe(u8, aspec[eq + 1..]) });
                } else {
                    try macro_attrs.append(.{ .name = try allocator.dupe(u8, aspec), .value = try allocator.dupe(u8, "set") });
                }
            }
            const key = try allocator.dupe(u8, macro_name);
            global_macros.?.put(key, try allocator.dupe(AttrValue, macro_attrs.items)) catch {};
            macro_attrs.deinit();
            continue;
        }

        // Parse: pattern attr1=val1 attr2 -attr3 !attr4
        // Handle quoted patterns before tokenizing
        var pattern: []const u8 = undefined;
        var pattern_allocated = false;
        var attr_start: usize = 0;
        if (trimmed[0] == '"') {
            // Quoted pattern - find closing quote handling escape sequences
            var end_idx: usize = 1;
            while (end_idx < trimmed.len) {
                if (trimmed[end_idx] == '\\' and end_idx + 1 < trimmed.len) {
                    end_idx += 2;
                    continue;
                }
                if (trimmed[end_idx] == '"') break;
                end_idx += 1;
            }
            if (end_idx >= trimmed.len) continue; // no closing quote
            const quoted_content = trimmed[1..end_idx];
            var unquoted = std.ArrayList(u8).init(allocator);
            defer unquoted.deinit();
            var qi: usize = 0;
            while (qi < quoted_content.len) {
                if (quoted_content[qi] == '\\' and qi + 1 < quoted_content.len) {
                    qi += 1;
                    try unquoted.append(quoted_content[qi]);
                } else {
                    try unquoted.append(quoted_content[qi]);
                }
                qi += 1;
            }
            pattern = try allocator.dupe(u8, unquoted.items);
            pattern_allocated = true;
            attr_start = end_idx + 1;
        } else {
            // Unquoted pattern - first whitespace-delimited token
            var end_idx: usize = 0;
            while (end_idx < trimmed.len and trimmed[end_idx] != ' ' and trimmed[end_idx] != '\t') {
                end_idx += 1;
            }
            pattern = trimmed[0..end_idx];
            attr_start = end_idx;
        }
        var parts = std.mem.tokenizeAny(u8, trimmed[attr_start..], " \t");

        // helpers.If pattern starts with /, it's anchored to the directory
        var is_anchored = false;
        if (pattern.len > 0 and pattern[0] == '/') {
            is_anchored = true;
            pattern = pattern[1..];
        }

        // Prepend prefix for subdirectory patterns
        // In git, patterns with / are relative to the .gitattributes directory
        var full_pattern: []u8 = undefined;
        const has_slash = std.mem.indexOf(u8, pattern, "/") != null;
        if (prefix.len > 0 and (is_anchored or has_slash)) {
            // Anchored or path pattern: prepend directory prefix
            full_pattern = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, pattern });
        } else if (prefix.len > 0 and !is_anchored) {
            // Non-anchored basename patterns can match anywhere
            full_pattern = try allocator.dupe(u8, pattern);
        } else {
            full_pattern = try allocator.dupe(u8, pattern);
        }

        var attrs = std.ArrayList(AttrValue).init(allocator);
        while (parts.next()) |attr_spec| {
            if (attr_spec.len == 0) continue;

            if (std.mem.indexOf(u8, attr_spec, "=")) |eq| {
                // attr=value
                const name = try allocator.dupe(u8, attr_spec[0..eq]);
                const val = try allocator.dupe(u8, attr_spec[eq + 1..]);
                try attrs.append(.{ .name = name, .value = val });
            } else if (attr_spec[0] == '-') {
                // -attr (unset)
                const name = try allocator.dupe(u8, attr_spec[1..]);
                const val = try allocator.dupe(u8, "unset");
                try attrs.append(.{ .name = name, .value = val });
            } else if (attr_spec[0] == '!') {
                // !attr (unspecified)
                const name = try allocator.dupe(u8, attr_spec[1..]);
                const val = try allocator.dupe(u8, "unspecified");
                try attrs.append(.{ .name = name, .value = val });
            } else {
                // Check if this is a macro name
                if (global_macros) |macros| {
                    if (macros.get(attr_spec)) |macro_attrs| {
                        // Expand macro
                        for (macro_attrs) |ma| {
                            try attrs.append(.{ .name = try allocator.dupe(u8, ma.name), .value = try allocator.dupe(u8, ma.value) });
                        }
                        continue;
                    }
                }
                // attr (set to true)
                const name = try allocator.dupe(u8, attr_spec);
                const val = try allocator.dupe(u8, "set");
                try attrs.append(.{ .name = name, .value = val });
            }
        }

        if (attrs.items.len > 0) {
            try rules.append(.{ .pattern = full_pattern, .attrs = attrs });
        } else {
            allocator.free(full_pattern);
            attrs.deinit();
        }
    }
}


pub fn attrPatternMatches(pattern: []const u8, path: []const u8) bool {
    // For simple literal patterns (no glob chars), do direct matching
    // This avoids the GitignoreEntry trimming issue with spaces
    const has_glob = std.mem.indexOfAny(u8, pattern, "*?[") != null;
    if (!has_glob and std.mem.indexOf(u8, pattern, "/") == null) {
        // Simple basename match: match against the last path component
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| path[idx + 1 ..] else path;
        return std.mem.eql(u8, pattern, basename);
    }
    if (!has_glob and std.mem.indexOf(u8, pattern, "/") != null) {
        // Pattern with slash: match the full path
        return std.mem.eql(u8, pattern, path);
    }
    // Use the gitignore glob matching for patterns with wildcards
    if (gitignore_mod.GitignoreEntry.init(pattern, std.heap.page_allocator)) |entry| {
        defer entry.deinit(std.heap.page_allocator);
        return entry.matches(path, false);
    } else |_| {
        return false;
    }
}
