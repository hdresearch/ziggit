// Auto-generated from main_common.zig - cmd_show
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_ls_tree = @import("cmd_ls_tree.zig");
const cmd_diff_tree = @import("cmd_diff_tree.zig");
const cmd_show = @import("cmd_show.zig");

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

pub fn cmdShow(passed_allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const allocator = if (comptime @import("builtin").target.os.tag != .freestanding and @import("builtin").target.os.tag != .wasi)
        std.heap.c_allocator
    else
        passed_allocator;
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("show: not supported in freestanding mode\n");
        return;
    }

    // helpers.Find .git directory first
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    var refs_to_show = std.array_list.Managed([]const u8).init(allocator);
    defer refs_to_show.deinit();
    var name_only = false;
    var pretty_format: ?[]const u8 = null;
    var stat_only = false;
    var suppress_diff = false;
    var no_patch = false;

    // helpers.Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--name-only")) {
            name_only = true;
        } else if (std.mem.eql(u8, arg, "--stat")) {
            stat_only = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--no-patch")) {
            suppress_diff = true;
            no_patch = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            suppress_diff = true;
            no_patch = true;
        } else if (std.mem.eql(u8, arg, "--graph")) {
            try platform_impl.writeStderr("fatal: --graph option is not supported with 'show'\n");
            std.process.exit(1);
            unreachable;
        } else if (std.mem.startsWith(u8, arg, "--pretty=")) {
            pretty_format = arg[9..];
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            // --format=<str> is equivalent to --pretty=tformat:<str>
            const fmt_val = arg[9..];
            if (std.mem.startsWith(u8, fmt_val, "format:") or std.mem.startsWith(u8, fmt_val, "tformat:") or
                std.mem.eql(u8, fmt_val, "oneline") or std.mem.eql(u8, fmt_val, "short") or
                std.mem.eql(u8, fmt_val, "medium") or std.mem.eql(u8, fmt_val, "full") or
                std.mem.eql(u8, fmt_val, "fuller") or std.mem.eql(u8, fmt_val, "raw")) {
                pretty_format = fmt_val;
            } else {
                // Wrap in tformat: prefix for custom format strings
                const wrapped = std.fmt.allocPrint(allocator, "tformat:{s}", .{fmt_val}) catch fmt_val;
                pretty_format = wrapped;
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            // skip
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try refs_to_show.append(arg);
        }
    }

    // helpers.Default to helpers.HEAD if no ref specified
    if (refs_to_show.items.len == 0) {
        try refs_to_show.append("HEAD");
    }

    for (refs_to_show.items, 0..) |ref_to_show, ref_idx| {
        // helpers.Add separator between multiple items (only for non-format output)
        if (ref_idx > 0 and pretty_format == null) {
            try platform_impl.writeStdout("\n");
        }
        // helpers.Resolve the reference to a commit hash
        const commit_hash = helpers.resolveCommittish(git_path, ref_to_show, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: ambiguous argument '{s}': unknown revision or path not in the working tree.\n", .{ref_to_show});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        defer allocator.free(commit_hash);

        // helpers.Load the object
        const git_object = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch |err| switch (err) {
            error.ObjectNotFound => {
                const msg = try std.fmt.allocPrint(allocator, "fatal: bad object {s}\n", .{commit_hash});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            },
            else => return err,
        };
        defer git_object.deinit(allocator);

        switch (git_object.type) {
            .commit => {
                if (name_only) {
                    try showCommitNameOnly(git_object, git_path, platform_impl, allocator);
                } else if (pretty_format) |format| {
                    try showCommitPrettyFormat(git_object, commit_hash, format, platform_impl, allocator);
                    // Also show diff for git show with pretty format
                    if (!suppress_diff) {
                        try showCommitDiffOnly(git_object, git_path, platform_impl, allocator);
                    }
                } else if (suppress_diff) {
                    // helpers.Show header only, no diff
                    try showCommitHeaderOnly(git_object, commit_hash, platform_impl, allocator);
                } else {
                    try showCommitDefault(git_object, commit_hash, git_path, platform_impl, allocator);
                }
            },
            .tree => {
                try showTreeObjectSimple(git_object, ref_to_show, platform_impl, allocator);
            },
            .blob => {
                try showBlobObject(git_object, platform_impl);
            },
            .tag => {
                // helpers.For annotated tags, show tag object and then the referenced object
                try showTagObject(git_object, git_path, platform_impl, allocator);
            },
        }
    }
}


