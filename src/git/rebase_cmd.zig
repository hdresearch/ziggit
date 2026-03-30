const git_helpers_mod = @import("../git_helpers.zig");
// rebase_cmd.zig - Full git rebase implementation with interactive support
const std = @import("std");
const objects = @import("objects.zig");
const refs = @import("refs.zig");
const index_mod = @import("index.zig");
const platform_mod = @import("../platform/platform.zig");
const main_common = @import("../main_common.zig");

const Platform = platform_mod.Platform;

// ============================================================================
// Public entry point
// ============================================================================

pub fn nativeCmdRebase(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const Platform) !void {
    const git_path = try git_helpers_mod.findGitDirectory(allocator, platform_impl);
    defer allocator.free(git_path);
    const repo_root = std.fs.path.dirname(git_path) orelse ".";

    // Parse arguments
    var opts = try parseRebaseArgs(allocator, args, command_index, platform_impl);
    defer opts.deinit(allocator);

    // Handle --quit
    if (opts.do_quit) {
        if (!hasRebaseInProgress(git_path, allocator)) {
            try platform_impl.writeStderr("fatal: no rebase in progress\n");
            std.process.exit(1);
        }
        cleanupRebaseState(git_path, allocator);
        return;
    }

    // Handle --abort
    if (opts.do_abort) {
        try rebaseAbort(git_path, repo_root, allocator, platform_impl);
        return;
    }

    // Handle --continue
    if (opts.do_continue) {
        try rebaseContinue(git_path, repo_root, allocator, platform_impl, opts.quiet);
        return;
    }

    // Handle --skip
    if (opts.do_skip) {
        try rebaseSkip(git_path, repo_root, allocator, platform_impl, opts.quiet);
        return;
    }

    // Handle --show-current-patch
    if (opts.show_current_patch) {
        try rebaseShowCurrentPatch(git_path, allocator, platform_impl);
        return;
    }

    // Start a new rebase
    try startRebase(git_path, repo_root, allocator, platform_impl, &opts);
}

// ============================================================================
// Argument parsing
// ============================================================================

const RebaseOpts = struct {
    onto: ?[]const u8 = null,
    upstream_arg: ?[]const u8 = null,
    branch_arg: ?[]const u8 = null,
    do_continue: bool = false,
    do_abort: bool = false,
    do_skip: bool = false,
    do_quit: bool = false,
    show_current_patch: bool = false,
    quiet: bool = false,
    force_rebase: bool = false,
    apply_mode: bool = false,
    merge_mode: bool = false,
    keep_base: bool = false,
    interactive: bool = false,
    has_exec: bool = false,
    exec_cmds: std.array_list.Managed([]const u8),
    has_rebase_merges: bool = false,
    has_update_refs: bool = false,
    has_root: bool = false,
    has_strategy: bool = false,
    has_strategy_option: bool = false,
    strategy_option: ?[]const u8 = null,
    has_autosquash: bool = false,
    has_keep_empty: bool = false,
    has_empty: bool = false,
    has_reapply_cherry_picks: bool = false,
    has_no_reapply_cherry_picks: bool = false,
    whitespace_opt: bool = false,
    no_stat: bool = false,
    stat: bool = false,
    verbose: bool = false,
    original_upstream_display: ?[]const u8 = null,
    resolved_dash_upstream: ?[]u8 = null,
    reschedule_failed_exec: ?bool = null,

    fn deinit(self: *RebaseOpts, allocator: std.mem.Allocator) void {
        if (self.resolved_dash_upstream) |r| allocator.free(r);
        self.exec_cmds.deinit();
    }
};

fn parseRebaseArgs(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const Platform) !RebaseOpts {
    var opts = RebaseOpts{
        .exec_cmds = std.array_list.Managed([]const u8).init(allocator),
    };
    var positionals = std.array_list.Managed([]const u8).init(allocator);
    defer positionals.deinit();

    var i: usize = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--continue")) {
            opts.do_continue = true;
        } else if (std.mem.eql(u8, arg, "--abort")) {
            opts.do_abort = true;
        } else if (std.mem.eql(u8, arg, "--skip")) {
            opts.do_skip = true;
        } else if (std.mem.eql(u8, arg, "--quit")) {
            opts.do_quit = true;
        } else if (std.mem.eql(u8, arg, "--show-current-patch")) {
            opts.show_current_patch = true;
        } else if (std.mem.eql(u8, arg, "--onto")) {
            i += 1;
            if (i < args.len) opts.onto = args[i];
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force-rebase") or std.mem.eql(u8, arg, "--no-ff")) {
            opts.force_rebase = true;
        } else if (std.mem.eql(u8, arg, "--apply")) {
            opts.apply_mode = true;
        } else if (std.mem.eql(u8, arg, "--merge") or std.mem.eql(u8, arg, "-m")) {
            opts.merge_mode = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--no-stat")) {
            opts.no_stat = true;
        } else if (std.mem.eql(u8, arg, "--stat")) {
            opts.stat = true;
        } else if (std.mem.startsWith(u8, arg, "--whitespace=")) {
            const ws_val = arg["--whitespace=".len..];
            const valid_ws = [_][]const u8{ "nowarn", "warn", "fix", "error", "error-all" };
            var ws_valid = false;
            for (valid_ws) |v| {
                if (std.mem.eql(u8, ws_val, v)) {
                    ws_valid = true;
                    break;
                }
            }
            if (!ws_valid) {
                const ws_err = try std.fmt.allocPrint(allocator, "fatal: Invalid whitespace option: '{s}'\n", .{ws_val});
                defer allocator.free(ws_err);
                try platform_impl.writeStderr(ws_err);
                std.process.exit(1);
            }
            opts.apply_mode = true;
            opts.whitespace_opt = true;
        } else if (std.mem.eql(u8, arg, "--whitespace")) {
            opts.apply_mode = true;
            opts.whitespace_opt = true;
        } else if (std.mem.startsWith(u8, arg, "--strategy=") or std.mem.eql(u8, arg, "-s")) {
            opts.has_strategy = true;
            opts.merge_mode = true;
            if (std.mem.eql(u8, arg, "-s")) {
                i += 1;
            }
        } else if (std.mem.startsWith(u8, arg, "--strategy-option=")) {
            opts.has_strategy_option = true;
            opts.strategy_option = arg["--strategy-option=".len..];
            opts.merge_mode = true;
        } else if (std.mem.eql(u8, arg, "--strategy-option") or std.mem.eql(u8, arg, "-X")) {
            opts.has_strategy_option = true;
            opts.merge_mode = true;
            if (i + 1 < args.len) {
                i += 1;
                opts.strategy_option = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--autosquash") or std.mem.eql(u8, arg, "--no-autosquash")) {
            opts.has_autosquash = true;
            opts.merge_mode = true;
        } else if (std.mem.eql(u8, arg, "--keep-empty") or std.mem.eql(u8, arg, "--no-keep-empty")) {
            opts.has_keep_empty = true;
            opts.merge_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--empty")) {
            opts.has_empty = true;
            opts.merge_mode = true;
        } else if (std.mem.eql(u8, arg, "--no-reapply-cherry-picks")) {
            opts.has_no_reapply_cherry_picks = true;
        } else if (std.mem.eql(u8, arg, "--reapply-cherry-picks")) {
            opts.has_reapply_cherry_picks = true;
        } else if (std.mem.eql(u8, arg, "--rebase-merges") or std.mem.startsWith(u8, arg, "--rebase-merges=")) {
            opts.has_rebase_merges = true;
            opts.merge_mode = true;
        } else if (std.mem.eql(u8, arg, "--root")) {
            opts.has_root = true;
        } else if (std.mem.eql(u8, arg, "--exec") or std.mem.eql(u8, arg, "-x")) {
            i += 1;
            if (i < args.len) {
                const exec_cmd = args[i];
                const trimmed_exec = std.mem.trim(u8, exec_cmd, " \t");
                if (trimmed_exec.len == 0) {
                    try platform_impl.writeStderr("error: empty exec command\n");
                    std.process.exit(1);
                }
                if (std.mem.indexOfScalar(u8, exec_cmd, '\n') != null) {
                    try platform_impl.writeStderr("error: exec commands cannot contain newlines\n");
                    std.process.exit(1);
                }
                try opts.exec_cmds.append(exec_cmd);
            }
            opts.has_exec = true;
            opts.merge_mode = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interactive")) {
            opts.interactive = true;
            opts.merge_mode = true;
        } else if (std.mem.eql(u8, arg, "--update-refs")) {
            opts.has_update_refs = true;
            opts.merge_mode = true;
        } else if (std.mem.eql(u8, arg, "--keep-base")) {
            opts.keep_base = true;
        } else if (std.mem.eql(u8, arg, "--no-fork-point") or std.mem.eql(u8, arg, "--fork-point")) {
            // ignore for now
        } else if (std.mem.startsWith(u8, arg, "-C") and arg.len > 2) {
            _ = std.fmt.parseInt(i32, arg[2..], 10) catch {
                try platform_impl.writeStderr("fatal: switch `C' expects a numerical value\n");
                std.process.exit(1);
            };
            opts.apply_mode = true;
        } else if (std.mem.eql(u8, arg, "--reschedule-failed-exec")) {
            opts.reschedule_failed_exec = true;
        } else if (std.mem.eql(u8, arg, "--no-reschedule-failed-exec")) {
            opts.reschedule_failed_exec = false;
        } else if (std.mem.startsWith(u8, arg, "-c")) {
            // skip -c key=value
        } else if (std.mem.eql(u8, arg, "-")) {
            try positionals.append(arg);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try positionals.append(arg);
        }
    }

    // Config-based options
    checkConfigOptions(allocator, &opts, platform_impl);

    // Check incompatible options
    if (opts.apply_mode or opts.whitespace_opt) {
        const apply_opt_name: []const u8 = if (opts.whitespace_opt) "--whitespace=..." else "--apply";
        const incompat_pairs = [_]struct { flag: bool, name: []const u8 }{
            .{ .flag = opts.merge_mode and !opts.apply_mode, .name = "--merge" },
            .{ .flag = opts.has_strategy, .name = "--strategy" },
            .{ .flag = opts.has_strategy_option, .name = "--strategy-option" },
            .{ .flag = opts.has_autosquash, .name = "--autosquash" },
            .{ .flag = opts.interactive, .name = "--interactive" },
            .{ .flag = opts.has_exec, .name = "--exec" },
            .{ .flag = opts.has_keep_empty, .name = "--keep-empty" },
            .{ .flag = opts.has_empty, .name = "--empty" },
            .{ .flag = opts.has_no_reapply_cherry_picks, .name = "--no-reapply-cherry-picks" },
            .{ .flag = opts.has_reapply_cherry_picks, .name = "--reapply-cherry-picks" },
            .{ .flag = opts.has_rebase_merges, .name = "--rebase-merges" },
            .{ .flag = opts.has_update_refs, .name = "--update-refs" },
            .{ .flag = opts.has_root, .name = "--root" },
        };
        for (incompat_pairs) |pair| {
            if (pair.flag) {
                const emsg = try std.fmt.allocPrint(allocator, "fatal: {s} is incompatible with {s}\n", .{ apply_opt_name, pair.name });
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(1);
            }
        }
    }

    if (positionals.items.len >= 1) opts.upstream_arg = positionals.items[0];
    if (positionals.items.len >= 2) opts.branch_arg = positionals.items[1];

    return opts;
}

fn checkConfigOptions(allocator: std.mem.Allocator, opts: *RebaseOpts, platform_impl: *const Platform) void {
    const git_path = git_helpers_mod.findGitDirectory(allocator, platform_impl) catch return;
    defer allocator.free(git_path);

    if (!opts.has_rebase_merges) {
        if (git_helpers_mod.getConfigOverride("rebase.rebasemerges")) |val| {
            const trimmed = std.mem.trim(u8, val, " \t\r\n");
            if (!std.mem.eql(u8, trimmed, "false") and trimmed.len > 0) {
                opts.has_rebase_merges = true;
            }
        }
    }
    if (!opts.has_update_refs) {
        if (git_helpers_mod.getConfigOverride("rebase.updaterefs")) |val| {
            const trimmed = std.mem.trim(u8, val, " \t\r\n");
            if (std.mem.eql(u8, trimmed, "true")) {
                opts.has_update_refs = true;
            }
        }
    }

    const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch return;
    defer allocator.free(config_path);
    const config_content = platform_impl.fs.readFile(allocator, config_path) catch return;
    defer allocator.free(config_content);

    if (!opts.has_rebase_merges) {
        if (findConfigValue(config_content, "rebase", null, "rebasemerges")) |val| {
            const trimmed = std.mem.trim(u8, val, " \t\r\n");
            if (!std.mem.eql(u8, trimmed, "false") and trimmed.len > 0) {
                opts.has_rebase_merges = true;
            }
        }
    }
    if (!opts.has_update_refs) {
        if (findConfigValue(config_content, "rebase", null, "updaterefs")) |val| {
            const trimmed = std.mem.trim(u8, val, " \t\r\n");
            if (std.mem.eql(u8, trimmed, "true")) {
                opts.has_update_refs = true;
            }
        }
    }
}

// ============================================================================
// Start a new rebase
// ============================================================================

