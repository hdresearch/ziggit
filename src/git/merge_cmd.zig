const std = @import("std");
const pm = @import("../platform/platform.zig");
const refs = @import("refs.zig");
const objects = @import("objects.zig");
const index_mod = @import("index.zig");
const config_mod = @import("config.zig");
const diff_stats = @import("diff_stats.zig");
const mc = @import("../main_common.zig");

const Allocator = std.mem.Allocator;

/// Valid built-in merge strategies
const VALID_STRATEGIES = [_][]const u8{
    "recursive",
    "resolve",
    "octopus",
    "ours",
    "subtree",
    "ort",
};

fn isValidStrategy(name: []const u8) bool {
    for (VALID_STRATEGIES) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

const MergeOpts = struct {
    message: ?[]const u8 = null,
    allow_unrelated_histories: bool = false,
    no_ff: bool = false,
    ff_only: bool = false,
    explicit_ff: bool = false,
    squash: bool = false,
    no_commit: bool = false,
    explicit_commit: bool = false,
    strategy: ?[]const u8 = null,
    octopus_strategies: ?[]const u8 = null, // space-separated list from pull.octopus
    signoff: bool = false,
    stat: ?bool = null, // null = default (true)
    log: ?bool = null,
    log_count: ?u32 = null,
    quiet: bool = false,
    verbose: bool = false,
    edit: ?bool = null,
    abort: bool = false,
    @"continue": bool = false,
    quit: bool = false,
    no_rerere_autoupdate: bool = false,
    no_verify: bool = false,
    verify_signatures: bool = false,
    strategy_options: std.array_list.Managed([]const u8),
    targets: std.array_list.Managed([]const u8),
    progress: ?bool = null,
    into_name: ?[]const u8 = null,
    overwrite_ignore: bool = true,
    autostash: ?bool = null,
    cleanup: ?[]const u8 = null,

    fn init(allocator: Allocator) MergeOpts {
        return .{
            .strategy_options = std.array_list.Managed([]const u8).init(allocator),
            .targets = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    fn deinit(self: *MergeOpts) void {
        self.strategy_options.deinit();
        self.targets.deinit();
    }
};

fn writeStdout(pi: *const pm.Platform, msg: []const u8) void {
    pi.writeStdout(msg) catch {};
}

fn writeStderr(pi: *const pm.Platform, msg: []const u8) void {
    pi.writeStderr(msg) catch {};
}

pub fn cmdMerge(allocator: Allocator, args: *pm.ArgIterator, platform_impl: *const pm.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        writeStderr(platform_impl, "merge: not supported in freestanding mode\n");
        return;
    }

    const git_path = mc.findGitDirectory(allocator, platform_impl) catch {
        writeStderr(platform_impl, "fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    var opts = MergeOpts.init(allocator);
    defer opts.deinit();

    // Parse arguments
    var saw_double_dash = false;
    while (args.next()) |arg| {
        if (saw_double_dash) {
            opts.targets.append(arg) catch {};
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            saw_double_dash = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-s")) {
            opts.strategy = args.next() orelse {
                writeStderr(platform_impl, "error: switch `s' requires a value\n");
                std.process.exit(128);
            };
        } else if (std.mem.startsWith(u8, arg, "--strategy=")) {
            opts.strategy = arg["--strategy=".len..];
        } else if (std.mem.eql(u8, arg, "-s=")) {
            // -s= with no value
            writeStderr(platform_impl, "error: switch `s' requires a value\n");
            std.process.exit(128);
        } else if (std.mem.startsWith(u8, arg, "-s=")) {
            opts.strategy = arg["-s=".len..];
        } else if (std.mem.eql(u8, arg, "-X")) {
            const val = args.next() orelse {
                writeStderr(platform_impl, "error: switch `X' requires a value\n");
                std.process.exit(128);
            };
            opts.strategy_options.append(val) catch {};
        } else if (std.mem.startsWith(u8, arg, "--strategy-option=")) {
            opts.strategy_options.append(arg["--strategy-option=".len..]) catch {};
        } else if (std.mem.startsWith(u8, arg, "-X")) {
            opts.strategy_options.append(arg[2..]) catch {};
        } else if (std.mem.eql(u8, arg, "-m")) {
            opts.message = args.next() orelse {
                writeStderr(platform_impl, "error: switch `m' requires a value\n");
                std.process.exit(128);
            };
        } else if (std.mem.startsWith(u8, arg, "-m") and arg.len > 2) {
            opts.message = arg[2..];
        } else if (std.mem.eql(u8, arg, "-F")) {
            const fname = args.next() orelse {
                writeStderr(platform_impl, "error: switch `F' requires a value\n");
                std.process.exit(128);
            };
            if (std.mem.eql(u8, fname, "-")) {
                // Read from stdin
                opts.message = readStdinAll(allocator) catch null;
            } else {
                opts.message = std.fs.cwd().readFileAlloc(allocator, fname, 10 * 1024 * 1024) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--allow-unrelated-histories")) {
            opts.allow_unrelated_histories = true;
        } else if (std.mem.eql(u8, arg, "--no-ff")) {
            opts.no_ff = true;
            opts.ff_only = false;
            opts.explicit_ff = true;
        } else if (std.mem.eql(u8, arg, "--ff")) {
            opts.no_ff = false;
            opts.ff_only = false;
            opts.explicit_ff = true;
        } else if (std.mem.eql(u8, arg, "--ff-only")) {
            opts.ff_only = true;
            opts.no_ff = false;
            opts.explicit_ff = true;
        } else if (std.mem.eql(u8, arg, "--squash")) {
            opts.squash = true;
        } else if (std.mem.eql(u8, arg, "--no-squash")) {
            opts.squash = false;
        } else if (std.mem.eql(u8, arg, "--no-commit")) {
            opts.no_commit = true;
        } else if (std.mem.eql(u8, arg, "--commit")) {
            opts.no_commit = false;
            opts.explicit_commit = true;
        } else if (std.mem.eql(u8, arg, "--signoff")) {
            opts.signoff = true;
        } else if (std.mem.eql(u8, arg, "--no-signoff")) {
            opts.signoff = false;
        } else if (std.mem.eql(u8, arg, "--edit") or std.mem.eql(u8, arg, "-e")) {
            opts.edit = true;
        } else if (std.mem.eql(u8, arg, "--no-edit")) {
            opts.edit = false;
        } else if (std.mem.eql(u8, arg, "--stat")) {
            opts.stat = true;
        } else if (std.mem.eql(u8, arg, "--no-stat") or std.mem.eql(u8, arg, "-n")) {
            opts.stat = false;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            opts.stat = true;
        } else if (std.mem.eql(u8, arg, "--no-summary")) {
            opts.stat = false;
        } else if (std.mem.eql(u8, arg, "--log")) {
            opts.log = true;
        } else if (std.mem.eql(u8, arg, "--no-log")) {
            opts.log = false;
        } else if (std.mem.startsWith(u8, arg, "--log=")) {
            opts.log = true;
            opts.log_count = std.fmt.parseInt(u32, arg["--log=".len..], 10) catch null;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
            opts.verbose = false;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
            opts.quiet = false;
        } else if (std.mem.eql(u8, arg, "--progress")) {
            opts.progress = true;
        } else if (std.mem.eql(u8, arg, "--no-progress")) {
            opts.progress = false;
        } else if (std.mem.eql(u8, arg, "--abort")) {
            opts.abort = true;
        } else if (std.mem.eql(u8, arg, "--continue")) {
            opts.@"continue" = true;
        } else if (std.mem.eql(u8, arg, "--quit")) {
            opts.quit = true;
        } else if (std.mem.eql(u8, arg, "--no-rerere-autoupdate")) {
            opts.no_rerere_autoupdate = true;
        } else if (std.mem.eql(u8, arg, "--rerere-autoupdate")) {
            opts.no_rerere_autoupdate = false;
        } else if (std.mem.eql(u8, arg, "--no-verify")) {
            opts.no_verify = true;
        } else if (std.mem.eql(u8, arg, "--verify-signatures")) {
            opts.verify_signatures = true;
        } else if (std.mem.eql(u8, arg, "--no-verify-signatures")) {
            opts.verify_signatures = false;
        } else if (std.mem.eql(u8, arg, "--no-overwrite-ignore")) {
            opts.overwrite_ignore = false;
        } else if (std.mem.eql(u8, arg, "--overwrite-ignore")) {
            opts.overwrite_ignore = true;
        } else if (std.mem.eql(u8, arg, "--autostash")) {
            opts.autostash = true;
        } else if (std.mem.eql(u8, arg, "--no-autostash")) {
            opts.autostash = false;
        } else if (std.mem.startsWith(u8, arg, "--cleanup=")) {
            opts.cleanup = arg["--cleanup=".len..];
        } else if (std.mem.eql(u8, arg, "--cleanup")) {
            opts.cleanup = args.next();
        } else if (std.mem.startsWith(u8, arg, "--into-name=")) {
            opts.into_name = arg["--into-name=".len..];
        } else if (std.mem.eql(u8, arg, "--into-name")) {
            opts.into_name = args.next();
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // Unknown long option
            const opt_name = arg[2..];
            const msg = std.fmt.allocPrint(allocator, "error: unknown option `{s}'\nusage: git merge [<options>] [<commit>...]\n", .{opt_name}) catch "";
            if (msg.len > 0) {
                defer allocator.free(msg);
                writeStderr(platform_impl, msg);
            }
            std.process.exit(128);
        } else if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and !std.mem.eql(u8, arg, "--")) {
            // Unknown short option - report first unknown char
            const ch = arg[1];
            const msg = std.fmt.allocPrint(allocator, "error: unknown switch `{c}'\nusage: git merge [<options>] [<commit>...]\n", .{ch}) catch "";
            if (msg.len > 0) {
                defer allocator.free(msg);
                writeStderr(platform_impl, msg);
            }
            std.process.exit(128);
        } else {
            opts.targets.append(arg) catch {};
        }
    }

    // Check for index.lock
    {
        const lock_path = std.fmt.allocPrint(allocator, "{s}/index.lock", .{git_path}) catch "";
        defer if (lock_path.len > 0) allocator.free(lock_path);
        if (lock_path.len > 0) {
            if (std.fs.cwd().access(lock_path, .{})) |_| {
                writeStderr(platform_impl, "fatal: Unable to create '");
                writeStderr(platform_impl, lock_path);
                writeStderr(platform_impl, "': File exists.\n\nAnother git process seems to be running in this repository, e.g.\nan editor opened by 'git commit'. Please make sure all processes\nare terminated then try again. If it still fails, a git process\nmay have crashed in this repository earlier:\nremove the file manually to continue.\n");
                std.process.exit(128);
            } else |_| {}
        }
    }

    // Read config for defaults
    applyConfigDefaults(git_path, &opts, allocator, platform_impl);

    // Validate: --abort, --continue, --quit take no extra arguments
    if (opts.abort) {
        if (opts.targets.items.len > 0) {
            writeStderr(platform_impl, "fatal: --abort expects no arguments\n");
            std.process.exit(128);
        }
        return doAbort(git_path, allocator, platform_impl);
    }
    if (opts.@"continue") {
        if (opts.targets.items.len > 0) {
            writeStderr(platform_impl, "fatal: --continue expects no arguments\n");
            std.process.exit(128);
        }
        return doContinue(git_path, &opts, allocator, platform_impl);
    }
    if (opts.quit) {
        if (opts.targets.items.len > 0) {
            writeStderr(platform_impl, "fatal: --quit expects no arguments\n");
            std.process.exit(128);
        }
        return doQuit(git_path, allocator, platform_impl);
    }

    // Validate: --squash + --no-ff is invalid
    if (opts.squash and opts.no_ff) {
        writeStderr(platform_impl, "fatal: options '--squash' and '--no-ff' cannot be used together.\n");
        std.process.exit(128);
    }

    // Validate: --squash + --commit is invalid  
    if (opts.squash and opts.explicit_commit) {
        writeStderr(platform_impl, "fatal: options '--squash' and '--commit' cannot be used together.\n");
        std.process.exit(128);
    }

    // Validate strategy
    if (opts.strategy) |s| {
        if (!isValidStrategy(s)) {
            const msg = std.fmt.allocPrint(allocator, "Could not find merge strategy '{s}'.\n", .{s}) catch "";
            if (msg.len > 0) {
                defer allocator.free(msg);
                writeStderr(platform_impl, msg);
            }
            writeStderr(platform_impl, "Available strategies are:");
            for (VALID_STRATEGIES) |vs| {
                const m2 = std.fmt.allocPrint(allocator, " {s}", .{vs}) catch "";
                if (m2.len > 0) {
                    defer allocator.free(m2);
                    writeStderr(platform_impl, m2);
                }
            }
            writeStderr(platform_impl, ".\n");
            std.process.exit(2);
        }
    }

    // No merge targets
    if (opts.targets.items.len == 0) {
        // Check if MERGE_HEAD exists for implicit continue
        const merge_head_path = std.fmt.allocPrint(allocator, "{s}/MERGE_HEAD", .{git_path}) catch "";
        defer if (merge_head_path.len > 0) allocator.free(merge_head_path);
        if (merge_head_path.len > 0) {
            if (std.fs.cwd().access(merge_head_path, .{})) |_| {
                // There's a merge in progress, suggest --continue
                writeStderr(platform_impl, "fatal: You have not concluded your merge (MERGE_HEAD exists).\nPlease, commit your changes before you merge.\n");
                std.process.exit(128);
            } else |_| {}
        }

        // Check if configured upstream
        const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch {
            writeStderr(platform_impl, "fatal: No current branch.\n");
            std.process.exit(128);
        };
        defer allocator.free(current_branch);
        const short_branch = if (std.mem.startsWith(u8, current_branch, "refs/heads/")) current_branch["refs/heads/".len..] else current_branch;

        // Try to get upstream
        var cfg = config_mod.loadGitConfig(git_path, allocator) catch null;
        defer if (cfg) |*c| c.deinit();
        if (cfg) |c| {
            if (c.getBranchMerge(short_branch)) |_| {
                // Has upstream configured but no merge target specified
                // Try reading FETCH_HEAD
                const fetch_head_path = std.fmt.allocPrint(allocator, "{s}/FETCH_HEAD", .{git_path}) catch "";
                defer if (fetch_head_path.len > 0) allocator.free(fetch_head_path);
                if (fetch_head_path.len > 0) {
                    if (std.fs.cwd().access(fetch_head_path, .{})) |_| {
                        // Has FETCH_HEAD - use it
                        return doMergeWithFetchHead(git_path, &opts, allocator, platform_impl);
                    } else |_| {}
                }
            }
        }

        writeStderr(platform_impl, "fatal: No remote for the current branch.\n");
        std.process.exit(128);
    }

    // Resolve all targets to hashes
    var target_hashes = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (target_hashes.items) |h| allocator.free(h);
        target_hashes.deinit();
    }

    for (opts.targets.items) |target| {
        // Special handling for FETCH_HEAD
        if (std.mem.eql(u8, target, "FETCH_HEAD")) {
            const fh_path = std.fmt.allocPrint(allocator, "{s}/FETCH_HEAD", .{git_path}) catch {
                writeStderr(platform_impl, "merge: FETCH_HEAD - not something we can merge\n");
                std.process.exit(1);
            };
            defer allocator.free(fh_path);
            const fh_content = std.fs.cwd().readFileAlloc(allocator, fh_path, 10 * 1024 * 1024) catch {
                writeStderr(platform_impl, "merge: FETCH_HEAD - not something we can merge\n");
                std.process.exit(1);
            };
            defer allocator.free(fh_content);

            var found_merge = false;
            var fh_lines = std.mem.splitScalar(u8, fh_content, '\n');
            while (fh_lines.next()) |fh_line| {
                if (fh_line.len < 40) continue;
                if (std.mem.indexOf(u8, fh_line, "not-for-merge") != null) continue;
                const fh_hash = allocator.dupe(u8, fh_line[0..40]) catch continue;
                target_hashes.append(fh_hash) catch {};
                found_merge = true;
            }
            if (!found_merge) {
                writeStderr(platform_impl, "fatal: No remote for the current branch.\n");
                std.process.exit(128);
            }
            continue;
        }

        const hash = resolveToCommitHash(git_path, target, allocator, platform_impl) catch {
            // Try suggesting remote refnames
            suggestRemoteRef(git_path, target, allocator, platform_impl);
            std.process.exit(1);
        };
        target_hashes.append(hash) catch {};
    }

    // Get current state
    const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch {
        writeStderr(platform_impl, "fatal: unable to determine current branch\n");
        std.process.exit(128);
    };
    defer allocator.free(current_branch);

    const current_commit_opt = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
    defer if (current_commit_opt) |h| allocator.free(h);

    // Handle merge from unborn branch (no commits yet)
    if (current_commit_opt == null) {
        if (target_hashes.items.len != 1) {
            writeStderr(platform_impl, "fatal: Can merge only exactly one commit into empty head\n");
            std.process.exit(128);
        }
        return doUnbornMerge(git_path, current_branch, target_hashes.items[0], &opts, allocator, platform_impl);
    }

    const current_hash = current_commit_opt.?;

    // Check if already up to date - filter out targets that are ancestors of HEAD
    {
        var non_merged = std.array_list.Managed([]const u8).init(allocator);
        defer non_merged.deinit();
        var non_merged_names = std.array_list.Managed([]const u8).init(allocator);
        defer non_merged_names.deinit();

        for (target_hashes.items, 0..) |target_hash, ti| {
            if (std.mem.eql(u8, current_hash, target_hash)) continue;
            if (isAncestor(git_path, target_hash, current_hash, allocator, platform_impl) catch false) continue;
            non_merged.append(target_hash) catch {};
            if (ti < opts.targets.items.len)
                non_merged_names.append(opts.targets.items[ti]) catch {};
        }

        if (non_merged.items.len == 0) {
            writeStdout(platform_impl, "Already up to date.\n");
            return;
        }

        // Replace target lists with non-merged ones
        if (non_merged.items.len > 1) {
            if (opts.ff_only) {
                writeStderr(platform_impl, "fatal: Not possible to fast-forward, aborting.\n");
                std.process.exit(128);
            }
            // Check if strategy supports octopus (multiple heads)
            if (opts.strategy) |strat| {
                if (!std.mem.eql(u8, strat, "octopus")) {
                    // If we have a list of strategies from pull.octopus, try each in order
                    if (opts.octopus_strategies) |strats| {
                        var found_octopus = false;
                        var strat_iter = std.mem.tokenizeAny(u8, strats, " \t");
                        while (strat_iter.next()) |s| {
                            if (std.mem.eql(u8, s, "octopus")) {
                                found_octopus = true;
                                break;
                            }
                        }
                        if (found_octopus) {
                            // Use octopus strategy from the list
                            return doOctopusMerge(git_path, current_hash, current_branch, &opts, non_merged.items, allocator, platform_impl);
                        }
                    }
                    // Non-octopus strategies can't handle multiple targets
                    const emsg = std.fmt.allocPrint(allocator, "Merge strategy '{s}' does not support merging multiple heads.\n", .{strat}) catch "Merge strategy does not support merging multiple heads.\n";
                    defer if (!std.mem.eql(u8, emsg, "Merge strategy does not support merging multiple heads.\n")) allocator.free(emsg);
                    writeStderr(platform_impl, emsg);
                    std.process.exit(2);
                }
            }
            return doOctopusMerge(git_path, current_hash, current_branch, &opts, non_merged.items, allocator, platform_impl);
        }

        // Single non-merged target
        const target_hash_single = non_merged.items[0];
        const merge_target_name_single = if (non_merged_names.items.len > 0) non_merged_names.items[0] else opts.targets.items[0];

        // Handle -s ours strategy
        if (opts.strategy) |strat| {
            if (std.mem.eql(u8, strat, "ours")) {
                return doOursStrategy(git_path, current_hash, target_hash_single, current_branch, merge_target_name_single, &opts, allocator, platform_impl);
            }
        }

        // Check if fast-forward is possible
        const can_ff = isAncestor(git_path, current_hash, target_hash_single, allocator, platform_impl) catch false;

        if (can_ff and !opts.no_ff) {
            if (opts.squash) {
                return doSquashFastForward(git_path, current_hash, target_hash_single, current_branch, merge_target_name_single, &opts, allocator, platform_impl);
            }
            return doFastForward(git_path, current_hash, target_hash_single, current_branch, merge_target_name_single, &opts, allocator, platform_impl);
        }

        if (opts.ff_only) {
            writeStderr(platform_impl, "fatal: Not possible to fast-forward, aborting.\n");
            std.process.exit(128);
        }

        if (opts.squash) {
            return doSquashMerge(git_path, current_hash, target_hash_single, current_branch, merge_target_name_single, &opts, allocator, platform_impl);
        }

        return doThreeWayMerge(git_path, current_hash, target_hash_single, current_branch, merge_target_name_single, &opts, allocator, platform_impl);
    }

}

fn applyConfigDefaults(git_path: []const u8, opts: *MergeOpts, allocator: Allocator, platform_impl: *const pm.Platform) void {
    var cfg = config_mod.loadGitConfig(git_path, allocator) catch null;
    defer if (cfg) |*c| c.deinit();

    // merge.ff config (only if not explicitly set on command line)
    if (!opts.explicit_ff) {
        if (mc.getConfigOverride("merge.ff")) |val| {
            applyFfConfig(val, opts);
        } else if (cfg) |c| {
            if (c.get("merge", null, "ff")) |val| {
                applyFfConfig(val, opts);
            }
        }
    }

    // merge.stat / merge.diffstat config
    if (opts.stat == null) {
        if (mc.getConfigOverride("merge.stat")) |val| {
            opts.stat = isTruthy(val);
        } else if (mc.getConfigOverride("merge.diffstat")) |val| {
            opts.stat = isTruthy(val);
        } else if (cfg) |c| {
            if (c.get("merge", null, "stat")) |val| {
                opts.stat = isTruthy(val);
            } else if (c.get("merge", null, "diffstat")) |val| {
                opts.stat = isTruthy(val);
            }
        }
    }

    // merge.log config
    if (opts.log == null) {
        if (mc.getConfigOverride("merge.log")) |val| {
            opts.log = isTruthy(val);
            if (opts.log.?) {
                opts.log_count = std.fmt.parseInt(u32, val, 10) catch null;
            }
        } else if (cfg) |c| {
            if (c.get("merge", null, "log")) |val| {
                opts.log = isTruthy(val);
                if (opts.log.?) {
                    opts.log_count = std.fmt.parseInt(u32, val, 10) catch null;
                }
            }
        }
    }

    // commit.cleanup config
    if (opts.cleanup == null) {
        if (mc.getConfigOverride("commit.cleanup")) |val| {
            opts.cleanup = val;
        } else if (cfg) |c| {
            if (c.get("commit", null, "cleanup")) |val| {
                opts.cleanup = val;
            }
        }
    }

    // merge.autoStash config
    if (opts.autostash == null) {
        if (mc.getConfigOverride("merge.autostash")) |val| {
            opts.autostash = isTruthy(val);
        } else if (mc.getConfigOverride("merge.autoStash")) |val| {
            opts.autostash = isTruthy(val);
        } else if (cfg) |c| {
            if (c.get("merge", null, "autostash")) |val| {
                opts.autostash = isTruthy(val);
            } else if (c.get("merge", null, "autoStash")) |val| {
                opts.autostash = isTruthy(val);
            }
        }
    }

    // pull.octopus config for default octopus strategy
    if (opts.strategy == null and opts.targets.items.len > 1) {
        if (mc.getConfigOverride("pull.octopus")) |val| {
            opts.octopus_strategies = allocator.dupe(u8, val) catch null;
            // Also set strategy to first valid one
            var strat_iter = std.mem.tokenizeAny(u8, val, " \t");
            if (strat_iter.next()) |first_strat| {
                if (isValidStrategy(first_strat)) {
                    opts.strategy = allocator.dupe(u8, first_strat) catch null;
                }
            }
        } else if (cfg) |c| {
            if (c.get("pull", null, "octopus")) |val| {
                opts.octopus_strategies = allocator.dupe(u8, val) catch null;
                var strat_iter = std.mem.tokenizeAny(u8, val, " \t");
                if (strat_iter.next()) |first_strat| {
                    if (isValidStrategy(first_strat)) {
                        opts.strategy = allocator.dupe(u8, first_strat) catch null;
                    }
                }
            }
        }
    }

    // pull.twohead / config for default two-head strategy
    if (opts.strategy == null and opts.targets.items.len <= 1) {
        if (mc.getConfigOverride("pull.twohead")) |val| {
            // pull.twohead can be a space-separated list of strategies; use first one
            var strat_iter = std.mem.tokenizeAny(u8, val, " \t");
            if (strat_iter.next()) |first_strat| {
                if (isValidStrategy(first_strat)) {
                    opts.strategy = allocator.dupe(u8, first_strat) catch null;
                }
            }
        } else if (cfg) |c| {
            if (c.get("pull", null, "twohead")) |val| {
                var strat_iter = std.mem.tokenizeAny(u8, val, " \t");
                if (strat_iter.next()) |first_strat| {
                    if (isValidStrategy(first_strat)) {
                        opts.strategy = allocator.dupe(u8, first_strat) catch null;
                    }
                }
            }
        }
    }

    // branch.<name>.mergeoptions config
    const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch return;
    defer allocator.free(current_branch);
    const short_branch = if (std.mem.startsWith(u8, current_branch, "refs/heads/")) current_branch["refs/heads/".len..] else current_branch;

    const merge_opts_key = std.fmt.allocPrint(allocator, "branch.{s}.mergeoptions", .{short_branch}) catch return;
    defer allocator.free(merge_opts_key);

    var merge_options_val: ?[]const u8 = null;
    if (mc.getConfigOverride(merge_opts_key)) |val| {
        merge_options_val = val;
    } else if (cfg) |c| {
        if (c.get("branch", short_branch, "mergeoptions")) |val| {
            merge_options_val = val;
        }
    }

    if (merge_options_val) |mopts| {
        // Parse space-separated options - branch config is lower priority than command line
        var iter = std.mem.tokenizeAny(u8, mopts, " \t");
        while (iter.next()) |opt| {
            if (std.mem.eql(u8, opt, "--no-ff") and !opts.explicit_ff) {
                opts.no_ff = true;
                opts.ff_only = false;
            } else if (std.mem.eql(u8, opt, "--ff-only") and !opts.explicit_ff) {
                opts.ff_only = true;
                opts.no_ff = false;
            } else if (std.mem.eql(u8, opt, "--ff") and !opts.explicit_ff) {
                opts.no_ff = false;
                opts.ff_only = false;
            } else if (std.mem.eql(u8, opt, "--squash")) {
                opts.squash = true;
            } else if (std.mem.eql(u8, opt, "--no-commit")) {
                opts.no_commit = true;
            } else if (std.mem.eql(u8, opt, "--commit")) {
                opts.no_commit = false;
            } else if (std.mem.eql(u8, opt, "--stat")) {
                opts.stat = true;
            } else if (std.mem.eql(u8, opt, "--no-stat") or std.mem.eql(u8, opt, "-n")) {
                opts.stat = false;
            } else if (std.mem.eql(u8, opt, "--log")) {
                opts.log = true;
            } else if (std.mem.eql(u8, opt, "--no-log")) {
                opts.log = false;
            }
        }
    }
}

fn applyFfConfig(val: []const u8, opts: *MergeOpts) void {
    if (std.ascii.eqlIgnoreCase(val, "only")) {
        opts.ff_only = true;
        opts.no_ff = false;
    } else if (std.ascii.eqlIgnoreCase(val, "false") or std.mem.eql(u8, val, "0") or std.ascii.eqlIgnoreCase(val, "no")) {
        opts.no_ff = true;
        opts.ff_only = false;
    } else if (std.ascii.eqlIgnoreCase(val, "true") or std.mem.eql(u8, val, "1") or std.ascii.eqlIgnoreCase(val, "yes")) {
        opts.no_ff = false;
        opts.ff_only = false;
    }
}

fn isTruthy(val: []const u8) bool {
    return std.ascii.eqlIgnoreCase(val, "true") or
        std.ascii.eqlIgnoreCase(val, "yes") or
        std.ascii.eqlIgnoreCase(val, "on") or
        std.mem.eql(u8, val, "1");
}

fn invokeEditor(git_path: []const u8, message: []const u8, allocator: Allocator) ?[]u8 {
    // Write message to MERGE_MSG file
    const merge_msg_path = std.fmt.allocPrint(allocator, "{s}/MERGE_MSG", .{git_path}) catch return null;
    defer allocator.free(merge_msg_path);

    // Write the message (ensure trailing newline like real git)
    var f = std.fs.cwd().createFile(merge_msg_path, .{}) catch return null;
    f.writeAll(message) catch {
        f.close();
        return null;
    };
    if (message.len == 0 or message[message.len - 1] != '\n') {
        f.writeAll("\n") catch {};
    }
    f.close();

    // Get editor
    const editor = std.process.getEnvVarOwned(allocator, "GIT_EDITOR") catch
        std.process.getEnvVarOwned(allocator, "VISUAL") catch
        std.process.getEnvVarOwned(allocator, "EDITOR") catch
        (allocator.dupe(u8, "vi") catch return null);
    defer allocator.free(editor);

    // Run editor using shell
    const cmd = std.fmt.allocPrint(allocator, "{s} \"{s}\"", .{ editor, merge_msg_path }) catch return null;
    defer allocator.free(cmd);

    const cmd_z = allocator.dupeZ(u8, cmd) catch return null;
    defer allocator.free(cmd_z);

    const argv = [_][]const u8{ "/bin/sh", "-c", cmd_z };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch return null;
    const result = child.wait() catch return null;

    if (result.Exited == 0) {
        // Read edited file
        return std.fs.cwd().readFileAlloc(allocator, merge_msg_path, 10 * 1024 * 1024) catch null;
    }
    return null;
}

fn readStdinAll(allocator: Allocator) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    const f = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = f.read(&buf) catch break;
        if (n == 0) break;
        try result.appendSlice(buf[0..n]);
    }
    return result.toOwnedSlice();
}

fn resolveToCommitHash(git_path: []const u8, target: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) ![]u8 {
    // Try as revision
    if (mc.resolveRevision(git_path, target, platform_impl, allocator)) |hash| {
        // Peel tag to commit if needed
        return peelToCommit(git_path, hash, allocator, platform_impl);
    } else |_| {}

    // Try as branch
    if (refs.branchExists(git_path, target, platform_impl, allocator) catch false) {
        if (refs.getBranchCommit(git_path, target, platform_impl, allocator) catch null) |hash| {
            return hash;
        }
    }

    return error.NotFound;
}

fn suggestRemoteRef(git_path: []const u8, target: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    const msg = std.fmt.allocPrint(allocator, "merge: {s} - not something we can merge\n", .{target}) catch "";
    if (msg.len > 0) {
        defer allocator.free(msg);
        writeStderr(platform_impl, msg);
    }

    // Look for matching refs in remotes
    const remotes_dir = std.fmt.allocPrint(allocator, "{s}/refs/remotes", .{git_path}) catch return;
    defer allocator.free(remotes_dir);

    var found_any = false;

    if (std.fs.cwd().openDir(remotes_dir, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close();

        var it = dir.iterate();
        while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const remote_name = entry.name;
        // Check if remote_name/target exists
        const ref_path = std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}/{s}", .{ git_path, remote_name, target }) catch continue;
        defer allocator.free(ref_path);

        if (std.fs.cwd().access(ref_path, .{})) |_| {
            // Also check if there's a local branch with same name (ambiguity)
            const local_path = std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}/{s}", .{ git_path, remote_name, target }) catch continue;
            defer allocator.free(local_path);
            const is_ambiguous = if (std.fs.cwd().access(local_path, .{})) |_| true else |_| false;

            if (!found_any) {
                writeStderr(platform_impl, "\nDid you mean one of these?\n");
                found_any = true;
            }
            if (is_ambiguous) {
                const hint = std.fmt.allocPrint(allocator, "\tremotes/{s}/{s}\n", .{ remote_name, target }) catch continue;
                defer allocator.free(hint);
                writeStderr(platform_impl, hint);
            } else {
                const hint = std.fmt.allocPrint(allocator, "\t{s}/{s}\n", .{ remote_name, target }) catch continue;
                defer allocator.free(hint);
                writeStderr(platform_impl, hint);
            }
        } else |_| {}
    }
    } else |_| {} // openDir failed

    // Also check packed-refs for remote refs
    if (!found_any) {
        const packed_path = std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_path}) catch return;
        defer allocator.free(packed_path);
        const packed_content = std.fs.cwd().readFileAlloc(allocator, packed_path, 10 * 1024 * 1024) catch return;
        defer allocator.free(packed_content);

        const search = std.fmt.allocPrint(allocator, "refs/remotes/", .{}) catch return;
        defer allocator.free(search);
        const suffix = std.fmt.allocPrint(allocator, "/{s}", .{target}) catch return;
        defer allocator.free(suffix);

        var lines = std.mem.splitScalar(u8, packed_content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            // Format: hash SP ref
            if (line.len > 40) {
                const ref = std.mem.trimLeft(u8, line[41..], " ");
                if (std.mem.startsWith(u8, ref, "refs/remotes/") and std.mem.endsWith(u8, ref, suffix)) {
                    if (!found_any) {
                        writeStderr(platform_impl, "\nDid you mean one of these?\n");
                        found_any = true;
                    }
                    // Check ambiguity
                    const remote_ref = ref["refs/remotes/".len..];
                    const local_check = std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, remote_ref }) catch continue;
                    defer allocator.free(local_check);
                    const is_ambiguous = if (std.fs.cwd().access(local_check, .{})) |_| true else |_| false;

                    if (is_ambiguous) {
                        const hint = std.fmt.allocPrint(allocator, "\tremotes/{s}\n", .{remote_ref}) catch continue;
                        defer allocator.free(hint);
                        writeStderr(platform_impl, hint);
                    } else {
                        const hint = std.fmt.allocPrint(allocator, "\t{s}\n", .{remote_ref}) catch continue;
                        defer allocator.free(hint);
                        writeStderr(platform_impl, hint);
                    }
                }
            }
        }
    }
}