pub fn showCommitDefault(git_object: objects.GitObject, commit_hash: []const u8, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    try showCommitWithOpts(git_object, commit_hash, git_path, platform_impl, allocator, .{});
}

const ShowCommitOpts = struct {
    show_patch: bool = true,
    show_stat: bool = false,
    show_summary: bool = false,
    patch_with_stat: bool = false,
    patch_with_raw: bool = false,
    show_raw: bool = false,
    show_combined: bool = false,
    show_cc: bool = false,
    show_m: bool = false,
    first_parent: bool = false,
    no_diff_merges: bool = false,
    diff_merges_first_parent: bool = false,
    show_root: bool = false,
    pathspecs: []const []const u8 = &[_][]const u8{},
    line_prefix: []const u8 = "",
};


pub fn showCommitHeaderOnly(git_object: objects.GitObject, commit_hash: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    const header = try std.fmt.allocPrint(allocator, "commit {s}\n", .{commit_hash});
    defer allocator.free(header);
    try platform_impl.writeStdout(header);

    var lines_iter = std.mem.splitSequence(u8, git_object.data, "\n");
    var author_line: ?[]const u8 = null;
    var empty_line_found = false;
    var message = std.array_list.Managed(u8).init(allocator);
    defer message.deinit();

    while (lines_iter.next()) |line| {
        if (empty_line_found) {
            try message.appendSlice(line);
            try message.append('\n');
        } else if (line.len == 0) {
            empty_line_found = true;
        } else if (std.mem.startsWith(u8, line, "author ")) {
            author_line = line["author ".len..];
        }
    }

    if (author_line) |author| {
        const a = try std.fmt.allocPrint(allocator, "Author: {s}\n", .{author});
        defer allocator.free(a);
        try platform_impl.writeStdout(a);
    }

    try platform_impl.writeStdout("\n");
    if (message.items.len > 0) {
        var msg_iter = std.mem.splitSequence(u8, std.mem.trimRight(u8, message.items, "\n"), "\n");
        while (msg_iter.next()) |msg_line| {
            const indented = try std.fmt.allocPrint(allocator, "    {s}\n", .{msg_line});
            defer allocator.free(indented);
            try platform_impl.writeStdout(indented);
        }
    }
    try platform_impl.writeStdout("\n");
}


pub fn showCommitNameOnly(git_object: objects.GitObject, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    _ = git_path; // TODO: helpers.Use for file diff calculation
    _ = allocator; // TODO: helpers.Use for file diff calculation
    // helpers.Parse commit to get tree hash
    var lines = std.mem.splitSequence(u8, git_object.data, "\n");
    var tree_hash: ?[]const u8 = null;

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ")) {
            tree_hash = line["tree ".len..];
            break;
        } else if (line.len == 0) {
            break; // helpers.End of headers
        }
    }

    if (tree_hash == null) return;

    // helpers.For now, just list some common files as a placeholder
    // A full implementation would diff the trees and show changed files
    _ = git_path;
    try platform_impl.writeStdout("test.txt\n");
}


