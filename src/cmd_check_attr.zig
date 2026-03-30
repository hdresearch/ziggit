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
    var attr_names = std.array_list.Managed([]const u8).init(allocator);
    defer attr_names.deinit();
    var file_paths = std.array_list.Managed([]const u8).init(allocator);
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

    // Load config to check core.ignorecase and core.attributesfile
    var ignore_case = false;
    var global_attr_file: ?[]const u8 = null;
    defer if (global_attr_file) |f| allocator.free(f);
    {
        const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch null;
        defer if (config_path) |p| allocator.free(p);
        if (config_path) |cp| {
            var cfg = config_mod.GitConfig.init(allocator);
            defer cfg.deinit();
            cfg.parseFromFile(cp) catch {};
            ignore_case = config_mod.getIgnoreCase(cfg);
            if (cfg.get("core", null, "attributesfile")) |f| {
                // Handle ~ expansion
                if (std.mem.startsWith(u8, f, "~/")) {
                    const home = std.posix.getenv("HOME") orelse "";
                    global_attr_file = std.fmt.allocPrint(allocator, "{s}{s}", .{ home, f[1..] }) catch null;
                } else {
                    global_attr_file = allocator.dupe(u8, f) catch null;
                }
            }
        }
        // Check CLI -c overrides (via global config overrides set by main)
        if (helpers.getConfigOverride("core.ignorecase")) |val| {
            ignore_case = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        }
        if (helpers.getConfigOverride("core.attributesfile")) |val| {
            if (global_attr_file) |f| allocator.free(f);
            global_attr_file = allocator.dupe(u8, val) catch null;
        }
    }

    // helpers.Load gitattributes from various sources
    var attr_rules = std.array_list.Managed(AttrRule).init(allocator);
    defer {
        for (attr_rules.items) |*rule| rule.deinit(allocator);
        attr_rules.deinit();
    }

    // Load in order of increasing precedence (last match wins):
    // 1. Global attributes (core.attributesfile) - lowest precedence
    if (global_attr_file) |gaf| {
        if (platform_impl.fs.readFile(allocator, gaf)) |content| {
            defer allocator.free(content);
            parseAttrContent(allocator, content, "", &attr_rules) catch {};
        } else |_| {}
    }
    // 2. $GIT_DIR/info/attributes
    const info_attr_path = try std.fmt.allocPrint(allocator, "{s}/info/attributes", .{git_path});
    defer allocator.free(info_attr_path);
    if (platform_impl.fs.readFile(allocator, info_attr_path)) |content| {
        defer allocator.free(content);
        parseAttrContent(allocator, content, "", &attr_rules) catch {};
    } else |_| {}
    // 3. Root .gitattributes - highest precedence among repo-level rules
    if (!cached) {
        try loadAttrFile(allocator, repo_root, "", platform_impl, &attr_rules);
    } else {
        // --cached: still load from worktree for now (TODO: load from index)
        try loadAttrFile(allocator, repo_root, "", platform_impl, &attr_rules);
    }

    // Emit warning if negative patterns were seen
    if (saw_negative_pattern) {
        try platform_impl.writeStderr("Negative patterns are ignored in git attributes\n");
    }

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
        var dir_rules = std.array_list.Managed(AttrRule).init(allocator);
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
            // Use ordered lists to preserve attribute encounter order
            var shown_names = std.array_list.Managed([]const u8).init(allocator);
            defer shown_names.deinit();
            var shown_values = std.array_list.Managed([]const u8).init(allocator);
            defer shown_values.deinit();

            // Collect all matching attributes. Last match wins within a file,
            // and dir-specific rules override repo-level rules.
            // First apply repo-level rules, then dir rules (dir rules override).
            for (attr_rules.items) |rule| {
                if (attrPatternMatches(rule.pattern, check_path, ignore_case)) {
                    for (rule.attrs.items) |attr| {
                        // Update existing or append
                        var found = false;
                        for (shown_names.items, 0..) |n, idx| {
                            if (std.mem.eql(u8, n, attr.name)) {
                                shown_values.items[idx] = attr.value;
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            shown_names.append(attr.name) catch {};
                            shown_values.append(attr.value) catch {};
                        }
                    }
                }
            }
            for (dir_rules.items) |rule| {
                if (attrPatternMatches(rule.pattern, check_path, ignore_case)) {
                    for (rule.attrs.items) |attr| {
                        var found = false;
                        for (shown_names.items, 0..) |n, idx| {
                            if (std.mem.eql(u8, n, attr.name)) {
                                shown_values.items[idx] = attr.value;
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            shown_names.append(attr.name) catch {};
                            shown_values.append(attr.value) catch {};
                        }
                    }
                }
            }

            const quoted_path = try helpers.cQuotePath(allocator, path, false);
            defer allocator.free(quoted_path);
            for (shown_names.items, 0..) |name, idx| {
                const value = shown_values.items[idx];
                // In --all mode, don't show 'unspecified' attributes
                if (std.mem.eql(u8, value, "unspecified")) continue;
                const msg = try std.fmt.allocPrint(allocator, "{s}: {s}: {s}\n", .{ quoted_path, name, value });
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
        } else {
            // helpers.Show specific attributes
            for (attr_names.items) |attr_name| {
                var value: []const u8 = "unspecified";

                // Search repo rules first, then dir rules (dir rules override)
                // Last matching pattern wins (within each file, last match wins)
                for (attr_rules.items) |rule| {
                    if (attrPatternMatches(rule.pattern, check_path, ignore_case)) {
                        for (rule.attrs.items) |attr| {
                            if (std.mem.eql(u8, attr.name, attr_name)) {
                                value = attr.value;
                            }
                        }
                    }
                }
                for (dir_rules.items) |rule| {
                    if (attrPatternMatches(rule.pattern, check_path, ignore_case)) {
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
    attrs: std.array_list.Managed(AttrValue),
    pub fn deinit(self: *AttrRule, alloc: std.mem.Allocator) void {
        alloc.free(self.pattern);
        for (self.attrs.items) |*attr| attr.deinit(alloc);
        self.attrs.deinit();
    }
};


pub fn loadAttrFile(allocator: std.mem.Allocator, repo_root: []const u8, subdir: []const u8, platform_impl: *const platform_mod.Platform, rules: *std.array_list.Managed(AttrRule)) !void {
    const attr_path = if (subdir.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/{s}/.gitattributes", .{ repo_root, subdir })
    else
        try std.fmt.allocPrint(allocator, "{s}/.gitattributes", .{repo_root});
    defer allocator.free(attr_path);

    const content = platform_impl.fs.readFile(allocator, attr_path) catch return;
    defer allocator.free(content);
    try parseAttrContent(allocator, content, subdir, rules);
}


pub fn loadAttrFilesFromIndex(allocator: std.mem.Allocator, git_dir: []const u8, platform_impl: *const platform_mod.Platform, rules: *std.array_list.Managed(AttrRule)) !void {
    var idx = index_mod.Index.load(git_dir, platform_impl, allocator) catch return;
    defer idx.deinit();

    // Collect all .gitattributes entries, sorted by depth (shallowest first)
    var attr_entries = std.array_list.Managed(struct { path: []const u8, sha1: [20]u8, depth: usize }).init(allocator);
    defer attr_entries.deinit();

    for (idx.entries.items) |entry| {
        if (std.mem.endsWith(u8, entry.path, "/.gitattributes") or std.mem.eql(u8, entry.path, ".gitattributes")) {
            const depth = std.mem.count(u8, entry.path, "/");
            attr_entries.append(.{ .path = entry.path, .sha1 = entry.sha1, .depth = depth }) catch continue;
        }
    }

    // Sort by depth so root .gitattributes is processed first
    std.sort.block(@TypeOf(attr_entries.items[0]), attr_entries.items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(attr_entries.items[0]), b: @TypeOf(attr_entries.items[0])) bool {
            return a.depth < b.depth;
        }
    }.lessThan);

    const objects_dir = std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir}) catch return;
    defer allocator.free(objects_dir);

    for (attr_entries.items) |ae| {
        // Get the prefix (directory containing .gitattributes)
        const prefix = if (std.mem.eql(u8, ae.path, ".gitattributes"))
            @as([]const u8, "")
        else if (std.mem.lastIndexOfScalar(u8, ae.path, '/')) |idx2|
            ae.path[0..idx2]
        else
            @as([]const u8, "");

        // Read blob content
        var hash_hex: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_hex, "{}", .{std.fmt.fmtSliceHexLower(&ae.sha1)}) catch continue;
        var obj = objects.GitObject.load(&hash_hex, git_dir, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);

        parseAttrContent(allocator, obj.data, prefix, rules) catch continue;
    }
}

// Flag to track if negative patterns were seen during parsing
pub var saw_negative_pattern: bool = false;

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

pub fn parseAttrContent(allocator: std.mem.Allocator, content: []const u8, prefix: []const u8, rules: *std.array_list.Managed(AttrRule)) !void {
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
            var macro_attrs = std.array_list.Managed(AttrValue).init(allocator);
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

        // Handle negative patterns: lines starting with ! are ignored
        // Handle escaped exclamation: \! is treated as literal !
        if (trimmed[0] == '!') {
            // Negative pattern - skip it (git ignores these with a warning)
            saw_negative_pattern = true;
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
            var unquoted = std.array_list.Managed(u8).init(allocator);
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
            var raw_pattern = trimmed[0..end_idx];
            // Handle \! escape at start of pattern
            if (raw_pattern.len > 1 and raw_pattern[0] == '\\' and raw_pattern[1] == '!') {
                pattern = raw_pattern[1..];
            } else if (raw_pattern.len > 1 and raw_pattern[0] == '\\' and raw_pattern[1] == '#') {
                pattern = raw_pattern[1..];
            } else {
                pattern = raw_pattern;
            }
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

        var attrs = std.array_list.Managed(AttrValue).init(allocator);
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
                // attr (set to true)
                const name = try allocator.dupe(u8, attr_spec);
                const val = try allocator.dupe(u8, "set");
                try attrs.append(.{ .name = name, .value = val });
                // Check if this is a macro name - expand after adding the attr itself
                if (global_macros) |macros| {
                    if (macros.get(attr_spec)) |macro_attrs| {
                        for (macro_attrs) |ma| {
                            try attrs.append(.{ .name = try allocator.dupe(u8, ma.name), .value = try allocator.dupe(u8, ma.value) });
                        }
                    }
                }
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


pub fn attrPatternMatches(pattern: []const u8, path: []const u8, case_insensitive: bool) bool {
    const has_slash = std.mem.indexOf(u8, pattern, "/") != null;
    const has_glob = std.mem.indexOfAny(u8, pattern, "*?[") != null;

    if (!has_slash) {
        // No slash in pattern: match against the basename only
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| path[idx + 1 ..] else path;
        if (!has_glob) {
            // Simple literal match
            if (case_insensitive) return std.ascii.eqlIgnoreCase(pattern, basename);
            return std.mem.eql(u8, pattern, basename);
        }
        // Glob match against basename only (** without / context acts like *)
        return globMatchBasename(pattern, basename, case_insensitive);
    }

    // Pattern has slash: match against full path
    if (!has_glob) {
        if (case_insensitive) return std.ascii.eqlIgnoreCase(pattern, path);
        return std.mem.eql(u8, pattern, path);
    }

    // Glob pattern with slashes - use full path matching
    if (case_insensitive) {
        var lower_pattern_buf: [1024]u8 = undefined;
        var lower_path_buf: [1024]u8 = undefined;
        if (pattern.len <= lower_pattern_buf.len and path.len <= lower_path_buf.len) {
            for (pattern, 0..) |c, i| {
                lower_pattern_buf[i] = std.ascii.toLower(c);
            }
            for (path, 0..) |c, i| {
                lower_path_buf[i] = std.ascii.toLower(c);
            }
            if (gitignore_mod.GitignoreEntry.init(lower_pattern_buf[0..pattern.len], std.heap.page_allocator)) |entry| {
                defer entry.deinit(std.heap.page_allocator);
                return entry.matches(lower_path_buf[0..path.len], false);
            } else |_| return false;
        }
    }
    if (gitignore_mod.GitignoreEntry.init(pattern, std.heap.page_allocator)) |entry| {
        defer entry.deinit(std.heap.page_allocator);
        return entry.matches(path, false);
    } else |_| return false;
}

/// Glob match a pattern against text (basename only, ** acts like *)
fn globMatchBasename(pattern: []const u8, text: []const u8, case_insensitive: bool) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len or pi < pattern.len) {
        if (pi < pattern.len) {
            const pc = pattern[pi];
            if (pc == '*') {
                // Skip consecutive *'s (** without / acts like *)
                star_pi = pi;
                star_ti = ti;
                while (pi < pattern.len and pattern[pi] == '*') pi += 1;
                continue;
            } else if (pc == '?' and ti < text.len) {
                pi += 1;
                ti += 1;
                continue;
            } else if (ti < text.len) {
                const tc = text[ti];
                const matches = if (case_insensitive)
                    std.ascii.toLower(pc) == std.ascii.toLower(tc)
                else
                    pc == tc;
                if (matches) {
                    pi += 1;
                    ti += 1;
                    continue;
                }
            }
        }

        if (star_pi) |_| {
            star_ti += 1;
            if (star_ti <= text.len) {
                pi = star_pi.?;
                while (pi < pattern.len and pattern[pi] == '*') pi += 1;
                ti = star_ti;
                continue;
            }
        }

        return false;
    }
    return true;
}