fn peelToCommit(git_path: []const u8, hash: []u8, allocator: Allocator, platform_impl: *const pm.Platform) ![]u8 {
    // Check if it's a tag object and peel it
    const obj = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch return hash;
    defer obj.deinit(allocator);

    if (obj.type == .tag) {
        // Find "object " line
        var lines_iter = std.mem.splitScalar(u8, obj.data, '\n');
        while (lines_iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "object ")) {
                const target_hash = try allocator.dupe(u8, line["object ".len..]);
                allocator.free(hash);
                return peelToCommit(git_path, target_hash, allocator, platform_impl);
            }
            if (line.len == 0) break;
        }
    }
    return hash;
}

/// Check if ancestor_hash is an ancestor of descendant_hash using BFS
fn isAncestor(git_path: []const u8, ancestor_hash: []const u8, descendant_hash: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) !bool {
    if (std.mem.eql(u8, ancestor_hash, descendant_hash)) return true;

    var queue = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (queue.items) |h| allocator.free(h);
        queue.deinit();
    }
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var it = visited.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        visited.deinit();
    }

    try queue.append(try allocator.dupe(u8, descendant_hash));
    try visited.put(try allocator.dupe(u8, descendant_hash), {});

    var depth: usize = 0;
    while (queue.items.len > 0 and depth < 10000) : (depth += 1) {
        const current = queue.orderedRemove(0);
        defer allocator.free(current);

        const obj = objects.GitObject.load(current, git_path, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);
        if (obj.type != .commit) continue;

        var lines_iter = std.mem.splitScalar(u8, obj.data, '\n');
        while (lines_iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                const parent = line["parent ".len..];
                if (std.mem.eql(u8, parent, ancestor_hash)) return true;
                if (!visited.contains(parent)) {
                    const dup = try allocator.dupe(u8, parent);
                    try visited.put(try allocator.dupe(u8, parent), {});
                    try queue.append(dup);
                }
            } else if (line.len == 0) break;
        }
    }
    return false;
}

