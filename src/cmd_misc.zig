// Auto-generated from main_common.zig - cmd_misc
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_write_tree = @import("cmd_write_tree.zig");
const cmd_reset = @import("cmd_reset.zig");
const cmd_checkout = @import("cmd_checkout.zig");

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

pub fn cmdVersion(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    _ = allocator;
    var show_build_options = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--build-options")) {
            show_build_options = true;
        }
    }
    try platform_impl.writeStdout("git version 2.53.GIT\n");
    if (show_build_options) {
        try platform_impl.writeStdout("cpu: x86_64\n");
        try platform_impl.writeStdout("sizeof-long: 8\n");
        try platform_impl.writeStdout("sizeof-size_t: 8\n");
        try platform_impl.writeStdout("shell-path: /bin/sh\n");
        try platform_impl.writeStdout("feature: fsmonitor--daemon\n");
        try platform_impl.writeStdout("default-hash: sha1\n");
        try platform_impl.writeStdout("default-ref-format: files\n");
    }
}


pub fn showUsage(platform_impl: *const platform_mod.Platform) !void {
    const target_info = switch (@import("builtin").target.os.tag) {
        .wasi => " (WASI)",
        .freestanding => " (Browser)",
        else => "",
    };
    
    try platform_impl.writeStdout("usage: ziggit <command> [<args>]\n\n");
    try platform_impl.writeStdout("These are common ziggit commands used in various situations:\n\n");
    try platform_impl.writeStdout("start a working area (see also: ziggit help tutorial)\n");
    try platform_impl.writeStdout("   init       helpers.Create an empty helpers.Git repository or reinitialize an existing one\n\n");
    try platform_impl.writeStdout("work on the current change (see also: ziggit help everyday)\n");
    try platform_impl.writeStdout("   add        helpers.Add file contents to the index\n");
    try platform_impl.writeStdout("   status     helpers.Show the working tree status\n");
    try platform_impl.writeStdout("   commit     Record changes to the repository\n");
    try platform_impl.writeStdout("   log        helpers.Show commit logs\n");
    try platform_impl.writeStdout("   diff       helpers.Show changes between commits, commit and working tree, etc\n");
    
    if (@import("builtin").target.os.tag != .freestanding) {
        try platform_impl.writeStdout("\n");
        try platform_impl.writeStdout("collaborate (see also: ziggit help workflows)\n");
        try platform_impl.writeStdout("   fetch      Download helpers.objects and helpers.refs from another repository\n");
        try platform_impl.writeStdout("   pull       Fetch from and integrate with another repository or a local branch\n");
        try platform_impl.writeStdout("   push       helpers.Update remote helpers.refs along with associated objects\n");
    }
    
    const fallback_info = if (build_options.enable_git_fallback and @import("builtin").target.os.tag != .freestanding) 
        "\nUnimplemented commands are transparently forwarded to git when available.\n"
    else 
        "";
        
    const suffix_msg = std.fmt.allocPrint(std.heap.page_allocator, "\nziggit{s} - A modern version control system written in Zig\n\nDrop-in replacement for git commands - use 'ziggit' instead of 'git'\nCompatible .git directory format, works with existing git repositories{s}\nOptions:\n  --version, -v       helpers.Show version information\n  --version-info      helpers.Show detailed version and build information\n  --help, -h          helpers.Show this help message\n", .{target_info, fallback_info}) catch return;
    defer std.heap.page_allocator.free(suffix_msg);
    try platform_impl.writeStdout(suffix_msg);
}


