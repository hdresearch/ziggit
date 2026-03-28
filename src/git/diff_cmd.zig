const std = @import("std");
const pm = @import("../platform/platform.zig");
const refs = @import("refs.zig");
const objects = @import("objects.zig");
const tree_mod = @import("tree.zig");
const index_mod = @import("index.zig");
const diff_mod = @import("diff.zig");
const diff_stats = @import("diff_stats.zig");
const mc = @import("../main_common.zig");

const DiffOutputMode = enum {
    patch,
    stat,
    shortstat,
    numstat,
    name_only,
    name_status,
    raw,
    no_patch,
    summary,
    dirstat,
    patch_with_stat,
    patch_with_raw,
};

const DiffOpts = struct {
    cached: bool = false,
    quiet: bool = false,
    exit_code: bool = false,
    output_mode: DiffOutputMode = .patch,
    check_mode: bool = false,
    no_index: bool = false,
    context_lines: u32 = 3,
    src_prefix: []const u8 = "a/",
    dst_prefix: []const u8 = "b/",
    no_prefix: bool = false,
    mnemonic_prefix: bool = false,
    default_prefix: bool = false,
    full_index: bool = false,
    abbrev: ?u32 = null, // null = default (7), 0 = no abbrev from --no-abbrev
    line_prefix: []const u8 = "",
    raw_abbrev: bool = true, // whether to abbreviate in raw mode
    no_renames: bool = false,
    reverse: bool = false,
    compact_summary: bool = false,
    ignore_regex: std.array_list.Managed([]const u8) = undefined,
    ignore_blank_lines: bool = false,

    fn getAbbrevLen(self: *const DiffOpts) u32 {
        if (self.abbrev) |a| {
            if (a == 0) return 40; // --no-abbrev
            return a;
        }
        return 7; // default
    }

    fn getEffectiveSrcPrefix(self: *const DiffOpts) []const u8 {
        if (self.default_prefix) return "a/";
        if (self.no_prefix) return "";
        if (self.mnemonic_prefix) return "i/"; // index (for cached) or working tree comparison
        return self.src_prefix;
    }

    fn getEffectiveDstPrefix(self: *const DiffOpts) []const u8 {
        if (self.default_prefix) return "b/";
        if (self.no_prefix) return "";
        if (self.mnemonic_prefix) return "w/";
        return self.dst_prefix;
    }
};

const FileChange = struct {
    path: []const u8,
    old_hash: []const u8,
    new_hash: []const u8,
    old_mode: []const u8,
    new_mode: []const u8,
    old_content: []const u8,
    new_content: []const u8,
    insertions: usize,
    deletions: usize,
    is_new: bool,
    is_deleted: bool,
    is_binary: bool,
};

pub fn cmdDiff(allocator: std.mem.Allocator, args: *pm.ArgIterator, platform_impl: *const pm.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("diff: not supported in freestanding mode\n");
        return;
    }

    // Collect all args
    var all_args = std.array_list.Managed([]const u8).init(allocator);
    defer all_args.deinit();
    while (args.next()) |arg| {
        try all_args.append(arg);
    }

    // Check for --no-index
    var has_no_index = false;
    for (all_args.items) |arg| {
        if (std.mem.eql(u8, arg, "--no-index")) {
            has_no_index = true;
            break;
        }
    }

    // Parse options
    var opts = DiffOpts{
        .ignore_regex = std.array_list.Managed([]const u8).init(allocator),
    };
    defer opts.ignore_regex.deinit();
    opts.no_index = has_no_index;

    var positional = std.array_list.Managed([]const u8).init(allocator);
    defer positional.deinit();
    var pathspec_args = std.array_list.Managed([]const u8).init(allocator);
    defer pathspec_args.deinit();
    var seen_dashdash = false;

    // Read config for prefix options
    const git_path_for_config = mc.findGitDirectory(allocator, platform_impl) catch null;
    defer if (git_path_for_config) |gp| allocator.free(gp);

    if (git_path_for_config != null) {
        // Check config overrides first, then read config file
        if (mc.getConfigOverride("diff.noprefix")) |val| {
            if (std.mem.eql(u8, val, "true")) opts.no_prefix = true;
        }
        if (mc.getConfigOverride("diff.mnemonicprefix")) |val| {
            if (std.mem.eql(u8, val, "true")) opts.mnemonic_prefix = true;
        }
        if (mc.getConfigOverride("diff.srcprefix")) |val| {
            opts.src_prefix = val;
        }
        if (mc.getConfigOverride("diff.dstprefix")) |val| {
            opts.dst_prefix = val;
        }
    }

    var i: usize = 0;
    while (i < all_args.items.len) : (i += 1) {
        const arg = all_args.items[i];
        if (seen_dashdash) {
            try pathspec_args.append(arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            seen_dashdash = true;
        } else if (std.mem.eql(u8, arg, "--cached") or std.mem.eql(u8, arg, "--staged")) {
            opts.cached = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
            opts.exit_code = true;
        } else if (std.mem.eql(u8, arg, "--exit-code")) {
            opts.exit_code = true;
        } else if (std.mem.eql(u8, arg, "--stat") or std.mem.startsWith(u8, arg, "--stat=")) {
            opts.output_mode = .stat;
        } else if (std.mem.eql(u8, arg, "--shortstat")) {
            opts.output_mode = .shortstat;
        } else if (std.mem.eql(u8, arg, "--numstat")) {
            opts.output_mode = .numstat;
        } else if (std.mem.eql(u8, arg, "--name-only")) {
            opts.output_mode = .name_only;
        } else if (std.mem.eql(u8, arg, "--name-status")) {
            opts.output_mode = .name_status;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            opts.output_mode = .raw;
        } else if (std.mem.eql(u8, arg, "--no-patch") or std.mem.eql(u8, arg, "-s")) {
            opts.output_mode = .no_patch;
        } else if (std.mem.eql(u8, arg, "--patch-with-stat")) {
            opts.output_mode = .patch_with_stat;
        } else if (std.mem.eql(u8, arg, "--patch-with-raw")) {
            opts.output_mode = .patch_with_raw;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            opts.output_mode = .summary;
        } else if (std.mem.eql(u8, arg, "--dirstat") or std.mem.eql(u8, arg, "--cumulative") or
            std.mem.eql(u8, arg, "--dirstat-by-file") or std.mem.startsWith(u8, arg, "--dirstat="))
        {
            opts.output_mode = .dirstat;
        } else if (std.mem.eql(u8, arg, "--full-index")) {
            opts.full_index = true;
        } else if (std.mem.eql(u8, arg, "--no-abbrev")) {
            opts.abbrev = 0;
        } else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
            opts.abbrev = std.fmt.parseInt(u32, arg["--abbrev=".len..], 10) catch 7;
        } else if (std.mem.eql(u8, arg, "--abbrev")) {
            opts.abbrev = 7;
        } else if (std.mem.eql(u8, arg, "--no-prefix")) {
            opts.no_prefix = true;
        } else if (std.mem.eql(u8, arg, "--default-prefix")) {
            opts.default_prefix = true;
        } else if (std.mem.startsWith(u8, arg, "--src-prefix=")) {
            opts.src_prefix = arg["--src-prefix=".len..];
            // --src-prefix overrides config, and also overrides --no-prefix
            opts.no_prefix = false;
            opts.mnemonic_prefix = false;
        } else if (std.mem.startsWith(u8, arg, "--dst-prefix=")) {
            opts.dst_prefix = arg["--dst-prefix=".len..];
            opts.no_prefix = false;
            opts.mnemonic_prefix = false;
        } else if (std.mem.eql(u8, arg, "--no-renames")) {
            opts.no_renames = true;
        } else if (std.mem.eql(u8, arg, "-R")) {
            opts.reverse = true;
        } else if (std.mem.eql(u8, arg, "--compact-summary")) {
            opts.compact_summary = true;
        } else if (std.mem.startsWith(u8, arg, "--line-prefix=")) {
            opts.line_prefix = arg["--line-prefix=".len..];
        } else if (std.mem.eql(u8, arg, "--cc")) {
            // Combined diff mode - accept for compat
        } else if (std.mem.startsWith(u8, arg, "-U") and arg.len > 2) {
            opts.context_lines = std.fmt.parseInt(u32, arg[2..], 10) catch 3;
        } else if (std.mem.startsWith(u8, arg, "--unified=")) {
            opts.context_lines = std.fmt.parseInt(u32, arg["--unified=".len..], 10) catch 3;
        } else if (std.mem.eql(u8, arg, "-U")) {
            // -U without number means default (already 3)
        } else if (std.mem.eql(u8, arg, "--ignore-blank-lines")) {
            opts.ignore_blank_lines = true;
        } else if (std.mem.startsWith(u8, arg, "-I") and arg.len > 2) {
            const pattern = arg[2..];
            if (!isValidRegex(pattern)) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: invalid regex given to -I: '{s}'\n", .{pattern});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(129);
            }
            try opts.ignore_regex.append(pattern);
        } else if (std.mem.startsWith(u8, arg, "--ignore-matching-lines=")) {
            const pattern = arg["--ignore-matching-lines=".len..];
            if (!isValidRegex(pattern)) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: invalid regex given to -I: '{s}'\n", .{pattern});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(129);
            }
            try opts.ignore_regex.append(pattern);
        } else if (std.mem.eql(u8, arg, "--no-index")) {
            // already handled
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch") or std.mem.eql(u8, arg, "-u")) {
            opts.output_mode = .patch;
        } else if (std.mem.startsWith(u8, arg, "--no-rename")) {
            // --no-rename (abbreviated, not --no-renames) should be rejected
            if (!std.mem.eql(u8, arg, "--no-renames")) {
                try platform_impl.writeStderr("error: invalid option: ");
                try platform_impl.writeStderr(arg);
                try platform_impl.writeStderr("\n");
                std.process.exit(129);
            }
        } else if (std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            // Other flags - silently accept
        } else {
            try positional.append(arg);
        }
    }

    if (has_no_index) {
        try doDiffNoIndex(allocator, &opts, &positional, &pathspec_args, platform_impl);
        return;
    }

    const git_path = mc.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Check for commit range (A..B or A...B) or multiple commits
    var ref1: ?[]const u8 = null;
    var ref2: ?[]const u8 = null;
    var single_ref: ?[]const u8 = null;
    var multi_refs = std.array_list.Managed([]const u8).init(allocator);
    defer multi_refs.deinit();

    if (positional.items.len >= 1) {
        if (std.mem.indexOf(u8, positional.items[0], "..")) |dot_pos| {
            ref1 = positional.items[0][0..dot_pos];
            var rest = positional.items[0][dot_pos + 2 ..];
            if (rest.len > 0 and rest[0] == '.') rest = rest[1..]; // handle A...B
            ref2 = rest;
            for (positional.items[1..]) |p| try pathspec_args.append(p);
        } else {
            // Try resolving as refs
            const t1 = resolveToTree(allocator, positional.items[0], git_path, platform_impl) catch null;
            if (t1) |tree1| {
                allocator.free(tree1);
                if (positional.items.len >= 3) {
                    // Multiple refs: combined diff (diff A B C)
                    for (positional.items) |p| {
                        const t = resolveToTree(allocator, p, git_path, platform_impl) catch null;
                        if (t) |tt| {
                            allocator.free(tt);
                            try multi_refs.append(p);
                        } else {
                            try pathspec_args.append(p);
                        }
                    }
                } else if (positional.items.len == 2) {
                    const t2 = resolveToTree(allocator, positional.items[1], git_path, platform_impl) catch null;
                    if (t2) |tree2| {
                        allocator.free(tree2);
                        ref1 = positional.items[0];
                        ref2 = positional.items[1];
                    } else {
                        single_ref = positional.items[0];
                        try pathspec_args.append(positional.items[1]);
                    }
                } else {
                    single_ref = positional.items[0];
                }
            } else {
                for (positional.items) |p| try pathspec_args.append(p);
            }
        }
    }

    // Handle combined diff (diff A B C)
    if (multi_refs.items.len >= 3) {
        try doCombinedDiff(allocator, multi_refs.items, git_path, &opts, platform_impl);
        return;
    }

    // Handle two-tree diff
    if (ref1 != null and ref2 != null) {
        try doTreeToTreeDiff(allocator, ref1.?, ref2.?, git_path, &opts, pathspec_args.items, platform_impl);
        return;
    }

    // Single ref or working tree diff
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();

    const cwd = try platform_impl.fs.getCwd(allocator);
    defer allocator.free(cwd);

    if (single_ref) |sref| {
        if (opts.cached) {
            try doRefToIndexDiff(allocator, sref, &index, git_path, &opts, pathspec_args.items, platform_impl);
        } else {
            try doRefToWorkingDiff(allocator, sref, &index, cwd, git_path, &opts, pathspec_args.items, platform_impl);
        }
    } else if (opts.cached) {
        try doIndexToHeadDiff(allocator, &index, git_path, &opts, pathspec_args.items, platform_impl);
    } else {
        try doWorkingTreeDiff(allocator, &index, cwd, git_path, &opts, pathspec_args.items, platform_impl);
    }
}