/// Find merge base of two commits
fn findMergeBase(git_path: []const u8, hash1: []const u8, hash2: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) !?[]u8 {
    // Collect all ancestors of hash1
    var ancestors1 = std.StringHashMap(u32).init(allocator);
    defer {
        var it = ancestors1.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        ancestors1.deinit();
    }
    try collectAncestorsWithDepth(git_path, hash1, &ancestors1, 0, allocator, platform_impl);

    // BFS from hash2, find first common ancestor (closest)
    var queue = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (queue.items) |h| allocator.free(h);
        queue.deinit();
    }
    var visited2 = std.StringHashMap(void).init(allocator);
    defer {
        var it = visited2.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        visited2.deinit();
    }

    try queue.append(try allocator.dupe(u8, hash2));
    try visited2.put(try allocator.dupe(u8, hash2), {});

    var best: ?[]u8 = null;
    var best_depth: u32 = std.math.maxInt(u32);

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);
        defer allocator.free(current);

        if (ancestors1.get(current)) |d| {
            if (d < best_depth) {
                if (best) |b| allocator.free(b);
                best = try allocator.dupe(u8, current);
                best_depth = d;
            }
            continue; // Don't explore past merge base
        }

        const obj = objects.GitObject.load(current, git_path, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);
        if (obj.type != .commit) continue;

        var lines_iter = std.mem.splitScalar(u8, obj.data, '\n');
        while (lines_iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                const parent = line["parent ".len..];
                if (!visited2.contains(parent)) {
                    const dup = try allocator.dupe(u8, parent);
                    try visited2.put(try allocator.dupe(u8, parent), {});
                    try queue.append(dup);
                }
            } else if (line.len == 0) break;
        }
    }

    return best;
}

fn collectAncestorsWithDepth(git_path: []const u8, hash: []const u8, ancestors: *std.StringHashMap(u32), depth: u32, allocator: Allocator, platform_impl: *const pm.Platform) !void {
    if (depth > 10000) return;
    if (ancestors.contains(hash)) {
        // Update if we found shorter path
        if (ancestors.get(hash).? > depth) {
            // Can't really update easily, skip
        }
        return;
    }

    try ancestors.put(try allocator.dupe(u8, hash), depth);

    const obj = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch return;
    defer obj.deinit(allocator);
    if (obj.type != .commit) return;

    var lines_iter = std.mem.splitScalar(u8, obj.data, '\n');
    while (lines_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "parent ")) {
            const parent = line["parent ".len..];
            try collectAncestorsWithDepth(git_path, parent, ancestors, depth + 1, allocator, platform_impl);
        } else if (line.len == 0) break;
    }
}

fn getCommitTree(git_path: []const u8, commit_hash: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) ![]u8 {
    const obj = try objects.GitObject.load(commit_hash, git_path, platform_impl, allocator);
    defer obj.deinit(allocator);
    if (obj.type != .commit) return error.NotACommit;

    var lines_iter = std.mem.splitScalar(u8, obj.data, '\n');
    while (lines_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ")) {
            return try allocator.dupe(u8, line["tree ".len..]);
        }
    }
    return error.InvalidObject;
}

fn doAbort(git_path: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    const merge_head_path = std.fmt.allocPrint(allocator, "{s}/MERGE_HEAD", .{git_path}) catch return;
    defer allocator.free(merge_head_path);

    if (std.fs.cwd().access(merge_head_path, .{})) |_| {} else |_| {
        writeStderr(platform_impl, "fatal: There is no merge to abort (MERGE_HEAD missing).\n");
        std.process.exit(128);
    }

    // Reset to HEAD
    if (refs.getCurrentCommit(git_path, platform_impl, allocator) catch null) |head_hash| {
        defer allocator.free(head_hash);
        checkoutTree(git_path, head_hash, allocator, platform_impl);
        resetIndexToCommit(git_path, head_hash, allocator, platform_impl);
    }

    // Clean up merge state files
    cleanMergeState(git_path, allocator);
}

fn doContinue(git_path: []const u8, opts: *MergeOpts, allocator: Allocator, platform_impl: *const pm.Platform) void {
    const merge_head_path = std.fmt.allocPrint(allocator, "{s}/MERGE_HEAD", .{git_path}) catch return;
    defer allocator.free(merge_head_path);

    if (std.fs.cwd().access(merge_head_path, .{})) |_| {} else |_| {
        writeStderr(platform_impl, "fatal: There is no merge in progress (MERGE_HEAD missing).\n");
        std.process.exit(128);
    }

    // Read MERGE_HEAD
    const merge_head_content = std.fs.cwd().readFileAlloc(allocator, merge_head_path, 1024) catch {
        writeStderr(platform_impl, "fatal: Could not read MERGE_HEAD\n");
        std.process.exit(128);
    };
    defer allocator.free(merge_head_content);
    const target_hash = std.mem.trim(u8, merge_head_content, " \t\r\n");

    // Read MERGE_MSG
    const merge_msg_path = std.fmt.allocPrint(allocator, "{s}/MERGE_MSG", .{git_path}) catch return;
    defer allocator.free(merge_msg_path);
    const merge_msg = std.fs.cwd().readFileAlloc(allocator, merge_msg_path, 1024 * 1024) catch "";
    defer if (merge_msg.len > 0) allocator.free(merge_msg);

    const current_hash = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
    defer if (current_hash) |h| allocator.free(h);

    if (current_hash == null) {
        writeStderr(platform_impl, "fatal: unable to get current commit\n");
        std.process.exit(128);
    }

    const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch {
        writeStderr(platform_impl, "fatal: unable to determine current branch\n");
        std.process.exit(128);
    };
    defer allocator.free(current_branch);

    // Check for unresolved conflicts - check index for conflict entries
    // For now just check if index has conflict markers in working tree
    // This is simplified; a proper implementation checks index stages

    const msg = if (opts.message) |m| m else if (merge_msg.len > 0) merge_msg else "Merge commit";
    createMergeCommit(git_path, current_hash.?, target_hash, current_branch, msg, allocator, platform_impl);

    cleanMergeState(git_path, allocator);
    writeStdout(platform_impl, "Merge made by the 'ort' strategy.\n");
    // [already-up-to-date handled earlier, so not reached here for that case]
}

fn doQuit(git_path: []const u8, allocator: Allocator, _: *const pm.Platform) void {
    cleanMergeState(git_path, allocator);
}

fn cleanMergeState(git_path: []const u8, allocator: Allocator) void {
    const files = [_][]const u8{ "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE" };
    for (files) |name| {
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, name }) catch continue;
        defer allocator.free(path);
        std.fs.cwd().deleteFile(path) catch {};
    }
    // Also clean AUTO_MERGE
    const auto_merge = std.fmt.allocPrint(allocator, "{s}/AUTO_MERGE", .{git_path}) catch return;
    defer allocator.free(auto_merge);
    std.fs.cwd().deleteFile(auto_merge) catch {};
}

fn doUnbornMerge(git_path: []const u8, current_branch: []const u8, target_hash: []const u8, opts: *MergeOpts, allocator: Allocator, platform_impl: *const pm.Platform) void {
    _ = opts;
    // Fast-forward from empty to target
    refs.updateRef(git_path, current_branch, target_hash, platform_impl, allocator) catch {
        writeStderr(platform_impl, "fatal: unable to update ref\n");
        std.process.exit(128);
    };
    checkoutTree(git_path, target_hash, allocator, platform_impl);
    writeStdout(platform_impl, "Fast-forward\n");
}

fn doFastForward(git_path: []const u8, current_hash: []const u8, target_hash: []const u8, current_branch: []const u8, merge_target_name: []const u8, opts: *MergeOpts, allocator: Allocator, platform_impl: *const pm.Platform) void {
    // Show "Updating FROM..TO" line first
    const updating_msg = std.fmt.allocPrint(allocator, "Updating {s}..{s}\n", .{ current_hash[0..@min(7, current_hash.len)], target_hash[0..@min(7, target_hash.len)] }) catch "";
    defer if (updating_msg.len > 0) allocator.free(updating_msg);
    writeStdout(platform_impl, updating_msg);

    // Update ref
    refs.updateRef(git_path, current_branch, target_hash, platform_impl, allocator) catch {
        writeStderr(platform_impl, "fatal: unable to update ref\n");
        std.process.exit(128);
    };

    // Checkout the new tree
    checkoutTree(git_path, target_hash, allocator, platform_impl);

    writeStdout(platform_impl, "Fast-forward\n");

    // Show diffstat if enabled
    const show_stat = opts.stat orelse true;
    if (show_stat and !opts.quiet) {
        showDiffstat(git_path, current_hash, target_hash, allocator, platform_impl);
    }

    // Write reflog
    const reflog_msg = std.fmt.allocPrint(allocator, "merge {s}: Fast-forward", .{merge_target_name}) catch "merge: Fast-forward";
    defer if (!std.mem.eql(u8, reflog_msg, "merge: Fast-forward")) allocator.free(reflog_msg);
    writeReflogEntry(git_path, current_branch, current_hash, target_hash, reflog_msg, allocator, platform_impl);
}

fn doSquashFastForward(git_path: []const u8, current_hash: []const u8, target_hash: []const u8, current_branch: []const u8, merge_target: []const u8, opts: *MergeOpts, allocator: Allocator, platform_impl: *const pm.Platform) void {
    _ = current_branch;
    // Checkout target tree but don't create commit or update HEAD
    const updating_msg = std.fmt.allocPrint(allocator, "Updating {s}..{s}\n", .{ current_hash[0..@min(7, current_hash.len)], target_hash[0..@min(7, target_hash.len)] }) catch "";
    defer if (updating_msg.len > 0) allocator.free(updating_msg);
    writeStdout(platform_impl, updating_msg);
    writeStdout(platform_impl, "Fast-forward\n");

    checkoutTreeNoHead(git_path, target_hash, allocator, platform_impl);

    // Show diffstat
    const show_stat = opts.stat orelse true;
    if (show_stat and !opts.quiet) {
        showDiffstat(git_path, current_hash, target_hash, allocator, platform_impl);
    }

    // Write SQUASH_MSG
    const squash_msg = buildSquashMsg(git_path, current_hash, merge_target, allocator, platform_impl);
    defer if (squash_msg.len > 0) allocator.free(squash_msg);
    if (squash_msg.len > 0) {
        const squash_path = std.fmt.allocPrint(allocator, "{s}/SQUASH_MSG", .{git_path}) catch return;
        defer allocator.free(squash_path);
        platform_impl.fs.writeFile(squash_path, squash_msg) catch {};
    }

    writeStdout(platform_impl, "Squash commit -- not updating HEAD\n");
}

