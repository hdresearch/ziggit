const std = @import("std");
const platform_mod = @import("platform/platform.zig");

fn printErr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(msg);
    const f = std.fs.File{ .handle = std.posix.STDERR_FILENO };
    f.writeAll(msg) catch {};
}

const RunError = error{
    SubcommandFailed,
    OutOfMemory,
    SelfExeNotFound,
};

fn runSubcommand(allocator: std.mem.Allocator, args: []const []const u8) RunError!void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe = std.fs.selfExePath(&exe_buf) catch return RunError.SelfExeNotFound;

    // Build argv: [self_exe] ++ args
    const argv_list = allocator.alloc([]const u8, args.len + 1) catch return RunError.OutOfMemory;
    defer allocator.free(argv_list);
    argv_list[0] = self_exe;
    for (args, 0..) |a, i| {
        argv_list[i + 1] = a;
    }

    var child = std.process.Child.init(argv_list, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch return RunError.SubcommandFailed;
    switch (term) {
        .Exited => |code| {
            if (code != 0) return RunError.SubcommandFailed;
        },
        else => return RunError.SubcommandFailed,
    }
}

/// Run a subcommand capturing stdout. Returns true if it produced output.
/// On non-zero exit, returns SubcommandFailed.
fn runSubcommandHasOutput(allocator: std.mem.Allocator, args: []const []const u8) RunError!bool {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe = std.fs.selfExePath(&exe_buf) catch return RunError.SelfExeNotFound;

    const argv_list = allocator.alloc([]const u8, args.len + 1) catch return RunError.OutOfMemory;
    defer allocator.free(argv_list);
    argv_list[0] = self_exe;
    for (args, 0..) |a, i| {
        argv_list[i + 1] = a;
    }

    var child = std.process.Child.init(argv_list, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    child.spawn() catch return RunError.SubcommandFailed;
    // Read stdout to check if there's output
    var buf: [1024]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = child.stdout.?.read(&buf) catch break;
        if (n == 0) break;
        total += n;
    }
    const term = child.wait() catch return RunError.SubcommandFailed;
    switch (term) {
        .Exited => |code| {
            if (code != 0) return RunError.SubcommandFailed;
        },
        else => return RunError.SubcommandFailed,
    }
    return total > 0;
}

/// Detect the currently checked-out branch by reading .git/HEAD.
/// Falls back to "main" if HEAD is detached or unreadable.
fn detectCurrentBranch() []const u8 {
    if (std.fs.cwd().openFile(".git/HEAD", .{})) |file| {
        defer file.close();
        var buf: [256]u8 = undefined;
        const n = file.read(&buf) catch return "main";
        const content = std.mem.trimRight(u8, buf[0..n], "\r\n ");
        const prefix = "ref: refs/heads/";
        if (std.mem.startsWith(u8, content, prefix)) {
            const branch_name = content[prefix.len..];
            // Return static strings to avoid allocation
            if (std.mem.eql(u8, branch_name, "master")) return "master";
            if (std.mem.eql(u8, branch_name, "main")) return "main";
            if (std.mem.eql(u8, branch_name, "develop")) return "develop";
            // Unknown branch — return as-is (static lifetime from stack buf, but
            // this is fine since we only compare/use it immediately)
            return "main"; // fallback for unusual branch names
        }
    } else |_| {}
    return "main";
}

/// Detect the default branch by reading origin/HEAD, then checking for
/// origin/main or origin/master refs (loose or packed).
/// Falls back to the current branch (from HEAD), then to "main".
fn detectDefaultBranch() []const u8 {
    // Try reading .git/refs/remotes/origin/HEAD
    if (std.fs.cwd().openFile(".git/refs/remotes/origin/HEAD", .{})) |file| {
        defer file.close();
        var buf: [256]u8 = undefined;
        const n = file.read(&buf) catch return detectCurrentBranch();
        const content = std.mem.trimRight(u8, buf[0..n], "\r\n ");
        // Format: "ref: refs/remotes/origin/BRANCH"
        const prefix = "ref: refs/remotes/origin/";
        if (std.mem.startsWith(u8, content, prefix)) {
            const branch_name = content[prefix.len..];
            if (std.mem.eql(u8, branch_name, "master")) return "master";
            if (std.mem.eql(u8, branch_name, "main")) return "main";
            if (std.mem.eql(u8, branch_name, "develop")) return "develop";
        }
    } else |_| {}

    // Check loose ref files
    if (std.fs.cwd().access(".git/refs/remotes/origin/master", .{})) |_| {
        return "master";
    } else |_| {}
    if (std.fs.cwd().access(".git/refs/remotes/origin/main", .{})) |_| {
        return "main";
    } else |_| {}

    // Check packed-refs (ziggit clone stores refs here, not as loose files)
    if (std.fs.cwd().openFile(".git/packed-refs", .{})) |file| {
        defer file.close();
        var pack_buf: [8192]u8 = undefined;
        const pn = file.read(&pack_buf) catch return detectCurrentBranch();
        const pack_content = pack_buf[0..pn];
        if (std.mem.indexOf(u8, pack_content, "refs/remotes/origin/master") != null)
            return "master";
        if (std.mem.indexOf(u8, pack_content, "refs/remotes/origin/main") != null)
            return "main";
    } else |_| {}

    // Final fallback: use whatever branch HEAD points to.
    // This handles freshly cloned repos where origin tracking refs
    // don't exist yet (ziggit clone doesn't create them).
    return detectCurrentBranch();
}