fn startRebase(git_path: []const u8, repo_root: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform, opts: *RebaseOpts) !void {
    // Resolve "-" to previous branch
    if (opts.upstream_arg != null and std.mem.eql(u8, opts.upstream_arg.?, "-")) {
        opts.original_upstream_display = "@{-1}";
        opts.resolved_dash_upstream = resolvePreviousBranch(git_path, 1, allocator, platform_impl) catch null;
        if (opts.resolved_dash_upstream) |rb| {
            opts.upstream_arg = rb;
        }
    }

    // If branch_arg is given, switch to it first
    if (opts.branch_arg) |branch| {
        const branch_hash = git_helpers_mod.resolveRevision(git_path, branch, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: no such branch/commit '{s}'\n", .{branch});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        defer allocator.free(branch_hash);

        const is_branch = refs.branchExists(git_path, branch, platform_impl, allocator) catch false;
        if (is_branch) {
            checkoutCommitTree(git_path, branch_hash, allocator, platform_impl) catch {};
            try refs.updateHEAD(git_path, branch, platform_impl, allocator);
        } else {
            checkoutCommitTree(git_path, branch_hash, allocator, platform_impl) catch {};
            try refs.updateHEAD(git_path, branch_hash, platform_impl, allocator);
        }
    }

    // Resolve upstream
    var upstream_hash: []u8 = undefined;
    if (opts.upstream_arg) |ua| {
        upstream_hash = git_helpers_mod.resolveRevision(git_path, ua, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: invalid upstream '{s}'\n", .{ua});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
    } else {
        const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch {
            try platform_impl.writeStderr("fatal: no rebase branch and no upstream configured\n");
            std.process.exit(128);
        };
        defer allocator.free(current_branch);

        if (std.mem.eql(u8, current_branch, "HEAD")) {
            try platform_impl.writeStderr("fatal: You are not currently on a branch.\n");
            std.process.exit(128);
        }

        upstream_hash = getConfiguredUpstream(git_path, current_branch, allocator, platform_impl) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: no upstream configured for branch '{s}'\n", .{current_branch});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };
    }
    defer allocator.free(upstream_hash);

    // Get current HEAD
    const head_hash = refs.getCurrentCommit(git_path, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: cannot read HEAD\n");
        std.process.exit(128);
    } orelse {
        try platform_impl.writeStderr("fatal: HEAD is not set\n");
        std.process.exit(128);
    };
    defer allocator.free(head_hash);

    const current_branch_name = refs.getCurrentBranch(git_path, platform_impl, allocator) catch try allocator.dupe(u8, "HEAD");
    defer allocator.free(current_branch_name);

    // Check for dirty worktree/index
    try checkRebaseClean(git_path, repo_root, head_hash, allocator, platform_impl);

    // Determine onto target
    const onto_hash = try resolveOnto(git_path, opts.onto, opts.keep_base, head_hash, upstream_hash, allocator, platform_impl);
    defer allocator.free(onto_hash);

    // Find merge base
    const merge_base = findMergeBase(git_path, head_hash, upstream_hash, allocator, platform_impl) catch try allocator.dupe(u8, upstream_hash);
    defer allocator.free(merge_base);

    // Collect commits to replay
    var commits_to_replay = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (commits_to_replay.items) |c| allocator.free(c);
        commits_to_replay.deinit();
    }
    try collectCommitsToReplay(git_path, head_hash, merge_base, &commits_to_replay, allocator, platform_impl);

    // Detect noop/fast-forward
    const is_fast_forward = commits_to_replay.items.len == 0 and
        !std.mem.eql(u8, head_hash, onto_hash) and
        std.mem.eql(u8, merge_base, head_hash);
    const is_noop = blk: {
        if (is_fast_forward) break :blk false;
        if (commits_to_replay.items.len == 0 and std.mem.eql(u8, head_hash, onto_hash))
            break :blk true;
        // onto == merge_base and onto == head means HEAD is already on the right base with nothing to replay
        if (commits_to_replay.items.len == 0 and std.mem.eql(u8, onto_hash, merge_base))
            break :blk true;
        // When there are commits, check if they're already based on onto
        if (commits_to_replay.items.len > 0 and opts.onto == null and std.mem.eql(u8, onto_hash, merge_base))
            break :blk true;
        break :blk false;
    };

    const is_interactive = opts.interactive or opts.has_exec;
    const force = opts.force_rebase or opts.has_exec;
    if (is_noop and !force and !is_interactive) {
        if (!opts.quiet) {
            const msg = try std.fmt.allocPrint(allocator, "Current branch {s} is up to date.\n", .{current_branch_name});
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        }
        return;
    }
    if (is_noop and force) {
        if (!opts.quiet) {
            const msg = try std.fmt.allocPrint(allocator, "Current branch {s} is up to date, rebase forced.\n", .{current_branch_name});
            defer allocator.free(msg);
            if (opts.apply_mode) {
                try platform_impl.writeStdout(msg);
            } else {
                try platform_impl.writeStderr(msg);
            }
        }
    }

    // Fast-forward case
    if (is_fast_forward and !force) {
        try doFastForward(git_path, head_hash, onto_hash, current_branch_name, opts, allocator, platform_impl);
        return;
    }

    // Set ORIG_HEAD
    const orig_head_path = try std.fmt.allocPrint(allocator, "{s}/ORIG_HEAD", .{git_path});
    defer allocator.free(orig_head_path);
    const orig_head_content = try std.fmt.allocPrint(allocator, "{s}\n", .{head_hash});
    defer allocator.free(orig_head_content);
    platform_impl.fs.writeFile(orig_head_path, orig_head_content) catch {};

    // Determine if interactive (merge_mode implies merge backend which uses rebase-merge dir)
    const use_merge_backend = opts.merge_mode or opts.interactive or opts.has_exec or !opts.apply_mode;

    // Generate todo list
    var todo = std.array_list.Managed(u8).init(allocator);
    defer todo.deinit();
    for (commits_to_replay.items) |c| {
        const subject = getCommitSubject(c, git_path, platform_impl, allocator) catch try allocator.dupe(u8, "");
        defer allocator.free(subject);
        try todo.appendSlice("pick ");
        try todo.appendSlice(c);
        try todo.append(' ');
        try todo.appendSlice(subject);
        try todo.append('\n');
    }

    // Add exec commands after each pick if --exec was specified
    if (opts.has_exec and opts.exec_cmds.items.len > 0) {
        var new_todo = std.array_list.Managed(u8).init(allocator);
        defer new_todo.deinit();
        var lines = std.mem.splitScalar(u8, todo.items, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try new_todo.appendSlice(line);
            try new_todo.append('\n');
            if (std.mem.startsWith(u8, line, "pick ") or std.mem.startsWith(u8, line, "p ")) {
                for (opts.exec_cmds.items) |cmd| {
                    try new_todo.appendSlice("exec ");
                    try new_todo.appendSlice(cmd);
                    try new_todo.append('\n');
                }
            }
        }
        todo.clearRetainingCapacity();
        try todo.appendSlice(new_todo.items);
    }

    // Add Rebase comment to todo for interactive mode
    if (is_interactive) {
        // Count commands
        var cmd_count: usize = 0;
        var count_lines = std.mem.splitScalar(u8, todo.items, '\n');
        while (count_lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0 and trimmed[0] != '#') cmd_count += 1;
        }
        const short_base = upstream_hash[0..@min(7, upstream_hash.len)];
        const short_head = head_hash[0..@min(7, head_hash.len)];
        const short_onto = onto_hash[0..@min(7, onto_hash.len)];
        const comment = try std.fmt.allocPrint(allocator, "\n# Rebase {s}..{s} onto {s} ({d} command{s})\n", .{
            short_base, short_head, short_onto, cmd_count, if (cmd_count != 1) "s" else "",
        });
        defer allocator.free(comment);
        try todo.appendSlice(comment);
    }

    // Save rebase state
    try saveRebaseState(git_path, todo.items, onto_hash, head_hash, current_branch_name, upstream_hash, !use_merge_backend, opts, allocator, platform_impl);

    // If interactive (explicitly -i), invoke sequence editor
    if (opts.interactive) {
        const todo_path = try std.fmt.allocPrint(allocator, "{s}/rebase-merge/git-rebase-todo", .{git_path});
        defer allocator.free(todo_path);

        const editor_result = try invokeSequenceEditor(todo_path, git_path, allocator, platform_impl);
        if (!editor_result) {
            // Editor returned non-zero, abort
            cleanupRebaseState(git_path, allocator);
            try platform_impl.writeStderr("rebase aborted\n");
            return;
        }

        // Re-read the possibly modified todo
        const new_todo = platform_impl.fs.readFile(allocator, todo_path) catch {
            cleanupRebaseState(git_path, allocator);
            return;
        };
        defer allocator.free(new_todo);

        // Check if todo is empty, noop, or unchanged from original
        var has_action = false;
        var has_non_pick_action = false;
        var todo_pick_count: usize = 0;
        var check_lines = std.mem.splitScalar(u8, new_todo, '\n');
        while (check_lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0 and trimmed[0] != '#') {
                if (std.mem.eql(u8, trimmed, "noop")) continue;
                has_action = true;
                if (std.mem.startsWith(u8, trimmed, "pick ") or std.mem.startsWith(u8, trimmed, "p ")) {
                    todo_pick_count += 1;
                } else {
                    has_non_pick_action = true;
                }
            }
        }
        // If noop: todo has no actions, or only picks that match original (same order)
        if (!has_action) {
            // Nothing to do - this is an error in interactive mode
            try platform_impl.writeStderr("error: nothing to do\n");
            cleanupRebaseState(git_path, allocator);
            // Restore original branch
            if (!std.mem.eql(u8, current_branch_name, "HEAD")) {
                refs.updateHEAD(git_path, current_branch_name, platform_impl, allocator) catch {};
            }
            std.process.exit(1);
        }

        // If was originally noop and editor didn't change the order/actions,
        // and we're not forcing rebase, treat as noop
        if (is_noop and !opts.force_rebase and !has_non_pick_action and todo_pick_count == commits_to_replay.items.len) {
            var is_same_order = true;
            var todo_idx: usize = 0;
            var check_lines2 = std.mem.splitScalar(u8, new_todo, '\n');
            while (check_lines2.next()) |line| {
                const trimmed2 = std.mem.trim(u8, line, " \t\r");
                if (trimmed2.len == 0 or trimmed2[0] == '#') continue;
                if (std.mem.eql(u8, trimmed2, "noop")) continue;
                if (std.mem.startsWith(u8, trimmed2, "pick ") or std.mem.startsWith(u8, trimmed2, "p ")) {
                    if (todo_idx < commits_to_replay.items.len) {
                        const after_cmd = std.mem.trimLeft(u8, trimmed2[if (trimmed2[0] == 'p' and trimmed2.len > 1 and trimmed2[1] == 'i') @as(usize, 5) else @as(usize, 2)..], " ");
                        const space = std.mem.indexOfScalar(u8, after_cmd, ' ') orelse after_cmd.len;
                        const hash = after_cmd[0..space];
                        if (!std.mem.startsWith(u8, commits_to_replay.items[todo_idx], hash) and
                            !std.mem.startsWith(u8, hash, commits_to_replay.items[todo_idx]))
                        {
                            is_same_order = false;
                        }
                        todo_idx += 1;
                    }
                }
            }
            if (is_same_order) {
                cleanupRebaseState(git_path, allocator);
                if (!opts.quiet) {
                    try platform_impl.writeStderr("Successfully rebased and updated refs/heads/");
                    try platform_impl.writeStderr(current_branch_name);
                    try platform_impl.writeStderr(".\n");
                }
                return;
            }
        }
    }

    // Check for untracked files that would be overwritten by checkout to onto
    {
        const onto_tree = getCommitTree(git_path, onto_hash, allocator, platform_impl) catch null;
        defer if (onto_tree) |ot| allocator.free(ot);
        const head_tree = getCommitTree(git_path, head_hash, allocator, platform_impl) catch null;
        defer if (head_tree) |ht| allocator.free(ht);

        if (onto_tree) |ot| {
            var onto_entries = std.StringHashMap(FileEntry).init(allocator);
            defer onto_entries.deinit();
            collectTreeEntriesFlat(git_path, ot, "", &onto_entries, allocator, platform_impl) catch {};

            var head_entries = std.StringHashMap(FileEntry).init(allocator);
            defer head_entries.deinit();
            if (head_tree) |ht| {
                collectTreeEntriesFlat(git_path, ht, "", &head_entries, allocator, platform_impl) catch {};
            }

            // Also load index to check tracked files
            var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch null;
            defer if (idx) |*i| i.deinit();
            var indexed_paths = std.StringHashMap(void).init(allocator);
            defer indexed_paths.deinit();
            if (idx) |i| {
                for (i.entries.items) |ie| {
                    indexed_paths.put(ie.path, {}) catch {};
                }
            }

            var untracked_conflicts = std.array_list.Managed([]const u8).init(allocator);
            defer untracked_conflicts.deinit();

            var it = onto_entries.iterator();
            while (it.next()) |entry| {
                const path = entry.key_ptr.*;
                // If the file is in onto but not in HEAD's tree AND not in index, check if it exists on disk
                if (head_entries.get(path) == null and indexed_paths.get(path) == null) {
                    const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path }) catch continue;
                    defer allocator.free(full_path);
                    if (platform_impl.fs.readFile(allocator, full_path)) |disk_content| {
                        defer allocator.free(disk_content);
                        // Compare with blob content - if same, no conflict
                        const onto_entry = entry.value_ptr.*;
                        var hex: [40]u8 = undefined;
                        for (onto_entry.sha1, 0..) |b, bi| {
                            const hx = "0123456789abcdef";
                            hex[bi * 2] = hx[b >> 4];
                            hex[bi * 2 + 1] = hx[b & 0xf];
                        }
                        const blob_obj = objects.GitObject.load(&hex, git_path, platform_impl, allocator) catch {
                            untracked_conflicts.append(path) catch {};
                            continue;
                        };
                        defer blob_obj.deinit(allocator);
                        if (blob_obj.type == .blob and std.mem.eql(u8, blob_obj.data, disk_content)) {
                            // Content matches - not a conflict
                        } else {
                            untracked_conflicts.append(path) catch {};
                        }
                    } else |_| {}
                }
            }

            if (untracked_conflicts.items.len > 0) {
                try platform_impl.writeStderr("error: The following untracked working tree files would be overwritten by checkout:\n");
                for (untracked_conflicts.items) |path| {
                    const msg = std.fmt.allocPrint(allocator, "\t{s}\n", .{path}) catch continue;
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                }
                try platform_impl.writeStderr("Please move or remove them before you switch branches.\nAborting\n");
                cleanupRebaseState(git_path, allocator);
                std.process.exit(1);
            }
        }
    }

    // Detach HEAD at onto
    try refs.updateHEAD(git_path, onto_hash, platform_impl, allocator);
    checkoutCommitTree(git_path, onto_hash, allocator, platform_impl) catch {};

    // Write reflog start entry
    const reflog_action = getReflogAction(allocator);
    defer allocator.free(reflog_action);
    const upstream_name = if (opts.onto != null) (opts.onto orelse "upstream") else (opts.original_upstream_display orelse opts.upstream_arg orelse "upstream");
    const start_msg = try std.fmt.allocPrint(allocator, "{s} (start): checkout {s}", .{ reflog_action, upstream_name });
    defer allocator.free(start_msg);
    writeReflogEntry(git_path, "HEAD", head_hash, onto_hash, start_msg, allocator, platform_impl) catch {};

    // Execute the todo list
    try executeTodoList(git_path, repo_root, current_branch_name, opts.quiet, !use_merge_backend, opts, allocator, platform_impl);
}

// ============================================================================
// Todo list execution - the core interactive rebase engine
// ============================================================================

const TodoCmd = enum {
    pick,
    reword,
    edit,
    squash,
    fixup,
    exec,
    break_cmd,
    drop,
    label,
    reset,
    merge,
    noop,
};

const TodoItem = struct {
    cmd: TodoCmd,
    hash: []const u8,
    rest: []const u8, // full original line remainder (for exec, message, etc)
    original_line: []const u8,
};

fn parseTodoItems(todo_content: []const u8, allocator: std.mem.Allocator) !std.array_list.Managed(TodoItem) {
    var items = std.array_list.Managed(TodoItem).init(allocator);
    var lines = std.mem.splitScalar(u8, todo_content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (parseSingleTodo(trimmed)) |item| {
            try items.append(item);
        }
    }
    return items;
}

fn parseSingleTodo(trimmed: []const u8) ?TodoItem {
    // exec command
    if (std.mem.startsWith(u8, trimmed, "exec ") or std.mem.startsWith(u8, trimmed, "x ")) {
        const rest_start = if (trimmed[0] == 'x') @as(usize, 2) else @as(usize, 5);
        return TodoItem{
            .cmd = .exec,
            .hash = "",
            .rest = trimmed[rest_start..],
            .original_line = trimmed,
        };
    }
    // break command
    if (std.mem.eql(u8, trimmed, "break") or std.mem.eql(u8, trimmed, "b")) {
        return TodoItem{
            .cmd = .break_cmd,
            .hash = "",
            .rest = "",
            .original_line = trimmed,
        };
    }
    // noop
    if (std.mem.eql(u8, trimmed, "noop")) {
        return TodoItem{
            .cmd = .noop,
            .hash = "",
            .rest = "",
            .original_line = trimmed,
        };
    }

    // <cmd> <hash> [message]
    const space1 = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return null;
    const cmd_str = trimmed[0..space1];
    const after_cmd = std.mem.trimLeft(u8, trimmed[space1 + 1 ..], " ");
    const space2 = std.mem.indexOfScalar(u8, after_cmd, ' ') orelse after_cmd.len;
    const hash = after_cmd[0..space2];

    const cmd = if (std.mem.eql(u8, cmd_str, "pick") or std.mem.eql(u8, cmd_str, "p"))
        TodoCmd.pick
    else if (std.mem.eql(u8, cmd_str, "reword") or std.mem.eql(u8, cmd_str, "r"))
        TodoCmd.reword
    else if (std.mem.eql(u8, cmd_str, "edit") or std.mem.eql(u8, cmd_str, "e"))
        TodoCmd.edit
    else if (std.mem.eql(u8, cmd_str, "squash") or std.mem.eql(u8, cmd_str, "s"))
        TodoCmd.squash
    else if (std.mem.eql(u8, cmd_str, "fixup") or std.mem.eql(u8, cmd_str, "f") or std.mem.startsWith(u8, cmd_str, "fixup"))
        TodoCmd.fixup
    else if (std.mem.eql(u8, cmd_str, "drop") or std.mem.eql(u8, cmd_str, "d"))
        TodoCmd.drop
    else if (std.mem.eql(u8, cmd_str, "label") or std.mem.eql(u8, cmd_str, "l"))
        TodoCmd.label
    else if (std.mem.eql(u8, cmd_str, "reset") or std.mem.eql(u8, cmd_str, "t"))
        TodoCmd.reset
    else if (std.mem.eql(u8, cmd_str, "merge") or std.mem.eql(u8, cmd_str, "m"))
        TodoCmd.merge
    else
        return null; // unknown command - bad line

    return TodoItem{
        .cmd = cmd,
        .hash = hash,
        .rest = if (space2 < after_cmd.len) after_cmd[space2 + 1 ..] else "",
        .original_line = trimmed,
    };
}

fn executeTodoList(git_path: []const u8, repo_root: []const u8, branch_name: []const u8, quiet: bool, apply_mode: bool, opts: *RebaseOpts, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const dir_name = if (apply_mode) "rebase-apply" else "rebase-merge";

    // Read the todo list
    const todo_path = try std.fmt.allocPrint(allocator, "{s}/{s}/git-rebase-todo", .{ git_path, dir_name });
    defer allocator.free(todo_path);
    const todo_content = platform_impl.fs.readFile(allocator, todo_path) catch return;
    defer allocator.free(todo_content);

    var items = try parseTodoItems(todo_content, allocator);
    defer items.deinit();

    const reflog_action = getReflogAction(allocator);
    defer allocator.free(reflog_action);

    // Read the done file path
    const done_path = try std.fmt.allocPrint(allocator, "{s}/{s}/done", .{ git_path, dir_name });
    defer allocator.free(done_path);

    // Ensure done file exists
    if (platform_impl.fs.readFile(allocator, done_path)) |content| {
        allocator.free(content);
    } else |_| {
        platform_impl.fs.writeFile(done_path, "") catch {};
    }

    var idx: usize = 0;
    while (idx < items.items.len) : (idx += 1) {
        const item = items.items[idx];

        // Update msgnum
        const msgnum_path = try std.fmt.allocPrint(allocator, "{s}/{s}/msgnum", .{ git_path, dir_name });
        defer allocator.free(msgnum_path);
        const msgnum_str = try std.fmt.allocPrint(allocator, "{d}", .{idx + 1});
        defer allocator.free(msgnum_str);
        platform_impl.fs.writeFile(msgnum_path, msgnum_str) catch {};

        // Write remaining todo (after this item)
        try writeRemainingTodo(git_path, dir_name, items.items[idx + 1 ..], allocator, platform_impl);

        switch (item.cmd) {
            .noop => {},
            .drop => {
                // Append to done
                try appendDone(git_path, dir_name, item.original_line, allocator, platform_impl);
            },
            .pick => {
                try executePick(git_path, item.hash, item.original_line, dir_name, reflog_action, quiet, false, allocator, platform_impl);
            },
            .reword => {
                try executePick(git_path, item.hash, item.original_line, dir_name, reflog_action, quiet, false, allocator, platform_impl);
                // For reword, we need to open editor on the commit message and amend
                try rewordLastCommit(git_path, allocator, platform_impl);
            },
            .edit => {
                try executePick(git_path, item.hash, item.original_line, dir_name, reflog_action, quiet, false, allocator, platform_impl);
                // Stop for user to edit
                // Save state: current position
                try writeStoppedSha(git_path, dir_name, item.hash, allocator, platform_impl);
                // Write amend flag
                const amend_path = try std.fmt.allocPrint(allocator, "{s}/{s}/amend", .{ git_path, dir_name });
                defer allocator.free(amend_path);
                const current_head2 = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
                if (current_head2) |ch| {
                    platform_impl.fs.writeFile(amend_path, ch) catch {};
                    allocator.free(ch);
                }

                if (!quiet) {
                    try platform_impl.writeStderr("Stopped at ");
                    try platform_impl.writeStderr(item.hash[0..@min(7, item.hash.len)]);
                    try platform_impl.writeStderr("... ");
                    const subj = getCommitSubject(item.hash, git_path, platform_impl, allocator) catch try allocator.dupe(u8, "");
                    defer allocator.free(subj);
                    try platform_impl.writeStderr(subj);
                    try platform_impl.writeStderr("\n");
                }
                std.process.exit(0);
            },
            .squash, .fixup => {
                try executeSquashFixup(git_path, item, dir_name, reflog_action, quiet, allocator, platform_impl);
            },
            .exec => {
                try appendDone(git_path, dir_name, item.original_line, allocator, platform_impl);
                const exec_result = try executeExec(item.rest, repo_root, allocator);
                if (!exec_result) {
                    // Exec failed - check reschedule
                    const do_reschedule = opts.reschedule_failed_exec orelse blk: {
                        // Check config
                        const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch break :blk false;
                        defer allocator.free(config_path);
                        const cfg = platform_impl.fs.readFile(allocator, config_path) catch break :blk false;
                        defer allocator.free(cfg);
                        if (findConfigValue(cfg, "rebase", null, "rescheduleFailedExec")) |val| {
                            const t = std.mem.trim(u8, val, " \t\r\n");
                            break :blk std.mem.eql(u8, t, "true");
                        }
                        break :blk false;
                    };
                    if (do_reschedule) {
                        // Prepend this exec to remaining todo
                        try prependToTodo(git_path, dir_name, item.original_line, allocator, platform_impl);
                    }
                    const emsg = try std.fmt.allocPrint(allocator, "warning: execution failed: {s}\n", .{item.rest});
                    defer allocator.free(emsg);
                    try platform_impl.writeStderr(emsg);
                    try platform_impl.writeStderr("You can fix the problem, and then run\n\n\tgit rebase --continue\n\n\n");
                    std.process.exit(1);
                }
            },
            .break_cmd => {
                try appendDone(git_path, dir_name, item.original_line, allocator, platform_impl);
                // Write remaining todo
                try writeRemainingTodo(git_path, dir_name, items.items[idx + 1 ..], allocator, platform_impl);
                std.process.exit(0);
            },
            else => {
                // label, reset, merge - skip for now
                try appendDone(git_path, dir_name, item.original_line, allocator, platform_impl);
            },
        }
    }

    // Rebase complete
    try finishRebase(git_path, branch_name, quiet, apply_mode, reflog_action, allocator, platform_impl);
}

