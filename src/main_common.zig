// main_common.zig - Thin dispatch layer
// This file only contains zigzitMain() which routes commands to their implementations.
// DO NOT add command implementations here. Put them in src/cmd_*.zig files.
// Shared helpers are in src/git_helpers.zig.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const network = helpers.network;
const build_options = @import("build_options");
const version_mod = @import("version.zig");
const wildmatch_mod = @import("wildmatch.zig");

// Command modules
const cmd_add = @import("cmd_add.zig");
const cmd_apply = @import("cmd_apply.zig");
const cmd_branch = @import("cmd_branch.zig");
const cmd_cat_file = @import("cmd_cat_file.zig");
const cmd_check_attr = @import("cmd_check_attr.zig");
const cmd_check_ignore = @import("cmd_check_ignore.zig");
const cmd_check_ref_format = @import("cmd_check_ref_format.zig");
const cmd_checkout = @import("cmd_checkout.zig");
const cmd_clean = @import("cmd_clean.zig");
const cmd_clone = @import("cmd_clone.zig");
const cmd_column = @import("cmd_column.zig");
const cmd_commit = @import("cmd_commit.zig");
const cmd_commit_tree = @import("cmd_commit_tree.zig");
const cmd_count_objects = @import("cmd_count_objects.zig");
const cmd_daemon = @import("cmd_daemon.zig");
const cmd_describe = @import("cmd_describe.zig");
const cmd_diff_core = @import("cmd_diff_core.zig");
const cmd_diff_tree = @import("cmd_diff_tree.zig");
const cmd_fast_export = @import("cmd_fast_export.zig");
const cmd_fast_import = @import("cmd_fast_import.zig");
const cmd_for_each_ref = @import("cmd_for_each_ref.zig");
const cmd_format_patch = @import("cmd_format_patch.zig");
const cmd_fsck = @import("cmd_fsck.zig");
const cmd_gc = @import("cmd_gc.zig");
const cmd_hash_object = @import("cmd_hash_object.zig");
const cmd_init = @import("cmd_init.zig");
const cmd_last_modified = @import("cmd_last_modified.zig");
const cmd_log = @import("cmd_log.zig");
const cmd_ls_files = @import("cmd_ls_files.zig");
const cmd_ls_remote = @import("cmd_ls_remote.zig");
const cmd_ls_tree = @import("cmd_ls_tree.zig");
const cmd_merge_base = @import("cmd_merge_base.zig");
const cmd_misc = @import("cmd_misc.zig");
const cmd_mktag = @import("cmd_mktag.zig");
const cmd_mktree = @import("cmd_mktree.zig");
const cmd_mv = @import("cmd_mv.zig");
const cmd_name_rev = @import("cmd_name_rev.zig");
const cmd_notes = @import("cmd_notes.zig");
const cmd_pack = @import("cmd_pack.zig");
const cmd_pack_refs = @import("cmd_pack_refs.zig");
const cmd_prune = @import("cmd_prune.zig");
const cmd_push_impl = @import("cmd_push_impl.zig");
const cmd_read_tree = @import("cmd_read_tree.zig");
const cmd_reflog = @import("cmd_reflog.zig");
const cmd_refs = @import("cmd_refs.zig");
const cmd_remote = @import("cmd_remote.zig");
const cmd_repack = @import("cmd_repack.zig");
const cmd_reset = @import("cmd_reset.zig");
const cmd_rev_list = @import("cmd_rev_list.zig");
const cmd_rev_parse = @import("cmd_rev_parse.zig");
const cmd_rm = @import("cmd_rm.zig");
const cmd_show = @import("cmd_show.zig");
const cmd_show_branch = @import("cmd_show_branch.zig");
const cmd_show_index = @import("cmd_show_index.zig");
const cmd_show_ref = @import("cmd_show_ref.zig");
const cmd_stash = @import("cmd_stash.zig");
const cmd_status = @import("cmd_status.zig");
const cmd_stripspace = @import("cmd_stripspace.zig");
const cmd_symbolic_ref = @import("cmd_symbolic_ref.zig");
const cmd_tag = @import("cmd_tag.zig");
const cmd_update_index = @import("cmd_update_index.zig");
const cmd_update_ref = @import("cmd_update_ref.zig");
const cmd_update_server_info = @import("cmd_update_server_info.zig");
const cmd_var = @import("cmd_var.zig");
const cmd_verify = @import("cmd_verify.zig");
const cmd_verify_pack = @import("cmd_verify_pack.zig");
const cmd_web_browse = @import("cmd_web_browse.zig");
const cmd_write_tree = @import("cmd_write_tree.zig");

// Already-extracted command modules
const config_cmd_mod = helpers.config_cmd_mod;
const diff_cmd_mod = helpers.diff_cmd_mod;
const merge_cmd_mod = helpers.merge_cmd_mod;
const fetch_cmd = helpers.fetch_cmd;
const push_cmd = helpers.push_cmd;
const rebase_cmd = helpers.rebase_cmd;
const cherry_pick_mod = helpers.cherry_pick_mod;

// Re-export helpers that other modules may need
pub const git_helpers = helpers;