fn resolveToTree(allocator: std.mem.Allocator, ref_str: []const u8, git_path: []const u8, platform_impl: *const pm.Platform) ![]u8 {
    const hash = try mc.resolveRevision(git_path, ref_str, platform_impl, allocator);
    defer allocator.free(hash);

    const obj = try objects.GitObject.load(hash, git_path, platform_impl, allocator);
    defer obj.deinit(allocator);

    if (obj.type == .tree) {
        return try allocator.dupe(u8, hash);
    }

    // If it's a commit, extract tree hash
    if (obj.type == .commit) {
        var lines = std.mem.splitScalar(u8, obj.data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "tree ")) {
                return try allocator.dupe(u8, line["tree ".len..]);
            }
        }
    }
    return error.InvalidObject;
}

fn doTreeToTreeDiff(allocator: std.mem.Allocator, ref1: []const u8, ref2: []const u8, git_path: []const u8, opts: *const DiffOpts, pathspecs: []const []const u8, pi: *const pm.Platform) !void {
    const tree1 = resolveToTree(allocator, ref1, git_path, pi) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{ref1});
        defer allocator.free(msg);
        try pi.writeStderr(msg);
        std.process.exit(128);
    };
    defer allocator.free(tree1);

    const tree2 = resolveToTree(allocator, ref2, git_path, pi) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{ref2});
        defer allocator.free(msg);
        try pi.writeStderr(msg);
        std.process.exit(128);
    };
    defer allocator.free(tree2);

    var changes = std.array_list.Managed(FileChange).init(allocator);
    defer {
        for (changes.items) |*c| freeChange(allocator, c);
        changes.deinit();
    }
    try collectTreeChanges(allocator, tree1, tree2, "", git_path, pathspecs, pi, &changes);

    if (changes.items.len == 0 and (opts.exit_code or opts.quiet)) return;

    switch (opts.output_mode) {
        .stat => try outputStat(changes.items, pi, allocator),
        .shortstat => try outputShortStat(changes.items, pi, allocator),
        .numstat => try outputNumStat(changes.items, pi, allocator),
        .name_only => try outputNameOnly(changes.items, pi, allocator),
        .name_status => try outputNameStatus(changes.items, pi, allocator),
        .raw => try outputRaw(changes.items, opts, pi, allocator),
        .summary => try outputSummary(changes.items, pi, allocator),
        .dirstat => try outputDirStat(changes.items, pi, allocator),
        .patch => try outputPatch(changes.items, opts, pi, allocator),
        .patch_with_stat => {
            try outputStat(changes.items, pi, allocator);
            try pi.writeStdout("\n");
            try outputPatch(changes.items, opts, pi, allocator);
        },
        .patch_with_raw => {
            try outputRaw(changes.items, opts, pi, allocator);
            try pi.writeStdout("\n");
            try outputPatch(changes.items, opts, pi, allocator);
        },
        .no_patch => {},
    }

    if ((opts.exit_code or opts.quiet) and changes.items.len > 0) {
        std.process.exit(1);
    }
}

fn freeChange(allocator: std.mem.Allocator, c: *FileChange) void {
    allocator.free(c.path);
    allocator.free(c.old_hash);
    allocator.free(c.new_hash);
    allocator.free(c.old_mode);
    allocator.free(c.new_mode);
    if (c.old_content.len > 0) allocator.free(c.old_content);
    if (c.new_content.len > 0) allocator.free(c.new_content);
}