fn doSquashMerge(git_path: []const u8, current_hash: []const u8, target_hash: []const u8, current_branch: []const u8, merge_target: []const u8, opts: *MergeOpts, allocator: Allocator, platform_impl: *const pm.Platform) void {
    _ = current_branch;
    // Perform 3-way merge but don't commit
    const merge_base = findMergeBase(git_path, current_hash, target_hash, allocator, platform_impl) catch null;
    defer if (merge_base) |b| allocator.free(b);

    const base = merge_base orelse current_hash;
    var conflict_files = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (conflict_files.items) |f| allocator.free(f);
        conflict_files.deinit();
    }
    const conflicts = doTreeMergeTracked(git_path, base, current_hash, target_hash, &conflict_files, allocator, platform_impl);

    // Show diffstat
    const show_stat = opts.stat orelse true;
    if (show_stat and !opts.quiet) {
        showDiffstat(git_path, current_hash, target_hash, allocator, platform_impl);
    }

    // Write SQUASH_MSG
    var squash_msg_buf = buildSquashMsgBuf(git_path, current_hash, merge_target, allocator, platform_impl);
    defer squash_msg_buf.deinit();
    if (conflicts) {
        appendConflictInfo(&squash_msg_buf, conflict_files.items, opts.cleanup);
    }
    const squash_msg = squash_msg_buf.toOwnedSlice() catch "";
    defer if (squash_msg.len > 0) allocator.free(squash_msg);
    if (squash_msg.len > 0) {
        const squash_path = std.fmt.allocPrint(allocator, "{s}/SQUASH_MSG", .{git_path}) catch return;
        defer allocator.free(squash_path);
        platform_impl.fs.writeFile(squash_path, squash_msg) catch {};
    }

    if (conflicts) {
        // Write merge state for conflict resolution
        writeStderr(platform_impl, "Automatic merge failed; fix conflicts and then commit the result.\n");
        writeStdout(platform_impl, "Squash commit -- not updating HEAD\n");
        std.process.exit(1);
    } else {
        writeStdout(platform_impl, "Squash commit -- not updating HEAD\n");
    }
}

fn doOursStrategy(git_path: []const u8, current_hash: []const u8, target_hash: []const u8, current_branch: []const u8, merge_target: []const u8, opts: *MergeOpts, allocator: Allocator, platform_impl: *const pm.Platform) void {
    // Keep our tree exactly as-is, just create merge commit with two parents
    const merge_msg = opts.message orelse (buildMergeMessage(merge_target, current_branch, git_path, allocator, platform_impl) catch "Merge");
    const should_free = opts.message == null and !std.mem.eql(u8, merge_msg, "Merge");
    defer if (should_free) allocator.free(@constCast(merge_msg));

    // Use our tree hash directly (don't scan work tree which may have stale files)
    const tree_hash = getCommitTree(git_path, current_hash, allocator, platform_impl) catch {
        writeStderr(platform_impl, "fatal: unable to get tree from HEAD\n");
        std.process.exit(128);
    };
    defer allocator.free(tree_hash);

    const author_line = getAuthorString(allocator) catch blk: {
        const ts = std.time.timestamp();
        break :blk std.fmt.allocPrint(allocator, "User <user@example.com> {d} +0000", .{ts}) catch return;
    };
    defer allocator.free(author_line);
    const committer_line = getCommitterString(allocator) catch blk: {
        const ts = std.time.timestamp();
        break :blk std.fmt.allocPrint(allocator, "User <user@example.com> {d} +0000", .{ts}) catch return;
    };
    defer allocator.free(committer_line);

    const parents = [_][]const u8{ current_hash, target_hash };
    const commit_obj = objects.createCommitObject(tree_hash, &parents, author_line, committer_line, merge_msg, allocator) catch return;
    defer commit_obj.deinit(allocator);

    const new_hash = commit_obj.store(git_path, platform_impl, allocator) catch return;
    defer allocator.free(new_hash);

    refs.updateRef(git_path, current_branch, new_hash, platform_impl, allocator) catch {};

    // Write reflog
    const short_branch = if (std.mem.startsWith(u8, current_branch, "refs/heads/")) current_branch["refs/heads/".len..] else current_branch;
    const reflog_msg = std.fmt.allocPrint(allocator, "merge {s}: Merge made by the 'ours' strategy.", .{merge_target}) catch return;
    defer allocator.free(reflog_msg);
    writeReflogEntry(git_path, std.fmt.allocPrint(allocator, "refs/heads/{s}", .{short_branch}) catch return, current_hash, new_hash, reflog_msg, allocator, platform_impl);

    // Ensure work tree matches our tree (remove stale files from previous merges)
    {
        const our_tree = getCommitTree(git_path, current_hash, allocator, platform_impl) catch return;
        defer allocator.free(our_tree);
        var our_files = TreeFileMap.init(allocator);
        defer freeTreeMap(&our_files, allocator);
        parseTreeToMap(git_path, our_tree, "", &our_files, allocator, platform_impl);

        const repo_root = std.fs.path.dirname(git_path) orelse ".";
        // Scan work tree for files not in our tree and remove them
        var dir = std.fs.cwd().openDir(repo_root, .{ .iterate = true }) catch return;
        defer dir.close();
        var walker = dir.iterate();
        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.eql(u8, entry.name, ".gitignore")) continue;
            if (!our_files.contains(entry.name)) {
                dir.deleteFile(entry.name) catch {};
            }
        }
    }

    writeStdout(platform_impl, "Merge made by the 'ours' strategy.\n");
}

fn doThreeWayMerge(git_path: []const u8, current_hash: []const u8, target_hash: []const u8, current_branch: []const u8, merge_target: []const u8, opts: *MergeOpts, allocator: Allocator, platform_impl: *const pm.Platform) void {
    const merge_base = findMergeBase(git_path, current_hash, target_hash, allocator, platform_impl) catch null;
    defer if (merge_base) |b| allocator.free(b);

    const base = merge_base orelse current_hash;
    var conflict_files = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (conflict_files.items) |f| allocator.free(f);
        conflict_files.deinit();
    }
    const conflicts = doTreeMergeTracked(git_path, base, current_hash, target_hash, &conflict_files, allocator, platform_impl);

    const merge_msg = opts.message orelse (buildMergeMessage(merge_target, current_branch, git_path, allocator, platform_impl) catch "Merge");
    const should_free_msg = opts.message == null and !std.mem.eql(u8, merge_msg, "Merge");
    defer if (should_free_msg) allocator.free(@constCast(merge_msg));

    if (conflicts) {
        // Write merge state with conflict info
        writeMergeStateWithConflicts(git_path, target_hash, merge_msg, conflict_files.items, opts.cleanup, allocator, platform_impl);
        writeStderr(platform_impl, "Automatic merge failed; fix conflicts and then commit the result.\n");
        std.process.exit(1);
    }

    if (opts.no_commit) {
        writeMergeState(git_path, target_hash, merge_msg, allocator, platform_impl);
        writeStdout(platform_impl, "Automatic merge went well; stopped before committing as requested\n");
        return;
    }

    // Build final message with log if needed
    var final_msg_buf = std.array_list.Managed(u8).init(allocator);
    defer final_msg_buf.deinit();
    final_msg_buf.appendSlice(merge_msg) catch {};

    if (opts.log orelse false) {
        appendMergeLog(git_path, current_hash, merge_target, &final_msg_buf, opts.log_count, allocator, platform_impl);
    }

    if (opts.signoff) {
        appendSignoff(&final_msg_buf, allocator);
    }

    var final_msg = if (final_msg_buf.items.len > 0) final_msg_buf.items else merge_msg;

    // If --edit, write merge state first (so killed process can be continued)
    if (opts.edit orelse false) {
        // Write MERGE_HEAD, MERGE_MSG, MERGE_MODE so --continue works if killed
        writeMergeState(git_path, target_hash, final_msg, allocator, platform_impl);

        if (invokeEditor(git_path, final_msg, allocator)) |edited_msg| {
            // Strip comment lines (starting with #) and trailing whitespace
            var clean_buf = std.array_list.Managed(u8).init(allocator);
            var line_iter = std.mem.splitScalar(u8, edited_msg, '\n');
            while (line_iter.next()) |line| {
                if (line.len > 0 and line[0] == '#') continue;
                clean_buf.appendSlice(line) catch {};
                clean_buf.append('\n') catch {};
            }
            // Strip trailing newlines
            while (clean_buf.items.len > 0 and clean_buf.items[clean_buf.items.len - 1] == '\n') {
                _ = clean_buf.pop();
            }
            final_msg = clean_buf.toOwnedSlice() catch edited_msg;
        }
    }

    createMergeCommit(git_path, current_hash, target_hash, current_branch, final_msg, allocator, platform_impl);

    // Clean up merge state files after successful commit
    cleanupMergeState(git_path, allocator);

    // Show diffstat (compare old HEAD to new merge commit)
    const show_stat = opts.stat orelse true;
    if (show_stat and !opts.quiet) {
        const new_head = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
        defer if (new_head) |h| allocator.free(h);
        if (new_head) |nh| {
            showDiffstat(git_path, current_hash, nh, allocator, platform_impl);
        }
    }

    // Output strategy name
    if (opts.strategy) |strat| {
        if (std.mem.eql(u8, strat, "resolve")) {
            writeStdout(platform_impl, "Wonderful.\n");
        }
        const strat_msg = std.fmt.allocPrint(allocator, "Merge made by the '{s}' strategy.\n", .{strat}) catch "Merge made by the 'ort' strategy.\n";
        defer if (!std.mem.eql(u8, strat_msg, "Merge made by the 'ort' strategy.\n")) allocator.free(strat_msg);
        writeStdout(platform_impl, strat_msg);
    } else {
        writeStdout(platform_impl, "Merge made by the 'ort' strategy.\n");
    }
}

fn doOctopusMerge(git_path: []const u8, current_hash: []const u8, current_branch: []const u8, opts: *MergeOpts, target_hashes: []const []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    // Octopus: merge each target sequentially, creating intermediate commits
    var head = allocator.dupe(u8, current_hash) catch return;
    // We'll free head at end or when replaced

    for (target_hashes) |target_hash| {
        // Check if already up to date
        if (isAncestor(git_path, target_hash, head, allocator, platform_impl) catch false) continue;

        if (isAncestor(git_path, head, target_hash, allocator, platform_impl) catch false) {
            // Fast-forward
            checkoutTree(git_path, target_hash, allocator, platform_impl);
            allocator.free(head);
            head = allocator.dupe(u8, target_hash) catch return;
        } else {
            // Actual 3-way merge needed
            const merge_base = findMergeBase(git_path, head, target_hash, allocator, platform_impl) catch null;
            defer if (merge_base) |b| allocator.free(b);
            const base = merge_base orelse head;

            const conflicts = doTreeMerge(git_path, base, head, target_hash, allocator, platform_impl);
            if (conflicts) {
                writeStderr(platform_impl, "Should not be doing an octopus.\n");
                writeStderr(platform_impl, "fatal: merge program failed\n");
                writeStderr(platform_impl, "Automatic merge failed; fix conflicts and then commit the result.\n");
                // Restore original state
                checkoutTree(git_path, current_hash, allocator, platform_impl);
                cleanMergeState(git_path, allocator);
                std.process.exit(2);
            }

            // Create intermediate commit from working tree state
            updateIndexFromWorkTree(git_path, allocator, platform_impl);
            var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch continue;
            defer idx.deinit();
            const tree_hash = writeTreeFromIndex(allocator, &idx, git_path, platform_impl) catch continue;
            defer allocator.free(tree_hash);

            const author_line = getAuthorString(allocator) catch continue;
            defer allocator.free(author_line);
            const committer_line = getCommitterString(allocator) catch continue;
            defer allocator.free(committer_line);

            const parents = [_][]const u8{ head, target_hash };
            const commit_obj = objects.createCommitObject(tree_hash, &parents, author_line, committer_line, "intermediate octopus merge", allocator) catch continue;
            defer commit_obj.deinit(allocator);
            const new_hash = commit_obj.store(git_path, platform_impl, allocator) catch continue;

            allocator.free(head);
            head = new_hash;
        }
    }

    const merge_msg = opts.message orelse (buildOctopusMessage(opts.targets.items, current_branch, git_path, allocator, platform_impl) catch "Merge");
    const should_free = opts.message == null and !std.mem.eql(u8, merge_msg, "Merge");
    defer if (should_free) allocator.free(@constCast(merge_msg));

    if (opts.no_commit or opts.squash) {
        // Don't create commit, write merge state
        if (opts.squash) {
            // Build proper squash message matching git log --no-merges ^HEAD targets...
            var squash_buf = std.array_list.Managed(u8).init(allocator);
            defer squash_buf.deinit();
            squash_buf.appendSlice("Squashed commit of the following:\n\n") catch {};
            // Match git log behavior: walk from last target only
            if (opts.targets.items.len > 0) {
                const last_target = opts.targets.items[opts.targets.items.len - 1];
                buildSquashMsgInto(&squash_buf, git_path, current_hash, last_target, allocator, platform_impl);
            }

            const squash_path = std.fmt.allocPrint(allocator, "{s}/SQUASH_MSG", .{git_path}) catch {
                allocator.free(head);
                return;
            };
            defer allocator.free(squash_path);
            platform_impl.fs.writeFile(squash_path, squash_buf.items) catch {};
            writeStdout(platform_impl, "Squash commit -- not updating HEAD\n");
        } else {
            // Write MERGE_HEAD with all target hashes
            var mh_buf = std.array_list.Managed(u8).init(allocator);
            defer mh_buf.deinit();
            for (target_hashes) |th| {
                mh_buf.appendSlice(th) catch {};
                mh_buf.append('\n') catch {};
            }
            const mh_path = std.fmt.allocPrint(allocator, "{s}/MERGE_HEAD", .{git_path}) catch {
                allocator.free(head);
                return;
            };
            defer allocator.free(mh_path);
            platform_impl.fs.writeFile(mh_path, mh_buf.items) catch {};

            const mm_path = std.fmt.allocPrint(allocator, "{s}/MERGE_MSG", .{git_path}) catch {
                allocator.free(head);
                return;
            };
            defer allocator.free(mm_path);
            if (merge_msg.len > 0 and merge_msg[merge_msg.len - 1] != '\n') {
                const msg_nl = std.fmt.allocPrint(allocator, "{s}\n", .{merge_msg}) catch {
                    allocator.free(head);
                    return;
                };
                defer allocator.free(msg_nl);
                platform_impl.fs.writeFile(mm_path, msg_nl) catch {};
            } else {
                platform_impl.fs.writeFile(mm_path, merge_msg) catch {};
            }

            const mode_path = std.fmt.allocPrint(allocator, "{s}/MERGE_MODE", .{git_path}) catch {
                allocator.free(head);
                return;
            };
            defer allocator.free(mode_path);
            platform_impl.fs.writeFile(mode_path, "") catch {};

            writeStdout(platform_impl, "Automatic merge went well; stopped before committing as requested\n");
        }
        allocator.free(head);
        return;
    }

    // Create final octopus merge commit with all parents
    createOctopusMergeCommit(git_path, current_hash, target_hashes, current_branch, merge_msg, allocator, platform_impl);
    allocator.free(head);

    writeStdout(platform_impl, "Merge made by the 'octopus' strategy.\n");
}