fn executePick(git_path: []const u8, hash: []const u8, original_line: []const u8, dir_name: []const u8, reflog_action: []const u8, quiet: bool, is_continue: bool, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    _ = quiet;
    _ = is_continue;

    // Resolve hash (could be abbreviated)
    const full_hash = git_helpers_mod.resolveRevision(git_path, hash, platform_impl, allocator) catch {
        const msg = try std.fmt.allocPrint(allocator, "error: could not apply {s}\n", .{hash});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    };
    defer allocator.free(full_hash);

    // Write REBASE_HEAD
    const rebase_head_path = try std.fmt.allocPrint(allocator, "{s}/REBASE_HEAD", .{git_path});
    defer allocator.free(rebase_head_path);
    platform_impl.fs.writeFile(rebase_head_path, full_hash) catch {};

    // Cherry-pick
    const result = cherryPickCommit(git_path, full_hash, allocator, platform_impl);
    if (result) |new_hash| {
        defer allocator.free(new_hash);
        const old_head = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
        defer if (old_head) |oh| allocator.free(oh);
        try refs.updateHEAD(git_path, new_hash, platform_impl, allocator);

        const subject = getCommitSubject(full_hash, git_path, platform_impl, allocator) catch try allocator.dupe(u8, "");
        defer allocator.free(subject);
        const pick_msg = try std.fmt.allocPrint(allocator, "{s} (pick): {s}", .{ reflog_action, subject });
        defer allocator.free(pick_msg);
        writeReflogEntry(git_path, "HEAD", old_head orelse full_hash, new_hash, pick_msg, allocator, platform_impl) catch {};

        // Copy notes
        copyRebaseNotes(git_path, full_hash, new_hash, allocator, platform_impl) catch {};

        // Remove REBASE_HEAD after success
        platform_impl.fs.deleteFile(rebase_head_path) catch {};

        // Append to done
        try appendDone(git_path, dir_name, original_line, allocator, platform_impl);
    } else |err| {
        if (err == error.MergeConflict) {
            // Write current state for continue
            try appendDone(git_path, dir_name, original_line, allocator, platform_impl);
            // Write stopped-sha
            try writeStoppedSha(git_path, dir_name, full_hash, allocator, platform_impl);
            // Write MERGE_MSG
            const msg2 = getCommitMessage(git_path, full_hash, allocator, platform_impl) catch null;
            if (msg2) |m| {
                defer allocator.free(m);
                const merge_msg_path = try std.fmt.allocPrint(allocator, "{s}/MERGE_MSG", .{git_path});
                defer allocator.free(merge_msg_path);
                platform_impl.fs.writeFile(merge_msg_path, m) catch {};
            }
            // Write the patch
            try writePatchFile(git_path, dir_name, full_hash, allocator, platform_impl);

            const subj = getCommitSubject(full_hash, git_path, platform_impl, allocator) catch try allocator.dupe(u8, "");
            defer allocator.free(subj);
            const err_msg = try std.fmt.allocPrint(allocator, "error: could not apply {s}... {s}\n", .{ hash[0..@min(7, hash.len)], subj });
            defer allocator.free(err_msg);
            try platform_impl.writeStderr(err_msg);
            try platform_impl.writeStderr("hint: Resolve all conflicts manually, mark them as resolved with\nhint: \"git add/rm <conflicted_files>\", then run \"git rebase --continue\".\nhint: You can instead skip this commit: run \"git rebase --skip\".\nhint: To abort and get back to the state before \"git rebase\", run \"git rebase --abort\".\n");
            const could_not_msg = try std.fmt.allocPrint(allocator, "Could not apply {s}... {s}\n", .{ hash[0..@min(7, hash.len)], subj });
            defer allocator.free(could_not_msg);
            try platform_impl.writeStderr(could_not_msg);
            std.process.exit(1);
        }
        // Other error - append to done and continue
        try appendDone(git_path, dir_name, original_line, allocator, platform_impl);
    }
}

fn executeSquashFixup(git_path: []const u8, item: TodoItem, dir_name: []const u8, reflog_action: []const u8, quiet: bool, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    _ = quiet;
    const is_squash = item.cmd == .squash;
    const full_hash = git_helpers_mod.resolveRevision(git_path, item.hash, platform_impl, allocator) catch return;
    defer allocator.free(full_hash);

    // Write REBASE_HEAD
    const rebase_head_path = try std.fmt.allocPrint(allocator, "{s}/REBASE_HEAD", .{git_path});
    defer allocator.free(rebase_head_path);
    platform_impl.fs.writeFile(rebase_head_path, full_hash) catch {};

    // Cherry-pick
    const result = cherryPickCommit(git_path, full_hash, allocator, platform_impl);
    if (result) |new_hash| {
        defer allocator.free(new_hash);

        // Get the pre-cherry-pick HEAD (the commit we're squashing into)
        const prev_head = (refs.getCurrentCommit(git_path, platform_impl, allocator) catch null) orelse return;
        defer allocator.free(prev_head);

        // Get the tree from the cherry-picked result (has the squashed changes)
        const current_tree = getCommitTree(git_path, new_hash, allocator, platform_impl) catch return;
        defer allocator.free(current_tree);

        // The parent of the squashed commit is the parent of the previous HEAD
        // (since we're merging prev_head and new_hash into one commit)
        const parent_hash = prev_head;
        const grandparent = getCommitFirstParent(git_path, prev_head, allocator, platform_impl) catch null;
        defer if (grandparent) |gp| allocator.free(gp);

        // Build new message
        var new_message: []u8 = undefined;
        if (is_squash) {
            // Combine messages
            const prev_msg = getCommitMessage(git_path, parent_hash, allocator, platform_impl) catch try allocator.dupe(u8, "");
            defer allocator.free(prev_msg);
            const this_msg = getCommitMessage(git_path, full_hash, allocator, platform_impl) catch try allocator.dupe(u8, "");
            defer allocator.free(this_msg);

            // Count how many commits (check squash message file)
            const sq_msg_path = try std.fmt.allocPrint(allocator, "{s}/{s}/message-squash", .{ git_path, dir_name });
            defer allocator.free(sq_msg_path);
            const existing_squash = platform_impl.fs.readFile(allocator, sq_msg_path) catch null;
            defer if (existing_squash) |es| allocator.free(es);

            if (existing_squash) |es| {
                // Parse existing count and increment
                var count: usize = 2;
                if (std.mem.indexOf(u8, es, "# This is a combination of ")) |pos| {
                    const rest = es[pos + "# This is a combination of ".len..];
                    if (std.mem.indexOf(u8, rest, " commits")) |end| {
                        count = std.fmt.parseInt(usize, rest[0..end], 10) catch 2;
                    }
                }
                count += 1;
                // Update the count in the header and append new message
                const count_str = try std.fmt.allocPrint(allocator, "{d}", .{count});
                defer allocator.free(count_str);
                var updated = std.array_list.Managed(u8).init(allocator);
                // Replace count in first line
                if (std.mem.indexOf(u8, es, "# This is a combination of ")) |pos| {
                    const prefix_end = pos + "# This is a combination of ".len;
                    try updated.appendSlice(es[0..prefix_end]);
                    try updated.appendSlice(count_str);
                    if (std.mem.indexOfPos(u8, es, prefix_end, " commits")) |cnt_end| {
                        try updated.appendSlice(es[cnt_end..]);
                    }
                } else {
                    try updated.appendSlice(es);
                }
                new_message = try std.fmt.allocPrint(allocator, "{s}\n\n# This is the commit message #{d}:\n\n{s}", .{ updated.items, count, std.mem.trim(u8, this_msg, "\n") });
                updated.deinit();
            } else {
                new_message = try std.fmt.allocPrint(allocator, "# This is a combination of 2 commits.\n# This is the 1st commit message:\n\n{s}\n\n# This is the commit message #2:\n\n{s}", .{ std.mem.trim(u8, prev_msg, "\n"), std.mem.trim(u8, this_msg, "\n") });
            }
            // Save for subsequent squashes
            platform_impl.fs.writeFile(sq_msg_path, new_message) catch {};

            // Invoke editor on the message for squash (not fixup)
            const commit_msg_path = try std.fmt.allocPrint(allocator, "{s}/COMMIT_EDITMSG", .{git_path});
            defer allocator.free(commit_msg_path);
            platform_impl.fs.writeFile(commit_msg_path, new_message) catch {};
            const editor_ok = invokeCommitEditor(commit_msg_path, git_path, allocator, platform_impl) catch false;
            if (editor_ok) {
                const edited_msg = platform_impl.fs.readFile(allocator, commit_msg_path) catch null;
                if (edited_msg) |em| {
                    allocator.free(new_message);
                    new_message = try stripCommentLines(em, allocator);
                    allocator.free(em);
                }
            } else {
                // No editor or editor failed - strip comments from the default message
                const stripped = try stripCommentLines(new_message, allocator);
                allocator.free(new_message);
                new_message = stripped;
            }
        } else {
            // Fixup: keep the parent's message
            new_message = getCommitMessage(git_path, parent_hash, allocator, platform_impl) catch try allocator.dupe(u8, "");
        }
        defer allocator.free(new_message);

        // Get author from parent commit (the one being squashed into)
        const author_line = getCommitAuthorLine(git_path, parent_hash, allocator, platform_impl) catch try allocator.dupe(u8, "Unknown <unknown> 0 +0000");
        defer allocator.free(author_line);

        const committer_line = getCommitterString(allocator) catch try allocator.dupe(u8, "Unknown <unknown> 0 +0000");
        defer allocator.free(committer_line);

        // Create new squashed commit with grandparent as parent
        var parents_buf: [1][]const u8 = undefined;
        var parents_slice: []const []const u8 = &[_][]const u8{};
        if (grandparent) |gp| {
            parents_buf[0] = gp;
            parents_slice = &parents_buf;
        }

        const squash_commit = objects.createCommitObject(current_tree, parents_slice, author_line, committer_line, new_message, allocator) catch return;
        defer squash_commit.deinit(allocator);
        const squash_hash = squash_commit.store(git_path, platform_impl, allocator) catch return;
        defer allocator.free(squash_hash);

        // Update HEAD
        refs.updateHEAD(git_path, squash_hash, platform_impl, allocator) catch {};

        const subject = getCommitSubject(full_hash, git_path, platform_impl, allocator) catch try allocator.dupe(u8, "");
        defer allocator.free(subject);
        const action_name: []const u8 = if (is_squash) "squash" else "fixup";
        const sq_msg = std.fmt.allocPrint(allocator, "{s} ({s}): {s}", .{ reflog_action, action_name, subject }) catch null;
        defer if (sq_msg) |sm| allocator.free(sm);
        if (sq_msg) |sm| writeReflogEntry(git_path, "HEAD", prev_head, squash_hash, sm, allocator, platform_impl) catch {};

        // Update index/working tree to match
        checkoutCommitTree(git_path, squash_hash, allocator, platform_impl) catch {};

        // Remove REBASE_HEAD
        platform_impl.fs.deleteFile(rebase_head_path) catch {};
    } else |err| {
        if (err == error.MergeConflict) {
            try appendDone(git_path, dir_name, item.original_line, allocator, platform_impl);
            const subj = getCommitSubject(full_hash, git_path, platform_impl, allocator) catch try allocator.dupe(u8, "");
            defer allocator.free(subj);
            const err_msg = try std.fmt.allocPrint(allocator, "CONFLICT: could not apply {s}... {s}\n", .{ item.hash[0..@min(7, item.hash.len)], subj });
            defer allocator.free(err_msg);
            try platform_impl.writeStderr(err_msg);
            std.process.exit(1);
        }
    }

    try appendDone(git_path, dir_name, item.original_line, allocator, platform_impl);
}

fn executeExec(cmd: []const u8, repo_root: []const u8, allocator: std.mem.Allocator) !bool {
    // Build: cd <repo_root> && <cmd>
    const full_cmd = try std.fmt.allocPrint(allocator, "cd \"{s}\" && {s}", .{ repo_root, cmd });
    defer allocator.free(full_cmd);
    return try runShellCommand(full_cmd, allocator);
}

fn rewordLastCommit(git_path: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const head = (refs.getCurrentCommit(git_path, platform_impl, allocator) catch null) orelse return;
    defer allocator.free(head);

    const msg = getCommitMessage(git_path, head, allocator, platform_impl) catch return;
    defer allocator.free(msg);

    // Write to COMMIT_EDITMSG
    const editmsg_path = try std.fmt.allocPrint(allocator, "{s}/COMMIT_EDITMSG", .{git_path});
    defer allocator.free(editmsg_path);
    platform_impl.fs.writeFile(editmsg_path, msg) catch return;

    // Invoke editor
    const edited = try invokeCommitEditor(editmsg_path, git_path, allocator, platform_impl);
    if (!edited) return;

    // Read edited message
    const new_msg = platform_impl.fs.readFile(allocator, editmsg_path) catch return;
    defer allocator.free(new_msg);

    // Strip comment lines
    const clean_msg = try stripCommentLines(new_msg, allocator);
    defer allocator.free(clean_msg);

    // Amend the commit with new message
    try amendCommitMessage(git_path, head, clean_msg, allocator, platform_impl);
}

fn amendCommitMessage(git_path: []const u8, commit_hash: []const u8, new_message: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const commit_obj = try objects.GitObject.load(commit_hash, git_path, platform_impl, allocator);
    defer commit_obj.deinit(allocator);

    // Parse headers
    const header_end = std.mem.indexOf(u8, commit_obj.data, "\n\n") orelse return;
    const headers = commit_obj.data[0..header_end];

    // Build new commit data
    const new_data = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ headers, new_message });
    defer allocator.free(new_data);

    const new_obj = objects.GitObject{ .type = .commit, .data = new_data };
    const new_hash = try new_obj.store(git_path, platform_impl, allocator);
    defer allocator.free(new_hash);

    try refs.updateHEAD(git_path, new_hash, platform_impl, allocator);
}

// ============================================================================
// Continue / Skip / Abort
// ============================================================================

