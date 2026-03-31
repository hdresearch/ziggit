const git_helpers_mod = @import("../git_helpers.zig");
const std = @import("std");
const pm = @import("../platform/platform.zig");
const refs = @import("refs.zig");
const objects = @import("objects.zig");
const tree_mod = @import("tree.zig");
const index_mod = @import("index.zig");
const diff_mod = @import("diff.zig");
const diff_stats = @import("diff_stats.zig");
const userdiff = @import("userdiff.zig");
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
    find_renames: bool = false,
    find_copies: bool = false,
    rename_limit: ?u32 = null,
    reverse: bool = false,
    compact_summary: bool = false,
    show_summary: bool = false,
    ignore_regex: std.array_list.Managed([]const u8) = undefined,
    ignore_blank_lines: bool = false,
    suppress_blank_empty: bool = false,
    combined_use_c: bool = false, // true for -c (diff --combined), false for --cc (diff --cc)
    break_rewrites: bool = false,

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
    is_rename: bool = false,
    rename_from: ?[]const u8 = null,
    similarity: u8 = 0,
    is_unmerged: bool = false,
};

pub fn cmdDiff(allocator: std.mem.Allocator, args: *pm.ArgIterator, platform_impl: *const pm.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("diff: not supported in freestanding mode\n");
        return;
    }
    // Debug removed

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
    const git_path_for_config = git_helpers_mod.findGitDirectory(allocator, platform_impl) catch null;
    defer if (git_path_for_config) |gp| allocator.free(gp);

    if (git_path_for_config != null) {
        // Check config overrides first, then read config file
        if (git_helpers_mod.getConfigOverride("diff.noprefix")) |val| {
            if (std.mem.eql(u8, val, "true")) opts.no_prefix = true;
        }
        if (git_helpers_mod.getConfigOverride("diff.mnemonicprefix")) |val| {
            if (std.mem.eql(u8, val, "true")) opts.mnemonic_prefix = true;
        }
        if (git_helpers_mod.getConfigOverride("diff.srcprefix")) |val| {
            opts.src_prefix = val;
        }
        if (git_helpers_mod.getConfigOverride("diff.dstprefix")) |val| {
            opts.dst_prefix = val;
        }
        if (git_helpers_mod.getConfigOverride("diff.renames")) |val| {
            if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) {
                opts.no_renames = true;
            }
        }
        if (git_helpers_mod.getConfigOverride("diff.suppressBlankEmpty")) |val| {
            if (std.mem.eql(u8, val, "true")) opts.suppress_blank_empty = true;
        }
        // Also check config file for suppressBlankEmpty
        if (!opts.suppress_blank_empty) {
            const cfg_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path_for_config.?}) catch null;
            defer if (cfg_path) |p| allocator.free(p);
            if (cfg_path) |p| {
                const cfg_data = std.fs.cwd().readFileAlloc(allocator, p, 1024 * 1024) catch null;
                defer if (cfg_data) |d| allocator.free(d);
                if (cfg_data) |d| {
                    if (getConfigValue(d, "diff", "suppressBlankEmpty")) |v| {
                        if (std.ascii.eqlIgnoreCase(v, "true")) opts.suppress_blank_empty = true;
                    }
                }
            }
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
            opts.show_summary = true;
            if (opts.output_mode == .patch or opts.output_mode == .no_patch) opts.output_mode = .summary;
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
        } else if (std.mem.eql(u8, arg, "-M") or std.mem.startsWith(u8, arg, "-M") or std.mem.eql(u8, arg, "--find-renames") or std.mem.startsWith(u8, arg, "--find-renames=")) {
            opts.find_renames = true;
        } else if (std.mem.eql(u8, arg, "-C") or std.mem.startsWith(u8, arg, "-C") or std.mem.eql(u8, arg, "--find-copies") or std.mem.startsWith(u8, arg, "--find-copies=")) {
            opts.find_copies = true;
            opts.find_renames = true;
        } else if (std.mem.startsWith(u8, arg, "-l") and arg.len > 2) {
            opts.rename_limit = std.fmt.parseInt(u32, arg[2..], 10) catch null;
        } else if (std.mem.eql(u8, arg, "-R")) {
            opts.reverse = true;
        } else if (std.mem.eql(u8, arg, "--compact-summary")) {
            opts.compact_summary = true;
            if (opts.output_mode == .no_patch) opts.output_mode = .patch;
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
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--ignore-all-space")) {
            // Ignore whitespace changes - accept but treat as noop for now
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--ignore-space-change")) {
            // Accept
        } else if (std.mem.eql(u8, arg, "--ignore-space-at-eol")) {
            // Accept
        } else if (std.mem.eql(u8, arg, "--check")) {
            opts.check_mode = true;
        } else if (std.mem.eql(u8, arg, "--find-copies-harder")) {
            opts.find_copies = true;
            opts.find_renames = true;
        } else if (std.mem.eql(u8, arg, "--submodule") or std.mem.startsWith(u8, arg, "--submodule=")) {
            // Accept submodule option
        } else if (std.mem.eql(u8, arg, "--color") or std.mem.startsWith(u8, arg, "--color=")) {
            // Accept color option
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            // Accept
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--text")) {
            // Accept
        } else if (std.mem.eql(u8, arg, "--binary")) {
            // Accept (we don't output binary patches but don't error)
        } else if (std.mem.eql(u8, arg, "--ita-invisible-in-index") or std.mem.eql(u8, arg, "--ita-visible-in-index")) {
            // Accept
        } else if (std.mem.eql(u8, arg, "--patience") or std.mem.eql(u8, arg, "--histogram") or std.mem.eql(u8, arg, "--minimal") or std.mem.eql(u8, arg, "--no-minimal")) {
            // Accept diff algorithm options
        } else if (std.mem.startsWith(u8, arg, "--diff-algorithm=")) {
            // Accept
        } else if (std.mem.startsWith(u8, arg, "--diff-filter=")) {
            // Accept diff filter
        } else if (std.mem.startsWith(u8, arg, "--word-diff") or std.mem.startsWith(u8, arg, "--color-words") or std.mem.startsWith(u8, arg, "--color-moved")) {
            // Accept
        } else if (std.mem.startsWith(u8, arg, "--inter-hunk-context=")) {
            // Accept
        } else if (std.mem.eql(u8, arg, "--function-context")) {
            // Accept
        } else if (std.mem.eql(u8, arg, "--ext-diff") or std.mem.eql(u8, arg, "--no-ext-diff")) {
            // Accept
        } else if (std.mem.eql(u8, arg, "--textconv") or std.mem.eql(u8, arg, "--no-textconv")) {
            // Accept
        } else if (std.mem.eql(u8, arg, "--ignore-submodules") or std.mem.startsWith(u8, arg, "--ignore-submodules=")) {
            // Accept
        } else if (std.mem.eql(u8, arg, "--indent-heuristic") or std.mem.eql(u8, arg, "--no-indent-heuristic")) {
            // Accept
        } else if (std.mem.eql(u8, arg, "--no-pager")) {
            // Accept
        } else if (std.mem.startsWith(u8, arg, "--output=") or std.mem.startsWith(u8, arg, "--output-indicator-")) {
            // Accept
        } else if (std.mem.startsWith(u8, arg, "--relative") or std.mem.startsWith(u8, arg, "--no-relative")) {
            // Accept
        } else if (std.mem.startsWith(u8, arg, "--break-rewrites") or std.mem.startsWith(u8, arg, "-B")) {
            opts.break_rewrites = true;
        } else if (std.mem.startsWith(u8, arg, "--") and arg.len > 2) {
            // Unknown long option - error
            const msg = try std.fmt.allocPrint(allocator, "usage: git diff [<options>] [<commit>] [--] [<path>...]\n", .{});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        } else if (std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-") and arg.len > 1) {
            // Unknown short option - accept for compatibility
        } else {
            try positional.append(arg);
        }
    }

    if (has_no_index) {
        try doDiffNoIndex(allocator, &opts, &positional, &pathspec_args, platform_impl);
        return;
    }

    const git_path = git_helpers_mod.findGitDirectory(allocator, platform_impl) catch {
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
    const hash = try git_helpers_mod.resolveRevision(git_path, ref_str, platform_impl, allocator);
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

    try outputChanges(changes.items, opts, pi, allocator);
}

fn fileChangeContainsString(c: *const FileChange, search: []const u8) bool {
    // Check if the search string appears in the old or new content
    // (i.e., the file is relevant to the pickaxe search)
    if (search.len == 0) return true;
    const old_has = if (c.old_content.len > 0) std.mem.indexOf(u8, c.old_content, search) != null else false;
    const new_has = if (c.new_content.len > 0) std.mem.indexOf(u8, c.new_content, search) != null else false;
    // Show file if the count of occurrences changed
    if (old_has != new_has) return true;
    if (old_has and new_has) {
        // Count occurrences
        var old_count: usize = 0;
        var oi: usize = 0;
        while (oi <= c.old_content.len - search.len) {
            if (std.mem.eql(u8, c.old_content[oi .. oi + search.len], search)) {
                old_count += 1;
                oi += search.len;
            } else oi += 1;
        }
        var new_count: usize = 0;
        var ni: usize = 0;
        while (ni <= c.new_content.len - search.len) {
            if (std.mem.eql(u8, c.new_content[ni .. ni + search.len], search)) {
                new_count += 1;
                ni += search.len;
            } else ni += 1;
        }
        return old_count != new_count;
    }
    return false;
}

fn fileChangeMatchesGrep(c: *const FileChange, search: []const u8) bool {
    // Check if search string appears in diff lines (added or removed)
    if (search.len == 0) return true;
    // Simple: check if the diff hunks contain the search string in changed lines
    const old_has = if (c.old_content.len > 0) std.mem.indexOf(u8, c.old_content, search) != null else false;
    const new_has = if (c.new_content.len > 0) std.mem.indexOf(u8, c.new_content, search) != null else false;
    return old_has or new_has;
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

const EMPTY_TREE_HASH = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

fn collectTreeChanges(allocator: std.mem.Allocator, tree1_hash: []const u8, tree2_hash: []const u8, prefix: []const u8, git_path: []const u8, pathspecs: []const []const u8, pi: *const pm.Platform, out: *std.array_list.Managed(FileChange)) !void {
    const is_empty1 = std.mem.eql(u8, tree1_hash, EMPTY_TREE_HASH);
    const is_empty2 = std.mem.eql(u8, tree2_hash, EMPTY_TREE_HASH);

    const t1o = if (!is_empty1) (objects.GitObject.load(tree1_hash, git_path, pi, allocator) catch return) else null;
    defer if (t1o) |o| o.deinit(allocator);
    const t2o = if (!is_empty2) (objects.GitObject.load(tree2_hash, git_path, pi, allocator) catch return) else null;
    defer if (t2o) |o| o.deinit(allocator);

    var p1 = if (t1o) |o| (tree_mod.parseTree(o.data, allocator) catch return) else std.array_list.Managed(tree_mod.TreeEntry).init(allocator);
    defer p1.deinit();
    var p2 = if (t2o) |o| (tree_mod.parseTree(o.data, allocator) catch return) else std.array_list.Managed(tree_mod.TreeEntry).init(allocator);
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
                const empty_tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
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
                const empty_tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
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
    for (pathspecs) |raw_ps| {
        // Strip trailing slash from pathspec for matching
        const ps = if (raw_ps.len > 0 and raw_ps[raw_ps.len - 1] == '/') raw_ps[0 .. raw_ps.len - 1] else raw_ps;
        if (std.mem.eql(u8, path, ps)) return true;
        // path starts with pathspec (path is under pathspec directory)
        if (std.mem.startsWith(u8, path, ps) and path.len > ps.len and path[ps.len] == '/') return true;
        // path is under pathspec with trailing slash (dir/ matches dir/sub)
        if (std.mem.startsWith(u8, path, raw_ps)) return true;
        // pathspec starts with path (pathspec is under path directory)
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

/// Simple POSIX-like regex matcher supporting: . * + ? ^ $ [...] [^...]
/// Used for -I<regex> pattern matching
fn simpleRegexMatch(pattern: []const u8, str: []const u8) bool {
    // If pattern starts with ^, must match from start
    if (pattern.len > 0 and pattern[0] == '^') {
        return regexMatchAt(pattern[1..], str, 0);
    }
    // Otherwise, try matching at every position
    var i: usize = 0;
    while (i <= str.len) : (i += 1) {
        if (regexMatchAt(pattern, str, i)) return true;
    }
    return false;
}

fn regexMatchAt(pattern: []const u8, str: []const u8, start: usize) bool {
    var pi: usize = 0;
    var si: usize = start;

    while (pi < pattern.len) {
        // Check for $ at end of pattern
        if (pattern[pi] == '$' and pi + 1 == pattern.len) {
            return si == str.len;
        }

        // Check for quantifier (* + ?) on next char
        const has_star = pi + 1 < pattern.len and pattern[pi + 1] == '*';
        const has_plus = pi + 1 < pattern.len and pattern[pi + 1] == '+';
        const has_question = pi + 1 < pattern.len and pattern[pi + 1] == '?';

        if (pattern[pi] == '[') {
            // Character class
            const class_end = findClassEnd(pattern, pi);
            if (class_end == 0) return false;
            const class_pattern = pattern[pi .. class_end + 1];
            const advance = class_end + 1;

            const has_star2 = advance < pattern.len and pattern[advance] == '*';
            const has_plus2 = advance < pattern.len and pattern[advance] == '+';
            const has_q2 = advance < pattern.len and pattern[advance] == '?';

            if (has_star2 or has_plus2) {
                const min_count: usize = if (has_plus2) 1 else 0;
                const quant_advance = advance + 1;
                // Greedy: match as many as possible, then backtrack
                var count: usize = 0;
                while (si + count < str.len and matchCharClass(class_pattern, str[si + count])) count += 1;
                while (count >= min_count) : (count -= 1) {
                    if (regexMatchAt(pattern[quant_advance..], str, si + count)) return true;
                    if (count == 0) break;
                }
                return false;
            } else if (has_q2) {
                if (si < str.len and matchCharClass(class_pattern, str[si])) {
                    if (regexMatchAt(pattern[advance + 1 ..], str, si + 1)) return true;
                }
                return regexMatchAt(pattern[advance + 1 ..], str, si);
            } else {
                if (si >= str.len or !matchCharClass(class_pattern, str[si])) return false;
                pi = advance;
                si += 1;
                continue;
            }
        }

        if (pattern[pi] == '\\' and pi + 1 < pattern.len) {
            // Escaped character
            const esc_char = pattern[pi + 1];
            const pat_advance: usize = 2;
            const has_star3 = pi + 2 < pattern.len and pattern[pi + 2] == '*';
            const has_plus3 = pi + 2 < pattern.len and pattern[pi + 2] == '+';

            if (has_star3 or has_plus3) {
                const min_count: usize = if (has_plus3) 1 else 0;
                var count: usize = 0;
                while (si + count < str.len and str[si + count] == esc_char) count += 1;
                while (count >= min_count) : (count -= 1) {
                    if (regexMatchAt(pattern[pat_advance + 1 ..], str, si + count)) return true;
                    if (count == 0) break;
                }
                return false;
            }
            if (si >= str.len or str[si] != esc_char) return false;
            pi += 2;
            si += 1;
            continue;
        }

        if (pattern[pi] == '.' and (has_star or has_plus)) {
            // .* or .+
            const min_count: usize = if (has_plus) 1 else 0;
            var count: usize = str.len - si;
            while (count >= min_count) : (count -= 1) {
                if (regexMatchAt(pattern[pi + 2 ..], str, si + count)) return true;
                if (count == 0) break;
            }
            return false;
        }
        if (pattern[pi] == '.' and has_question) {
            if (si < str.len) {
                if (regexMatchAt(pattern[pi + 2 ..], str, si + 1)) return true;
            }
            return regexMatchAt(pattern[pi + 2 ..], str, si);
        }
        if (pattern[pi] == '.') {
            if (si >= str.len) return false;
            pi += 1;
            si += 1;
            continue;
        }

        // Literal character with quantifier
        if (has_star or has_plus) {
            const ch = pattern[pi];
            const min_count: usize = if (has_plus) 1 else 0;
            var count: usize = 0;
            while (si + count < str.len and str[si + count] == ch) count += 1;
            while (count >= min_count) : (count -= 1) {
                if (regexMatchAt(pattern[pi + 2 ..], str, si + count)) return true;
                if (count == 0) break;
            }
            return false;
        }
        if (has_question) {
            if (si < str.len and str[si] == pattern[pi]) {
                if (regexMatchAt(pattern[pi + 2 ..], str, si + 1)) return true;
            }
            return regexMatchAt(pattern[pi + 2 ..], str, si);
        }

        // Literal match
        if (si >= str.len or str[si] != pattern[pi]) return false;
        pi += 1;
        si += 1;
    }

    return true; // pattern exhausted (no $ anchor means we don't need to be at end of str)
}

fn findClassEnd(pattern: []const u8, start: usize) usize {
    // Find matching ] for character class starting at pattern[start] == '['
    var i = start + 1;
    if (i < pattern.len and pattern[i] == '^') i += 1;
    if (i < pattern.len and pattern[i] == ']') i += 1; // ] as first char in class
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == ']') return i;
    }
    return 0; // no matching ]
}

fn matchCharClass(class: []const u8, ch: u8) bool {
    // class is like "[abc]" or "[^abc]" or "[a-z]" or "[^a-z0-9]"
    if (class.len < 2 or class[0] != '[') return false;
    var negate = false;
    var i: usize = 1;
    if (i < class.len and class[i] == '^') {
        negate = true;
        i += 1;
    }
    var matched = false;
    // Handle ] as first char after [^ or [
    if (i < class.len and class[i] == ']') {
        if (ch == ']') matched = true;
        i += 1;
    }
    while (i < class.len and class[i] != ']') {
        if (i + 2 < class.len and class[i + 1] == '-' and class[i + 2] != ']') {
            // Range
            if (ch >= class[i] and ch <= class[i + 2]) matched = true;
            i += 3;
        } else {
            if (ch == class[i]) matched = true;
            i += 1;
        }
    }
    return if (negate) !matched else matched;
}

fn abbreviateHash(hash: []const u8, len: u32) []const u8 {
    if (len >= 40) return hash;
    return hash[0..@min(len, hash.len)];
}

/// Compute the rename pretty-print display: e.g. "a/b/c => c/b/a" or "c/{b/a => d/e}" or "{c/d => d}/e"
/// Mirrors git's pprint_rename() in diff.c
fn renamePrettyPath(from: []const u8, to: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // Match git's pprint_rename algorithm exactly

    // Find common prefix (at directory boundary)
    var pfx_length: usize = 0;
    {
        var i: usize = 0;
        while (i < from.len and i < to.len and from[i] == to[i]) : (i += 1) {
            if (from[i] == '/') pfx_length = i + 1;
        }
    }

    // Find common suffix (at directory boundary)
    // Allow overlap with prefix by 1 char (the shared slash) if prefix > 0
    var sfx_length: usize = 0;
    {
        const pfx_adjust: usize = if (pfx_length > 0) 1 else 0;
        var fi = from.len;
        var ti = to.len;
        while (fi > 0 and ti > 0 and pfx_length <= fi + pfx_adjust and pfx_length <= ti + pfx_adjust) {
            fi -= 1;
            ti -= 1;
            if (from[fi] != to[ti]) break;
            if (from[fi] == '/') sfx_length = from.len - fi;
        }
    }

    // Compute mid lengths (can be 0 or negative -> 0)
    const a_midlen = if (from.len >= pfx_length + sfx_length) from.len - pfx_length - sfx_length else 0;
    const b_midlen = if (to.len >= pfx_length + sfx_length) to.len - pfx_length - sfx_length else 0;

    const from_mid = from[pfx_length .. pfx_length + a_midlen];
    const to_mid = to[pfx_length .. pfx_length + b_midlen];
    const prefix = from[0..pfx_length];
    const suffix = if (sfx_length <= from.len) from[from.len - sfx_length ..] else "";

    if (pfx_length == 0 and sfx_length == 0) {
        return std.fmt.allocPrint(allocator, "{s} => {s}", .{ from, to });
    } else {
        var buf = std.array_list.Managed(u8).init(allocator);
        defer buf.deinit();
        try buf.appendSlice(prefix);
        try buf.append('{');
        try buf.appendSlice(from_mid);
        try buf.appendSlice(" => ");
        try buf.appendSlice(to_mid);
        try buf.append('}');
        try buf.appendSlice(suffix);
        return allocator.dupe(u8, buf.items);
    }
}

fn getDisplayPath(c: FileChange, allocator: std.mem.Allocator) ![]u8 {
    if (c.is_rename) {
        if (c.rename_from) |from| {
            return renamePrettyPath(from, c.path, allocator);
        }
    }
    return allocator.dupe(u8, c.path);
}

fn outputStat(changes: []const FileChange, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    if (changes.len == 0) return;

    // Compute display paths
    var display_paths = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (display_paths.items) |p| allocator.free(p);
        display_paths.deinit();
    }
    var max_path_len: usize = 0;
    for (changes) |c| {
        const dp = try getDisplayPath(c, allocator);
        if (dp.len > max_path_len) max_path_len = dp.len;
        try display_paths.append(dp);
    }

    var total_ins: usize = 0;
    var total_dels: usize = 0;

    for (changes, 0..) |c, idx| {
        total_ins += c.insertions;
        total_dels += c.deletions;
        const total = c.insertions + c.deletions;
        const dp = display_paths.items[idx];
        const pad_len = max_path_len - dp.len;
        const pad = try allocator.alloc(u8, pad_len);
        defer allocator.free(pad);
        @memset(pad, ' ');

        if (c.is_binary) {
            const line = try std.fmt.allocPrint(allocator, " {s}{s} | Bin\n", .{ dp, pad });
            defer allocator.free(line);
            try pi.writeStdout(line);
        } else if (total == 0) {
            const line = try std.fmt.allocPrint(allocator, " {s}{s} | 0\n", .{ dp, pad });
            defer allocator.free(line);
            try pi.writeStdout(line);
        } else {
            const plus = try allocator.alloc(u8, c.insertions);
            defer allocator.free(plus);
            @memset(plus, '+');
            const minus = try allocator.alloc(u8, c.deletions);
            defer allocator.free(minus);
            @memset(minus, '-');
            const line = try std.fmt.allocPrint(allocator, " {s}{s} | {d} {s}{s}\n", .{ dp, pad, total, plus, minus });
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
        if (c.is_unmerged) {
            const line = try std.fmt.allocPrint(allocator, "U\t{s}\n", .{c.path});
            defer allocator.free(line);
            try pi.writeStdout(line);
        } else if (c.is_rename) {
            const from = c.rename_from orelse c.path;
            const line = try std.fmt.allocPrint(allocator, "R{d:0>3}\t{s}\t{s}\n", .{ @as(u32, c.similarity), from, c.path });
            defer allocator.free(line);
            try pi.writeStdout(line);
        } else {
            const status: u8 = if (c.is_new) 'A' else if (c.is_deleted) 'D' else 'M';
            const line = try std.fmt.allocPrint(allocator, "{c}\t{s}\n", .{ status, c.path });
            defer allocator.free(line);
            try pi.writeStdout(line);
        }
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
        if (c.is_unmerged) {
            const line = try std.fmt.allocPrint(allocator, ":{s} {s} {s}{s} {s}{s} U\t{s}\n", .{
                c.old_mode, c.new_mode,
                abbreviateHash(c.old_hash, abbrev_len), actual_ellipsis,
                abbreviateHash(c.new_hash, abbrev_len), actual_ellipsis,
                c.path,
            });
            defer allocator.free(line);
            try pi.writeStdout(line);
            continue;
        }
        const status: u8 = if (c.is_new) 'A' else if (c.is_deleted) 'D' else if (c.is_rename) 'R' else 'M';
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
        if (c.is_rename) {
            if (c.rename_from) |from| {
                const pretty = try renamePrettyPath(from, c.path, allocator);
                defer allocator.free(pretty);
                const line = try std.fmt.allocPrint(allocator, " rename {s} ({d}%)\n", .{ pretty, c.similarity });
                defer allocator.free(line);
                try pi.writeStdout(line);
            }
        } else if (c.is_new) {
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
    const has_ignore = opts.ignore_regex.items.len > 0 or opts.ignore_blank_lines;

    for (changes) |c| {
        // Skip 100% similarity renames (only show header)
        if (c.is_rename and c.similarity == 100) {
            try outputDiffHeader(c, sp, dp, lp, opts, pi, allocator);
            continue;
        }

        if (c.is_binary) {
            const src_p = c.rename_from orelse c.path;
            const header = try std.fmt.allocPrint(allocator, "{s}diff --git {s}{s} {s}{s}\n{s}Binary files {s}{s} and {s}{s} differ\n", .{
                lp, sp, src_p, dp, c.path,
                lp, sp, src_p, dp, c.path,
            });
            defer allocator.free(header);
            try pi.writeStdout(header);
            continue;
        }

        if (has_ignore) {
            // Generate hunks first, filter, then output
            const hunks_text = generateFilteredHunks(c.old_content, c.new_content, opts, allocator) catch "";
            defer if (hunks_text.len > 0) allocator.free(hunks_text);
            if (hunks_text.len == 0) continue; // all hunks filtered out

            try outputDiffHeader(c, sp, dp, lp, opts, pi, allocator);
            if (lp.len > 0) {
                // Prepend line prefix to each line
                var lines_it = std.mem.splitScalar(u8, hunks_text, '\n');
                while (lines_it.next()) |line| {
                    if (line.len > 0) {
                        try pi.writeStdout(lp);
                        try pi.writeStdout(line);
                        try pi.writeStdout("\n");
                    }
                }
            } else {
                try pi.writeStdout(hunks_text);
            }
        } else {
            // Diff header
            try outputDiffHeader(c, sp, dp, lp, opts, pi, allocator);

            // Generate and output hunks
            if (c.old_content.len > 0 or c.new_content.len > 0) {
                const fm = resolveFuncnameMatcher(c.path, allocator);
                try outputDiffHunksWithMatcher(c.old_content, c.new_content, opts.context_lines, lp, pi, allocator, opts.suppress_blank_empty, fm);
            }
        }
    }
}

const FilteredStats = struct {
    has_changes: bool,
    ins: usize,
    dels: usize,
};

/// Get filtered stats for a file (with -I filtering applied)
fn getFilteredStats(c: FileChange, opts: *const DiffOpts, allocator: std.mem.Allocator) FilteredStats {
    if (opts.ignore_regex.items.len == 0 and !opts.ignore_blank_lines) {
        return .{ .has_changes = true, .ins = c.insertions, .dels = c.deletions };
    }
    if (c.is_binary) return .{ .has_changes = true, .ins = c.insertions, .dels = c.deletions };
    if (c.is_new or c.is_deleted) return .{ .has_changes = true, .ins = c.insertions, .dels = c.deletions };

    const hunks = generateFilteredHunks(c.old_content, c.new_content, opts, allocator) catch
        return .{ .has_changes = true, .ins = c.insertions, .dels = c.deletions };
    defer if (hunks.len > 0) allocator.free(hunks);

    if (hunks.len == 0) return .{ .has_changes = false, .ins = 0, .dels = 0 };

    // Count insertions/deletions in filtered hunks
    var ins: usize = 0;
    var dels: usize = 0;
    var lines_it = std.mem.splitScalar(u8, hunks, '\n');
    while (lines_it.next()) |line| {
        if (line.len > 0 and line[0] == '+') ins += 1;
        if (line.len > 0 and line[0] == '-') dels += 1;
    }
    return .{ .has_changes = true, .ins = ins, .dels = dels };
}

/// Generate filtered hunks text (with -I filtering applied). Returns empty string if all hunks filtered.
fn generateFilteredHunks(old_content: []const u8, new_content: []const u8, opts: *const DiffOpts, allocator: std.mem.Allocator) ![]u8 {
    // Generate diff with large context to allow re-splitting after filtering
    const big_ctx: u32 = 10000; // huge context so we get one big hunk
    const diff_output = diff_mod.generateUnifiedDiffWithHashesAndContext(
        old_content, new_content, "placeholder", "0", "0", big_ctx, allocator,
    ) catch return try allocator.dupe(u8, "");
    defer allocator.free(diff_output);

    // Collect all diff lines (skip headers)
    var diff_lines = std.array_list.Managed(DiffLine).init(allocator);
    defer diff_lines.deinit();

    var lines = std.mem.splitScalar(u8, diff_output, '\n');
    var in_hunk = false;
    var old_line: usize = 0;
    var new_line: usize = 0;

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@")) {
            in_hunk = true;
            // Parse hunk header for start positions
            // Format: @@ -old_start,old_count +new_start,new_count @@
            const old_start = parseHunkStart(line, '-') orelse 1;
            const new_start = parseHunkStart(line, '+') orelse 1;
            old_line = old_start;
            new_line = new_start;
            continue;
        }
        if (!in_hunk) continue;
        if (line.len == 0) continue;

        const kind: DiffLineKind = if (line[0] == '+') .add else if (line[0] == '-') .del else .ctx;
        const content = if (line.len > 0) line[1..] else "";
        const ignored = if (kind != .ctx) lineMatchesIgnorePatterns(content, opts) else false;

        try diff_lines.append(.{
            .kind = kind,
            .content = line,
            .old_pos = if (kind != .add) old_line else 0,
            .new_pos = if (kind != .del) new_line else 0,
            .ignored = ignored,
        });

        if (kind == .ctx) { old_line += 1; new_line += 1; }
        if (kind == .del) { old_line += 1; }
        if (kind == .add) { new_line += 1; }
    }

    // Find ranges of non-ignored changes
    var change_indices = std.array_list.Managed(usize).init(allocator);
    defer change_indices.deinit();
    for (diff_lines.items, 0..) |dl, idx| {
        if (dl.kind != .ctx and !dl.ignored) {
            try change_indices.append(idx);
        }
    }

    if (change_indices.items.len == 0) return try allocator.dupe(u8, "");

    // Group changes into hunks with context_lines context
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    const ctx = opts.context_lines;
    var hunk_start: ?usize = null;
    var hunk_end: usize = 0;

    for (change_indices.items) |ci| {
        const this_start = if (ci >= ctx) ci - ctx else 0;
        const this_end = @min(ci + ctx + 1, diff_lines.items.len);

        if (hunk_start == null) {
            hunk_start = this_start;
            hunk_end = this_end;
        } else if (this_start <= hunk_end) {
            // Overlapping or adjacent - merge
            hunk_end = @max(hunk_end, this_end);
        } else {
            // Output previous hunk
            try outputFilteredHunk(diff_lines.items, hunk_start.?, hunk_end, &result);
            hunk_start = this_start;
            hunk_end = this_end;
        }
    }
    // Output last hunk
    if (hunk_start) |hs| {
        try outputFilteredHunk(diff_lines.items, hs, hunk_end, &result);
    }

    if (result.items.len == 0) return try allocator.dupe(u8, "");
    return try result.toOwnedSlice();
}

const DiffLineKind = enum { ctx, add, del };

const DiffLine = struct {
    kind: DiffLineKind,
    content: []const u8,
    old_pos: usize,
    new_pos: usize,
    ignored: bool,
};

fn parseHunkStart(header: []const u8, marker: u8) ?usize {
    var i: usize = 0;
    while (i < header.len) : (i += 1) {
        if (header[i] == marker and i + 1 < header.len) {
            i += 1;
            var num: usize = 0;
            while (i < header.len and header[i] >= '0' and header[i] <= '9') : (i += 1) {
                num = num * 10 + (header[i] - '0');
            }
            return if (num > 0) num else null;
        }
    }
    return null;
}

fn outputFilteredHunk(diff_lines: []const DiffLine, start: usize, end: usize, result: *std.array_list.Managed(u8)) !void {
    // Calculate old and new line ranges
    var old_start: usize = 0;
    var old_count: usize = 0;
    var new_start: usize = 0;
    var new_count: usize = 0;
    var first_old = true;
    var first_new = true;

    for (diff_lines[start..end]) |dl| {
        if (dl.kind == .ctx or dl.kind == .del) {
            if (first_old) { old_start = dl.old_pos; first_old = false; }
            old_count += 1;
        }
        if (dl.kind == .ctx or dl.kind == .add) {
            if (first_new) { new_start = dl.new_pos; first_new = false; }
            new_count += 1;
        }
    }

    if (old_start == 0) old_start = 1;
    if (new_start == 0) new_start = 1;

    // Write hunk header
    const w = result.writer();
    try w.print("@@ -{d},{d} +{d},{d} @@\n", .{ old_start, old_count, new_start, new_count });

    // Write lines
    for (diff_lines[start..end]) |dl| {
        try result.appendSlice(dl.content);
        try result.append('\n');
    }
}

fn lineMatchesIgnorePatterns(content: []const u8, opts: *const DiffOpts) bool {
    // Check --ignore-blank-lines
    if (opts.ignore_blank_lines) {
        var all_space = true;
        for (content) |ch| {
            if (ch != ' ' and ch != '\t' and ch != '\r') {
                all_space = false;
                break;
            }
        }
        if (all_space) return true;
    }

    // Check -I patterns
    for (opts.ignore_regex.items) |pattern| {
        if (simpleRegexMatch(pattern, content)) return true;
    }
    return false;
}

fn outputDiffHeader(c: FileChange, sp: []const u8, dp: []const u8, lp: []const u8, opts: *const DiffOpts, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    const src_path = c.rename_from orelse c.path;

    // diff --git line
    const git_line = try std.fmt.allocPrint(allocator, "{s}diff --git {s}{s} {s}{s}\n", .{ lp, sp, src_path, dp, c.path });
    defer allocator.free(git_line);
    try pi.writeStdout(git_line);

    if (c.is_rename) {
        if (c.similarity == 100) {
            const sim = try std.fmt.allocPrint(allocator, "{s}similarity index 100%\n{s}rename from {s}\n{s}rename to {s}\n", .{
                lp, lp, src_path, lp, c.path,
            });
            defer allocator.free(sim);
            try pi.writeStdout(sim);
        } else {
            const sim = try std.fmt.allocPrint(allocator, "{s}rename from {s}\n{s}rename to {s}\n", .{
                lp, src_path, lp, c.path,
            });
            defer allocator.free(sim);
            try pi.writeStdout(sim);
        }
    } else if (c.is_new) {
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

    // For rename with 100% similarity, skip index and --- +++ lines
    if (c.is_rename and c.similarity == 100) return;

    // index line
    const full = opts.full_index;
    const old_h = if (full) c.old_hash else blk: {
        const git_dir = git_helpers_mod.findGitDirectory(allocator, pi) catch break :blk abbreviateHash(c.old_hash, opts.getAbbrevLen());
        defer allocator.free(git_dir);
        break :blk git_helpers_mod.uniqueAbbrev(allocator, git_dir, c.old_hash, opts.getAbbrevLen());
    };
    const new_h = if (full) c.new_hash else blk: {
        const git_dir = git_helpers_mod.findGitDirectory(allocator, pi) catch break :blk abbreviateHash(c.new_hash, opts.getAbbrevLen());
        defer allocator.free(git_dir);
        break :blk git_helpers_mod.uniqueAbbrev(allocator, git_dir, c.new_hash, opts.getAbbrevLen());
    };

    if (c.is_rename) {
        // For renames with changes, don't show index line but show --- +++
    } else if (c.is_new or c.is_deleted) {
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
        const a_line = try std.fmt.allocPrint(allocator, "{s}--- {s}{s}\n", .{ lp, sp, src_path });
        defer allocator.free(a_line);
        try pi.writeStdout(a_line);
        const b_line = try std.fmt.allocPrint(allocator, "{s}+++ {s}{s}\n", .{ lp, dp, c.path });
        defer allocator.free(b_line);
        try pi.writeStdout(b_line);
    }
}

/// Resolve a funcname matcher for a file path by reading .gitattributes
fn resolveFuncnameMatcher(file_path: []const u8, allocator: std.mem.Allocator) ?diff_mod.FuncnameMatcher {
    // Try to read .gitattributes and find diff= attribute for this file
    const gitattrs_content = std.fs.cwd().readFileAlloc(allocator, ".gitattributes", 256 * 1024) catch return null;
    defer allocator.free(gitattrs_content);

    return resolveFuncnameFromAttrs(gitattrs_content, file_path);
}

/// Parse .gitattributes content and find funcname matcher for a file
fn resolveFuncnameFromAttrs(attrs_content: []const u8, file_path: []const u8) ?diff_mod.FuncnameMatcher {
    // Parse .gitattributes lines in reverse (last match wins)
    var driver_name: ?[]const u8 = null;
    var lines_iter = std.mem.splitScalar(u8, attrs_content, '\n');
    while (lines_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Parse: pattern attr1 attr2 ...
        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
        const pattern = parts.next() orelse continue;

        // Check if pattern matches file_path
        if (!gitattribPatternMatches(pattern, file_path)) continue;

        // Look for diff= attribute
        while (parts.next()) |attr| {
            if (std.mem.startsWith(u8, attr, "diff=")) {
                driver_name = attr[5..];
            }
        }
    }

    if (driver_name) |name| {
        if (userdiff.findDriverByName(name)) |driver| {
            return driver.match_fn;
        }
    }
    return null;
}

/// Simple gitattributes pattern matching
fn gitattribPatternMatches(pattern: []const u8, path: []const u8) bool {
    // Handle patterns like "*.py", "python-*", "*.java"
    const basename = std.fs.path.basename(path);
    return attrGlobMatch(pattern, basename);
}

/// Simple glob matching supporting * and ?
fn attrGlobMatch(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    var star_pi: ?usize = null;
    var star_ni: ?usize = null;

    while (ni < name.len or pi < pattern.len) {
        if (pi < pattern.len) {
            if (pattern[pi] == '*') {
                star_pi = pi;
                star_ni = ni;
                pi += 1;
                continue;
            }
            if (ni < name.len) {
                if (pattern[pi] == '?' or pattern[pi] == name[ni]) {
                    pi += 1;
                    ni += 1;
                    continue;
                }
            }
        }
        // Mismatch - backtrack to star
        if (star_pi) |sp| {
            pi = sp + 1;
            star_ni = star_ni.? + 1;
            ni = star_ni.?;
            if (ni > name.len) return false;
            continue;
        }
        return false;
    }
    return true;
}

fn outputDiffHunks(old_content: []const u8, new_content: []const u8, context_lines: u32, lp: []const u8, pi: *const pm.Platform, allocator: std.mem.Allocator, suppress_blank_empty: bool) !void {
    return outputDiffHunksWithMatcher(old_content, new_content, context_lines, lp, pi, allocator, suppress_blank_empty, null);
}

fn outputDiffHunksWithMatcher(old_content: []const u8, new_content: []const u8, context_lines: u32, lp: []const u8, pi: *const pm.Platform, allocator: std.mem.Allocator, suppress_blank_empty: bool, funcname_matcher: ?diff_mod.FuncnameMatcher) !void {
    // Use the existing diff module to generate the unified diff
    const diff_output = diff_mod.generateUnifiedDiffWithHashesContextAndFuncname(
        old_content, new_content, "placeholder", "0", "0", context_lines, funcname_matcher, allocator,
    ) catch return;
    defer allocator.free(diff_output);

    // Check if old/new content lacks trailing newline
    const old_no_nl = old_content.len > 0 and old_content[old_content.len - 1] != '\n';
    const new_no_nl = new_content.len > 0 and new_content[new_content.len - 1] != '\n';

    // Extract just the hunks (skip the header lines)
    var lines_list = std.array_list.Managed([]const u8).init(allocator);
    defer lines_list.deinit();
    {
        var lines = std.mem.splitScalar(u8, diff_output, '\n');
        var in_hunk = false;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "@@")) {
                in_hunk = true;
            }
            if (in_hunk and line.len > 0) {
                try lines_list.append(line);
            }
        }
    }

    for (lines_list.items) |line| {
        if (lp.len > 0) try pi.writeStdout(lp);
        // When suppress_blank_empty is true, context lines that are just a space
        // should be output as empty lines (no trailing space)
        if (suppress_blank_empty and line.len == 1 and line[0] == ' ') {
            try pi.writeStdout("\n");
        } else {
            try pi.writeStdout(line);
            try pi.writeStdout("\n");
        }

        // After this line, check if we need "\ No newline at end of file"
        if (line.len > 1) {
            const line_text = line[1..]; // skip the +/- / space prefix
            // Check: is this a remove/context line matching the last line of old content (no trailing nl)?
            if ((line[0] == '-' or line[0] == ' ') and old_no_nl) {
                if (contentEndsWithLine(old_content, line_text)) {
                    if (lp.len > 0) try pi.writeStdout(lp);
                    try pi.writeStdout("\\ No newline at end of file\n");
                }
            }
            // Check: is this an add/context line matching the last line of new content (no trailing nl)?
            if ((line[0] == '+' or line[0] == ' ') and new_no_nl) {
                if (contentEndsWithLine(new_content, line_text)) {
                    if (lp.len > 0) try pi.writeStdout(lp);
                    try pi.writeStdout("\\ No newline at end of file\n");
                }
            }
        }
    }
}