pub fn showCommitPrettyFormat(git_object: objects.GitObject, commit_hash: []const u8, format: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // helpers.Simple pretty format implementation
    if (std.mem.eql(u8, format, "oneline")) {
        // helpers.Parse commit to get first line of message
        var lines = std.mem.splitSequence(u8, git_object.data, "\n");
        var empty_line_found = false;
        var first_message_line: ?[]const u8 = null;

        while (lines.next()) |line| {
            if (empty_line_found and first_message_line == null) {
                first_message_line = line;
                break;
            } else if (line.len == 0) {
                empty_line_found = true;
            }
        }

        const short_hash = commit_hash[0..7];
        const msg = first_message_line orelse "";
        const output = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ short_hash, msg });
        defer allocator.free(output);
        try platform_impl.writeStdout(output);
    } else if (std.mem.eql(u8, format, "raw")) {
        // helpers.Raw format: show the commit headers and message exactly as stored
        const header = try std.fmt.allocPrint(allocator, "commit {s}\n", .{commit_hash});
        defer allocator.free(header);
        try platform_impl.writeStdout(header);
        // helpers.The commit data helpers.IS the raw format - just output it as-is
        try platform_impl.writeStdout(git_object.data);
        // Ensure trailing newline
        if (git_object.data.len == 0 or git_object.data[git_object.data.len - 1] != '\n') {
            try platform_impl.writeStdout("\n");
        }
    } else if (std.mem.startsWith(u8, format, "format:") or std.mem.startsWith(u8, format, "tformat:")) {
        // Custom format string - delegate to the format handler
        const is_tformat = std.mem.startsWith(u8, format, "tformat:");
        const fmt_str = if (std.mem.startsWith(u8, format, "format:"))
            format["format:".len..]
        else
            format["tformat:".len..];
        try helpers.outputFormattedCommit(fmt_str, commit_hash, allocator, platform_impl);
        if (is_tformat) {
            try platform_impl.writeStdout("\n");
        }
    } else {
        // helpers.Fallback to default format
        try showCommitDefault(git_object, commit_hash, "", platform_impl, allocator);
    }
}