fn collectTreeChanges(allocator: std.mem.Allocator, tree1_hash: []const u8, tree2_hash: []const u8, prefix: []const u8, git_path: []const u8, pathspecs: []const []const u8, pi: *const pm.Platform, out: *std.array_list.Managed(FileChange)) !void {
    const t1o = objects.GitObject.load(tree1_hash, git_path, pi, allocator) catch return;
    defer t1o.deinit(allocator);
    const t2o = objects.GitObject.load(tree2_hash, git_path, pi, allocator) catch return;
    defer t2o.deinit(allocator);

    var p1 = tree_mod.parseTree(t1o.data, allocator) catch return;
    defer p1.deinit();
    var p2 = tree_mod.parseTree(t2o.data, allocator) catch return;
    defer p2.deinit();

    var m1 = std.StringHashMap(tree_mod.TreeEntry).init(allocator);
    defer m1.deinit();
    var m2 = std.StringHashMap(tree_mod.TreeEntry).init(allocator);
    defer m2.deinit();

    for (p1.items) |e| m1.put(e.name, e) catch {};
    for (p2.items) |e| m2.put(e.name, e) catch {};

    // Collect all names
    var all_names = std.StringHashMap(void).init(allocator);
    defer all_names.deinit();
    for (p1.items) |e| all_names.put(e.name, {}) catch {};
    for (p2.items) |e| all_names.put(e.name, {}) catch {};

    var sorted_names = std.array_list.Managed([]const u8).init(allocator);
    defer sorted_names.deinit();
    var ki = all_names.keyIterator();
    while (ki.next()) |k| try sorted_names.append(k.*);
    std.mem.sort([]const u8, sorted_names.items, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.cmp);

    const is_tree = struct {
        fn f(mode: []const u8) bool {
            return std.mem.eql(u8, mode, "40000") or std.mem.eql(u8, mode, "040000");
        }
    }.f;

    for (sorted_names.items) |name| {
        const e1 = m1.get(name);
        const e2 = m2.get(name);
        const full_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);

        if (e1 != null and e2 != null) {
            if (std.mem.eql(u8, e1.?.hash, e2.?.hash) and std.mem.eql(u8, e1.?.mode, e2.?.mode)) {
                allocator.free(full_name);
                continue;
            }
            if (is_tree(e1.?.mode) and is_tree(e2.?.mode)) {
                try collectTreeChanges(allocator, e1.?.hash, e2.?.hash, full_name, git_path, pathspecs, pi, out);
                allocator.free(full_name);
                continue;
            }
            if (!matchPathspec(full_name, pathspecs)) {
                allocator.free(full_name);
                continue;
            }
            const old_c = loadBlob(allocator, e1.?.hash, git_path, pi) catch "";
            const new_c = loadBlob(allocator, e2.?.hash, git_path, pi) catch "";
            const stats = diff_stats.countInsDels(old_c, new_c);
            try out.append(.{
                .path = full_name,
                .old_hash = try allocator.dupe(u8, e1.?.hash),
                .new_hash = try allocator.dupe(u8, e2.?.hash),
                .old_mode = try allocator.dupe(u8, e1.?.mode),
                .new_mode = try allocator.dupe(u8, e2.?.mode),
                .old_content = old_c,
                .new_content = new_c,
                .insertions = stats.ins,
                .deletions = stats.dels,
                .is_new = false,
                .is_deleted = false,
                .is_binary = diff_stats.isBinContent(old_c) or diff_stats.isBinContent(new_c),
            });
        } else if (e1 != null and e2 == null) {
            // Deleted
            if (is_tree(e1.?.mode)) {
                const empty_tree = "4b825dc642cb6eb9a060e54bf899d69f82cf0101";
                try collectTreeChanges(allocator, e1.?.hash, empty_tree, full_name, git_path, pathspecs, pi, out);
                allocator.free(full_name);
                continue;
            }
            if (!matchPathspec(full_name, pathspecs)) {
                allocator.free(full_name);
                continue;
            }
            const old_c = loadBlob(allocator, e1.?.hash, git_path, pi) catch "";
            try out.append(.{
                .path = full_name,
                .old_hash = try allocator.dupe(u8, e1.?.hash),
                .new_hash = try allocator.dupe(u8, "0000000000000000000000000000000000000000"),
                .old_mode = try allocator.dupe(u8, e1.?.mode),
                .new_mode = try allocator.dupe(u8, "000000"),
                .old_content = old_c,
                .new_content = try allocator.dupe(u8, ""),
                .insertions = 0,
                .deletions = diff_stats.countLines(old_c),
                .is_new = false,
                .is_deleted = true,
                .is_binary = diff_stats.isBinContent(old_c),
            });
        } else if (e2 != null) {
            // Added
            if (is_tree(e2.?.mode)) {
                const empty_tree = "4b825dc642cb6eb9a060e54bf899d69f82cf0101";
                try collectTreeChanges(allocator, empty_tree, e2.?.hash, full_name, git_path, pathspecs, pi, out);
                allocator.free(full_name);
                continue;
            }
            if (!matchPathspec(full_name, pathspecs)) {
                allocator.free(full_name);
                continue;
            }
            const new_c = loadBlob(allocator, e2.?.hash, git_path, pi) catch "";
            try out.append(.{
                .path = full_name,
                .old_hash = try allocator.dupe(u8, "0000000000000000000000000000000000000000"),
                .new_hash = try allocator.dupe(u8, e2.?.hash),
                .old_mode = try allocator.dupe(u8, "000000"),
                .new_mode = try allocator.dupe(u8, e2.?.mode),
                .old_content = try allocator.dupe(u8, ""),
                .new_content = new_c,
                .insertions = diff_stats.countLines(new_c),
                .deletions = 0,
                .is_new = true,
                .is_deleted = false,
                .is_binary = diff_stats.isBinContent(new_c),
            });
        } else {
            allocator.free(full_name);
        }
    }
}

fn loadBlob(allocator: std.mem.Allocator, hash: []const u8, git_path: []const u8, pi: *const pm.Platform) ![]u8 {
    const obj = objects.GitObject.load(hash, git_path, pi, allocator) catch return error.ObjectNotFound;
    defer obj.deinit(allocator);
    if (obj.type != .blob) return error.NotABlob;
    return allocator.dupe(u8, obj.data);
}

fn matchPathspec(path: []const u8, pathspecs: []const []const u8) bool {
    if (pathspecs.len == 0) return true;
    for (pathspecs) |ps| {
        if (std.mem.eql(u8, path, ps)) return true;
        if (std.mem.startsWith(u8, path, ps) and path.len > ps.len and path[ps.len] == '/') return true;
        if (std.mem.startsWith(u8, ps, path) and ps.len > path.len and ps[path.len] == '/') return true;
        // Simple glob matching
        if (std.mem.indexOf(u8, ps, "*") != null or std.mem.indexOf(u8, ps, "?") != null) {
            if (globMatch(ps, path)) return true;
        }
    }
    return false;
}

fn isValidRegex(pattern: []const u8) bool {
    // Basic check for unmatched brackets
    var bracket_depth: i32 = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            i += 1; // skip escaped char
            continue;
        }
        if (pattern[i] == '[') bracket_depth += 1;
        if (pattern[i] == ']') bracket_depth -= 1;
    }
    if (bracket_depth != 0) return false;
    // Check for unmatched parens
    var paren_depth: i32 = 0;
    i = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            i += 1;
            continue;
        }
        if (pattern[i] == '(') paren_depth += 1;
        if (pattern[i] == ')') paren_depth -= 1;
    }
    if (paren_depth != 0) return false;
    return true;
}