/// Check if the content ends with the given line (no trailing newline)
fn contentEndsWithLine(content: []const u8, line_text: []const u8) bool {
    if (content.len < line_text.len) return false;
    // Content should end with exactly line_text (no trailing \n)
    if (!std.mem.endsWith(u8, content, line_text)) return false;
    const before_len = content.len - line_text.len;
    // The character before should be \n or there should be nothing before
    return before_len == 0 or content[before_len - 1] == '\n';
}

fn doCombinedDiff(allocator: std.mem.Allocator, ref_list: []const []const u8, git_path: []const u8, opts: *const DiffOpts, pi: *const pm.Platform) !void {
    // Combined diff: refs[0] is the result, refs[1..] are parents
    // Shows how result differs from each parent
    if (ref_list.len < 2) return;

    // Resolve all trees: first is result, rest are parents
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

    const result_tree = trees.items[0];
    const parent_trees = trees.items[1..];

    // Collect files from all trees
    var result_files = std.StringHashMap(TreeFileInfo).init(allocator);
    defer {
        var it = result_files.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.hash);
            allocator.free(entry.value_ptr.mode);
        }
        result_files.deinit();
    }
    try collectAllTreeFiles(allocator, result_tree, "", git_path, pi, &result_files);

    var parent_file_maps = std.array_list.Managed(std.StringHashMap(TreeFileInfo)).init(allocator);
    defer {
        for (parent_file_maps.items) |*pf| {
            var it = pf.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.hash);
                allocator.free(entry.value_ptr.mode);
            }
            pf.deinit();
        }
        parent_file_maps.deinit();
    }
    for (parent_trees) |pt| {
        var pf = std.StringHashMap(TreeFileInfo).init(allocator);
        try collectAllTreeFiles(allocator, pt, "", git_path, pi, &pf);
        try parent_file_maps.append(pf);
    }

    // Collect all file names
    var all_files = std.StringHashMap(void).init(allocator);
    defer all_files.deinit();
    {
        var it = result_files.keyIterator();
        while (it.next()) |k| all_files.put(k.*, {}) catch {};
    }
    for (parent_file_maps.items) |*pf| {
        var it = pf.keyIterator();
        while (it.next()) |k| all_files.put(k.*, {}) catch {};
    }

    // Sort
    var sorted = std.array_list.Managed([]const u8).init(allocator);
    defer sorted.deinit();
    {
        var fk = all_files.keyIterator();
        while (fk.next()) |k| try sorted.append(k.*);
    }
    std.mem.sort([]const u8, sorted.items, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.cmp);

    const lp = opts.line_prefix;

    for (sorted.items) |fname| {
        const result_info = result_files.get(fname);
        const result_hash = if (result_info) |ri| ri.hash else null;

        // Check if file differs from at least one parent
        var differs_from_any = false;
        for (parent_file_maps.items) |pf| {
            const parent_info = pf.get(fname);
            const parent_hash = if (parent_info) |pp| pp.hash else null;
            if (result_hash == null and parent_hash == null) continue;
            if (result_hash == null or parent_hash == null) { differs_from_any = true; break; }
            if (!std.mem.eql(u8, result_hash.?, parent_hash.?)) { differs_from_any = true; break; }
        }
        if (!differs_from_any) continue;

        // Check if ALL parents differ (only show in combined diff if all parents differ)
        var all_parents_differ = true;
        for (parent_file_maps.items) |pf| {
            const parent_info = pf.get(fname);
            const parent_hash = if (parent_info) |pp| pp.hash else null;
            // Both null means file doesn't exist in either → same
            if (result_hash == null and parent_hash == null) {
                all_parents_differ = false;
                break;
            }
            // Both exist and same hash → same
            if (result_hash != null and parent_hash != null and std.mem.eql(u8, result_hash.?, parent_hash.?)) {
                all_parents_differ = false;
                break;
            }
        }
        if (!all_parents_differ) continue;

        // Load contents
        var parent_contents = std.array_list.Managed([]const u8).init(allocator);
        defer {
            for (parent_contents.items) |c| if (c.len > 0) allocator.free(c);
            parent_contents.deinit();
        }
        var parent_hashes = std.array_list.Managed([]const u8).init(allocator);
        defer parent_hashes.deinit();

        for (parent_file_maps.items) |pf| {
            const pi2 = pf.get(fname);
            if (pi2) |pp| {
                try parent_hashes.append(pp.hash);
                const content = loadBlob(allocator, pp.hash, git_path, pi) catch try allocator.dupe(u8, "");
                try parent_contents.append(content);
            } else {
                try parent_hashes.append("0000000000000000000000000000000000000000");
                try parent_contents.append(try allocator.dupe(u8, ""));
            }
        }

        const result_content = if (result_hash) |rh|
            (loadBlob(allocator, rh, git_path, pi) catch try allocator.dupe(u8, ""))
        else
            try allocator.dupe(u8, "");
        defer allocator.free(result_content);

        // Output header - -c uses "diff --combined", --cc uses "diff --cc"
        const diff_type: []const u8 = if (opts.combined_use_c) "diff --combined" else "diff --cc";
        const header = try std.fmt.allocPrint(allocator, "{s}{s} {s}\n", .{ lp, diff_type, fname });
        defer allocator.free(header);
        try pi.writeStdout(header);

        // Index line
        {
            var idx = std.array_list.Managed(u8).init(allocator);
            defer idx.deinit();
            try idx.appendSlice(lp);
            try idx.appendSlice("index ");
            for (parent_hashes.items, 0..) |ph, j| {
                if (j > 0) try idx.append(',');
                try idx.appendSlice(ph[0..@min(7, ph.len)]);
            }
            try idx.appendSlice("..");
            if (result_hash) |rh| {
                try idx.appendSlice(rh[0..@min(7, rh.len)]);
            } else {
                try idx.appendSlice("0000000");
            }
            try idx.append('\n');
            try pi.writeStdout(idx.items);
        }

        const dash = try std.fmt.allocPrint(allocator, "{s}--- a/{s}\n{s}+++ b/{s}\n", .{ lp, fname, lp, fname });
        defer allocator.free(dash);
        try pi.writeStdout(dash);

        try outputCombinedHunksNew(allocator, parent_contents.items, result_content, lp, pi);
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

// Old combined diff helpers removed - using new LCS-based approach

fn outputCombinedHunksNew(allocator: std.mem.Allocator, parent_contents: []const []const u8, result_content: []const u8, lp: []const u8, pi: *const pm.Platform) !void {
    const num_parents = parent_contents.len;
    if (num_parents == 0) return;

    const result_lines = splitLines(allocator, result_content) catch return;
    defer result_lines.deinit();

    var parent_lines_list = std.array_list.Managed(std.array_list.Managed([]const u8)).init(allocator);
    defer {
        for (parent_lines_list.items) |*pl| pl.deinit();
        parent_lines_list.deinit();
    }
    for (parent_contents) |pc| {
        const pl = splitLines(allocator, pc) catch return;
        try parent_lines_list.append(pl);
    }

    // For each parent, compute LCS with result
    var parent_in_result = std.array_list.Managed([]bool).init(allocator);
    defer {
        for (parent_in_result.items) |pr| allocator.free(pr);
        parent_in_result.deinit();
    }
    var parent_in_parent = std.array_list.Managed([]bool).init(allocator);
    defer {
        for (parent_in_parent.items) |pp| allocator.free(pp);
        parent_in_parent.deinit();
    }

    for (parent_lines_list.items) |parent_lines| {
        const in_result = try allocator.alloc(bool, result_lines.items.len);
        @memset(in_result, false);
        const in_parent = try allocator.alloc(bool, parent_lines.items.len);
        @memset(in_parent, false);
        computeLCS(parent_lines.items, result_lines.items, in_parent, in_result, allocator);
        try parent_in_result.append(in_result);
        try parent_in_parent.append(in_parent);
    }

    // Build combined output line by line
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    var parent_pos = try allocator.alloc(usize, num_parents);
    defer allocator.free(parent_pos);
    @memset(parent_pos, 0);

    for (0..result_lines.items.len) |ri| {
        // Before this result line, output any deleted lines from parents
        for (0..num_parents) |p| {
            while (parent_pos[p] < parent_lines_list.items[p].items.len and
                !parent_in_parent.items[p][parent_pos[p]])
            {
                for (0..num_parents) |pp| {
                    try output.append(if (pp == p) @as(u8, '-') else ' ');
                }
                try output.appendSlice(parent_lines_list.items[p].items[parent_pos[p]]);
                try output.append('\n');
                parent_pos[p] += 1;
            }
        }

        // Output result line with markers
        for (0..num_parents) |p| {
            if (parent_in_result.items[p][ri]) {
                try output.append(' ');
                if (parent_pos[p] < parent_lines_list.items[p].items.len) {
                    parent_pos[p] += 1;
                }
            } else {
                try output.append('+');
            }
        }
        try output.appendSlice(result_lines.items[ri]);
        try output.append('\n');
    }

    // Output remaining deleted lines from parents
    for (0..num_parents) |p| {
        while (parent_pos[p] < parent_lines_list.items[p].items.len) {
            if (!parent_in_parent.items[p][parent_pos[p]]) {
                for (0..num_parents) |pp| {
                    try output.append(if (pp == p) @as(u8, '-') else ' ');
                }
                try output.appendSlice(parent_lines_list.items[p].items[parent_pos[p]]);
                try output.append('\n');
            }
            parent_pos[p] += 1;
        }
    }

    if (output.items.len == 0) return;

    // Output hunk header
    var header = std.array_list.Managed(u8).init(allocator);
    defer header.deinit();
    try header.appendSlice(lp);
    for (0..num_parents + 1) |_| try header.append('@');
    for (0..num_parents) |p| {
        try header.appendSlice(" -");
        const total = parent_lines_list.items[p].items.len;
        try header.writer().print("{d},{d}", .{ if (total > 0) @as(usize, 1) else @as(usize, 0), total });
    }
    try header.appendSlice(" +");
    try header.writer().print("{d},{d}", .{ if (result_lines.items.len > 0) @as(usize, 1) else @as(usize, 0), result_lines.items.len });
    try header.append(' ');
    for (0..num_parents + 1) |_| try header.append('@');
    try header.append('\n');
    try pi.writeStdout(header.items);

    // Output lines with line prefix
    if (lp.len > 0) {
        var lines_it = std.mem.splitScalar(u8, output.items, '\n');
        while (lines_it.next()) |line| {
            if (line.len > 0) {
                try pi.writeStdout(lp);
                try pi.writeStdout(line);
                try pi.writeStdout("\n");
            }
        }
    } else {
        try pi.writeStdout(output.items);
    }
}

fn splitLines(allocator: std.mem.Allocator, content: []const u8) !std.array_list.Managed([]const u8) {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    if (content.len > 0) {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| try lines.append(line);
        if (lines.items.len > 0 and content[content.len - 1] == '\n') _ = lines.pop();
    }
    return lines;
}

fn computeLCS(parent_lines: []const []const u8, result_lines: []const []const u8, in_parent: []bool, in_result: []bool, allocator: std.mem.Allocator) void {
    const n = parent_lines.len;
    const m = result_lines.len;
    if (n == 0 or m == 0) return;

    const dp = allocator.alloc(u16, (n + 1) * (m + 1)) catch return;
    defer allocator.free(dp);
    @memset(dp, 0);

    for (0..n) |i| {
        for (0..m) |j| {
            if (std.mem.eql(u8, parent_lines[i], result_lines[j])) {
                dp[(i + 1) * (m + 1) + (j + 1)] = dp[i * (m + 1) + j] + 1;
            } else {
                const up = dp[i * (m + 1) + (j + 1)];
                const left = dp[(i + 1) * (m + 1) + j];
                dp[(i + 1) * (m + 1) + (j + 1)] = @max(up, left);
            }
        }
    }

    var i: usize = n;
    var j: usize = m;
    while (i > 0 and j > 0) {
        if (std.mem.eql(u8, parent_lines[i - 1], result_lines[j - 1])) {
            in_parent[i - 1] = true;
            in_result[j - 1] = true;
            i -= 1;
            j -= 1;
        } else if (dp[(i - 1) * (m + 1) + j] > dp[i * (m + 1) + (j - 1)]) {
            i -= 1;
        } else {
            j -= 1;
        }
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

    var has_diff = false;
    if (stat_a != null and stat_a.?.kind == .directory and
        stat_b != null and stat_b.?.kind == .directory)
    {
        // Compare directories
        try diffDirectories(allocator, path_a, path_b, opts, pi);
        has_diff = true; // conservative: assume dirs differ
    } else if (stat_a != null and stat_b != null) {
        // Compare two files - check if they differ
        const content_a = std.fs.cwd().readFileAlloc(allocator, path_a, 10 * 1024 * 1024) catch "";
        defer if (content_a.len > 0) allocator.free(content_a);
        const content_b = std.fs.cwd().readFileAlloc(allocator, path_b, 10 * 1024 * 1024) catch "";
        defer if (content_b.len > 0) allocator.free(content_b);
        if (!std.mem.eql(u8, content_a, content_b)) {
            has_diff = true;
        }
        try diffTwoFiles(allocator, path_a, path_b, opts, pi);
    } else {
        // One might be /dev/null or missing
        has_diff = true;
        if (stat_b != null) {
            try diffNewFile(allocator, path_b, opts, pi);
        } else if (stat_a != null) {
            // Deleted file
        }
    }

    // git diff --no-index always exits 1 if there are differences
    if (has_diff) {
        std.process.exit(1);
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

    try outputDiffHunks(content_a, content_b, opts.context_lines, "", pi, allocator, opts.suppress_blank_empty);
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

    // Check for files in tree but not in index (deleted files)
    var index_paths = std.StringHashMap(void).init(allocator);
    defer index_paths.deinit();
    for (index.entries.items) |entry| {
        index_paths.put(entry.path, {}) catch {};
    }

    var tree_it = tree_files.iterator();
    while (tree_it.next()) |entry| {
        const tree_path = entry.key_ptr.*;
        if (index_paths.contains(tree_path)) continue;
        if (pathspecs.len > 0 and !matchPathspec(tree_path, pathspecs)) continue;

        const tree_info = entry.value_ptr.*;
        const old_c = loadBlob(allocator, tree_info.hash, git_path, pi) catch try allocator.dupe(u8, "");
        try changes.append(.{
            .path = try allocator.dupe(u8, tree_path),
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
    }

    // Sort changes by path
    std.mem.sort(FileChange, changes.items, {}, struct {
        fn cmp(_: void, a: FileChange, b: FileChange) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.cmp);

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
    const head_commit = refs.getCurrentCommit(git_path, pi, allocator) catch null;
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

    // Pre-scan: find paths with unmerged (stage > 0) entries
    var unmerged_paths = std.StringHashMap(void).init(allocator);
    defer unmerged_paths.deinit();
    for (index.entries.items) |entry| {
        const stage = (entry.flags >> 12) & 0x3;
        if (stage > 0) {
            const duped = try allocator.dupe(u8, entry.path);
            try unmerged_paths.put(duped, {});
        }
    }

    // Track paths already processed (for handling multiple stage entries)
    var seen_paths = std.StringHashMap(void).init(allocator);
    defer seen_paths.deinit();

    for (index.entries.items) |entry| {
        const stage = (entry.flags >> 12) & 0x3;
        // Skip higher stage entries - they are handled via unmerged_paths
        if (stage > 0) continue;

        if (pathspecs.len > 0 and !matchPathspec(entry.path, pathspecs)) continue;

        // Skip if we already processed this path
        if (seen_paths.contains(entry.path)) continue;
        try seen_paths.put(try allocator.dupe(u8, entry.path), {});

        // For unmerged paths (have any stage > 0 entry), emit a single unmerged change
        if (unmerged_paths.contains(entry.path)) {
            try changes.append(.{
                .path = try allocator.dupe(u8, entry.path),
                .old_hash = try allocator.dupe(u8, "0000000000000000000000000000000000000000"),
                .new_hash = try allocator.dupe(u8, "0000000000000000000000000000000000000000"),
                .old_mode = try allocator.dupe(u8, "100644"),
                .new_mode = try allocator.dupe(u8, "100644"),
                .old_content = try allocator.dupe(u8, ""),
                .new_content = try allocator.dupe(u8, ""),
                .insertions = 0,
                .deletions = 0,
                .is_new = false,
                .is_deleted = false,
                .is_binary = false,
                .is_unmerged = true,
            });
            continue;
        }

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

    // Second pass: add unmerged paths that had no stage 0 entry
    var iter = unmerged_paths.iterator();
    while (iter.next()) |kv| {
        const upath = kv.key_ptr.*;
        if (seen_paths.contains(upath)) continue;
        if (pathspecs.len > 0 and !matchPathspec(upath, pathspecs)) continue;
        try changes.append(.{
            .path = try allocator.dupe(u8, upath),
            .old_hash = try allocator.dupe(u8, "0000000000000000000000000000000000000000"),
            .new_hash = try allocator.dupe(u8, "0000000000000000000000000000000000000000"),
            .old_mode = try allocator.dupe(u8, "100644"),
            .new_mode = try allocator.dupe(u8, "100644"),
            .old_content = try allocator.dupe(u8, ""),
            .new_content = try allocator.dupe(u8, ""),
            .insertions = 0,
            .deletions = 0,
            .is_new = false,
            .is_deleted = false,
            .is_binary = false,
            .is_unmerged = true,
        });
    }

    try outputChanges(changes.items, opts, pi, allocator);
}

fn detectRenames(changes: *std.array_list.Managed(FileChange), allocator: std.mem.Allocator) void {
    // Find added and deleted files
    var deleted_indices = std.array_list.Managed(usize).init(allocator);
    defer deleted_indices.deinit();
    var added_indices = std.array_list.Managed(usize).init(allocator);
    defer added_indices.deinit();

    for (changes.items, 0..) |c, i| {
        if (c.is_deleted and !c.is_rename) deleted_indices.append(i) catch {};
        if (c.is_new and !c.is_rename) added_indices.append(i) catch {};
    }

    // For each added file, find best matching deleted file
    var matched_deleted = std.AutoHashMap(usize, void).init(allocator);
    defer matched_deleted.deinit();
    var rename_pairs = std.array_list.Managed([2]usize).init(allocator);
    defer rename_pairs.deinit();

    for (added_indices.items) |ai| {
        var best_di: ?usize = null;
        var best_sim: u8 = 0;

        for (deleted_indices.items) |di| {
            if (matched_deleted.contains(di)) continue;

            const sim = computeSimilarity(changes.items[di].old_content, changes.items[ai].new_content);
            // Also check basename similarity
            const basename_bonus: u8 = if (sameBasename(changes.items[di].path, changes.items[ai].path)) 10 else 0;
            const total_sim = @min(@as(u16, sim) + basename_bonus, 100);

            if (total_sim > best_sim and total_sim >= 50) {
                best_sim = @intCast(total_sim);
                best_di = di;
            }
        }

        if (best_di) |di| {
            matched_deleted.put(di, {}) catch {};
            rename_pairs.append(.{ di, ai }) catch {};
        }
    }

    // Convert pairs to rename changes
    for (rename_pairs.items) |pair| {
        const di = pair[0];
        const ai = pair[1];

        // Mark deleted as consumed
        changes.items[di].is_deleted = false;
        changes.items[di].is_rename = true; // mark for removal

        // Convert added to rename
        changes.items[ai].is_new = false;
        changes.items[ai].is_rename = true;
        changes.items[ai].rename_from = changes.items[di].path;
        changes.items[ai].old_hash = changes.items[di].old_hash;
        changes.items[ai].old_mode = changes.items[di].old_mode;
        changes.items[ai].old_content = changes.items[di].old_content;

        // Recalculate stats
        const stats = diff_stats.countInsDels(changes.items[ai].old_content, changes.items[ai].new_content);
        changes.items[ai].insertions = stats.ins;
        changes.items[ai].deletions = stats.dels;
        changes.items[ai].similarity = computeSimilarity(changes.items[ai].old_content, changes.items[ai].new_content);
    }

    // Remove consumed deleted entries (iterate backwards to keep indices valid)
    var i: usize = changes.items.len;
    while (i > 0) {
        i -= 1;
        if (changes.items[i].is_rename and changes.items[i].rename_from == null) {
            // This is the old deleted entry marked for removal
            _ = changes.orderedRemove(i);
        }
    }
}

fn computeSimilarity(content1: []const u8, content2: []const u8) u8 {
    if (content1.len == 0 and content2.len == 0) return 100;
    if (content1.len == 0 or content2.len == 0) return 0;

    // Count matching lines
    var lines1 = std.mem.splitScalar(u8, content1, '\n');
    var count1: usize = 0;
    while (lines1.next()) |_| count1 += 1;

    var lines2 = std.mem.splitScalar(u8, content2, '\n');
    var count2: usize = 0;
    while (lines2.next()) |_| count2 += 1;

    // Simple: count lines that appear in both (bag similarity)
    // For better accuracy, we'd use LCS, but this is sufficient for basic rename detection
    var matching: usize = 0;
    var l1_iter = std.mem.splitScalar(u8, content1, '\n');
    while (l1_iter.next()) |line1| {
        var l2_iter = std.mem.splitScalar(u8, content2, '\n');
        while (l2_iter.next()) |line2| {
            if (std.mem.eql(u8, line1, line2)) {
                matching += 1;
                break;
            }
        }
    }

    const total = @max(count1, count2);
    if (total == 0) return 100;
    return @intCast(@min(matching * 100 / total, 100));
}

fn sameBasename(path1: []const u8, path2: []const u8) bool {
    const base1 = if (std.mem.lastIndexOf(u8, path1, "/")) |pos| path1[pos + 1 ..] else path1;
    const base2 = if (std.mem.lastIndexOf(u8, path2, "/")) |pos| path2[pos + 1 ..] else path2;
    return std.mem.eql(u8, base1, base2);
}

fn outputChanges(changes_slice: []const FileChange, opts: *const DiffOpts, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    if (changes_slice.len == 0 and (opts.exit_code or opts.quiet)) return;

    if (opts.quiet and !(opts.exit_code)) return;

    // Apply rename detection if enabled (default on unless --no-renames, or forced with -M)
    var rename_list: ?std.array_list.Managed(FileChange) = null;
    defer if (rename_list) |*rl| rl.deinit();

    const do_renames = !opts.no_renames or opts.find_renames;
    const changes = if (do_renames) blk: {
        rename_list = std.array_list.Managed(FileChange).init(allocator);
        for (changes_slice) |c| rename_list.?.append(c) catch {};
        detectRenames(&rename_list.?, allocator);
        break :blk rename_list.?.items;
    } else changes_slice;

    // Apply break-rewrites: for modified files that are mostly rewritten,
    // report as full delete + insert
    var break_rewrite_list: ?std.array_list.Managed(FileChange) = null;
    defer if (break_rewrite_list) |*brl| brl.deinit();
    const changes2 = if (opts.break_rewrites) blk_br: {
        break_rewrite_list = std.array_list.Managed(FileChange).init(allocator);
        for (changes) |c| {
            var fc = c;
            if (!c.is_new and !c.is_deleted and !c.is_binary and !c.is_unmerged) {
                const old_lines = diff_stats.countLines(c.old_content);
                const new_lines = diff_stats.countLines(c.new_content);
                if (old_lines > 0) {
                    const total = c.insertions + c.deletions;
                    const max_possible = old_lines + new_lines;
                    if (max_possible > 0 and total * 100 / max_possible > 60) {
                        fc.insertions = new_lines;
                        fc.deletions = old_lines;
                    }
                }
            }
            break_rewrite_list.?.append(fc) catch {};
        }
        break :blk_br break_rewrite_list.?.items;
    } else changes;

    const has_ignore = opts.ignore_regex.items.len > 0 or opts.ignore_blank_lines;

    // For -I filtering with non-patch modes, we need to filter changes
    var filtered_changes: ?std.array_list.Managed(FileChange) = null;
    defer if (filtered_changes) |*fc| fc.deinit();

    const effective_changes = if (has_ignore and (opts.output_mode == .raw or opts.output_mode == .name_only or
        opts.output_mode == .name_status or opts.output_mode == .stat or opts.output_mode == .shortstat))
    blk: {
        filtered_changes = std.array_list.Managed(FileChange).init(allocator);
        for (changes2) |c| {
            // Unmerged, deleted, new files always pass through -I filter
            if (c.is_unmerged or c.is_deleted or c.is_new) {
                filtered_changes.?.append(c) catch {};
                continue;
            }
            const filtered = getFilteredStats(c, opts, allocator);
            if (filtered.has_changes) {
                var fc = c;
                fc.insertions = filtered.ins;
                fc.deletions = filtered.dels;
                filtered_changes.?.append(fc) catch {};
            }
        }
        break :blk filtered_changes.?.items;
    } else changes2;

    if (opts.quiet) {
        if (effective_changes.len > 0) std.process.exit(1);
        return;
    }

    switch (opts.output_mode) {
        .stat => {
            try outputStat(effective_changes, pi, allocator);
            if (opts.show_summary) try outputSummary(effective_changes, pi, allocator);
        },
        .shortstat => try outputShortStat(effective_changes, pi, allocator),
        .numstat => try outputNumStat(effective_changes, pi, allocator),
        .name_only => try outputNameOnly(effective_changes, pi, allocator),
        .name_status => try outputNameStatus(effective_changes, pi, allocator),
        .raw => try outputRaw(effective_changes, opts, pi, allocator),
        .summary => try outputSummary(effective_changes, pi, allocator),
        .dirstat => try outputDirStat(effective_changes, pi, allocator),
        .patch => {
            try outputPatch(changes, opts, pi, allocator);
            if (opts.show_summary) try outputSummary(changes, pi, allocator);
        },
        .patch_with_stat => {
            try outputStat(effective_changes, pi, allocator);
            if (opts.show_summary) try outputSummary(effective_changes, pi, allocator);
            try pi.writeStdout("\n");
            try outputPatch(changes, opts, pi, allocator);
        },
        .patch_with_raw => {
            try outputRaw(effective_changes, opts, pi, allocator);
            try pi.writeStdout("\n");
            try outputPatch(changes, opts, pi, allocator);
        },
        .no_patch => {
            if (opts.show_summary) try outputSummary(effective_changes, pi, allocator);
        },
    }

    if (opts.exit_code and effective_changes.len > 0) {
        std.process.exit(1);
    }
}

// ============================================================================
// Log / Show / Format-Patch / Whatchanged commands
// ============================================================================

const LogOpts = struct {
    show_patch: bool = false,
    show_stat: bool = false,
    show_shortstat: bool = false,
    show_summary: bool = false,
    show_raw: bool = false,
    show_notes: bool = true, // notes shown by default in log
    explicit_patch: bool = false,
    explicit_stat: bool = false,
    root: bool = false,
    first_parent: bool = false,
    diff_merges: DiffMergesMode = .default,
    diff_merges_explicit: bool = false, // true if set by command-line to specific mode
    max_count: ?u32 = null,
    skip_count: u32 = 0,
    oneline: bool = false,
    decorate: DecorateMode = .no,
    clear_decorations: bool = false,
    patch_with_stat: bool = false,
    patch_with_raw: bool = false,
    pickaxe_s: ?[]const u8 = null,
    pickaxe_g: ?[]const u8 = null,
    pickaxe_all: bool = false,
    name_only: bool = false,
    name_status: bool = false,
    ignore_regex: std.array_list.Managed([]const u8),
    pathspecs: std.array_list.Managed([]const u8),
    all_refs: bool = false,
    // format-patch specific
    format_patch: bool = false,
    stdout_mode: bool = false,
    numbered: ?bool = null, // null = auto
    no_numbered: bool = false,
    subject_prefix: []const u8 = "PATCH",
    cover_letter: bool = false,
    start_number: usize = 1,
    attach: bool = false,
    inline_mode: bool = false,
    suffix: []const u8 = ".patch",
    numbered_files: bool = false,
    // show-specific
    show_mode: bool = false,
    // whatchanged-specific
    whatchanged_mode: bool = false,
    // commit filtering
    no_merges: bool = false,
    min_parents: ?u32 = null,
    max_parents: ?u32 = null,
    // diff options
    context_lines: u32 = 3,
    full_index: bool = false,
    abbrev: ?u32 = null,
    src_prefix: []const u8 = "a/",
    dst_prefix: []const u8 = "b/",
    no_prefix: bool = false,
    combined_style: CombinedStyle = .none,
    line_prefix: []const u8 = "",
    format_string: ?[]const u8 = null,
    format_is_separator: bool = false,
    walk_reflog: bool = false,
    grep_pattern: ?[]const u8 = null,
    output_encoding: ?[]const u8 = null,
    author_filters: std.array_list.Managed([]const u8) = std.array_list.Managed([]const u8).init(std.heap.page_allocator),
    committer_filters: std.array_list.Managed([]const u8) = std.array_list.Managed([]const u8).init(std.heap.page_allocator),
    grep_filters: std.array_list.Managed([]const u8) = std.array_list.Managed([]const u8).init(std.heap.page_allocator),
    all_match: bool = false,
    fixed_strings: bool = false,
    fixed_strings_explicit: bool = false,
    grep_reflog: bool = false,
    invert_grep: bool = false,
    use_color: bool = false,
    raw_format: bool = false,

    const DiffMergesMode = enum { default, off, on, first_parent, combined, dense_combined, separate };
    const DecorateMode = enum { no, short, full };
    const CombinedStyle = enum { none, c_style, cc_style };
};

/// Get encoding from commit object headers (default UTF-8)
fn getCommitEncoding(data: []const u8) []const u8 {
    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "encoding ")) {
            return line["encoding ".len..];
        }
    }
    return "UTF-8";
}

/// Check if two encoding names refer to the same encoding
fn encodingsMatch(a: []const u8, b: []const u8) bool {
    // Normalize common encoding names
    const na = normalizeEncodingName(a);
    const nb = normalizeEncodingName(b);
    return std.mem.eql(u8, na, nb);
}

fn normalizeEncodingName(name: []const u8) []const u8 {
    // Case-insensitive comparison of common encoding names
    if (std.ascii.eqlIgnoreCase(name, "UTF-8") or std.ascii.eqlIgnoreCase(name, "utf8")) return "UTF-8";
    if (std.ascii.eqlIgnoreCase(name, "ISO-8859-1") or std.ascii.eqlIgnoreCase(name, "latin1") or std.ascii.eqlIgnoreCase(name, "latin-1")) return "ISO-8859-1";
    return name;
}

/// Re-encode message from commit_enc to out_enc for grep matching
fn reencodeForGrep(allocator: std.mem.Allocator, msg: []const u8, commit_enc: []const u8, out_enc: []const u8) ![]const u8 {
    if (encodingsMatch(commit_enc, out_enc)) return msg;
    const norm_commit = normalizeEncodingName(commit_enc);
    const norm_out = normalizeEncodingName(out_enc);
    if (std.mem.eql(u8, norm_commit, "ISO-8859-1") and std.mem.eql(u8, norm_out, "UTF-8")) {
        return latin1ToUtf8(allocator, msg);
    }
    if (std.mem.eql(u8, norm_commit, "UTF-8") and std.mem.eql(u8, norm_out, "ISO-8859-1")) {
        return utf8ToLatin1(allocator, msg);
    }
    return msg; // Can't re-encode, return as-is
}

/// Convert Latin-1 bytes to UTF-8
fn latin1ToUtf8(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    for (input) |byte| {
        if (byte < 0x80) {
            try result.append(byte);
        } else {
            try result.append(0xC0 | (byte >> 6));
            try result.append(0x80 | (byte & 0x3F));
        }
    }
    return result.toOwnedSlice();
}

/// Convert UTF-8 to Latin-1 (codepoints > 255 become '?')
fn utf8ToLatin1(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] < 0x80) {
            try result.append(input[i]);
            i += 1;
        } else if (input[i] & 0xE0 == 0xC0 and i + 1 < input.len) {
            const cp = (@as(u16, input[i] & 0x1F) << 6) | @as(u16, input[i + 1] & 0x3F);
            if (cp <= 0xFF) {
                try result.append(@intCast(cp));
            } else {
                try result.append('?');
            }
            i += 2;
        } else if (input[i] & 0xF0 == 0xE0) {
            try result.append('?');
            i += 3;
        } else if (input[i] & 0xF8 == 0xF0) {
            try result.append('?');
            i += 4;
        } else {
            try result.append('?');
            i += 1;
        }
    }
    return result.toOwnedSlice();
}

fn extractField(data: []const u8, header: []const u8) []const u8 {
    const prefix = header;
    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) break; // end of headers
        if (std.mem.startsWith(u8, line, prefix)) {
            return line[prefix.len..];
        }
    }
    return "";
}