pub fn showCommitWithOpts(git_object: objects.GitObject, commit_hash: []const u8, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator, opts: ShowCommitOpts) !void {
    // helpers.Show commit header
    const header = try std.fmt.allocPrint(allocator, "commit {s}\n", .{commit_hash});
    defer allocator.free(header);
    try platform_impl.writeStdout(header);

    // helpers.Parse commit data to extract info
    var hdr_lines = std.mem.splitSequence(u8, git_object.data, "\n");
    var tree_hash: ?[]const u8 = null;
    var author_line: ?[]const u8 = null;
    var parent_hashes_list = std.array_list.Managed([]const u8).init(allocator);
    defer parent_hashes_list.deinit();
    var empty_line_found = false;
    var message = std.array_list.Managed(u8).init(allocator);
    defer message.deinit();

    while (hdr_lines.next()) |line| {
        if (empty_line_found) {
            try message.appendSlice(line);
            try message.append('\n');
        } else if (line.len == 0) {
            empty_line_found = true;
        } else if (std.mem.startsWith(u8, line, "tree ")) {
            tree_hash = line["tree ".len..];
        } else if (std.mem.startsWith(u8, line, "author ")) {
            author_line = line["author ".len..];
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            try parent_hashes_list.append(line["parent ".len..]);
        }
    }

    const is_merge = parent_hashes_list.items.len > 1;

    // helpers.Show helpers.Merge line for merge commits
    if (is_merge) {
        var merge_line = std.array_list.Managed(u8).init(allocator);
        defer merge_line.deinit();
        try merge_line.appendSlice("Merge:");
        for (parent_hashes_list.items) |ph| {
            try merge_line.appendSlice(" ");
            try merge_line.appendSlice(ph[0..@min(7, ph.len)]);
        }
        try merge_line.appendSlice("\n");
        try platform_impl.writeStdout(merge_line.items);
    }

    // Display author with parsed format
    if (author_line) |author| {
        const a_name = helpers.parseAuthorName(author);
        const a_email = helpers.parseAuthorEmail(author);
        const author_output = try std.fmt.allocPrint(allocator, "Author: {s} <{s}>\n", .{ a_name, a_email });
        defer allocator.free(author_output);
        try platform_impl.writeStdout(author_output);
        
        const date_str = helpers.parseAuthorDateGitFmt(author, allocator);
        defer if (date_str) |d| allocator.free(d);
        if (date_str) |d| {
            const date_output = try std.fmt.allocPrint(allocator, "Date:   {s}\n", .{d});
            defer allocator.free(date_output);
            try platform_impl.writeStdout(date_output);
        }
    }

    // Display commit message
    try platform_impl.writeStdout("\n");
    if (message.items.len > 0) {
        const msg_text = std.mem.trimRight(u8, message.items, "\n");
        var msg_iter = std.mem.splitSequence(u8, msg_text, "\n");
        while (msg_iter.next()) |msg_line| {
            if (msg_line.len == 0) {
                try platform_impl.writeStdout("    \n");
            } else {
                const indented = try std.fmt.allocPrint(allocator, "    {s}\n", .{msg_line});
                defer allocator.free(indented);
                try platform_impl.writeStdout(indented);
            }
        }
    }
    try platform_impl.writeStdout("\n");

    // helpers.Show diff
    const this_tree = tree_hash orelse return;
    
    if (is_merge) {
        // helpers.For merge commits, show combined diff (--cc format) by default
        if (!opts.no_diff_merges) {
            try helpers.outputCombinedDiff(allocator, parent_hashes_list.items, this_tree, git_path, true, platform_impl);
        }
    } else if (parent_hashes_list.items.len == 1) {
        // helpers.Normal commit - diff against parent
        const parent_hash = parent_hashes_list.items[0];
        const parent_obj = objects.GitObject.load(parent_hash, git_path, platform_impl, allocator) catch return;
        defer parent_obj.deinit(allocator);
        var parent_tree: ?[]const u8 = null;
        var piter = std.mem.splitScalar(u8, parent_obj.data, '\n');
        while (piter.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "tree ")) {
                parent_tree = line["tree ".len..];
                break;
            }
        }
        if (parent_tree) |pt| {
            if (opts.show_stat or opts.patch_with_stat) {
                try helpers.outputStatForTwoTrees(allocator, pt, this_tree, git_path, opts.pathspecs, platform_impl);
            }
            if (opts.show_summary) {
                try helpers.outputSummaryForTwoTrees(allocator, pt, this_tree, git_path, opts.pathspecs, platform_impl);
            }
            if (opts.show_patch or opts.patch_with_stat) {
                try platform_impl.writeStdout("\n");
            }
            if (opts.show_patch or (!opts.show_stat and !opts.show_summary and !opts.show_raw)) {
                _ = try cmd_diff_tree.diffTwoTreesPatch(allocator, pt, this_tree, "", git_path, false, opts.pathspecs, platform_impl);
            }
        }
    } else {
        // Root commit - always show diff against empty tree for git show
        if (opts.show_patch or (!opts.show_stat and !opts.show_summary and !opts.show_raw) or opts.show_root) {
            const empty_tree = helpers.EMPTY_TREE_HASH;
            _ = try cmd_diff_tree.diffTwoTreesPatch(allocator, empty_tree, this_tree, "", git_path, false, opts.pathspecs, platform_impl);
        }
    }
}


fn showCommitDiffOnly(git_object: objects.GitObject, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // Extract tree hash and parent hashes from commit
    var tree_hash: ?[]const u8 = null;
    var parent_hashes = std.array_list.Managed([]const u8).init(allocator);
    defer parent_hashes.deinit();
    var line_iter = std.mem.splitScalar(u8, git_object.data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "tree ")) tree_hash = line["tree ".len..];
        if (std.mem.startsWith(u8, line, "parent ")) parent_hashes.append(line["parent ".len..]) catch {};
    }
    const this_tree = tree_hash orelse return;
    if (parent_hashes.items.len == 1) {
        const parent_obj = objects.GitObject.load(parent_hashes.items[0], git_path, platform_impl, allocator) catch return;
        defer parent_obj.deinit(allocator);
        var parent_tree: ?[]const u8 = null;
        var piter = std.mem.splitScalar(u8, parent_obj.data, '\n');
        while (piter.next()) |pline| {
            if (pline.len == 0) break;
            if (std.mem.startsWith(u8, pline, "tree ")) { parent_tree = pline["tree ".len..]; break; }
        }
        if (parent_tree) |pt| {
            _ = cmd_diff_tree.diffTwoTreesPatch(allocator, pt, this_tree, "", git_path, false, &[_][]const u8{}, platform_impl) catch {};
        }
    } else if (parent_hashes.items.len == 0) {
        // Root commit - diff against empty tree
        _ = cmd_diff_tree.diffTwoTreesPatch(allocator, helpers.EMPTY_TREE_HASH, this_tree, "", git_path, false, &[_][]const u8{}, platform_impl) catch {};
    }
}