fn doMergeWithFetchHead(git_path: []const u8, opts: *MergeOpts, allocator: Allocator, platform_impl: *const pm.Platform) void {
    const fetch_head_path = std.fmt.allocPrint(allocator, "{s}/FETCH_HEAD", .{git_path}) catch return;
    defer allocator.free(fetch_head_path);
    const content = std.fs.cwd().readFileAlloc(allocator, fetch_head_path, 10 * 1024 * 1024) catch return;
    defer allocator.free(content);

    // Parse first non-"not-for-merge" line
    var lines_iter = std.mem.splitScalar(u8, content, '\n');
    while (lines_iter.next()) |line| {
        if (line.len < 40) continue;
        if (std.mem.indexOf(u8, line, "not-for-merge") != null) continue;
        const hash = line[0..40];
        opts.targets.append(allocator.dupe(u8, hash) catch continue) catch continue;
        break;
    }

    if (opts.targets.items.len == 0) {
        writeStderr(platform_impl, "fatal: No remote for the current branch.\n");
        std.process.exit(128);
    }

    // Recurse with the resolved target
    cmdMerge2(git_path, opts, allocator, platform_impl);
}

fn cmdMerge2(_: []const u8, _: *MergeOpts, _: Allocator, _: *const pm.Platform) void {
    // Placeholder for recursive merge with pre-resolved targets
}

// ============================================================
// Tree merge implementation
// ============================================================

const TreeFileMap = std.StringHashMap(TreeFileEntry);

const TreeFileEntry = struct {
    hash: []const u8,
    mode: []const u8,
};

fn parseTreeToMap(git_path: []const u8, tree_hash: []const u8, prefix: []const u8, map: *TreeFileMap, allocator: Allocator, platform_impl: *const pm.Platform) void {
    const obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch return;
    defer obj.deinit(allocator);
    if (obj.type != .tree) return;

    var i: usize = 0;
    while (i < obj.data.len) {
        const space_pos = std.mem.indexOf(u8, obj.data[i..], " ") orelse break;
        const mode = obj.data[i .. i + space_pos];
        i = i + space_pos + 1;
        const null_pos = std.mem.indexOf(u8, obj.data[i..], "\x00") orelse break;
        const name = obj.data[i .. i + null_pos];
        i = i + null_pos + 1;
        if (i + 20 > obj.data.len) break;
        const hash_bytes = obj.data[i .. i + 20];
        i += 20;

        const full_path = if (prefix.len > 0)
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name }) catch continue
        else
            allocator.dupe(u8, name) catch continue;

        var hex: [40]u8 = undefined;
        for (hash_bytes, 0..) |b, bi| {
            hex[bi * 2] = "0123456789abcdef"[b >> 4];
            hex[bi * 2 + 1] = "0123456789abcdef"[b & 0xf];
        }

        if (std.mem.eql(u8, mode, "40000")) {
            const sub_hash = allocator.dupe(u8, &hex) catch {
                allocator.free(full_path);
                continue;
            };
            defer allocator.free(sub_hash);
            parseTreeToMap(git_path, sub_hash, full_path, map, allocator, platform_impl);
            allocator.free(full_path);
        } else {
            const hash_dup = allocator.dupe(u8, &hex) catch {
                allocator.free(full_path);
                continue;
            };
            const mode_dup = allocator.dupe(u8, mode) catch {
                allocator.free(full_path);
                allocator.free(hash_dup);
                continue;
            };
            map.put(full_path, .{ .hash = hash_dup, .mode = mode_dup }) catch {
                allocator.free(full_path);
                allocator.free(hash_dup);
                allocator.free(mode_dup);
            };
        }
    }
}

fn freeTreeMap(map: *TreeFileMap, allocator: Allocator) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.hash);
        allocator.free(entry.value_ptr.mode);
    }
    map.deinit();
}

/// Perform 3-way tree merge tracking conflict files. Returns true if conflicts found.
fn doTreeMergeTracked(git_path: []const u8, base_hash: []const u8, ours_hash: []const u8, theirs_hash: []const u8, conflict_files: *std.array_list.Managed([]const u8), allocator: Allocator, platform_impl: *const pm.Platform) bool {
    return doTreeMergeImpl(git_path, base_hash, ours_hash, theirs_hash, conflict_files, allocator, platform_impl);
}

/// Perform 3-way tree merge. Returns true if conflicts found.
fn doTreeMerge(git_path: []const u8, base_hash: []const u8, ours_hash: []const u8, theirs_hash: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) bool {
    return doTreeMergeImpl(git_path, base_hash, ours_hash, theirs_hash, null, allocator, platform_impl);
}

fn doTreeMergeImpl(git_path: []const u8, base_hash: []const u8, ours_hash: []const u8, theirs_hash: []const u8, conflict_files: ?*std.array_list.Managed([]const u8), allocator: Allocator, platform_impl: *const pm.Platform) bool {
    const base_tree = getCommitTree(git_path, base_hash, allocator, platform_impl) catch return true;
    defer allocator.free(base_tree);
    const ours_tree = getCommitTree(git_path, ours_hash, allocator, platform_impl) catch return true;
    defer allocator.free(ours_tree);
    const theirs_tree = getCommitTree(git_path, theirs_hash, allocator, platform_impl) catch return true;
    defer allocator.free(theirs_tree);

    var base_map = TreeFileMap.init(allocator);
    defer freeTreeMap(&base_map, allocator);
    var ours_map = TreeFileMap.init(allocator);
    defer freeTreeMap(&ours_map, allocator);
    var theirs_map = TreeFileMap.init(allocator);
    defer freeTreeMap(&theirs_map, allocator);

    parseTreeToMap(git_path, base_tree, "", &base_map, allocator, platform_impl);
    parseTreeToMap(git_path, ours_tree, "", &ours_map, allocator, platform_impl);
    parseTreeToMap(git_path, theirs_tree, "", &theirs_map, allocator, platform_impl);

    // Collect all paths
    var all_paths = std.StringHashMap(void).init(allocator);
    defer {
        var it = all_paths.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        all_paths.deinit();
    }

    var it1 = base_map.iterator();
    while (it1.next()) |e| {
        if (!all_paths.contains(e.key_ptr.*))
            all_paths.put(allocator.dupe(u8, e.key_ptr.*) catch continue, {}) catch {};
    }
    var it2 = ours_map.iterator();
    while (it2.next()) |e| {
        if (!all_paths.contains(e.key_ptr.*))
            all_paths.put(allocator.dupe(u8, e.key_ptr.*) catch continue, {}) catch {};
    }
    var it3 = theirs_map.iterator();
    while (it3.next()) |e| {
        if (!all_paths.contains(e.key_ptr.*))
            all_paths.put(allocator.dupe(u8, e.key_ptr.*) catch continue, {}) catch {};
    }

    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    var conflicts = false;

    var path_it = all_paths.iterator();
    while (path_it.next()) |entry| {
        const path = entry.key_ptr.*;
        const base_e = base_map.get(path);
        const ours_e = ours_map.get(path);
        const theirs_e = theirs_map.get(path);

        const base_h = if (base_e) |e| e.hash else null;
        const ours_h = if (ours_e) |e| e.hash else null;
        const theirs_h = if (theirs_e) |e| e.hash else null;

        if (ours_h != null and theirs_h != null and std.mem.eql(u8, ours_h.?, theirs_h.?)) {
            // Same in both - use ours (or either)
            writeFileFromBlob(git_path, path, ours_h.?, repo_root, allocator, platform_impl);
        } else if (base_h != null and ours_h != null and theirs_h != null) {
            if (std.mem.eql(u8, base_h.?, ours_h.?)) {
                // Only theirs changed
                writeFileFromBlob(git_path, path, theirs_h.?, repo_root, allocator, platform_impl);
            } else if (std.mem.eql(u8, base_h.?, theirs_h.?)) {
                // Only ours changed
                writeFileFromBlob(git_path, path, ours_h.?, repo_root, allocator, platform_impl);
            } else {
                // Both changed - try content merge
                if (tryContentMerge(git_path, path, base_h.?, ours_h.?, theirs_h.?, repo_root, allocator, platform_impl)) {
                    // Merged successfully
                } else {
                    conflicts = true;
                    if (conflict_files) |cf| cf.append(allocator.dupe(u8, path) catch path) catch {};
                    writeConflictFile(git_path, path, base_h.?, ours_h.?, theirs_h.?, repo_root, allocator, platform_impl);
                }
            }
        } else if (base_h == null and ours_h == null and theirs_h != null) {
            // Added in theirs only
            writeFileFromBlob(git_path, path, theirs_h.?, repo_root, allocator, platform_impl);
        } else if (base_h == null and ours_h != null and theirs_h == null) {
            // Added in ours only - keep
            writeFileFromBlob(git_path, path, ours_h.?, repo_root, allocator, platform_impl);
        } else if (base_h == null and ours_h != null and theirs_h != null) {
            // Added in both differently - conflict
            if (tryContentMerge(git_path, path, "", ours_h.?, theirs_h.?, repo_root, allocator, platform_impl)) {
                // OK
            } else {
                conflicts = true;
                if (conflict_files) |cf| cf.append(allocator.dupe(u8, path) catch path) catch {};
                const msg = std.fmt.allocPrint(allocator, "CONFLICT (add/add): Merge conflict in {s}\n", .{path}) catch "";
                defer if (msg.len > 0) allocator.free(msg);
                writeStderr(platform_impl, msg);
                writeConflictFile(git_path, path, "", ours_h.?, theirs_h.?, repo_root, allocator, platform_impl);
            }
        } else if (base_h != null and ours_h == null and theirs_h == null) {
            // Deleted in both
            deleteFile(path, repo_root, allocator);
        } else if (base_h != null and ours_h != null and theirs_h == null) {
            if (std.mem.eql(u8, base_h.?, ours_h.?)) {
                // Not modified in ours, deleted in theirs
                deleteFile(path, repo_root, allocator);
            } else {
                // Modified in ours, deleted in theirs - conflict
                conflicts = true;
                if (conflict_files) |cf| cf.append(allocator.dupe(u8, path) catch path) catch {};
                const msg = std.fmt.allocPrint(allocator, "CONFLICT (modify/delete): {s} deleted in theirs and modified in ours.\n", .{path}) catch "";
                defer if (msg.len > 0) allocator.free(msg);
                writeStderr(platform_impl, msg);
                writeFileFromBlob(git_path, path, ours_h.?, repo_root, allocator, platform_impl);
            }
        } else if (base_h != null and ours_h == null and theirs_h != null) {
            if (std.mem.eql(u8, base_h.?, theirs_h.?)) {
                // Not modified in theirs, deleted in ours
                deleteFile(path, repo_root, allocator);
            } else {
                // Modified in theirs, deleted in ours - conflict
                conflicts = true;
                if (conflict_files) |cf| cf.append(allocator.dupe(u8, path) catch path) catch {};
                const msg = std.fmt.allocPrint(allocator, "CONFLICT (modify/delete): {s} deleted in ours and modified in theirs.\n", .{path}) catch "";
                defer if (msg.len > 0) allocator.free(msg);
                writeStderr(platform_impl, msg);
                writeFileFromBlob(git_path, path, theirs_h.?, repo_root, allocator, platform_impl);
            }
        }
    }

    // Update index
    updateIndexFromWorkTree(git_path, allocator, platform_impl);

    return conflicts;
}

fn deleteFile(path: []const u8, repo_root: []const u8, allocator: Allocator) void {
    const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path }) catch return;
    defer allocator.free(full);
    std.fs.cwd().deleteFile(full) catch {};
}

fn writeFileFromBlob(git_path: []const u8, path: []const u8, blob_hash: []const u8, repo_root: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    const obj = objects.GitObject.load(blob_hash, git_path, platform_impl, allocator) catch return;
    defer obj.deinit(allocator);
    if (obj.type != .blob) return;

    const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path }) catch return;
    defer allocator.free(full);

    if (std.fs.path.dirname(full)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }
    platform_impl.fs.writeFile(full, obj.data) catch {};
}

fn loadBlobContent(git_path: []const u8, hash: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) []const u8 {
    if (hash.len == 0) return "";
    const obj = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch return "";
    defer obj.deinit(allocator);
    if (obj.type != .blob) return "";
    return allocator.dupe(u8, obj.data) catch "";
}

fn tryContentMerge(git_path: []const u8, path: []const u8, base_hash: []const u8, ours_hash: []const u8, theirs_hash: []const u8, repo_root: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) bool {
    const base_content = loadBlobContent(git_path, base_hash, allocator, platform_impl);
    defer if (base_content.len > 0) allocator.free(base_content);
    const ours_content = loadBlobContent(git_path, ours_hash, allocator, platform_impl);
    defer if (ours_content.len > 0) allocator.free(ours_content);
    const theirs_content = loadBlobContent(git_path, theirs_hash, allocator, platform_impl);
    defer if (theirs_content.len > 0) allocator.free(theirs_content);

    // Simple merge: if one side is same as base, take the other
    if (std.mem.eql(u8, base_content, ours_content)) {
        // Write theirs
        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path }) catch return false;
        defer allocator.free(full);
        if (std.fs.path.dirname(full)) |parent| std.fs.cwd().makePath(parent) catch {};
        platform_impl.fs.writeFile(full, theirs_content) catch return false;
        return true;
    }
    if (std.mem.eql(u8, base_content, theirs_content)) {
        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path }) catch return false;
        defer allocator.free(full);
        if (std.fs.path.dirname(full)) |parent| std.fs.cwd().makePath(parent) catch {};
        platform_impl.fs.writeFile(full, ours_content) catch return false;
        return true;
    }
    if (std.mem.eql(u8, ours_content, theirs_content)) {
        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path }) catch return false;
        defer allocator.free(full);
        if (std.fs.path.dirname(full)) |parent| std.fs.cwd().makePath(parent) catch {};
        platform_impl.fs.writeFile(full, ours_content) catch return false;
        return true;
    }

    // Try line-level 3-way merge
    const merged = lineMerge3Way(base_content, ours_content, theirs_content, allocator) orelse return false;
    defer allocator.free(merged);

    const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path }) catch return false;
    defer allocator.free(full);
    if (std.fs.path.dirname(full)) |parent| std.fs.cwd().makePath(parent) catch {};
    platform_impl.fs.writeFile(full, merged) catch return false;
    return true;
}

fn writeConflictFile(git_path: []const u8, path: []const u8, base_hash: []const u8, ours_hash: []const u8, theirs_hash: []const u8, repo_root: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    _ = base_hash;
    const ours_content = loadBlobContent(git_path, ours_hash, allocator, platform_impl);
    defer if (ours_content.len > 0) allocator.free(ours_content);
    const theirs_content = loadBlobContent(git_path, theirs_hash, allocator, platform_impl);
    defer if (theirs_content.len > 0) allocator.free(theirs_content);

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    buf.appendSlice("<<<<<<< HEAD\n") catch return;
    buf.appendSlice(ours_content) catch return;
    if (ours_content.len > 0 and ours_content[ours_content.len - 1] != '\n')
        buf.append('\n') catch return;
    buf.appendSlice("=======\n") catch return;
    buf.appendSlice(theirs_content) catch return;
    if (theirs_content.len > 0 and theirs_content[theirs_content.len - 1] != '\n')
        buf.append('\n') catch return;
    buf.appendSlice(">>>>>>> incoming\n") catch return;

    const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path }) catch return;
    defer allocator.free(full);
    if (std.fs.path.dirname(full)) |parent| std.fs.cwd().makePath(parent) catch {};
    platform_impl.fs.writeFile(full, buf.items) catch {};
}

// ============================================================
// Merge message helpers
// ============================================================