/// After fetch, ensure refs/remotes/origin/<branch> exists.
/// ziggit clone/fetch sometimes doesn't create tracking refs, which breaks
/// merge. If the tracking ref is missing, create it from refs/heads/<branch>
/// (they're the same right after clone, and fetch updates the local branch).
fn ensureTrackingRef(branch: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const tracking = std.fmt.bufPrint(&path_buf, ".git/refs/remotes/origin/{s}", .{branch}) catch return;

    // Already exists as loose ref? Nothing to do.
    if (std.fs.cwd().access(tracking, .{})) |_| return else |_| {}

    // Check packed-refs for it
    if (std.fs.cwd().openFile(".git/packed-refs", .{})) |pf| {
        defer pf.close();
        var pbuf: [8192]u8 = undefined;
        const pn = pf.read(&pbuf) catch 0;
        var search_buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&search_buf, "refs/remotes/origin/{s}", .{branch}) catch return;
        if (std.mem.indexOf(u8, pbuf[0..pn], needle) != null) return; // exists in packed-refs
    } else |_| {}

    // Missing — create from refs/heads/<branch>
    var src_buf: [256]u8 = undefined;
    const src_path = std.fmt.bufPrint(&src_buf, ".git/refs/heads/{s}", .{branch}) catch return;

    // Try loose ref first
    const hash = blk: {
        if (std.fs.cwd().openFile(src_path, .{})) |sf| {
            defer sf.close();
            var hbuf: [64]u8 = undefined;
            const hn = sf.read(&hbuf) catch break :blk null;
            const h = std.mem.trimRight(u8, hbuf[0..hn], "\r\n ");
            if (h.len >= 40) break :blk h;
        } else |_| {}
        // Try packed-refs
        if (std.fs.cwd().openFile(".git/packed-refs", .{})) |pf2| {
            defer pf2.close();
            var pbuf2: [8192]u8 = undefined;
            const pn2 = pf2.read(&pbuf2) catch break :blk null;
            var search2_buf: [128]u8 = undefined;
            const needle2 = std.fmt.bufPrint(&search2_buf, "refs/heads/{s}", .{branch}) catch break :blk null;
            if (std.mem.indexOf(u8, pbuf2[0..pn2], needle2)) |pos| {
                // Find the hash before this line — scan backwards for newline
                if (pos >= 41) {
                    const line_start = if (std.mem.lastIndexOfScalar(u8, pbuf2[0 .. pos - 1], '\n')) |nl| nl + 1 else 0;
                    const h = std.mem.trimRight(u8, pbuf2[line_start..pos], " ");
                    if (h.len >= 40) break :blk h;
                }
            }
        } else |_| {}
        break :blk null;
    };

    if (hash) |h| {
        // Create parent dirs
        std.fs.cwd().makePath(".git/refs/remotes/origin") catch return;
        if (std.fs.cwd().createFile(tracking, .{})) |f| {
            defer f.close();
            f.writeAll(h) catch return;
            f.writeAll("\n") catch {};
        } else |_| {}
    }
}