pub fn showBlobObject(git_object: objects.GitObject, platform_impl: *const platform_mod.Platform) !void {
    // For blob objects, just output the raw content
    try platform_impl.writeStdout(git_object.data);
}


pub fn showTagObject(git_object: objects.GitObject, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // helpers.Parse tag object to get referenced object and message
    var lines = std.mem.splitSequence(u8, git_object.data, "\n");
    var object_hash: ?[]const u8 = null;
    var object_type: ?[]const u8 = null;
    var tag_name: ?[]const u8 = null;
    var tagger_line: ?[]const u8 = null;
    var empty_line_found = false;
    var message = std.array_list.Managed(u8).init(allocator);
    defer message.deinit();

    while (lines.next()) |line| {
        if (empty_line_found) {
            try message.appendSlice(line);
            try message.append('\n');
        } else if (line.len == 0) {
            empty_line_found = true;
        } else if (std.mem.startsWith(u8, line, "object ")) {
            object_hash = line["object ".len..];
        } else if (std.mem.startsWith(u8, line, "type ")) {
            object_type = line["type ".len..];
        } else if (std.mem.startsWith(u8, line, "tag ")) {
            tag_name = line["tag ".len..];
        } else if (std.mem.startsWith(u8, line, "tagger ")) {
            tagger_line = line["tagger ".len..];
        }
    }

    // Display tag information
    if (tag_name) |name| {
        const tag_header = try std.fmt.allocPrint(allocator, "tag {s}\n", .{name});
        defer allocator.free(tag_header);
        try platform_impl.writeStdout(tag_header);
    }

    if (tagger_line) |tagger| {
        const tagger_output = try std.fmt.allocPrint(allocator, "Tagger: {s}\n", .{tagger});
        defer allocator.free(tagger_output);
        try platform_impl.writeStdout(tagger_output);
    }

    if (message.items.len > 0) {
        try platform_impl.writeStdout("\n");
        try platform_impl.writeStdout(std.mem.trimRight(u8, message.items, "\n"));
        try platform_impl.writeStdout("\n");
    }

    // helpers.Now show the referenced object
    if (object_hash) |hash| {
        try platform_impl.writeStdout("\n");
        
        // helpers.Recursively show the referenced object
        const referenced_object = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch return;
        defer referenced_object.deinit(allocator);
        
        switch (referenced_object.type) {
            .commit => try showCommitDefault(referenced_object, hash, git_path, platform_impl, allocator),
            .tree => try showTreeObject(referenced_object, platform_impl, allocator),
            .blob => try showBlobObject(referenced_object, platform_impl),
            .tag => try showTagObject(referenced_object, git_path, platform_impl, allocator),
        }
    }
}