fn buildMergeMessage(merge_target: []const u8, current_branch: []const u8, git_path: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) ![]u8 {
    _ = platform_impl;
    const short_branch = if (std.mem.startsWith(u8, current_branch, "refs/heads/")) current_branch["refs/heads/".len..] else current_branch;

    // Check if target is branch~N or branch^N format
    const tilde_pos = std.mem.indexOf(u8, merge_target, "~");
    const caret_pos = std.mem.indexOf(u8, merge_target, "^");
    const suffix_pos = if (tilde_pos != null and caret_pos != null) @min(tilde_pos.?, caret_pos.?) else (tilde_pos orelse caret_pos);

    if (suffix_pos) |sp| {
        const base_name = merge_target[0..sp];
        // Check if base_name is a branch
        const is_branch = isBranchRef(git_path, base_name, allocator);
        if (is_branch) {
            if (isDefaultBranch(short_branch, allocator)) {
                return std.fmt.allocPrint(allocator, "Merge branch '{s}' (early part)", .{base_name});
            } else {
                return std.fmt.allocPrint(allocator, "Merge branch '{s}' (early part) into {s}", .{ base_name, short_branch });
            }
        }
        // If it's a tag with suffix, use "Merge commit 'target'"
        if (isTagRef(git_path, base_name, allocator)) {
            if (isDefaultBranch(short_branch, allocator)) {
                return std.fmt.allocPrint(allocator, "Merge commit '{s}'", .{merge_target});
            } else {
                return std.fmt.allocPrint(allocator, "Merge commit '{s}' into {s}", .{ merge_target, short_branch });
            }
        }
        // Default: "Merge commit 'target'"
        if (isDefaultBranch(short_branch, allocator)) {
            return std.fmt.allocPrint(allocator, "Merge commit '{s}'", .{merge_target});
        } else {
            return std.fmt.allocPrint(allocator, "Merge commit '{s}' into {s}", .{ merge_target, short_branch });
        }
    }

    const is_tag = isTagRef(git_path, merge_target, allocator);
    const kind = if (is_tag) "tag" else "branch";
    if (isDefaultBranch(short_branch, allocator)) {
        return std.fmt.allocPrint(allocator, "Merge {s} '{s}'", .{ kind, merge_target });
    } else {
        return std.fmt.allocPrint(allocator, "Merge {s} '{s}' into {s}", .{ kind, merge_target, short_branch });
    }
}

fn isBranchRef(git_path: []const u8, name: []const u8, allocator: Allocator) bool {
    const branch_path = std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, name }) catch return false;
    defer allocator.free(branch_path);
    if (std.fs.cwd().access(branch_path, .{})) |_| return true else |_| {}

    // Check packed-refs
    const packed_path = std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_path}) catch return false;
    defer allocator.free(packed_path);
    const packed_ref = std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name}) catch return false;
    defer allocator.free(packed_ref);
    if (std.fs.cwd().readFileAlloc(allocator, packed_path, 10 * 1024 * 1024)) |content| {
        defer allocator.free(content);
        return std.mem.indexOf(u8, content, packed_ref) != null;
    } else |_| {}
    return false;
}

fn isTagRef(git_path: []const u8, name: []const u8, allocator: Allocator) bool {
    const tag_path = std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{ git_path, name }) catch return false;
    defer allocator.free(tag_path);
    if (std.fs.cwd().access(tag_path, .{})) |_| return true else |_| {}

    // Check packed-refs
    const packed_path = std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_path}) catch return false;
    defer allocator.free(packed_path);
    const packed_ref = std.fmt.allocPrint(allocator, "refs/tags/{s}", .{name}) catch return false;
    defer allocator.free(packed_ref);
    if (std.fs.cwd().readFileAlloc(allocator, packed_path, 10 * 1024 * 1024)) |content| {
        defer allocator.free(content);
        return std.mem.indexOf(u8, content, packed_ref) != null;
    } else |_| {}
    return false;
}

fn isDefaultBranch(branch: []const u8, allocator: Allocator) bool {
    if (std.process.getEnvVarOwned(allocator, "GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME") catch null) |ev| {
        defer allocator.free(ev);
        if (ev.len > 0) return std.mem.eql(u8, branch, ev);
    }
    return std.mem.eql(u8, branch, "master") or std.mem.eql(u8, branch, "main");
}

fn buildOctopusMessage(targets: []const []const u8, current_branch: []const u8, git_path: []const u8, allocator: Allocator, _: *const pm.Platform) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    const short_branch = if (std.mem.startsWith(u8, current_branch, "refs/heads/")) current_branch["refs/heads/".len..] else current_branch;

    if (targets.len == 1) {
        const is_tag = isTagRef(git_path, targets[0], allocator);
        const kind = if (is_tag) "tag" else "branch";
        try buf.appendSlice("Merge ");
        try buf.appendSlice(kind);
        try buf.appendSlice(" '");
        try buf.appendSlice(targets[0]);
        try buf.appendSlice("'");
    } else {
        try buf.appendSlice("Merge ");
        // Check types
        var all_tags = true;
        var all_branches = true;
        for (targets) |t| {
            if (isTagRef(git_path, t, allocator)) {
                all_branches = false;
            } else {
                all_tags = false;
            }
        }
        if (all_tags) {
            try buf.appendSlice("tags ");
        } else if (all_branches) {
            try buf.appendSlice("branches ");
        } else {
            try buf.appendSlice("commits ");
        }
        for (targets, 0..) |t, i| {
            if (i > 0) {
                if (i == targets.len - 1) {
                    try buf.appendSlice(" and ");
                } else {
                    try buf.appendSlice(", ");
                }
            }
            try buf.append('\'');
            try buf.appendSlice(t);
            try buf.append('\'');
        }
    }

    if (!isDefaultBranch(short_branch, allocator)) {
        try buf.appendSlice(" into ");
        try buf.appendSlice(short_branch);
    }

    return buf.toOwnedSlice();
}

fn buildSquashMsgBuf(git_path: []const u8, current_hash: []const u8, merge_target: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) std.array_list.Managed(u8) {
    var buf = std.array_list.Managed(u8).init(allocator);
    buf.appendSlice("Squashed commit of the following:\n\n") catch {};
    buildSquashMsgInto(&buf, git_path, current_hash, merge_target, allocator, platform_impl);
    return buf;
}

fn buildSquashMsg(git_path: []const u8, current_hash: []const u8, merge_target: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) []const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    buf.appendSlice("Squashed commit of the following:\n\n") catch return "";
    buildSquashMsgInto(&buf, git_path, current_hash, merge_target, allocator, platform_impl);
    return buf.toOwnedSlice() catch "";
}

fn buildSquashMsgMultiple(buf: *std.array_list.Managed(u8), git_path: []const u8, _: []const u8, targets: []const []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    // Walk all targets and collect commits in timestamp-descending order (like git log)
    // This matches git log --no-merges ^HEAD <targets> behavior
    const SquashCommitInfo = struct {
        hash: []const u8,
        timestamp: i64,
        data: []const u8,
    };

    var commits = std.array_list.Managed(SquashCommitInfo).init(allocator);
    defer {
        for (commits.items) |ci| {
            allocator.free(ci.hash);
            allocator.free(ci.data);
        }
        commits.deinit();
    }
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        seen.deinit();
    }

    for (targets) |tgt| {
        const target_hash = resolveToCommitHash(git_path, tgt, allocator, platform_impl) catch continue;
        defer allocator.free(target_hash);

        var commit_h = allocator.dupe(u8, target_hash) catch continue;
        var depth: usize = 0;
        while (depth < 100) : (depth += 1) {
            if (seen.contains(commit_h)) {
                allocator.free(commit_h);
                break;
            }
            seen.put(allocator.dupe(u8, commit_h) catch {
                allocator.free(commit_h);
                break;
            }, {}) catch {
                allocator.free(commit_h);
                break;
            };

            const obj = objects.GitObject.load(commit_h, git_path, platform_impl, allocator) catch {
                allocator.free(commit_h);
                break;
            };
            // Don't defer deinit - we'll store the data

            var parent_count: usize = 0;
            var first_parent: ?[]const u8 = null;
            var ts: i64 = 0;
            {
                var hl = std.mem.splitScalar(u8, obj.data, '\n');
                while (hl.next()) |line| {
                    if (std.mem.startsWith(u8, line, "parent ")) {
                        parent_count += 1;
                        if (first_parent == null) first_parent = line["parent ".len..];
                    }
                    if (std.mem.startsWith(u8, line, "committer ")) {
                        // Extract timestamp
                        if (std.mem.lastIndexOf(u8, line, ">")) |gt| {
                            const rest = std.mem.trim(u8, line[gt + 1 ..], " ");
                            if (std.mem.indexOf(u8, rest, " ")) |sp| {
                                ts = std.fmt.parseInt(i64, rest[0..sp], 10) catch 0;
                            }
                        }
                    }
                    if (line.len == 0) break;
                }
            }

            if (parent_count <= 1) {
                commits.append(.{
                    .hash = allocator.dupe(u8, commit_h) catch {
                        obj.deinit(allocator);
                        allocator.free(commit_h);
                        break;
                    },
                    .timestamp = ts,
                    .data = allocator.dupe(u8, obj.data) catch {
                        obj.deinit(allocator);
                        allocator.free(commit_h);
                        break;
                    },
                }) catch {};
            }

            obj.deinit(allocator);

            const next = if (first_parent) |ph| allocator.dupe(u8, ph) catch null else null;
            allocator.free(commit_h);
            if (next) |n| {
                commit_h = n;
            } else break;
        }
    }

    // Sort by timestamp descending (matching git log order)
    std.mem.sort(SquashCommitInfo, commits.items, {}, struct {
        fn cmp(_: void, a: SquashCommitInfo, b: SquashCommitInfo) bool {
            return a.timestamp > b.timestamp;
        }
    }.cmp);

    for (commits.items) |ci| {
        formatCommitForSquash(ci.data, ci.hash, buf);
    }
}

fn buildSquashMsgInto(buf: *std.array_list.Managed(u8), git_path: []const u8, _: []const u8, merge_target: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {

    // Get target hash
    const target_hash = resolveToCommitHash(git_path, merge_target, allocator, platform_impl) catch return;
    defer allocator.free(target_hash);

    // Walk from target through all ancestors (matching git log --no-merges ^HEAD behavior)
    var commit = allocator.dupe(u8, target_hash) catch return;
    var depth: usize = 0;
    while (depth < 100) : (depth += 1) {

        const obj = objects.GitObject.load(commit, git_path, platform_impl, allocator) catch {
            allocator.free(commit);
            break;
        };
        defer obj.deinit(allocator);

        // Skip merge commits (--no-merges)
        var parent_count: usize = 0;
        var first_parent: ?[]const u8 = null;
        {
            var hl = std.mem.splitScalar(u8, obj.data, '\n');
            while (hl.next()) |line| {
                if (std.mem.startsWith(u8, line, "parent ")) {
                    parent_count += 1;
                    if (first_parent == null) first_parent = line["parent ".len..];
                }
                if (line.len == 0) break;
            }
        }

        if (parent_count <= 1) {
            // Format this commit
            formatCommitForSquash(obj.data, commit, buf);
        }

        allocator.free(commit);
        if (first_parent) |ph| {
            commit = allocator.dupe(u8, ph) catch break;
        } else break;
    }

}

fn collectAncestorSet(git_path: []const u8, hash: []const u8, set: *std.StringHashMap(void), allocator: Allocator, platform_impl: *const pm.Platform) void {
    if (set.contains(hash)) return;
    set.put(allocator.dupe(u8, hash) catch return, {}) catch return;

    const obj = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch return;
    defer obj.deinit(allocator);
    if (obj.type != .commit) return;

    var lines_iter = std.mem.splitScalar(u8, obj.data, '\n');
    while (lines_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "parent ")) {
            collectAncestorSet(git_path, line["parent ".len..], set, allocator, platform_impl);
        }
        if (line.len == 0) break;
    }
}

fn formatCommitForSquash(data: []const u8, hash: []const u8, buf: *std.array_list.Managed(u8)) void {
    const msg_start = std.mem.indexOf(u8, data, "\n\n") orelse return;
    const headers = data[0..msg_start];
    const msg_body = data[msg_start + 2 ..];

    // Extract author info - use medium format (Author + Date on separate lines) matching git log
    var author_name_email: []const u8 = "";
    var author_ts: []const u8 = "";
    var author_tz: []const u8 = "";

    var hl_iter = std.mem.splitScalar(u8, headers, '\n');
    while (hl_iter.next()) |hl| {
        if (std.mem.startsWith(u8, hl, "author ")) {
            const author_str = hl["author ".len..];
            if (std.mem.lastIndexOf(u8, author_str, ">")) |gt| {
                author_name_email = author_str[0 .. gt + 1];
                const rest = std.mem.trim(u8, author_str[gt + 1 ..], " ");
                if (std.mem.indexOf(u8, rest, " ")) |sp| {
                    author_ts = rest[0..sp];
                    author_tz = rest[sp + 1 ..];
                } else {
                    author_ts = rest;
                }
            }
        }
    }

    buf.appendSlice("commit ") catch {};
    buf.appendSlice(hash) catch {};
    buf.append('\n') catch {};
    buf.appendSlice("Author: ") catch {};
    buf.appendSlice(author_name_email) catch {};
    buf.append('\n') catch {};

    // Format date in git log medium format
    const page_alloc = @import("std").heap.page_allocator;
    const formatted_date = formatGitDate(author_ts, author_tz, page_alloc);
    defer if (formatted_date.len > 0) page_alloc.free(formatted_date);
    buf.appendSlice("Date:   ") catch {};
    if (formatted_date.len > 0) {
        buf.appendSlice(formatted_date) catch {};
    } else {
        buf.appendSlice(author_ts) catch {};
        buf.append(' ') catch {};
        buf.appendSlice(author_tz) catch {};
    }
    buf.append('\n') catch {};
    buf.append('\n') catch {};

    // Indent message body, matching git log format
    var msg_iter = std.mem.splitScalar(u8, msg_body, '\n');
    while (msg_iter.next()) |ml| {
        // Skip trailing empty lines from the raw commit data
        if (ml.len == 0 and msg_iter.peek() == null) break;
        buf.appendSlice("    ") catch {};
        buf.appendSlice(ml) catch {};
        buf.append('\n') catch {};
    }
    buf.append('\n') catch {};
}