fn rebaseContinue(git_path: []const u8, repo_root: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform, quiet: bool) !void {
    _ = repo_root;
    if (!hasRebaseInProgress(git_path, allocator)) {
        try platform_impl.writeStderr("fatal: no rebase in progress\n");
        std.process.exit(128);
    }

    const dir_name = getRebaseDirName(git_path, allocator);
    const is_apply_mode = std.mem.eql(u8, dir_name, "rebase-apply");

    // Read head-name
    const head_name_raw = readRebaseFile(git_path, "head-name", allocator, platform_impl) orelse {
        try platform_impl.writeStderr("fatal: no rebase in progress\n");
        std.process.exit(128);
    };
    defer allocator.free(head_name_raw);
    const head_name = std.mem.trim(u8, head_name_raw, " \t\n\r");

    const branch_name = if (std.mem.startsWith(u8, head_name, "refs/heads/"))
        head_name["refs/heads/".len..]
    else
        "HEAD";

    // Remove MERGE_MSG if present
    const merge_msg_path = try std.fmt.allocPrint(allocator, "{s}/MERGE_MSG", .{git_path});
    defer allocator.free(merge_msg_path);
    platform_impl.fs.deleteFile(merge_msg_path) catch {};

    // Remove CHERRY_PICK_HEAD if present
    {
        const cp_path = try std.fmt.allocPrint(allocator, "{s}/CHERRY_PICK_HEAD", .{git_path});
        defer allocator.free(cp_path);
        platform_impl.fs.deleteFile(cp_path) catch {};
    }

    // Check if we need to commit resolved conflicts
    const rebase_head_path = try std.fmt.allocPrint(allocator, "{s}/REBASE_HEAD", .{git_path});
    defer allocator.free(rebase_head_path);
    const has_rebase_head = if (platform_impl.fs.readFile(allocator, rebase_head_path)) |rh| blk: {
        defer allocator.free(rh);
        // Commit the resolved state
        const rh_trimmed = std.mem.trim(u8, rh, " \t\n\r");
        try commitResolvedConflict(git_path, rh_trimmed, dir_name, is_apply_mode, allocator, platform_impl);
        break :blk true;
    } else |_| false;

    // Check for amend (edit command)
    const amend_path = try std.fmt.allocPrint(allocator, "{s}/{s}/amend", .{ git_path, dir_name });
    defer allocator.free(amend_path);
    if (platform_impl.fs.readFile(allocator, amend_path)) |amend_hash| {
        defer allocator.free(amend_hash);
        const trimmed_amend = std.mem.trim(u8, amend_hash, " \t\n\r");
        // Check if HEAD has changed (user made changes with commit --amend)
        const current_head = (refs.getCurrentCommit(git_path, platform_impl, allocator) catch null) orelse trimmed_amend;
        defer if (!std.mem.eql(u8, current_head, trimmed_amend)) allocator.free(current_head);
        // Clean up amend file
        platform_impl.fs.deleteFile(amend_path) catch {};
    } else |_| {
        if (!has_rebase_head) {
            // No rebase head and no amend - might be a break/exec continue, that's fine
        }
    }

    // Remove stopped-sha
    const stopped_path = try std.fmt.allocPrint(allocator, "{s}/{s}/stopped-sha", .{ git_path, dir_name });
    defer allocator.free(stopped_path);
    platform_impl.fs.deleteFile(stopped_path) catch {};

    // Remove REBASE_HEAD
    platform_impl.fs.deleteFile(rebase_head_path) catch {};

    // Read opts
    var dummy_opts = RebaseOpts{
        .exec_cmds = std.array_list.Managed([]const u8).init(allocator),
    };
    defer dummy_opts.deinit(allocator);

    // Check reschedule config
    const rfe_path = try std.fmt.allocPrint(allocator, "{s}/{s}/reschedule-failed-exec", .{ git_path, dir_name });
    defer allocator.free(rfe_path);
    if (platform_impl.fs.readFile(allocator, rfe_path)) |rfe| {
        defer allocator.free(rfe);
        dummy_opts.reschedule_failed_exec = true;
    } else |_| {}

    const reflog_action = getReflogAction(allocator);
    defer allocator.free(reflog_action);

    // Continue executing the todo list
    // Read remaining todo
    const todo_path = try std.fmt.allocPrint(allocator, "{s}/{s}/git-rebase-todo", .{ git_path, dir_name });
    defer allocator.free(todo_path);
    const todo_content = platform_impl.fs.readFile(allocator, todo_path) catch {
        // No todo - finish
        try finishRebase(git_path, branch_name, quiet, is_apply_mode, reflog_action, allocator, platform_impl);
        return;
    };
    defer allocator.free(todo_content);

    // Check if there are remaining items
    var has_items = false;
    var check = std.mem.splitScalar(u8, todo_content, '\n');
    while (check.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0 and trimmed[0] != '#') {
            has_items = true;
            break;
        }
    }

    if (!has_items) {
        try finishRebase(git_path, branch_name, quiet, is_apply_mode, reflog_action, allocator, platform_impl);
        return;
    }

    // Parse and execute remaining items
    var items = try parseTodoItems(todo_content, allocator);
    defer items.deinit();

    const done_path = try std.fmt.allocPrint(allocator, "{s}/{s}/done", .{ git_path, dir_name });
    defer allocator.free(done_path);

    var idx: usize = 0;
    while (idx < items.items.len) : (idx += 1) {
        const item = items.items[idx];

        // Write remaining todo
        try writeRemainingTodo(git_path, dir_name, items.items[idx + 1 ..], allocator, platform_impl);

        switch (item.cmd) {
            .noop => {},
            .drop => {
                try appendDone(git_path, dir_name, item.original_line, allocator, platform_impl);
            },
            .pick => {
                try executePick(git_path, item.hash, item.original_line, dir_name, reflog_action, quiet, true, allocator, platform_impl);
            },
            .reword => {
                try executePick(git_path, item.hash, item.original_line, dir_name, reflog_action, quiet, true, allocator, platform_impl);
                try rewordLastCommit(git_path, allocator, platform_impl);
            },
            .edit => {
                try executePick(git_path, item.hash, item.original_line, dir_name, reflog_action, quiet, true, allocator, platform_impl);
                try writeStoppedSha(git_path, dir_name, item.hash, allocator, platform_impl);
                const amend_path2 = try std.fmt.allocPrint(allocator, "{s}/{s}/amend", .{ git_path, dir_name });
                defer allocator.free(amend_path2);
                const ch = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
                if (ch) |c| {
                    platform_impl.fs.writeFile(amend_path2, c) catch {};
                    allocator.free(c);
                }
                if (!quiet) {
                    try platform_impl.writeStderr("Stopped at ");
                    try platform_impl.writeStderr(item.hash[0..@min(7, item.hash.len)]);
                    try platform_impl.writeStderr("...\n");
                }
                std.process.exit(0);
            },
            .squash, .fixup => {
                try executeSquashFixup(git_path, item, dir_name, reflog_action, quiet, allocator, platform_impl);
            },
            .exec => {
                try appendDone(git_path, dir_name, item.original_line, allocator, platform_impl);
                const repo_root2 = std.fs.path.dirname(git_path) orelse ".";
                const exec_result = try executeExec(item.rest, repo_root2, allocator);
                if (!exec_result) {
                    const do_reschedule = dummy_opts.reschedule_failed_exec orelse false;
                    if (do_reschedule) {
                        try prependToTodo(git_path, dir_name, item.original_line, allocator, platform_impl);
                    }
                    const emsg = try std.fmt.allocPrint(allocator, "warning: execution failed: {s}\n", .{item.rest});
                    defer allocator.free(emsg);
                    try platform_impl.writeStderr(emsg);
                    try platform_impl.writeStderr("You can fix the problem, and then run\n\n\tgit rebase --continue\n\n\n");
                    std.process.exit(1);
                }
            },
            .break_cmd => {
                try appendDone(git_path, dir_name, item.original_line, allocator, platform_impl);
                try writeRemainingTodo(git_path, dir_name, items.items[idx + 1 ..], allocator, platform_impl);
                std.process.exit(0);
            },
            else => {
                try appendDone(git_path, dir_name, item.original_line, allocator, platform_impl);
            },
        }
    }

    try finishRebase(git_path, branch_name, quiet, is_apply_mode, reflog_action, allocator, platform_impl);
}

fn commitResolvedConflict(git_path: []const u8, commit_hash: []const u8, dir_name: []const u8, is_apply_mode: bool, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const author = getCommitAuthorLine(git_path, commit_hash, allocator, platform_impl) catch try getAuthorString(allocator);
    defer allocator.free(author);
    const message = getCommitMessage(git_path, commit_hash, allocator, platform_impl) catch try allocator.dupe(u8, "rebase continue");
    defer allocator.free(message);

    const current_head = (try refs.getCurrentCommit(git_path, platform_impl, allocator)) orelse return;
    defer allocator.free(current_head);

    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
    defer idx.deinit();
    const new_tree = try writeTreeFromIndex(allocator, &idx, git_path, platform_impl);
    defer allocator.free(new_tree);

    const committer_line = getCommitterString(allocator) catch try allocator.dupe(u8, "Unknown <unknown> 0 +0000");
    defer allocator.free(committer_line);

    const parents = [_][]const u8{current_head};
    const new_commit = try objects.createCommitObject(new_tree, &parents, author, committer_line, message, allocator);
    defer new_commit.deinit(allocator);
    const new_hash = try new_commit.store(git_path, platform_impl, allocator);
    defer allocator.free(new_hash);

    const old_head_for_reflog = try allocator.dupe(u8, current_head);
    defer allocator.free(old_head_for_reflog);

    try refs.updateHEAD(git_path, new_hash, platform_impl, allocator);

    const reflog_action_str = getReflogAction(allocator);
    defer allocator.free(reflog_action_str);
    const subject = getCommitSubject(commit_hash, git_path, platform_impl, allocator) catch try allocator.dupe(u8, "");
    defer allocator.free(subject);
    const action_name: []const u8 = if (is_apply_mode) "pick" else "continue";
    const msg2 = try std.fmt.allocPrint(allocator, "{s} ({s}): {s}", .{ reflog_action_str, action_name, subject });
    defer allocator.free(msg2);
    writeReflogEntry(git_path, "HEAD", old_head_for_reflog, new_hash, msg2, allocator, platform_impl) catch {};

    _ = dir_name;
}

fn rebaseAbort(git_path: []const u8, repo_root: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    _ = repo_root;
    if (!hasRebaseInProgress(git_path, allocator)) {
        try platform_impl.writeStderr("fatal: no rebase in progress\n");
        std.process.exit(128);
    }

    const orig_head_raw = readRebaseFile(git_path, "orig-head", allocator, platform_impl) orelse {
        try platform_impl.writeStderr("fatal: no rebase in progress\n");
        std.process.exit(128);
    };
    defer allocator.free(orig_head_raw);
    const orig_head = std.mem.trim(u8, orig_head_raw, " \t\n\r");

    const head_name_raw = readRebaseFile(git_path, "head-name", allocator, platform_impl) orelse try allocator.dupe(u8, "detached HEAD");
    defer allocator.free(head_name_raw);
    const head_name = std.mem.trim(u8, head_name_raw, " \t\n\r");

    const current_head = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
    defer if (current_head) |ch| allocator.free(ch);

    checkoutCommitTree(git_path, orig_head, allocator, platform_impl) catch {};

    if (std.mem.startsWith(u8, head_name, "refs/heads/")) {
        const branch = head_name["refs/heads/".len..];
        try refs.updateRef(git_path, branch, orig_head, platform_impl, allocator);
        try refs.updateHEAD(git_path, branch, platform_impl, allocator);
    } else {
        try refs.updateHEAD(git_path, orig_head, platform_impl, allocator);
    }

    const abort_reflog_action = getReflogAction(allocator);
    defer allocator.free(abort_reflog_action);
    const return_target = if (std.mem.startsWith(u8, head_name, "refs/")) head_name else orig_head;
    const abort_msg = try std.fmt.allocPrint(allocator, "{s} (abort): returning to {s}", .{ abort_reflog_action, return_target });
    defer allocator.free(abort_msg);
    writeReflogEntry(git_path, "HEAD", current_head orelse orig_head, orig_head, abort_msg, allocator, platform_impl) catch {};

    cleanupRebaseState(git_path, allocator);
}

fn rebaseSkip(git_path: []const u8, repo_root: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform, quiet: bool) !void {
    _ = repo_root;
    if (!hasRebaseInProgress(git_path, allocator)) {
        try platform_impl.writeStderr("fatal: no rebase in progress\n");
        std.process.exit(128);
    }

    const dir_name = getRebaseDirName(git_path, allocator);
    const is_apply_mode = std.mem.eql(u8, dir_name, "rebase-apply");

    const head_name_raw = readRebaseFile(git_path, "head-name", allocator, platform_impl) orelse return;
    defer allocator.free(head_name_raw);
    const head_name = std.mem.trim(u8, head_name_raw, " \t\n\r");
    const branch_name = if (std.mem.startsWith(u8, head_name, "refs/heads/"))
        head_name["refs/heads/".len..]
    else
        "HEAD";

    // Reset working tree to current HEAD (or onto if needed)
    const onto_raw = readRebaseFile(git_path, "onto", allocator, platform_impl) orelse return;
    defer allocator.free(onto_raw);
    const onto = std.mem.trim(u8, onto_raw, " \t\n\r");

    const current_head = (refs.getCurrentCommit(git_path, platform_impl, allocator) catch null) orelse onto;
    if (!std.mem.eql(u8, current_head, onto)) {
        // We have current_head allocated, no need to free onto
    }

    checkoutCommitTree(git_path, current_head, allocator, platform_impl) catch {};

    // Write skip reflog
    const reflog_action = getReflogAction(allocator);
    defer allocator.free(reflog_action);

    // Remove REBASE_HEAD
    const rebase_head_path = try std.fmt.allocPrint(allocator, "{s}/REBASE_HEAD", .{git_path});
    defer allocator.free(rebase_head_path);
    platform_impl.fs.deleteFile(rebase_head_path) catch {};

    // Remove amend/stopped-sha
    const amend_path = try std.fmt.allocPrint(allocator, "{s}/{s}/amend", .{ git_path, dir_name });
    defer allocator.free(amend_path);
    platform_impl.fs.deleteFile(amend_path) catch {};
    const stopped_path = try std.fmt.allocPrint(allocator, "{s}/{s}/stopped-sha", .{ git_path, dir_name });
    defer allocator.free(stopped_path);
    platform_impl.fs.deleteFile(stopped_path) catch {};

    // Read remaining todo and execute
    const todo_path = try std.fmt.allocPrint(allocator, "{s}/{s}/git-rebase-todo", .{ git_path, dir_name });
    defer allocator.free(todo_path);
    const todo_content = platform_impl.fs.readFile(allocator, todo_path) catch {
        try finishRebase(git_path, branch_name, quiet, is_apply_mode, reflog_action, allocator, platform_impl);
        return;
    };
    defer allocator.free(todo_content);

    var items = try parseTodoItems(todo_content, allocator);
    defer items.deinit();

    if (items.items.len == 0) {
        try finishRebase(git_path, branch_name, quiet, is_apply_mode, reflog_action, allocator, platform_impl);
        return;
    }

    var dummy_opts = RebaseOpts{
        .exec_cmds = std.array_list.Managed([]const u8).init(allocator),
    };
    defer dummy_opts.deinit(allocator);

    var idx: usize = 0;
    while (idx < items.items.len) : (idx += 1) {
        const item = items.items[idx];
        try writeRemainingTodo(git_path, dir_name, items.items[idx + 1 ..], allocator, platform_impl);

        switch (item.cmd) {
            .noop, .drop => {
                try appendDone(git_path, dir_name, item.original_line, allocator, platform_impl);
            },
            .pick => {
                try executePick(git_path, item.hash, item.original_line, dir_name, reflog_action, quiet, false, allocator, platform_impl);
            },
            .exec => {
                try appendDone(git_path, dir_name, item.original_line, allocator, platform_impl);
                const repo_root2 = std.fs.path.dirname(git_path) orelse ".";
                const exec_result = try executeExec(item.rest, repo_root2, allocator);
                if (!exec_result) {
                    const emsg = try std.fmt.allocPrint(allocator, "warning: execution failed: {s}\n", .{item.rest});
                    defer allocator.free(emsg);
                    try platform_impl.writeStderr(emsg);
                    std.process.exit(1);
                }
            },
            .break_cmd => {
                try appendDone(git_path, dir_name, item.original_line, allocator, platform_impl);
                try writeRemainingTodo(git_path, dir_name, items.items[idx + 1 ..], allocator, platform_impl);
                std.process.exit(0);
            },
            else => {
                try appendDone(git_path, dir_name, item.original_line, allocator, platform_impl);
            },
        }
    }

    try finishRebase(git_path, branch_name, quiet, is_apply_mode, reflog_action, allocator, platform_impl);
}

fn rebaseShowCurrentPatch(git_path: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const rebase_apply_dir = try std.fmt.allocPrint(allocator, "{s}/rebase-apply", .{git_path});
    defer allocator.free(rebase_apply_dir);

    const rebase_head_path = try std.fmt.allocPrint(allocator, "{s}/REBASE_HEAD", .{git_path});
    defer allocator.free(rebase_head_path);
    const rebase_head = platform_impl.fs.readFile(allocator, rebase_head_path) catch {
        try platform_impl.writeStderr("fatal: no rebase in progress\n");
        std.process.exit(1);
    };
    defer allocator.free(rebase_head);
    const hash = std.mem.trim(u8, rebase_head, " \t\n\r");

    if (dirExists(rebase_apply_dir)) {
        try platform_impl.writeStdout(hash);
        try platform_impl.writeStdout("\n");
        const trace_msg = try std.fmt.allocPrint(allocator, "show {s}\n", .{hash});
        defer allocator.free(trace_msg);
        try platform_impl.writeStderr(trace_msg);
    } else {
        const show_msg = try std.fmt.allocPrint(allocator, "show REBASE_HEAD\nshow {s}\n", .{hash});
        defer allocator.free(show_msg);
        try platform_impl.writeStderr(show_msg);
    }
}

// ============================================================================
// Finish rebase
// ============================================================================

fn finishRebase(git_path: []const u8, branch_name: []const u8, quiet: bool, apply_mode: bool, reflog_action: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    _ = apply_mode;
    const head_hash = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null orelse return;
    defer allocator.free(head_hash);

    if (!std.mem.eql(u8, branch_name, "HEAD")) {
        // Read original head for reflog
        var old_branch_hash: []const u8 = "0000000000000000000000000000000000000000";
        var old_branch_hash_alloc: ?[]u8 = null;
        {
            const orig_head_p = std.fmt.allocPrint(allocator, "{s}/ORIG_HEAD", .{git_path}) catch "";
            defer if (orig_head_p.len > 0) allocator.free(orig_head_p);
            if (orig_head_p.len > 0) {
                if (platform_impl.fs.readFile(allocator, orig_head_p)) |oh| {
                    const trimmed = std.mem.trim(u8, oh, " \t\n\r");
                    if (trimmed.len == 40) {
                        old_branch_hash_alloc = oh;
                        old_branch_hash = trimmed;
                    } else {
                        allocator.free(oh);
                    }
                } else |_| {}
            }
        }
        defer if (old_branch_hash_alloc) |a| allocator.free(a);

        try refs.updateRef(git_path, branch_name, head_hash, platform_impl, allocator);
        const branch_reflog_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name});
        defer allocator.free(branch_reflog_name);

        const onto_for_reflog = readRebaseFile(git_path, "onto", allocator, platform_impl) orelse try allocator.dupe(u8, head_hash);
        defer allocator.free(onto_for_reflog);
        const onto_trimmed = std.mem.trim(u8, onto_for_reflog, " \t\n\r");

        const rebase_msg = try std.fmt.allocPrint(allocator, "{s} (finish): {s} onto {s}", .{ reflog_action, branch_reflog_name, onto_trimmed });
        defer allocator.free(rebase_msg);
        writeReflogEntry(git_path, branch_reflog_name, old_branch_hash, head_hash, rebase_msg, allocator, platform_impl) catch {};

        try refs.updateHEAD(git_path, branch_name, platform_impl, allocator);

        const finish_head_msg = try std.fmt.allocPrint(allocator, "{s} (finish): returning to {s}", .{ reflog_action, branch_reflog_name });
        defer allocator.free(finish_head_msg);
        writeReflogEntry(git_path, "HEAD", head_hash, head_hash, finish_head_msg, allocator, platform_impl) catch {};
    }

    cleanupRebaseState(git_path, allocator);

    // Remove REBASE_HEAD
    const rebase_head_path = try std.fmt.allocPrint(allocator, "{s}/REBASE_HEAD", .{git_path});
    defer allocator.free(rebase_head_path);
    platform_impl.fs.deleteFile(rebase_head_path) catch {};

    if (!quiet) {
        try platform_impl.writeStderr("Successfully rebased and updated ");
        if (std.mem.eql(u8, branch_name, "HEAD")) {
            try platform_impl.writeStderr("HEAD.\n");
        } else {
            const ref_msg = try std.fmt.allocPrint(allocator, "refs/heads/{s}.\n", .{branch_name});
            defer allocator.free(ref_msg);
            try platform_impl.writeStderr(ref_msg);
        }
    }
}

// ============================================================================
// Fast forward
// ============================================================================