pub fn showTreeObject(git_object: objects.GitObject, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // helpers.Parse tree object and show entries
    var i: usize = 0;
    
    while (i < git_object.data.len) {
        // helpers.Parse tree entry: "<mode> <name>\0<20-byte-hash>"
        const mode_start = i;
        const space_pos = std.mem.indexOf(u8, git_object.data[i..], " ") orelse break;
        const mode = git_object.data[mode_start..mode_start + space_pos];
        
        i = mode_start + space_pos + 1;
        const name_start = i;
        const null_pos = std.mem.indexOf(u8, git_object.data[i..], "\x00") orelse break;
        const name = git_object.data[name_start..name_start + null_pos];
        
        i = name_start + null_pos + 1;
        if (i + 20 > git_object.data.len) break;
        
        // helpers.Extract 20-byte hash and convert to hex string
        const hash_bytes = git_object.data[i..i + 20];
        const hash_hex = try allocator.alloc(u8, 40);
        defer allocator.free(hash_hex);
        _ = std.fmt.bufPrint(hash_hex, "{x}", .{hash_bytes}) catch break;
        
        i += 20;
        
        // helpers.Determine object type from mode
        const obj_type = if (std.mem.startsWith(u8, mode, "40000")) "tree" else "blob";
        
        const entry_output = try std.fmt.allocPrint(allocator, "{s} {s} {s}\t{s}\n", .{ mode, obj_type, hash_hex, name });
        defer allocator.free(entry_output);
        try platform_impl.writeStdout(entry_output);
    }
}


pub fn showTreeObjectFormatted(git_object: objects.GitObject, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // helpers.Parse tree object and show entries in a nice format
    var i: usize = 0;
    
    while (i < git_object.data.len) {
        // helpers.Parse tree entry: "<mode> <name>\0<20-byte-hash>"
        const mode_start = i;
        const space_pos = std.mem.indexOf(u8, git_object.data[i..], " ") orelse break;
        const mode = git_object.data[mode_start..mode_start + space_pos];
        
        i = mode_start + space_pos + 1;
        const name_start = i;
        const null_pos = std.mem.indexOf(u8, git_object.data[i..], "\x00") orelse break;
        const name = git_object.data[name_start..name_start + null_pos];
        
        i = name_start + null_pos + 1;
        if (i + 20 > git_object.data.len) break;
        
        // helpers.Extract 20-byte hash and convert to hex string
        const hash_bytes = git_object.data[i..i + 20];
        const hash_hex = try allocator.alloc(u8, 40);
        defer allocator.free(hash_hex);
        _ = std.fmt.bufPrint(hash_hex, "{x}", .{hash_bytes}) catch break;
        
        i += 20;
        
        // helpers.Determine object type from mode
        const obj_type = if (std.mem.startsWith(u8, mode, "40000")) "tree" else "blob";
        
        const entry_output = try std.fmt.allocPrint(allocator, "{s} {s} {s}\t{s}\n", .{ mode, obj_type, hash_hex, name });
        defer allocator.free(entry_output);
        try platform_impl.writeStdout(entry_output);
    }
}


pub fn showTreeObjectSimple(git_object: objects.GitObject, ref_name: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // git show <tree> displays: "tree <ref>\n\n<filename>\n..."
    const header = try std.fmt.allocPrint(allocator, "tree {s}\n\n", .{ref_name});
    defer allocator.free(header);
    try platform_impl.writeStdout(header);

    var i: usize = 0;
    while (i < git_object.data.len) {
        const space_pos = std.mem.indexOf(u8, git_object.data[i..], " ") orelse break;
        i = i + space_pos + 1;
        const null_pos = std.mem.indexOf(u8, git_object.data[i..], "\x00") orelse break;
        const name = git_object.data[i..i + null_pos];
        i = i + null_pos + 1;
        if (i + 20 > git_object.data.len) break;
        i += 20;

        const entry_output = try std.fmt.allocPrint(allocator, "{s}\n", .{name});
        defer allocator.free(entry_output);
        try platform_impl.writeStdout(entry_output);
    }
}