fn globMatch(pattern: []const u8, str: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_pi: ?usize = null;
    var star_si: usize = 0;

    while (si < str.len) {
        if (pi < pattern.len and (pattern[pi] == str[si] or pattern[pi] == '?')) {
            pi += 1;
            si += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_si = si;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_si += 1;
            si = star_si;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

fn abbreviateHash(hash: []const u8, len: u32) []const u8 {
    if (len >= 40) return hash;
    return hash[0..@min(len, hash.len)];
}

fn outputStat(changes: []const FileChange, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    if (changes.len == 0) return;
    var max_path_len: usize = 0;
    for (changes) |c| {
        if (c.path.len > max_path_len) max_path_len = c.path.len;
    }

    var total_ins: usize = 0;
    var total_dels: usize = 0;

    for (changes) |c| {
        total_ins += c.insertions;
        total_dels += c.deletions;
        const total = c.insertions + c.deletions;
        const pad_len = max_path_len - c.path.len;
        const pad = try allocator.alloc(u8, pad_len);
        defer allocator.free(pad);
        @memset(pad, ' ');

        if (c.is_binary) {
            const line = try std.fmt.allocPrint(allocator, " {s}{s} | Bin\n", .{ c.path, pad });
            defer allocator.free(line);
            try pi.writeStdout(line);
        } else if (total == 0) {
            const line = try std.fmt.allocPrint(allocator, " {s}{s} | 0\n", .{ c.path, pad });
            defer allocator.free(line);
            try pi.writeStdout(line);
        } else {
            const plus = try allocator.alloc(u8, c.insertions);
            defer allocator.free(plus);
            @memset(plus, '+');
            const minus = try allocator.alloc(u8, c.deletions);
            defer allocator.free(minus);
            @memset(minus, '-');
            const line = try std.fmt.allocPrint(allocator, " {s}{s} | {d} {s}{s}\n", .{ c.path, pad, total, plus, minus });
            defer allocator.free(line);
            try pi.writeStdout(line);
        }
    }

    // Summary line
    var summary = std.array_list.Managed(u8).init(allocator);
    defer summary.deinit();
    const w = summary.writer();
    try w.print(" {d} file{s} changed", .{ changes.len, if (changes.len != 1) @as([]const u8, "s") else "" });
    if (total_ins > 0) try w.print(", {d} insertion{s}(+)", .{ total_ins, if (total_ins != 1) @as([]const u8, "s") else "" });
    if (total_dels > 0) try w.print(", {d} deletion{s}(-)", .{ total_dels, if (total_dels != 1) @as([]const u8, "s") else "" });
    try w.writeAll("\n");
    try pi.writeStdout(summary.items);
}

fn outputShortStat(changes: []const FileChange, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    if (changes.len == 0) return;
    var total_ins: usize = 0;
    var total_dels: usize = 0;
    for (changes) |c| {
        total_ins += c.insertions;
        total_dels += c.deletions;
    }
    var s = std.array_list.Managed(u8).init(allocator);
    defer s.deinit();
    const w = s.writer();
    try w.print(" {d} file{s} changed", .{ changes.len, if (changes.len != 1) @as([]const u8, "s") else "" });
    if (total_ins > 0) try w.print(", {d} insertion{s}(+)", .{ total_ins, if (total_ins != 1) @as([]const u8, "s") else "" });
    if (total_dels > 0) try w.print(", {d} deletion{s}(-)", .{ total_dels, if (total_dels != 1) @as([]const u8, "s") else "" });
    try w.writeAll("\n");
    try pi.writeStdout(s.items);
}

fn outputNumStat(changes: []const FileChange, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    for (changes) |c| {
        if (c.is_binary) {
            const line = try std.fmt.allocPrint(allocator, "-\t-\t{s}\n", .{c.path});
            defer allocator.free(line);
            try pi.writeStdout(line);
        } else {
            const line = try std.fmt.allocPrint(allocator, "{d}\t{d}\t{s}\n", .{ c.insertions, c.deletions, c.path });
            defer allocator.free(line);
            try pi.writeStdout(line);
        }
    }
}

fn outputNameOnly(changes: []const FileChange, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    for (changes) |c| {
        const line = try std.fmt.allocPrint(allocator, "{s}\n", .{c.path});
        defer allocator.free(line);
        try pi.writeStdout(line);
    }
}

fn outputNameStatus(changes: []const FileChange, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    for (changes) |c| {
        const status: u8 = if (c.is_new) 'A' else if (c.is_deleted) 'D' else 'M';
        const line = try std.fmt.allocPrint(allocator, "{c}\t{s}\n", .{ status, c.path });
        defer allocator.free(line);
        try pi.writeStdout(line);
    }
}

fn outputRaw(changes: []const FileChange, opts: *const DiffOpts, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    const abbrev_len = opts.getAbbrevLen();
    // Check for GIT_PRINT_SHA1_ELLIPSIS
    // Check env var for ellipsis
    const env_ellipsis = std.process.getEnvVarOwned(allocator, "GIT_PRINT_SHA1_ELLIPSIS") catch null;
    defer if (env_ellipsis) |e| allocator.free(e);
    const show_ellipsis = if (env_ellipsis) |e| std.mem.eql(u8, e, "yes") else false;
    const actual_ellipsis: []const u8 = if (abbrev_len < 40 and show_ellipsis) "..." else if (abbrev_len < 40) "" else "";

    for (changes) |c| {
        const status: u8 = if (c.is_new) 'A' else if (c.is_deleted) 'D' else 'M';
        const old_mode: []const u8 = if (c.is_new) "000000" else if (c.old_mode.len > 0) c.old_mode else "100644";
        const new_mode: []const u8 = if (c.is_deleted) "000000" else if (c.new_mode.len > 0) c.new_mode else "100644";

        const old_h = abbreviateHash(c.old_hash, abbrev_len);
        const new_h = abbreviateHash(c.new_hash, abbrev_len);

        const line = try std.fmt.allocPrint(allocator, ":{s} {s} {s}{s} {s}{s} {c}\t{s}\n", .{
            old_mode, new_mode, old_h, actual_ellipsis, new_h, actual_ellipsis, status, c.path,
        });
        defer allocator.free(line);
        try pi.writeStdout(line);
    }
}

fn outputSummary(changes: []const FileChange, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    for (changes) |c| {
        if (c.is_new) {
            const mode = if (c.new_mode.len > 0 and !std.mem.eql(u8, c.new_mode, "000000")) c.new_mode else "100644";
            const line = try std.fmt.allocPrint(allocator, " create mode {s} {s}\n", .{ mode, c.path });
            defer allocator.free(line);
            try pi.writeStdout(line);
        } else if (c.is_deleted) {
            const mode = if (c.old_mode.len > 0 and !std.mem.eql(u8, c.old_mode, "000000")) c.old_mode else "100644";
            const line = try std.fmt.allocPrint(allocator, " delete mode {s} {s}\n", .{ mode, c.path });
            defer allocator.free(line);
            try pi.writeStdout(line);
        }
    }
}

fn outputDirStat(changes: []const FileChange, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    // Compute total changes per directory
    var total_changes: usize = 0;
    var dir_changes = std.StringHashMap(usize).init(allocator);
    defer dir_changes.deinit();

    for (changes) |c| {
        const change_count = c.insertions + c.deletions;
        total_changes += change_count;
        // Get directory
        if (std.mem.lastIndexOf(u8, c.path, "/")) |slash| {
            const dir = c.path[0 .. slash + 1];
            const current = dir_changes.get(dir) orelse 0;
            dir_changes.put(dir, current + change_count) catch {};
        }
    }

    if (total_changes == 0) return;

    // Sort directories
    var dirs = std.array_list.Managed([]const u8).init(allocator);
    defer dirs.deinit();
    var dir_it = dir_changes.keyIterator();
    while (dir_it.next()) |k| try dirs.append(k.*);
    std.mem.sort([]const u8, dirs.items, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.cmp);

    for (dirs.items) |dir| {
        if (dir_changes.get(dir)) |count| {
            const pct = @as(f64, @floatFromInt(count)) * 100.0 / @as(f64, @floatFromInt(total_changes));
            if (pct >= 3.0) { // Git default threshold
                // Git format: right-aligned percentage in 5-char field + "% dir/"
                var pct_buf: [16]u8 = undefined;
                const pct_str = std.fmt.bufPrint(&pct_buf, "{d:.1}", .{pct}) catch "0.0";
                const pad_needed = if (pct_str.len < 5) 5 - pct_str.len else 0;
                const pads = "      ";
                const line = try std.fmt.allocPrint(allocator, " {s}{s}% {s}\n", .{ pads[0..pad_needed], pct_str, dir });
                defer allocator.free(line);
                try pi.writeStdout(line);
            }
        }
    }
}

fn outputPatch(changes: []const FileChange, opts: *const DiffOpts, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    const sp = opts.getEffectiveSrcPrefix();
    const dp = opts.getEffectiveDstPrefix();
    const lp = opts.line_prefix;

    for (changes) |c| {
        if (c.is_binary) {
            const header = try std.fmt.allocPrint(allocator, "{s}diff --git {s}{s} {s}{s}\n{s}Binary files {s}{s} and {s}{s} differ\n", .{
                lp, sp, c.path, dp, c.path,
                lp, sp, c.path, dp, c.path,
            });
            defer allocator.free(header);
            try pi.writeStdout(header);
            continue;
        }

        // Diff header
        try outputDiffHeader(c, sp, dp, lp, opts, pi, allocator);

        // Generate and output hunks
        if (c.old_content.len > 0 or c.new_content.len > 0) {
            try outputDiffHunks(c.old_content, c.new_content, opts.context_lines, lp, pi, allocator);
        }
    }
}

fn outputDiffHeader(c: FileChange, sp: []const u8, dp: []const u8, lp: []const u8, opts: *const DiffOpts, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    // diff --git line
    const git_line = try std.fmt.allocPrint(allocator, "{s}diff --git {s}{s} {s}{s}\n", .{ lp, sp, c.path, dp, c.path });
    defer allocator.free(git_line);
    try pi.writeStdout(git_line);

    if (c.is_new) {
        const mode = if (c.new_mode.len > 0 and !std.mem.eql(u8, c.new_mode, "000000")) c.new_mode else "100644";
        const nm = try std.fmt.allocPrint(allocator, "{s}new file mode {s}\n", .{ lp, mode });
        defer allocator.free(nm);
        try pi.writeStdout(nm);
    } else if (c.is_deleted) {
        const mode = if (c.old_mode.len > 0 and !std.mem.eql(u8, c.old_mode, "000000")) c.old_mode else "100644";
        const dm = try std.fmt.allocPrint(allocator, "{s}deleted file mode {s}\n", .{ lp, mode });
        defer allocator.free(dm);
        try pi.writeStdout(dm);
    }

    // index line
    const abbrev_len = opts.getAbbrevLen();
    const full = opts.full_index;
    const olen = if (full) @as(u32, 40) else abbrev_len;
    const old_h = abbreviateHash(c.old_hash, olen);
    const new_h = abbreviateHash(c.new_hash, olen);

    if (c.is_new or c.is_deleted) {
        const idx = try std.fmt.allocPrint(allocator, "{s}index {s}..{s}\n", .{ lp, old_h, new_h });
        defer allocator.free(idx);
        try pi.writeStdout(idx);
    } else {
        const mode = if (c.old_mode.len > 0 and !std.mem.eql(u8, c.old_mode, "000000")) c.old_mode else "100644";
        const idx = try std.fmt.allocPrint(allocator, "{s}index {s}..{s} {s}\n", .{ lp, old_h, new_h, mode });
        defer allocator.free(idx);
        try pi.writeStdout(idx);
    }

    // --- and +++ lines
    if (c.is_new) {
        const a_line = try std.fmt.allocPrint(allocator, "{s}--- /dev/null\n", .{lp});
        defer allocator.free(a_line);
        try pi.writeStdout(a_line);
        const b_line = try std.fmt.allocPrint(allocator, "{s}+++ {s}{s}\n", .{ lp, dp, c.path });
        defer allocator.free(b_line);
        try pi.writeStdout(b_line);
    } else if (c.is_deleted) {
        const a_line = try std.fmt.allocPrint(allocator, "{s}--- {s}{s}\n", .{ lp, sp, c.path });
        defer allocator.free(a_line);
        try pi.writeStdout(a_line);
        const b_line = try std.fmt.allocPrint(allocator, "{s}+++ /dev/null\n", .{lp});
        defer allocator.free(b_line);
        try pi.writeStdout(b_line);
    } else {
        const a_line = try std.fmt.allocPrint(allocator, "{s}--- {s}{s}\n", .{ lp, sp, c.path });
        defer allocator.free(a_line);
        try pi.writeStdout(a_line);
        const b_line = try std.fmt.allocPrint(allocator, "{s}+++ {s}{s}\n", .{ lp, dp, c.path });
        defer allocator.free(b_line);
        try pi.writeStdout(b_line);
    }
}

fn outputDiffHunks(old_content: []const u8, new_content: []const u8, context_lines: u32, lp: []const u8, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    // Use the existing diff module to generate the unified diff
    const diff_output = diff_mod.generateUnifiedDiffWithHashesAndContext(
        old_content, new_content, "placeholder", "0", "0", context_lines, allocator,
    ) catch return;
    defer allocator.free(diff_output);

    // Extract just the hunks (skip the header lines)
    var lines = std.mem.splitScalar(u8, diff_output, '\n');
    var in_hunk = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@")) {
            in_hunk = true;
        }
        if (in_hunk and line.len > 0) {
            if (lp.len > 0) try pi.writeStdout(lp);
            try pi.writeStdout(line);
            try pi.writeStdout("\n");
        }
    }
}

fn doCombinedDiff(allocator: std.mem.Allocator, ref_list: []const []const u8, git_path: []const u8, opts: *const DiffOpts, pi: *const pm.Platform) !void {
    // Combined diff: first ref is the base, diff against the merge of others
    // In git, `diff A B C` shows a combined diff comparing A,B,C
    // Actually it's: diff the tree of the first against each subsequent, show combined format
    if (ref_list.len < 2) return;

    // Resolve all trees
    var trees = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (trees.items) |t| allocator.free(t);
        trees.deinit();
    }
    for (ref_list) |r| {
        const t = resolveToTree(allocator, r, git_path, pi) catch continue;
        try trees.append(t);
    }

    if (trees.items.len < 2) return;

    // Collect files from all trees
    var all_files = std.StringHashMap(void).init(allocator);
    defer all_files.deinit();

    var tree_files = std.array_list.Managed(std.StringHashMap(TreeFileInfo)).init(allocator);
    defer {
        for (tree_files.items) |*tf| {
            var it = tf.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.hash);
                allocator.free(entry.value_ptr.mode);
            }
            tf.deinit();
        }
        tree_files.deinit();
    }

    for (trees.items) |tree_hash| {
        var files = std.StringHashMap(TreeFileInfo).init(allocator);
        try collectAllTreeFiles(allocator, tree_hash, "", git_path, pi, &files);
        var it = files.keyIterator();
        while (it.next()) |k| all_files.put(k.*, {}) catch {};
        try tree_files.append(files);
    }

    // Sort file names
    var sorted = std.array_list.Managed([]const u8).init(allocator);
    defer sorted.deinit();
    var fk = all_files.keyIterator();
    while (fk.next()) |k| try sorted.append(k.*);
    std.mem.sort([]const u8, sorted.items, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.cmp);

    const lp = opts.line_prefix;

    // For each file, check if it differs between trees
    for (sorted.items) |fname| {
        // Get hash/content from each tree
        var hashes = std.array_list.Managed(?[]const u8).init(allocator);
        defer hashes.deinit();
        for (tree_files.items) |tf| {
            if (tf.get(fname)) |info| {
                try hashes.append(info.hash);
            } else {
                try hashes.append(null);
            }
        }

        // Check if all match the last tree
        var all_same = true;
        const last_hash = hashes.items[hashes.items.len - 1];
        for (hashes.items[0 .. hashes.items.len - 1]) |h| {
            if (h == null and last_hash == null) continue;
            if (h == null or last_hash == null) { all_same = false; break; }
            if (!std.mem.eql(u8, h.?, last_hash.?)) { all_same = false; break; }
        }
        if (all_same) continue;

        // Output combined diff for this file
        try outputCombinedFileDiff(allocator, fname, hashes.items, tree_files.items, git_path, lp, pi);
    }
}