fn stripPersonTimestamp(person: []const u8) []const u8 {
    // "Name <email> timestamp tz" -> "Name <email>"
    // Find the last '>' which ends the email
    if (std.mem.lastIndexOfScalar(u8, person, '>')) |gt| {
        return person[0 .. gt + 1];
    }
    return person;
}

fn logFilterMatch(text: []const u8, pattern: []const u8, fixed: bool) bool {
    if (pattern.len == 0) return true;
    if (text.len == 0) return false;
    if (fixed) {
        return std.mem.indexOf(u8, text, pattern) != null;
    }
    // Handle basic regex anchors
    var pat = pattern;
    var anchor_start = false;
    var anchor_end = false;
    if (pat.len > 0 and pat[0] == '^') {
        anchor_start = true;
        pat = pat[1..];
    }
    if (pat.len > 0 and pat[pat.len - 1] == '$') {
        anchor_end = true;
        pat = pat[0 .. pat.len - 1];
    }
    // Handle \. as literal dot
    // For simplicity, unescape common regex escapes for literal matching
    var unescaped_buf: [512]u8 = undefined;
    var ulen: usize = 0;
    var has_regex_chars = false;
    var pi: usize = 0;
    while (pi < pat.len and ulen < unescaped_buf.len) {
        if (pat[pi] == '\\' and pi + 1 < pat.len) {
            unescaped_buf[ulen] = pat[pi + 1];
            ulen += 1;
            pi += 2;
        } else if (pat[pi] == '.' or pat[pi] == '*' or pat[pi] == '+' or pat[pi] == '?' or pat[pi] == '[' or pat[pi] == '(' or pat[pi] == '|') {
            has_regex_chars = true;
            unescaped_buf[ulen] = pat[pi];
            ulen += 1;
            pi += 1;
        } else {
            unescaped_buf[ulen] = pat[pi];
            ulen += 1;
            pi += 1;
        }
    }
    const search_pat = unescaped_buf[0..ulen];

    // Check each line for matches
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (has_regex_chars) {
            // Simple regex matching with . as wildcard
            if (anchor_start and anchor_end) {
                if (line.len == search_pat.len and simplePatternMatch(line, search_pat)) return true;
            } else if (anchor_start) {
                if (line.len >= search_pat.len and simplePatternMatch(line[0..search_pat.len], search_pat)) return true;
            } else if (anchor_end) {
                if (line.len >= search_pat.len and simplePatternMatch(line[line.len - search_pat.len ..], search_pat)) return true;
            } else {
                // Substring regex match
                if (search_pat.len == 0) return true;
                if (line.len >= search_pat.len) {
                    var si: usize = 0;
                    while (si + search_pat.len <= line.len) : (si += 1) {
                        if (simplePatternMatch(line[si .. si + search_pat.len], search_pat)) return true;
                    }
                }
            }
        } else {
            if (anchor_start and anchor_end) {
                if (std.mem.eql(u8, line, search_pat)) return true;
            } else if (anchor_start) {
                if (std.mem.startsWith(u8, line, search_pat)) return true;
            } else if (anchor_end) {
                if (std.mem.endsWith(u8, line, search_pat)) return true;
            } else {
                if (std.mem.indexOf(u8, line, search_pat) != null) return true;
            }
        }
    }
    return false;
}

/// Simple pattern matching: '.' matches any character, all other chars match literally
fn simplePatternMatch(text: []const u8, pattern: []const u8) bool {
    if (text.len != pattern.len) return false;
    for (text, pattern) |tc, pc| {
        if (pc != '.' and tc != pc) return false;
    }
    return true;
}

fn extractMessage(data: []const u8) []const u8 {
    if (std.mem.indexOf(u8, data, "\n\n")) |pos| {
        return data[pos + 2 ..];
    }
    return "";
}

fn getAllParents(data: []const u8, allocator: std.mem.Allocator) !std.array_list.Managed([]const u8) {
    var parents = std.array_list.Managed([]const u8).init(allocator);
    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "parent ")) {
            try parents.append(line["parent ".len..]);
        }
    }
    return parents;
}

fn getCommitterTimestamp(data: []const u8) i64 {
    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "committer ")) {
            if (std.mem.indexOf(u8, line, "> ")) |gt| {
                const rest = line[gt + 2 ..];
                if (std.mem.indexOf(u8, rest, " ")) |sp| {
                    return std.fmt.parseInt(i64, rest[0..sp], 10) catch 0;
                }
                return std.fmt.parseInt(i64, rest, 10) catch 0;
            }
        }
    }
    return 0;
}

fn parsePersonName(person: []const u8) []const u8 {
    if (std.mem.indexOf(u8, person, " <")) |lt| {
        return person[0..lt];
    }
    return person;
}

fn parsePersonEmail(person: []const u8) []const u8 {
    if (std.mem.indexOf(u8, person, "<")) |lt| {
        if (std.mem.indexOfPos(u8, person, lt, ">")) |gt| {
            return person[lt + 1 .. gt];
        }
    }
    return "unknown";
}

fn formatGitDate(person: []const u8, allocator: std.mem.Allocator) ?[]u8 {
    // Parse "Name <email> timestamp tz" -> formatted date string
    if (std.mem.indexOf(u8, person, "> ")) |gt| {
        const rest = person[gt + 2 ..];
        var sp_iter = std.mem.splitScalar(u8, rest, ' ');
        const ts_str = sp_iter.next() orelse return null;
        const tz_str = sp_iter.next() orelse "+0000";
        const timestamp = std.fmt.parseInt(i64, ts_str, 10) catch return null;

        const tz_sign: i64 = if (tz_str.len > 0 and tz_str[0] == '-') @as(i64, -1) else 1;
        const tz_abs = if (tz_str.len >= 5) tz_str[1..5] else "0000";
        const tz_hours = std.fmt.parseInt(i64, tz_abs[0..2], 10) catch 0;
        const tz_mins = std.fmt.parseInt(i64, tz_abs[2..4], 10) catch 0;
        const tz_offset = tz_sign * (tz_hours * 3600 + tz_mins * 60);
        const adjusted = timestamp + tz_offset;
        const epoch_secs: u64 = if (adjusted >= 0) @intCast(adjusted) else 0;

        const days_since_epoch = @divFloor(epoch_secs, 86400);
        const time_of_day = epoch_secs % 86400;
        const hours = time_of_day / 3600;
        const mins = (time_of_day % 3600) / 60;
        const secs = time_of_day % 60;

        // Day of week
        const dow = (days_since_epoch + 4) % 7; // 0=Sun
        const dow_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        const mon_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

        // Convert days to y/m/d
        var remaining_days = days_since_epoch;
        var year: u64 = 1970;
        while (true) {
            const days_in_year: u64 = if (isLeapYear(year)) 366 else 365;
            if (remaining_days < days_in_year) break;
            remaining_days -= days_in_year;
            year += 1;
        }
        const leap = isLeapYear(year);
        const month_days = if (leap) [_]u64{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 } else [_]u64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var month: usize = 0;
        while (month < 12) {
            if (remaining_days < month_days[month]) break;
            remaining_days -= month_days[month];
            month += 1;
        }
        const day = remaining_days + 1;

        return std.fmt.allocPrint(allocator, "{s} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} {d:0>4} {s}", .{
            dow_names[dow],
            mon_names[month],
            day,
            hours,
            mins,
            secs,
            year,
            tz_str,
        }) catch null;
    }
    return null;
}

fn isLeapYear(y: u64) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