fn doFastForward(git_path: []const u8, head_hash: []const u8, onto_hash: []const u8, current_branch_name: []const u8, opts: *RebaseOpts, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const ff_reflog_action = getReflogAction(allocator);
    defer allocator.free(ff_reflog_action);
    const ff_upstream_name = if (opts.onto != null) (opts.onto orelse "upstream") else (opts.original_upstream_display orelse opts.upstream_arg orelse "upstream");

    const ff_start_msg = try std.fmt.allocPrint(allocator, "{s} (start): checkout {s}", .{ ff_reflog_action, ff_upstream_name });
    defer allocator.free(ff_start_msg);
    writeReflogEntry(git_path, "HEAD", head_hash, onto_hash, ff_start_msg, allocator, platform_impl) catch {};

    if (!std.mem.eql(u8, current_branch_name, "HEAD")) {
        try refs.updateRef(git_path, current_branch_name, onto_hash, platform_impl, allocator);
        const ff_branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{current_branch_name});
        defer allocator.free(ff_branch_ref);
        const ff_finish_branch_msg = try std.fmt.allocPrint(allocator, "{s} (finish): {s} onto {s}", .{ ff_reflog_action, ff_branch_ref, onto_hash });
        defer allocator.free(ff_finish_branch_msg);
        writeReflogEntry(git_path, ff_branch_ref, head_hash, onto_hash, ff_finish_branch_msg, allocator, platform_impl) catch {};
    }
    try refs.updateHEAD(git_path, if (std.mem.eql(u8, current_branch_name, "HEAD")) onto_hash else current_branch_name, platform_impl, allocator);

    if (!std.mem.eql(u8, current_branch_name, "HEAD")) {
        const ff_branch_ref2 = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{current_branch_name});
        defer allocator.free(ff_branch_ref2);
        const ff_finish_head_msg = try std.fmt.allocPrint(allocator, "{s} (finish): returning to {s}", .{ ff_reflog_action, ff_branch_ref2 });
        defer allocator.free(ff_finish_head_msg);
        writeReflogEntry(git_path, "HEAD", onto_hash, onto_hash, ff_finish_head_msg, allocator, platform_impl) catch {};
    }

    checkoutCommitTree(git_path, onto_hash, allocator, platform_impl) catch {};
    if (!opts.quiet) {
        const ff_branch = if (std.mem.eql(u8, current_branch_name, "HEAD")) "HEAD" else current_branch_name;
        const ff_msg = try std.fmt.allocPrint(allocator, "Fast-forwarded {s} to {s}.\n", .{ ff_branch, ff_upstream_name });
        defer allocator.free(ff_msg);
        try platform_impl.writeStdout(ff_msg);
    }
}

// ============================================================================
// Helper functions
// ============================================================================

fn hasRebaseInProgress(git_path: []const u8, allocator: std.mem.Allocator) bool {
    const merge_dir = std.fmt.allocPrint(allocator, "{s}/rebase-merge", .{git_path}) catch return false;
    defer allocator.free(merge_dir);
    const apply_dir = std.fmt.allocPrint(allocator, "{s}/rebase-apply", .{git_path}) catch return false;
    defer allocator.free(apply_dir);
    return dirExists(merge_dir) or dirExists(apply_dir);
}

fn getRebaseDirName(git_path: []const u8, allocator: std.mem.Allocator) []const u8 {
    const merge_dir = std.fmt.allocPrint(allocator, "{s}/rebase-merge", .{git_path}) catch return "rebase-merge";
    defer allocator.free(merge_dir);
    if (dirExists(merge_dir)) return "rebase-merge";
    return "rebase-apply";
}

fn dirExists(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

fn getReflogAction(allocator: std.mem.Allocator) []u8 {
    return std.process.getEnvVarOwned(allocator, "GIT_REFLOG_ACTION") catch allocator.dupe(u8, "rebase") catch @as([]u8, @constCast("rebase"));
}

fn readRebaseFile(git_path: []const u8, filename: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) ?[]u8 {
    const merge_path = std.fmt.allocPrint(allocator, "{s}/rebase-merge/{s}", .{ git_path, filename }) catch return null;
    defer allocator.free(merge_path);
    if (platform_impl.fs.readFile(allocator, merge_path)) |content| return content else |_| {}

    const apply_path = std.fmt.allocPrint(allocator, "{s}/rebase-apply/{s}", .{ git_path, filename }) catch return null;
    defer allocator.free(apply_path);
    if (platform_impl.fs.readFile(allocator, apply_path)) |content| return content else |_| {}

    return null;
}

fn writeRemainingTodo(git_path: []const u8, dir_name: []const u8, remaining: []const TodoItem, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    for (remaining) |item| {
        try buf.appendSlice(item.original_line);
        try buf.append('\n');
    }
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}/git-rebase-todo", .{ git_path, dir_name });
    defer allocator.free(path);
    platform_impl.fs.writeFile(path, buf.items) catch {};
}

fn appendDone(git_path: []const u8, dir_name: []const u8, line: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const done_path = try std.fmt.allocPrint(allocator, "{s}/{s}/done", .{ git_path, dir_name });
    defer allocator.free(done_path);
    const existing = platform_impl.fs.readFile(allocator, done_path) catch try allocator.dupe(u8, "");
    defer allocator.free(existing);
    const new_content = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ existing, line });
    defer allocator.free(new_content);
    platform_impl.fs.writeFile(done_path, new_content) catch {};
}

fn prependToTodo(git_path: []const u8, dir_name: []const u8, line: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const todo_path = try std.fmt.allocPrint(allocator, "{s}/{s}/git-rebase-todo", .{ git_path, dir_name });
    defer allocator.free(todo_path);
    const existing = platform_impl.fs.readFile(allocator, todo_path) catch try allocator.dupe(u8, "");
    defer allocator.free(existing);
    const new_content = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ line, existing });
    defer allocator.free(new_content);
    platform_impl.fs.writeFile(todo_path, new_content) catch {};
}

fn writeStoppedSha(git_path: []const u8, dir_name: []const u8, hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}/stopped-sha", .{ git_path, dir_name });
    defer allocator.free(path);
    platform_impl.fs.writeFile(path, hash) catch {};
}

fn formatMode(mode: u32) []const u8 {
    return switch (mode) {
        0o100644 => "100644",
        0o100755 => "100755",
        0o120000 => "120000",
        0o160000 => "160000",
        0o040000 => "040000",
        else => "100644",
    };
}

fn writePatchFile(git_path: []const u8, dir_name: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const patch_path = try std.fmt.allocPrint(allocator, "{s}/{s}/patch", .{ git_path, dir_name });
    defer allocator.free(patch_path);

    // Generate a real unified diff between commit's parent and the commit
    const commit_obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch {
        const content = try std.fmt.allocPrint(allocator, "diff for {s}\n", .{commit_hash});
        defer allocator.free(content);
        platform_impl.fs.writeFile(patch_path, content) catch {};
        return;
    };
    defer commit_obj.deinit(allocator);

    const commit_tree = getCommitTree(git_path, commit_hash, allocator, platform_impl) catch return;
    defer allocator.free(commit_tree);
    const parent_hash = getCommitFirstParent(git_path, commit_hash, allocator, platform_impl) catch null;
    defer if (parent_hash) |ph| allocator.free(ph);
    const parent_tree = if (parent_hash) |ph|
        getCommitTree(git_path, ph, allocator, platform_impl) catch null
    else
        null;
    defer if (parent_tree) |pt| allocator.free(pt);

    // Collect entries from both trees
    var parent_entries = std.StringHashMap(FileEntry).init(allocator);
    defer parent_entries.deinit();
    var commit_entries = std.StringHashMap(FileEntry).init(allocator);
    defer commit_entries.deinit();

    if (parent_tree) |pt| {
        collectTreeEntriesFlat(git_path, pt, "", &parent_entries, allocator, platform_impl) catch {};
    }
    collectTreeEntriesFlat(git_path, commit_tree, "", &commit_entries, allocator, platform_impl) catch {};

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    // Collect all paths
    var all_paths = std.StringHashMap(void).init(allocator);
    defer all_paths.deinit();
    {
        var it = parent_entries.iterator();
        while (it.next()) |e| all_paths.put(e.key_ptr.*, {}) catch {};
    }
    {
        var it = commit_entries.iterator();
        while (it.next()) |e| all_paths.put(e.key_ptr.*, {}) catch {};
    }

    var path_list = std.array_list.Managed([]const u8).init(allocator);
    defer path_list.deinit();
    {
        var it = all_paths.iterator();
        while (it.next()) |e| path_list.append(e.key_ptr.*) catch {};
    }
    std.mem.sort([]const u8, path_list.items, {}, struct {
        pub fn f(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.f);

    for (path_list.items) |path| {
        const pe = parent_entries.get(path);
        const ce = commit_entries.get(path);
        if (pe != null and ce != null and std.mem.eql(u8, &pe.?.sha1, &ce.?.sha1)) continue;

        var old_hex_buf: [40]u8 = undefined;
        var new_hex_buf: [40]u8 = undefined;
        const old_hex: []const u8 = if (pe) |p| blk: {
            for (p.sha1, 0..) |b, bi| {
                old_hex_buf[bi * 2] = "0123456789abcdef"[b >> 4];
                old_hex_buf[bi * 2 + 1] = "0123456789abcdef"[b & 0xf];
            }
            break :blk &old_hex_buf;
        } else "0000000000000000000000000000000000000000";
        const new_hex: []const u8 = if (ce) |c| blk: {
            for (c.sha1, 0..) |b, bi| {
                new_hex_buf[bi * 2] = "0123456789abcdef"[b >> 4];
                new_hex_buf[bi * 2 + 1] = "0123456789abcdef"[b & 0xf];
            }
            break :blk &new_hex_buf;
        } else "0000000000000000000000000000000000000000";

        const old_mode_str = if (pe) |p| formatMode(p.mode) else "000000";
        const new_mode_str = if (ce) |c| formatMode(c.mode) else "000000";

        try output.appendSlice("diff --git a/");
        try output.appendSlice(path);
        try output.appendSlice(" b/");
        try output.appendSlice(path);
        try output.append('\n');

        if (pe == null) {
            try output.appendSlice("new file mode ");
            try output.appendSlice(new_mode_str);
            try output.append('\n');
        } else if (ce == null) {
            try output.appendSlice("deleted file mode ");
            try output.appendSlice(old_mode_str);
            try output.append('\n');
        }

        try output.appendSlice("index ");
        try output.appendSlice(old_hex[0..7]);
        try output.appendSlice("..");
        try output.appendSlice(new_hex[0..7]);
        if (pe != null and ce != null) {
            try output.append(' ');
            try output.appendSlice(new_mode_str);
        }
        try output.append('\n');

        // Read file contents for diff
        const old_content = if (pe) |_| (objects.GitObject.load(old_hex, git_path, platform_impl, allocator) catch null) else null;
        defer if (old_content) |oc| oc.deinit(allocator);
        const new_content = if (ce) |_| (objects.GitObject.load(new_hex, git_path, platform_impl, allocator) catch null) else null;
        defer if (new_content) |nc| nc.deinit(allocator);

        const old_data = if (old_content) |oc| oc.data else "";
        const new_data = if (new_content) |nc| nc.data else "";

        if (pe == null) {
            try output.appendSlice("--- /dev/null\n+++ b/");
        } else if (ce == null) {
            try output.appendSlice("--- a/");
            try output.appendSlice(path);
            try output.appendSlice("\n+++ /dev/null\n");
        } else {
            try output.appendSlice("--- a/");
            try output.appendSlice(path);
            try output.appendSlice("\n+++ b/");
        }
        if (pe != null and ce != null) {
            try output.appendSlice(path);
            try output.append('\n');
        } else if (pe == null) {
            try output.appendSlice(path);
            try output.append('\n');
        }

        // Simple line-by-line diff
        var old_lines_count: usize = 0;
        var new_lines_count: usize = 0;
        {
            var it = std.mem.splitScalar(u8, old_data, '\n');
            while (it.next()) |_| old_lines_count += 1;
            if (old_data.len > 0 and old_data[old_data.len - 1] == '\n') old_lines_count -= 1;
        }
        {
            var it = std.mem.splitScalar(u8, new_data, '\n');
            while (it.next()) |_| new_lines_count += 1;
            if (new_data.len > 0 and new_data[new_data.len - 1] == '\n') new_lines_count -= 1;
        }

        const hunk_header = try std.fmt.allocPrint(allocator, "@@ -{d} +{d} @@\n", .{
            if (old_lines_count == 0) @as(usize, 0) else old_lines_count,
            if (new_lines_count == 0) @as(usize, 0) else new_lines_count,
        });
        defer allocator.free(hunk_header);
        try output.appendSlice(hunk_header);

        // Output old lines as removed, new lines as added
        if (old_data.len > 0) {
            var it = std.mem.splitScalar(u8, std.mem.trimRight(u8, old_data, "\n"), '\n');
            while (it.next()) |line| {
                try output.append('-');
                try output.appendSlice(line);
                try output.append('\n');
            }
        }
        if (new_data.len > 0) {
            var it = std.mem.splitScalar(u8, std.mem.trimRight(u8, new_data, "\n"), '\n');
            while (it.next()) |line| {
                try output.append('+');
                try output.appendSlice(line);
                try output.append('\n');
            }
        }
    }

    platform_impl.fs.writeFile(patch_path, output.items) catch {};
}

fn saveRebaseState(git_path: []const u8, todo_content: []const u8, onto_hash: []const u8, orig_head: []const u8, branch_name: []const u8, upstream_hash: []const u8, apply_mode: bool, opts: *RebaseOpts, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const dir_name = if (apply_mode) "rebase-apply" else "rebase-merge";
    const rebase_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, dir_name });
    defer allocator.free(rebase_dir);
    std.fs.cwd().makePath(rebase_dir) catch {};

    const write = struct {
        fn f(dir: []const u8, name: []const u8, content: []const u8, alloc: std.mem.Allocator, pi: *const Platform) void {
            const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name }) catch return;
            defer alloc.free(path);
            pi.fs.writeFile(path, content) catch {};
        }
    }.f;

    write(rebase_dir, "onto", onto_hash, allocator, platform_impl);
    write(rebase_dir, "orig-head", orig_head, allocator, platform_impl);
    write(rebase_dir, "upstream", upstream_hash, allocator, platform_impl);
    write(rebase_dir, "git-rebase-todo", todo_content, allocator, platform_impl);
    write(rebase_dir, "done", "", allocator, platform_impl);

    // head-name
    if (!std.mem.eql(u8, branch_name, "HEAD")) {
        const head_name_content = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name});
        defer allocator.free(head_name_content);
        write(rebase_dir, "head-name", head_name_content, allocator, platform_impl);
    } else {
        write(rebase_dir, "head-name", "detached HEAD", allocator, platform_impl);
    }

    // Count commits
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, todo_content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0 and trimmed[0] != '#') count += 1;
    }
    const total_str = try std.fmt.allocPrint(allocator, "{d}", .{count});
    defer allocator.free(total_str);
    write(rebase_dir, "end", total_str, allocator, platform_impl);
    write(rebase_dir, "msgnum", "0", allocator, platform_impl);

    // Write interactive flag
    if (opts.interactive or opts.has_exec) {
        write(rebase_dir, "interactive", "", allocator, platform_impl);
    }

    // Save strategy options
    if (opts.has_strategy_option) {
        if (opts.strategy_option) |so| {
            write(rebase_dir, "strategy_opts", so, allocator, platform_impl);
        }
    }

    // Reschedule failed exec
    if (opts.reschedule_failed_exec) |rfe| {
        if (rfe) {
            write(rebase_dir, "reschedule-failed-exec", "", allocator, platform_impl);
        }
    }
}

fn cleanupRebaseState(git_path: []const u8, allocator: std.mem.Allocator) void {
    const merge_dir = std.fmt.allocPrint(allocator, "{s}/rebase-merge", .{git_path}) catch return;
    defer allocator.free(merge_dir);
    removeDirectoryRecursive(merge_dir);

    const apply_dir = std.fmt.allocPrint(allocator, "{s}/rebase-apply", .{git_path}) catch return;
    defer allocator.free(apply_dir);
    removeDirectoryRecursive(apply_dir);

    const rh = std.fmt.allocPrint(allocator, "{s}/REBASE_HEAD", .{git_path}) catch return;
    defer allocator.free(rh);
    std.fs.cwd().deleteFile(rh) catch {};
}

fn removeDirectoryRecursive(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
}

fn invokeSequenceEditor(todo_path: []const u8, git_path: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !bool {
    // Check GIT_SEQUENCE_EDITOR env var first
    var editor: ?[]u8 = null;
    defer if (editor) |e| allocator.free(e);

    editor = std.process.getEnvVarOwned(allocator, "GIT_SEQUENCE_EDITOR") catch null;
    if (editor == null) {
        // Check sequence.editor config
        const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch return true;
        defer allocator.free(config_path);
        if (platform_impl.fs.readFile(allocator, config_path)) |cfg| {
            defer allocator.free(cfg);
            if (findConfigValue(cfg, "sequence", null, "editor")) |val| {
                editor = allocator.dupe(u8, val) catch null;
            }
        } else |_| {}
    }

    // Fall back to GIT_EDITOR, then core.editor, then VISUAL, then EDITOR
    if (editor == null) editor = std.process.getEnvVarOwned(allocator, "GIT_EDITOR") catch null;
    if (editor == null) {
        const config_path2 = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch return true;
        defer allocator.free(config_path2);
        if (platform_impl.fs.readFile(allocator, config_path2)) |cfg| {
            defer allocator.free(cfg);
            if (findConfigValue(cfg, "core", null, "editor")) |val| {
                editor = allocator.dupe(u8, val) catch null;
            }
        } else |_| {}
    }
    if (editor == null) editor = std.process.getEnvVarOwned(allocator, "VISUAL") catch null;
    if (editor == null) editor = std.process.getEnvVarOwned(allocator, "EDITOR") catch null;

    if (editor == null) return true; // No editor configured, proceed as-is

    const ed = editor.?;
    if (std.mem.eql(u8, ed, ":")) return true; // noop editor

    // Build command: <editor> <todo_path>
    const cmd = try std.fmt.allocPrint(allocator, "{s} \"{s}\"", .{ ed, todo_path });
    defer allocator.free(cmd);

    return try runShellCommand(cmd, allocator);
}

fn invokeCommitEditor(editmsg_path: []const u8, git_path: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !bool {
    // Check GIT_EDITOR, then core.editor, then VISUAL, then EDITOR
    var editor: ?[]u8 = null;
    defer if (editor) |e| allocator.free(e);

    editor = std.process.getEnvVarOwned(allocator, "GIT_EDITOR") catch null;
    if (editor == null) {
        const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch return false;
        defer allocator.free(config_path);
        if (platform_impl.fs.readFile(allocator, config_path)) |cfg| {
            defer allocator.free(cfg);
            if (findConfigValue(cfg, "core", null, "editor")) |val| {
                editor = allocator.dupe(u8, val) catch null;
            }
        } else |_| {}
    }
    if (editor == null) editor = std.process.getEnvVarOwned(allocator, "VISUAL") catch null;
    if (editor == null) editor = std.process.getEnvVarOwned(allocator, "EDITOR") catch null;
    if (editor == null) return false;

    const ed = editor.?;
    if (std.mem.eql(u8, ed, ":")) return true;

    const cmd = try std.fmt.allocPrint(allocator, "{s} \"{s}\"", .{ ed, editmsg_path });
    defer allocator.free(cmd);

    return try runShellCommand(cmd, allocator);
}

fn runShellCommand(cmd: []const u8, allocator: std.mem.Allocator) !bool {
    // Need null-terminated
    const cmd_z = try allocator.dupeZ(u8, cmd);
    defer allocator.free(cmd_z);

    const pid = try std.posix.fork();
    if (pid == 0) {
        // Child
        const argv = [_:null]?[*:0]const u8{
            "/bin/sh",
            "-c",
            cmd_z,
            null,
        };
        _ = std.posix.execveZ("/bin/sh", &argv, @ptrCast(std.os.environ.ptr)) catch {};
        std.process.exit(127);
    }
    const result = std.posix.waitpid(pid, 0);
    if (std.posix.W.IFEXITED(result.status)) {
        return std.posix.W.EXITSTATUS(result.status) == 0;
    }
    return false;
}

fn stripCommentLines(text: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "#")) {
            try buf.appendSlice(line);
            try buf.append('\n');
        }
    }
    // Trim trailing newlines
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n') {
        _ = buf.pop();
    }
    if (buf.items.len > 0) try buf.append('\n');
    return buf.toOwnedSlice();
}

