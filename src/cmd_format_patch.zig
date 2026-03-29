// Auto-generated from main_common.zig - cmd_format_patch
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

pub fn cmdFormatPatch(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // helpers.Parse arguments
    var rev_range: ?[]const u8 = null;
    var stdout_mode = false;
    var numbered = false;
    var subject_prefix: []const u8 = "PATCH";
    var start_number: usize = 1;
    var signoff = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--stdout")) {
            stdout_mode = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--signoff")) {
            signoff = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--numbered")) {
            numbered = true;
        } else if (std.mem.eql(u8, arg, "--cover-letter")) {
            // cover_letter = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--in-reply-to") or
                   std.mem.eql(u8, arg, "--signature") or std.mem.eql(u8, arg, "--start-number")) {
            _ = args.next(); // consume value
        } else if (std.mem.startsWith(u8, arg, "--subject-prefix=")) {
            subject_prefix = arg["--subject-prefix=".len..];
        } else if (std.mem.startsWith(u8, arg, "--start-number=")) {
            start_number = std.fmt.parseInt(usize, arg["--start-number=".len..], 10) catch 1;
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and std.ascii.isDigit(arg[1])) {
            // -N means last N commits from helpers.HEAD
            const count = std.fmt.parseInt(usize, arg[1..], 10) catch 1;
            const range = std.fmt.allocPrint(allocator, "HEAD~{d}..HEAD", .{count}) catch null;
            if (range) |r| rev_range = r;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            rev_range = arg;
        }
        // Silently ignore other flags
    }

    if (rev_range == null) {
        try platform_impl.writeStderr("fatal: no revision range specified\n");
        std.process.exit(128);
    }

    // helpers.Get the list of commits in the range
    const range = rev_range.?;
    
    // helpers.Parse range like "A..B" or "A...B" or just "A" (meaning A..HEAD)
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

    const base_hash = helpers.resolveRevision(git_path, base_rev, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: bad revision range\n");
        std.process.exit(128);
    };
    defer allocator.free(base_hash);
    
    const tip_hash = helpers.resolveRevision(git_path, tip_rev, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: bad revision range\n");
        std.process.exit(128);
    };
    defer allocator.free(tip_hash);

    // helpers.Walk from tip back to base, collecting commits
    var commit_list = std.ArrayList([]const u8).init(allocator);
    defer {
        for (commit_list.items) |h| allocator.free(h);
        commit_list.deinit();
    }

    var current = try allocator.dupe(u8, tip_hash);
    var walk_count: usize = 0;
    while (walk_count < 1000) : (walk_count += 1) {
        if (std.mem.eql(u8, current, base_hash)) {
            allocator.free(current);
            break;
        }
        try commit_list.append(current);
        
        // helpers.Get parent
        const obj = objects.GitObject.load(current, git_path, platform_impl, allocator) catch {
            allocator.free(current);
            break;
        };
        defer obj.deinit(allocator);
        
        const parent = helpers.extractHeaderField(obj.data, "parent");
        if (parent.len == 0) {
            break;
        }
        current = try allocator.dupe(u8, parent);
    } else {
        allocator.free(current);
    }

    // helpers.Reverse to get chronological order
    std.mem.reverse([]const u8, commit_list.items);
    
    const total = commit_list.items.len;
    
    for (commit_list.items, 0..) |commit_hash, idx| {
        const obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);
        
        // helpers.Extract commit info
        const author_line = helpers.extractHeaderField(obj.data, "author");
        const commit_msg = if (std.mem.indexOf(u8, obj.data, "\n\n")) |pos| obj.data[pos + 2 ..] else obj.data;
        const first_line = if (std.mem.indexOf(u8, commit_msg, "\n")) |nl| commit_msg[0..nl] else commit_msg;
        
        // helpers.Parse author
        const author_name = helpers.parseAuthorName(author_line);
        const author_email = helpers.parseAuthorEmail(author_line);
        const author_date = helpers.parseAuthorDate(author_line, allocator);
        defer if (author_date) |d| allocator.free(d);
        
        const patch_num = start_number + idx;
        
        if (stdout_mode) {
            // helpers.Output to stdout in mbox format
            const from_line = try std.fmt.allocPrint(allocator, "From {s} helpers.Mon Sep 17 00:00:00 2001\n", .{commit_hash});
            defer allocator.free(from_line);
            try platform_impl.writeStdout(from_line);
            
            const from_header = try std.fmt.allocPrint(allocator, "From: {s} <{s}>\n", .{ author_name, author_email });
            defer allocator.free(from_header);
            try platform_impl.writeStdout(from_header);
            
            const date_header = try std.fmt.allocPrint(allocator, "Date: {s}\n", .{ author_date orelse "helpers.Thu, 1 helpers.Jan 1970 00:00:00 +0000" });
            defer allocator.free(date_header);
            try platform_impl.writeStdout(date_header);
            
            if (numbered or total > 1) {
                const subj = try std.fmt.allocPrint(allocator, "Subject: [{s} {d}/{d}] {s}\n", .{ subject_prefix, patch_num, total, first_line });
                defer allocator.free(subj);
                try platform_impl.writeStdout(subj);
            } else {
                const subj = try std.fmt.allocPrint(allocator, "Subject: [{s}] {s}\n", .{ subject_prefix, first_line });
                defer allocator.free(subj);
                try platform_impl.writeStdout(subj);
            }

            // Add MIME headers if signoff name or commit message has non-ASCII
            var needs_mime = false;
            if (signoff) {
                // Get committer name for signoff
                const committer_name_env = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_NAME") catch null;
                defer if (committer_name_env) |n| allocator.free(n);
                const signer_name = committer_name_env orelse author_name;
                for (signer_name) |c| {
                    if (c > 127) {
                        needs_mime = true;
                        break;
                    }
                }
            }
            if (needs_mime) {
                try platform_impl.writeStdout("MIME-Version: 1.0\n");
                try platform_impl.writeStdout("Content-Type: text/plain; charset=UTF-8\n");
                try platform_impl.writeStdout("Content-Transfer-Encoding: 8bit\n");
            }
            
            // Write commit message body
            try platform_impl.writeStdout("\n");
            const full_msg = std.mem.trimRight(u8, commit_msg, "\n ");
            try platform_impl.writeStdout(full_msg);
            try platform_impl.writeStdout("\n");
            if (signoff) {
                const committer_name_env2 = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_NAME") catch null;
                defer if (committer_name_env2) |n| allocator.free(n);
                const committer_email_env2 = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_EMAIL") catch null;
                defer if (committer_email_env2) |n| allocator.free(n);
                const sob_name = committer_name_env2 orelse author_name;
                const sob_email = committer_email_env2 orelse author_email;
                const sob = try std.fmt.allocPrint(allocator, "\nSigned-off-by: {s} <{s}>\n", .{ sob_name, sob_email });
                defer allocator.free(sob);
                try platform_impl.writeStdout(sob);
            }
            try platform_impl.writeStdout("\n---\n\n");
            
            // helpers.Get parent for diff
            const parent_hash = helpers.extractHeaderField(obj.data, "parent");
            if (parent_hash.len >= 40) {
                const diff_output = helpers.generateDiffBetweenCommits(git_path, parent_hash, commit_hash, allocator, platform_impl) catch "";
                defer if (diff_output.len > 0) allocator.free(diff_output);
                if (diff_output.len > 0) {
                    try platform_impl.writeStdout(diff_output);
                }
            }
            
            try platform_impl.writeStdout("-- \n");
            const version_line = try std.fmt.allocPrint(allocator, "{s}\n\n", .{@import("version.zig").GIT_COMPAT_VERSION});
            defer allocator.free(version_line);
            try platform_impl.writeStdout(version_line);
        } else {
            // helpers.Write to file
            const filename = try std.fmt.allocPrint(allocator, "./{d:0>4}-{s}.patch", .{ patch_num, helpers.sanitizeSubjectForFilename(first_line, allocator) catch first_line });
            defer allocator.free(filename);
            
            const out_msg = try std.fmt.allocPrint(allocator, "{s}\n", .{filename});
            defer allocator.free(out_msg);
            try platform_impl.writeStdout(out_msg);
        }
    }
}