fn formatRfc2822Date(person: []const u8, allocator: std.mem.Allocator) ?[]u8 {
    // Parse "Name <email> timestamp tz" -> "Thu, 1 Jan 1970 00:00:00 +0000"
    if (std.mem.indexOf(u8, person, "> ")) |gt| {
        const rest = person[gt + 2 ..];
        var sp_iter = std.mem.splitScalar(u8, rest, ' ');
        const ts_str = sp_iter.next() orelse return null;
        const tz_str = sp_iter.next() orelse "+0000";
        const timestamp = std.fmt.parseInt(i64, ts_str, 10) catch return null;

        const tz_sign: i64 = if (tz_str.len > 0 and tz_str[0] == '-') @as(i64, -1) else 1;
        const tz_abs = if (tz_str.len >= 5) tz_str[1..5] else "0000";
        const tz_hours = std.fmt.parseInt(i64, tz_abs[0..2], 10) catch 0;
        const tz_mins = std.fmt.parseInt(i64, tz_abs[2..4], 10) catch 0;
        const tz_offset = tz_sign * (tz_hours * 3600 + tz_mins * 60);
        const adjusted = timestamp + tz_offset;
        const epoch_secs: u64 = if (adjusted >= 0) @intCast(adjusted) else 0;

        const days_since_epoch = @divFloor(epoch_secs, 86400);
        const time_of_day = epoch_secs % 86400;
        const hours = time_of_day / 3600;
        const mins = (time_of_day % 3600) / 60;
        const secs = time_of_day % 60;
        const dow = (days_since_epoch + 4) % 7;
        const dow_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        const mon_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        var remaining_days = days_since_epoch;
        var year: u64 = 1970;
        while (true) {
            const diy: u64 = if (isLeapYear(year)) 366 else 365;
            if (remaining_days < diy) break;
            remaining_days -= diy;
            year += 1;
        }
        const leap = isLeapYear(year);
        const md = if (leap) [_]u64{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 } else [_]u64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var month: usize = 0;
        while (month < 12) {
            if (remaining_days < md[month]) break;
            remaining_days -= md[month];
            month += 1;
        }
        const day = remaining_days + 1;

        return std.fmt.allocPrint(allocator, "{s}, {d} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} {s}", .{
            dow_names[dow],
            day,
            mon_names[month],
            year,
            hours,
            mins,
            secs,
            tz_str,
        }) catch null;
    }
    return null;
}

const ReflogInfo = struct {
    selector: []const u8,
    message: []const u8,
    who: []const u8,
};

fn writeFormattedCommit(format: []const u8, hash: []const u8, data: []const u8, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    return writeFormattedCommitInner(format, hash, data, pi, allocator, null, null);
}

fn writeFormattedCommitWithDecorations(format: []const u8, hash: []const u8, data: []const u8, pi: *const pm.Platform, allocator: std.mem.Allocator, decorations: ?*const std.StringHashMap([]const u8)) !void {
    return writeFormattedCommitInner(format, hash, data, pi, allocator, null, decorations);
}

fn writeFormattedCommitWithReflog(format: []const u8, hash: []const u8, data: []const u8, pi: *const pm.Platform, allocator: std.mem.Allocator, reflog_info: *const ReflogInfo) !void {
    return writeFormattedCommitInner(format, hash, data, pi, allocator, reflog_info, null);
}

fn writeFormattedCommitInner(format: []const u8, hash: []const u8, data: []const u8, pi: *const pm.Platform, allocator: std.mem.Allocator, reflog_info: ?*const ReflogInfo, decorations: ?*const std.StringHashMap([]const u8)) !void {
    // Parse commit fields
    var tree_hash: []const u8 = "";
    var parent_hashes_list = std.array_list.Managed([]const u8).init(allocator);
    defer parent_hashes_list.deinit();
    var author_full: []const u8 = "";
    var committer_full: []const u8 = "";
    var subject: []const u8 = "";
    var body_buf = std.array_list.Managed(u8).init(allocator);
    defer body_buf.deinit();
    var raw_message: []const u8 = "";

    if (std.mem.indexOf(u8, data, "\n\n")) |sep_pos| {
        raw_message = data[sep_pos + 2 ..];
    }
    var lines_iter = std.mem.splitSequence(u8, data, "\n");
    var in_body = false;
    var first_body_line = true;
    while (lines_iter.next()) |line| {
        if (in_body) {
            if (first_body_line) {
                subject = line;
                first_body_line = false;
            } else {
                if (body_buf.items.len > 0) body_buf.append('\n') catch {};
                body_buf.appendSlice(line) catch {};
            }
        } else if (line.len == 0) {
            in_body = true;
        } else if (std.mem.startsWith(u8, line, "tree ")) {
            tree_hash = line["tree ".len..];
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            parent_hashes_list.append(line["parent ".len..]) catch {};
        } else if (std.mem.startsWith(u8, line, "author ")) {
            author_full = line["author ".len..];
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            committer_full = line["committer ".len..];
        }
    }

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '%' and i + 1 < format.len) {
            const c = format[i + 1];
            if (c == 'H') {
                try output.appendSlice(hash);
                i += 2;
            } else if (c == 'h') {
                try output.appendSlice(if (hash.len >= 7) hash[0..7] else hash);
                i += 2;
            } else if (c == 'T') {
                try output.appendSlice(tree_hash);
                i += 2;
            } else if (c == 't') {
                try output.appendSlice(if (tree_hash.len >= 7) tree_hash[0..7] else tree_hash);
                i += 2;
            } else if (c == 'P') {
                for (parent_hashes_list.items, 0..) |ph, pi2| {
                    if (pi2 > 0) try output.append(' ');
                    try output.appendSlice(ph);
                }
                i += 2;
            } else if (c == 'p') {
                for (parent_hashes_list.items, 0..) |ph, pi2| {
                    if (pi2 > 0) try output.append(' ');
                    try output.appendSlice(if (ph.len >= 7) ph[0..7] else ph);
                }
                i += 2;
            } else if (c == 's') {
                try output.appendSlice(subject);
                i += 2;
            } else if (c == 'f') {
                // %f = sanitized subject for filename
                for (subject) |ch| {
                    if (std.ascii.isAlphanumeric(ch)) {
                        try output.append(ch);
                    } else {
                        try output.append('-');
                    }
                }
                i += 2;
            } else if (c == 'b') {
                // Body: strip leading blank lines, keep trailing newline
                var body_trimmed = std.mem.trimLeft(u8, body_buf.items, "\n");
                body_trimmed = std.mem.trimRight(u8, body_trimmed, "\n");
                if (body_trimmed.len > 0) {
                    try output.appendSlice(body_trimmed);
                    try output.append('\n');
                }
                i += 2;
            } else if (c == 'B') {
                const trimmed_raw = std.mem.trimRight(u8, raw_message, "\n");
                try output.appendSlice(trimmed_raw);
                try output.append('\n');
                i += 2;
            } else if (c == 'n') {
                try output.append('\n');
                i += 2;
            } else if (c == '%') {
                try output.append('%');
                i += 2;
            } else if (c == 'a' and i + 2 < format.len) {
                const spec = format[i + 2];
                if (spec == 'n') {
                    try output.appendSlice(parsePersonName(author_full));
                } else if (spec == 'e' or spec == 'E') {
                    try output.appendSlice(parsePersonEmail(author_full));
                } else if (spec == 'd' or spec == 'D' or spec == 'i' or spec == 'I') {
                    const date_str = formatGitDate(author_full, allocator);
                    defer if (date_str) |d| allocator.free(d);
                    if (date_str) |d| try output.appendSlice(d);
                } else {
                    try output.appendSlice(author_full);
                }
                i += 3;
            } else if (c == 'c' and i + 2 < format.len) {
                const spec = format[i + 2];
                if (spec == 'n') {
                    try output.appendSlice(parsePersonName(committer_full));
                } else if (spec == 'e' or spec == 'E') {
                    try output.appendSlice(parsePersonEmail(committer_full));
                } else if (spec == 'd' or spec == 'D' or spec == 'i' or spec == 'I') {
                    const date_str = formatGitDate(committer_full, allocator);
                    defer if (date_str) |d| allocator.free(d);
                    if (date_str) |d| try output.appendSlice(d);
                } else {
                    try output.appendSlice(committer_full);
                }
                i += 3;
            } else if (c == 'd') {
                // %d = decorations with wrapping: " (ref1, ref2)"
                if (decorations) |decor_map| {
                    if (decor_map.get(hash)) |decor_str| {
                        try output.appendSlice(" (");
                        try output.appendSlice(decor_str);
                        try output.append(')');
                    }
                }
                i += 2;
            } else if (c == 'D') {
                // %D = decorations without wrapping parentheses
                if (decorations) |decor_map| {
                    if (decor_map.get(hash)) |decor_str| {
                        try output.appendSlice(decor_str);
                    }
                }
                i += 2;
            } else if (c == 'g' and i + 2 < format.len) {
                const gc = format[i + 2];
                if (gc == 's') {
                    // %gs = reflog subject
                    if (reflog_info) |ri| try output.appendSlice(ri.message);
                } else if (gc == 'd') {
                    // %gd = reflog selector (short)
                    if (reflog_info) |ri| try output.appendSlice(ri.selector);
                } else if (gc == 'D') {
                    // %gD = reflog selector (full)
                    if (reflog_info) |ri| try output.appendSlice(ri.selector);
                } else if (gc == 'n') {
                    // %gn = reflog identity name
                    if (reflog_info) |ri| try output.appendSlice(parsePersonName(ri.who));
                } else if (gc == 'e') {
                    // %ge = reflog identity email
                    if (reflog_info) |ri| try output.appendSlice(parsePersonEmail(ri.who));
                }
                i += 3;
            } else if (c == 'G' and i + 2 < format.len) {
                i += 3;
            } else if (c == 'C' and i + 2 < format.len) {
                if (i + 2 < format.len and format[i + 2] == '(') {
                    var j = i + 3;
                    while (j < format.len and format[j] != ')') : (j += 1) {}
                    i = if (j < format.len) j + 1 else j;
                } else {
                    i += 3;
                }
            } else if (c == 'x' and i + 3 < format.len) {
                const hex_str = format[i + 2 .. i + 4];
                const byte_val = std.fmt.parseInt(u8, hex_str, 16) catch 0;
                try output.append(byte_val);
                i += 4;
            } else if (c == 'w' and i + 2 < format.len and format[i + 2] == '(') {
                // %w() - rewrap, skip
                var j = i + 3;
                while (j < format.len and format[j] != ')') : (j += 1) {}
                i = if (j < format.len) j + 1 else j;
            } else if (c == '(' and i + 2 < format.len) {
                // %(trailers), %(describe), etc - skip
                var j = i + 2;
                while (j < format.len and format[j] != ')') : (j += 1) {}
                i = if (j < format.len) j + 1 else j;
            } else {
                try output.append(format[i]);
                try output.append(format[i + 1]);
                i += 2;
            }
        } else if (format[i] == '\\' and i + 1 < format.len) {
            if (format[i + 1] == 'n') {
                try output.append('\n');
                i += 2;
            } else if (format[i + 1] == 't') {
                try output.append('\t');
                i += 2;
            } else {
                try output.append(format[i]);
                i += 1;
            }
        } else {
            try output.append(format[i]);
            i += 1;
        }
    }

    try pi.writeStdout(output.items);
}

fn writeCommitHeaderWithFrom(hash: []const u8, data: []const u8, from_hash: []const u8, lo: *const LogOpts, pi: *const pm.Platform, allocator: std.mem.Allocator, git_path: []const u8) !void {
    const author = extractField(data, "author ");
    const parents = try getAllParents(data, allocator);
    defer parents.deinit();
    const msg = extractMessage(data);

    // commit line with (from <parent>)
    const commit_line = try std.fmt.allocPrint(allocator, "commit {s} (from {s})\n", .{ hash, from_hash });
    defer allocator.free(commit_line);
    try pi.writeStdout(commit_line);

    // Merge line
    if (parents.items.len > 1) {
        var merge_line = std.array_list.Managed(u8).init(allocator);
        defer merge_line.deinit();
        try merge_line.appendSlice("Merge:");
        for (parents.items) |ph| {
            try merge_line.append(' ');
            try merge_line.appendSlice(ph[0..@min(7, ph.len)]);
        }
        try merge_line.append('\n');
        try pi.writeStdout(merge_line.items);
    }

    // Author
    const name = parsePersonName(author);
    const email = parsePersonEmail(author);
    const author_out = try std.fmt.allocPrint(allocator, "Author: {s} <{s}>\n", .{ name, email });
    defer allocator.free(author_out);
    try pi.writeStdout(author_out);

    // Date
    const date_str = formatGitDate(author, allocator);
    defer if (date_str) |d| allocator.free(d);
    if (date_str) |d| {
        const date_out = try std.fmt.allocPrint(allocator, "Date:   {s}\n", .{d});
        defer allocator.free(date_out);
        try pi.writeStdout(date_out);
    }

    // Blank line before message
    try pi.writeStdout("\n");

    // Message with 4-space indent
    const trimmed_msg = std.mem.trimRight(u8, msg, "\n");
    var msg_iter = std.mem.splitScalar(u8, trimmed_msg, '\n');
    while (msg_iter.next()) |line| {
        const mout = try std.fmt.allocPrint(allocator, "    {s}\n", .{line});
        defer allocator.free(mout);
        try pi.writeStdout(mout);
    }

    _ = lo;
    _ = git_path;
}

fn writeCommitHeader(hash: []const u8, data: []const u8, lo: *const LogOpts, is_last: bool, pi: *const pm.Platform, allocator: std.mem.Allocator, git_path: []const u8) !void {
    _ = is_last;
    const author = extractField(data, "author ");
    const parents = try getAllParents(data, allocator);
    defer parents.deinit();
    const msg = extractMessage(data);

    // Raw format: output commit object headers directly
    if (lo.raw_format) {
        const header_out = try std.fmt.allocPrint(allocator, "commit {s}\n", .{hash});
        defer allocator.free(header_out);
        try pi.writeStdout(header_out);
        // Output the raw commit data (everything before the empty line + the empty line)
        var raw_iter = std.mem.splitScalar(u8, data, '\n');
        while (raw_iter.next()) |line| {
            if (line.len == 0) {
                try pi.writeStdout("\n");
                break;
            }
            const lo2 = try std.fmt.allocPrint(allocator, "{s}\n", .{line});
            defer allocator.free(lo2);
            try pi.writeStdout(lo2);
        }
        // Output message with 4-space indent
        const trimmed_msg = std.mem.trimRight(u8, msg, "\n");
        var msg_iter = std.mem.splitScalar(u8, trimmed_msg, '\n');
        while (msg_iter.next()) |mline| {
            const mout = try std.fmt.allocPrint(allocator, "    {s}\n", .{mline});
            defer allocator.free(mout);
            try pi.writeStdout(mout);
        }
        try pi.writeStdout("\n");
        return;
    }

    // commit line
    var commit_line = std.array_list.Managed(u8).init(allocator);
    defer commit_line.deinit();
    if (lo.use_color) try commit_line.appendSlice("\x1b[33m");
    try commit_line.appendSlice("commit ");
    try commit_line.appendSlice(hash);

    // Decoration
    if (lo.decorate != .no) {
        const decos = getDecorations(hash, git_path, lo, pi, allocator) catch null;
        if (decos) |d| {
            defer allocator.free(d);
            if (d.len > 0) {
                try commit_line.appendSlice(" (");
                try commit_line.appendSlice(d);
                try commit_line.append(')');
            }
        }
    }
    if (lo.use_color) try commit_line.appendSlice("\x1b[m");
    try commit_line.append('\n');
    try pi.writeStdout(commit_line.items);

    // Merge line
    if (parents.items.len > 1) {
        var merge_line = std.array_list.Managed(u8).init(allocator);
        defer merge_line.deinit();
        try merge_line.appendSlice("Merge:");
        for (parents.items) |ph| {
            try merge_line.append(' ');
            try merge_line.appendSlice(ph[0..@min(7, ph.len)]);
        }
        try merge_line.append('\n');
        try pi.writeStdout(merge_line.items);
    }

    // Author
    const name = parsePersonName(author);
    const email = parsePersonEmail(author);
    const author_out = try std.fmt.allocPrint(allocator, "Author: {s} <{s}>\n", .{ name, email });
    defer allocator.free(author_out);
    try pi.writeStdout(author_out);

    // Date
    const date_str = formatGitDate(author, allocator);
    defer if (date_str) |d| allocator.free(d);
    if (date_str) |d| {
        const date_out = try std.fmt.allocPrint(allocator, "Date:   {s}\n", .{d});
        defer allocator.free(date_out);
        try pi.writeStdout(date_out);
    }

    // Blank line before message
    try pi.writeStdout("\n");

    // Message with 4-space indent
    const trimmed = std.mem.trimRight(u8, msg, "\n");
    var msg_iter = std.mem.splitScalar(u8, trimmed, '\n');
    while (msg_iter.next()) |line| {
        const indented = try std.fmt.allocPrint(allocator, "    {s}\n", .{line});
        defer allocator.free(indented);
        try pi.writeStdout(indented);
    }

    // Notes
    if (lo.show_notes) {
        const note = getNoteForCommit(hash, git_path, pi, allocator) catch null;
        if (note) |n| {
            defer allocator.free(n);
            if (n.len > 0) {
                try pi.writeStdout("\nNotes:\n");
                var note_iter = std.mem.splitScalar(u8, std.mem.trimRight(u8, n, "\n"), '\n');
                while (note_iter.next()) |nline| {
                    const nout = try std.fmt.allocPrint(allocator, "    {s}\n", .{nline});
                    defer allocator.free(nout);
                    try pi.writeStdout(nout);
                }
            }
        }
    }
}

fn getNoteForCommit(hash: []const u8, git_path: []const u8, pi: *const pm.Platform, allocator: std.mem.Allocator) !?[]u8 {
    // Read refs/notes/commits to find the note tree
    const notes_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/notes/commits", .{git_path});
    defer allocator.free(notes_ref_path);
    const notes_ref = std.fs.cwd().readFileAlloc(allocator, notes_ref_path, 256) catch return null;
    defer allocator.free(notes_ref);
    const notes_hash = std.mem.trimRight(u8, notes_ref, "\n \r");
    if (notes_hash.len < 40) return null;

    // Load the notes commit and get its tree
    const notes_obj = objects.GitObject.load(notes_hash, git_path, pi, allocator) catch return null;
    defer notes_obj.deinit(allocator);
    const notes_tree_hash = extractField(notes_obj.data, "tree ");
    if (notes_tree_hash.len == 0) return null;

    // Load the tree
    const tree_obj = objects.GitObject.load(notes_tree_hash, git_path, pi, allocator) catch return null;
    defer tree_obj.deinit(allocator);
    const tree_entries = tree_mod.parseTree(tree_obj.data, allocator) catch return null;
    defer tree_entries.deinit();

    // Look for an entry matching the commit hash (flat layout)
    for (tree_entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, hash)) {
            // Load the blob
            const blob_obj = objects.GitObject.load(entry.hash, git_path, pi, allocator) catch return null;
            defer blob_obj.deinit(allocator);
            return try allocator.dupe(u8, blob_obj.data);
        }
    }

    // Try fanned-out layout: look for a subtree named hash[0..2]
    if (hash.len >= 3) {
        const prefix = hash[0..2];
        const rest = hash[2..];
        for (tree_entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, prefix)) {
                // Load the subtree
                const sub_obj = objects.GitObject.load(entry.hash, git_path, pi, allocator) catch return null;
                defer sub_obj.deinit(allocator);
                const sub_entries = tree_mod.parseTree(sub_obj.data, allocator) catch return null;
                defer sub_entries.deinit();
                for (sub_entries.items) |sub_entry| {
                    if (std.mem.eql(u8, sub_entry.name, rest)) {
                        const blob_obj = objects.GitObject.load(sub_entry.hash, git_path, pi, allocator) catch return null;
                        defer blob_obj.deinit(allocator);
                        return try allocator.dupe(u8, blob_obj.data);
                    }
                }
                return null;
            }
        }
    }

    return null;
}

fn parseGitDateToTimestamp(date_str: []const u8, allocator: std.mem.Allocator) ?[]u8 {
    // Try parsing as "YYYY-MM-DD HH:MM:SS +ZZZZ" format
    // Returns "timestamp +ZZZZ" or null if already in timestamp format
    if (date_str.len < 10) return null;
    // Check if it starts with a digit that looks like a timestamp already
    if (date_str[0] >= '0' and date_str[0] <= '9') {
        // Could be unix timestamp already, check if it has a dash (date format)
        if (std.mem.indexOf(u8, date_str[0..@min(5, date_str.len)], "-") == null) return null;
    }
    // Try to parse "YYYY-MM-DD HH:MM:SS +ZZZZ"
    if (date_str.len < 19) return null;
    const year = std.fmt.parseInt(i64, date_str[0..4], 10) catch return null;
    if (date_str[4] != '-') return null;
    const month = std.fmt.parseInt(i64, date_str[5..7], 10) catch return null;
    if (date_str[7] != '-') return null;
    const day = std.fmt.parseInt(i64, date_str[8..10], 10) catch return null;
    if (date_str[10] != ' ') return null;
    const hour = std.fmt.parseInt(i64, date_str[11..13], 10) catch return null;
    if (date_str[13] != ':') return null;
    const minute = std.fmt.parseInt(i64, date_str[14..16], 10) catch return null;
    if (date_str[16] != ':') return null;
    const second = std.fmt.parseInt(i64, date_str[17..19], 10) catch return null;

    // Get timezone
    var tz_str: []const u8 = "+0000";
    if (date_str.len > 20) {
        tz_str = std.mem.trim(u8, date_str[19..], " ");
    }

    // Convert to unix timestamp (UTC)
    // Days from epoch to year
    var days: i64 = 0;
    var y: i64 = 1970;
    while (y < year) : (y += 1) {
        days += if (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0)) @as(i64, 366) else @as(i64, 365);
    }
    // Days for months
    const md = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    var m: usize = 0;
    while (m < @as(usize, @intCast(month - 1))) : (m += 1) {
        days += if (m == 1 and leap) @as(i64, 29) else md[m];
    }
    days += day - 1;
    const timestamp = days * 86400 + hour * 3600 + minute * 60 + second;

    return std.fmt.allocPrint(allocator, "{d} {s}", .{ timestamp, tz_str }) catch null;
}

fn getDecorations(hash: []const u8, git_path: []const u8, lo: *const LogOpts, pi: *const pm.Platform, allocator: std.mem.Allocator) ![]u8 {
    var decos = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (decos.items) |d| allocator.free(d);
        decos.deinit();
    }

    // Check HEAD
    const head_content = blk: {
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
        defer allocator.free(head_path);
        break :blk std.fs.cwd().readFileAlloc(allocator, head_path, 4096) catch break :blk null;
    };
    defer if (head_content) |hc| allocator.free(hc);
    const head_trimmed = if (head_content) |hc| std.mem.trimRight(u8, hc, "\n \r") else "";
    var head_ref: ?[]const u8 = null;
    if (std.mem.startsWith(u8, head_trimmed, "ref: ")) {
        head_ref = head_trimmed["ref: ".len..];
    }

    // Check if HEAD points to this commit
    const head_hash = refs.getCurrentCommit(git_path, pi, allocator) catch null;
    defer if (head_hash) |hh| allocator.free(hh);
    var is_head = false;
    if (head_hash) |hh| {
        if (std.mem.eql(u8, hh, hash)) is_head = true;
    }

    // Scan refs/heads/
    const heads_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{git_path});
    defer allocator.free(heads_path);
    if (std.fs.cwd().openDir(heads_path, .{ .iterate = true })) |*dir_handle| {
        var dir = dir_handle.*;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ heads_path, entry.name });
            defer allocator.free(ref_path);
            const ref_hash_raw = std.fs.cwd().readFileAlloc(allocator, ref_path, 256) catch continue;
            defer allocator.free(ref_hash_raw);
            const ref_hash = std.mem.trimRight(u8, ref_hash_raw, "\n \r");
            if (std.mem.eql(u8, ref_hash, hash)) {
                const full_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{entry.name});
                defer allocator.free(full_ref);
                if (lo.decorate == .full) {
                    try decos.append(try allocator.dupe(u8, full_ref));
                } else {
                    try decos.append(try allocator.dupe(u8, entry.name));
                }
            }
        }
    } else |_| {}

    // Scan refs/tags/
    const tags_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_path});
    defer allocator.free(tags_path);
    if (std.fs.cwd().openDir(tags_path, .{ .iterate = true })) |*dir_handle| {
        var dir = dir_handle.*;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tags_path, entry.name });
            defer allocator.free(ref_path);
            const ref_hash_raw = std.fs.cwd().readFileAlloc(allocator, ref_path, 256) catch continue;
            defer allocator.free(ref_hash_raw);
            const ref_hash = std.mem.trimRight(u8, ref_hash_raw, "\n \r");
            if (std.mem.eql(u8, ref_hash, hash)) {
                if (lo.decorate == .full) {
                    const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{entry.name});
                    try decos.append(tag_ref);
                } else {
                    const tag_ref = try std.fmt.allocPrint(allocator, "tag: {s}", .{entry.name});
                    try decos.append(tag_ref);
                }
            }
        }
    } else |_| {}

    // Scan refs/remotes/
    if (!lo.clear_decorations) {
        const remotes_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes", .{git_path});
        defer allocator.free(remotes_path);
        if (std.fs.cwd().openDir(remotes_path, .{ .iterate = true })) |*dir_handle| {
            var dir = dir_handle.*;
            defer dir.close();
            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind == .directory) {
                    const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remotes_path, entry.name });
                    defer allocator.free(sub_path);
                    if (std.fs.cwd().openDir(sub_path, .{ .iterate = true })) |*sub_dir| {
                        var sd = sub_dir.*;
                        defer sd.close();
                        var sub_iter = sd.iterate();
                        while (try sub_iter.next()) |sub_entry| {
                            if (sub_entry.kind != .file) continue;
                            const r_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sub_path, sub_entry.name });
                            defer allocator.free(r_path);
                            const r_hash_raw = std.fs.cwd().readFileAlloc(allocator, r_path, 256) catch continue;
                            defer allocator.free(r_hash_raw);
                            const r_hash = std.mem.trimRight(u8, r_hash_raw, "\n \r");
                            if (std.mem.eql(u8, r_hash, hash)) {
                                if (lo.decorate == .full) {
                                    const rr = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ entry.name, sub_entry.name });
                                    try decos.append(rr);
                                } else {
                                    const rr = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.name, sub_entry.name });
                                    try decos.append(rr);
                                }
                            }
                        }
                    } else |_| {}
                }
            }
        } else |_| {}
    }

    // Scan refs/notes/ (only with --clear-decorations)
    if (lo.clear_decorations) {
        const notes_path = try std.fmt.allocPrint(allocator, "{s}/refs/notes", .{git_path});
        defer allocator.free(notes_path);
        if (std.fs.cwd().openDir(notes_path, .{ .iterate = true })) |*dir_handle| {
            var dir2 = dir_handle.*;
            defer dir2.close();
            var iter2 = dir2.iterate();
            while (try iter2.next()) |entry| {
                if (entry.kind != .file) continue;
                const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ notes_path, entry.name });
                defer allocator.free(ref_path);
                const ref_hash_raw = std.fs.cwd().readFileAlloc(allocator, ref_path, 256) catch continue;
                defer allocator.free(ref_hash_raw);
                const ref_hash = std.mem.trimRight(u8, ref_hash_raw, "\n \r");
                if (std.mem.eql(u8, ref_hash, hash)) {
                    const notes_ref = try std.fmt.allocPrint(allocator, "refs/notes/{s}", .{entry.name});
                    try decos.append(notes_ref);
                }
            }
        } else |_| {}
    }

    // Sort decorations: HEAD first, then branches, then tags, then remotes
    // Actually for git log --decorate, HEAD -> branch comes first
    if (is_head) {
        // Build "HEAD -> branch" if applicable
        var head_deco: []u8 = undefined;
        if (head_ref) |hr| {
            const branch = if (std.mem.startsWith(u8, hr, "refs/heads/")) hr["refs/heads/".len..] else hr;
            if (lo.decorate == .full) {
                head_deco = try std.fmt.allocPrint(allocator, "HEAD -> {s}", .{hr});
            } else {
                head_deco = try std.fmt.allocPrint(allocator, "HEAD -> {s}", .{branch});
            }
            // Remove the branch from decos if present
            var i: usize = 0;
            while (i < decos.items.len) {
                if (std.mem.eql(u8, decos.items[i], branch) or std.mem.eql(u8, decos.items[i], hr)) {
                    allocator.free(decos.items[i]);
                    _ = decos.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        } else {
            head_deco = try allocator.dupe(u8, "HEAD");
        }
        try decos.insert(0, head_deco);
    }

    // Join with ", "
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    for (decos.items, 0..) |d, i| {
        if (i > 0) try result.appendSlice(", ");
        try result.appendSlice(d);
    }
    return try allocator.dupe(u8, result.items);
}

fn commitMatchesPickaxe(data: []const u8, parent_hash: ?[]const u8, git_path: []const u8, search: []const u8, is_regex: bool, allocator: std.mem.Allocator, pi: *const pm.Platform) bool {
    _ = is_regex;
    // Check if the commit introduces or removes the search string
    const tree_hash = extractField(data, "tree ");
    if (tree_hash.len == 0) return false;

    // Get parent tree
    var parent_tree: []const u8 = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"; // empty tree
    var parent_tree_alloc: ?[]u8 = null;
    defer if (parent_tree_alloc) |a| allocator.free(a);
    if (parent_hash) |ph| {
        const pobj = objects.GitObject.load(ph, git_path, pi, allocator) catch return false;
        defer pobj.deinit(allocator);
        const pt = extractField(pobj.data, "tree ");
        if (pt.len > 0) {
            parent_tree_alloc = allocator.dupe(u8, pt) catch return false;
            parent_tree = parent_tree_alloc.?;
        }
    }

    // Compare trees - look for files that changed and contain the search string
    var changes = std.array_list.Managed(FileChange).init(allocator);
    defer {
        for (changes.items) |*c| freeChange(allocator, c);
        changes.deinit();
    }
    collectTreeChanges(allocator, parent_tree, tree_hash, "", git_path, &.{}, pi, &changes) catch return false;

    for (changes.items) |c| {
        // -S: count occurrences in old vs new, show if count changed
        const old_count = countOccurrences(c.old_content, search);
        const new_count = countOccurrences(c.new_content, search);
        if (old_count != new_count) return true;
    }
    return false;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var pos: usize = 0;
    while (pos + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[pos .. pos + needle.len], needle)) {
            count += 1;
            pos += needle.len;
        } else {
            pos += 1;
        }
    }
    return count;
}