// ============================================================================
// Git object helpers (reimplemented to avoid dependency on private main_common fns)
// ============================================================================

fn getCommitTree(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) ![]u8 {
    const commit_obj = try objects.GitObject.load(commit_hash, git_path, platform_impl, allocator);
    defer commit_obj.deinit(allocator);
    if (commit_obj.type != .commit) return error.NotACommit;
    var lines = std.mem.splitSequence(u8, commit_obj.data, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ")) {
            return try allocator.dupe(u8, line["tree ".len..]);
        }
        if (line.len == 0) break;
    }
    return error.InvalidCommit;
}

fn getCommitFirstParent(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) ![]u8 {
    const commit_obj = try objects.GitObject.load(commit_hash, git_path, platform_impl, allocator);
    defer commit_obj.deinit(allocator);
    if (commit_obj.type != .commit) return error.NotACommit;
    var lines = std.mem.splitSequence(u8, commit_obj.data, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "parent ")) return try allocator.dupe(u8, line["parent ".len..]);
        if (line.len == 0) break;
    }
    return error.NoParent;
}

fn getCommitMessage(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) ![]u8 {
    const commit_obj = try objects.GitObject.load(commit_hash, git_path, platform_impl, allocator);
    defer commit_obj.deinit(allocator);
    if (commit_obj.type != .commit) return error.NotACommit;
    if (std.mem.indexOf(u8, commit_obj.data, "\n\n")) |pos| {
        return try allocator.dupe(u8, commit_obj.data[pos + 2 ..]);
    }
    return try allocator.dupe(u8, "");
}

fn getCommitAuthorLine(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) ![]u8 {
    const commit_obj = try objects.GitObject.load(commit_hash, git_path, platform_impl, allocator);
    defer commit_obj.deinit(allocator);
    if (commit_obj.type != .commit) return error.NotACommit;
    var lines = std.mem.splitSequence(u8, commit_obj.data, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "author ")) return try allocator.dupe(u8, line["author ".len..]);
        if (line.len == 0) break;
    }
    return error.NoAuthor;
}

fn getCommitSubject(hash: []const u8, git_path: []const u8, platform_impl: *const Platform, allocator: std.mem.Allocator) ![]u8 {
    const msg = try getCommitMessage(git_path, hash, allocator, platform_impl);
    defer allocator.free(msg);
    const trimmed = std.mem.trimLeft(u8, msg, " \t\n\r");
    if (std.mem.indexOfScalar(u8, trimmed, '\n')) |nl| {
        return try allocator.dupe(u8, trimmed[0..nl]);
    }
    return try allocator.dupe(u8, trimmed);
}

fn getCommitterString(allocator: std.mem.Allocator) ![]u8 {
    const name = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_NAME") catch try allocator.dupe(u8, "C O Mitter");
    defer allocator.free(name);
    const email = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_EMAIL") catch try allocator.dupe(u8, "committer@example.com");
    defer allocator.free(email);
    const date = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_DATE") catch null;
    defer if (date) |d| allocator.free(d);
    if (date) |d| {
        // Parse @<timestamp> <tz> format
        if (std.mem.startsWith(u8, d, "@")) {
            return try std.fmt.allocPrint(allocator, "{s} <{s}> {s}", .{ name, email, d[1..] });
        }
        return try std.fmt.allocPrint(allocator, "{s} <{s}> {s}", .{ name, email, d });
    }
    const timestamp = std.time.timestamp();
    return try std.fmt.allocPrint(allocator, "{s} <{s}> {d} +0000", .{ name, email, timestamp });
}

fn getAuthorString(allocator: std.mem.Allocator) ![]u8 {
    const name = std.process.getEnvVarOwned(allocator, "GIT_AUTHOR_NAME") catch try allocator.dupe(u8, "A U Thor");
    defer allocator.free(name);
    const email = std.process.getEnvVarOwned(allocator, "GIT_AUTHOR_EMAIL") catch try allocator.dupe(u8, "author@example.com");
    defer allocator.free(email);
    const date = std.process.getEnvVarOwned(allocator, "GIT_AUTHOR_DATE") catch null;
    defer if (date) |d| allocator.free(d);
    if (date) |d| {
        if (std.mem.startsWith(u8, d, "@")) {
            return try std.fmt.allocPrint(allocator, "{s} <{s}> {s}", .{ name, email, d[1..] });
        }
        return try std.fmt.allocPrint(allocator, "{s} <{s}> {s}", .{ name, email, d });
    }
    const timestamp = std.time.timestamp();
    return try std.fmt.allocPrint(allocator, "{s} <{s}> {d} +0000", .{ name, email, timestamp });
}

fn collectCommitsToReplay(git_path: []const u8, head_hash: []const u8, base_hash: []const u8, commits: *std.array_list.Managed([]u8), allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    var current = try allocator.dupe(u8, head_hash);
    var depth: usize = 0;
    while (depth < 10000) : (depth += 1) {
        if (std.mem.eql(u8, current, base_hash)) {
            allocator.free(current);
            break;
        }
        try commits.append(current);
        const parent = getCommitFirstParent(git_path, current, allocator, platform_impl) catch {
            break;
        };
        current = parent;
    }
    std.mem.reverse([]u8, commits.items);
}

fn checkRebaseClean(git_path: []const u8, repo_root: []const u8, head_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    _ = repo_root;
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
    defer idx.deinit();

    const head_tree = getCommitTree(git_path, head_hash, allocator, platform_impl) catch return;
    defer allocator.free(head_tree);

    // Collect HEAD tree entries to compare with index
    var tree_map = std.StringHashMap([20]u8).init(allocator);
    defer tree_map.deinit();
    var tree_count: usize = 0;
    {
        var tree_entries_list = std.array_list.Managed(TreeFileEntry).init(allocator);
        defer {
            for (tree_entries_list.items) |*e| allocator.free(e.path);
            tree_entries_list.deinit();
        }
        collectTreeEntriesForCheck(git_path, head_tree, "", &tree_entries_list, allocator, platform_impl) catch {};
        tree_count = tree_entries_list.items.len;
        for (tree_entries_list.items) |e| {
            tree_map.put(e.path, e.sha1) catch {};
        }
    }

    // Check if index differs from HEAD tree
    for (idx.entries.items) |entry| {
        if (tree_map.get(entry.path)) |tree_sha| {
            if (!std.mem.eql(u8, &entry.sha1, &tree_sha)) {
                try platform_impl.writeStderr("error: cannot rebase: Your index contains uncommitted changes.\n");
                std.process.exit(1);
            }
        } else {
            try platform_impl.writeStderr("error: cannot rebase: Your index contains uncommitted changes.\n");
            std.process.exit(1);
        }
    }
    if (idx.entries.items.len != tree_count) {
        try platform_impl.writeStderr("error: cannot rebase: Your index contains uncommitted changes.\n");
        std.process.exit(1);
    }

    // Check working tree
    var dir = std.fs.cwd().openDir(std.fs.path.dirname(git_path) orelse ".", .{}) catch return;
    defer dir.close();
    for (idx.entries.items) |entry| {
        const stat = dir.statFile(entry.path) catch continue;
        if (entry.size > 0 and stat.size != entry.size) {
            try platform_impl.writeStderr("error: cannot rebase: You have unstaged changes.\nerror: Please commit or stash them.\n");
            std.process.exit(1);
        }
        // Check mtime
        const mtime_sec: u32 = @intCast(@max(0, @divFloor(stat.mtime, std.time.ns_per_s)));
        if (entry.mtime_sec > 0 and mtime_sec != entry.mtime_sec) {
            const file_content = dir.readFileAlloc(allocator, entry.path, 10 * 1024 * 1024) catch continue;
            defer allocator.free(file_content);
            const blob = objects.createBlobObject(file_content, allocator) catch continue;
            defer blob.deinit(allocator);
            const hash = blob.hash(allocator) catch continue;
            defer allocator.free(hash);
            var expected_hex: [40]u8 = undefined;
            for (entry.sha1, 0..) |b, j| {
                const hex_chars = "0123456789abcdef";
                expected_hex[j * 2] = hex_chars[b >> 4];
                expected_hex[j * 2 + 1] = hex_chars[b & 0xf];
            }
            if (!std.mem.eql(u8, hash, &expected_hex)) {
                try platform_impl.writeStderr("error: cannot rebase: You have unstaged changes.\nerror: Please commit or stash them.\n");
                std.process.exit(1);
            }
        }
    }
}

fn checkUntrackedConflicts(git_path: []const u8, onto_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    // Check for untracked files in the worktree that would conflict with files
    // that need to be checked out during the rebase (i.e., new files in the
    // commits being replayed or onto target that don't exist in HEAD).

    // We need to check what files will be added to the worktree during rebase.
    // The most important case: files in onto's tree that are NOT in HEAD tree
    // and NOT in the index, but DO exist on disk as untracked files.

    // Get the tree of the onto commit
    const onto_tree = getCommitTree(git_path, onto_hash, allocator, platform_impl) catch return;
    defer allocator.free(onto_tree);

    // Get current HEAD tree
    const head_hash = (refs.getCurrentCommit(git_path, platform_impl, allocator) catch return) orelse return;
    defer allocator.free(head_hash);
    const head_tree = getCommitTree(git_path, head_hash, allocator, platform_impl) catch return;
    defer allocator.free(head_tree);

    // If onto tree == head tree, no conflicts possible
    if (std.mem.eql(u8, onto_tree, head_tree)) return;

    // Collect files in onto tree but not in HEAD tree
    var onto_entries = std.array_list.Managed(TreeFileEntry).init(allocator);
    defer {
        for (onto_entries.items) |*e| allocator.free(e.path);
        onto_entries.deinit();
    }
    collectTreeEntriesForCheck(git_path, onto_tree, "", &onto_entries, allocator, platform_impl) catch {};

    var onto_map = std.StringHashMap([20]u8).init(allocator);
    defer onto_map.deinit();
    for (onto_entries.items) |e| onto_map.put(e.path, e.sha1) catch {};

    var head_entries = std.array_list.Managed(TreeFileEntry).init(allocator);
    defer {
        for (head_entries.items) |*e| allocator.free(e.path);
        head_entries.deinit();
    }
    collectTreeEntriesForCheck(git_path, head_tree, "", &head_entries, allocator, platform_impl) catch {};

    var head_files = std.StringHashMap(void).init(allocator);
    defer head_files.deinit();
    for (head_entries.items) |e| head_files.put(e.path, {}) catch {};

    // Also load the current index to know what's tracked
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
    defer idx.deinit();
    var indexed_files = std.StringHashMap(void).init(allocator);
    defer indexed_files.deinit();
    for (idx.entries.items) |entry| {
        indexed_files.put(entry.path, {}) catch {};
    }

    // Check for files in onto that are NOT in HEAD/index but exist as untracked on disk
    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    var conflicts = std.array_list.Managed([]const u8).init(allocator);
    defer conflicts.deinit();

    var dir = std.fs.cwd().openDir(repo_root, .{}) catch return;
    defer dir.close();

    var it = onto_map.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.*;
        if (!head_files.contains(path) and !indexed_files.contains(path)) {
            // This file is in onto but not in HEAD/index. Check if it exists on disk (truly untracked)
            const full_path2 = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path }) catch continue;
            defer allocator.free(full_path2);
            if (platform_impl.fs.readFile(allocator, full_path2)) |disk_content| {
                defer allocator.free(disk_content);
                // Compare with onto blob content
                const onto_sha = entry.value_ptr.*;
                var hex2: [40]u8 = undefined;
                for (onto_sha, 0..) |b, bi| {
                    const hx = "0123456789abcdef";
                    hex2[bi * 2] = hx[b >> 4];
                    hex2[bi * 2 + 1] = hx[b & 0xf];
                }
                const blob_obj2 = objects.GitObject.load(&hex2, git_path, platform_impl, allocator) catch {
                    conflicts.append(path) catch {};
                    continue;
                };
                defer blob_obj2.deinit(allocator);
                if (blob_obj2.type == .blob and std.mem.eql(u8, blob_obj2.data, disk_content)) {
                    // Same content - not a real conflict
                } else {
                    conflicts.append(path) catch {};
                }
            } else |_| {}
        }
    }

    if (conflicts.items.len > 0) {
        try platform_impl.writeStderr("error: The following untracked working tree files would be overwritten by checkout:\n");
        for (conflicts.items) |path| {
            try platform_impl.writeStderr("\t");
            try platform_impl.writeStderr(path);
            try platform_impl.writeStderr("\n");
        }
        try platform_impl.writeStderr("Please move or remove them before you switch branches.\nAborting\n");
        cleanupRebaseState(git_path, allocator);
        std.process.exit(1);
    }
}

const TreeFileEntry = struct {
    path: []u8,
    sha1: [20]u8,
};

fn collectTreeEntriesForCheck(git_path: []const u8, tree_hash: []const u8, prefix: []const u8, entries: *std.array_list.Managed(TreeFileEntry), allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const tree_obj = try objects.GitObject.load(tree_hash, git_path, platform_impl, allocator);
    defer tree_obj.deinit(allocator);

    var pos: usize = 0;
    while (pos < tree_obj.data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, pos, ' ') orelse break;
        const mode_str = tree_obj.data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, space_pos, 0) orelse break;
        const name = tree_obj.data[space_pos + 1 .. null_pos];
        if (null_pos + 21 > tree_obj.data.len) break;
        const sha1_bytes = tree_obj.data[null_pos + 1 .. null_pos + 21];

        var hex_hash: [40]u8 = undefined;
        for (sha1_bytes, 0..) |b, bi| {
            const hex = "0123456789abcdef";
            hex_hash[bi * 2] = hex[b >> 4];
            hex_hash[bi * 2 + 1] = hex[b & 0xf];
        }

        const full_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);

        if (std.mem.eql(u8, mode_str, "40000")) {
            defer allocator.free(full_name);
            try collectTreeEntriesForCheck(git_path, &hex_hash, full_name, entries, allocator, platform_impl);
        } else {
            try entries.append(.{ .path = full_name, .sha1 = sha1_bytes[0..20].* });
        }
        pos = null_pos + 21;
    }
}

fn resolveOnto(git_path: []const u8, onto: ?[]const u8, keep_base: bool, head_hash: []const u8, upstream_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) ![]u8 {
    if (onto) |onto_ref| {
        if (std.mem.endsWith(u8, onto_ref, "...")) {
            const base_ref = onto_ref[0 .. onto_ref.len - 3];
            const base_h = try git_helpers_mod.resolveRevision(git_path, base_ref, platform_impl, allocator);
            defer allocator.free(base_h);
            return findMergeBase(git_path, base_h, head_hash, allocator, platform_impl) catch try allocator.dupe(u8, base_h);
        }
        if (std.mem.indexOf(u8, onto_ref, "...")) |dot_pos| {
            const left = onto_ref[0..dot_pos];
            const right = onto_ref[dot_pos + 3 ..];
            const lh = try git_helpers_mod.resolveRevision(git_path, left, platform_impl, allocator);
            defer allocator.free(lh);
            const rh = try git_helpers_mod.resolveRevision(git_path, right, platform_impl, allocator);
            defer allocator.free(rh);
            return findMergeBase(git_path, lh, rh, allocator, platform_impl) catch try allocator.dupe(u8, lh);
        }
        return git_helpers_mod.resolveRevision(git_path, onto_ref, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: invalid --onto '{s}'\n", .{onto_ref});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
    } else if (keep_base) {
        return findMergeBase(git_path, head_hash, upstream_hash, allocator, platform_impl) catch try allocator.dupe(u8, upstream_hash);
    } else {
        return try allocator.dupe(u8, upstream_hash);
    }
}

fn findMergeBase(git_path: []const u8, hash1: []const u8, hash2: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) ![]u8 {
    // Walk both ancestor chains and find common commit
    var ancestors1 = std.StringHashMap(void).init(allocator);
    defer ancestors1.deinit();

    var current = try allocator.dupe(u8, hash1);
    var depth: usize = 0;
    while (depth < 10000) : (depth += 1) {
        ancestors1.put(current, {}) catch {};
        const parent = getCommitFirstParent(git_path, current, allocator, platform_impl) catch break;
        current = parent;
    }

    current = try allocator.dupe(u8, hash2);
    depth = 0;
    while (depth < 10000) : (depth += 1) {
        if (ancestors1.contains(current)) {
            return current;
        }
        const parent = getCommitFirstParent(git_path, current, allocator, platform_impl) catch break;
        allocator.free(current);
        current = parent;
    }
    allocator.free(current);
    return error.NoMergeBase;
}

fn checkoutCommitTree(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const tree_hash = getCommitTree(git_path, commit_hash, allocator, platform_impl) catch return;
    defer allocator.free(tree_hash);

    const repo_root = std.fs.path.dirname(git_path) orelse ".";

    // Only remove tracked files (from index), leave untracked files alone
    clearTrackedFiles(git_path, repo_root, allocator, platform_impl) catch {};

    // Load tree and checkout
    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch return;
    defer tree_obj.deinit(allocator);
    if (tree_obj.type == .tree) {
        checkoutTreeRecursive(git_path, tree_obj.data, repo_root, "", allocator, platform_impl) catch {};
    }

    // Update index
    updateIndexFromTree(git_path, tree_hash, allocator, platform_impl) catch {};
}

fn clearTrackedFiles(git_path: []const u8, repo_root: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    // Only remove files that are in the current index (tracked files)
    // Leave untracked files alone to match real git behavior
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
    defer idx.deinit();

    for (idx.entries.items) |entry| {
        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path }) catch continue;
        defer allocator.free(full_path);
        std.fs.cwd().deleteFile(full_path) catch {};
    }

    // Try to remove now-empty directories (best effort)
    // Collect unique directory paths from index entries
    var dirs = std.StringHashMap(void).init(allocator);
    defer dirs.deinit();
    for (idx.entries.items) |entry| {
        if (std.mem.lastIndexOfScalar(u8, entry.path, '/')) |slash| {
            dirs.put(entry.path[0..slash], {}) catch {};
        }
    }
    var dir_it = dirs.iterator();
    while (dir_it.next()) |d| {
        const dir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, d.key_ptr.* }) catch continue;
        defer allocator.free(dir_path);
        std.fs.cwd().deleteDir(dir_path) catch {};
    }
}