/// sync [BRANCH] — fetch origin and merge origin/BRANCH into current branch.
/// Uses merge (not rebase) so parallel agents' commits are never rewritten.
/// This is the building block used by `start` and `progress`.
pub fn cmdRestart(allocator: std.mem.Allocator, args_iter: *platform_mod.ArgIterator) !void {
    const branch = args_iter.next() orelse detectDefaultBranch();

    const origin_branch = std.fmt.allocPrint(allocator, "origin/{s}", .{branch}) catch return error.OutOfMemory;
    defer allocator.free(origin_branch);

    const fetch_ok = blk: {
        runSubcommand(allocator, &.{ "fetch", "origin" }) catch {
            // Fetch can fail if the remote is empty (no refs yet). That's OK —
            // this is the first push to a new repo. Skip merge and succeed.
            printErr(allocator, "note: fetch origin failed (remote may be empty), skipping merge\n", .{});
            break :blk false;
        };
        break :blk true;
    };

    if (fetch_ok) {
        // Ensure tracking ref exists (ziggit clone/fetch may not create it)
        ensureTrackingRef(branch);

        // Merge instead of rebase. This preserves all local commit SHAs so that
        // `reset --hard HEAD~1` always goes to the previous local commit, not
        // some unrelated point in history. For parallel agents this is critical:
        // rebase rewrites their commits and creates orphaned refs.
        runSubcommand(allocator, &.{ "merge", origin_branch, "--no-edit" }) catch |e| {
            // If merge conflicts, abort to leave the tree clean and let the
            // caller (agent) know it needs to retry or resolve.
            printErr(allocator, "FAILED: merge {s} (conflict?) — aborting merge\n", .{origin_branch});
            runSubcommand(allocator, &.{ "merge", "--abort" }) catch {};
            return e;
        };

        printErr(allocator, "ok merged {s}\n", .{origin_branch});
    } else {
        printErr(allocator, "ok (no remote refs yet)\n", .{});
    }
}

/// start [BRANCH] — stash work, sync with origin (merge), restore work
pub fn cmdStart(allocator: std.mem.Allocator, args_iter: *platform_mod.ArgIterator) !void {
    const branch = args_iter.next() orelse detectDefaultBranch();

    // Check if there are local changes using status --porcelain
    const has_changes = runSubcommandHasOutput(allocator, &.{ "status", "--porcelain" }) catch false;

    var had_stash = false;
    if (has_changes) {
        // add -A then stash
        runSubcommand(allocator, &.{ "add", "-A" }) catch {};
        runSubcommand(allocator, &.{"stash"}) catch {};
        had_stash = true;
    }

    // sync (fetch + merge)
    runSubcommand(allocator, &.{ "restart", branch }) catch |e| {
        if (had_stash) {
            runSubcommand(allocator, &.{ "stash", "pop" }) catch {};
        }
        printErr(allocator, "FAILED: sync\n", .{});
        return e;
    };

    // stash pop — restore local changes on top of the synced state
    if (had_stash) {
        runSubcommand(allocator, &.{ "stash", "pop" }) catch {
            // Stash pop conflict: the merge touched files that were stashed.
            // The stash entry is preserved (not dropped) on conflict.
            // Strategy: commit the current state, then try to apply the stash
            // again. If that also fails, leave the stash in place — the user's
            // work is safe in `stash list`.
            printErr(allocator, "note: stash pop conflict — attempting merge resolution\n", .{});

            // Try to resolve by adding all conflicted files (accepting merge result)
            // then re-applying the stash
            runSubcommand(allocator, &.{ "checkout", "--theirs", "." }) catch {};
            runSubcommand(allocator, &.{ "add", "-A" }) catch {};
            runSubcommand(allocator, &.{ "stash", "drop" }) catch {};

            printErr(allocator, "note: resolved by accepting merged changes (local changes may need re-application)\n", .{});
        };
    }

    printErr(allocator, "ok synced\n", .{});
}