fn formatGitDate(ts_str: []const u8, tz_str: []const u8, allocator: Allocator) []u8 {
    const ts = std.fmt.parseInt(i64, ts_str, 10) catch return allocator.alloc(u8, 0) catch "";

    // Parse timezone offset
    var tz_offset_minutes: i32 = 0;
    if (tz_str.len >= 5) {
        const sign: i32 = if (tz_str[0] == '-') -1 else 1;
        const hours = std.fmt.parseInt(i32, tz_str[1..3], 10) catch 0;
        const minutes = std.fmt.parseInt(i32, tz_str[3..5], 10) catch 0;
        tz_offset_minutes = sign * (hours * 60 + minutes);
    }

    // Adjust timestamp by timezone
    const adjusted_ts = ts + @as(i64, tz_offset_minutes) * 60;

    // Convert to date components
    const epoch_secs: u64 = if (adjusted_ts >= 0) @intCast(adjusted_ts) else 0;
    const epoch_day = @divFloor(epoch_secs, 86400);
    const day_secs = epoch_secs % 86400;
    const hour = day_secs / 3600;
    const minute = (day_secs % 3600) / 60;
    const second = day_secs % 60;

    // Calculate date from epoch days (Jan 1 1970 = day 0)
    // Using a simplified algorithm
    var y: i64 = 1970;
    var remaining_days: i64 = @intCast(epoch_day);

    while (remaining_days >= daysInYear(y)) {
        remaining_days -= daysInYear(y);
        y += 1;
    }

    const month_days = [_]i64{ 31, if (isLeapYear(y)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: usize = 0;
    while (m < 12 and remaining_days >= month_days[m]) {
        remaining_days -= month_days[m];
        m += 1;
    }

    const day = remaining_days + 1;
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const day_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const dow = epoch_day % 7; // Jan 1 1970 was Thursday

    return std.fmt.allocPrint(allocator, "{s} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} {d} {s}", .{
        day_names[dow],
        month_names[m],
        day,
        hour,
        minute,
        second,
        y,
        tz_str,
    }) catch allocator.alloc(u8, 0) catch "";
}

fn daysInYear(y: i64) i64 {
    return if (isLeapYear(y)) 366 else 365;
}

fn isLeapYear(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

fn appendMergeLog(git_path: []const u8, current_hash: []const u8, merge_target: []const u8, buf: *std.array_list.Managed(u8), max_count: ?u32, allocator: Allocator, platform_impl: *const pm.Platform) void {
    const target_hash = resolveToCommitHash(git_path, merge_target, allocator, platform_impl) catch return;
    defer allocator.free(target_hash);

    const merge_base = findMergeBase(git_path, current_hash, target_hash, allocator, platform_impl) catch null;
    defer if (merge_base) |b| allocator.free(b);

    const is_tag = isTagRef(git_path, merge_target, allocator);
    const kind = if (is_tag) "tag" else "branch";

    buf.appendSlice("\n") catch return;
    const header = std.fmt.allocPrint(allocator, "# By {s} '{s}':\n", .{ kind, merge_target }) catch return;
    defer allocator.free(header);

    // Not exactly right but close enough - walk log
    buf.appendSlice("* ") catch return;
    buf.appendSlice(kind) catch return;
    buf.appendSlice(" '") catch return;
    buf.appendSlice(merge_target) catch return;
    buf.appendSlice("':\n") catch return;

    var commit = allocator.dupe(u8, target_hash) catch return;
    var count: u32 = 0;
    const limit = max_count orelse 20;
    while (count < limit) : (count += 1) {
        if (merge_base) |mb| {
            if (std.mem.eql(u8, commit, mb)) {
                allocator.free(commit);
                break;
            }
        }
        const obj = objects.GitObject.load(commit, git_path, platform_impl, allocator) catch {
            allocator.free(commit);
            break;
        };
        defer obj.deinit(allocator);

        if (std.mem.indexOf(u8, obj.data, "\n\n")) |ms| {
            const msg = obj.data[ms + 2 ..];
            const first_line_end = std.mem.indexOf(u8, msg, "\n") orelse msg.len;
            buf.appendSlice("  ") catch {};
            buf.appendSlice(msg[0..first_line_end]) catch {};
            buf.append('\n') catch {};
        }

        var parent_hash: ?[]const u8 = null;
        var lines2 = std.mem.splitScalar(u8, obj.data, '\n');
        while (lines2.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                parent_hash = line["parent ".len..];
                break;
            }
            if (line.len == 0) break;
        }

        allocator.free(commit);
        if (parent_hash) |ph| {
            commit = allocator.dupe(u8, ph) catch break;
        } else break;
    }
}

fn appendSignoff(buf: *std.array_list.Managed(u8), allocator: Allocator) void {
    const committer_str = getCommitterString(allocator) catch return;
    defer allocator.free(committer_str);
    const gt = std.mem.lastIndexOf(u8, committer_str, ">") orelse committer_str.len;
    const name_email = committer_str[0..@min(gt + 1, committer_str.len)];
    buf.appendSlice("\n\nSigned-off-by: ") catch return;
    buf.appendSlice(name_email) catch return;
}

// ============================================================
// Helper operations
// ============================================================

fn checkoutTreeNoHead(git_path: []const u8, commit_hash: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    // Checkout files from commit tree without updating HEAD or index based on HEAD
    const tree_hash = getCommitTree(git_path, commit_hash, allocator, platform_impl) catch return;
    defer allocator.free(tree_hash);
    const repo_root = std.fs.path.dirname(git_path) orelse ".";

    var file_map = TreeFileMap.init(allocator);
    defer freeTreeMap(&file_map, allocator);
    parseTreeToMap(git_path, tree_hash, "", &file_map, allocator, platform_impl);

    // Write all files from tree
    var it = file_map.iterator();
    while (it.next()) |entry| {
        writeFileFromBlob(git_path, entry.key_ptr.*, entry.value_ptr.hash, repo_root, allocator, platform_impl);
    }

    // Update index to match the target tree (not HEAD)
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch {
        return;
    };
    defer idx.deinit();

    var it2 = file_map.iterator();
    while (it2.next()) |entry| {
        idx.add(entry.key_ptr.*, entry.key_ptr.*, platform_impl, git_path) catch {};
    }
    idx.save(git_path, platform_impl) catch {};
}

fn checkoutTree(git_path: []const u8, commit_hash: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    const tree_hash = getCommitTree(git_path, commit_hash, allocator, platform_impl) catch return;
    defer allocator.free(tree_hash);
    const repo_root = std.fs.path.dirname(git_path) orelse ".";

    // Parse tree and write all files
    var file_map = TreeFileMap.init(allocator);
    defer freeTreeMap(&file_map, allocator);
    parseTreeToMap(git_path, tree_hash, "", &file_map, allocator, platform_impl);

    // First, clean up files not in target tree
    cleanWorkTree(git_path, &file_map, repo_root, allocator, platform_impl);

    // Write all files from tree
    var it = file_map.iterator();
    while (it.next()) |entry| {
        writeFileFromBlob(git_path, entry.key_ptr.*, entry.value_ptr.hash, repo_root, allocator, platform_impl);
    }

    // Update index
    updateIndexFromWorkTree(git_path, allocator, platform_impl);
}

fn cleanWorkTree(git_path: []const u8, target_map: *TreeFileMap, repo_root: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    // Get current index and remove files not in target
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
    defer idx.deinit();

    for (idx.entries.items) |entry| {
        if (!target_map.contains(entry.path)) {
            const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path }) catch continue;
            defer allocator.free(full);
            std.fs.cwd().deleteFile(full) catch {};
        }
    }
}

fn updateIndexFromWorkTree(git_path: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    const repo_root = std.fs.path.dirname(git_path) orelse ".";

    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch {
        var new_idx = index_mod.Index.init(allocator);
        defer new_idx.deinit();
        // Add all files from working tree - simplified
        return;
    };
    defer idx.deinit();

    // Get current tree to know what files should be tracked
    const head_hash = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
    defer if (head_hash) |h| allocator.free(h);

    if (head_hash) |hh| {
        const tree_hash = getCommitTree(git_path, hh, allocator, platform_impl) catch return;
        defer allocator.free(tree_hash);

        var tree_map = TreeFileMap.init(allocator);
        defer freeTreeMap(&tree_map, allocator);
        parseTreeToMap(git_path, tree_hash, "", &tree_map, allocator, platform_impl);

        // Collect all paths (from both index and tree)
        var all_paths = std.StringHashMap(void).init(allocator);
        defer {
            var it = all_paths.iterator();
            while (it.next()) |e| allocator.free(e.key_ptr.*);
            all_paths.deinit();
        }

        for (idx.entries.items) |entry| {
            if (!all_paths.contains(entry.path))
                all_paths.put(allocator.dupe(u8, entry.path) catch continue, {}) catch {};
        }
        var tm_it = tree_map.iterator();
        while (tm_it.next()) |entry| {
            if (!all_paths.contains(entry.key_ptr.*))
                all_paths.put(allocator.dupe(u8, entry.key_ptr.*) catch continue, {}) catch {};
        }

        var ap_it = all_paths.iterator();
        while (ap_it.next()) |entry| {
            const path = entry.key_ptr.*;
            const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path }) catch continue;
            defer allocator.free(full);

            if (std.fs.cwd().openFile(full, .{})) |file| {
                file.close();
                idx.add(path, path, platform_impl, git_path) catch {};
            } else |_| {
                idx.remove(path) catch {};
            }
        }
    }

    idx.save(git_path, platform_impl) catch {};
}

fn resetIndexToCommit(git_path: []const u8, commit_hash: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    const tree_hash = getCommitTree(git_path, commit_hash, allocator, platform_impl) catch return;
    defer allocator.free(tree_hash);

    var tree_map = TreeFileMap.init(allocator);
    defer freeTreeMap(&tree_map, allocator);
    parseTreeToMap(git_path, tree_hash, "", &tree_map, allocator, platform_impl);

    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    var idx = index_mod.Index.init(allocator);
    defer idx.deinit();

    var it = tree_map.iterator();
    while (it.next()) |entry| {
        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.key_ptr.* }) catch continue;
        defer allocator.free(full);
        idx.add(entry.key_ptr.*, entry.key_ptr.*, platform_impl, git_path) catch {};
    }
    idx.save(git_path, platform_impl) catch {};
}

fn createMergeCommit(git_path: []const u8, current_hash: []const u8, target_hash: []const u8, current_branch: []const u8, message: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    // Build tree from current index
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch {
        writeStderr(platform_impl, "fatal: unable to load index\n");
        std.process.exit(128);
    };
    defer idx.deinit();

    // Re-add all tracked files
    updateIndexFromWorkTree(git_path, allocator, platform_impl);
    // Reload
    var idx2 = index_mod.Index.load(git_path, platform_impl, allocator) catch {
        writeStderr(platform_impl, "fatal: unable to load index\n");
        std.process.exit(128);
    };
    defer idx2.deinit();

    const tree_hash = writeTreeFromIndex(allocator, &idx2, git_path, platform_impl) catch {
        writeStderr(platform_impl, "fatal: unable to write tree\n");
        std.process.exit(128);
    };
    defer allocator.free(tree_hash);

    const author_line = getAuthorString(allocator) catch blk: {
        const ts = std.time.timestamp();
        break :blk std.fmt.allocPrint(allocator, "User <user@example.com> {d} +0000", .{ts}) catch return;
    };
    defer allocator.free(author_line);
    const committer_line = getCommitterString(allocator) catch blk: {
        const ts = std.time.timestamp();
        break :blk std.fmt.allocPrint(allocator, "User <user@example.com> {d} +0000", .{ts}) catch return;
    };
    defer allocator.free(committer_line);

    const parents = [_][]const u8{ current_hash, target_hash };
    const commit_obj = objects.createCommitObject(tree_hash, &parents, author_line, committer_line, message, allocator) catch return;
    defer commit_obj.deinit(allocator);

    const new_hash = commit_obj.store(git_path, platform_impl, allocator) catch return;
    defer allocator.free(new_hash);

    refs.updateRef(git_path, current_branch, new_hash, platform_impl, allocator) catch {};
}

fn createOctopusMergeCommit(git_path: []const u8, current_hash: []const u8, target_hashes: []const []const u8, current_branch: []const u8, message: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    updateIndexFromWorkTree(git_path, allocator, platform_impl);

    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
    defer idx.deinit();

    const tree_hash = writeTreeFromIndex(allocator, &idx, git_path, platform_impl) catch return;
    defer allocator.free(tree_hash);

    const author_line = getAuthorString(allocator) catch return;
    defer allocator.free(author_line);
    const committer_line = getCommitterString(allocator) catch return;
    defer allocator.free(committer_line);

    // Build parents list
    var parents = std.array_list.Managed([]const u8).init(allocator);
    defer parents.deinit();
    parents.append(current_hash) catch return;
    for (target_hashes) |th| parents.append(th) catch {};

    const commit_obj = objects.createCommitObject(tree_hash, parents.items, author_line, committer_line, message, allocator) catch return;
    defer commit_obj.deinit(allocator);

    const new_hash = commit_obj.store(git_path, platform_impl, allocator) catch return;
    defer allocator.free(new_hash);

    refs.updateRef(git_path, current_branch, new_hash, platform_impl, allocator) catch {};
}

fn showDiffstat(git_path: []const u8, from_hash: []const u8, to_hash: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    // Get both trees
    const from_tree = getCommitTree(git_path, from_hash, allocator, platform_impl) catch return;
    defer allocator.free(from_tree);
    const to_tree = getCommitTree(git_path, to_hash, allocator, platform_impl) catch return;
    defer allocator.free(to_tree);

    var entries = std.array_list.Managed(diff_stats.StatEntry).init(allocator);
    defer {
        for (entries.items) |e| {
            allocator.free(e.path);
        }
        entries.deinit();
    }

    diff_stats.collectAccurate(allocator, from_tree, to_tree, "", git_path, &.{}, platform_impl, &entries) catch return;
    diff_stats.formatStat(entries.items, platform_impl, allocator) catch return;

    // Show create/delete mode summary lines
    for (entries.items) |e| {
        if (e.is_new) {
            const line = std.fmt.allocPrint(allocator, " create mode 100644 {s}\n", .{e.path}) catch continue;
            defer allocator.free(line);
            writeStdout(platform_impl, line);
        } else if (e.is_deleted) {
            const line = std.fmt.allocPrint(allocator, " delete mode 100644 {s}\n", .{e.path}) catch continue;
            defer allocator.free(line);
            writeStdout(platform_impl, line);
        }
    }
}

fn writeMergeStateWithConflicts(git_path: []const u8, target_hash: []const u8, message: []const u8, conflict_files: []const []const u8, cleanup: ?[]const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    const merge_head_path = std.fmt.allocPrint(allocator, "{s}/MERGE_HEAD", .{git_path}) catch return;
    defer allocator.free(merge_head_path);
    const head_content = std.fmt.allocPrint(allocator, "{s}\n", .{target_hash}) catch return;
    defer allocator.free(head_content);
    platform_impl.fs.writeFile(merge_head_path, head_content) catch {};

    // Build MERGE_MSG with conflict info
    var msg_buf = std.array_list.Managed(u8).init(allocator);
    defer msg_buf.deinit();
    msg_buf.appendSlice(message) catch {};
    if (message.len > 0 and message[message.len - 1] != '\n') msg_buf.append('\n') catch {};
    appendConflictInfo(&msg_buf, conflict_files, cleanup);

    const merge_msg_path = std.fmt.allocPrint(allocator, "{s}/MERGE_MSG", .{git_path}) catch return;
    defer allocator.free(merge_msg_path);
    platform_impl.fs.writeFile(merge_msg_path, msg_buf.items) catch {};

    const merge_mode_path = std.fmt.allocPrint(allocator, "{s}/MERGE_MODE", .{git_path}) catch return;
    defer allocator.free(merge_mode_path);
    platform_impl.fs.writeFile(merge_mode_path, "") catch {};
}

fn appendConflictInfo(buf: *std.array_list.Managed(u8), conflict_files: []const []const u8, cleanup: ?[]const u8) void {
    if (conflict_files.len == 0) return;

    const is_scissors = if (cleanup) |c| std.ascii.eqlIgnoreCase(c, "scissors") else false;

    if (is_scissors) {
        // Always ensure blank line before scissors
        if (buf.items.len > 0 and buf.items[buf.items.len - 1] != '\n') {
            buf.append('\n') catch {};
        }
        // Ensure double newline (blank line) before scissors
        if (buf.items.len < 2 or buf.items[buf.items.len - 1] != '\n' or buf.items[buf.items.len - 2] != '\n') {
            buf.append('\n') catch {};
        }
        buf.appendSlice("# ------------------------ >8 ------------------------\n") catch {};
        buf.appendSlice("# Do not modify or remove the line above.\n") catch {};
        buf.appendSlice("# Everything below it will be ignored.\n#\n") catch {};
        buf.appendSlice("# Conflicts:\n") catch {};
    } else {
        // Don't add extra blank line if buffer already ends with one
        const ends_with_blank = buf.items.len >= 2 and buf.items[buf.items.len - 1] == '\n' and buf.items[buf.items.len - 2] == '\n';
        if (!ends_with_blank) {
            buf.append('\n') catch {};
        }
        buf.appendSlice("# Conflicts:\n") catch {};
    }
    for (conflict_files) |f| {
        buf.appendSlice("#\t") catch {};
        buf.appendSlice(f) catch {};
        buf.append('\n') catch {};
    }
}