fn clearWorkingDirectory(repo_root: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    _ = platform_impl;
    var dir = std.fs.cwd().openDir(repo_root, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        if (std.mem.eql(u8, entry.name, ".gitmodules")) continue;
        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.name }) catch continue;
        defer allocator.free(full);
        if (entry.kind == .directory) {
            std.fs.cwd().deleteTree(full) catch {};
        } else {
            std.fs.cwd().deleteFile(full) catch {};
        }
    }
}

fn checkoutTreeRecursive(git_path: []const u8, tree_data: []const u8, repo_root: []const u8, current_path: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    var pos: usize = 0;
    while (pos < tree_data.len) {
        // Parse: <mode> <name>\0<20-byte-sha1>
        const space_pos = std.mem.indexOfScalarPos(u8, tree_data, pos, ' ') orelse break;
        const mode = tree_data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, tree_data, space_pos, 0) orelse break;
        const name = tree_data[space_pos + 1 .. null_pos];
        if (null_pos + 21 > tree_data.len) break;
        const sha1_bytes = tree_data[null_pos + 1 .. null_pos + 21];

        // Convert binary hash to hex
        var hex_hash: [40]u8 = undefined;
        for (sha1_bytes, 0..) |b, bi| {
            const hex = "0123456789abcdef";
            hex_hash[bi * 2] = hex[b >> 4];
            hex_hash[bi * 2 + 1] = hex[b & 0xf];
        }

        const full_path = if (current_path.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ repo_root, current_path, name })
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, name });
        defer allocator.free(full_path);

        if (std.mem.eql(u8, mode, "40000")) {
            // Directory - recurse
            std.fs.cwd().makePath(full_path) catch {};
            const sub_tree = objects.GitObject.load(&hex_hash, git_path, platform_impl, allocator) catch {
                pos = null_pos + 21;
                continue;
            };
            defer sub_tree.deinit(allocator);
            const sub_path = if (current_path.len > 0)
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_path, name })
            else
                try allocator.dupe(u8, name);
            defer allocator.free(sub_path);
            try checkoutTreeRecursive(git_path, sub_tree.data, repo_root, sub_path, allocator, platform_impl);
        } else {
            // File
            const blob_obj = objects.GitObject.load(&hex_hash, git_path, platform_impl, allocator) catch {
                pos = null_pos + 21;
                continue;
            };
            defer blob_obj.deinit(allocator);

            // Ensure parent directory exists
            if (std.fs.path.dirname(full_path)) |parent| {
                std.fs.cwd().makePath(parent) catch {};
            }

            // Write file
            std.fs.cwd().writeFile(.{ .sub_path = full_path, .data = blob_obj.data }) catch {};

            // Set executable if mode is 100755
            if (std.mem.eql(u8, mode, "100755")) {
                var f = std.fs.cwd().openFile(full_path, .{ .mode = .read_write }) catch continue;
                defer f.close();
                f.chmod(0o755) catch {};
            }
        }
        pos = null_pos + 21;
    }
}

fn updateIndexFromTree(git_path: []const u8, tree_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    var idx = index_mod.Index.init(allocator);
    defer idx.deinit();
    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    try populateIndexFromTree(git_path, tree_hash, repo_root, "", &idx, allocator, platform_impl);
    idx.save(git_path, platform_impl) catch {};
}

fn populateIndexFromTree(git_path: []const u8, tree_hash: []const u8, repo_root: []const u8, prefix: []const u8, idx: *index_mod.Index, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const tree_obj = try objects.GitObject.load(tree_hash, git_path, platform_impl, allocator);
    defer tree_obj.deinit(allocator);

    var pos: usize = 0;
    while (pos < tree_obj.data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, pos, ' ') orelse break;
        const mode_str = tree_obj.data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, space_pos, 0) orelse break;
        const name = tree_obj.data[space_pos + 1 .. null_pos];
        if (null_pos + 21 > tree_obj.data.len) break;
        const sha1_bytes = tree_obj.data[null_pos + 1 .. null_pos + 21];

        var hex_hash: [40]u8 = undefined;
        for (sha1_bytes, 0..) |b, bi| {
            const hex = "0123456789abcdef";
            hex_hash[bi * 2] = hex[b >> 4];
            hex_hash[bi * 2 + 1] = hex[b & 0xf];
        }

        const full_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);

        if (std.mem.eql(u8, mode_str, "40000")) {
            // Directory - recurse
            defer allocator.free(full_name);
            try populateIndexFromTree(git_path, &hex_hash, repo_root, full_name, idx, allocator, platform_impl);
        } else {
            // File entry
            const mode: u32 = if (std.mem.eql(u8, mode_str, "100755")) 0o100755 else if (std.mem.eql(u8, mode_str, "120000")) 0o120000 else 0o100644;

            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, full_name });
            defer allocator.free(full_path);
            const stat = std.fs.cwd().statFile(full_path) catch std.fs.File.Stat{
                .inode = 0,
                .size = 0,
                .mode = @truncate(mode),
                .mtime = 0,
                .ctime = 0,
                .atime = 0,
                .kind = .file,
            };

            const entry = index_mod.IndexEntry.init(full_name, stat, sha1_bytes[0..20].*);
            try idx.entries.append(entry);
        }
        pos = null_pos + 21;
    }
}

fn writeTreeFromIndex(allocator: std.mem.Allocator, idx: *index_mod.Index, git_dir: []const u8, platform_impl: *const Platform) ![]u8 {
    return try writeTreeRecursive(allocator, idx, "", git_dir, platform_impl);
}

fn writeTreeRecursive(allocator: std.mem.Allocator, idx: *index_mod.Index, prefix: []const u8, git_dir: []const u8, platform_impl: *const Platform) ![]u8 {
    // Build tree data from index entries
    var tree_data = std.array_list.Managed(u8).init(allocator);
    defer tree_data.deinit();

    var seen_dirs = std.StringHashMap(void).init(allocator);
    defer seen_dirs.deinit();

    for (idx.entries.items) |entry| {
        // Check if this entry belongs under our prefix
        if (prefix.len > 0) {
            if (!std.mem.startsWith(u8, entry.path, prefix) or entry.path.len <= prefix.len or entry.path[prefix.len] != '/') continue;
        }

        const relative = if (prefix.len > 0) entry.path[prefix.len + 1 ..] else entry.path;

        if (std.mem.indexOfScalar(u8, relative, '/')) |slash| {
            // This is in a subdirectory
            const dir_name = relative[0..slash];
            const dir_key = if (prefix.len > 0) try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, dir_name }) else try allocator.dupe(u8, dir_name);
            defer allocator.free(dir_key);

            if (!seen_dirs.contains(dir_name)) {
                seen_dirs.put(try allocator.dupe(u8, dir_name), {}) catch {};
                // Recurse to build subtree
                const sub_tree_hash = try writeTreeRecursive(allocator, idx, dir_key, git_dir, platform_impl);
                defer allocator.free(sub_tree_hash);

                // Add directory entry
                try tree_data.appendSlice("40000 ");
                try tree_data.appendSlice(dir_name);
                try tree_data.append(0);
                // Convert hex hash to binary
                var bin_hash: [20]u8 = undefined;
                for (0..20) |bi| {
                    bin_hash[bi] = std.fmt.parseInt(u8, sub_tree_hash[bi * 2 .. bi * 2 + 2], 16) catch 0;
                }
                try tree_data.appendSlice(&bin_hash);
            }
        } else {
            // Direct file entry
            const mode_str = if (entry.mode == 0o100755) "100755" else if (entry.mode == 0o120000) "120000" else "100644";
            try tree_data.appendSlice(mode_str);
            try tree_data.append(' ');
            try tree_data.appendSlice(relative);
            try tree_data.append(0);
            try tree_data.appendSlice(&entry.sha1);
        }
    }

    const tree_obj = objects.GitObject{ .type = .tree, .data = tree_data.items };
    return try tree_obj.store(git_dir, platform_impl, allocator);
}

fn cherryPickCommit(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) ![]u8 {
    const commit_obj = try objects.GitObject.load(commit_hash, git_path, platform_impl, allocator);
    defer commit_obj.deinit(allocator);
    if (commit_obj.type != .commit) return error.NotACommit;

    var tree_hash: ?[]const u8 = null;
    var parent_hash: ?[]const u8 = null;
    var author_line: ?[]const u8 = null;
    var committer_line_orig: ?[]const u8 = null;
    var lines_iter = std.mem.splitSequence(u8, commit_obj.data, "\n");
    var header_end: usize = 0;
    var pos: usize = 0;

    while (lines_iter.next()) |line| {
        if (line.len == 0) {
            header_end = pos + 1;
            break;
        }
        if (std.mem.startsWith(u8, line, "tree ")) tree_hash = line["tree ".len..];
        if (std.mem.startsWith(u8, line, "parent ") and parent_hash == null) parent_hash = line["parent ".len..];
        if (std.mem.startsWith(u8, line, "author ")) author_line = line["author ".len..];
        if (std.mem.startsWith(u8, line, "committer ")) committer_line_orig = line["committer ".len..];
        pos += line.len + 1;
    }

    const commit_tree = tree_hash orelse return error.InvalidCommit;
    const original_author = author_line orelse return error.InvalidCommit;
    const commit_message = if (header_end < commit_obj.data.len) commit_obj.data[header_end..] else "";

    const current_hash = (try refs.getCurrentCommit(git_path, platform_impl, allocator)) orelse return error.NoHead;
    defer allocator.free(current_hash);

    // Fast-forward optimization: if the commit's parent is current HEAD,
    // we can reuse the original commit directly (no need to re-create it)
    if (parent_hash) |ph| {
        if (std.mem.eql(u8, ph, current_hash)) {
            // The commit's parent is our current HEAD - just advance to this commit
            const repo_root = std.fs.path.dirname(git_path) orelse ".";
            clearTrackedFiles(git_path, repo_root, allocator, platform_impl) catch {};
            const t_obj = objects.GitObject.load(commit_tree, git_path, platform_impl, allocator) catch return error.InvalidCommit;
            defer t_obj.deinit(allocator);
            if (t_obj.type == .tree) {
                checkoutTreeRecursive(git_path, t_obj.data, repo_root, "", allocator, platform_impl) catch {};
            }
            updateIndexFromTree(git_path, commit_tree, allocator, platform_impl) catch {};
            return try allocator.dupe(u8, commit_hash);
        }
    }

    const current_tree = try getCommitTree(git_path, current_hash, allocator, platform_impl);
    defer allocator.free(current_tree);

    const base_tree = if (parent_hash) |ph|
        getCommitTree(git_path, ph, allocator, platform_impl) catch try allocator.dupe(u8, current_tree)
    else
        try allocator.dupe(u8, current_tree);
    defer allocator.free(base_tree);

    var new_tree: []u8 = undefined;
    if (std.mem.eql(u8, base_tree, current_tree)) {
        new_tree = try allocator.dupe(u8, commit_tree);
        const repo_root = std.fs.path.dirname(git_path) orelse ".";
        clearTrackedFiles(git_path, repo_root, allocator, platform_impl) catch {};
        const t_obj = objects.GitObject.load(commit_tree, git_path, platform_impl, allocator) catch return error.InvalidCommit;
        defer t_obj.deinit(allocator);
        if (t_obj.type == .tree) {
            checkoutTreeRecursive(git_path, t_obj.data, repo_root, "", allocator, platform_impl) catch {};
        }
        updateIndexFromTree(git_path, commit_tree, allocator, platform_impl) catch {};
    } else if (std.mem.eql(u8, base_tree, commit_tree)) {
        new_tree = try allocator.dupe(u8, current_tree);
    } else if (std.mem.eql(u8, current_tree, commit_tree)) {
        new_tree = try allocator.dupe(u8, current_tree);
    } else {
        // 3-way merge needed
        const has_conflicts = try threeWayMerge(git_path, base_tree, current_tree, commit_tree, commit_hash, allocator, platform_impl);
        if (has_conflicts) {
            return error.MergeConflict;
        }
        var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return error.IndexError;
        defer idx.deinit();
        new_tree = try writeTreeFromIndex(allocator, &idx, git_path, platform_impl);
    }
    defer allocator.free(new_tree);

    const committer_line = getCommitterString(allocator) catch try allocator.dupe(u8, "Unknown <unknown> 0 +0000");
    defer allocator.free(committer_line);

    const parents = [_][]const u8{current_hash};
    const new_commit = try objects.createCommitObject(new_tree, &parents, original_author, committer_line, commit_message, allocator);
    defer new_commit.deinit(allocator);
    return try new_commit.store(git_path, platform_impl, allocator);
}

fn threeWayMerge(git_path: []const u8, base_tree: []const u8, ours_tree: []const u8, theirs_tree: []const u8, theirs_commit: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !bool {
    // Simplified 3-way merge: collect entries from all three trees,
    // merge file by file
    var base_entries = std.StringHashMap(FileEntry).init(allocator);
    defer base_entries.deinit();
    var ours_entries = std.StringHashMap(FileEntry).init(allocator);
    defer ours_entries.deinit();
    var theirs_entries = std.StringHashMap(FileEntry).init(allocator);
    defer theirs_entries.deinit();

    try collectTreeEntriesFlat(git_path, base_tree, "", &base_entries, allocator, platform_impl);
    try collectTreeEntriesFlat(git_path, ours_tree, "", &ours_entries, allocator, platform_impl);
    try collectTreeEntriesFlat(git_path, theirs_tree, "", &theirs_entries, allocator, platform_impl);

    var idx = index_mod.Index.init(allocator);
    defer idx.deinit();
    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    var has_conflicts = false;

    // Collect all paths
    var all_paths = std.StringHashMap(void).init(allocator);
    defer all_paths.deinit();
    {
        var it = base_entries.iterator();
        while (it.next()) |e| all_paths.put(e.key_ptr.*, {}) catch {};
    }
    {
        var it = ours_entries.iterator();
        while (it.next()) |e| all_paths.put(e.key_ptr.*, {}) catch {};
    }
    {
        var it = theirs_entries.iterator();
        while (it.next()) |e| all_paths.put(e.key_ptr.*, {}) catch {};
    }

    var paths_it = all_paths.iterator();
    while (paths_it.next()) |path_entry| {
        const path = path_entry.key_ptr.*;
        const base = base_entries.get(path);
        const ours = ours_entries.get(path);
        const theirs = theirs_entries.get(path);

        // Determine merge result
        if (ours != null and theirs != null) {
            if (std.mem.eql(u8, &ours.?.sha1, &theirs.?.sha1)) {
                // Same change - use either
                try addIndexEntry(&idx, path, ours.?.sha1, ours.?.mode, repo_root, allocator);
                try writeFileFromBlob(git_path, repo_root, path, &ours.?.sha1, allocator, platform_impl);
            } else if (base != null and std.mem.eql(u8, &base.?.sha1, &theirs.?.sha1)) {
                // Only ours changed
                try addIndexEntry(&idx, path, ours.?.sha1, ours.?.mode, repo_root, allocator);
                try writeFileFromBlob(git_path, repo_root, path, &ours.?.sha1, allocator, platform_impl);
            } else if (base != null and std.mem.eql(u8, &base.?.sha1, &ours.?.sha1)) {
                // Only theirs changed
                try addIndexEntry(&idx, path, theirs.?.sha1, theirs.?.mode, repo_root, allocator);
                try writeFileFromBlob(git_path, repo_root, path, &theirs.?.sha1, allocator, platform_impl);
            } else {
                // Conflict!
                has_conflicts = true;
                // Write conflict markers
                try writeConflictFile(git_path, repo_root, path, base, ours.?, theirs.?, theirs_commit, allocator, platform_impl);
                // Add to index as unmerged (stages 1,2,3)
                if (base) |b| {
                    try addIndexEntryStaged(&idx, path, b.sha1, b.mode, repo_root, allocator, 1);
                }
                try addIndexEntryStaged(&idx, path, ours.?.sha1, ours.?.mode, repo_root, allocator, 2);
                try addIndexEntryStaged(&idx, path, theirs.?.sha1, theirs.?.mode, repo_root, allocator, 3);
            }
        } else if (ours != null and theirs == null) {
            if (base != null and std.mem.eql(u8, &base.?.sha1, &ours.?.sha1)) {
                // Deleted in theirs, unchanged in ours - delete
            } else if (base == null) {
                // Added in ours only
                try addIndexEntry(&idx, path, ours.?.sha1, ours.?.mode, repo_root, allocator);
                try writeFileFromBlob(git_path, repo_root, path, &ours.?.sha1, allocator, platform_impl);
            } else {
                // Modified in ours, deleted in theirs - conflict
                has_conflicts = true;
                try addIndexEntry(&idx, path, ours.?.sha1, ours.?.mode, repo_root, allocator);
                try writeFileFromBlob(git_path, repo_root, path, &ours.?.sha1, allocator, platform_impl);
            }
        } else if (ours == null and theirs != null) {
            if (base != null and std.mem.eql(u8, &base.?.sha1, &theirs.?.sha1)) {
                // Deleted in ours, unchanged in theirs - delete
            } else if (base == null) {
                // Added in theirs only
                try addIndexEntry(&idx, path, theirs.?.sha1, theirs.?.mode, repo_root, allocator);
                try writeFileFromBlob(git_path, repo_root, path, &theirs.?.sha1, allocator, platform_impl);
            } else {
                // Deleted in ours, modified in theirs - conflict
                has_conflicts = true;
                if (base) |b| {
                    try addIndexEntryStaged(&idx, path, b.sha1, b.mode, repo_root, allocator, 1);
                }
                try addIndexEntryStaged(&idx, path, theirs.?.sha1, theirs.?.mode, repo_root, allocator, 3);
                try writeFileFromBlob(git_path, repo_root, path, &theirs.?.sha1, allocator, platform_impl);
            }
        }
    }

    // Save index
    idx.save(git_path, platform_impl) catch {};
    return has_conflicts;
}

const FileEntry = struct {
    sha1: [20]u8,
    mode: u32,
};

fn collectTreeEntriesFlat(git_path: []const u8, tree_hash: []const u8, prefix: []const u8, map: *std.StringHashMap(FileEntry), allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const tree_obj = try objects.GitObject.load(tree_hash, git_path, platform_impl, allocator);
    defer tree_obj.deinit(allocator);

    var pos: usize = 0;
    while (pos < tree_obj.data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, pos, ' ') orelse break;
        const mode_str = tree_obj.data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, space_pos, 0) orelse break;
        const name = tree_obj.data[space_pos + 1 .. null_pos];
        if (null_pos + 21 > tree_obj.data.len) break;
        const sha1_bytes = tree_obj.data[null_pos + 1 .. null_pos + 21];

        var hex_hash: [40]u8 = undefined;
        for (sha1_bytes, 0..) |b, bi| {
            const hex = "0123456789abcdef";
            hex_hash[bi * 2] = hex[b >> 4];
            hex_hash[bi * 2 + 1] = hex[b & 0xf];
        }

        const full_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);

        if (std.mem.eql(u8, mode_str, "40000")) {
            defer allocator.free(full_name);
            try collectTreeEntriesFlat(git_path, &hex_hash, full_name, map, allocator, platform_impl);
        } else {
            const mode: u32 = if (std.mem.eql(u8, mode_str, "100755")) 0o100755 else if (std.mem.eql(u8, mode_str, "120000")) 0o120000 else 0o100644;
            try map.put(full_name, FileEntry{ .sha1 = sha1_bytes[0..20].*, .mode = mode });
        }
        pos = null_pos + 21;
    }
}