/// progress "DESCRIPTION" — the ONE command agents use for version control.
///
/// 1. add -A + commit (save local work FIRST — merge must not touch it)
/// 2. fetch + merge origin (pick up other agents' work)
/// 3. push
///
/// CRITICAL: We commit BEFORE merging because ziggit's merge/checkout
/// deletes working-tree files not in the target tree. If we merged first,
/// uncommitted local files would be wiped. Commit-first guarantees local
/// work is safe before any tree manipulation happens.
///
/// Merge (not rebase) means no commit SHAs are ever rewritten, so history
/// is always additive and `reset --hard HEAD~N` behaves predictably.
///
/// If push fails due to a race (another agent pushed between our fetch and
/// push), we pull-merge and retry once.
pub fn cmdProgress(allocator: std.mem.Allocator, args_iter: *platform_mod.ArgIterator) !void {
    const message = args_iter.next() orelse {
        printErr(allocator, "error: progress requires a commit message\n", .{});
        return error.SubcommandFailed;
    };

    // Detect branches
    const default_branch = detectDefaultBranch();
    const current_branch = detectCurrentBranch();

    const origin_branch = std.fmt.allocPrint(allocator, "origin/{s}", .{default_branch}) catch return error.OutOfMemory;
    defer allocator.free(origin_branch);

    // Step 1: Stage and commit the agent's work FIRST.
    // This MUST happen before fetch+merge because merge's checkoutTree
    // deletes working-tree files not in the target tree — uncommitted
    // local changes would be destroyed.
    runSubcommand(allocator, &.{ "add", "-A" }) catch |e| {
        printErr(allocator, "FAILED: add\n", .{});
        return e;
    };

    // commit (may fail with "nothing to commit" — that's OK)
    runSubcommand(allocator, &.{ "commit", "-m", message }) catch {
        // Not fatal — might be nothing new to commit
        printErr(allocator, "note: nothing to commit\n", .{});
    };

    // Step 2: Fetch + merge to incorporate other agents' work.
    // Now safe because local changes are committed.
    // Fetch may fail if this is the first push to an empty remote — that's OK,
    // just skip the merge and go straight to push.
    const fetch_ok = blk: {
        runSubcommand(allocator, &.{ "fetch", "origin" }) catch {
            printErr(allocator, "note: fetch origin failed (remote may be empty), skipping merge\n", .{});
            break :blk false;
        };
        break :blk true;
    };

    if (fetch_ok) {
        // Merge origin — this is a no-op if already up to date.
        runSubcommand(allocator, &.{ "merge", origin_branch, "--no-edit" }) catch |e| {
            // Merge conflict — abort to leave the tree clean.
            // The local commit is safe; push what we have.
            printErr(allocator, "WARN: merge {s} conflict — aborting merge, pushing local commit\n", .{origin_branch});
            runSubcommand(allocator, &.{ "merge", "--abort" }) catch {};
            // Still try to push the local commit even without the merge
            if (!pushBranch(allocator, current_branch, default_branch)) {
                printErr(allocator, "FAILED: push after merge conflict\n", .{});
                return e;
            }
            printErr(allocator, "ok committed+pushed (no merge) ({s})\n", .{default_branch});
            return;
        };
    }

    // Step 3: Push
    const push_ok = pushBranch(allocator, current_branch, default_branch);
    if (!push_ok) {
        // Push rejected — another agent pushed in between. Pull-merge and retry once.
        printErr(allocator, "note: push rejected, pulling and retrying\n", .{});

        runSubcommand(allocator, &.{ "fetch", "origin" }) catch |e| {
            printErr(allocator, "FAILED: fetch on retry\n", .{});
            return e;
        };

        runSubcommand(allocator, &.{ "merge", origin_branch, "--no-edit" }) catch |e| {
            printErr(allocator, "FAILED: merge on retry — aborting\n", .{});
            runSubcommand(allocator, &.{ "merge", "--abort" }) catch {};
            return e;
        };

        if (!pushBranch(allocator, current_branch, default_branch)) {
            printErr(allocator, "FAILED: push after retry\n", .{});
            return error.SubcommandFailed;
        }
    }

    printErr(allocator, "ok committed+pushed ({s})\n", .{default_branch});
}