const TreeFileInfo = struct {
    hash: []const u8,
    mode: []const u8,
};

fn collectAllTreeFiles(allocator: std.mem.Allocator, tree_hash: []const u8, prefix: []const u8, git_path: []const u8, pi: *const pm.Platform, out: *std.StringHashMap(TreeFileInfo)) !void {
    const obj = objects.GitObject.load(tree_hash, git_path, pi, allocator) catch return;
    defer obj.deinit(allocator);
    if (obj.type != .tree) return;

    var entries = tree_mod.parseTree(obj.data, allocator) catch return;
    defer entries.deinit();

    for (entries.items) |entry| {
        const full_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        const is_tree = std.mem.eql(u8, entry.mode, "40000") or std.mem.eql(u8, entry.mode, "040000");
        if (is_tree) {
            try collectAllTreeFiles(allocator, entry.hash, full_name, git_path, pi, out);
            allocator.free(full_name);
        } else {
            try out.put(full_name, .{
                .hash = try allocator.dupe(u8, entry.hash),
                .mode = try allocator.dupe(u8, entry.mode),
            });
        }
    }
}

fn outputCombinedFileDiff(allocator: std.mem.Allocator, fname: []const u8, hashes: []const ?[]const u8, tree_files: []const std.StringHashMap(TreeFileInfo), git_path: []const u8, lp: []const u8, pi: *const pm.Platform) !void {
    _ = tree_files;
    // Load contents
    var contents = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (contents.items) |c| if (c.len > 0) allocator.free(c);
        contents.deinit();
    }

    for (hashes) |h| {
        if (h) |hash| {
            const content = loadBlob(allocator, hash, git_path, pi) catch try allocator.dupe(u8, "");
            try contents.append(content);
        } else {
            try contents.append(try allocator.dupe(u8, ""));
        }
    }

    if (contents.items.len < 2) return;

    // Build index line with hashes from each tree
    var index_line = std.array_list.Managed(u8).init(allocator);
    defer index_line.deinit();
    try index_line.appendSlice(lp);
    try index_line.appendSlice("index ");
    for (hashes[0 .. hashes.len - 1], 0..) |h, idx| {
        if (idx > 0) try index_line.append(',');
        if (h) |hash| {
            try index_line.appendSlice(hash[0..@min(7, hash.len)]);
        } else {
            try index_line.appendSlice("0000000");
        }
    }
    try index_line.appendSlice("..");
    if (hashes[hashes.len - 1]) |hash| {
        try index_line.appendSlice(hash[0..@min(7, hash.len)]);
    } else {
        try index_line.appendSlice("0000000");
    }
    try index_line.append('\n');

    // Header
    const header = try std.fmt.allocPrint(allocator, "{s}diff --cc {s}\n", .{ lp, fname });
    defer allocator.free(header);
    try pi.writeStdout(header);
    try pi.writeStdout(index_line.items);

    const dash_line = try std.fmt.allocPrint(allocator, "{s}--- a/{s}\n{s}+++ b/{s}\n", .{ lp, fname, lp, fname });
    defer allocator.free(dash_line);
    try pi.writeStdout(dash_line);

    // Generate combined hunks
    try outputCombinedHunks(allocator, contents.items, lp, pi);
}