fn addIndexEntry(idx: *index_mod.Index, path: []const u8, sha1: [20]u8, mode: u32, repo_root: []const u8, allocator: std.mem.Allocator) !void {
    try addIndexEntryStaged(idx, path, sha1, mode, repo_root, allocator, 0);
}

fn addIndexEntryStaged(idx: *index_mod.Index, path: []const u8, sha1: [20]u8, mode: u32, repo_root: []const u8, allocator: std.mem.Allocator, stage: u2) !void {
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path });
    defer allocator.free(full_path);
    const stat = std.fs.cwd().statFile(full_path) catch std.fs.File.Stat{
        .inode = 0,
        .size = 0,
        .mode = @truncate(mode),
        .mtime = 0,
        .ctime = 0,
        .atime = 0,
        .kind = .file,
    };
    var entry = index_mod.IndexEntry.init(try allocator.dupe(u8, path), stat, sha1);
    if (stage > 0) {
        // Set stage bits in flags (bits 12-13)
        const path_len: u16 = @intCast(@min(path.len, 0xFFF));
        entry.flags = (@as(u16, stage) << 12) | path_len;
    }
    try idx.entries.append(entry);
}

fn writeFileFromBlob(git_path: []const u8, repo_root: []const u8, path: []const u8, sha1: *const [20]u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    var hex_hash: [40]u8 = undefined;
    for (sha1, 0..) |b, bi| {
        const hex = "0123456789abcdef";
        hex_hash[bi * 2] = hex[b >> 4];
        hex_hash[bi * 2 + 1] = hex[b & 0xf];
    }
    const blob_obj = objects.GitObject.load(&hex_hash, git_path, platform_impl, allocator) catch return;
    defer blob_obj.deinit(allocator);

    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path });
    defer allocator.free(full_path);
    if (std.fs.path.dirname(full_path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }
    std.fs.cwd().writeFile(.{ .sub_path = full_path, .data = blob_obj.data }) catch {};
}

fn writeConflictFile(git_path: []const u8, repo_root: []const u8, path: []const u8, base: ?FileEntry, ours: FileEntry, theirs: FileEntry, theirs_commit: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    // Read file contents
    var ours_hex: [40]u8 = undefined;
    for (ours.sha1, 0..) |b, bi| {
        const hex = "0123456789abcdef";
        ours_hex[bi * 2] = hex[b >> 4];
        ours_hex[bi * 2 + 1] = hex[b & 0xf];
    }
    const ours_blob = objects.GitObject.load(&ours_hex, git_path, platform_impl, allocator) catch return;
    defer ours_blob.deinit(allocator);

    var theirs_hex: [40]u8 = undefined;
    for (theirs.sha1, 0..) |b, bi| {
        const hex = "0123456789abcdef";
        theirs_hex[bi * 2] = hex[b >> 4];
        theirs_hex[bi * 2 + 1] = hex[b & 0xf];
    }
    const theirs_blob = objects.GitObject.load(&theirs_hex, git_path, platform_impl, allocator) catch return;
    defer theirs_blob.deinit(allocator);

    _ = base;

    // Write simple conflict markers with commit info
    const theirs_label = blk: {
        if (theirs_commit.len >= 7) {
            const short = theirs_commit[0..7];
            const subj = getCommitSubject(theirs_commit, git_path, platform_impl, allocator) catch null;
            defer if (subj) |s| allocator.free(s);
            if (subj) |s| {
                break :blk std.fmt.allocPrint(allocator, "{s} ({s})", .{ short, s }) catch break :blk allocator.dupe(u8, short) catch break :blk @as(?[]u8, null);
            }
            break :blk allocator.dupe(u8, short) catch null;
        }
        break :blk @as(?[]u8, null);
    };
    defer if (theirs_label) |tl| allocator.free(tl);
    const theirs_short = theirs_label orelse theirs_hex[0..7];
    const conflict_content = std.fmt.allocPrint(allocator, "<<<<<<< HEAD\n{s}=======\n{s}>>>>>>> {s}\n", .{ ours_blob.data, theirs_blob.data, theirs_short }) catch return;
    defer allocator.free(conflict_content);

    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path });
    defer allocator.free(full_path);
    if (std.fs.path.dirname(full_path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }
    std.fs.cwd().writeFile(.{ .sub_path = full_path, .data = conflict_content }) catch {};
}

fn writeReflogEntry(git_dir: []const u8, ref_name: []const u8, old_hash: []const u8, new_hash: []const u8, msg_str: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    // Determine reflog path
    const reflog_path = if (std.mem.eql(u8, ref_name, "HEAD"))
        try std.fmt.allocPrint(allocator, "{s}/logs/HEAD", .{git_dir})
    else if (std.mem.startsWith(u8, ref_name, "refs/"))
        try std.fmt.allocPrint(allocator, "{s}/logs/{s}", .{ git_dir, ref_name })
    else
        try std.fmt.allocPrint(allocator, "{s}/logs/refs/heads/{s}", .{ git_dir, ref_name });
    defer allocator.free(reflog_path);

    if (std.fs.path.dirname(reflog_path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }

    // Get committer info for reflog
    const name = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_NAME") catch allocator.dupe(u8, "C O Mitter") catch return;
    defer allocator.free(name);
    const email = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_EMAIL") catch allocator.dupe(u8, "committer@example.com") catch return;
    defer allocator.free(email);
    const timestamp = std.time.timestamp();

    const old = if (old_hash.len == 40) old_hash else "0000000000000000000000000000000000000000";
    const new = if (new_hash.len == 40) new_hash else "0000000000000000000000000000000000000000";

    const entry = try std.fmt.allocPrint(allocator, "{s} {s} {s} <{s}> {d} +0000\t{s}\n", .{ old, new, name, email, timestamp, msg_str });
    defer allocator.free(entry);

    // Append to reflog
    const existing = platform_impl.fs.readFile(allocator, reflog_path) catch try allocator.dupe(u8, "");
    defer allocator.free(existing);
    const new_content = try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing, entry });
    defer allocator.free(new_content);
    platform_impl.fs.writeFile(reflog_path, new_content) catch {};
}

fn copyRebaseNotes(git_path: []const u8, old_commit: []const u8, new_commit: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
    defer allocator.free(config_path);
    const config_content = platform_impl.fs.readFile(allocator, config_path) catch return;
    defer allocator.free(config_content);

    var rewrite_rebase = false;
    if (findConfigValue(config_content, "notes", null, "rewrite.rebase")) |val| {
        const trimmed = std.mem.trim(u8, val, " \t\r\n");
        rewrite_rebase = std.mem.eql(u8, trimmed, "true");
    }
    if (!rewrite_rebase) {
        if (findConfigValue(config_content, "notes", "rewrite", "rebase")) |val| {
            const trimmed = std.mem.trim(u8, val, " \t\r\n");
            rewrite_rebase = std.mem.eql(u8, trimmed, "true");
        }
    }
    if (!rewrite_rebase) return;

    // Get rewrite ref (default: refs/notes/commits)
    var rewrite_ref: []const u8 = "refs/notes/commits";
    if (findConfigValue(config_content, "notes", null, "rewriteref")) |val| {
        const trimmed = std.mem.trim(u8, val, " \t\r\n");
        if (trimmed.len > 0) rewrite_ref = trimmed;
    }
    if (findConfigValue(config_content, "notes", null, "rewriteRef")) |val| {
        const trimmed = std.mem.trim(u8, val, " \t\r\n");
        if (trimmed.len > 0) rewrite_ref = trimmed;
    }

    const actual_ref = if (std.mem.indexOf(u8, rewrite_ref, "*") != null) "refs/notes/commits" else rewrite_ref;

    // Read notes commit
    const notes_commit_hash = refs.getRef(git_path, actual_ref, platform_impl, allocator) catch return;
    defer allocator.free(notes_commit_hash);

    const notes_tree_hash = getCommitTree(git_path, notes_commit_hash, allocator, platform_impl) catch return;
    defer allocator.free(notes_tree_hash);

    // Look up old_commit in notes tree
    const note_blob = lookupTreeEntry(git_path, notes_tree_hash, old_commit, allocator, platform_impl) catch return;
    defer allocator.free(note_blob);

    // Read existing tree
    const tree_obj = objects.GitObject.load(notes_tree_hash, git_path, platform_impl, allocator) catch return;
    defer tree_obj.deinit(allocator);

    // Build new tree with added entry
    var new_tree_data = std.array_list.Managed(u8).init(allocator);
    defer new_tree_data.deinit();

    var pos: usize = 0;
    while (pos < tree_obj.data.len) {
        const space_pos = std.mem.indexOf(u8, tree_obj.data[pos..], " ") orelse break;
        const null_pos = std.mem.indexOf(u8, tree_obj.data[pos + space_pos..], &[_]u8{0}) orelse break;
        const entry_end = pos + space_pos + null_pos + 1 + 20;
        if (entry_end > tree_obj.data.len) break;
        const entry_name = tree_obj.data[pos + space_pos + 1 .. pos + space_pos + null_pos];
        if (!std.mem.eql(u8, entry_name, new_commit)) {
            new_tree_data.appendSlice(tree_obj.data[pos..entry_end]) catch break;
        }
        pos = entry_end;
    }

    new_tree_data.appendSlice("100644 ") catch return;
    new_tree_data.appendSlice(new_commit) catch return;
    new_tree_data.append(0) catch return;
    var bin_hash: [20]u8 = undefined;
    for (0..20) |bi| {
        bin_hash[bi] = std.fmt.parseInt(u8, note_blob[bi * 2 .. bi * 2 + 2], 16) catch 0;
    }
    new_tree_data.appendSlice(&bin_hash) catch return;

    const new_tree_obj = objects.GitObject{ .type = .tree, .data = new_tree_data.items };
    const new_tree_hash = new_tree_obj.store(git_path, platform_impl, allocator) catch return;
    defer allocator.free(new_tree_hash);

    const committer_name = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_NAME") catch allocator.dupe(u8, "C O Mitter") catch return;
    defer allocator.free(committer_name);
    const committer_email = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_EMAIL") catch allocator.dupe(u8, "committer@example.com") catch return;
    defer allocator.free(committer_email);
    const timestamp = std.time.timestamp();
    const committer_str = std.fmt.allocPrint(allocator, "{s} <{s}> {d} +0000", .{ committer_name, committer_email, timestamp }) catch return;
    defer allocator.free(committer_str);
    var parents: [1][]const u8 = .{notes_commit_hash};
    const notes_commit_obj = objects.createCommitObject(new_tree_hash, &parents, committer_str, committer_str, "Notes added by 'git notes copy'", allocator) catch return;
    defer notes_commit_obj.deinit(allocator);
    const new_notes_hash = notes_commit_obj.store(git_path, platform_impl, allocator) catch return;
    defer allocator.free(new_notes_hash);
    refs.updateRef(git_path, actual_ref, new_notes_hash, platform_impl, allocator) catch {};
}

fn lookupTreeEntry(git_path: []const u8, tree_hash: []const u8, name: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) ![]u8 {
    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch return error.NotFound;
    defer tree_obj.deinit(allocator);

    var pos: usize = 0;
    while (pos < tree_obj.data.len) {
        const space_pos = std.mem.indexOf(u8, tree_obj.data[pos..], " ") orelse break;
        const null_pos = std.mem.indexOf(u8, tree_obj.data[pos + space_pos..], &[_]u8{0}) orelse break;
        const entry_end = pos + space_pos + null_pos + 1 + 20;
        if (entry_end > tree_obj.data.len) break;
        const entry_name = tree_obj.data[pos + space_pos + 1 .. pos + space_pos + null_pos];
        const sha1_bytes = tree_obj.data[pos + space_pos + null_pos + 1 .. entry_end];
        const mode = tree_obj.data[pos .. pos + space_pos];

        if (std.mem.eql(u8, entry_name, name)) {
            var hex_buf: [40]u8 = undefined;
            for (sha1_bytes, 0..) |b, bi| {
                const h = "0123456789abcdef";
                hex_buf[bi * 2] = h[b >> 4];
                hex_buf[bi * 2 + 1] = h[b & 0xf];
            }
            return try allocator.dupe(u8, &hex_buf);
        }

        // Check fanout directory (2-char prefix)
        if (name.len >= 2 and std.mem.eql(u8, entry_name, name[0..2]) and std.mem.eql(u8, mode, "40000")) {
            var sub_hash: [40]u8 = undefined;
            for (sha1_bytes, 0..) |b, bi| {
                const h = "0123456789abcdef";
                sub_hash[bi * 2] = h[b >> 4];
                sub_hash[bi * 2 + 1] = h[b & 0xf];
            }
            return lookupTreeEntry(git_path, &sub_hash, name[2..], allocator, platform_impl);
        }

        pos = entry_end;
    }
    return error.NotFound;
}

fn getConfiguredUpstream(git_path: []const u8, branch_name: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) ![]u8 {
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
    defer allocator.free(config_path);
    const config_content = platform_impl.fs.readFile(allocator, config_path) catch return error.NoUpstream;
    defer allocator.free(config_content);

    const merge_ref = findConfigValue(config_content, "branch", branch_name, "merge") orelse return error.NoUpstream;
    const remote = findConfigValue(config_content, "branch", branch_name, "remote") orelse ".";

    if (std.mem.eql(u8, remote, ".")) {
        // Local branch
        if (std.mem.startsWith(u8, merge_ref, "refs/heads/")) {
            const local_branch = merge_ref["refs/heads/".len..];
            return refs.getRef(git_path, try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{local_branch}), platform_impl, allocator) catch return error.NoUpstream;
        }
        return git_helpers_mod.resolveRevision(git_path, merge_ref, platform_impl, allocator) catch return error.NoUpstream;
    }

    // Remote tracking branch
    if (std.mem.startsWith(u8, merge_ref, "refs/heads/")) {
        const remote_branch = merge_ref["refs/heads/".len..];
        const remote_ref = try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ remote, remote_branch });
        defer allocator.free(remote_ref);
        return refs.getRef(git_path, remote_ref, platform_impl, allocator) catch return error.NoUpstream;
    }
    return error.NoUpstream;
}

fn resolvePreviousBranch(git_path: []const u8, n: u32, allocator: std.mem.Allocator, platform_impl: *const Platform) ![]u8 {
    const head_reflog_path = try std.fmt.allocPrint(allocator, "{s}/logs/HEAD", .{git_path});
    defer allocator.free(head_reflog_path);
    const reflog_content = platform_impl.fs.readFile(allocator, head_reflog_path) catch return error.NotFound;
    defer allocator.free(reflog_content);

    var checkout_entries = std.array_list.Managed([]const u8).init(allocator);
    defer checkout_entries.deinit();

    var lines = std.mem.splitScalar(u8, reflog_content, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "checkout: moving from ")) |idx_pos| {
            const rest = line[idx_pos + "checkout: moving from ".len..];
            if (std.mem.indexOf(u8, rest, " to ")) |to_idx| {
                checkout_entries.append(rest[0..to_idx]) catch {};
            }
        }
    }

    if (checkout_entries.items.len > 0) {
        var count: u32 = 0;
        var i_entry: usize = checkout_entries.items.len;
        while (i_entry > 0) : (count += 1) {
            i_entry -= 1;
            if (count + 1 == n) {
                return try allocator.dupe(u8, checkout_entries.items[i_entry]);
            }
        }
    }
    return error.NotFound;
}

fn findConfigValue(config_data: []const u8, section: []const u8, subsection: ?[]const u8, key: []const u8) ?[]const u8 {
    var in_section = false;
    var lines = std.mem.splitScalar(u8, config_data, '\n');
    var last_val: ?[]const u8 = null;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;
        if (trimmed[0] == '[') {
            in_section = false;
            if (std.mem.indexOfScalar(u8, trimmed, ']')) |close| {
                const header = trimmed[1..close];
                if (subsection) |sub| {
                    if (std.mem.indexOfScalar(u8, header, '"')) |q1| {
                        const sec = std.mem.trim(u8, header[0..q1], " \t");
                        if (std.mem.lastIndexOfScalar(u8, header, '"')) |q2| {
                            if (q2 > q1) {
                                const sub_val = header[q1 + 1 .. q2];
                                if (std.ascii.eqlIgnoreCase(sec, section) and std.mem.eql(u8, sub_val, sub)) {
                                    in_section = true;
                                }
                            }
                        }
                    }
                } else {
                    const sec = std.mem.trim(u8, header, " \t");
                    if (std.mem.indexOfScalar(u8, sec, '"') == null and std.ascii.eqlIgnoreCase(sec, section)) {
                        in_section = true;
                    }
                }
            }
        } else if (in_section) {
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                const k = std.mem.trim(u8, trimmed[0..eq], " \t");
                const v = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(k, key)) {
                    last_val = v;
                }
            }
        }
    }
    return last_val;
}