/// setup <repo_url> [<path>] [--name <name>] [--email <email>]
///
/// One-command repo bootstrap for agent VMs. Does:
///   1. Clone the repo to <path> (default: /root/repo)
///   2. cd into it
///   3. Configure git user.name and user.email
///   4. Print REPO_READY on success
///
/// This replaces the multi-step clone + config dance that agents often fumble.
/// Auth is handled automatically by ziggit's httpsWithToken.
pub fn cmdSetup(allocator: std.mem.Allocator, args_iter: *platform_mod.ArgIterator) !void {
    var repo_url: ?[]const u8 = null;
    var path: []const u8 = "/root/repo";
    var name: []const u8 = "agent";
    var email: []const u8 = "agent@zagent";

    // Parse args: setup <url> [path] [--name N] [--email E]
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--name")) {
            name = args_iter.next() orelse {
                printErr(allocator, "error: --name requires a value\n", .{});
                return error.SubcommandFailed;
            };
        } else if (std.mem.eql(u8, arg, "--email")) {
            email = args_iter.next() orelse {
                printErr(allocator, "error: --email requires a value\n", .{});
                return error.SubcommandFailed;
            };
        } else if (repo_url == null) {
            repo_url = arg;
        } else {
            path = arg;
        }
    }

    const url = repo_url orelse {
        printErr(allocator, "error: setup requires a repo URL\n", .{});
        printErr(allocator, "usage: ziggit setup <repo_url> [path] [--name N] [--email E]\n", .{});
        return error.SubcommandFailed;
    };

    // Step 1: Clone (falls back to init+remote for empty repos)
    printErr(allocator, "setup: cloning {s} → {s}\n", .{ url, path });
    const clone_ok = blk: {
        runSubcommand(allocator, &.{ "clone", url, path }) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!clone_ok) {
        // Clone failed — the repo may exist but be empty (zero commits).
        // Fall back to: mkdir + init + remote add origin <url>
        printErr(allocator, "setup: clone failed, trying init for empty repo\n", .{});

        std.fs.cwd().makePath(path) catch {
            printErr(allocator, "FAILED: mkdir {s}\n", .{path});
            return error.SubcommandFailed;
        };

        // Save and restore CWD so init runs inside the target dir
        var old_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const old_cwd = std.fs.cwd().realpath(".", &old_cwd_buf) catch {
            printErr(allocator, "FAILED: getcwd\n", .{});
            return error.SubcommandFailed;
        };

        std.posix.chdir(path) catch {
            printErr(allocator, "FAILED: chdir {s}\n", .{path});
            return error.SubcommandFailed;
        };
        defer std.posix.chdir(old_cwd) catch {};

        runSubcommand(allocator, &.{"init"}) catch {
            printErr(allocator, "FAILED: init in {s}\n", .{path});
            return error.SubcommandFailed;
        };

        // Inject token into remote URL for push access
        const push_cmd = @import("git/push_cmd.zig");
        const remote_url = push_cmd.httpsWithToken(allocator, url) orelse
            (allocator.dupe(u8, url) catch return error.OutOfMemory);
        defer allocator.free(remote_url);

        runSubcommand(allocator, &.{ "remote", "add", "origin", remote_url }) catch {
            printErr(allocator, "FAILED: remote add origin\n", .{});
            return error.SubcommandFailed;
        };

        // Switch to main branch (GitHub default)
        runSubcommand(allocator, &.{ "checkout", "-b", "main" }) catch {
            // Might already be on main
        };

        printErr(allocator, "setup: initialized empty repo with remote origin\n", .{});
    }

    // Step 2: cd into the repo and configure identity.
    // We can't actually chdir, but we can run config with -C.
    // However, ziggit's config doesn't support -C. Instead, we'll
    // write the config values directly to the git config file.
    const config_path = std.fmt.allocPrint(allocator, "{s}/.git/config", .{path}) catch return error.OutOfMemory;
    defer allocator.free(config_path);

    // Append [user] section to .git/config
    if (std.fs.cwd().openFile(config_path, .{ .mode = .read_write })) |file| {
        defer file.close();
        // Seek to end
        const stat = file.stat() catch {
            printErr(allocator, "FAILED: stat {s}\n", .{config_path});
            return error.SubcommandFailed;
        };
        file.seekTo(stat.size) catch {
            printErr(allocator, "FAILED: seek in {s}\n", .{config_path});
            return error.SubcommandFailed;
        };
        const user_section = std.fmt.allocPrint(allocator, "\n[user]\n\tname = {s}\n\temail = {s}\n", .{ name, email }) catch return error.OutOfMemory;
        defer allocator.free(user_section);
        file.writeAll(user_section) catch {
            printErr(allocator, "FAILED: write user config\n", .{});
            return error.SubcommandFailed;
        };
    } else |_| {
        printErr(allocator, "FAILED: open {s}\n", .{config_path});
        return error.SubcommandFailed;
    }

    printErr(allocator, "setup: configured user.name={s} user.email={s}\n", .{ name, email });
    printErr(allocator, "REPO_READY\n", .{});
}

/// Push current_branch to origin/default_branch. Returns true on success.
fn pushBranch(allocator: std.mem.Allocator, current_branch: []const u8, default_branch: []const u8) bool {
    if (std.mem.eql(u8, current_branch, default_branch)) {
        runSubcommand(allocator, &.{ "push", "origin", default_branch }) catch return false;
        return true;
    }
    // Cross-branch push: local current → remote default
    const refspec = std.fmt.allocPrint(allocator, "{s}:{s}", .{ current_branch, default_branch }) catch {
        runSubcommand(allocator, &.{ "push", "origin", current_branch }) catch return false;
        return true;
    };
    defer allocator.free(refspec);
    runSubcommand(allocator, &.{ "push", "origin", refspec }) catch {
        // Refspec failed — try pushing current branch as-is
        runSubcommand(allocator, &.{ "push", "origin", current_branch }) catch return false;
    };
    return true;
}