fn writeDiffForCommit(hash: []const u8, data: []const u8, parent_hash: ?[]const u8, lo: *const LogOpts, git_path: []const u8, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    const tree_hash = extractField(data, "tree ");
    if (tree_hash.len == 0) return;

    var p_tree: []const u8 = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
    var p_tree_alloc: ?[]u8 = null;
    defer if (p_tree_alloc) |a| allocator.free(a);
    _ = hash;
    if (parent_hash) |ph| {
        const pobj = objects.GitObject.load(ph, git_path, pi, allocator) catch return;
        defer pobj.deinit(allocator);
        const pt = extractField(pobj.data, "tree ");
        if (pt.len > 0) {
            p_tree_alloc = allocator.dupe(u8, pt) catch return;
            p_tree = p_tree_alloc.?;
        }
    } else if (!lo.root and !lo.show_mode) {
        return; // No parent and --root not specified = no diff for initial commit
    } else if (lo.show_mode and !lo.root) {
        // Check log.showroot config
        const cfg_gp = git_helpers_mod.findGitDirectory(allocator, pi) catch null;
        defer if (cfg_gp) |gp| allocator.free(gp);
        if (cfg_gp) |gp| {
            const cfg_p = std.fmt.allocPrint(allocator, "{s}/config", .{gp}) catch null;
            defer if (cfg_p) |cp| allocator.free(cp);
            if (cfg_p) |cp| {
                if (std.fs.cwd().readFileAlloc(allocator, cp, 1024 * 1024)) |cfg_content| {
                    defer allocator.free(cfg_content);
                    if (getConfigValue(cfg_content, "log", "showroot")) |val| {
                        if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "0")) {
                            return; // log.showroot=false, skip root diff in show mode
                        }
                    }
                } else |_| {}
            }
        }
    }

    var changes = std.array_list.Managed(FileChange).init(allocator);
    defer {
        for (changes.items) |*c| freeChange(allocator, c);
        changes.deinit();
    }
    collectTreeChanges(allocator, p_tree, tree_hash, "", git_path, lo.pathspecs.items, pi, &changes) catch return;

    if (changes.items.len == 0) return;

    // Pickaxe file filtering: only show files where the search string appears
    if (!lo.pickaxe_all) {
        if (lo.pickaxe_s) |search| {
            var filtered = std.array_list.Managed(FileChange).init(allocator);
            for (changes.items) |*c| {
                if (fileChangeContainsString(c, search)) {
                    filtered.append(c.*) catch continue;
                    c.old_content = "";
                    c.new_content = ""; // prevent double-free of content
                } else {
                    freeChange(allocator, c);
                }
            }
            changes.deinit();
            changes = filtered;
        } else if (lo.pickaxe_g) |search| {
            var filtered = std.array_list.Managed(FileChange).init(allocator);
            for (changes.items) |*c| {
                if (fileChangeMatchesGrep(c, search)) {
                    filtered.append(c.*) catch continue;
                    c.old_content = "";
                    c.new_content = ""; // prevent double-free of content
                } else {
                    freeChange(allocator, c);
                }
            }
            changes.deinit();
            changes = filtered;
        }
    }

    if (changes.items.len == 0) return;

    var diff_opts = DiffOpts{
        .ignore_regex = std.array_list.Managed([]const u8).init(allocator),
        .context_lines = lo.context_lines,
        .full_index = lo.full_index,
        .line_prefix = lo.line_prefix,
    };
    defer diff_opts.ignore_regex.deinit();
    if (lo.abbrev) |a| diff_opts.abbrev = a;
    if (lo.no_prefix) {
        diff_opts.no_prefix = true;
    }
    for (lo.ignore_regex.items) |pat| {
        try diff_opts.ignore_regex.append(pat);
    }

    if (lo.patch_with_stat) {
        try pi.writeStdout("---\n");
        try outputStat(changes.items, pi, allocator);
        if (lo.show_summary) try outputSummary(changes.items, pi, allocator);
        try pi.writeStdout("\n");
        try outputPatch(changes.items, &diff_opts, pi, allocator);
    } else if (lo.patch_with_raw) {
        try outputRaw(changes.items, &diff_opts, pi, allocator);
        try pi.writeStdout("\n");
        try outputPatch(changes.items, &diff_opts, pi, allocator);
    } else {
        if (lo.show_stat) {
            try outputStat(changes.items, pi, allocator);
        }
        if (lo.show_raw) {
            try outputRaw(changes.items, &diff_opts, pi, allocator);
        }
        if (lo.show_patch) {
            try outputPatch(changes.items, &diff_opts, pi, allocator);
        }
        if (lo.show_summary) {
            try outputSummary(changes.items, pi, allocator);
        }
        if (lo.name_only) {
            try outputNameOnly(changes.items, pi, allocator);
        }
        if (lo.name_status) {
            try outputNameStatus(changes.items, pi, allocator);
        }
    }
}

const CommitEntry = struct {
    hash: []const u8,
    timestamp: i64,
    order: u32 = 0,
};

pub fn cmdLog(allocator: std.mem.Allocator, args: *pm.ArgIterator, pi: *const pm.Platform) !void {
    return cmdLogInner(allocator, args, pi, false, false);
}

pub fn cmdWhatchanged(allocator: std.mem.Allocator, args: *pm.ArgIterator, pi: *const pm.Platform) !void {
    return cmdLogInner(allocator, args, pi, false, true);
}

const RefEntry = struct { hash: []const u8, name: []const u8 };

fn buildDecorationMap(allocator: std.mem.Allocator, git_path: []const u8, pi: *const pm.Platform, map: *std.StringHashMap([]const u8)) !void {
    // Read HEAD
    const head_hash = refs.getCurrentCommit(git_path, pi, allocator) catch null;
    defer if (head_hash) |h| allocator.free(h);
    // Read HEAD symbolic ref
    const head_ref: ?[]u8 = blk: {
        const hp = std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path}) catch break :blk null;
        defer allocator.free(hp);
        const hc = std.fs.cwd().readFileAlloc(allocator, hp, 256) catch break :blk null;
        const ht = std.mem.trimRight(u8, hc, "\n\r ");
        if (std.mem.startsWith(u8, ht, "ref: ")) {
            const result = allocator.dupe(u8, ht[5..]) catch { allocator.free(hc); break :blk null; };
            allocator.free(hc);
            break :blk result;
        }
        allocator.free(hc);
        break :blk null;
    };
    defer if (head_ref) |r| allocator.free(r);

    // Collect all refs: branches, tags, remotes
    var ref_list = std.array_list.Managed(RefEntry).init(allocator);
    defer {
        for (ref_list.items) |r| { allocator.free(r.hash); allocator.free(r.name); }
        ref_list.deinit();
    }
    const ref_dirs = [_]struct { dir: []const u8, prefix: []const u8 }{
        .{ .dir = "refs/heads", .prefix = "" },
        .{ .dir = "refs/tags", .prefix = "tag: " },
        .{ .dir = "refs/remotes", .prefix = "" },
    };
    for (ref_dirs) |rd| {
        const dir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, rd.dir }) catch continue;
        defer allocator.free(dir_path);
        collectRefsFromDir(allocator, dir_path, rd.dir, rd.prefix, &ref_list) catch {};
    }
    // Also read packed-refs
    collectPackedRefs(allocator, git_path, &ref_list) catch {};

    // Build hash -> decoration string map
    for (ref_list.items) |r| {
        const gop = map.getOrPut(try allocator.dupe(u8, r.hash)) catch continue;
        if (gop.found_existing) {
            // Append to existing decoration
            const old = gop.value_ptr.*;
            const new = std.fmt.allocPrint(allocator, "{s}, {s}", .{ old, r.name }) catch continue;
            allocator.free(old);
            gop.value_ptr.* = new;
            allocator.free(gop.key_ptr.*);
            gop.key_ptr.* = try allocator.dupe(u8, r.hash);
        } else {
            gop.value_ptr.* = try allocator.dupe(u8, r.name);
        }
    }

    // Prepend HEAD -> branch to the HEAD commit's decoration
    if (head_hash) |hh| {
        const head_name = blk: {
            if (head_ref) |hr| {
                if (std.mem.startsWith(u8, hr, "refs/heads/")) {
                    break :blk std.fmt.allocPrint(allocator, "HEAD -> {s}", .{hr["refs/heads/".len..]}) catch break :blk try allocator.dupe(u8, "HEAD");
                }
            }
            break :blk try allocator.dupe(u8, "HEAD");
        };
        defer allocator.free(head_name);
        const gop = map.getOrPut(try allocator.dupe(u8, hh)) catch return;
        if (gop.found_existing) {
            const old = gop.value_ptr.*;
            const new = std.fmt.allocPrint(allocator, "{s}, {s}", .{ head_name, old }) catch return;
            allocator.free(old);
            gop.value_ptr.* = new;
            allocator.free(gop.key_ptr.*);
            gop.key_ptr.* = try allocator.dupe(u8, hh);
        } else {
            gop.value_ptr.* = try allocator.dupe(u8, head_name);
        }
    }
}

fn collectRefsFromDir(allocator: std.mem.Allocator, dir_path: []const u8, ref_prefix: []const u8, display_prefix: []const u8, ref_list: anytype) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) {
            const sub_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            defer allocator.free(sub_path);
            const sub_prefix = std.fmt.allocPrint(allocator, "{s}/{s}", .{ ref_prefix, entry.name }) catch continue;
            defer allocator.free(sub_prefix);
            collectRefsFromDir(allocator, sub_path, sub_prefix, display_prefix, ref_list) catch {};
        } else {
            const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            defer allocator.free(full_path);
            const content = std.fs.cwd().readFileAlloc(allocator, full_path, 256) catch continue;
            defer allocator.free(content);
            const hash = std.mem.trimRight(u8, content, "\n\r ");
            if (hash.len < 40) continue;
            const ref_name = std.fmt.allocPrint(allocator, "{s}/{s}", .{ ref_prefix, entry.name }) catch continue;
            const short_name = blk: {
                if (std.mem.startsWith(u8, ref_name, "refs/heads/")) {
                    break :blk std.fmt.allocPrint(allocator, "{s}{s}", .{ display_prefix, ref_name["refs/heads/".len..] }) catch continue;
                } else if (std.mem.startsWith(u8, ref_name, "refs/tags/")) {
                    break :blk std.fmt.allocPrint(allocator, "{s}{s}", .{ display_prefix, ref_name["refs/tags/".len..] }) catch continue;
                } else if (std.mem.startsWith(u8, ref_name, "refs/remotes/")) {
                    break :blk std.fmt.allocPrint(allocator, "{s}{s}", .{ display_prefix, ref_name["refs/remotes/".len..] }) catch continue;
                }
                break :blk try allocator.dupe(u8, ref_name);
            };
            try ref_list.append(.{ .hash = try allocator.dupe(u8, hash[0..40]), .name = short_name });
            allocator.free(ref_name);
        }
    }
}

fn collectPackedRefs(allocator: std.mem.Allocator, git_path: []const u8, ref_list: anytype) !void {
    const packed_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_path});
    defer allocator.free(packed_path);
    const content = std.fs.cwd().readFileAlloc(allocator, packed_path, 10 * 1024 * 1024) catch return;
    defer allocator.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len < 41 or line[0] == '#' or line[0] == '^') continue;
        const hash = line[0..40];
        if (line[40] != ' ') continue;
        const ref_name = line[41..];
        const short_name = blk: {
            if (std.mem.startsWith(u8, ref_name, "refs/heads/")) {
                break :blk try allocator.dupe(u8, ref_name["refs/heads/".len..]);
            } else if (std.mem.startsWith(u8, ref_name, "refs/tags/")) {
                break :blk std.fmt.allocPrint(allocator, "tag: {s}", .{ref_name["refs/tags/".len..]}) catch continue;
            } else if (std.mem.startsWith(u8, ref_name, "refs/remotes/")) {
                break :blk try allocator.dupe(u8, ref_name["refs/remotes/".len..]);
            }
            break :blk try allocator.dupe(u8, ref_name);
        };
        try ref_list.append(.{ .hash = try allocator.dupe(u8, hash), .name = short_name });
    }
}

fn addRefsFromDir(allocator: std.mem.Allocator, dir_path: []const u8, start_hashes: *std.array_list.Managed([]u8), git_path: []const u8) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    // Collect and sort entries for deterministic order
    var names = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit();
    }
    var kinds = std.array_list.Managed(std.fs.Dir.Entry.Kind).init(allocator);
    defer kinds.deinit();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        try names.append(try allocator.dupe(u8, entry.name));
        try kinds.append(entry.kind);
    }
    // Sort by name
    const SortCtx = struct {
        names: [][]u8,
        kinds: []std.fs.Dir.Entry.Kind,
    };
    const ctx = SortCtx{ .names = names.items, .kinds = kinds.items };
    const indices = try allocator.alloc(usize, names.items.len);
    defer allocator.free(indices);
    for (indices, 0..) |*idx, i| idx.* = i;
    std.mem.sort(usize, indices, ctx, struct {
        fn lessThan(c: SortCtx, a: usize, b: usize) bool {
            return std.mem.order(u8, c.names[a], c.names[b]) == .lt;
        }
    }.lessThan);

    for (indices) |ni| {
        const name = names.items[ni];
        const kind = kinds.items[ni];
        const rp = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name }) catch continue;
        defer allocator.free(rp);
        if (kind == .directory) {
            addRefsFromDir(allocator, rp, start_hashes, git_path) catch {};
            continue;
        }
        if (kind != .file) continue;
        const content = std.fs.cwd().readFileAlloc(allocator, rp, 256) catch continue;
        defer allocator.free(content);
        var h = std.mem.trimRight(u8, content, "\n \r");
        // Handle symbolic refs (e.g., ref: refs/remotes/./main)
        if (std.mem.startsWith(u8, h, "ref: ")) {
            const target = h["ref: ".len..];
            const target_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, target }) catch continue;
            defer allocator.free(target_path);
            const target_content = std.fs.cwd().readFileAlloc(allocator, target_path, 256) catch continue;
            defer allocator.free(target_content);
            h = std.mem.trimRight(u8, target_content, "\n \r");
        }
        if (h.len >= 40) {
            var found = false;
            for (start_hashes.items) |existing| {
                if (std.mem.eql(u8, existing, h)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                start_hashes.append(allocator.dupe(u8, h) catch continue) catch {};
            }
        }
    }
}

fn resolveToCommit(allocator: std.mem.Allocator, hash: []const u8, git_path: []const u8) ![]const u8 {
    // If the object is a tag, dereference to the commit
    const pi_null: ?*const pm.Platform = null;
    _ = pi_null;
    // Just return the hash - we'll let the log walker handle non-commit objects
    _ = allocator;
    _ = git_path;
    return hash;
}

pub fn cmdShow(allocator: std.mem.Allocator, args: *pm.ArgIterator, pi: *const pm.Platform) !void {
    return cmdLogInner(allocator, args, pi, true, false);
}