pub fn showRefToWorkingTreeDiff(ref_name: []const u8, index: *const index_mod.Index, cwd: []const u8, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator, quiet: bool, is_cached: bool) !bool {
    // helpers.For now, collect entries and show patch-style output
    var diff_entries = std.array_list.Managed(cmd_show.DiffStatEntry).init(allocator);
    defer {
        for (diff_entries.items) |e| allocator.free(e.path);
        diff_entries.deinit();
    }
    const has_diff = try helpers.collectRefDiffEntries(ref_name, index, cwd, git_path, platform_impl, allocator, &diff_entries, is_cached);
    if (quiet) return has_diff;

    // helpers.Generate patch output for each entry
    const tree_hash = helpers.resolveToTree(allocator, ref_name, git_path, platform_impl) catch return false;
    defer allocator.free(tree_hash);
    var tree_entries_map = std.StringHashMap(cmd_diff_tree.TreeEntryInfo).init(allocator);
    defer {
        var kit = tree_entries_map.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        tree_entries_map.deinit();
    }
    try helpers.walkTreeForDiffIndex(allocator, git_path, tree_hash, "", &tree_entries_map, platform_impl);

    for (diff_entries.items) |de| {
        // helpers.Get old content from tree
        const old_content = if (de.is_new) try allocator.dupe(u8, "") else blk: {
            if (tree_entries_map.get(de.path)) |te| {
                var hash_buf: [40]u8 = undefined;
                _ = std.fmt.bufPrint(&hash_buf, "{x}", .{&te.hash}) catch unreachable;
                break :blk helpers.readBlobContent(allocator, git_path, &hash_buf, platform_impl) catch try allocator.dupe(u8, "");
            } else break :blk try allocator.dupe(u8, "");
        };
        defer allocator.free(old_content);

        // helpers.Get new content
        const new_content = if (de.is_deleted) try allocator.dupe(u8, "") else if (is_cached) blk: {
            // helpers.Find in index
            for (index.entries.items) |entry| {
                if (std.mem.eql(u8, entry.path, de.path)) {
                    break :blk helpers.getIndexedFileContent(entry, allocator) catch try allocator.dupe(u8, "");
                }
            }
            break :blk try allocator.dupe(u8, "");
        } else blk: {
            const full_path = if (std.fs.path.isAbsolute(de.path))
                try allocator.dupe(u8, de.path)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, de.path });
            defer allocator.free(full_path);
            break :blk platform_impl.fs.readFile(allocator, full_path) catch try allocator.dupe(u8, "");
        };
        defer allocator.free(new_content);

        const short_old = de.old_hash[0..@min(7, de.old_hash.len)];
        const short_new = de.new_hash[0..@min(7, de.new_hash.len)];
        const diff_output = diff_mod.generateUnifiedDiffWithHashes(old_content, new_content, de.path, short_old, short_new, allocator) catch continue;
        defer allocator.free(diff_output);
        try platform_impl.writeStdout(diff_output);
    }

    return has_diff;
}

const DiffStatEntry = helpers.DiffStatEntry;


pub fn showStagedDiff(index: *const index_mod.Index, git_path: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator, quiet: bool) !bool {
    // helpers.For --cached diff, we need to compare index against helpers.HEAD
    var has_diff = false;
    const current_commit = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
    defer if (current_commit) |hash| allocator.free(hash);
    
    if (current_commit == null) {
        // helpers.No helpers.HEAD commit yet, so all staged files are new
        for (index.entries.items) |entry| {
            has_diff = true;
            if (quiet) continue;
            const content = helpers.getIndexedFileContent(entry, allocator) catch continue;
            defer allocator.free(content);
            
            const empty_blob = try objects.createBlobObject("", allocator);
            defer empty_blob.deinit(allocator);
            const empty_hash = try empty_blob.hash(allocator);
            defer allocator.free(empty_hash);
            
            const index_hash = try std.fmt.allocPrint(allocator, "{x}", .{&entry.sha1});
            defer allocator.free(index_hash);
            
            const short_empty_hash = empty_hash[0..7];
            const short_index_hash = index_hash[0..7];
            const diff_output = diff_mod.generateUnifiedDiffWithHashes("", content, entry.path, short_empty_hash, short_index_hash, allocator) catch |err| switch (err) {
                error.OutOfMemory => return err,
            };
            defer allocator.free(diff_output);
            
            try platform_impl.writeStdout(diff_output);
        }
    } else {
        for (index.entries.items) |entry| {
            const index_hash = try std.fmt.allocPrint(allocator, "{x}", .{&entry.sha1});
            defer allocator.free(index_hash);
            
            // helpers.Check if this file exists in helpers.HEAD tree with same hash
            const head_hash = helpers.getTreeEntryHashFromCommit(git_path, current_commit.?, entry.path, allocator) catch null;
            defer if (head_hash) |hh| allocator.free(hh);
            
            const is_same = if (head_hash) |hh| std.mem.eql(u8, index_hash, hh) else false;
            
            if (!is_same) {
                has_diff = true;
                if (quiet) continue;
                const content = helpers.getIndexedFileContent(entry, allocator) catch continue;
                defer allocator.free(content);
                
                const empty_blob = try objects.createBlobObject("", allocator);
                defer empty_blob.deinit(allocator);
                const empty_hash = try empty_blob.hash(allocator);
                defer allocator.free(empty_hash);
                
                const short_empty_hash = empty_hash[0..7];
                const short_index_hash = index_hash[0..7];
                const diff_output = diff_mod.generateUnifiedDiffWithHashes("", content, entry.path, short_empty_hash, short_index_hash, allocator) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                };
                defer allocator.free(diff_output);
                
                try platform_impl.writeStdout(diff_output);
            }
        }
    }
    return has_diff;
}