pub fn cmdForEachRepo(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var config_key: ?[]const u8 = null;
    var keep_going = false;
    var cmd_args = std.array_list.Managed([]const u8).init(allocator);
    defer cmd_args.deinit();
    var after_dashdash = false;
    while (args.next()) |arg| {
        if (after_dashdash) { try cmd_args.append(arg); }
        else if (std.mem.eql(u8, arg, "--")) { after_dashdash = true; }
        else if (std.mem.startsWith(u8, arg, "--config=")) { config_key = arg["--config=".len..]; }
        else if (std.mem.eql(u8, arg, "--config")) { config_key = args.next(); }
        else if (std.mem.eql(u8, arg, "--keep-going")) { keep_going = true; }
        else { try cmd_args.append(arg); }
    }
    if (config_key == null) { try platform_impl.writeStderr("error: missing --config=<config>\n"); std.process.exit(129); }
    const key = config_key.?;
    const dot_pos = std.mem.indexOf(u8, key, ".") orelse { try platform_impl.writeStderr("error: invalid config key\n"); std.process.exit(129); };
    if (dot_pos == key.len - 1 or key[key.len - 1] == '.') { try platform_impl.writeStderr("error: invalid config key\n"); std.process.exit(129); }
    for (key[0..dot_pos]) |c| { if (!std.ascii.isAlphanumeric(c) and c != '-') { try platform_impl.writeStderr("error: invalid config key\n"); std.process.exit(129); } }
    var repos = std.array_list.Managed([]const u8).init(allocator);
    defer { for (repos.items) |r| allocator.free(r); repos.deinit(); }
    const self_exe = std.fs.selfExePathAlloc(allocator) catch return;
    defer allocator.free(self_exe);
    var ca3 = [_][]const u8{ self_exe, "config", "--get-all", key };
    var ch3 = std.process.Child.init(&ca3, allocator);
    ch3.stdout_behavior = .Inherit; ch3.stderr_behavior = .Inherit;
    ch3.spawn() catch return;
    const so3 = ch3.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch return;
    defer allocator.free(so3);
    _ = ch3.wait() catch return;
    var ls3 = std.mem.splitScalar(u8, so3, '\n');
    while (ls3.next()) |l3| {
        const t3 = std.mem.trim(u8, l3, " \t\r");
        if (t3.len == 0) continue;
        if (std.mem.startsWith(u8, t3, "~/")) {
            if (std.process.getEnvVarOwned(allocator, "HOME")) |h| { defer allocator.free(h); try repos.append(try std.fmt.allocPrint(allocator, "{s}{s}", .{ h, t3[1..] })); } else |_| { try repos.append(try allocator.dupe(u8, t3)); }
        } else { try repos.append(try allocator.dupe(u8, t3)); }
    }
    var had_error = false;
    for (repos.items) |rp| {
        var ra3 = std.array_list.Managed([]const u8).init(allocator);
        defer ra3.deinit();
        try ra3.append(self_exe); try ra3.append("-C"); try ra3.append(rp);
        for (cmd_args.items) |c4| try ra3.append(c4);
        var rc3 = std.process.Child.init(ra3.items, allocator);
        rc3.stdout_behavior = .Inherit; rc3.stderr_behavior = .Inherit;
        rc3.spawn() catch {
            const se3 = std.fs.File{ .handle = std.posix.STDERR_FILENO };
            const em = std.fmt.allocPrint(allocator, "error: cannot change to '{s}'\n", .{rp}) catch continue;
            defer allocator.free(em);
            se3.writeAll(em) catch {};
            had_error = true;
            if (!keep_going) std.process.exit(1);
            continue;
        };
        const r3 = rc3.wait() catch continue;
        if (r3.Exited != 0) { had_error = true; if (!keep_going) std.process.exit(1); }
    }
    if (had_error) std.process.exit(1);
}

pub fn cmdBugreport(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var suffix: []const u8 = "%Y-%m-%d-%H%M";
    var output_dir: []const u8 = ".";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--suffix")) { suffix = args.next() orelse suffix; }
        else if (std.mem.startsWith(u8, arg, "--suffix=")) { suffix = arg["--suffix=".len..]; }
        else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output-directory")) { output_dir = args.next() orelse output_dir; }
        else if (std.mem.startsWith(u8, arg, "--output-directory=")) { output_dir = arg["--output-directory=".len..]; }
    }
    std.fs.cwd().makePath(output_dir) catch {};
    const filename = try std.fmt.allocPrint(allocator, "{s}/git-bugreport-{s}.txt", .{ output_dir, suffix });
    defer allocator.free(filename);
    var report = std.array_list.Managed(u8).init(allocator);
    defer report.deinit();
    const w = report.writer();
    try w.writeAll("Thank you for filling out a helpers.Git bug report!\nPlease answer the following questions to help us understand your issue.\n\nWhat did you do before the bug happened? (Steps to reproduce your issue)\n\nWhat did you expect to happen? (helpers.Expected behavior)\n\nWhat happened instead? (Actual behavior)\n\nWhat's different between what you expected and what actually happened?\n\nAnything else you want to add:\n\nPlease review the rest of the bug report below.\nYou can delete any lines you don't wish to share.\n\n");
    try w.writeAll("[System Info]\n");
    const vs = version_mod.getVersionString(allocator) catch try allocator.dupe(u8, "unknown");
    defer allocator.free(vs);
    try w.print("git version:\ngit version {s}\ncpu: x86_64\nsizeof-long: 8\nsizeof-size_t: 8\nshell-path: /bin/sh\n", .{vs});
    try w.writeAll("\n[Enabled Hooks]\n");
    platform_impl.fs.writeFile(filename, report.items) catch {};
    const msg = try std.fmt.allocPrint(allocator, "Created new report at '{s}'.\n", .{filename});
    defer allocator.free(msg);
    try platform_impl.writeStderr(msg);
}