fn cmdLogInner(allocator: std.mem.Allocator, args: *pm.ArgIterator, pi: *const pm.Platform, show_mode: bool, whatchanged_mode: bool) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try pi.writeStderr("log: not supported in freestanding mode\n");
        return;
    }

    var lo = LogOpts{
        .ignore_regex = std.array_list.Managed([]const u8).init(allocator),
        .pathspecs = std.array_list.Managed([]const u8).init(allocator),
        .show_mode = show_mode,
        .whatchanged_mode = whatchanged_mode,
    };
    defer lo.ignore_regex.deinit();
    defer lo.pathspecs.deinit();

    // show defaults to showing patch
    if (show_mode) {
        lo.show_patch = true;
    }
    // whatchanged defaults to showing raw
    if (whatchanged_mode) {
        lo.show_raw = true;
    }

    var committish_list = std.array_list.Managed([]const u8).init(allocator);
    defer committish_list.deinit();
    var seen_dashdash = false;
    // Note: --i-still-use-this is stripped in main_common.zig arg pre-processing
    // so we can't check for it here.

    // Check for -S requiring argument
    var args_list = std.array_list.Managed([]const u8).init(allocator);
    defer args_list.deinit();
    while (args.next()) |arg| {
        try args_list.append(arg);
    }

    var i: usize = 0;
    while (i < args_list.items.len) : (i += 1) {
        const arg = args_list.items[i];
        if (seen_dashdash) {
            try lo.pathspecs.append(arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            seen_dashdash = true;
        } else if (std.mem.eql(u8, arg, "--oneline")) {
            lo.oneline = true;
        } else if (std.mem.eql(u8, arg, "--pretty=oneline") or std.mem.eql(u8, arg, "--pretty=short")) {
            lo.oneline = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--no-patch")) {
            lo.show_patch = false;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch") or std.mem.eql(u8, arg, "-u")) {
            lo.show_patch = true;
            lo.explicit_patch = true;
        } else if (std.mem.eql(u8, arg, "--stat") or std.mem.startsWith(u8, arg, "--stat=")) {
            lo.show_stat = true;
            lo.explicit_stat = true;
        } else if (std.mem.eql(u8, arg, "--shortstat")) {
            lo.show_shortstat = true;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            lo.show_raw = true;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            lo.show_summary = true;
        } else if (std.mem.eql(u8, arg, "--notes") or std.mem.eql(u8, arg, "--show-notes")) {
            lo.show_notes = true;
        } else if (std.mem.eql(u8, arg, "--no-notes")) {
            lo.show_notes = false;
        } else if (std.mem.eql(u8, arg, "--name-only")) {
            lo.name_only = true;
        } else if (std.mem.eql(u8, arg, "--name-status")) {
            lo.name_status = true;
        } else if (std.mem.eql(u8, arg, "--root")) {
            lo.root = true;
        } else if (std.mem.eql(u8, arg, "--first-parent")) {
            lo.first_parent = true;
        } else if (std.mem.eql(u8, arg, "--no-merges")) {
            lo.no_merges = true;
            lo.max_parents = 1;
        } else if (std.mem.eql(u8, arg, "--merges")) {
            lo.min_parents = 2;
        } else if (std.mem.startsWith(u8, arg, "--min-parents=")) {
            lo.min_parents = std.fmt.parseInt(u32, arg["--min-parents=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--max-parents=")) {
            lo.max_parents = std.fmt.parseInt(u32, arg["--max-parents=".len..], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--no-diff-merges") or std.mem.eql(u8, arg, "--diff-merges=off")) {
            lo.diff_merges = .off;
            lo.diff_merges_explicit = true;
        } else if (std.mem.eql(u8, arg, "--diff-merges=on")) {
            // "on" means enable with config or default to separate
            lo.diff_merges = .on;
        } else if (std.mem.eql(u8, arg, "--diff-merges=separate")) {
            lo.diff_merges = .separate;
            lo.diff_merges_explicit = true;
        } else if (std.mem.eql(u8, arg, "--diff-merges=first-parent")) {
            lo.diff_merges = .first_parent;
            lo.diff_merges_explicit = true;
        } else if (std.mem.eql(u8, arg, "--diff-merges=combined") or std.mem.eql(u8, arg, "--diff-merges=c")) {
            lo.diff_merges = .combined;
            lo.diff_merges_explicit = true;
        } else if (std.mem.eql(u8, arg, "--diff-merges=dense-combined") or std.mem.eql(u8, arg, "--diff-merges=cc")) {
            lo.diff_merges = .dense_combined;
            lo.diff_merges_explicit = true;
        } else if (std.mem.eql(u8, arg, "--dd") or std.mem.eql(u8, arg, "--diff-merges=1")) {
            lo.diff_merges = .first_parent;
            lo.diff_merges_explicit = true;
            lo.show_patch = true;
            lo.explicit_patch = true;
        } else if (std.mem.eql(u8, arg, "-m")) {
            // -m means enable separate, but can be overridden by config
            lo.diff_merges = .on;
        } else if (std.mem.eql(u8, arg, "-c")) {
            lo.combined_style = .c_style;
            lo.diff_merges = .combined;
            lo.diff_merges_explicit = true;
        } else if (std.mem.eql(u8, arg, "--cc")) {
            lo.combined_style = .cc_style;
            lo.diff_merges = .dense_combined;
            lo.diff_merges_explicit = true;
        } else if (std.mem.eql(u8, arg, "--patch-with-stat")) {
            lo.patch_with_stat = true;
            lo.show_patch = true;
        } else if (std.mem.eql(u8, arg, "--patch-with-raw")) {
            lo.patch_with_raw = true;
            lo.show_patch = true;
        } else if (std.mem.eql(u8, arg, "--decorate")) {
            lo.decorate = .short;
        } else if (std.mem.eql(u8, arg, "--decorate=short")) {
            lo.decorate = .short;
        } else if (std.mem.eql(u8, arg, "--decorate=full")) {
            lo.decorate = .full;
        } else if (std.mem.eql(u8, arg, "--no-decorate")) {
            lo.decorate = .no;
        } else if (std.mem.eql(u8, arg, "--clear-decorations")) {
            lo.clear_decorations = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            lo.all_refs = true;
        } else if (std.mem.eql(u8, arg, "--no-walk") or std.mem.eql(u8, arg, "--no-walk=sorted") or std.mem.eql(u8, arg, "--no-walk=unsorted")) {
            // Accept
        } else if (std.mem.eql(u8, arg, "--do-walk")) {
            // Accept
        } else if (std.mem.eql(u8, arg, "-S")) {
            if (i + 1 < args_list.items.len) {
                i += 1;
                lo.pickaxe_s = args_list.items[i];
            } else {
                try pi.writeStderr("error: switch `S' requires a value\n");
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "-S")) {
            lo.pickaxe_s = arg[2..];
        } else if (std.mem.startsWith(u8, arg, "-G")) {
            lo.pickaxe_g = arg[2..];
        } else if (std.mem.eql(u8, arg, "--pickaxe-all")) {
            lo.pickaxe_all = true;
        } else if (std.mem.startsWith(u8, arg, "--grep=")) {
            lo.grep_pattern = arg["--grep=".len..];
            try lo.grep_filters.append(arg["--grep=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--author=")) {
            try lo.author_filters.append(arg["--author=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--committer=")) {
            try lo.committer_filters.append(arg["--committer=".len..]);
        } else if (std.mem.eql(u8, arg, "--all-match")) {
            lo.all_match = true;
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings")) {
            lo.fixed_strings = true;
            lo.fixed_strings_explicit = true;
        } else if (std.mem.eql(u8, arg, "-G") or std.mem.eql(u8, arg, "--basic-regexp") or std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--extended-regexp") or std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--perl-regexp")) {
            lo.fixed_strings = false;
            lo.fixed_strings_explicit = true;
        } else if (std.mem.eql(u8, arg, "--grep-reflog") or std.mem.startsWith(u8, arg, "--grep-reflog=")) {
            lo.grep_reflog = true;
        } else if (std.mem.eql(u8, arg, "--invert-grep")) {
            lo.invert_grep = true;
        } else if (std.mem.startsWith(u8, arg, "-I") and arg.len > 2) {
            try lo.ignore_regex.append(arg[2..]);
        } else if (std.mem.startsWith(u8, arg, "--max-count=")) {
            lo.max_count = std.fmt.parseInt(u32, arg["--max-count=".len..], 10) catch null;
        } else if (std.mem.eql(u8, arg, "-n")) {
            if (i + 1 < args_list.items.len) {
                i += 1;
                lo.max_count = std.fmt.parseInt(u32, args_list.items[i], 10) catch null;
            }
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and std.ascii.isDigit(arg[1])) {
            lo.max_count = std.fmt.parseInt(u32, arg[1..], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--no-prefix")) {
            lo.no_prefix = true;
        } else if (std.mem.eql(u8, arg, "--full-index")) {
            lo.full_index = true;
        } else if (std.mem.startsWith(u8, arg, "-U") and arg.len > 2) {
            lo.context_lines = std.fmt.parseInt(u32, arg[2..], 10) catch 3;
        } else if (std.mem.startsWith(u8, arg, "--unified=")) {
            lo.context_lines = std.fmt.parseInt(u32, arg["--unified=".len..], 10) catch 3;
        } else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
            lo.abbrev = std.fmt.parseInt(u32, arg["--abbrev=".len..], 10) catch 7;
        } else if (std.mem.eql(u8, arg, "--abbrev")) {
            lo.abbrev = 7;
        } else if (std.mem.eql(u8, arg, "--no-abbrev")) {
            lo.abbrev = 0;
        } else if (std.mem.startsWith(u8, arg, "--line-prefix=")) {
            lo.line_prefix = arg["--line-prefix=".len..];
        } else if (std.mem.eql(u8, arg, "--i-still-use-this")) {
            // whatchanged deprecation override
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            lo.format_string = arg["--format=".len..];
            lo.format_is_separator = false;
        } else if (std.mem.startsWith(u8, arg, "--pretty=format:")) {
            lo.format_string = arg["--pretty=format:".len..];
            lo.format_is_separator = true;
        } else if (std.mem.startsWith(u8, arg, "--pretty=tformat:")) {
            lo.format_string = arg["--pretty=tformat:".len..];
            lo.format_is_separator = false;
        } else if (std.mem.startsWith(u8, arg, "--pretty=")) {
            const fmt_val = arg["--pretty=".len..];
            if (std.mem.eql(u8, fmt_val, "oneline") or std.mem.eql(u8, fmt_val, "short")) {
                lo.oneline = true;
            } else if (std.mem.eql(u8, fmt_val, "raw")) {
                lo.raw_format = true;
            } else if (std.mem.eql(u8, fmt_val, "medium") or std.mem.eql(u8, fmt_val, "full") or
                std.mem.eql(u8, fmt_val, "fuller") or std.mem.eql(u8, fmt_val, "email") or
                std.mem.eql(u8, fmt_val, "reference") or
                std.mem.eql(u8, fmt_val, "mboxrd")) {
                // Named formats - use default
            } else if (fmt_val.len > 0) {
                lo.format_string = fmt_val;
                lo.format_is_separator = false;
            }
        } else if (std.mem.eql(u8, arg, "--pretty") or std.mem.eql(u8, arg, "--pretty=medium")) {
            // default format
        } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--walk-reflogs")) {
            lo.walk_reflog = true;
        } else if (std.mem.startsWith(u8, arg, "--encoding=")) {
            lo.output_encoding = arg["--encoding=".len..];
        } else if (std.mem.eql(u8, arg, "--color") or std.mem.eql(u8, arg, "--color=always")) {
            lo.use_color = true;
        } else if (std.mem.eql(u8, arg, "--no-color") or std.mem.eql(u8, arg, "--color=never")) {
            lo.use_color = false;
        } else if (std.mem.startsWith(u8, arg, "--color=")) {
            // --color=auto - check GIT_PAGER_IN_USE
            const val = arg["--color=".len..];
            if (std.mem.eql(u8, val, "auto")) {
                if (std.posix.getenv("GIT_PAGER_IN_USE")) |_| lo.use_color = true;
            }
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            lo.show_patch = false;
        } else if (std.mem.eql(u8, arg, "--graph")) {
            try pi.writeStderr("fatal: options '--no-walk' and '--graph' cannot be used together\n");
            std.process.exit(128);
        } else if (std.mem.eql(u8, arg, "--source") or
            std.mem.eql(u8, arg, "--use-mailmap") or std.mem.eql(u8, arg, "--no-mailmap") or
            std.mem.eql(u8, arg, "--no-diff-merges") or
            std.mem.eql(u8, arg, "--expand-tabs") or std.mem.startsWith(u8, arg, "--expand-tabs=") or
            std.mem.eql(u8, arg, "--no-expand-tabs") or
            std.mem.eql(u8, arg, "--no-standard-notes") or std.mem.eql(u8, arg, "--standard-notes") or
            std.mem.eql(u8, arg, "--remerge-diff") or std.mem.eql(u8, arg, "--no-remerge-diff") or
            std.mem.eql(u8, arg, "--follow") or std.mem.eql(u8, arg, "--no-follow") or
            std.mem.startsWith(u8, arg, "--diff-algorithm=") or
            std.mem.startsWith(u8, arg, "--decorate-refs=") or std.mem.startsWith(u8, arg, "--decorate-refs-exclude="))
        {
            // Accept silently
        } else if (std.mem.startsWith(u8, arg, "^") and arg.len > 1) {
            // ^ref means exclude commits reachable from ref
            try committish_list.append(arg);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try committish_list.append(arg);
        }
    }

    // Fix option interactions:
    // In show mode, --stat without explicit -p should disable default patch
    if (show_mode and (lo.explicit_stat or lo.show_raw or lo.show_summary or lo.show_shortstat or lo.name_only or lo.name_status) and !lo.explicit_patch and !lo.patch_with_stat and !lo.patch_with_raw) {
        lo.show_patch = false;
    }
    // In whatchanged mode, -p should replace default raw
    if (whatchanged_mode and lo.explicit_patch and !lo.patch_with_raw) {
        lo.show_raw = false;
    }

    // Auto-detect color: if color.ui=auto and GIT_PAGER_IN_USE is set, enable color
    if (!lo.use_color) {
        const gp_for_color = git_helpers_mod.findGitDirectory(allocator, pi) catch null;
        defer if (gp_for_color) |gpc| allocator.free(gpc);
        if (gp_for_color) |gpc| {
            const color_ui = git_helpers_mod.getConfigValueByKey(gpc, "color.ui", allocator);
            if (color_ui) |val| {
                defer allocator.free(val);
                if (std.ascii.eqlIgnoreCase(val, "auto")) {
                    if (std.posix.getenv("GIT_PAGER_IN_USE")) |_| lo.use_color = true;
                } else if (std.ascii.eqlIgnoreCase(val, "always") or std.ascii.eqlIgnoreCase(val, "true")) {
                    lo.use_color = true;
                }
            }
        }
    }

    // Read log.diffMerges config (check -c overrides first, then config file)
    {
        var dm_config = git_helpers_mod.getConfigOverride("log.diffmerges");
        var dm_config_alloc: ?[]u8 = null;
        defer if (dm_config_alloc) |d| allocator.free(d);
        if (dm_config == null) {
            // Read from git config file
            const cfg_git_path = git_helpers_mod.findGitDirectory(allocator, pi) catch null;
            defer if (cfg_git_path) |gp| allocator.free(gp);
            if (cfg_git_path) |gp| {
                const cfg_path = std.fmt.allocPrint(allocator, "{s}/config", .{gp}) catch null;
                defer if (cfg_path) |cp| allocator.free(cp);
                if (cfg_path) |cp| {
                    if (std.fs.cwd().readFileAlloc(allocator, cp, 1024 * 1024)) |cfg_content| {
                        defer allocator.free(cfg_content);
                        if (getConfigValue(cfg_content, "log", "diffmerges")) |val| {
                            dm_config_alloc = allocator.dupe(u8, val) catch null;
                            dm_config = dm_config_alloc;
                        }
                    } else |_| {}
                }
            }
        }
        if (dm_config) |val| {
            // Parse config value
            var config_mode: ?LogOpts.DiffMergesMode = null;
            if (std.mem.eql(u8, val, "off") or std.mem.eql(u8, val, "none")) {
                config_mode = .off;
            } else if (std.mem.eql(u8, val, "on") or std.mem.eql(u8, val, "separate")) {
                config_mode = .separate;
            } else if (std.mem.eql(u8, val, "first-parent") or std.mem.eql(u8, val, "1")) {
                config_mode = .first_parent;
            } else if (std.mem.eql(u8, val, "combined") or std.mem.eql(u8, val, "c")) {
                config_mode = .combined;
            } else if (std.mem.eql(u8, val, "dense-combined") or std.mem.eql(u8, val, "cc")) {
                config_mode = .dense_combined;
            } else {
                const msg = try std.fmt.allocPrint(allocator, "fatal: unknown value for config 'log.diffMerges': {s}\n", .{val});
                defer allocator.free(msg);
                try pi.writeStderr(msg);
                std.process.exit(128);
            }
            if (config_mode) |cm| {
                // Apply config for default or "on" modes
                if (lo.diff_merges == .default or lo.diff_merges == .on) {
                    lo.diff_merges = cm;
                }
            }
        } else {
            // No config - resolve "on" to "separate"
            if (lo.diff_merges == .on) {
                lo.diff_merges = .separate;
            }
        }
    }

    const git_path = git_helpers_mod.findGitDirectory(allocator, pi) catch {
        try pi.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Resolve starting commits
    var start_hashes = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (start_hashes.items) |h| allocator.free(h);
        start_hashes.deinit();
    }
    var start_ref_names = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (start_ref_names.items) |n| allocator.free(n);
        start_ref_names.deinit();
    }

    // Separate include and exclude refs
    var exclude_hashes = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (exclude_hashes.items) |h| allocator.free(h);
        exclude_hashes.deinit();
    }
    if (committish_list.items.len > 0) {
        for (committish_list.items) |c| {
            if (std.mem.startsWith(u8, c, "^") and c.len > 1) {
                // Exclude ref
                const h = git_helpers_mod.resolveRevision(git_path, c[1..], pi, allocator) catch continue;
                try exclude_hashes.append(h);
            } else if (std.mem.indexOf(u8, c, "..")) |dot_pos| {
                // A..B range: exclude A, include B
                if (dot_pos > 0) {
                    const h = git_helpers_mod.resolveRevision(git_path, c[0..dot_pos], pi, allocator) catch continue;
                    try exclude_hashes.append(h);
                }
                if (dot_pos + 2 < c.len) {
                    const h = git_helpers_mod.resolveRevision(git_path, c[dot_pos + 2..], pi, allocator) catch {
                        const msg = try std.fmt.allocPrint(allocator, "fatal: ambiguous argument '{s}': unknown revision or path not in the working tree.\n", .{c});
                        defer allocator.free(msg);
                        try pi.writeStderr(msg);
                        std.process.exit(128);
                    };
                    try start_hashes.append(h);
                    try start_ref_names.append(try allocator.dupe(u8, c[dot_pos + 2..]));
                }
            } else {
                const h = git_helpers_mod.resolveRevision(git_path, c, pi, allocator) catch {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: ambiguous argument '{s}': unknown revision or path not in the working tree.\n", .{c});
                    defer allocator.free(msg);
                    try pi.writeStderr(msg);
                    std.process.exit(128);
                };
                try start_hashes.append(h);
                try start_ref_names.append(try allocator.dupe(u8, c));
            }
        }
    }
    if (start_hashes.items.len == 0) {
        const head = refs.getCurrentCommit(git_path, pi, allocator) catch null;
        if (head == null) {
            try pi.writeStderr("fatal: your current branch does not have any commits yet\n");
            std.process.exit(128);
        }
        try start_hashes.append(head.?);
        try start_ref_names.append(try allocator.dupe(u8, "HEAD"));
    }

    // If --all, add all refs
    if (lo.all_refs) {
        // Add all refs from refs/heads/, refs/tags/, refs/remotes/, refs/notes/
        const dirs = [_][]const u8{ "refs/heads", "refs/tags", "refs/notes", "refs/remotes" };
        for (dirs) |d| {
            const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, d });
            defer allocator.free(dir_path);
            addRefsFromDir(allocator, dir_path, &start_hashes, git_path) catch {};
            // Ensure ref names list stays in sync
            while (start_ref_names.items.len < start_hashes.items.len) {
                try start_ref_names.append(try allocator.dupe(u8, start_hashes.items[start_ref_names.items.len]));
            }
        }
    }

    // Read grep.patternType from config (overridden by -F/-E/-G/-P flags)
    if (!lo.fixed_strings_explicit) {
        if (git_helpers_mod.getConfigValueByKey(git_path, "grep.patterntype", allocator)) |pt_val| {
            if (std.ascii.eqlIgnoreCase(pt_val, "fixed")) {
                lo.fixed_strings = true;
            }
            allocator.free(pt_val);
        }
    }

    // Build decoration map (hash -> "HEAD -> main, tag: v1.0, origin/main")
    var decoration_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        var dit = decoration_map.iterator();
        while (dit.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        decoration_map.deinit();
    }
    if (lo.format_string != null or lo.decorate != .no) {
        try buildDecorationMap(allocator, git_path, pi, &decoration_map);
    }

    // Validate --grep-reflog can only be used with -g
    if (lo.grep_reflog and !lo.walk_reflog) {
        try pi.writeStderr("fatal: --grep-reflog can only be used under -g\n");
        std.process.exit(1);
    }

    // Reflog walking mode (-g / --walk-reflogs)
    if (lo.walk_reflog) {
        const ref_name = if (committish_list.items.len > 0) committish_list.items[0] else "HEAD";
        // Build reflog path - check refs/heads/ first for branch names
        var reflog_content: ?[]u8 = null;
        var reflog_path2: ?[]u8 = null;
        defer if (reflog_path2) |p2| allocator.free(p2);
        if (!std.mem.eql(u8, ref_name, "HEAD") and !std.mem.startsWith(u8, ref_name, "refs/")) {
            reflog_path2 = try std.fmt.allocPrint(allocator, "{s}/logs/refs/heads/{s}", .{ git_path, ref_name });
            reflog_content = pi.fs.readFile(allocator, reflog_path2.?) catch null;
        }
        const reflog_path = try std.fmt.allocPrint(allocator, "{s}/logs/{s}", .{ git_path, ref_name });
        defer allocator.free(reflog_path);
        if (reflog_content == null) {
            reflog_content = pi.fs.readFile(allocator, reflog_path) catch null;
        }
        if (reflog_content) |content| {
            defer allocator.free(content);
            const ReflogEntry = struct {
                old_hash: []u8,
                new_hash: []u8,
                who: []u8,
                message: []u8,
            };
            var reflog_entries = std.array_list.Managed(ReflogEntry).init(allocator);
            defer {
                for (reflog_entries.items) |*e| {
                    allocator.free(e.old_hash);
                    allocator.free(e.new_hash);
                    allocator.free(e.who);
                    allocator.free(e.message);
                }
                reflog_entries.deinit();
            }
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                if (line.len < 82) continue;
                const old_h = line[0..40];
                const new_h = line[41..81];
                const rest = line[82..];
                var msg: []const u8 = "";
                var who: []const u8 = rest;
                if (std.mem.indexOf(u8, rest, "\t")) |tab_pos| {
                    who = rest[0..tab_pos];
                    msg = rest[tab_pos + 1 ..];
                }
                try reflog_entries.append(.{
                    .old_hash = try allocator.dupe(u8, old_h),
                    .new_hash = try allocator.dupe(u8, new_h),
                    .who = try allocator.dupe(u8, who),
                    .message = try allocator.dupe(u8, msg),
                });
            }
            // Walk in reverse (newest first)
            var count: u32 = 0;
            var entry_idx: usize = reflog_entries.items.len;
            while (entry_idx > 0 and (lo.max_count == null or count < lo.max_count.?)) {
                entry_idx -= 1;
                const entry = reflog_entries.items[entry_idx];
                const ref_for_selector = if (committish_list.items.len > 0) ref_name else "HEAD";
                const selector = try std.fmt.allocPrint(allocator, "{s}@{{{d}}}", .{ ref_for_selector, reflog_entries.items.len - 1 - entry_idx });
                defer allocator.free(selector);

                // Apply --grep filtering for reflog entries
                if (lo.grep_filters.items.len > 0) {
                    // For reflog, match against the commit message
                    const r_obj = objects.GitObject.load(entry.new_hash, git_path, pi, allocator) catch null;
                    defer if (r_obj) |o| o.deinit(allocator);
                    const r_msg = if (r_obj) |o| extractMessage(o.data) else "";
                    var grep_ok = false;
                    for (lo.grep_filters.items) |gf| {
                        if (logFilterMatch(r_msg, gf, lo.fixed_strings)) { grep_ok = true; break; }
                    }
                    const skip = if (lo.invert_grep) grep_ok else !grep_ok;
                    if (skip) continue;
                }

                if (lo.format_string) |fmt| {
                    if (lo.format_is_separator and count > 0) {
                        try pi.writeStdout("\n");
                    }
                    // Load commit object for standard fields
                    const obj = objects.GitObject.load(entry.new_hash, git_path, pi, allocator) catch null;
                    defer if (obj) |o| o.deinit(allocator);
                    const obj_data = if (obj) |o| o.data else "";
                    const ri = ReflogInfo{
                        .selector = selector,
                        .message = entry.message,
                        .who = entry.who,
                    };
                    try writeFormattedCommitWithReflog(fmt, entry.new_hash, obj_data, pi, allocator, &ri);
                    if (!lo.format_is_separator) {
                        try pi.writeStdout("\n");
                    }
                } else if (lo.oneline) {
                    const short_hash = if (entry.new_hash.len >= 7) entry.new_hash[0..7] else entry.new_hash;
                    const out_line = try std.fmt.allocPrint(allocator, "{s} {s}: {s}\n", .{ short_hash, selector, entry.message });
                    defer allocator.free(out_line);
                    try pi.writeStdout(out_line);
                } else {
                    // Default format
                    const out_hdr = try std.fmt.allocPrint(allocator, "commit {s} ({s})\n", .{ entry.new_hash, selector });
                    defer allocator.free(out_hdr);
                    try pi.writeStdout(out_hdr);
                    const obj = objects.GitObject.load(entry.new_hash, git_path, pi, allocator) catch null;
                    defer if (obj) |o| o.deinit(allocator);
                    if (obj) |o| {
                        const author_f = extractField(o.data, "author ");
                        const name_f = parsePersonName(author_f);
                        const email_f = parsePersonEmail(author_f);
                        const author_out = try std.fmt.allocPrint(allocator, "Reflog: {s} ({s})\nReflog message: {s}\nAuthor: {s} <{s}>\n", .{ selector, name_f, entry.message, name_f, email_f });
                        defer allocator.free(author_out);
                        try pi.writeStdout(author_out);
                        const date_str = formatGitDate(author_f, allocator);
                        defer if (date_str) |d| allocator.free(d);
                        if (date_str) |d| {
                            const date_out = try std.fmt.allocPrint(allocator, "Date:   {s}\n", .{d});
                            defer allocator.free(date_out);
                            try pi.writeStdout(date_out);
                        }
                        const cmsg = extractMessage(o.data);
                        try pi.writeStdout("\n");
                        var msg_iter = std.mem.splitScalar(u8, std.mem.trimRight(u8, cmsg, "\n"), '\n');
                        while (msg_iter.next()) |ml| {
                            const indented = try std.fmt.allocPrint(allocator, "    {s}\n", .{ml});
                            defer allocator.free(indented);
                            try pi.writeStdout(indented);
                        }
                        try pi.writeStdout("\n");
                    }
                }
                count += 1;
            }
        }
        return;
    }

    // Show mode: walk history when ranges/exclude or -N is used
    if (show_mode and (exclude_hashes.items.len > 0 or (lo.max_count != null and lo.max_count.? > 1))) {
        // Build excluded set by walking excluded refs
        var excluded_set = std.StringHashMap(void).init(allocator);
        defer {
            var eit = excluded_set.iterator();
            while (eit.next()) |entry| allocator.free(entry.key_ptr.*);
            excluded_set.deinit();
        }
        for (exclude_hashes.items) |eh| {
            var ewq = std.array_list.Managed([]const u8).init(allocator);
            defer ewq.deinit();
            try ewq.append(try allocator.dupe(u8, eh));
            while (ewq.items.len > 0) {
                if (ewq.items.len == 0) break;
                const ewh = ewq.items[ewq.items.len - 1];
                ewq.items.len -= 1;
                if (excluded_set.contains(ewh)) { allocator.free(@constCast(ewh)); continue; }
                try excluded_set.put(ewh, {});
                const eobj = objects.GitObject.load(ewh, git_path, pi, allocator) catch continue;
                defer eobj.deinit(allocator);
                var elines = std.mem.splitSequence(u8, eobj.data, "\n");
                while (elines.next()) |eline| {
                    if (eline.len == 0) break;
                    if (std.mem.startsWith(u8, eline, "parent ")) {
                        try ewq.append(try allocator.dupe(u8, eline["parent ".len..]));
                    }
                }
            }
        }

        // Walk from start hashes
        const ShowQE = struct { hash: []const u8, ts: i64 };
        var show_q = std.array_list.Managed(ShowQE).init(allocator);
        defer {
            for (show_q.items) |sq| allocator.free(@constCast(sq.hash));
            show_q.deinit();
        }
        var show_visited = std.StringHashMap(void).init(allocator);
        defer {
            var svi = show_visited.iterator();
            while (svi.next()) |entry| allocator.free(entry.key_ptr.*);
            show_visited.deinit();
        }
        for (start_hashes.items) |sh| {
            if (!show_visited.contains(sh)) {
                try show_visited.put(try allocator.dupe(u8, sh), {});
                try show_q.append(.{ .hash = try allocator.dupe(u8, sh), .ts = git_helpers_mod.getCommitTimestamp(sh, git_path, pi, allocator) });
            }
        }

        var show_count: u32 = 0;
        while (show_q.items.len > 0) {
            if (lo.max_count) |smc| { if (show_count >= smc) break; }

            var best_i: usize = 0;
            for (show_q.items, 0..) |sq, si| {
                if (sq.ts > show_q.items[best_i].ts) best_i = si;
            }
            const cur = show_q.swapRemove(best_i);
            defer allocator.free(@constCast(cur.hash));

            if (excluded_set.contains(cur.hash)) continue;

            var sobj = objects.GitObject.load(cur.hash, git_path, pi, allocator) catch continue;
            defer sobj.deinit(allocator);

            // Peel tags to commits silently in range walk mode
            if (sobj.type == .tag) {
                var tag_obj_hash2: ?[]const u8 = null;
                var tp: usize = 0;
                while (tp < sobj.data.len) {
                    const tnl2 = std.mem.indexOfScalarPos(u8, sobj.data, tp, '\n') orelse sobj.data.len;
                    const tl = sobj.data[tp..tnl2];
                    if (tl.len == 0) break;
                    if (std.mem.startsWith(u8, tl, "object ")) tag_obj_hash2 = tl["object ".len..];
                    tp = tnl2 + 1;
                }
                if (tag_obj_hash2) |toh2| {
                    if (!show_visited.contains(toh2)) {
                        try show_visited.put(try allocator.dupe(u8, toh2), {});
                        try show_q.append(.{ .hash = try allocator.dupe(u8, toh2), .ts = git_helpers_mod.getCommitTimestamp(toh2, git_path, pi, allocator) });
                    }
                }
                continue;
            }
            if (sobj.type != .commit) continue;

            // Apply --grep filtering
            if (lo.grep_filters.items.len > 0) {
                const gm = extractMessage(sobj.data);
                var gok = false;
                for (lo.grep_filters.items) |gf| {
                    if (logFilterMatch(gm, gf, lo.fixed_strings)) { gok = true; break; }
                }
                const gskip = if (lo.invert_grep) gok else !gok;
                if (gskip) {
                    // Still add parents for walking
                    var glines = std.mem.splitSequence(u8, sobj.data, "\n");
                    while (glines.next()) |gline| {
                        if (gline.len == 0) break;
                        if (std.mem.startsWith(u8, gline, "parent ")) {
                            const gph = gline["parent ".len..];
                            if (!show_visited.contains(gph) and !excluded_set.contains(gph)) {
                                try show_visited.put(try allocator.dupe(u8, gph), {});
                                try show_q.append(.{ .hash = try allocator.dupe(u8, gph), .ts = git_helpers_mod.getCommitTimestamp(gph, git_path, pi, allocator) });
                            }
                        }
                    }
                    continue;
                }
            }

            // Add parents when walking a range or using -N
            if (exclude_hashes.items.len > 0 or (lo.max_count != null and lo.max_count.? > 1)) {
                var slines = std.mem.splitSequence(u8, sobj.data, "\n");
                while (slines.next()) |sline| {
                    if (sline.len == 0) break;
                    if (std.mem.startsWith(u8, sline, "parent ")) {
                        const sph = sline["parent ".len..];
                        if (!show_visited.contains(sph) and !excluded_set.contains(sph)) {
                            try show_visited.put(try allocator.dupe(u8, sph), {});
                            try show_q.append(.{ .hash = try allocator.dupe(u8, sph), .ts = git_helpers_mod.getCommitTimestamp(sph, git_path, pi, allocator) });
                        }
                    }
                }
            }

            if (!lo.oneline and show_count > 0) try pi.writeStdout("\n");
            if (lo.format_string) |fmt| {
                if (lo.format_is_separator and show_count > 0) try pi.writeStdout("\n");
                try writeFormattedCommitWithDecorations(fmt, cur.hash, sobj.data, pi, allocator, &decoration_map);
                if (!lo.format_is_separator) try pi.writeStdout("\n");
            } else if (lo.oneline) {
                const short = cur.hash[0..@min(7, cur.hash.len)];
                const m = extractMessage(sobj.data);
                const first_line = if (std.mem.indexOf(u8, m, "\n")) |nl| m[0..nl] else std.mem.trimRight(u8, m, "\n");
                const out = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ short, first_line });
                defer allocator.free(out);
                try pi.writeStdout(out);
            } else {
                try writeCommitHeader(cur.hash, sobj.data, &lo, true, pi, allocator, git_path);
            }
            if (lo.show_patch) {
                const sparents = try getAllParents(sobj.data, allocator);
                defer sparents.deinit();
                const sp_parent: ?[]const u8 = if (sparents.items.len > 0) sparents.items[0] else null;
                try writeDiffForCommit(cur.hash, sobj.data, sp_parent, &lo, git_path, pi, allocator);
            }
            show_count += 1;
        }
        return;
    }

    // Show mode: just show the specified commits (don't walk history for non-show)
    if (show_mode) {
        try pi.writeStderr("SHOW-MODE-ENTERED\n");
        // Handle -N by walking parents from the first start hash
        if (lo.max_count != null and lo.max_count.? > 1 and start_hashes.items.len == 1) {
            var cur_h = try allocator.dupe(u8, start_hashes.items[0]);
            var n_shown: u32 = 0;
            while (n_shown < lo.max_count.?) {
                const wobj = objects.GitObject.load(cur_h, git_path, pi, allocator) catch break;
                defer wobj.deinit(allocator);
                if (wobj.type != .commit) break;

                if (n_shown > 0) try pi.writeStdout("\n");
                if (lo.format_string) |fmt| {
                    if (lo.format_is_separator and n_shown > 0) try pi.writeStdout("\n");
                    try writeFormattedCommit(fmt, cur_h, wobj.data, pi, allocator);
                    if (!lo.format_is_separator) try pi.writeStdout("\n");
                } else {
                    try writeCommitHeader(cur_h, wobj.data, &lo, true, pi, allocator, git_path);
                }
                if (lo.show_patch) {
                    const wparents = try getAllParents(wobj.data, allocator);
                    defer wparents.deinit();
                    const wp: ?[]const u8 = if (wparents.items.len > 0) wparents.items[0] else null;
                    try writeDiffForCommit(cur_h, wobj.data, wp, &lo, git_path, pi, allocator);
                }
                n_shown += 1;

                // Get first parent for next iteration
                const nparents = try getAllParents(wobj.data, allocator);
                defer nparents.deinit();
                if (nparents.items.len == 0) break;
                allocator.free(cur_h);
                cur_h = try allocator.dupe(u8, nparents.items[0]);
            }
            allocator.free(cur_h);
            return;
        }

        for (start_hashes.items, 0..) |hash, idx| {
            const obj = objects.GitObject.load(hash, git_path, pi, allocator) catch {
                const msg = try std.fmt.allocPrint(allocator, "fatal: bad object {s}\n", .{hash});
                defer allocator.free(msg);
                try pi.writeStderr(msg);
                continue;
            };
            defer obj.deinit(allocator);

            if (obj.type == .blob) {
                try pi.writeStdout(obj.data);
                continue;
            }
            if (obj.type == .tree) {
                if (idx > 0) try pi.writeStdout("\n");
                const display_name = if (idx < start_ref_names.items.len) start_ref_names.items[idx] else hash;
                const hdr = try std.fmt.allocPrint(allocator, "tree {s}\n\n", .{display_name});
                defer allocator.free(hdr);
                try pi.writeStdout(hdr);
                // List tree entries
                var tpos: usize = 0;
                while (tpos < obj.data.len) {
                    const mode_start = tpos;
                    const sp = std.mem.indexOfScalarPos(u8, obj.data, tpos, ' ') orelse break;
                    const mode = obj.data[mode_start..sp];
                    tpos = sp + 1;
                    const np = std.mem.indexOfScalarPos(u8, obj.data, tpos, 0) orelse break;
                    const ename = obj.data[tpos..np];
                    try pi.writeStdout(ename);
                    // Append / for directory entries (mode 40000)
                    if (std.mem.eql(u8, mode, "40000")) try pi.writeStdout("/");
                    try pi.writeStdout("\n");
                    tpos = np + 1 + 20;
                }
                continue;
            }
            if (obj.type == .tag) {
                // Parse and display tag object properly
                const tlines = std.mem.splitSequence(u8, obj.data, "\n");
                var tag_obj_hash: ?[]const u8 = null;
                var tag_name_val: ?[]const u8 = null;
                var tagger_val: ?[]const u8 = null;
                var tag_msg_start: usize = obj.data.len;
                {
                    var tpos2: usize = 0;
                    while (tpos2 < obj.data.len) {
                        const tnl = std.mem.indexOfScalarPos(u8, obj.data, tpos2, '\n') orelse obj.data.len;
                        const tline = obj.data[tpos2..tnl];
                        if (tline.len == 0) { tag_msg_start = tnl + 1; break; }
                        if (std.mem.startsWith(u8, tline, "object ")) tag_obj_hash = tline["object ".len..];
                        if (std.mem.startsWith(u8, tline, "tag ")) tag_name_val = tline["tag ".len..];
                        if (std.mem.startsWith(u8, tline, "tagger ")) tagger_val = tline["tagger ".len..];
                        tpos2 = tnl + 1;
                    }
                }
                _ = tlines;
                if (tag_name_val) |tn| {
                    const th = try std.fmt.allocPrint(allocator, "tag {s}\n", .{tn});
                    defer allocator.free(th);
                    try pi.writeStdout(th);
                }
                if (tagger_val) |tv| {
                    // Extract name <email> part
                    if (std.mem.indexOf(u8, tv, ">")) |gt| {
                        const tname = tv[0 .. gt + 1];
                        const tout = try std.fmt.allocPrint(allocator, "Tagger: {s}\n", .{tname});
                        defer allocator.free(tout);
                        try pi.writeStdout(tout);
                    }
                }
                try pi.writeStdout("\n");
                if (tag_msg_start < obj.data.len) {
                    try pi.writeStdout(std.mem.trimRight(u8, obj.data[tag_msg_start..], "\n"));
                    try pi.writeStdout("\n");
                }
                // Now show the referenced object
                if (tag_obj_hash) |toh| {
                    try pi.writeStdout("\n");
                    const ref_obj = objects.GitObject.load(toh, git_path, pi, allocator) catch {
                        const emsg = try std.fmt.allocPrint(allocator, "fatal: bad object {s}\n", .{toh});
                        defer allocator.free(emsg);
                        try pi.writeStderr(emsg);
                        std.process.exit(128);
                    };
                    defer ref_obj.deinit(allocator);
                    if (ref_obj.type == .commit) {
                        // Show the commit with diff
                        if (lo.format_string) |fmt| {
                            try writeFormattedCommit(fmt, toh, ref_obj.data, pi, allocator);
                        } else {
                            try writeCommitHeader(toh, ref_obj.data, &lo, true, pi, allocator, git_path);
                        }
                        if (lo.show_patch) {
                            const cparents = try getAllParents(ref_obj.data, allocator);
                            defer cparents.deinit();
                            const pparent: ?[]const u8 = if (cparents.items.len > 0) cparents.items[0] else null;
                            try writeDiffForCommit(toh, ref_obj.data, pparent, &lo, git_path, pi, allocator);
                        }
                    } else if (ref_obj.type == .blob) {
                        try pi.writeStdout(ref_obj.data);
                    } else if (ref_obj.type == .tree) {
                        try pi.writeStdout(ref_obj.data);
                    }
                }
                continue;
            }
            if (obj.type != .commit) continue;

            // Apply --grep filtering in show mode
            if (lo.grep_filters.items.len > 0) {
                const msg = extractMessage(obj.data);
                var grep_ok = false;
                for (lo.grep_filters.items) |gf| {
                    if (logFilterMatch(msg, gf, lo.fixed_strings)) { grep_ok = true; break; }
                }
                const skip = if (lo.invert_grep) grep_ok else !grep_ok;
                if (skip) continue;
            }

            const parents = try getAllParents(obj.data, allocator);
            defer parents.deinit();

            if (lo.format_string) |fmt| {
                if (lo.format_is_separator and idx > 0) {
                    try pi.writeStdout("\n");
                }
                try writeFormattedCommitWithDecorations(fmt, hash, obj.data, pi, allocator, &decoration_map);
                if (!lo.format_is_separator) {
                    try pi.writeStdout("\n");
                }
                // If name_only, name_status, or other diff modes, continue to diff output
                if (!lo.name_only and !lo.name_status and !lo.show_raw and !lo.show_stat and !lo.show_patch) {
                    continue;
                }
            }

            const is_separate_show = lo.format_string == null and parents.items.len > 1 and lo.diff_merges == .separate;
            if (is_separate_show) {
                // show -m: repeated header+diff for each parent
                const show_parents = if (lo.first_parent) parents.items[0..1] else parents.items;
                const use_from = show_parents.len > 1;
                for (show_parents, 0..) |ph, pidx| {
                    if (idx > 0 or pidx > 0) try pi.writeStdout("\n");
                    if (use_from) {
                        try writeCommitHeaderWithFrom(hash, obj.data, ph, &lo, pi, allocator, git_path);
                    } else {
                        try writeCommitHeader(hash, obj.data, &lo, false, pi, allocator, git_path);
                    }
                    try pi.writeStdout("\n");
                    try writeDiffForCommit(hash, obj.data, ph, &lo, git_path, pi, allocator);
                }
                continue;
            } else if (lo.format_string == null and lo.oneline) {
                const short = hash[0..@min(7, hash.len)];
                const msg = extractMessage(obj.data);
                const first_line = if (std.mem.indexOf(u8, msg, "\n")) |nl| msg[0..nl] else std.mem.trimRight(u8, msg, "\n");
                const out = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ short, first_line });
                defer allocator.free(out);
                try pi.writeStdout(out);
            } else if (lo.format_string == null) {
                try writeCommitHeader(hash, obj.data, &lo, idx == start_hashes.items.len - 1, pi, allocator, git_path);
            }

            // Skip diff output if -s/--no-patch and no stat/raw modes
            const need_diff = lo.show_patch or lo.show_stat or lo.show_raw or lo.show_summary or lo.show_shortstat or lo.name_only or lo.name_status;
            if (need_diff) {
                if (parents.items.len > 1) {
                    if (lo.first_parent or lo.diff_merges == .first_parent) {
                        // show --first-parent: first-parent diff
                        try pi.writeStdout("\n");
                        try writeDiffForCommit(hash, obj.data, parents.items[0], &lo, git_path, pi, allocator);
                    } else if (lo.combined_style != .none or lo.diff_merges == .combined or lo.diff_merges == .dense_combined) {
                        try pi.writeStdout("\n");
                        try writeCombinedDiffForCommit(obj.data, &lo, git_path, pi, allocator);
                    } else {
                        // Default show for merge: combined diff (--cc style)
                        try pi.writeStdout("\n");
                        try writeCombinedDiffForCommit(obj.data, &lo, git_path, pi, allocator);
                    }
                } else {
                    const ph = if (parents.items.len > 0) parents.items[0] else null;
                    if ((ph != null or lo.root or lo.show_mode) and !lo.patch_with_stat) {
                        try pi.writeStdout("\n");
                    }
                    try writeDiffForCommit(hash, obj.data, ph, &lo, git_path, pi, allocator);
                }
            }
        }
        return;
    }

    // Priority queue walk
    var queue = std.array_list.Managed(CommitEntry).init(allocator);
    defer {
        for (queue.items) |e| allocator.free(@constCast(e.hash));
        queue.deinit();
    }

    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var viter = visited.iterator();
        while (viter.next()) |e| allocator.free(e.key_ptr.*);
        visited.deinit();
    }

    // Pre-mark excluded commits and their ancestors as visited
    // This prevents them from being shown in the output
    if (exclude_hashes.items.len > 0) {
        var exc_queue_list = std.array_list.Managed([]const u8).init(allocator);
        defer exc_queue_list.deinit();
        for (exclude_hashes.items) |eh| {
            try exc_queue_list.append(try allocator.dupe(u8, eh));
        }
        while (exc_queue_list.items.len > 0) {
            if (exc_queue_list.items.len == 0) break;
            const eh = exc_queue_list.orderedRemove(exc_queue_list.items.len - 1);
            if (visited.contains(eh)) { allocator.free(eh); continue; }
            try visited.put(eh, {});
            const eobj = objects.GitObject.load(eh, git_path, pi, allocator) catch continue;
            defer eobj.deinit(allocator);
            var eit = std.mem.splitSequence(u8, eobj.data, "\n");
            while (eit.next()) |eline| {
                if (eline.len == 0) break;
                if (std.mem.startsWith(u8, eline, "parent ")) {
                    try exc_queue_list.append(try allocator.dupe(u8, eline["parent ".len..]));
                }
            }
        }
    }

    var insert_order: u32 = 0;
    for (start_hashes.items) |h| {
        if (!visited.contains(h)) {
            const obj = objects.GitObject.load(h, git_path, pi, allocator) catch continue;
            defer obj.deinit(allocator);
            const ts = getCommitterTimestamp(obj.data);
            try queue.append(.{ .hash = try allocator.dupe(u8, h), .timestamp = ts, .order = insert_order });
            insert_order += 1;
            try visited.put(try allocator.dupe(u8, h), {});
        }
    }

    var count: u32 = 0;
    var first = true;
    while (queue.items.len > 0) {
        if (lo.max_count) |mc2| {
            if (count >= mc2) break;
        }

        // Find entry with highest timestamp (tiebreak: lower insertion order first)
        var best: usize = 0;
        for (queue.items, 0..) |e, idx| {
            if (e.timestamp > queue.items[best].timestamp) {
                best = idx;
            } else if (e.timestamp == queue.items[best].timestamp) {
                if (e.order < queue.items[best].order) {
                    best = idx;
                }
            }
        }
        const entry = queue.orderedRemove(best);
        const cur_hash = entry.hash;
        defer allocator.free(@constCast(cur_hash));

        const obj = objects.GitObject.load(cur_hash, git_path, pi, allocator) catch continue;
        defer obj.deinit(allocator);
        if (obj.type != .commit) continue;

        const parents = try getAllParents(obj.data, allocator);
        defer parents.deinit();
        const is_merge = parents.items.len > 1;

        // --no-merges / --merges / --min-parents / --max-parents filtering
        if (lo.max_parents) |mp| {
            if (parents.items.len > mp) {
                addParentsToQueue(&queue, &visited, parents.items, lo.first_parent, git_path, pi, allocator) catch {};
                continue;
            }
        }
        if (lo.min_parents) |mp| {
            if (parents.items.len < mp) {
                addParentsToQueue(&queue, &visited, parents.items, lo.first_parent, git_path, pi, allocator) catch {};
                continue;
            }
        }

        // Pickaxe filtering
        if (lo.pickaxe_s) |search| {
            if (!commitMatchesPickaxe(obj.data, if (parents.items.len > 0) parents.items[0] else null, git_path, search, false, allocator, pi)) {
                // Still need to walk parents
                addParentsToQueue(&queue, &visited, parents.items, lo.first_parent, git_path, pi, allocator) catch {};
                continue;
            }
        }
        if (lo.pickaxe_g) |search| {
            if (!commitMatchesPickaxe(obj.data, if (parents.items.len > 0) parents.items[0] else null, git_path, search, true, allocator, pi)) {
                addParentsToQueue(&queue, &visited, parents.items, lo.first_parent, git_path, pi, allocator) catch {};
                continue;
            }
        }

        // --grep / --author / --committer filtering
        {
            const has_author_f = lo.author_filters.items.len > 0;
            const has_committer_f = lo.committer_filters.items.len > 0;
            const has_grep_f = lo.grep_filters.items.len > 0;

            if (has_author_f or has_committer_f or has_grep_f) {
                const raw_msg = extractMessage(obj.data);
                // Re-encode message for grep matching if --encoding is specified
                const grep_commit_enc = getCommitEncoding(obj.data);
                const grep_out_enc = lo.output_encoding orelse "UTF-8";
                const msg = reencodeForGrep(allocator, raw_msg, grep_commit_enc, grep_out_enc) catch raw_msg;
                const msg_needs_free = msg.ptr != raw_msg.ptr;
                defer if (msg_needs_free) allocator.free(msg);
                const author_full = extractField(obj.data, "author ");
                const committer_full = extractField(obj.data, "committer ");
                // Strip timestamp from author/committer for matching (only match name <email>)
                const author_val = stripPersonTimestamp(author_full);
                const committer_val = stripPersonTimestamp(committer_full);

                const should_show = if (lo.all_match) blk: {
                    // all-match: author uses union, committer uses union, grep ALL must match
                    if (has_author_f) {
                        var any = false;
                        for (lo.author_filters.items) |af| {
                            if (logFilterMatch(author_val, af, lo.fixed_strings)) { any = true; break; }
                        }
                        if (!any) break :blk false;
                    }
                    if (has_committer_f) {
                        var any = false;
                        for (lo.committer_filters.items) |cf| {
                            if (logFilterMatch(committer_val, cf, lo.fixed_strings)) { any = true; break; }
                        }
                        if (!any) break :blk false;
                    }
                    if (has_grep_f) {
                        var all_grep_match = true;
                        for (lo.grep_filters.items) |gf| {
                            if (!logFilterMatch(msg, gf, lo.fixed_strings)) { all_grep_match = false; break; }
                        }
                        const effective_grep = if (lo.invert_grep) !all_grep_match else all_grep_match;
                        if (!effective_grep) break :blk false;
                    }
                    break :blk true;
                } else blk: {
                    // Default: union within each filter type, intersection between types
                    var grep_ok = !has_grep_f;
                    var author_ok = !has_author_f;
                    var committer_ok = !has_committer_f;
                    if (has_grep_f) {
                        for (lo.grep_filters.items) |gf| {
                            if (logFilterMatch(msg, gf, lo.fixed_strings)) { grep_ok = true; break; }
                        }
                    }
                    if (has_author_f) {
                        for (lo.author_filters.items) |af| {
                            if (logFilterMatch(author_val, af, lo.fixed_strings)) { author_ok = true; break; }
                        }
                    }
                    if (has_committer_f) {
                        for (lo.committer_filters.items) |cf| {
                            if (logFilterMatch(committer_val, cf, lo.fixed_strings)) { committer_ok = true; break; }
                        }
                    }
                    // --invert-grep only inverts the grep match, not author/committer
                    const effective_grep = if (lo.invert_grep and has_grep_f) !grep_ok else grep_ok;
                    break :blk effective_grep and author_ok and committer_ok;
                };

                const skip = !should_show;
                if (skip) {
                    addParentsToQueue(&queue, &visited, parents.items, lo.first_parent, git_path, pi, allocator) catch {};
                    continue;
                }
            } else if (lo.grep_pattern) |pattern| {
                // Legacy single grep_pattern fallback
                const msg = extractMessage(obj.data);
                const commit_enc = getCommitEncoding(obj.data);
                const out_enc = lo.output_encoding orelse "UTF-8";
                const match_msg = reencodeForGrep(allocator, msg, commit_enc, out_enc) catch msg;
                const should_free = match_msg.ptr != msg.ptr;
                defer if (should_free) allocator.free(match_msg);
                if (std.mem.indexOf(u8, match_msg, pattern) == null) {
                    addParentsToQueue(&queue, &visited, parents.items, lo.first_parent, git_path, pi, allocator) catch {};
                    continue;
                }
            }
        }

        // For whatchanged mode without -p, we show raw by default
        // For log mode, default is no diff
        const show_any_diff = lo.show_patch or lo.show_stat or lo.show_raw or lo.show_summary or lo.show_shortstat or lo.patch_with_stat or lo.patch_with_raw or lo.name_only or lo.name_status;

        // Determine if we should show diff for this commit
        var show_diff = show_any_diff;
        var diff_parents: ?[]const []const u8 = null;

        if (is_merge) {
            switch (lo.diff_merges) {
                .off => {
                    show_diff = false;
                },
                .default => {
                    if (lo.combined_style != .none) {
                        show_diff = show_any_diff;
                    } else if (lo.first_parent and show_any_diff) {
                        // --first-parent implies diff against first parent
                        diff_parents = parents.items[0..1];
                    } else {
                        show_diff = false;
                    }
                },
                .first_parent => {
                    diff_parents = parents.items[0..1];
                    show_diff = true;
                },
                .separate => {
                    if (lo.first_parent) {
                        diff_parents = parents.items[0..1];
                    } else {
                        diff_parents = parents.items;
                    }
                },
                .combined, .dense_combined => {
                    show_diff = show_any_diff;
                },
                .on => {
                    diff_parents = parents.items;
                },
            }
        }

        // In whatchanged mode, skip merge commits (unless -m or -c/--cc is specified)
        if (lo.whatchanged_mode and is_merge and lo.diff_merges != .separate and lo.diff_merges != .on and lo.combined_style == .none and lo.diff_merges != .combined and lo.diff_merges != .dense_combined) {
            addParentsToQueue(&queue, &visited, parents.items, lo.first_parent, git_path, pi, allocator) catch {};
            continue;
        }

        // In whatchanged mode, skip commits with no changes to show
        if (lo.whatchanged_mode and !is_merge) {
            const ph = if (parents.items.len > 0) parents.items[0] else null;
            if (ph == null and !lo.root) {
                // Root commit without --root - skip
                addParentsToQueue(&queue, &visited, parents.items, lo.first_parent, git_path, pi, allocator) catch {};
                continue;
            }
        }

        // For merge commits with separate diff mode, output a header+diff per parent
        const is_separate_merge = is_merge and diff_parents != null and
            (lo.diff_merges == .separate or lo.diff_merges == .on or lo.diff_merges == .first_parent or lo.diff_merges == .default);
        if (is_separate_merge and show_diff) {
            // For --diff-merges=first-parent, enable patch if not explicitly set
            const old_patch = lo.show_patch;
            if (lo.diff_merges == .first_parent and !lo.show_patch and !lo.show_stat and !lo.show_raw) {
                lo.show_patch = true;
            }
            // Show "(from ...)" only when showing multiple parents explicitly
            const use_from_header = (lo.diff_merges == .separate or lo.diff_merges == .on) and diff_parents.?.len > 1;
            for (diff_parents.?) |ph| {
                if (!first) try pi.writeStdout("\n");
                first = false;
                if (!lo.oneline) {
                    if (use_from_header) {
                        try writeCommitHeaderWithFrom(cur_hash, obj.data, ph, &lo, pi, allocator, git_path);
                    } else {
                        try writeCommitHeader(cur_hash, obj.data, &lo, false, pi, allocator, git_path);
                    }
                } else {
                    const short = cur_hash[0..@min(7, cur_hash.len)];
                    const msg = extractMessage(obj.data);
                    const first_line = if (std.mem.indexOf(u8, msg, "\n")) |nl| msg[0..nl] else std.mem.trimRight(u8, msg, "\n");
                    const out = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ short, first_line });
                    defer allocator.free(out);
                    try pi.writeStdout(out);
                }
                try pi.writeStdout("\n");
                try writeDiffForCommit(cur_hash, obj.data, ph, &lo, git_path, pi, allocator);
            }
            lo.show_patch = old_patch;
        } else {
            // Normal commit header (single)
            if (lo.format_string) |fmt| {
                if (lo.format_is_separator and !first) {
                    try pi.writeStdout("\n");
                }
                first = false;
                try writeFormattedCommitWithDecorations(fmt, cur_hash, obj.data, pi, allocator, &decoration_map);
                if (!lo.format_is_separator) {
                    try pi.writeStdout("\n");
                }
            } else if (!lo.oneline) {
                if (!first) try pi.writeStdout("\n");
                first = false;
                try writeCommitHeader(cur_hash, obj.data, &lo, false, pi, allocator, git_path);
            } else {
                const short = cur_hash[0..@min(7, cur_hash.len)];
                const msg = extractMessage(obj.data);
                const first_line = if (std.mem.indexOf(u8, msg, "\n")) |nl| msg[0..nl] else std.mem.trimRight(u8, msg, "\n");
                const out = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ short, first_line });
                defer allocator.free(out);
                try pi.writeStdout(out);
            }

            // Output diff
            if (show_diff) {
                if (is_merge and (lo.combined_style != .none or lo.diff_merges == .combined or lo.diff_merges == .dense_combined)) {
                    try pi.writeStdout("\n");
                    try writeCombinedDiffForCommit(obj.data, &lo, git_path, pi, allocator);
                } else if (!is_merge) {
                    const ph = if (parents.items.len > 0) parents.items[0] else null;
                    const has_parent_or_root = (ph != null) or lo.root;
                    if (has_parent_or_root) {
                        if (lo.patch_with_stat) {
                            // patch-with-stat uses --- separator
                        } else {
                            try pi.writeStdout("\n");
                        }
                    }
                    try writeDiffForCommit(cur_hash, obj.data, ph, &lo, git_path, pi, allocator);
                }
            }
        }

        count += 1;

        // Add parents to queue
        addParentsToQueue(&queue, &visited, parents.items, lo.first_parent, git_path, pi, allocator) catch {};
    }
}