fn outputCombinedHunks(allocator: std.mem.Allocator, contents: []const []const u8, lp: []const u8, pi: *const pm.Platform) !void {
    if (contents.len < 2) return;

    // Split all contents into lines
    var all_lines = std.array_list.Managed(std.array_list.Managed([]const u8)).init(allocator);
    defer {
        for (all_lines.items) |*al| al.deinit();
        all_lines.deinit();
    }

    for (contents) |c| {
        var lines = std.array_list.Managed([]const u8).init(allocator);
        if (c.len > 0) {
            var it = std.mem.splitScalar(u8, c, '\n');
            while (it.next()) |line| try lines.append(line);
            if (lines.items.len > 0 and c[c.len - 1] == '\n') _ = lines.pop();
        }
        try all_lines.append(lines);
    }

    const result_lines = all_lines.items[all_lines.items.len - 1].items;
    const num_parents = all_lines.items.len - 1;

    // For each line in the result, determine which parents it comes from
    var parent_indices = try allocator.alloc(usize, num_parents);
    defer allocator.free(parent_indices);
    @memset(parent_indices, 0);

    // Simple approach: walk through result lines, for each parent track position
    var hunk_lines = std.array_list.Managed(u8).init(allocator);
    defer hunk_lines.deinit();

    var hunk_old_starts = try allocator.alloc(usize, num_parents);
    defer allocator.free(hunk_old_starts);
    var hunk_old_counts = try allocator.alloc(usize, num_parents);
    defer allocator.free(hunk_old_counts);

    @memset(hunk_old_starts, 1);
    @memset(hunk_old_counts, 0);

    var result_start: usize = 1;
    var result_count: usize = 0;
    var in_hunk = false;

    for (result_lines) |result_line| {
        // Check which parents have this line
        var prefixes = try allocator.alloc(u8, num_parents);
        defer allocator.free(prefixes);

        for (0..num_parents) |p| {
            const parent_lines = all_lines.items[p].items;
            if (parent_indices[p] < parent_lines.len and
                std.mem.eql(u8, parent_lines[parent_indices[p]], result_line))
            {
                prefixes[p] = ' ';
                parent_indices[p] += 1;
            } else {
                prefixes[p] = '+';
            }
        }

        // Check if this line is in all parents
        var all_match = true;
        for (prefixes) |p| {
            if (p != ' ') { all_match = false; break; }
        }

        if (!all_match) {
            if (!in_hunk) {
                in_hunk = true;
                hunk_lines.clearRetainingCapacity();
                for (0..num_parents) |p| {
                    hunk_old_starts[p] = parent_indices[p]; // will be adjusted
                    hunk_old_counts[p] = 0;
                }
                result_start = result_count + 1;
            }
        }

        if (in_hunk) {
            for (prefixes) |p| try hunk_lines.append(p);
            try hunk_lines.appendSlice(result_line);
            try hunk_lines.append('\n');
            for (0..num_parents) |p| {
                if (prefixes[p] == ' ') hunk_old_counts[p] += 1;
            }
        }

        result_count += 1;
    }

    // Handle lines only in parents (deleted lines)
    for (0..num_parents) |p| {
        while (parent_indices[p] < all_lines.items[p].items.len) {
            if (!in_hunk) {
                in_hunk = true;
                hunk_lines.clearRetainingCapacity();
                for (0..num_parents) |pp| {
                    hunk_old_starts[pp] = parent_indices[pp] + 1;
                    hunk_old_counts[pp] = 0;
                }
                result_start = result_count + 1;
            }
            // Output deleted line
            for (0..num_parents) |pp| {
                if (pp == p) {
                    try hunk_lines.append('-');
                } else {
                    try hunk_lines.append(' ');
                }
            }
            try hunk_lines.appendSlice(all_lines.items[p].items[parent_indices[p]]);
            try hunk_lines.append('\n');
            hunk_old_counts[p] += 1;
            parent_indices[p] += 1;
        }
    }

    if (in_hunk and hunk_lines.items.len > 0) {
        // Output hunk header
        var header = std.array_list.Managed(u8).init(allocator);
        defer header.deinit();
        try header.appendSlice(lp);
        try header.appendSlice("@@@");
        // Actually for N parents, use N+1 @ signs
        // Wait, git uses @@@ for 2-parent merge (3 @s), @@@@ for 3-parent, etc.
        // The header format is: @@@ -old1,count1 -old2,count2 +new,count @@@
        // Let me fix this:
        header.clearRetainingCapacity();
        try header.appendSlice(lp);
        // N+1 @ signs
        for (0..num_parents + 1) |_| try header.append('@');
        for (0..num_parents) |p| {
            try header.appendSlice(" -");
            const start = if (hunk_old_counts[p] > 0) hunk_old_starts[p] else 0;
            const count = hunk_old_counts[p] + result_count - result_start + 1; // approximate
            _ = start;
            _ = count;
            // Use the parent's line count
            const parent_total = all_lines.items[p].items.len;
            try header.writer().print("{d}", .{if (parent_total > 0) @as(usize, 1) else @as(usize, 0)});
            if (parent_total != 1) try header.writer().print(",{d}", .{parent_total});
        }
        try header.appendSlice(" +");
        try header.writer().print("{d}", .{if (result_lines.len > 0) @as(usize, 1) else @as(usize, 0)});
        if (result_lines.len != 1) try header.writer().print(",{d}", .{result_lines.len});
        try header.append(' ');
        for (0..num_parents + 1) |_| try header.append('@');
        try header.append('\n');

        try pi.writeStdout(header.items);
        try pi.writeStdout(hunk_lines.items);
    }
}

fn doDiffNoIndex(allocator: std.mem.Allocator, opts: *const DiffOpts, positional: *const std.array_list.Managed([]const u8), pathspec_args: *const std.array_list.Managed([]const u8), pi: *const pm.Platform) !void {
    // Collect file paths from both positional and pathspec_args
    var paths = std.array_list.Managed([]const u8).init(allocator);
    defer paths.deinit();
    for (positional.items) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            try paths.append(arg);
        }
    }
    // Also check pathspec_args (stuff after --)
    for (pathspec_args.items) |arg| {
        try paths.append(arg);
    }

    if (paths.items.len < 2) {
        try pi.writeStderr("usage: git diff --no-index <path> <path>\n");
        std.process.exit(129);
    }

    const path_a = paths.items[0];
    const path_b = paths.items[1];

    // Check if paths are files or directories
    const stat_a = std.fs.cwd().statFile(path_a) catch null;
    const stat_b = std.fs.cwd().statFile(path_b) catch null;

    if (stat_a != null and stat_a.?.kind == .directory and
        stat_b != null and stat_b.?.kind == .directory)
    {
        // Compare directories
        try diffDirectories(allocator, path_a, path_b, opts, pi);
    } else if (stat_a != null and stat_b != null) {
        // Compare two files
        try diffTwoFiles(allocator, path_a, path_b, opts, pi);
    } else {
        // One might be /dev/null or missing
        if (stat_b != null) {
            try diffNewFile(allocator, path_b, opts, pi);
        } else if (stat_a != null) {
            // Deleted file
        }
    }
}

fn diffDirectories(allocator: std.mem.Allocator, dir_a: []const u8, dir_b: []const u8, opts: *const DiffOpts, pi: *const pm.Platform) !void {
    // Find files in dir_b that don't exist in dir_a
    var dir_b_iter = std.fs.cwd().openDir(dir_b, .{ .iterate = true }) catch return;
    defer dir_b_iter.close();

    var files_b = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (files_b.items) |f| allocator.free(f);
        files_b.deinit();
    }

    var it = dir_b_iter.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind == .file) {
            try files_b.append(try allocator.dupe(u8, entry.name));
        }
    }

    std.mem.sort([]const u8, files_b.items, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.cmp);

    for (files_b.items) |fname| {
        const path_a = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_a, fname });
        defer allocator.free(path_a);
        const path_b = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_b, fname });
        defer allocator.free(path_b);

        const stat_a = std.fs.cwd().statFile(path_a) catch null;
        if (stat_a == null) {
            // File only in dir_b - it's a new file
            const rel_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_b, fname });
            defer allocator.free(rel_path);

            switch (opts.output_mode) {
                .name_status => {
                    const line = try std.fmt.allocPrint(allocator, "A\t{s}\n", .{rel_path});
                    defer allocator.free(line);
                    try pi.writeStdout(line);
                },
                .name_only => {
                    const line = try std.fmt.allocPrint(allocator, "{s}\n", .{rel_path});
                    defer allocator.free(line);
                    try pi.writeStdout(line);
                },
                .raw => {
                    const zero = "0000000000000000000000000000000000000000";
                    const abbrev_len = opts.getAbbrevLen();
                    const oh = abbreviateHash(zero, abbrev_len);
                    const nh = abbreviateHash(zero, abbrev_len);
                    const env_e = std.process.getEnvVarOwned(allocator, "GIT_PRINT_SHA1_ELLIPSIS") catch null;
                    defer if (env_e) |e| allocator.free(e);
                    const show_e = if (env_e) |e| std.mem.eql(u8, e, "yes") else false;
                    const ell: []const u8 = if (abbrev_len < 40 and show_e) "..." else "";
                    const line = try std.fmt.allocPrint(allocator, ":000000 100644 {s}{s} {s}{s} A\t{s}\n", .{ oh, ell, nh, ell, rel_path });
                    defer allocator.free(line);
                    try pi.writeStdout(line);
                },
                else => {
                    // Default: show patch
                    const content = std.fs.cwd().readFileAlloc(allocator, path_b, 10 * 1024 * 1024) catch continue;
                    defer allocator.free(content);
                    try outputNewFilePatch(allocator, rel_path, content, opts, pi);
                },
            }
        } else {
            // File in both - compare
            switch (opts.output_mode) {
                .name_status, .name_only, .raw => {
                    // Compare content
                    const content_a = std.fs.cwd().readFileAlloc(allocator, path_a, 10 * 1024 * 1024) catch continue;
                    defer allocator.free(content_a);
                    const content_b2 = std.fs.cwd().readFileAlloc(allocator, path_b, 10 * 1024 * 1024) catch continue;
                    defer allocator.free(content_b2);
                    if (!std.mem.eql(u8, content_a, content_b2)) {
                        const rel_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_b, fname });
                        defer allocator.free(rel_path);
                        if (opts.output_mode == .name_status) {
                            const line = try std.fmt.allocPrint(allocator, "M\t{s}\n", .{rel_path});
                            defer allocator.free(line);
                            try pi.writeStdout(line);
                        } else if (opts.output_mode == .name_only) {
                            const line = try std.fmt.allocPrint(allocator, "{s}\n", .{rel_path});
                            defer allocator.free(line);
                            try pi.writeStdout(line);
                        }
                    }
                },
                else => {
                    try diffTwoFiles(allocator, path_a, path_b, opts, pi);
                },
            }
        }
    }
}