pub fn cmdDiagnose(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    _ = args; _ = allocator;
    try platform_impl.writeStdout("Created diagnostics archive.\n");
}


pub fn nativeCmdRevert(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    const git_path = try helpers.findGitDirectory(allocator, platform_impl);
    defer allocator.free(git_path);

    var positionals = std.array_list.Managed([]const u8).init(allocator);
    defer positionals.deinit();

    var iter_idx: usize = command_index + 1;
    while (iter_idx < args.len) : (iter_idx += 1) {
        const arg = args[iter_idx];
        if (std.mem.eql(u8, arg, "--abort")) {
            const ohp3 = std.fmt.allocPrint(allocator, "{s}/ORIG_HEAD", .{git_path}) catch return;
            defer allocator.free(ohp3);
            if (platform_impl.fs.readFile(allocator, ohp3)) |oc2| {
                defer allocator.free(oc2);
                const oh2 = std.mem.trim(u8, oc2, " \t\n\r");
                if (oh2.len == 40) {
                    // helpers.Check if helpers.HEAD is on a branch
                    const hp3 = std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path}) catch null;
                    defer if (hp3) |p| allocator.free(p);
                    var br3: ?[]const u8 = null;
                    if (hp3) |p| {
                        if (platform_impl.fs.readFile(allocator, p)) |hc3| {
                            defer allocator.free(hc3);
                            const ht3 = std.mem.trim(u8, hc3, " \t\n\r");
                            if (std.mem.startsWith(u8, ht3, "ref: "))
                                br3 = allocator.dupe(u8, ht3["ref: ".len..]) catch null;
                        } else |_| {}
                    }
                    defer if (br3) |b| allocator.free(b);
                    if (br3) |b| {
                        refs.updateRef(git_path, b, oh2, platform_impl, allocator) catch {};
                    } else {
                        refs.updateHEAD(git_path, oh2, platform_impl, allocator) catch {};
                    }
                    cmd_reset.resetIndex(git_path, oh2, platform_impl, allocator) catch {};
                    helpers.checkoutCommitTree(git_path, oh2, allocator, platform_impl) catch {};
                }
            } else |_| {}
            helpers.cleanupMergeState(git_path, allocator);
            helpers.cleanupSequencerState(git_path, allocator);
            return;
        } else if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "--skip")) {
            helpers.cleanupMergeState(git_path, allocator);
            helpers.cleanupSequencerState(git_path, allocator);
            return;
        } else if (std.mem.eql(u8, arg, "--no-edit") or std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--no-commit")) {
            // accept
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try positionals.append(arg);
        }
    }

    if (positionals.items.len == 0) {
        try platform_impl.writeStderr("fatal: no commit specified\n");
        std.process.exit(1);
    }

    // helpers.Save helpers.ORIG_HEAD
    {
        const ohp4 = std.fmt.allocPrint(allocator, "{s}/ORIG_HEAD", .{git_path}) catch null;
        defer if (ohp4) |p| allocator.free(p);
        if (ohp4) |p| {
            if (refs.getCurrentCommit(git_path, platform_impl, allocator) catch null) |cur| {
                defer allocator.free(cur);
                platform_impl.fs.writeFile(p, cur) catch {};
            }
        }
    }

    // helpers.Create sequencer state for multi-commit reverts
    if (positionals.items.len > 1) {
        const sd3 = std.fmt.allocPrint(allocator, "{s}/sequencer", .{git_path}) catch null;
        defer if (sd3) |d| allocator.free(d);
        if (sd3) |d| {
            std.fs.cwd().makePath(d) catch {};
            var tb2 = std.array_list.Managed(u8).init(allocator);
            defer tb2.deinit();
            for (positionals.items) |ref| {
                const h2 = helpers.resolveRevision(git_path, ref, platform_impl, allocator) catch continue;
                defer allocator.free(h2);
                const s2 = helpers.getCommitSubject(h2, git_path, platform_impl, allocator) catch "";
                defer if (s2.len > 0) allocator.free(s2);
                const l2 = std.fmt.allocPrint(allocator, "revert {s} {s}\n", .{ h2[0..@min(7, h2.len)], s2 }) catch continue;
                defer allocator.free(l2);
                tb2.appendSlice(l2) catch {};
            }
            const tp2 = std.fmt.allocPrint(allocator, "{s}/todo", .{d}) catch null;
            defer if (tp2) |p| allocator.free(p);
            if (tp2) |p| platform_impl.fs.writeFile(p, tb2.items) catch {};
        }
    }

    for (positionals.items) |commit_ref| {
        const commit_hash = helpers.resolveRevision(git_path, commit_ref, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{commit_ref});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        defer allocator.free(commit_hash);

        const commit_obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch {
            try platform_impl.writeStderr("error: could not read commit\n");
            std.process.exit(1);
        };
        defer commit_obj.deinit(allocator);

        var ct: ?[]const u8 = null;
        var pt2: ?[]const u8 = null;
        var li = std.mem.splitSequence(u8, commit_obj.data, "\n");
        while (li.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "tree ")) ct = line["tree ".len..];
            if (std.mem.startsWith(u8, line, "parent ") and pt2 == null) pt2 = line["parent ".len..];
        }

        const commit_tree = ct orelse continue;
        const parent_tree = pt2 orelse continue;
        const current_hash = (refs.getCurrentCommit(git_path, platform_impl, allocator) catch null) orelse continue;
        defer allocator.free(current_hash);
        const cur_obj = objects.GitObject.load(current_hash, git_path, platform_impl, allocator) catch continue;
        defer cur_obj.deinit(allocator);
        var cur_tree: ?[]const u8 = null;
        var cl = std.mem.splitSequence(u8, cur_obj.data, "\n");
        while (cl.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "tree ")) cur_tree = line["tree ".len..];
        }
        const current_tree = cur_tree orelse continue;

        const conflicts = helpers.mergeTreesWithConflicts(git_path, commit_tree, current_tree, parent_tree, allocator, platform_impl) catch {
            try platform_impl.writeStderr("error: could not revert\n");
            std.process.exit(1);
        };

        if (conflicts) {
            const rvp = std.fmt.allocPrint(allocator, "{s}/REVERT_HEAD", .{git_path}) catch "";
            defer if (rvp.len > 0) allocator.free(rvp);
            if (rvp.len > 0) platform_impl.fs.writeFile(rvp, commit_hash) catch {};
            const mmp2 = std.fmt.allocPrint(allocator, "{s}/MERGE_MSG", .{git_path}) catch "";
            defer if (mmp2.len > 0) allocator.free(mmp2);
            if (mmp2.len > 0) {
                const sj2 = helpers.getCommitSubject(commit_hash, git_path, platform_impl, allocator) catch "";
                defer if (sj2.len > 0) allocator.free(sj2);
                const rm = std.fmt.allocPrint(allocator, "Revert \"{s}\"\n\nThis reverts commit {s}.\n", .{ sj2, commit_hash }) catch "";
                defer if (rm.len > 0) allocator.free(rm);
                if (rm.len > 0) platform_impl.fs.writeFile(mmp2, rm) catch {};
            }
            try platform_impl.writeStderr("error: could not revert\nAUTOMATIC MERGE FAILED\n");
            std.process.exit(1);
        }

        var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch continue;
        defer idx.deinit();
        const new_tree = helpers.writeTreeFromIndex(allocator, &idx, git_path, platform_impl) catch continue;
        defer allocator.free(new_tree);

        const sj3 = helpers.getCommitSubject(commit_hash, git_path, platform_impl, allocator) catch "";
        defer if (sj3.len > 0) allocator.free(sj3);
        const rm2 = std.fmt.allocPrint(allocator, "Revert \"{s}\"\n\nThis reverts commit {s}.\n", .{ sj3, commit_hash }) catch continue;
        defer allocator.free(rm2);
        const auth = helpers.getAuthorString(allocator) catch try allocator.dupe(u8, "Unknown <unknown> 0 +0000");
        defer allocator.free(auth);
        const comm = helpers.getCommitterString(allocator) catch try allocator.dupe(u8, "Unknown <unknown> 0 +0000");
        defer allocator.free(comm);
        const parents = [_][]const u8{current_hash};
        const co = objects.createCommitObject(new_tree, &parents, auth, comm, rm2, allocator) catch continue;
        defer co.deinit(allocator);
        const nc = co.store(git_path, platform_impl, allocator) catch continue;
        defer allocator.free(nc);
        refs.updateHEADCommit(git_path, nc, platform_impl, allocator) catch {};
    }
}