fn addParentsToQueue(queue: *std.array_list.Managed(CommitEntry), visited: *std.StringHashMap(void), parents: []const []const u8, first_parent: bool, git_path: []const u8, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    const limit = if (first_parent) @min(@as(usize, 1), parents.len) else parents.len;
    for (parents[0..limit]) |ph| {
        if (!visited.contains(ph)) {
            try visited.put(try allocator.dupe(u8, ph), {});
            const pobj = objects.GitObject.load(ph, git_path, pi, allocator) catch continue;
            defer pobj.deinit(allocator);
            const ts = getCommitterTimestamp(pobj.data);
            // Use max order so parents are visited after same-timestamp siblings
            try queue.append(.{ .hash = try allocator.dupe(u8, ph), .timestamp = ts, .order = std.math.maxInt(u32) });
        }
    }
}

fn writeCombinedDiffForCommit(data: []const u8, lo: *LogOpts, git_path: []const u8, pi: *const pm.Platform, allocator: std.mem.Allocator) !void {
    const tree_hash = extractField(data, "tree ");
    if (tree_hash.len == 0) return;

    const parents = try getAllParents(data, allocator);
    defer parents.deinit();
    if (parents.items.len < 2) return;

    // Build list of refs: result_tree, parent1_tree, parent2_tree, ...
    var ref_list = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (ref_list.items) |r| allocator.free(r);
        ref_list.deinit();
    }

    // Result tree
    try ref_list.append(try allocator.dupe(u8, tree_hash));
    // Parent trees
    for (parents.items) |ph| {
        const pobj = objects.GitObject.load(ph, git_path, pi, allocator) catch continue;
        defer pobj.deinit(allocator);
        const pt = extractField(pobj.data, "tree ");
        if (pt.len > 0) {
            try ref_list.append(try allocator.dupe(u8, pt));
        }
    }

    if (ref_list.items.len < 3) return;

    // If --patch-with-stat or --stat or --summary, output stat before combined diff
    if (lo.patch_with_stat or lo.show_stat or lo.show_summary or lo.show_shortstat) {
        // Compute changes between first parent and result for stat
        var changes = std.array_list.Managed(FileChange).init(allocator);
        defer {
            for (changes.items) |*c| freeChange(allocator, c);
            changes.deinit();
        }
        collectTreeChanges(allocator, ref_list.items[1], ref_list.items[0], "", git_path, &.{}, pi, &changes) catch {};
        if (changes.items.len > 0) {
            if (lo.patch_with_stat or lo.show_stat or lo.show_shortstat) {
                try outputStat(changes.items, pi, allocator);
            }
            if (lo.show_summary) {
                try outputSummary(changes.items, pi, allocator);
            }
            if (lo.patch_with_stat) {
                try pi.writeStdout("\n");
            }
        }
    }

    var diff_opts = DiffOpts{
        .ignore_regex = std.array_list.Managed([]const u8).init(allocator),
        .line_prefix = lo.line_prefix,
        .combined_use_c = lo.combined_style == .c_style,
    };
    defer diff_opts.ignore_regex.deinit();

    if (lo.show_patch or lo.patch_with_stat or lo.patch_with_raw) {
        doCombinedDiff(allocator, ref_list.items, git_path, &diff_opts, pi) catch {};
    }
}