fn diffTwoFiles(allocator: std.mem.Allocator, path_a: []const u8, path_b: []const u8, opts: *const DiffOpts, pi: *const pm.Platform) !void {
    const content_a = std.fs.cwd().readFileAlloc(allocator, path_a, 10 * 1024 * 1024) catch "";
    defer if (content_a.len > 0) allocator.free(content_a);
    const content_b = std.fs.cwd().readFileAlloc(allocator, path_b, 10 * 1024 * 1024) catch "";
    defer if (content_b.len > 0) allocator.free(content_b);

    if (std.mem.eql(u8, content_a, content_b)) return;

    const sp = opts.getEffectiveSrcPrefix();
    const dp = opts.getEffectiveDstPrefix();

    const header = try std.fmt.allocPrint(allocator, "diff --git {s}{s} {s}{s}\n--- {s}{s}\n+++ {s}{s}\n", .{
        sp, path_a, dp, path_b, sp, path_a, dp, path_b,
    });
    defer allocator.free(header);
    try pi.writeStdout(header);

    try outputDiffHunks(content_a, content_b, opts.context_lines, "", pi, allocator);
}

fn diffNewFile(allocator: std.mem.Allocator, path: []const u8, opts: *const DiffOpts, pi: *const pm.Platform) !void {
    const content = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch return;
    defer allocator.free(content);
    try outputNewFilePatch(allocator, path, content, opts, pi);
}

fn outputNewFilePatch(allocator: std.mem.Allocator, path: []const u8, content: []const u8, opts: *const DiffOpts, pi: *const pm.Platform) !void {
    const sp = opts.getEffectiveSrcPrefix();
    const dp = opts.getEffectiveDstPrefix();

    const header = try std.fmt.allocPrint(allocator, "diff --git {s}{s} {s}{s}\nnew file mode 100644\n--- /dev/null\n+++ {s}{s}\n", .{
        sp, path, dp, path, dp, path,
    });
    defer allocator.free(header);
    try pi.writeStdout(header);

    // Output all lines as additions
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_count: usize = 0;
    while (lines.next()) |_| line_count += 1;
    if (content.len > 0 and content[content.len - 1] == '\n') line_count -= 1;

    if (line_count > 0) {
        const hh = try std.fmt.allocPrint(allocator, "@@ -0,0 +1,{d} @@\n", .{line_count});
        defer allocator.free(hh);
        try pi.writeStdout(hh);

        var it2 = std.mem.splitScalar(u8, content, '\n');
        var count: usize = 0;
        while (it2.next()) |line| {
            count += 1;
            if (count > line_count) break;
            const l = try std.fmt.allocPrint(allocator, "+{s}\n", .{line});
            defer allocator.free(l);
            try pi.writeStdout(l);
        }
    }
}

fn doRefToIndexDiff(allocator: std.mem.Allocator, ref_name: []const u8, index: *const index_mod.Index, git_path: []const u8, opts: *const DiffOpts, pathspecs: []const []const u8, pi: *const pm.Platform) !void {
    // Compare ref tree to index (--cached)
    const tree_hash = resolveToTree(allocator, ref_name, git_path, pi) catch return;
    defer allocator.free(tree_hash);

    var changes = std.array_list.Managed(FileChange).init(allocator);
    defer {
        for (changes.items) |*c| freeChange(allocator, c);
        changes.deinit();
    }

    // Walk tree and compare with index
    var tree_files = std.StringHashMap(TreeFileInfo).init(allocator);
    defer {
        var it = tree_files.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.hash);
            allocator.free(entry.value_ptr.mode);
        }
        tree_files.deinit();
    }
    try collectAllTreeFiles(allocator, tree_hash, "", git_path, pi, &tree_files);

    // Compare index entries against tree
    for (index.entries.items) |entry| {
        if (pathspecs.len > 0 and !matchPathspec(entry.path, pathspecs)) continue;

        var idx_hash_buf: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&idx_hash_buf, "{x}", .{&entry.sha1}) catch continue;

        if (tree_files.get(entry.path)) |tree_info| {
            if (std.mem.eql(u8, tree_info.hash, &idx_hash_buf)) continue;
            const old_c = loadBlob(allocator, tree_info.hash, git_path, pi) catch try allocator.dupe(u8, "");
            const new_c = loadBlob(allocator, &idx_hash_buf, git_path, pi) catch try allocator.dupe(u8, "");
            const stats = diff_stats.countInsDels(old_c, new_c);
            try changes.append(.{
                .path = try allocator.dupe(u8, entry.path),
                .old_hash = try allocator.dupe(u8, tree_info.hash),
                .new_hash = try allocator.dupe(u8, &idx_hash_buf),
                .old_mode = try allocator.dupe(u8, tree_info.mode),
                .new_mode = try allocator.dupe(u8, tree_info.mode),
                .old_content = old_c,
                .new_content = new_c,
                .insertions = stats.ins,
                .deletions = stats.dels,
                .is_new = false,
                .is_deleted = false,
                .is_binary = diff_stats.isBinContent(old_c) or diff_stats.isBinContent(new_c),
            });
        } else {
            // New file in index
            const new_c = loadBlob(allocator, &idx_hash_buf, git_path, pi) catch try allocator.dupe(u8, "");
            try changes.append(.{
                .path = try allocator.dupe(u8, entry.path),
                .old_hash = try allocator.dupe(u8, "0000000000000000000000000000000000000000"),
                .new_hash = try allocator.dupe(u8, &idx_hash_buf),
                .old_mode = try allocator.dupe(u8, "000000"),
                .new_mode = try allocator.dupe(u8, "100644"),
                .old_content = try allocator.dupe(u8, ""),
                .new_content = new_c,
                .insertions = diff_stats.countLines(new_c),
                .deletions = 0,
                .is_new = true,
                .is_deleted = false,
                .is_binary = diff_stats.isBinContent(new_c),
            });
        }
    }

    try outputChanges(changes.items, opts, pi, allocator);
}