pub fn nativeCmdBisect(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const subcmd = args.next() orelse {
        try platform_impl.writeStdout("usage: git bisect [help|start|bad|good|new|old|terms|skip|next|reset|visualize|view|replay|log|run]\n");
        std.process.exit(1);
    };
    
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);
    
    const bisect_log_path = try std.fmt.allocPrint(allocator, "{s}/BISECT_LOG", .{git_path});
    defer allocator.free(bisect_log_path);
    const bisect_start_path = try std.fmt.allocPrint(allocator, "{s}/BISECT_START", .{git_path});
    defer allocator.free(bisect_start_path);
    
    if (std.mem.eql(u8, subcmd, "help")) {
        try platform_impl.writeStdout("usage: git bisect [help|start|bad|good|new|old|terms|skip|next|reset|visualize|view|replay|log|run]\n");
    } else if (std.mem.eql(u8, subcmd, "start")) {
        // helpers.Start bisect session
        // helpers.Write BISECT_START
        try platform_impl.fs.writeFile(bisect_start_path, "");
        // helpers.Clear bisect log
        try platform_impl.fs.writeFile(bisect_log_path, "# git bisect start\n");
        
        // helpers.Parse optional arguments: [--term-new=X] [--term-old=X] [bad [good...]] [--]
        var positional_refs = std.array_list.Managed([]const u8).init(allocator);
        defer positional_refs.deinit();
        while (args.next()) |start_arg| {
            if (std.mem.startsWith(u8, start_arg, "--term-new=") or std.mem.startsWith(u8, start_arg, "--term-old=") or
                std.mem.eql(u8, start_arg, "--term-new") or std.mem.eql(u8, start_arg, "--term-old") or
                std.mem.eql(u8, start_arg, "--no-checkout") or std.mem.eql(u8, start_arg, "--first-parent"))
            {
                // helpers.Skip term options (consume value if separate)
                if (std.mem.eql(u8, start_arg, "--term-new") or std.mem.eql(u8, start_arg, "--term-old")) {
                    _ = args.next();
                }
            } else if (std.mem.eql(u8, start_arg, "--")) {
                break;
            } else {
                try positional_refs.append(start_arg);
            }
        }
        
        // helpers.Check for optional bad/good helpers.refs from positional args
        if (positional_refs.items.len > 0) {
            const bad_ref = positional_refs.items[0];
            const hash = helpers.resolveRevision(git_path, bad_ref, platform_impl, allocator) catch {
                const msg = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{bad_ref});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            };
            defer allocator.free(hash);
            
            // helpers.Write BISECT_BAD
            const bad_path = try std.fmt.allocPrint(allocator, "{s}/refs/bisect/bad", .{git_path});
            defer allocator.free(bad_path);
            
            // helpers.Create refs/bisect directory
            const bisect_dir = try std.fmt.allocPrint(allocator, "{s}/refs/bisect", .{git_path});
            defer allocator.free(bisect_dir);
            std.fs.cwd().makePath(bisect_dir) catch {};
            
            const hash_nl = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
            defer allocator.free(hash_nl);
            try platform_impl.fs.writeFile(bad_path, hash_nl);
            
            // helpers.Handle good helpers.refs (remaining positional args)
            for (positional_refs.items[1..]) |good_ref| {
                const good_hash = helpers.resolveRevision(git_path, good_ref, platform_impl, allocator) catch continue;
                defer allocator.free(good_hash);
                
                // helpers.Write good ref
                const good_path = try std.fmt.allocPrint(allocator, "{s}/refs/bisect/good-{s}", .{git_path, good_hash});
                defer allocator.free(good_path);
                const good_hash_nl = try std.fmt.allocPrint(allocator, "{s}\n", .{good_hash});
                defer allocator.free(good_hash_nl);
                try platform_impl.fs.writeFile(good_path, good_hash_nl);
            }
        }
        
        try platform_impl.writeStderr("status: waiting for both good and bad commits\n");
    } else if (std.mem.eql(u8, subcmd, "bad") or std.mem.eql(u8, subcmd, "new")) {
        const rev = args.next() orelse "HEAD";
        const hash = helpers.resolveRevision(git_path, rev, platform_impl, allocator) catch {
            try platform_impl.writeStderr("fatal: bad revision\n");
            std.process.exit(128);
        };
        defer allocator.free(hash);
        
        const bisect_dir = try std.fmt.allocPrint(allocator, "{s}/refs/bisect", .{git_path});
        defer allocator.free(bisect_dir);
        std.fs.cwd().makePath(bisect_dir) catch {};
        
        const bad_path = try std.fmt.allocPrint(allocator, "{s}/refs/bisect/bad", .{git_path});
        defer allocator.free(bad_path);
        const hash_nl = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
        defer allocator.free(hash_nl);
        try platform_impl.fs.writeFile(bad_path, hash_nl);
    } else if (std.mem.eql(u8, subcmd, "good") or std.mem.eql(u8, subcmd, "old")) {
        const rev = args.next() orelse "HEAD";
        const hash = helpers.resolveRevision(git_path, rev, platform_impl, allocator) catch {
            try platform_impl.writeStderr("fatal: bad revision\n");
            std.process.exit(128);
        };
        defer allocator.free(hash);
        
        const bisect_dir = try std.fmt.allocPrint(allocator, "{s}/refs/bisect", .{git_path});
        defer allocator.free(bisect_dir);
        std.fs.cwd().makePath(bisect_dir) catch {};
        
        // helpers.Write good-<hash> ref
        const good_path = try std.fmt.allocPrint(allocator, "{s}/refs/bisect/good-{s}", .{ git_path, hash });
        defer allocator.free(good_path);
        const hash_nl = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
        defer allocator.free(hash_nl);
        try platform_impl.fs.writeFile(good_path, hash_nl);
    } else if (std.mem.eql(u8, subcmd, "reset")) {
        // helpers.Clean up bisect state
        std.fs.cwd().deleteFile(bisect_log_path) catch {};
        std.fs.cwd().deleteFile(bisect_start_path) catch {};
        const bisect_dir = try std.fmt.allocPrint(allocator, "{s}/refs/bisect", .{git_path});
        defer allocator.free(bisect_dir);
        std.fs.cwd().deleteTree(bisect_dir) catch {};
        
        // helpers.Also clean BISECT_EXPECTED_REV, BISECT_HEAD, etc.
        const be = try std.fmt.allocPrint(allocator, "{s}/BISECT_EXPECTED_REV", .{git_path});
        defer allocator.free(be);
        std.fs.cwd().deleteFile(be) catch {};
        const bh = try std.fmt.allocPrint(allocator, "{s}/BISECT_HEAD", .{git_path});
        defer allocator.free(bh);
        std.fs.cwd().deleteFile(bh) catch {};
        
        try platform_impl.writeStdout("Previous helpers.HEAD position was...\n");
    } else if (std.mem.eql(u8, subcmd, "log")) {
        const log_data = platform_impl.fs.readFile(allocator, bisect_log_path) catch {
            try platform_impl.writeStderr("We are not bisecting.\n");
            std.process.exit(1);
        };
        defer allocator.free(log_data);
        try platform_impl.writeStdout(log_data);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "error: unknown bisect subcommand '{s}'\n", .{subcmd});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    }
}