pub fn cmdFormatPatch(allocator: std.mem.Allocator, args: *pm.ArgIterator, pi: *const pm.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try pi.writeStderr("format-patch: not supported in freestanding mode\n");
        return;
    }

    const git_path = git_helpers_mod.findGitDirectory(allocator, pi) catch {
        try pi.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Parse arguments
    var rev_range: ?[]const u8 = null;
    var dash_n_count: ?usize = null;
    var positional_rev: ?[]const u8 = null;
    var stdout_mode = false;
    var numbered: ?bool = null;
    var no_numbered = false;
    var subject_prefix: []const u8 = "PATCH";
    var start_number: usize = 1;
    var cover_letter = false;
    var attach = false;
    var inline_mode = false;
    var suffix: []const u8 = ".patch";
    var numbered_files = false;
    var signoff = false;
    var fp_grep_pattern: ?[]const u8 = null;
    var fp_fixed_strings = false;
    var fp_fixed_strings_explicit = false;

    // Check for config format.subjectprefix
    if (git_helpers_mod.getConfigOverride("format.subjectprefix")) |val| {
        subject_prefix = val;
    }
    // Also check git config file
    var config_subject_prefix: ?[]u8 = null;
    defer if (config_subject_prefix) |csp| allocator.free(csp);
    {
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);
        if (std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024)) |config_content| {
            defer allocator.free(config_content);
            if (getConfigValue(config_content, "format", "subjectprefix")) |val| {
                config_subject_prefix = try allocator.dupe(u8, val);
                subject_prefix = config_subject_prefix.?;
            }
        } else |_| {}
    }

    var all_args = std.array_list.Managed([]const u8).init(allocator);
    defer all_args.deinit();
    while (args.next()) |arg| try all_args.append(arg);

    var i: usize = 0;
    while (i < all_args.items.len) : (i += 1) {
        const arg = all_args.items[i];
        if (std.mem.eql(u8, arg, "--stdout")) {
            stdout_mode = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--numbered")) {
            numbered = true;
        } else if (std.mem.eql(u8, arg, "--no-numbered")) {
            no_numbered = true;
            numbered = null;
        } else if (std.mem.eql(u8, arg, "--cover-letter")) {
            cover_letter = true;
        } else if (std.mem.eql(u8, arg, "--attach") or std.mem.startsWith(u8, arg, "--attach=")) {
            attach = true;
        } else if (std.mem.eql(u8, arg, "--inline") or std.mem.startsWith(u8, arg, "--inline=")) {
            inline_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--suffix=")) {
            suffix = arg["--suffix=".len..];
        } else if (std.mem.eql(u8, arg, "--numbered-files")) {
            numbered_files = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--signoff")) {
            signoff = true;
        } else if (std.mem.startsWith(u8, arg, "--grep=")) {
            fp_grep_pattern = arg["--grep=".len..];
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings")) {
            fp_fixed_strings = true;
            fp_fixed_strings_explicit = true;
        } else if (std.mem.eql(u8, arg, "-G") or std.mem.eql(u8, arg, "--basic-regexp") or std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--extended-regexp")) {
            fp_fixed_strings = false;
            fp_fixed_strings_explicit = true;
        } else if (std.mem.startsWith(u8, arg, "--subject-prefix=")) {
            subject_prefix = arg["--subject-prefix=".len..];
        } else if (std.mem.startsWith(u8, arg, "--start-number=")) {
            start_number = std.fmt.parseInt(usize, arg["--start-number=".len..], 10) catch 1;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output-directory")) {
            if (i + 1 < all_args.items.len) i += 1;
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and std.ascii.isDigit(arg[1])) {
            dash_n_count = std.fmt.parseInt(usize, arg[1..], 10) catch 1;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.indexOf(u8, arg, "..") != null) {
                rev_range = arg;
            } else {
                positional_rev = arg;
            }
        }
    }

    // Build rev_range from -N and positional revision
    if (rev_range == null) {
        if (dash_n_count) |count| {
            const tip = positional_rev orelse "HEAD";
            rev_range = try std.fmt.allocPrint(allocator, "{s}~{d}..{s}", .{ tip, count, tip });
        } else if (positional_rev) |rev| {
            rev_range = rev;
        }
    }

    if (rev_range == null) {
        try pi.writeStderr("fatal: no revision range specified\n");
        std.process.exit(128);
    }

    const range = rev_range.?;
    var base_rev: []const u8 = undefined;
    var tip_rev: []const u8 = "HEAD";

    if (std.mem.indexOf(u8, range, "..")) |dot_pos| {
        const is_triple = dot_pos + 2 < range.len and range[dot_pos + 2] == '.';
        base_rev = range[0..dot_pos];
        tip_rev = if (is_triple) range[dot_pos + 3 ..] else range[dot_pos + 2 ..];
        if (tip_rev.len == 0) tip_rev = "HEAD";
    } else {
        base_rev = range;
    }

    const base_hash = git_helpers_mod.resolveRevision(git_path, base_rev, pi, allocator) catch {
        try pi.writeStderr("fatal: bad revision range\n");
        std.process.exit(128);
    };
    defer allocator.free(base_hash);

    const tip_hash = git_helpers_mod.resolveRevision(git_path, tip_rev, pi, allocator) catch {
        try pi.writeStderr("fatal: bad revision range\n");
        std.process.exit(128);
    };
    defer allocator.free(tip_hash);

    // Walk from tip to base collecting non-merge commits (BFS)
    var commit_list = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (commit_list.items) |h| allocator.free(@constCast(h));
        commit_list.deinit();
    }

    {
        var visited = std.StringHashMap(void).init(allocator);
        defer visited.deinit();
        var queue = std.array_list.Managed([]const u8).init(allocator);
        defer {
            for (queue.items) |h| allocator.free(@constCast(h));
            queue.deinit();
        }

        try queue.append(try allocator.dupe(u8, tip_hash));
        try visited.put(tip_hash, {});

        // Also mark base as visited so we stop there
        try visited.put(base_hash, {});

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);
            defer allocator.free(current);

            if (std.mem.eql(u8, current, base_hash)) continue;

            const obj = objects.GitObject.load(current, git_path, pi, allocator) catch continue;
            defer obj.deinit(allocator);

            // Extract ALL parent hashes
            var parents = std.array_list.Managed([]const u8).init(allocator);
            defer parents.deinit();
            {
                var data_remaining = obj.data;
                while (data_remaining.len > 0) {
                    if (std.mem.indexOf(u8, data_remaining, "parent ")) |pos| {
                        const line_start = pos + "parent ".len;
                        if (line_start + 40 <= data_remaining.len) {
                            const phash = data_remaining[line_start .. line_start + 40];
                            try parents.append(phash);
                        }
                        data_remaining = data_remaining[@min(line_start + 40, data_remaining.len)..];
                    } else break;
                }
            }

            // Only include non-merge commits (1 parent or 0 parents)
            if (parents.items.len <= 1) {
                try commit_list.append(try allocator.dupe(u8, current));
            }

            // Enqueue all parents
            for (parents.items) |phash| {
                if (!visited.contains(phash)) {
                    try visited.put(try allocator.dupe(u8, phash), {});
                    try queue.append(try allocator.dupe(u8, phash));
                }
            }
        }
    }

    // Read grep.patternType from config for format-patch
    if (!fp_fixed_strings_explicit) {
        if (git_helpers_mod.getConfigValueByKey(git_path, "grep.patterntype", allocator)) |pt_val| {
            if (std.ascii.eqlIgnoreCase(pt_val, "fixed")) {
                fp_fixed_strings = true;
            }
            allocator.free(pt_val);
        }
    }

    // Apply --grep filtering to format-patch commits
    if (fp_grep_pattern) |gp| {
        var filtered = std.array_list.Managed([]const u8).init(allocator);
        for (commit_list.items) |h| {
            const fobj = objects.GitObject.load(h, git_path, pi, allocator) catch {
                allocator.free(@constCast(h));
                continue;
            };
            defer fobj.deinit(allocator);
            const fmsg = extractMessage(fobj.data);
            const matched = if (fp_fixed_strings)
                std.mem.indexOf(u8, fmsg, gp) != null
            else
                logFilterMatch(fmsg, gp, false);
            if (matched) {
                try filtered.append(h);
            } else {
                allocator.free(@constCast(h));
            }
        }
        commit_list.deinit();
        commit_list = filtered;
    }

    // Sort commits by date (oldest first) for format-patch ordering
    const SortCtx = struct {
        alloc: std.mem.Allocator,
        gp: []const u8,
        platform: *const pm.Platform,
    };
    const ctx = SortCtx{ .alloc = allocator, .gp = git_path, .platform = pi };
    std.mem.sort([]const u8, commit_list.items, ctx, struct {
        fn lessThan(c: SortCtx, a: []const u8, b: []const u8) bool {
            const a_ts = getCommitTimestamp(a, c.gp, c.platform, c.alloc);
            const b_ts = getCommitTimestamp(b, c.gp, c.platform, c.alloc);
            return a_ts < b_ts;
        }
    }.lessThan);
    const total = commit_list.items.len;

    // Auto-numbering: number if more than 1 patch
    const do_number = if (no_numbered) false else if (numbered) |n| n else (total > 1);

    // Get version string (must match git version output)
    const version_str = "2.53.GIT"; // Match cmdVersion in main_common

    // Cover letter
    if (cover_letter and stdout_mode and total > 0) {
        // Use the last (tip) commit for From hash, and environment for committer info
        const last_hash = commit_list.items[total - 1];
        const last_obj = objects.GitObject.load(last_hash, git_path, pi, allocator) catch null;
        defer if (last_obj) |o| o.deinit(allocator);

        // For cover letter, use GIT_COMMITTER_NAME/EMAIL/DATE from environment
        const env_name = std.posix.getenv("GIT_COMMITTER_NAME") orelse (if (last_obj) |o| parsePersonName(extractField(o.data, "committer ")) else "Unknown");
        const env_email = std.posix.getenv("GIT_COMMITTER_EMAIL") orelse (if (last_obj) |o| parsePersonEmail(extractField(o.data, "committer ")) else "unknown@example.com");
        const env_date = std.posix.getenv("GIT_COMMITTER_DATE");
        // Build a fake committer string for date formatting
        var committer_for_date: []u8 = undefined;
        var committer_alloc: ?[]u8 = null;
        defer if (committer_alloc) |ca| allocator.free(ca);
        if (env_date) |ed| {
            // Convert env date to unix timestamp format if needed
            // GIT_COMMITTER_DATE can be "timestamp tz" or "2006-06-26 00:06:00 +0000"
            const ts_val = parseGitDateToTimestamp(ed, allocator);
            if (ts_val) |tv| {
                committer_alloc = std.fmt.allocPrint(allocator, "{s} <{s}> {s}", .{ env_name, env_email, tv }) catch null;
                if (committer_alloc) |ca| committer_for_date = ca;
            } else {
                committer_alloc = std.fmt.allocPrint(allocator, "{s} <{s}> {s}", .{ env_name, env_email, ed }) catch null;
                if (committer_alloc) |ca| committer_for_date = ca;
            }
        } else {
            const committer_raw = if (last_obj) |o| extractField(o.data, "committer ") else "";
            committer_for_date = @constCast(committer_raw);
        }

        const from_line = try std.fmt.allocPrint(allocator, "From {s} Mon Sep 17 00:00:00 2001\n", .{last_hash});
        defer allocator.free(from_line);
        try pi.writeStdout(from_line);
        const from_hdr = try std.fmt.allocPrint(allocator, "From: {s} <{s}>\n", .{ env_name, env_email });
        defer allocator.free(from_hdr);
        try pi.writeStdout(from_hdr);
        const date_rfc = formatRfc2822Date(committer_for_date, allocator);
        defer if (date_rfc) |d| allocator.free(d);
        const date_hdr = try std.fmt.allocPrint(allocator, "Date: {s}\n", .{date_rfc orelse "Thu, 1 Jan 1970 00:00:00 +0000"});
        defer allocator.free(date_hdr);
        try pi.writeStdout(date_hdr);
        const subj = try std.fmt.allocPrint(allocator, "Subject: [{s} 0/{d}] *** SUBJECT HERE ***\n", .{ subject_prefix, total });
        defer allocator.free(subj);
        try pi.writeStdout(subj);
        try pi.writeStdout("\n*** BLURB HERE ***\n\n");

        // Shortlog: group commits by author
        {
            var author_commits = std.StringHashMap(std.array_list.Managed([]const u8)).init(allocator);
            defer {
                var vit = author_commits.valueIterator();
                while (vit.next()) |list| list.deinit();
                author_commits.deinit();
            }
            for (commit_list.items) |ch| {
                const cobj = objects.GitObject.load(ch, git_path, pi, allocator) catch continue;
                defer cobj.deinit(allocator);
                const ca = extractField(cobj.data, "author ");
                const aname = parsePersonName(ca);
                const cmsg = extractMessage(cobj.data);
                const cfirst = if (std.mem.indexOf(u8, cmsg, "\n")) |nl| cmsg[0..nl] else std.mem.trimRight(u8, cmsg, "\n");
                var list = author_commits.get(aname) orelse std.array_list.Managed([]const u8).init(allocator);
                try list.append(cfirst);
                try author_commits.put(aname, list);
            }
            var ait = author_commits.iterator();
            while (ait.next()) |entry| {
                const line = try std.fmt.allocPrint(allocator, "{s} ({d}):\n", .{ entry.key_ptr.*, entry.value_ptr.items.len });
                defer allocator.free(line);
                try pi.writeStdout(line);
                for (entry.value_ptr.items) |title| {
                    const tl = try std.fmt.allocPrint(allocator, "  {s}\n", .{title});
                    defer allocator.free(tl);
                    try pi.writeStdout(tl);
                }
                try pi.writeStdout("\n");
            }
        }

        // Diffstat of all changes (base to tip)
        {
            const base_obj = objects.GitObject.load(base_hash, git_path, pi, allocator) catch null;
            defer if (base_obj) |o| o.deinit(allocator);
            const base_tree = if (base_obj) |o| extractField(o.data, "tree ") else "";

            // Get the tip tree (tip_hash may be a merge, find the actual tip)
            const tip_obj_cl = objects.GitObject.load(tip_hash, git_path, pi, allocator) catch null;
            defer if (tip_obj_cl) |o| o.deinit(allocator);
            const tip_tree = if (tip_obj_cl) |o| extractField(o.data, "tree ") else "";

            if (base_tree.len >= 40 and tip_tree.len >= 40) {
                var changes = std.array_list.Managed(FileChange).init(allocator);
                defer {
                    for (changes.items) |*c| freeChange(allocator, c);
                    changes.deinit();
                }
                collectTreeChanges(allocator, base_tree, tip_tree, "", git_path, &.{}, pi, &changes) catch {};
                if (changes.items.len > 0) {
                    try outputStat(changes.items, pi, allocator);
                    try outputSummary(changes.items, pi, allocator);
                }
            }
        }

        try pi.writeStdout("\n-- \n");
        const ver_line = try std.fmt.allocPrint(allocator, "{s}\n\n", .{version_str});
        defer allocator.free(ver_line);
        try pi.writeStdout(ver_line);
    }

    for (commit_list.items, 0..) |commit_hash, idx| {
        const obj = objects.GitObject.load(commit_hash, git_path, pi, allocator) catch continue;
        defer obj.deinit(allocator);

        const author_line = extractField(obj.data, "author ");
        const commit_msg = extractMessage(obj.data);
        const first_line = if (std.mem.indexOf(u8, commit_msg, "\n")) |nl| commit_msg[0..nl] else std.mem.trimRight(u8, commit_msg, "\n");

        const patch_num = start_number + idx;

        if (stdout_mode) {
            // From line (add extra blank line between patches)
            if (idx > 0) try pi.writeStdout("\n");
            const from_line = try std.fmt.allocPrint(allocator, "From {s} Mon Sep 17 00:00:00 2001\n", .{commit_hash});
            defer allocator.free(from_line);
            try pi.writeStdout(from_line);

            // From header
            const from_hdr = try std.fmt.allocPrint(allocator, "From: {s} <{s}>\n", .{ parsePersonName(author_line), parsePersonEmail(author_line) });
            defer allocator.free(from_hdr);
            try pi.writeStdout(from_hdr);

            // Date
            const date_rfc = formatRfc2822Date(author_line, allocator);
            defer if (date_rfc) |d| allocator.free(d);
            const date_hdr = try std.fmt.allocPrint(allocator, "Date: {s}\n", .{date_rfc orelse "Thu, 1 Jan 1970 00:00:00 +0000"});
            defer allocator.free(date_hdr);
            try pi.writeStdout(date_hdr);

            // Subject
            if (do_number) {
                const subj = try std.fmt.allocPrint(allocator, "Subject: [{s} {d}/{d}] {s}\n", .{ subject_prefix, patch_num, total, first_line });
                defer allocator.free(subj);
                try pi.writeStdout(subj);
            } else {
                const subj = try std.fmt.allocPrint(allocator, "Subject: [{s}] {s}\n", .{ subject_prefix, first_line });
                defer allocator.free(subj);
                try pi.writeStdout(subj);
            }

            // Add MIME headers if signoff contains non-ASCII characters (only for plain format)
            if (signoff and !attach and !inline_mode) {
                const sob_name = std.posix.getenv("GIT_COMMITTER_NAME") orelse parsePersonName(author_line);
                var has_non_ascii = false;
                for (sob_name) |c| {
                    if (c > 127) {
                        has_non_ascii = true;
                        break;
                    }
                }
                if (has_non_ascii) {
                    try pi.writeStdout("MIME-Version: 1.0\n");
                    try pi.writeStdout("Content-Type: text/plain; charset=UTF-8\n");
                    try pi.writeStdout("Content-Transfer-Encoding: 8bit\n");
                }
            }

            // Collect changes for stat and patch
            const parent_hash = extractField(obj.data, "parent ");
            var changes = std.array_list.Managed(FileChange).init(allocator);
            defer {
                for (changes.items) |*c| freeChange(allocator, c);
                changes.deinit();
            }
            if (parent_hash.len >= 40) {
                const cur_tree = extractField(obj.data, "tree ");
                const pobj = objects.GitObject.load(parent_hash, git_path, pi, allocator) catch null;
                defer if (pobj) |po| po.deinit(allocator);
                const par_tree = if (pobj) |po| extractField(po.data, "tree ") else "";
                if (cur_tree.len >= 40 and par_tree.len >= 40) {
                    collectTreeChanges(allocator, par_tree, cur_tree, "", git_path, &.{}, pi, &changes) catch {};
                }
            }

            if (attach or inline_mode) {
                // MIME multipart format
                const boundary = try std.fmt.allocPrint(allocator, "------------{s}", .{version_str});
                defer allocator.free(boundary);
                try pi.writeStdout("MIME-Version: 1.0\n");
                const ct = try std.fmt.allocPrint(allocator, "Content-Type: multipart/mixed; boundary=\"{s}\"\n", .{boundary});
                defer allocator.free(ct);
                try pi.writeStdout(ct);
                try pi.writeStdout("\nThis is a multi-part message in MIME format.\n");
                const sep = try std.fmt.allocPrint(allocator, "--------------{s}\n", .{version_str});
                defer allocator.free(sep);
                try pi.writeStdout(sep);
                try pi.writeStdout("Content-Type: text/plain; charset=UTF-8; format=fixed\nContent-Transfer-Encoding: 8bit\n\n");

                // Message body (preserve leading blank lines in MIME parts)
                if (std.mem.indexOf(u8, commit_msg, "\n")) |nl| {
                    var rest = commit_msg[nl + 1 ..];
                    rest = std.mem.trimRight(u8, rest, "\n");
                    if (rest.len > 0) {
                        try pi.writeStdout(rest);
                        try pi.writeStdout("\n");
                    }
                }

                // Stat section
                if (changes.items.len > 0) {
                    try pi.writeStdout("---\n");
                    try outputStat(changes.items, pi, allocator);
                    try outputSummary(changes.items, pi, allocator);
                    try pi.writeStdout("\n");
                } else {
                    try pi.writeStdout("---\n\n");
                }

                // Attachment/inline part with the diff
                const sep2 = try std.fmt.allocPrint(allocator, "\n--------------{s}\n", .{version_str});
                defer allocator.free(sep2);
                try pi.writeStdout(sep2);

                const disp_type: []const u8 = if (inline_mode) "inline" else "attachment";
                var fname: []u8 = undefined;
                if (numbered_files) {
                    fname = try std.fmt.allocPrint(allocator, "{d}", .{patch_num});
                } else {
                    // For attach/inline, git uses "NNNN-subject.patch" format
                    const sane = try sanitizeSubject(first_line, allocator);
                    defer allocator.free(sane);
                    fname = try std.fmt.allocPrint(allocator, "{d:0>4}-{s}", .{ patch_num, sane });
                }
                defer allocator.free(fname);
                const full_fname = if (numbered_files) try allocator.dupe(u8, fname) else try std.fmt.allocPrint(allocator, "{s}{s}", .{ fname, suffix });
                defer allocator.free(full_fname);
                const cd = try std.fmt.allocPrint(allocator, "Content-Type: text/x-patch; name=\"{s}\"\nContent-Transfer-Encoding: 8bit\nContent-Disposition: {s}; filename=\"{s}\"\n\n", .{ full_fname, disp_type, full_fname });
                defer allocator.free(cd);
                try pi.writeStdout(cd);

                // Output the diff in the attachment
                if (changes.items.len > 0) {
                    var diff_opts = DiffOpts{
                        .ignore_regex = std.array_list.Managed([]const u8).init(allocator),
                    };
                    defer diff_opts.ignore_regex.deinit();
                    try outputPatch(changes.items, &diff_opts, pi, allocator);
                }

                const end_sep = try std.fmt.allocPrint(allocator, "\n--------------{s}--\n\n\n", .{version_str});
                defer allocator.free(end_sep);
                try pi.writeStdout(end_sep);
            } else {
                // Plain format (no MIME)
                // Message body (everything after first line)
                try pi.writeStdout("\n");
                if (std.mem.indexOf(u8, commit_msg, "\n")) |nl| {
                    var rest = commit_msg[nl + 1 ..];
                    rest = std.mem.trimLeft(u8, rest, "\n");
                    rest = std.mem.trimRight(u8, rest, "\n");
                    if (rest.len > 0) {
                        try pi.writeStdout(rest);
                        try pi.writeStdout("\n");
                    }
                }

                // Add Signed-off-by if --signoff
                if (signoff) {
                    const sob_name_p = std.posix.getenv("GIT_COMMITTER_NAME") orelse parsePersonName(author_line);
                    const sob_email_p = std.posix.getenv("GIT_COMMITTER_EMAIL") orelse parsePersonEmail(author_line);
                    const sob_line = try std.fmt.allocPrint(allocator, "\nSigned-off-by: {s} <{s}>\n", .{ sob_name_p, sob_email_p });
                    defer allocator.free(sob_line);
                    try pi.writeStdout(sob_line);
                }

                // Stat + patch
                if (changes.items.len > 0) {
                    try pi.writeStdout("---\n");
                    try outputStat(changes.items, pi, allocator);
                    try outputSummary(changes.items, pi, allocator);
                    try pi.writeStdout("\n");
                    var diff_opts = DiffOpts{
                        .ignore_regex = std.array_list.Managed([]const u8).init(allocator),
                    };
                    defer diff_opts.ignore_regex.deinit();
                    try outputPatch(changes.items, &diff_opts, pi, allocator);
                } else {
                    try pi.writeStdout("---\n\n");
                }

                try pi.writeStdout("-- \n");
                const ver_line = try std.fmt.allocPrint(allocator, "{s}\n\n", .{version_str});
                defer allocator.free(ver_line);
                try pi.writeStdout(ver_line);
            }
        } else {
            // Write to file - use --stdout mode to capture content, then write to disk
            const sane_subj = sanitizeSubject(first_line, allocator) catch {
                try pi.writeStdout("0001-patch.patch\n");
                continue;
            };
            defer allocator.free(sane_subj);
            const filename = try std.fmt.allocPrint(allocator, "{d:0>4}-{s}{s}", .{ patch_num, sane_subj, suffix });
            defer allocator.free(filename);

            // Collect tree changes
            const parent_hash_f = extractField(obj.data, "parent ");
            var changes_f = std.array_list.Managed(FileChange).init(allocator);
            defer {
                for (changes_f.items) |*c| freeChange(allocator, c);
                changes_f.deinit();
            }
            if (parent_hash_f.len >= 40) {
                const cur_tree_f = extractField(obj.data, "tree ");
                const pobj_f = objects.GitObject.load(parent_hash_f, git_path, pi, allocator) catch null;
                defer if (pobj_f) |po| po.deinit(allocator);
                const par_tree_f = if (pobj_f) |po| extractField(po.data, "tree ") else "";
                if (cur_tree_f.len >= 40 and par_tree_f.len >= 40) {
                    collectTreeChanges(allocator, par_tree_f, cur_tree_f, "", git_path, &.{}, pi, &changes_f) catch {};
                }
            }

            var file_buf = std.array_list.Managed(u8).init(allocator);
            defer file_buf.deinit();
            const w = file_buf.writer();

            try w.print("From {s} Mon Sep 17 00:00:00 2001\n", .{commit_hash});
            try w.print("From: {s} <{s}>\n", .{ parsePersonName(author_line), parsePersonEmail(author_line) });
            const date_rfc_f = formatRfc2822Date(author_line, allocator);
            defer if (date_rfc_f) |d| allocator.free(d);
            try w.print("Date: {s}\n", .{date_rfc_f orelse "Thu, 1 Jan 1970 00:00:00 +0000"});
            if (do_number) {
                try w.print("Subject: [{s} {d}/{d}] {s}\n", .{ subject_prefix, patch_num, total, first_line });
            } else {
                try w.print("Subject: [{s}] {s}\n", .{ subject_prefix, first_line });
            }
            try w.print("\n{s}\n", .{std.mem.trimRight(u8, commit_msg, "\n ")});
            if (signoff) {
                const sob_n = std.posix.getenv("GIT_COMMITTER_NAME") orelse parsePersonName(author_line);
                const sob_e = std.posix.getenv("GIT_COMMITTER_EMAIL") orelse parsePersonEmail(author_line);
                try w.print("\nSigned-off-by: {s} <{s}>\n", .{ sob_n, sob_e });
            }
            try w.print("---\n", .{});
            // Generate stat and diff content
            if (changes_f.items.len > 0) {
                // Stat
                for (changes_f.items) |fc| {
                    const ins = fc.insertions;
                    const del = fc.deletions;
                    const path = fc.path;
                    if (fc.is_binary) {
                        try w.print(" {s} | Bin\n", .{path});
                    } else {
                        try w.print(" {s} | {d}", .{ path, ins + del });
                        if (ins > 0) { var j: usize = 0; while (j < ins) : (j += 1) try w.writeByte('+'); }
                        if (del > 0) { var j: usize = 0; while (j < del) : (j += 1) try w.writeByte('-'); }
                        try w.writeByte('\n');
                    }
                }
                try w.print(" {d} file{s} changed\n\n", .{ changes_f.items.len, if (changes_f.items.len != 1) @as([]const u8, "s") else @as([]const u8, "") });
                // Patch
                for (changes_f.items) |fc| {
                    if (fc.is_new) {
                        try w.print("diff --git a/{s} b/{s}\nnew file mode {s}\n--- /dev/null\n+++ b/{s}\n", .{ fc.path, fc.path, fc.new_mode, fc.path });
                    } else if (fc.is_deleted) {
                        try w.print("diff --git a/{s} b/{s}\ndeleted file mode {s}\n--- a/{s}\n+++ /dev/null\n", .{ fc.path, fc.path, fc.old_mode, fc.path });
                    } else {
                        try w.print("diff --git a/{s} b/{s}\n--- a/{s}\n+++ b/{s}\n", .{ fc.path, fc.path, fc.path, fc.path });
                    }
                    // Generate unified diff from old/new content
                    const diff_text = diff_mod.generateUnifiedDiffWithHashesAndContext(fc.old_content, fc.new_content, fc.path, "", "", 3, allocator) catch "";
                    defer if (diff_text.len > 0) allocator.free(diff_text);
                    if (diff_text.len > 0) try w.print("{s}", .{diff_text});
                }
            } else {
                try w.print("\n", .{});
            }
            try w.print("-- \n{s}\n\n", .{version_str});

            pi.fs.writeFile(filename, file_buf.items) catch {};
            const out_msg = try std.fmt.allocPrint(allocator, "{s}\n", .{filename});
            defer allocator.free(out_msg);
            try pi.writeStdout(out_msg);
        }
    }
}

fn sanitizeSubject(subject: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    for (subject) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            try result.append(c);
        } else if (c == ' ') {
            try result.append('-');
        }
        // Skip other chars
    }
    return try allocator.dupe(u8, result.items);
}

fn getCommitTimestamp(hash: []const u8, gpath: []const u8, platform: *const pm.Platform, alloc: std.mem.Allocator) i64 {
    const obj = objects.GitObject.load(hash, gpath, platform, alloc) catch return 0;
    defer obj.deinit(alloc);
    const author = extractField(obj.data, "author ");
    // Parse timestamp from author line: "Name <email> timestamp timezone"
    var it = std.mem.splitBackwardsScalar(u8, author, ' ');
    _ = it.next(); // timezone
    const ts_str = it.next() orelse return 0;
    return std.fmt.parseInt(i64, ts_str, 10) catch 0;
}

fn getConfigValue(content: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    var in_section = false;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '[') {
            // Check section
            const section_match = std.fmt.allocPrint(std.heap.page_allocator, "[{s}]", .{section}) catch continue;
            defer std.heap.page_allocator.free(section_match);
            in_section = std.ascii.eqlIgnoreCase(trimmed, section_match);
            continue;
        }
        if (in_section) {
            if (std.mem.indexOf(u8, trimmed, "=")) |eq| {
                const k = std.mem.trim(u8, trimmed[0..eq], " \t");
                if (std.ascii.eqlIgnoreCase(k, key)) {
                    return std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
                }
            }
        }
    }
    return null;
}