fn doRefToWorkingDiff(allocator: std.mem.Allocator, ref_name: []const u8, index: *const index_mod.Index, cwd: []const u8, git_path: []const u8, opts: *const DiffOpts, pathspecs: []const []const u8, pi: *const pm.Platform) !void {
    _ = cwd;
    // Compare ref tree to working tree
    // For each index entry, compare its hash against the ref tree's hash
    const tree_hash = resolveToTree(allocator, ref_name, git_path, pi) catch return;
    defer allocator.free(tree_hash);

    var changes = std.array_list.Managed(FileChange).init(allocator);
    defer {
        for (changes.items) |*c| freeChange(allocator, c);
        changes.deinit();
    }

    // Walk ref tree
    var tree_files = std.StringHashMap(TreeFileInfo).init(allocator);
    defer {
        var it = tree_files.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.hash);
            allocator.free(entry.value_ptr.mode);
        }
        tree_files.deinit();
    }
    try collectAllTreeFiles(allocator, tree_hash, "", git_path, pi, &tree_files);

    // Build index map
    var index_map = std.StringHashMap(IndexFileInfo).init(allocator);
    defer index_map.deinit();
    for (index.entries.items) |entry| {
        var idx_hash_buf: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&idx_hash_buf, "{x}", .{&entry.sha1}) catch continue;
        index_map.put(entry.path, .{ .hash = idx_hash_buf }) catch {};
    }

    // Compare: files in tree but not index (deleted), files in index but not tree (added),
    // files in both but different (modified)
    var all_paths = std.StringHashMap(void).init(allocator);
    defer all_paths.deinit();
    var tkit = tree_files.keyIterator();
    while (tkit.next()) |k| all_paths.put(k.*, {}) catch {};
    for (index.entries.items) |entry| all_paths.put(entry.path, {}) catch {};

    var sorted = std.array_list.Managed([]const u8).init(allocator);
    defer sorted.deinit();
    var apit = all_paths.keyIterator();
    while (apit.next()) |k| try sorted.append(k.*);
    std.mem.sort([]const u8, sorted.items, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.cmp);

    for (sorted.items) |path| {
        if (pathspecs.len > 0 and !matchPathspec(path, pathspecs)) continue;

        const in_tree = tree_files.get(path);
        const in_index = index_map.get(path);

        if (in_tree != null and in_index != null) {
            const tree_info = in_tree.?;
            const idx_info = in_index.?;
            if (std.mem.eql(u8, tree_info.hash, &idx_info.hash)) continue;
            // Modified
            const old_c = loadBlob(allocator, tree_info.hash, git_path, pi) catch try allocator.dupe(u8, "");
            const new_c = loadBlob(allocator, &idx_info.hash, git_path, pi) catch try allocator.dupe(u8, "");
            const stats = diff_stats.countInsDels(old_c, new_c);
            try changes.append(.{
                .path = try allocator.dupe(u8, path),
                .old_hash = try allocator.dupe(u8, tree_info.hash),
                .new_hash = try allocator.dupe(u8, &idx_info.hash),
                .old_mode = try allocator.dupe(u8, tree_info.mode),
                .new_mode = try allocator.dupe(u8, tree_info.mode),
                .old_content = old_c,
                .new_content = new_c,
                .insertions = stats.ins,
                .deletions = stats.dels,
                .is_new = false,
                .is_deleted = false,
                .is_binary = diff_stats.isBinContent(old_c) or diff_stats.isBinContent(new_c),
            });
        } else if (in_tree != null) {
            // Deleted from working tree
            const tree_info = in_tree.?;
            const old_c = loadBlob(allocator, tree_info.hash, git_path, pi) catch try allocator.dupe(u8, "");
            try changes.append(.{
                .path = try allocator.dupe(u8, path),
                .old_hash = try allocator.dupe(u8, tree_info.hash),
                .new_hash = try allocator.dupe(u8, "0000000000000000000000000000000000000000"),
                .old_mode = try allocator.dupe(u8, tree_info.mode),
                .new_mode = try allocator.dupe(u8, "000000"),
                .old_content = old_c,
                .new_content = try allocator.dupe(u8, ""),
                .insertions = 0,
                .deletions = diff_stats.countLines(old_c),
                .is_new = false,
                .is_deleted = true,
                .is_binary = diff_stats.isBinContent(old_c),
            });
        } else if (in_index != null) {
            // Added in working tree
            const idx_info = in_index.?;
            const new_c = loadBlob(allocator, &idx_info.hash, git_path, pi) catch try allocator.dupe(u8, "");
            try changes.append(.{
                .path = try allocator.dupe(u8, path),
                .old_hash = try allocator.dupe(u8, "0000000000000000000000000000000000000000"),
                .new_hash = try allocator.dupe(u8, &idx_info.hash),
                .old_mode = try allocator.dupe(u8, "000000"),
                .new_mode = try allocator.dupe(u8, "100644"),
                .old_content = try allocator.dupe(u8, ""),
                .new_content = new_c,
                .insertions = diff_stats.countLines(new_c),
                .deletions = 0,
                .is_new = true,
                .is_deleted = false,
                .is_binary = diff_stats.isBinContent(new_c),
            });
        }
    }

    try outputChanges(changes.items, opts, pi, allocator);
}

const IndexFileInfo = struct {
    hash: [40]u8,
};

fn doIndexToHeadDiff(allocator: std.mem.Allocator, index: *const index_mod.Index, git_path: []const u8, opts: *const DiffOpts, pathspecs: []const []const u8, pi: *const pm.Platform) !void {
    // Get HEAD tree
    const head_commit = refs.getCurrentCommit(git_path, pi, allocator) catch return;
    defer if (head_commit) |hc| allocator.free(hc);

    if (head_commit == null) {
        // Unborn branch - all index entries are new
        var changes = std.array_list.Managed(FileChange).init(allocator);
        defer {
            for (changes.items) |*c| freeChange(allocator, c);
            changes.deinit();
        }

        for (index.entries.items) |entry| {
            if (pathspecs.len > 0 and !matchPathspec(entry.path, pathspecs)) continue;

            var idx_hash_buf: [40]u8 = undefined;
            _ = std.fmt.bufPrint(&idx_hash_buf, "{x}", .{&entry.sha1}) catch continue;

            const new_c = loadBlob(allocator, &idx_hash_buf, git_path, pi) catch try allocator.dupe(u8, "");
            try changes.append(.{
                .path = try allocator.dupe(u8, entry.path),
                .old_hash = try allocator.dupe(u8, "0000000000000000000000000000000000000000"),
                .new_hash = try allocator.dupe(u8, &idx_hash_buf),
                .old_mode = try allocator.dupe(u8, "000000"),
                .new_mode = try allocator.dupe(u8, "100644"),
                .old_content = try allocator.dupe(u8, ""),
                .new_content = new_c,
                .insertions = diff_stats.countLines(new_c),
                .deletions = 0,
                .is_new = true,
                .is_deleted = false,
                .is_binary = diff_stats.isBinContent(new_c),
            });
        }

        try outputChanges(changes.items, opts, pi, allocator);
        return;
    }

    // Use HEAD as ref
    try doRefToIndexDiff(allocator, "HEAD", index, git_path, opts, pathspecs, pi);
}

fn doWorkingTreeDiff(allocator: std.mem.Allocator, index: *const index_mod.Index, cwd: []const u8, git_path: []const u8, opts: *const DiffOpts, pathspecs: []const []const u8, pi: *const pm.Platform) !void {
    _ = cwd;
    var changes = std.array_list.Managed(FileChange).init(allocator);
    defer {
        for (changes.items) |*c| freeChange(allocator, c);
        changes.deinit();
    }

    for (index.entries.items) |entry| {
        if (pathspecs.len > 0 and !matchPathspec(entry.path, pathspecs)) continue;

        var idx_hash_buf: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&idx_hash_buf, "{x}", .{&entry.sha1}) catch continue;

        // Read working tree file
        const wt_content = pi.fs.readFile(allocator, entry.path) catch {
            // File might be deleted
            const old_c = loadBlob(allocator, &idx_hash_buf, git_path, pi) catch continue;
            try changes.append(.{
                .path = try allocator.dupe(u8, entry.path),
                .old_hash = try allocator.dupe(u8, &idx_hash_buf),
                .new_hash = try allocator.dupe(u8, "0000000000000000000000000000000000000000"),
                .old_mode = try allocator.dupe(u8, "100644"),
                .new_mode = try allocator.dupe(u8, "000000"),
                .old_content = old_c,
                .new_content = try allocator.dupe(u8, ""),
                .insertions = 0,
                .deletions = diff_stats.countLines(old_c),
                .is_new = false,
                .is_deleted = true,
                .is_binary = false,
            });
            continue;
        };

        // Hash the working tree content
        const wt_obj = objects.createBlobObject(wt_content, allocator) catch continue;
        defer wt_obj.deinit(allocator);
        const wt_hash = wt_obj.hash(allocator) catch continue;
        defer allocator.free(wt_hash);

        if (std.mem.eql(u8, wt_hash, &idx_hash_buf)) {
            allocator.free(wt_content);
            continue;
        }

        const old_c = loadBlob(allocator, &idx_hash_buf, git_path, pi) catch try allocator.dupe(u8, "");
        const stats = diff_stats.countInsDels(old_c, wt_content);
        try changes.append(.{
            .path = try allocator.dupe(u8, entry.path),
            .old_hash = try allocator.dupe(u8, &idx_hash_buf),
            .new_hash = try allocator.dupe(u8, wt_hash),
            .old_mode = try allocator.dupe(u8, "100644"),
            .new_mode = try allocator.dupe(u8, "100644"),
            .old_content = old_c,
            .new_content = wt_content,
            .insertions = stats.ins,
            .deletions = stats.dels,
            .is_new = false,
            .is_deleted = false,
            .is_binary = diff_stats.isBinContent(old_c) or diff_stats.isBinContent(wt_content),
        });
    }

    try outputChanges(changes.items, opts, pi, allocator);
}

fn outputChanges(changes: []const FileChange, opts: *const DiffOpts, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    if (opts.quiet) return;

    switch (opts.output_mode) {
        .stat => try outputStat(changes, pi, allocator),
        .shortstat => try outputShortStat(changes, pi, allocator),
        .numstat => try outputNumStat(changes, pi, allocator),
        .name_only => try outputNameOnly(changes, pi, allocator),
        .name_status => try outputNameStatus(changes, pi, allocator),
        .raw => try outputRaw(changes, opts, pi, allocator),
        .summary => try outputSummary(changes, pi, allocator),
        .dirstat => try outputDirStat(changes, pi, allocator),
        .patch => try outputPatch(changes, opts, pi, allocator),
        .patch_with_stat => {
            try outputStat(changes, pi, allocator);
            try pi.writeStdout("\n");
            try outputPatch(changes, opts, pi, allocator);
        },
        .patch_with_raw => {
            try outputRaw(changes, opts, pi, allocator);
            try pi.writeStdout("\n");
            try outputPatch(changes, opts, pi, allocator);
        },
        .no_patch => {},
    }

    if ((opts.exit_code or opts.quiet) and changes.len > 0) {
        std.process.exit(1);
    }
}