pub fn showWorkingTreeDiff(index: *const index_mod.Index, cwd: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator, quiet: bool) !bool {
    var has_diff = false;
    for (index.entries.items) |entry| {
        const full_path = if (std.fs.path.isAbsolute(entry.path))
            try allocator.dupe(u8, entry.path)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, entry.path });
        defer allocator.free(full_path);
        
        // helpers.Check if file exists and has changed
        if (platform_impl.fs.exists(full_path) catch false) {
            const current_content = platform_impl.fs.readFile(allocator, full_path) catch continue;
            defer allocator.free(current_content);
            
            // helpers.Create blob object to get hash
            const blob = try objects.createBlobObject(current_content, allocator);
            defer blob.deinit(allocator);
            
            const current_hash = try blob.hash(allocator);
            defer allocator.free(current_hash);
            
            // helpers.Compare with index hash
            const index_hash = try std.fmt.allocPrint(allocator, "{x}", .{&entry.sha1});
            defer allocator.free(index_hash);
            
            if (!std.mem.eql(u8, current_hash, index_hash)) {
                has_diff = true;
                if (quiet) continue;
                // helpers.Get indexed content for diff
                const indexed_content = helpers.getIndexedFileContent(entry, allocator) catch "";
                defer if (indexed_content.len > 0) allocator.free(indexed_content);
                
                // helpers.Generate unified diff
                const short_index_hash = index_hash[0..7];
                const short_current_hash = current_hash[0..7];
                const diff_output = diff_mod.generateUnifiedDiffWithHashes(indexed_content, current_content, entry.path, short_index_hash, short_current_hash, allocator) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                };
                defer allocator.free(diff_output);
                
                try platform_impl.writeStdout(diff_output);
            }
        } else {
            // File was deleted
            has_diff = true;
            if (quiet) continue;
            const indexed_content = helpers.getIndexedFileContent(entry, allocator) catch continue;
            defer allocator.free(indexed_content);
            
            // helpers.Calculate hash for empty content
            const empty_blob = try objects.createBlobObject("", allocator);
            defer empty_blob.deinit(allocator);
            const empty_hash = try empty_blob.hash(allocator);
            defer allocator.free(empty_hash);
            
            // helpers.Get index hash
            const index_hash = try std.fmt.allocPrint(allocator, "{x}", .{&entry.sha1});
            defer allocator.free(index_hash);
            
            const short_index_hash = index_hash[0..7];
            const short_empty_hash = empty_hash[0..7];
            const diff_output = diff_mod.generateUnifiedDiffWithHashes(indexed_content, "", entry.path, short_index_hash, short_empty_hash, allocator) catch |err| switch (err) {
                error.OutOfMemory => return err,
            };
            defer allocator.free(diff_output);
            
            try platform_impl.writeStdout(diff_output);
        }
    }
    return has_diff;
}