// Re-export globals for backward compatibility
// global_config_overrides is in git_helpers.zig
// Use helpers.global_git_dir_override directly
pub const cSetenv = helpers.cSetenv;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn zigzitMain(allocator: std.mem.Allocator) !void {
    const platform_impl = platform_mod.getCurrentPlatform();
    
    var args = try platform_impl.getArgs(allocator);
    defer args.deinit();
    
    // Check program name for git-<command> invocation pattern
    const prog_name = args.next() orelse {
        try cmd_misc.showUsage(&platform_impl);
        std.process.exit(1);
    };

    // Extract command from argv[0] if invoked as git-<command>
    var dashed_command: ?[]const u8 = null;
    {
        const basename = if (std.mem.lastIndexOfScalar(u8, prog_name, '/')) |slash| prog_name[slash + 1 ..] else prog_name;
        if (std.mem.startsWith(u8, basename, "git-") and basename.len > 4) {
            dashed_command = basename[4..];
        }
    }

    // Store all arguments for potential git fallback
    var all_original_args = std.array_list.Managed([]const u8).init(allocator);
    defer all_original_args.deinit();

    // If invoked as git-<command>, prepend the command name
    if (dashed_command) |dc| {
        try all_original_args.append(dc);
    }

    // Collect all arguments first
    while (args.next()) |arg| {
        try all_original_args.append(arg);
    }
    
    if (all_original_args.items.len == 0) {
        try cmd_misc.showUsage(&platform_impl);
        std.process.exit(1);
    }
    
    // Strip global flags that newer git versions support but older ones don't
    // This allows tests written for git 2.46+ to work with git 2.43
    {
        var write_idx: usize = 0;
        var read_idx: usize = 0;
        while (read_idx < all_original_args.items.len) {
            const arg = all_original_args.items[read_idx];
            if (std.mem.startsWith(u8, arg, "--ref-format=")) {
                const ref_fmt_val = arg["--ref-format=".len..];
                if (std.mem.eql(u8, ref_fmt_val, "files")) {
                    // Strip --ref-format=files (git 2.46+ feature, 2.43 only supports files)
                    read_idx += 1;
                    continue;
                } else {
                    // Unknown ref format - emit error like git 2.53 does
                    const err_msg = std.fmt.allocPrint(allocator, "fatal: unknown ref storage format '{s}'\n", .{ref_fmt_val}) catch "fatal: unknown ref storage format\n";
                    platform_impl.writeStderr(err_msg) catch {};
                    std.process.exit(128);
                }
            }
            if (std.mem.eql(u8, arg, "--no-advice") or
                std.mem.eql(u8, arg, "--i-still-use-this")) {
                // Strip these flags (git 2.46+ features not in git 2.43)
                read_idx += 1;
                continue;
            }
            // Translate newer git flags to older equivalents for git 2.43 compat
            if (std.mem.eql(u8, arg, "-ufalse") or std.mem.eql(u8, arg, "--untracked-files=false") or
                std.mem.eql(u8, arg, "-u0") or std.mem.eql(u8, arg, "--untracked-files=0")) {
                all_original_args.items[write_idx] = "-uno";
            } else if (std.mem.eql(u8, arg, "-utrue") or std.mem.eql(u8, arg, "--untracked-files=true") or
                       std.mem.eql(u8, arg, "-uyes") or std.mem.eql(u8, arg, "--untracked-files=yes") or
                       std.mem.eql(u8, arg, "-u1") or std.mem.eql(u8, arg, "--untracked-files=1") or
                       std.mem.eql(u8, arg, "-uon") or std.mem.eql(u8, arg, "--untracked-files=on")) {
                all_original_args.items[write_idx] = "-unormal";
            } else {
                all_original_args.items[write_idx] = arg;
            }
            // Translate -c key=value pairs for git 2.43 compat
            if (std.mem.eql(u8, all_original_args.items[write_idx], "-c") and read_idx + 1 < all_original_args.items.len) {
                // Next arg is key=value - translate if needed
                const next = all_original_args.items[read_idx + 1];
                all_original_args.items[write_idx + 1] = helpers.translateConfigKeyValue(next);
                write_idx += 2;
                read_idx += 2;
            } else if (std.mem.startsWith(u8, all_original_args.items[write_idx], "-c") and all_original_args.items[write_idx].len > 2 and all_original_args.items[write_idx][2] != ' ') {
                // -ckey=value form (no space between -c and key)
                all_original_args.items[write_idx] = helpers.translateConfigKeyValue(all_original_args.items[write_idx][2..]);
                // Need to split into -c and value... actually keep as-is, just translate in-place
                // This form is rare. Skip for now.
                write_idx += 1;
                read_idx += 1;
            } else {
                write_idx += 1;
                read_idx += 1;
            }
        }
        all_original_args.shrinkRetainingCapacity(write_idx);
    }

    // Post-process: command-specific flag translations for git 2.43 compat
    // show-ref --branches → show-ref --heads (git 2.46+ alias)
    // show-ref --exists → needs git 2.45+, handle specially
    {
        var found_show_ref = false;
        var found_for_each_ref = false;
        for (all_original_args.items) |arg| {
            if (std.mem.eql(u8, arg, "show-ref")) { found_show_ref = true; break; }
            if (std.mem.eql(u8, arg, "for-each-ref")) { found_for_each_ref = true; break; }
        }
        if (found_show_ref or found_for_each_ref) {
            for (all_original_args.items, 0..) |arg, i| {
                if (std.mem.eql(u8, arg, "--branches")) {
                    all_original_args.items[i] = "--heads";
                }
            }
        }
    }

    // Find the command by skipping global flags
    var command_index: usize = 0;
    while (command_index < all_original_args.items.len) {
        const arg = all_original_args.items[command_index];
        
        if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--git-dir") or std.mem.eql(u8, arg, "--work-tree")) {
            // Skip the flag and its value
            command_index += 2;
        } else if (std.mem.eql(u8, arg, "-c")) {
            // Skip -c and its value, but also register the override early
            if (command_index + 1 < all_original_args.items.len) {
                try helpers.addConfigOverride(allocator, all_original_args.items[command_index + 1]);
            }
            command_index += 2;
            if (command_index > all_original_args.items.len) {
                try platform_impl.writeStderr("error: invalid global flag usage\n");
                std.process.exit(128);
            }
        } else if (std.mem.eql(u8, arg, "--config-env")) {
            // --config-env requires a following argument
            if (command_index + 1 < all_original_args.items.len) {
                command_index += 1;
                helpers.handleConfigEnv(allocator, all_original_args.items[command_index]);
            } else {
                const fe = std.fs.File{ .handle = std.posix.STDERR_FILENO };
                _ = fe.write("error: no config key given for --config-env\n") catch {};
                std.process.exit(129);
            }
            command_index += 1;
        } else if (std.mem.startsWith(u8, arg, "--git-dir=") or
                   std.mem.startsWith(u8, arg, "--work-tree=") or
                   std.mem.startsWith(u8, arg, "--ref-format=") or 
                   std.mem.startsWith(u8, arg, "--no-advice") or
                   std.mem.startsWith(u8, arg, "--config-env=") or
                   std.mem.startsWith(u8, arg, "--namespace=") or
                   std.mem.startsWith(u8, arg, "--super-prefix=") or
                   std.mem.eql(u8, arg, "--bare") or
                   std.mem.eql(u8, arg, "--no-replace-objects") or
                   std.mem.eql(u8, arg, "--literal-pathspecs") or
                   std.mem.eql(u8, arg, "--glob-pathspecs") or
                   std.mem.eql(u8, arg, "--noglob-pathspecs") or
                   std.mem.eql(u8, arg, "--icase-pathspecs") or
                   std.mem.eql(u8, arg, "--no-optional-locks") or
                   std.mem.eql(u8, arg, "--no-lazy-fetch") or
                   std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--paginate") or
                   std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--no-pager")) {
            // Track pathspec global flags
            if (std.mem.eql(u8, arg, "--glob-pathspecs")) helpers.global_glob_pathspecs = true;
            if (std.mem.eql(u8, arg, "--noglob-pathspecs")) helpers.global_noglob_pathspecs = true;
            if (std.mem.eql(u8, arg, "--icase-pathspecs")) helpers.global_icase_pathspecs = true;
            if (std.mem.eql(u8, arg, "--literal-pathspecs")) helpers.global_literal_pathspecs = true;
            if (std.mem.startsWith(u8, arg, "--config-env=")) helpers.handleConfigEnv(allocator, arg["--config-env=".len..]);
            // Global flags with = form, or boolean global flags
            command_index += 1;
        } else {
            // This must be the command
            break;
        }
    }
    
    if (command_index >= all_original_args.items.len) {
        try cmd_misc.showUsage(&platform_impl);
        return;
    }
    
    var command = all_original_args.items[command_index];
    
    // Check if this is a native command; if not, try alias resolution (with loop detection)
    var alias_depth: u32 = 0;
    while (!helpers.isNativeCommand(command) and alias_depth < 10) : (alias_depth += 1) {
        // Try to resolve as an alias from git config
        const alias_value = try helpers.resolveAlias(allocator, command, &platform_impl);
        if (alias_value) |alias_cmd| {
            defer allocator.free(alias_cmd);
            // Parse the alias value into words and rebuild args
            // If alias starts with '!', it's a shell command - not supported natively
            if (alias_cmd.len > 0 and alias_cmd[0] == '!') {
                // Shell alias: execute via /bin/sh -c
                const shell_cmd = alias_cmd[1..];
                // Append remaining args to the shell command
                var full_cmd = std.array_list.Managed(u8).init(allocator);
                defer full_cmd.deinit();
                try full_cmd.appendSlice(shell_cmd);
                var ri: usize = command_index + 1;
                while (ri < all_original_args.items.len) : (ri += 1) {
                    try full_cmd.append(' ');
                    try full_cmd.appendSlice(all_original_args.items[ri]);
                }
                var child = std.process.Child.init(&.{ "/bin/sh", "-c", full_cmd.items }, allocator);
                child.stdin_behavior = .Inherit;
                child.stdout_behavior = .Inherit;
                child.stderr_behavior = .Inherit;
                if (@import("builtin").target.os.tag != .freestanding) helpers.config_helpers_mod.setConfigParametersEnv(allocator);
                _ = child.spawn() catch {
                    try platform_impl.writeStderr("fatal: failed to run shell alias\n");
                    std.process.exit(128);
                };
                const result = child.wait() catch {
                    std.process.exit(128);
                };
                switch (result) {
                    .Exited => |code| std.process.exit(code),
                    else => std.process.exit(128),
                }
                return;
            }
            // Split alias into words
            var alias_words = std.array_list.Managed([]const u8).init(allocator);
            defer alias_words.deinit();
            var word_iter = std.mem.tokenizeAny(u8, alias_cmd, " \t");
            while (word_iter.next()) |word| {
                try alias_words.append(try allocator.dupe(u8, word));
            }
            if (alias_words.items.len > 0) {
                // Rebuild all_original_args: global flags + alias words + remaining args
                var new_args = std.array_list.Managed([]const u8).init(allocator);
                defer new_args.deinit();
                // Copy global flags (before command_index)
                for (all_original_args.items[0..command_index]) |ga| {
                    try new_args.append(ga);
                }
                // Add expanded alias words
                for (alias_words.items) |aw| {
                    try new_args.append(aw);
                }
                // Add remaining args after the alias command
                var ri2: usize = command_index + 1;
                while (ri2 < all_original_args.items.len) : (ri2 += 1) {
                    try new_args.append(all_original_args.items[ri2]);
                }
                // Replace all_original_args content
                all_original_args.clearRetainingCapacity();
                for (new_args.items) |a| {
                    try all_original_args.append(a);
                }
                // Re-scan for global flags in expanded alias (e.g., alias = "-c key=val config ...")
                while (command_index < all_original_args.items.len) {
                    const carg = all_original_args.items[command_index];
                    if (std.mem.eql(u8, carg, "-c") and command_index + 1 < all_original_args.items.len) {
                        const cv = all_original_args.items[command_index + 1];
                        if (std.mem.indexOfScalar(u8, cv, '=')) |eq_pos| {
                            const ckey = cv[0..eq_pos];
                            const cval = cv[eq_pos + 1 ..];
                            if (helpers.global_config_overrides == null) {
                                helpers.global_config_overrides = std.array_list.Managed(helpers.ConfigOverride).init(allocator);
                            }
                            helpers.global_config_overrides.?.append(.{ .key = try allocator.dupe(u8, ckey), .value = try allocator.dupe(u8, cval) }) catch {};
                        }
                        command_index += 2;
                    } else if (std.mem.eql(u8, carg, "-C") and command_index + 1 < all_original_args.items.len) {
                        command_index += 2;
                    } else {
                        break;
                    }
                }
                if (command_index >= all_original_args.items.len) break;
                command = all_original_args.items[command_index];
                // Set GIT_CONFIG_PARAMETERS so config_cmd picks up alias-expanded -c overrides
                if (@import("builtin").target.os.tag != .freestanding) helpers.config_helpers_mod.setConfigParametersEnv(allocator);
                // Continue the while loop to check if the expanded command is native or needs further alias resolution
            }
        } else {
            // Check if command exists as git-<cmd> in exec path
            const exec_path = std.posix.getenv("GIT_EXEC_PATH") orelse "";
            if (exec_path.len > 0) {
                const ext_cmd = std.fmt.allocPrint(allocator, "{s}/git-{s}", .{exec_path, command}) catch null;
                if (ext_cmd) |ec| {
                    defer allocator.free(ec);
                    if (std.fs.cwd().access(ec, .{})) |_| {
                        // External command found - execute it
                        var argv = std.array_list.Managed([]const u8).init(allocator);
                        defer argv.deinit();
                        try argv.append(ec);
                        var ri: usize = command_index + 1;
                        while (ri < all_original_args.items.len) : (ri += 1) {
                            try argv.append(all_original_args.items[ri]);
                        }
                        var child = std.process.Child.init(argv.items, allocator);
                        child.stdin_behavior = .Inherit;
                        child.stdout_behavior = .Inherit;
                        child.stderr_behavior = .Inherit;
                        _ = child.spawn() catch { std.process.exit(128); };
                        const result = child.wait() catch { std.process.exit(128); };
                        switch (result) {
                            .Exited => |code| std.process.exit(code),
                            else => std.process.exit(128),
                        }
                    } else |_| {}
                }
            }
            // Also check PATH for git-<command>
            const path_env = std.posix.getenv("PATH") orelse "";
            if (path_env.len > 0) {
                const git_cmd_name = std.fmt.allocPrint(allocator, "git-{s}", .{command}) catch null;
                if (git_cmd_name) |gcn| {
                    defer allocator.free(gcn);
                    var path_iter = std.mem.splitScalar(u8, path_env, ':');
                    while (path_iter.next()) |dir| {
                        if (dir.len == 0) continue;
                        const full_cmd = std.fmt.allocPrint(allocator, "{s}/{s}", .{dir, gcn}) catch continue;
                        defer allocator.free(full_cmd);
                        if (std.fs.cwd().access(full_cmd, .{})) |_| {
                            // Found external command in PATH
                            var argv2 = std.array_list.Managed([]const u8).init(allocator);
                            defer argv2.deinit();
                            argv2.append(full_cmd) catch continue;
                            var ri3: usize = command_index + 1;
                            while (ri3 < all_original_args.items.len) : (ri3 += 1) {
                                argv2.append(all_original_args.items[ri3]) catch continue;
                            }
                            var child2 = std.process.Child.init(argv2.items, allocator);
                            child2.stdin_behavior = .Inherit;
                            child2.stdout_behavior = .Inherit;
                            child2.stderr_behavior = .Inherit;
                            _ = child2.spawn() catch continue;
                            const result2 = child2.wait() catch { std.process.exit(128); };
                            switch (result2) {
                                .Exited => |code| std.process.exit(code),
                                else => std.process.exit(128),
                            }
                        } else |_| {}
                    }
                }
            }
            // Command not found - check help.autocorrect config
            const error_msg = std.fmt.allocPrint(allocator, "git: '{s}' is not a git command. See 'git --help'.\n", .{command}) catch "git: invalid command. See 'git --help'.\n";
            defer if (error_msg.ptr != "ziggit: invalid command. See 'ziggit --help'.\n".ptr) allocator.free(error_msg);
            try platform_impl.writeStderr(error_msg);

            // Find similar commands for autocorrect
            const candidates = helpers.findSimilarCommands(allocator, command, &platform_impl) catch &[_][]const u8{};

            if (candidates.len > 0) {
                // Read help.autocorrect config
                var autocorrect_val: i32 = 0; // default: no autocorrect
                // Check config override first
                if (helpers.getConfigOverride("help.autocorrect")) |ov| {
                    autocorrect_val = helpers.parseAutocorrectValue(ov);
                } else {
                    // Try reading from git config
                    if (helpers.findGitDirectory(allocator, &platform_impl)) |git_path2| {
                        defer allocator.free(git_path2);
                        if (helpers.getConfigValueByKey(git_path2, "help.autocorrect", allocator)) |val| {
                            defer allocator.free(val);
                            autocorrect_val = helpers.parseAutocorrectValue(val);
                        }
                    } else |_| {}
                }

                if (autocorrect_val == -2) {
                    // never: don't show similar commands, just exit
                    std.process.exit(1);
                } else if (autocorrect_val == 0) {
                    // Show candidates but don't run
                    try platform_impl.writeStderr("\nThe most similar command");
                    if (candidates.len == 1) {
                        try platform_impl.writeStderr(" is\n");
                    } else {
                        try platform_impl.writeStderr("s are\n");
                    }
                    for (candidates) |cand| {
                        const cand_msg = std.fmt.allocPrint(allocator, "\t{s}\n", .{cand}) catch continue;
                        defer allocator.free(cand_msg);
                        try platform_impl.writeStderr(cand_msg);
                    }
                    std.process.exit(1);
                } else if (autocorrect_val < 0) {
                    // Immediate: run the best match
                    const best = candidates[0];
                    const auto_msg = std.fmt.allocPrint(allocator, "Assuming you meant '{s}'\n", .{best}) catch "";
                    defer if (auto_msg.len > 0) allocator.free(auto_msg);
                    try platform_impl.writeStderr(auto_msg);
                    // Replace command with the best match and restart
                    all_original_args.items[command_index] = best;
                    command = best;
                    alias_depth = 0;
                    continue;
                } else {
                    // Positive value: wait N deciseconds then run
                    const best = candidates[0];
                    const delay_msg = std.fmt.allocPrint(allocator, "\nRunning '{s}' in {d}.{d} seconds...\n", .{ best, @divTrunc(autocorrect_val, 10), @mod(autocorrect_val, 10) }) catch "";
                    defer if (delay_msg.len > 0) allocator.free(delay_msg);
                    try platform_impl.writeStderr(delay_msg);
                    // Sleep for deciseconds
                    const ns: u64 = @as(u64, @intCast(autocorrect_val)) * 100_000_000;
                    std.Thread.sleep(ns);
                    all_original_args.items[command_index] = best;
                    command = best;
                    alias_depth = 0;
                    continue;
                }
            }

            std.process.exit(1);
        }
    }
    // Check for alias loop (depth exceeded)
    if (alias_depth >= 10 and !helpers.isNativeCommand(command)) {
        const loop_msg = try std.fmt.allocPrint(allocator, "fatal: alias loop detected: expansion of '{s}' does not terminate\n", .{all_original_args.items[command_index]});
        defer allocator.free(loop_msg);
        try platform_impl.writeStderr(loop_msg);
        std.process.exit(128);
    }
    
    // Determine if this command is handled natively (NOT forwarded to real git)
    // Commands forwarded to git should NOT be here — git handles -C itself
    // All commands are handled natively — always process -C, -c, etc.
    const is_native_handler = true;

    // Process GIT_CONFIG_COUNT before -c args (environment config comes first)
    {
        const env_count_str2 = std.process.getEnvVarOwned(allocator, "GIT_CONFIG_COUNT") catch null;
        defer if (env_count_str2) |ecs2| allocator.free(ecs2);
        if (env_count_str2) |ecs2| {
            const trimmed_count = std.mem.trim(u8, ecs2, " \t");
            if (trimmed_count.len == 0) {
                // Empty count: treat as no config pairs (ignore)
            } else if (std.fmt.parseInt(usize, trimmed_count, 10)) |count2| {
                if (count2 > 1000000) {
                    const fe = std.fs.File{ .handle = std.posix.STDERR_FILENO };
                    _ = fe.write("error: too many entries for GIT_CONFIG_COUNT\n") catch {};
                    std.process.exit(128);
                }
                var env_idx2: usize = 0;
                while (env_idx2 < count2) : (env_idx2 += 1) {
                    const key_env_name2 = std.fmt.allocPrint(allocator, "GIT_CONFIG_KEY_{d}", .{env_idx2}) catch continue;
                    defer allocator.free(key_env_name2);
                    const val_env_name2 = std.fmt.allocPrint(allocator, "GIT_CONFIG_VALUE_{d}", .{env_idx2}) catch continue;
                    defer allocator.free(val_env_name2);
                    const env_key2 = std.process.getEnvVarOwned(allocator, key_env_name2) catch {
                        const fe = std.fs.File{ .handle = std.posix.STDERR_FILENO };
                        const em = std.fmt.allocPrint(allocator, "error: missing config key GIT_CONFIG_KEY_{d}\n", .{env_idx2}) catch continue;
                        defer allocator.free(em);
                        _ = fe.write(em) catch {};
                        std.process.exit(128);
                    };
                    defer allocator.free(env_key2);
                    const env_val2 = std.process.getEnvVarOwned(allocator, val_env_name2) catch {
                        const fe = std.fs.File{ .handle = std.posix.STDERR_FILENO };
                        const em = std.fmt.allocPrint(allocator, "error: missing config value GIT_CONFIG_VALUE_{d}\n", .{env_idx2}) catch continue;
                        defer allocator.free(em);
                        _ = fe.write(em) catch {};
                        std.process.exit(128);
                    };
                    defer allocator.free(env_val2);
                    const setting2 = std.fmt.allocPrint(allocator, "{s}={s}", .{env_key2, env_val2}) catch continue;
                    defer allocator.free(setting2);
                    helpers.addConfigOverride(allocator, setting2) catch continue;
                }
            } else |_| {
                const fe = std.fs.File{ .handle = std.posix.STDERR_FILENO };
                _ = fe.write("error: bogus count in GIT_CONFIG_COUNT\n") catch {};
                std.process.exit(128);
            }
        }
    }

    // Process global flags and execute
    var arg_index: usize = 0;
    
    // Handle global flags in a loop - only process -C for native commands
    // (forwarded commands pass all args to real git which handles -C itself)
    while (arg_index < all_original_args.items.len) {
        const arg = all_original_args.items[arg_index];
        
        if (std.mem.eql(u8, arg, "-C")) {
            if (arg_index + 1 >= all_original_args.items.len) {
                try platform_impl.writeStderr("error: option '-C' requires a directory path\n");
                std.process.exit(128);
            }
            
            arg_index += 1;
            const dir_path = all_original_args.items[arg_index];
            
            // Only change directory for native commands
            if (is_native_handler and dir_path.len > 0) {
                std.process.changeCurDir(dir_path) catch |err| switch (err) {
                    error.AccessDenied => {
                        const msg = try std.fmt.allocPrint(allocator, "fatal: cannot change to '{s}': Permission denied\n", .{dir_path});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(128);
                    },
                    error.FileNotFound => {
                        const msg = try std.fmt.allocPrint(allocator, "fatal: cannot change to '{s}': No such file or directory\n", .{dir_path});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(128);
                    },
                    error.NotDir => {
                        const msg = try std.fmt.allocPrint(allocator, "fatal: cannot change to '{s}': Not a directory\n", .{dir_path});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(128);
                    },
                    else => return err,
                };
            }
            
            arg_index += 1;
        } else if (std.mem.eql(u8, arg, "-c")) {
            if (arg_index + 1 >= all_original_args.items.len) {
                try platform_impl.writeStderr("error: option '-c' requires a config setting\n");
                std.process.exit(128);
            }
            
            arg_index += 1;
            const config_setting = all_original_args.items[arg_index];
            try helpers.addConfigOverride(allocator, config_setting);
            arg_index += 1;
        } else if (std.mem.eql(u8, arg, "--git-dir")) {
            if (arg_index + 1 >= all_original_args.items.len) {
                try platform_impl.writeStderr("error: option '--git-dir' requires a path\n");
                std.process.exit(128);
            }
            
            arg_index += 1;
            const git_dir_path = all_original_args.items[arg_index];
            helpers.global_git_dir_override = git_dir_path;
            arg_index += 1;
        } else if (std.mem.startsWith(u8, arg, "--git-dir=")) {
            helpers.global_git_dir_override = arg["--git-dir=".len..];
            arg_index += 1;
        } else if (std.mem.eql(u8, arg, "--work-tree")) {
            if (arg_index + 1 >= all_original_args.items.len) {
                try platform_impl.writeStderr("error: option '--work-tree' requires a path\n");
                std.process.exit(128);
            }
            
            arg_index += 1;
            // Skip the path for now (not implemented)
            arg_index += 1;
        } else {
            // Not a global flag, this must be the command - break
            break;
        }
    }
    
    // Process GIT_CONFIG_PARAMETERS environment variable
    {
        const params_str = std.process.getEnvVarOwned(allocator, "GIT_CONFIG_PARAMETERS") catch null;
        if (params_str) |params| {
            defer allocator.free(params);
            helpers.parseGitConfigParameters(allocator, params);
        }
    }

    // Create args iterator for the remaining arguments (after the command)
    var remaining_args = std.array_list.Managed([]const u8).init(allocator);
    defer remaining_args.deinit();
    
    var remaining_arg_index = command_index + 1;
    while (remaining_arg_index < all_original_args.items.len) {
        try remaining_args.append(all_original_args.items[remaining_arg_index]);
        remaining_arg_index += 1;
    }
    
    // Create a simple iterator for remaining args
    const remaining_args_copy = try allocator.dupe([]const u8, remaining_args.items);
    defer allocator.free(remaining_args_copy);
    
    var args_iter = platform_mod.ArgIterator{ 
        .args = remaining_args_copy, 
        .index = 0,
        .allocator = allocator,
    };

    // If -h is in the args for a command, show basic usage and exit 129
    // (git convention: -h prints usage to stdout, exits with 129)
    // Exception: grep uses -h as --no-filename
    if (!std.mem.eql(u8, command, "grep")) {
        var cmd_has_help = false;
        var cmd_saw_dd = false;
        for (remaining_args_copy) |arg| {
            if (std.mem.eql(u8, arg, "--")) {
                cmd_saw_dd = true;
                continue;
            }
            if (cmd_saw_dd) continue;
            if (std.mem.eql(u8, arg, "-h")) {
                cmd_has_help = true;
                break;
            }
        }
        if (cmd_has_help) {
            const usage_msg = try std.fmt.allocPrint(allocator, "usage: git {s} [<options>]\n", .{command});
            defer allocator.free(usage_msg);
            try platform_impl.writeStdout(usage_msg);
            std.process.exit(129);
        }
    }

    // Handle --git-completion-helper and --git-completion-helper-all
    for (remaining_args_copy) |carg| {
        if (std.mem.eql(u8, carg, "--git-completion-helper") or std.mem.eql(u8, carg, "--git-completion-helper-all")) {
            const is_show_all = std.mem.eql(u8, carg, "--git-completion-helper-all");
            const opts = helpers.getCompletionHelperOptions(command);
            if (opts.len > 0) {
                if (!is_show_all) {
                    // For --git-completion-helper, only output options before trailing " --" separator
                    var visible_end: usize = opts.len;
                    if (opts.len >= 3 and std.mem.eql(u8, opts[opts.len - 3 ..], " --")) {
                        visible_end = opts.len - 3;
                    }
                    const trimmed = std.mem.trim(u8, opts[0..visible_end], " ");
                    const cline = try std.fmt.allocPrint(allocator, "{s}\n", .{trimmed});
                    defer allocator.free(cline);
                    try platform_impl.writeStdout(cline);
                } else {
                    // For --git-completion-helper-all, output everything but remove trailing " --"
                    var end: usize = opts.len;
                    if (opts.len >= 3 and std.mem.eql(u8, opts[opts.len - 3 ..], " --")) {
                        end = opts.len - 3;
                    }
                    const trimmed2 = std.mem.trim(u8, opts[0..end], " ");
                    const cline = try std.fmt.allocPrint(allocator, "{s}\n", .{trimmed2});
                    defer allocator.free(cline);
                    try platform_impl.writeStdout(cline);
                }
            }
            std.process.exit(0);
        }
    }

    // Pre-command config validation (core.bare boolean check, etc.)
    if (@import("builtin").target.os.tag != .freestanding) helpers.config_helpers_mod.validatePreCommandConfig(&platform_impl);

    // Commands with native ziggit implementations
    if (std.mem.eql(u8, command, "init") or std.mem.eql(u8, command, "init-db")) {
        // Check for global --bare flag
        var global_bare = false;
        for (all_original_args.items[0..command_index]) |ga| {
            if (std.mem.eql(u8, ga, "--bare")) global_bare = true;
        }
        try cmd_init.cmdInit(allocator, &args_iter, &platform_impl, global_bare);
    } else if (std.mem.eql(u8, command, "status")) {
        try cmd_status.cmdStatus(allocator, &args_iter, &platform_impl, all_original_args.items);
    } else if (std.mem.eql(u8, command, "rev-list")) {
        try cmd_rev_list.cmdRevList(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "add")) {
        try cmd_add.cmdAdd(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "ls-files")) {
        try cmd_ls_files.cmdLsFiles(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "ls-tree")) {
        try cmd_ls_tree.nativeCmdLsTree(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "config")) {
        try config_cmd_mod.run(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "bundle")) {
        try network.cmdBundle(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "version")) {
        try cmd_misc.cmdVersion(allocator, &args_iter, &platform_impl);
    // Commands that forward to real git for full compatibility
    } else if (std.mem.eql(u8, command, "clone")) {
        // Use our native clone implementation (supports --depth for shallow clones)
        try cmd_clone.cmdClone(allocator, &args_iter, &platform_impl, all_original_args.items);
    } else if (std.mem.eql(u8, command, "rev-parse")) {
        try cmd_rev_parse.cmdRevParse(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "checkout")) {
        try cmd_checkout.cmdCheckout(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "bisect")) {
        try cmd_misc.nativeCmdBisect(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "symbolic-ref")) {
        try cmd_symbolic_ref.cmdSymbolicRef(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "commit")) {
        try cmd_commit.cmdCommit(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "log")) {
        try diff_cmd_mod.cmdLog(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "diff")) {
        try diff_cmd_mod.cmdDiff(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "branch")) {
        try cmd_branch.cmdBranch(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "merge")) {
        try merge_cmd_mod.cmdMerge(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "fetch")) {
        try fetch_cmd.cmdFetch(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "pull")) {
        try fetch_cmd.cmdPull(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "push")) {
        try push_cmd.cmdPush(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "describe")) {
        try cmd_describe.cmdDescribe(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "tag")) {
        try cmd_tag.cmdTag(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "show")) {
        try diff_cmd_mod.cmdShow(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "cat-file")) {
        try cmd_cat_file.cmdCatFile(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "remote")) {
        try cmd_remote.cmdRemote(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "reset")) {
        try cmd_reset.cmdReset(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "rm")) {
        try cmd_rm.cmdRm(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "hash-object")) {
        try cmd_hash_object.cmdHashObject(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "write-tree")) {
        try cmd_write_tree.cmdWriteTree(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "commit-tree")) {
        try cmd_commit_tree.cmdCommitTree(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "update-ref")) {
        try cmd_update_ref.cmdUpdateRef(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "update-index")) {
        try cmd_update_index.cmdUpdateIndex(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "diff-files")) {
        try cmd_diff_core.cmdDiffFiles(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "read-tree")) {
        try cmd_read_tree.cmdReadTree(allocator, &args_iter, &platform_impl);
    } else if (std.mem.startsWith(u8, command, "--list-cmds=")) {
        const spec = command["--list-cmds=".len..];
        // Output builtins, one per line
        if (std.mem.indexOf(u8, spec, "builtins") != null) {
            const builtins = [_][]const u8{
                "add", "am", "annotate", "apply", "archive", "bisect", "blame", "branch",
                "bugreport", "bundle", "cat-file", "check-attr", "check-ignore",
                "check-mailmap", "check-ref-format", "checkout", "checkout-index",
                "cherry", "cherry-pick", "clean", "clone", "column", "commit",
                "commit-graph", "commit-tree", "config", "count-objects", "credential",
                "credential-cache", "credential-store", "describe", "diagnose", "diff",
                "diff-files", "diff-index", "diff-tree", "difftool", "fast-export",
                "fast-import", "fetch", "fmt-merge-msg", "for-each-ref", "for-each-repo",
                "format-patch", "fsck", "gc", "grep", "hash-object", "help", "index-pack",
                "init", "interpret-trailers", "log", "ls-files", "ls-remote", "ls-tree",
                "mailinfo", "mailsplit", "merge", "merge-base", "merge-file", "merge-index",
                "merge-ours", "merge-recursive", "merge-tree", "mktag", "mktree", "multi-pack-index",
                "mv", "name-rev", "notes", "pack-objects", "pack-redundant", "pack-refs",
                "patch-id", "prune", "prune-packed", "pull", "push", "range-diff",
                "read-tree", "rebase", "receive-pack", "reflog", "remote", "repack",
                "replace", "rerere", "reset", "restore", "rev-list", "rev-parse",
                "revert", "rm", "send-pack", "shortlog", "show", "show-branch",
                "show-index", "show-ref", "sparse-checkout", "stash", "status",
                "stripspace", "submodule", "switch", "symbolic-ref", "tag",
                "unpack-file", "unpack-objects", "update-index", "update-ref",
                "update-server-info", "upload-archive", "upload-pack", "var",
                "verify-commit", "verify-pack", "verify-tag", "version", "worktree",
                "write-tree",
            };
            for (builtins) |cmd| {
                const line = try std.fmt.allocPrint(allocator, "{s}\n", .{cmd});
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            }
        }
        if (std.mem.indexOf(u8, spec, "list-mainporcelain") != null or
            std.mem.indexOf(u8, spec, "main") != null) {
            const cmds = [_][]const u8{
                "add", "am", "archive", "bisect", "branch", "bundle", "checkout",
                "cherry-pick", "citool", "clean", "clone", "commit", "describe",
                "diff", "fetch", "format-patch", "gc", "gitk", "grep", "gui",
                "init", "log", "maintenance", "merge", "mv", "notes", "pull",
                "push", "range-diff", "rebase", "reset", "restore", "revert",
                "rm", "shortlog", "show", "sparse-checkout", "stash", "status",
                "submodule", "switch", "tag", "worktree",
            };
            for (cmds) |cmd| {
                const line = try std.fmt.allocPrint(allocator, "{s}\n", .{cmd});
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            }
        }
        if (std.mem.indexOf(u8, spec, "list-complete") != null) {
            const complete_cmds = [_][]const u8{
                "apply", "blame", "cherry", "config", "difftool", "fsck",
                "help", "instaweb", "mergetool", "prune", "reflog", "remote",
                "repack", "replace", "request-pull", "send-email", "show-branch",
                "stage", "whatchanged",
            };
            for (complete_cmds) |cmd| {
                const line = try std.fmt.allocPrint(allocator, "{s}\n", .{cmd});
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            }
        }
        if (std.mem.indexOf(u8, spec, "list-guide") != null) {
            const guides = [_][]const u8{
                "core-tutorial", "credentials", "cvs-migration", "diffcore",
                "everyday", "faq", "glossary", "namespaces", "remote-helpers",
                "submodules", "tutorial", "tutorial-2", "workflows",
            };
            for (guides) |g| {
                const line = try std.fmt.allocPrint(allocator, "{s}\n", .{g});
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            }
        }
        if (std.mem.indexOf(u8, spec, "others") != null) {
            // External/contrib commands - typically empty for ziggit
        }
        if (std.mem.indexOf(u8, spec, "nohelpers") != null) {
            // Already handled by main listing
        }
        if (std.mem.indexOf(u8, spec, "alias") != null) {
            // List aliases from config
            const git_path_alias = helpers.findGitDirectory(allocator, &platform_impl) catch null;
            if (git_path_alias) |gp| {
                defer allocator.free(gp);
                const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{gp}) catch null;
                if (config_path) |cp| {
                    defer allocator.free(cp);
                    const config_content = platform_impl.fs.readFile(allocator, cp) catch null;
                    if (config_content) |cc| {
                        defer allocator.free(cc);
                        var lines_it = std.mem.splitScalar(u8, cc, '\n');
                        var in_alias = false;
                        while (lines_it.next()) |line| {
                            const trimmed = std.mem.trim(u8, line, " \t\r");
                            if (trimmed.len > 0 and trimmed[0] == '[') {
                                in_alias = std.mem.startsWith(u8, std.mem.trim(u8, trimmed[1..], " \t"), "alias");
                            } else if (in_alias) {
                                if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                                    const alias_name = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                                    if (alias_name.len > 0) {
                                        const aout = try std.fmt.allocPrint(allocator, "{s}\n", .{alias_name});
                                        defer allocator.free(aout);
                                        try platform_impl.writeStdout(aout);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if (std.mem.indexOf(u8, spec, "parseopt") != null) {
            try platform_impl.writeStdout("add am annotate apply archive bisect blame branch bugreport bundle cat-file check-attr check-ignore check-mailmap checkout checkout-index cherry cherry-pick clean clone column commit commit-graph commit-tree config count-helpers.objects describe diagnose difftool fast-export fetch fmt-merge-msg for-each-ref for-each-repo format-patch fsck gc grep hash-object help init interpret-trailers log ls-files ls-remote ls-tree mailinfo maintenance merge merge-base merge-file merge-tree mktag mktree multi-pack-index mv name-rev notes pack-helpers.objects pack-helpers.refs prune pull push range-diff read-tree rebase receive-pack reflog remote repack replace rerere reset restore revert rm send-pack shortlog show show-branch show-index show-ref sparse-checkout stash status stripspace switch symbolic-ref tag update-index update-ref update-server-info upload-pack verify-commit verify-pack verify-tag version whatchanged worktree write-tree \n");
        }
    } else if (std.mem.eql(u8, command, "--exec-path")) {
        // Output the directory containing this executable
        const self_exe = std.fs.selfExePathAlloc(allocator) catch {
            try platform_impl.writeStdout("/usr/lib/git-core\n");
            return;
        };
        defer allocator.free(self_exe);
        const dir = std.fs.path.dirname(self_exe) orelse "/usr/lib/git-core";
        const output = try std.fmt.allocPrint(allocator, "{s}\n", .{dir});
        defer allocator.free(output);
        try platform_impl.writeStdout(output);
    } else if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try cmd_misc.cmdVersion(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "--version-info")) {
        if (version_mod.getFullVersionInfo(allocator)) |version_info| {
            defer allocator.free(version_info);
            try platform_impl.writeStdout(version_info);
        } else |_| {
            try platform_impl.writeStdout("ziggit version 0.1.2\nError retrieving version details.\n");
        }
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try cmd_misc.showUsage(&platform_impl);
    } else if (std.mem.eql(u8, command, "help")) {
        try cmd_misc.showUsage(&platform_impl);
    } else if (std.mem.eql(u8, command, "count-objects")) {
        try cmd_count_objects.nativeCmdCountObjects(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "show-ref")) {
        try cmd_show_ref.nativeCmdShowRef(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "for-each-ref")) {
        try cmd_for_each_ref.nativeCmdForEachRef(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "verify-pack")) {
        try cmd_verify_pack.nativeCmdVerifyPack(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "update-server-info")) {
        try cmd_update_server_info.nativeCmdUpdateServerInfo(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "mktree")) {
        try cmd_mktree.nativeCmdMktree(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "mktag")) {
        try cmd_mktag.nativeCmdMktag(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "name-rev")) {
        try cmd_name_rev.nativeCmdNameRev(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "fsck")) {
        try cmd_fsck.nativeCmdFsck(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "gc")) {
        try cmd_gc.nativeCmdGc(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "prune")) {
        try cmd_prune.nativeCmdPrune(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "repack")) {
        try cmd_repack.nativeCmdRepack(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "pack-refs")) {
        try cmd_pack_refs.nativeCmdPackRefs(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "pack-objects")) {
        try cmd_pack.nativeCmdPackObjects(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "index-pack")) {
        try cmd_pack.nativeCmdIndexPack(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "reflog")) {
        try cmd_reflog.nativeCmdReflog(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "clean")) {
        try cmd_clean.nativeCmdClean(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "merge-base")) {
        try cmd_merge_base.nativeCmdMergeBase(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "unpack-objects")) {
        try cmd_pack.nativeCmdUnpackObjects(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "diff-tree")) {
        try cmd_diff_core.nativeCmdDiffTree(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "diff-index")) {
        try cmd_diff_core.nativeCmdDiffIndex(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "var")) {
        try cmd_var.nativeCmdVar(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "show-index")) {
        try cmd_show_index.nativeCmdShowIndex(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "prune-packed")) {
        try cmd_prune.nativeCmdPrunePacked(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "verify-commit")) {
        try cmd_verify.nativeCmdVerifyCommit(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "verify-tag")) {
        try cmd_verify.nativeCmdVerifyTag(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "mv")) {
        try cmd_mv.nativeCmdMv(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "stash")) {
        try cmd_stash.nativeCmdStash(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "apply")) {
        try cmd_apply.nativeCmdApply(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "column")) {
        try cmd_column.nativeCmdColumn(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "check-ignore")) {
        try cmd_check_ignore.nativeCmdCheckIgnore(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "check-attr")) {
        try cmd_check_attr.nativeCmdCheckAttr(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "switch")) {
        try cmd_checkout.cmdSwitch(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "restore")) {
        try cmd_checkout.cmdRestore(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "worktree")) {
        try cmd_checkout.cmdWorktree(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "stripspace")) {
        try cmd_stripspace.cmdStripspace(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "show-branch")) {
        try cmd_show_branch.nativeCmdShowBranch(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "checkout-index")) {
        try cmd_checkout.cmdCheckoutIndex(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "blame") or std.mem.eql(u8, command, "annotate")) {
        try @import("git/blame_cmd.zig").cmdBlame(allocator, &args_iter, &platform_impl, std.mem.eql(u8, command, "annotate"));
    } else if (std.mem.eql(u8, command, "grep")) {
        try @import("git/grep_cmd.zig").cmdGrep(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "ls-remote")) {
        try cmd_ls_remote.nativeCmdLsRemote(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "last-modified")) {
        try cmd_last_modified.cmdLastModified(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "daemon")) {
        try cmd_daemon.cmdDaemon(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "upload-pack") or std.mem.eql(u8, command, "receive-pack") or std.mem.eql(u8, command, "send-pack")) {
        const emsg = try std.fmt.allocPrint(allocator, "fatal: {s} not yet implemented in ziggit\n", .{command});
        defer allocator.free(emsg);
        try platform_impl.writeStderr(emsg);
        std.process.exit(128);
    } else if (std.mem.eql(u8, command, "check-ref-format")) {
        try cmd_check_ref_format.cmdCheckRefFormat(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "refs")) {
        try cmd_refs.cmdRefs(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "rebase")) {
        try rebase_cmd.nativeCmdRebase(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "cherry-pick")) {
        try cherry_pick_mod.nativeCmdCherryPick(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "revert")) {
        try cmd_misc.nativeCmdRevert(allocator, all_original_args.items, command_index, &platform_impl);
    } else if (std.mem.eql(u8, command, "web--browse")) {
        try cmd_web_browse.cmdWebBrowse(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "fast-import")) {
        try cmd_fast_import.cmdFastImport(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "fast-export")) {
        try cmd_fast_export.cmdFastExport(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "notes")) {
        try cmd_notes.cmdNotes(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "format-patch")) {
        try diff_cmd_mod.cmdFormatPatch(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "whatchanged")) {
        try diff_cmd_mod.cmdWhatchanged(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "for-each-repo")) {
        try cmd_misc.cmdForEachRepo(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "bugreport")) {
        try cmd_misc.cmdBugreport(allocator, &args_iter, &platform_impl);
    } else if (std.mem.eql(u8, command, "diagnose")) {
        try cmd_misc.cmdDiagnose(allocator, &args_iter, &platform_impl);
    }
}