fn writeMergeState(git_path: []const u8, target_hash: []const u8, message: []const u8, allocator: Allocator, platform_impl: *const pm.Platform) void {
    const merge_head_path = std.fmt.allocPrint(allocator, "{s}/MERGE_HEAD", .{git_path}) catch return;
    defer allocator.free(merge_head_path);
    const head_content = std.fmt.allocPrint(allocator, "{s}\n", .{target_hash}) catch return;
    defer allocator.free(head_content);
    platform_impl.fs.writeFile(merge_head_path, head_content) catch {};

    const merge_msg_path = std.fmt.allocPrint(allocator, "{s}/MERGE_MSG", .{git_path}) catch return;
    defer allocator.free(merge_msg_path);
    // Ensure message ends with newline
    if (message.len > 0 and message[message.len - 1] != '\n') {
        const msg_nl = std.fmt.allocPrint(allocator, "{s}\n", .{message}) catch return;
        defer allocator.free(msg_nl);
        platform_impl.fs.writeFile(merge_msg_path, msg_nl) catch {};
    } else {
        platform_impl.fs.writeFile(merge_msg_path, message) catch {};
    }

    const merge_mode_path = std.fmt.allocPrint(allocator, "{s}/MERGE_MODE", .{git_path}) catch return;
    defer allocator.free(merge_mode_path);
    platform_impl.fs.writeFile(merge_mode_path, "") catch {};
}

fn cleanupMergeState(git_path: []const u8, allocator: Allocator) void {
    const files = [_][]const u8{ "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE" };
    for (files) |f| {
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, f }) catch continue;
        defer allocator.free(path);
        std.fs.cwd().deleteFile(path) catch {};
    }
}

fn writeReflogEntry(git_path: []const u8, ref_name: []const u8, old_hash: []const u8, new_hash: []const u8, message: []const u8, allocator: Allocator, _: *const pm.Platform) void {
    const committer = getCommitterString(allocator) catch return;
    defer allocator.free(committer);

    const entry = std.fmt.allocPrint(allocator, "{s} {s} {s}\t{s}\n", .{ old_hash, new_hash, committer, message }) catch return;
    defer allocator.free(entry);

    // Write to branch reflog
    const reflog_path = std.fmt.allocPrint(allocator, "{s}/logs/{s}", .{ git_path, ref_name }) catch return;
    defer allocator.free(reflog_path);
    appendToReflog(reflog_path, entry);

    // Also write to HEAD reflog
    const head_reflog = std.fmt.allocPrint(allocator, "{s}/logs/HEAD", .{git_path}) catch return;
    defer allocator.free(head_reflog);
    appendToReflog(head_reflog, entry);
}

fn appendToReflog(path: []const u8, entry: []const u8) void {
    if (std.fs.path.dirname(path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }
    var file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch {
        var f = std.fs.cwd().createFile(path, .{}) catch return;
        f.writeAll(entry) catch {};
        f.close();
        return;
    };
    defer file.close();
    file.seekFromEnd(0) catch {};
    file.writeAll(entry) catch {};
}

// ============================================================
// Line-level 3-way merge
// ============================================================

fn lineMerge3Way(base: []const u8, ours: []const u8, theirs: []const u8, allocator: Allocator) ?[]u8 {
    const base_lines = splitLines2(base, allocator) orelse return null;
    defer allocator.free(base_lines);
    const ours_lines = splitLines2(ours, allocator) orelse return null;
    defer allocator.free(ours_lines);
    const theirs_lines = splitLines2(theirs, allocator) orelse return null;
    defer allocator.free(theirs_lines);

    // Compute LCS of base with ours/theirs
    const ours_lcs = computeLCS(base_lines, ours_lines, allocator) orelse return null;
    defer allocator.free(ours_lcs);
    const theirs_lcs = computeLCS(base_lines, theirs_lines, allocator) orelse return null;
    defer allocator.free(theirs_lcs);

    var ours_kept = allocator.alloc(bool, base_lines.len) catch return null;
    defer allocator.free(ours_kept);
    var theirs_kept = allocator.alloc(bool, base_lines.len) catch return null;
    defer allocator.free(theirs_kept);
    @memset(ours_kept, false);
    @memset(theirs_kept, false);
    for (ours_lcs) |bi| ours_kept[bi] = true;
    for (theirs_lcs) |bi| theirs_kept[bi] = true;

    // Find common anchors
    var anchors = std.array_list.Managed(usize).init(allocator);
    defer anchors.deinit();
    for (0..base_lines.len) |bi| {
        if (ours_kept[bi] and theirs_kept[bi])
            anchors.append(bi) catch {};
    }

    // Map anchors to ours/theirs indices
    var ours_map = std.array_list.Managed(usize).init(allocator);
    defer ours_map.deinit();
    var theirs_map2 = std.array_list.Managed(usize).init(allocator);
    defer theirs_map2.deinit();

    {
        var oi: usize = 0;
        for (anchors.items) |bi| {
            while (oi < ours_lines.len) : (oi += 1) {
                if (std.mem.eql(u8, ours_lines[oi], base_lines[bi])) {
                    ours_map.append(oi) catch {};
                    oi += 1;
                    break;
                }
            }
        }
    }
    {
        var ti: usize = 0;
        for (anchors.items) |bi| {
            while (ti < theirs_lines.len) : (ti += 1) {
                if (std.mem.eql(u8, theirs_lines[ti], base_lines[bi])) {
                    theirs_map2.append(ti) catch {};
                    ti += 1;
                    break;
                }
            }
        }
    }

    if (ours_map.items.len != anchors.items.len or theirs_map2.items.len != anchors.items.len)
        return null;

    var result = std.array_list.Managed(u8).init(allocator);
    const ac = anchors.items.len;
    var prev_base: usize = 0;
    var prev_ours: usize = 0;
    var prev_theirs: usize = 0;

    var i: usize = 0;
    while (i <= ac) : (i += 1) {
        const cur_base = if (i < ac) anchors.items[i] else base_lines.len;
        const cur_ours = if (i < ac) ours_map.items[i] else ours_lines.len;
        const cur_theirs = if (i < ac) theirs_map2.items[i] else theirs_lines.len;

        const bg = base_lines[prev_base..cur_base];
        const og = ours_lines[prev_ours..cur_ours];
        const tg = theirs_lines[prev_theirs..cur_theirs];

        if (slicesEqual(bg, og) and slicesEqual(bg, tg)) {
            for (bg) |line| {
                result.appendSlice(line) catch {};
                result.append('\n') catch {};
            }
        } else if (slicesEqual(bg, og)) {
            for (tg) |line| {
                result.appendSlice(line) catch {};
                result.append('\n') catch {};
            }
        } else if (slicesEqual(bg, tg)) {
            for (og) |line| {
                result.appendSlice(line) catch {};
                result.append('\n') catch {};
            }
        } else if (slicesEqual(og, tg)) {
            for (og) |line| {
                result.appendSlice(line) catch {};
                result.append('\n') catch {};
            }
        } else {
            result.deinit();
            return null; // Conflict
        }

        if (i < ac) {
            result.appendSlice(base_lines[anchors.items[i]]) catch {};
            result.append('\n') catch {};
            prev_base = anchors.items[i] + 1;
            prev_ours = cur_ours + 1;
            prev_theirs = cur_theirs + 1;
        }
    }

    return result.toOwnedSlice() catch null;
}

fn slicesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn splitLines2(text: []const u8, allocator: Allocator) ?[][]const u8 {
    if (text.len == 0) return allocator.alloc([]const u8, 0) catch null;
    var lines = std.array_list.Managed([]const u8).init(allocator);
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        if (line.len == 0 and iter.peek() == null) break;
        lines.append(line) catch {};
    }
    return lines.toOwnedSlice() catch null;
}

fn computeLCS(a: []const []const u8, b: []const []const u8, allocator: Allocator) ?[]usize {
    const m = a.len;
    const n = b.len;
    if (m == 0 or n == 0) return allocator.alloc(usize, 0) catch null;

    if (m * n > 1000000) {
        // Greedy LCS for large inputs
        var res = std.array_list.Managed(usize).init(allocator);
        var bj: usize = 0;
        for (0..m) |ai| {
            while (bj < n) : (bj += 1) {
                if (std.mem.eql(u8, a[ai], b[bj])) {
                    res.append(ai) catch {};
                    bj += 1;
                    break;
                }
            }
        }
        return res.toOwnedSlice() catch null;
    }

    const dp = allocator.alloc([]u16, m + 1) catch return null;
    defer {
        for (dp) |row| allocator.free(row);
        allocator.free(dp);
    }
    for (dp) |*row| {
        row.* = allocator.alloc(u16, n + 1) catch return null;
        @memset(row.*, 0);
    }

    for (1..m + 1) |ii| {
        for (1..n + 1) |jj| {
            if (std.mem.eql(u8, a[ii - 1], b[jj - 1])) {
                dp[ii][jj] = dp[ii - 1][jj - 1] + 1;
            } else {
                dp[ii][jj] = @max(dp[ii - 1][jj], dp[ii][jj - 1]);
            }
        }
    }

    var res = std.array_list.Managed(usize).init(allocator);
    var ii: usize = m;
    var jj: usize = n;
    while (ii > 0 and jj > 0) {
        if (std.mem.eql(u8, a[ii - 1], b[jj - 1])) {
            res.append(ii - 1) catch {};
            ii -= 1;
            jj -= 1;
        } else if (dp[ii - 1][jj] >= dp[ii][jj - 1]) {
            ii -= 1;
        } else {
            jj -= 1;
        }
    }
    std.mem.reverse(usize, res.items);
    return res.toOwnedSlice() catch null;
}

// ============================================================
// Write tree from index (simplified)
// ============================================================

fn writeTreeFromIndex(allocator: Allocator, idx: *index_mod.Index, git_dir: []const u8, platform_impl: *const pm.Platform) ![]u8 {
    // Build tree entries from index
    var entries = std.array_list.Managed(objects.TreeEntry).init(allocator);
    defer {
        for (entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.hash);
        }
        entries.deinit();
    }

    // Group by directory for nested trees
    var dirs = std.StringHashMap(std.array_list.Managed(index_mod.IndexEntry)).init(allocator);
    defer {
        var it = dirs.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit();
            allocator.free(e.key_ptr.*);
        }
        dirs.deinit();
    }

    for (idx.entries.items) |entry| {
        if (std.fs.path.dirname(entry.path)) |dir| {
            // Get top-level directory
            const slash = std.mem.indexOf(u8, entry.path, "/");
            if (slash) |s| {
                const top_dir = entry.path[0..s];
                const gop = dirs.getOrPut(allocator.dupe(u8, top_dir) catch continue) catch continue;
                if (!gop.found_existing) {
                    gop.value_ptr.* = std.array_list.Managed(index_mod.IndexEntry).init(allocator);
                }
                gop.value_ptr.append(entry) catch {};
                _ = dir;
            } else {
                // Top-level file
                var hash_hex: [40]u8 = undefined;
                for (entry.sha1, 0..) |b, bi| {
                    hash_hex[bi * 2] = "0123456789abcdef"[b >> 4];
                    hash_hex[bi * 2 + 1] = "0123456789abcdef"[b & 0xf];
                }
                entries.append(.{
                    .mode = "100644",
                    .name = allocator.dupe(u8, entry.path) catch continue,
                    .hash = allocator.dupe(u8, &hash_hex) catch continue,
                }) catch {};
            }
        } else {
            // Top-level file
            var hash_hex: [40]u8 = undefined;
            for (entry.sha1, 0..) |b, bi| {
                hash_hex[bi * 2] = "0123456789abcdef"[b >> 4];
                hash_hex[bi * 2 + 1] = "0123456789abcdef"[b & 0xf];
            }
            entries.append(.{
                .mode = "100644",
                .name = allocator.dupe(u8, entry.path) catch continue,
                .hash = allocator.dupe(u8, &hash_hex) catch continue,
            }) catch {};
        }
    }

    // For directories, recursively create sub-trees
    var dir_it = dirs.iterator();
    while (dir_it.next()) |de| {
        const dir_name = de.key_ptr.*;
        const dir_entries = de.value_ptr.*;

        // Build sub-index with relative paths
        var sub_idx = index_mod.Index.init(allocator);
        defer sub_idx.deinit();

        for (dir_entries.items) |ie| {
            const slash_pos = std.mem.indexOf(u8, ie.path, "/") orelse continue;
            const rel_path = ie.path[slash_pos + 1 ..];
            var new_entry = ie;
            new_entry.path = allocator.dupe(u8, rel_path) catch continue;
            sub_idx.entries.append(new_entry) catch {};
        }

        const sub_tree_hash = writeTreeFromIndex(allocator, &sub_idx, git_dir, platform_impl) catch continue;
        // Don't free sub_idx paths since they point to duped strings
        for (sub_idx.entries.items) |se| allocator.free(se.path);

        entries.append(.{
            .mode = "40000",
            .name = allocator.dupe(u8, dir_name) catch {
                allocator.free(sub_tree_hash);
                continue;
            },
            .hash = sub_tree_hash,
        }) catch {
            allocator.free(sub_tree_hash);
        };
    }

    const tree_obj = try objects.createTreeObject(entries.items, allocator);
    defer tree_obj.deinit(allocator);

    return tree_obj.store(git_dir, platform_impl, allocator);
}

// ============================================================
// Author/Committer helpers
// ============================================================

fn getAuthorString(allocator: Allocator) ![]u8 {
    const name = std.process.getEnvVarOwned(allocator, "GIT_AUTHOR_NAME") catch
        std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_NAME") catch
        try allocator.dupe(u8, "Author");
    defer allocator.free(name);

    const email = std.process.getEnvVarOwned(allocator, "GIT_AUTHOR_EMAIL") catch
        std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_EMAIL") catch
        try allocator.dupe(u8, "author@example.com");
    defer allocator.free(email);

    const date = std.process.getEnvVarOwned(allocator, "GIT_AUTHOR_DATE") catch null;
    defer if (date) |d| allocator.free(d);

    if (date) |d| {
        // Check if it's an epoch format or @epoch format
        const ts_str = if (std.mem.startsWith(u8, d, "@")) d[1..] else d;
        return std.fmt.allocPrint(allocator, "{s} <{s}> {s}", .{ name, email, ts_str });
    }

    const ts = std.time.timestamp();
    return std.fmt.allocPrint(allocator, "{s} <{s}> {d} +0000", .{ name, email, ts });
}

fn getCommitterString(allocator: Allocator) ![]u8 {
    const name = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_NAME") catch
        try allocator.dupe(u8, "Committer");
    defer allocator.free(name);

    const email = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_EMAIL") catch
        try allocator.dupe(u8, "committer@example.com");
    defer allocator.free(email);

    const date = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_DATE") catch null;
    defer if (date) |d| allocator.free(d);

    if (date) |d| {
        const ts_str = if (std.mem.startsWith(u8, d, "@")) d[1..] else d;
        return std.fmt.allocPrint(allocator, "{s} <{s}> {s}", .{ name, email, ts_str });
    }

    const ts = std.time.timestamp();
    return std.fmt.allocPrint(allocator, "{s} <{s}> {d} +0000", .{ name, email, ts });
}
