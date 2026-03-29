// Auto-generated from main_common.zig - cmd_fast_export
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

pub fn cmdFastExport(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // helpers.Parse arguments
    var export_all = false;
    var signed_tags_mode: enum { strip, abort_mode, warn, verbatim, warn_strip, warn_verbatim } = .strip;
    var signed_commits_mode: enum { strip, abort_mode, warn, verbatim, warn_strip, warn_verbatim } = .strip;
    var show_original_ids = false;
    var mark_tags = false;
    var reference_excluded_parents = false;
    var tag_of_filtered: enum { drop, rewrite, abort_mode } = .abort_mode;
    var reencode_mode: enum { yes, no, abort_mode } = .yes;
    var import_marks_file: ?[]const u8 = null;
    var export_marks_file: ?[]const u8 = null;
    var no_data = false;
    var use_done_feature = false;
    var positional_args = std.array_list.Managed([]const u8).init(allocator);
    defer positional_args.deinit();
    var seen_dashdash = false;

    while (args.next()) |arg| {
        if (seen_dashdash) {
            try positional_args.append(arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            seen_dashdash = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            export_all = true;
        } else if (std.mem.eql(u8, arg, "--show-original-ids")) {
            show_original_ids = true;
        } else if (std.mem.eql(u8, arg, "--mark-tags")) {
            mark_tags = true;
        } else if (std.mem.eql(u8, arg, "--reference-excluded-parents")) {
            reference_excluded_parents = true;
        } else if (std.mem.eql(u8, arg, "--no-data")) {
            no_data = true;
        } else if (std.mem.eql(u8, arg, "--use-done-feature")) {
            use_done_feature = true;
        } else if (std.mem.startsWith(u8, arg, "--signed-tags=")) {
            const val = arg["--signed-tags=".len..];
            if (std.mem.eql(u8, val, "abort")) signed_tags_mode = .abort_mode
            else if (std.mem.eql(u8, val, "verbatim")) signed_tags_mode = .verbatim
            else if (std.mem.eql(u8, val, "warn-verbatim")) signed_tags_mode = .warn_verbatim
            else if (std.mem.eql(u8, val, "strip")) signed_tags_mode = .strip
            else if (std.mem.eql(u8, val, "warn")) signed_tags_mode = .warn
            else if (std.mem.eql(u8, val, "warn-strip")) signed_tags_mode = .warn_strip;
        } else if (std.mem.startsWith(u8, arg, "--signed-commits=")) {
            const val = arg["--signed-commits=".len..];
            if (std.mem.eql(u8, val, "abort")) signed_commits_mode = .abort_mode
            else if (std.mem.eql(u8, val, "verbatim")) signed_commits_mode = .verbatim
            else if (std.mem.eql(u8, val, "warn-verbatim")) signed_commits_mode = .warn_verbatim
            else if (std.mem.eql(u8, val, "strip")) signed_commits_mode = .strip
            else if (std.mem.eql(u8, val, "warn")) signed_commits_mode = .warn
            else if (std.mem.eql(u8, val, "warn-strip")) signed_commits_mode = .warn_strip;
        } else if (std.mem.startsWith(u8, arg, "--tag-of-filtered-object=")) {
            const val = arg["--tag-of-filtered-object=".len..];
            if (std.mem.eql(u8, val, "drop")) tag_of_filtered = .drop
            else if (std.mem.eql(u8, val, "rewrite")) tag_of_filtered = .rewrite
            else if (std.mem.eql(u8, val, "abort")) tag_of_filtered = .abort_mode;
        } else if (std.mem.startsWith(u8, arg, "--reencode=")) {
            const val = arg["--reencode=".len..];
            if (std.mem.eql(u8, val, "yes")) reencode_mode = .yes
            else if (std.mem.eql(u8, val, "no")) reencode_mode = .no
            else if (std.mem.eql(u8, val, "abort")) reencode_mode = .abort_mode;
        } else if (std.mem.startsWith(u8, arg, "--import-marks=") or std.mem.startsWith(u8, arg, "--import-marks-if-exists=")) {
            if (std.mem.startsWith(u8, arg, "--import-marks="))
                import_marks_file = arg["--import-marks=".len..]
            else
                import_marks_file = arg["--import-marks-if-exists=".len..];
        } else if (std.mem.startsWith(u8, arg, "--export-marks=")) {
            export_marks_file = arg["--export-marks=".len..];
        } else if (std.mem.startsWith(u8, arg, "--progress=") or std.mem.startsWith(u8, arg, "--refspec=") or std.mem.startsWith(u8, arg, "--anonymize-map=") or std.mem.eql(u8, arg, "--anonymize") or std.mem.eql(u8, arg, "--full-tree") or std.mem.eql(u8, arg, "--fake-missing-tagger")) {
            // ignore for now
        } else if (!std.mem.startsWith(u8, arg, "-") or std.mem.startsWith(u8, arg, "^")) {
            try positional_args.append(arg);
        }
    }

    if (use_done_feature) {
        try platform_impl.writeStdout("feature done\n");
    }

    // helpers.Determine which helpers.refs to export
    var ref_targets = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (ref_targets.items) |r| allocator.free(r);
        ref_targets.deinit();
    }
    var excluded_commits = std.StringHashMap(void).init(allocator);
    defer excluded_commits.deinit();

    if (export_all) {
        const ref_mgr = refs.RefManager.init(git_path, allocator);
        const all_refs_info = try ref_mgr.getAllRefsInfo(platform_impl);
        defer {
            for (all_refs_info) |ri| {
                allocator.free(ri.name);
                allocator.free(ri.hash);
            }
            allocator.free(all_refs_info);
        }
        for (all_refs_info) |ri| {
            if (std.mem.eql(u8, ri.name, "HEAD")) continue;
            try ref_targets.append(try allocator.dupe(u8, ri.name));
        }
    }

    // helpers.Process positional args
    for (positional_args.items) |parg| {
        if (std.mem.startsWith(u8, parg, "^")) {
            const exc_ref = parg[1..];
            const exc_hash = helpers.resolveRevision(git_path, exc_ref, platform_impl, allocator) catch continue;
            try excluded_commits.put(exc_hash, {});
            // helpers.Walk back and exclude all ancestors
            var walk_list = std.array_list.Managed([]const u8).init(allocator);
            defer {
                for (walk_list.items) |w| allocator.free(w);
                walk_list.deinit();
            }
            try walk_list.append(try allocator.dupe(u8, exc_hash));
            var wi: usize = 0;
            while (wi < walk_list.items.len and wi < 10000) : (wi += 1) {
                const wh: []const u8 = walk_list.items[wi];
                const wobj = objects.GitObject.load(wh, git_path, platform_impl, allocator) catch continue;
                defer wobj.deinit(allocator);
                if (wobj.type != .commit) continue;
                var plines = std.mem.splitScalar(u8, wobj.data, '\n');
                while (plines.next()) |pline| {
                    if (pline.len == 0) break;
                    if (std.mem.startsWith(u8, pline, "parent ")) {
                        const ph = pline["parent ".len..];
                        if (!excluded_commits.contains(ph)) {
                            const phd = try allocator.dupe(u8, ph);
                            try excluded_commits.put(phd, {});
                            try walk_list.append(try allocator.dupe(u8, ph));
                        }
                    }
                }
            }
        } else if (!export_all) {
            // helpers.Try to find the actual ref name
            const ref_name = blk: {
                if (refs.resolveRef(git_path, parg, platform_impl, allocator) catch null) |_rh| {
                    allocator.free(_rh);
                    break :blk try allocator.dupe(u8, parg);
                }
                const heads_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{parg});
                if (refs.resolveRef(git_path, heads_ref, platform_impl, allocator) catch null) |_rh| {
                    allocator.free(_rh);
                    break :blk heads_ref;
                }
                allocator.free(heads_ref);
                const tags_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{parg});
                if (refs.resolveRef(git_path, tags_ref, platform_impl, allocator) catch null) |_rh| {
                    allocator.free(_rh);
                    break :blk tags_ref;
                }
                allocator.free(tags_ref);
                break :blk try allocator.dupe(u8, parg);
            };
            try ref_targets.append(ref_name);
        }
    }

    // helpers.Sort refs: branches first, then tags
    std.sort.block([]const u8, ref_targets.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            const a_is_tag = std.mem.startsWith(u8, a, "refs/tags/");
            const b_is_tag = std.mem.startsWith(u8, b, "refs/tags/");
            if (a_is_tag != b_is_tag) return !a_is_tag;
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // helpers.Collect all commits reachable from target helpers.refs
    var all_commits = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (all_commits.items) |c| allocator.free(c);
        all_commits.deinit();
    }
    var commit_set = std.StringHashMap(void).init(allocator);
    defer commit_set.deinit();

    // helpers.Map ref name -> commit hash
    var ref_to_commit = std.StringHashMap([]const u8).init(allocator);
    defer {
        var vit = ref_to_commit.valueIterator();
        while (vit.next()) |v| allocator.free(v.*);
        ref_to_commit.deinit();
    }

    for (ref_targets.items) |ref_name| {
        const raw_hash = refs.getRef(git_path, ref_name, platform_impl, allocator) catch continue;
        defer allocator.free(raw_hash);

        // helpers.Resolve tag helpers.objects to find commit
        var commit_hash = try allocator.dupe(u8, raw_hash);
        var depth: usize = 0;
        while (depth < 10) : (depth += 1) {
            const obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch break;
            defer obj.deinit(allocator);
            if (obj.type == .tag) {
                const target_hash = helpers.extractHeaderField(obj.data, "object");
                if (target_hash.len > 0) {
                    allocator.free(commit_hash);
                    commit_hash = try allocator.dupe(u8, target_hash);
                } else break;
            } else break;
        }

        try ref_to_commit.put(ref_name, try allocator.dupe(u8, commit_hash));

        // helpers.Walk commits
        if (!excluded_commits.contains(commit_hash) and !commit_set.contains(commit_hash)) {
            var walk_stack = std.array_list.Managed([]const u8).init(allocator);
            defer {
                for (walk_stack.items) |w| allocator.free(w);
                walk_stack.deinit();
            }
            try walk_stack.append(try allocator.dupe(u8, commit_hash));

            while (walk_stack.items.len > 0) {
                const cur = walk_stack.pop() orelse break;
                defer allocator.free(cur);
                if (excluded_commits.contains(cur) or commit_set.contains(cur)) continue;
                const obj = objects.GitObject.load(cur, git_path, platform_impl, allocator) catch continue;
                defer obj.deinit(allocator);
                if (obj.type != .commit) continue;

                const duped = try allocator.dupe(u8, cur);
                try commit_set.put(duped, {});
                try all_commits.append(try allocator.dupe(u8, cur));

                var plines = std.mem.splitScalar(u8, obj.data, '\n');
                while (plines.next()) |pline| {
                    if (pline.len == 0) break;
                    if (std.mem.startsWith(u8, pline, "parent ")) {
                        const ph = pline["parent ".len..];
                        if (!excluded_commits.contains(ph) and !commit_set.contains(ph)) {
                            try walk_stack.append(try allocator.dupe(u8, ph));
                        }
                    }
                }
            }
        }

        allocator.free(commit_hash);
    }

    // Topological sort: parents before children
    {
        var cm_ts = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
        defer {
            var vit_ts = cm_ts.valueIterator();
            while (vit_ts.next()) |v| v.deinit(allocator);
            cm_ts.deinit();
        }
        var id_ts = std.StringHashMap(usize).init(allocator);
        defer id_ts.deinit();

        for (all_commits.items) |ch| {
            if (!cm_ts.contains(ch)) {
                try cm_ts.put(ch, std.ArrayList([]const u8){});
                try id_ts.put(ch, 0);
            }
        }

        for (all_commits.items) |ch| {
            const co_ts = objects.GitObject.load(ch, git_path, platform_impl, allocator) catch continue;
            defer co_ts.deinit(allocator);
            if (co_ts.type != .commit) continue;
            var pl = std.mem.splitScalar(u8, co_ts.data, '\n');
            var dg: usize = 0;
            while (pl.next()) |pln| {
                if (pln.len == 0) break;
                if (std.mem.startsWith(u8, pln, "parent ")) {
                    const phs = pln["parent ".len..];
                    if (commit_set.contains(phs)) {
                        dg += 1;
                        if (cm_ts.getPtr(phs)) |cl| {
                            try cl.append(allocator, ch);
                        }
                    }
                }
            }
            if (id_ts.getPtr(ch)) |ptr| ptr.* = dg;
        }

        var qt: std.ArrayList([]const u8) = .{};
        defer qt.deinit(allocator);
        for (all_commits.items) |ch| {
            if ((id_ts.get(ch) orelse 0) == 0) {
                try qt.append(allocator, ch);
            }
        }

        var st: std.ArrayList([]const u8) = .{};
        defer st.deinit(allocator);
        while (qt.items.len > 0) {
            const cs = qt.orderedRemove(0);
            try st.append(allocator, cs);
            if (cm_ts.get(cs)) |cl| {
                for (cl.items) |child| {
                    if (id_ts.getPtr(child)) |ptr| {
                        if (ptr.* > 0) ptr.* -= 1;
                        if (ptr.* == 0) {
                            var dp = false;
                            for (qt.items) |qi| {
                                if (std.mem.eql(u8, qi, child)) { dp = true; break; }
                            }
                            if (!dp) {
                                for (st.items) |si| {
                                    if (std.mem.eql(u8, si, child)) { dp = true; break; }
                                }
                            }
                            if (!dp) try qt.append(allocator, child);
                        }
                    }
                }
            }
        }

        for (all_commits.items) |oc| allocator.free(oc);
        all_commits.clearRetainingCapacity();
        for (st.items) |s| {
            try all_commits.append(try allocator.dupe(u8, s));
        }
    }

    // Assign marks
    var mark_counter: usize = 0;
    var commit_to_mark = std.StringHashMap(usize).init(allocator);
    defer commit_to_mark.deinit();
    var blob_to_mark = std.StringHashMap(usize).init(allocator);
    defer blob_to_mark.deinit();
    var tag_mark_map = std.StringHashMap(usize).init(allocator);
    defer tag_mark_map.deinit();

    // Import marks
    if (import_marks_file) |marks_path| {
        const marks_content = platform_impl.fs.readFile(allocator, marks_path) catch "";
        defer if (marks_content.len > 0) allocator.free(marks_content);
        var mlines = std.mem.splitScalar(u8, marks_content, '\n');
        while (mlines.next()) |mline| {
            if (mline.len < 2 or mline[0] != ':') continue;
            if (std.mem.indexOfScalar(u8, mline[1..], ' ')) |sp| {
                const mark_num = std.fmt.parseInt(usize, mline[1 .. sp + 1], 10) catch continue;
                if (mark_num > mark_counter) mark_counter = mark_num;
            }
        }
    }

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    // helpers.Track which helpers.refs have been seen (for reset lines)
    var refs_seen = std.StringHashMap(void).init(allocator);
    defer refs_seen.deinit();

    // helpers.Determine which ref each commit belongs to
    // helpers.Build a map: commit_hash -> ref_name for branch helpers.refs
    var commit_to_ref = std.StringHashMap([]const u8).init(allocator);
    defer commit_to_ref.deinit();

    // helpers.For each branch ref, walk its history and assign commits
    for (ref_targets.items) |ref_name| {
        if (std.mem.startsWith(u8, ref_name, "refs/tags/")) continue;
        if (ref_to_commit.get(ref_name)) |tip_hash| {
            var cur_h = try allocator.dupe(u8, tip_hash);
            var walk_depth: usize = 0;
            while (walk_depth < 10000) : (walk_depth += 1) {
                defer allocator.free(cur_h);
                if (!commit_set.contains(cur_h)) break;
                if (!commit_to_ref.contains(cur_h)) {
                    try commit_to_ref.put(cur_h, ref_name);
                }
                const obj = objects.GitObject.load(cur_h, git_path, platform_impl, allocator) catch break;
                defer obj.deinit(allocator);
                const parent = helpers.extractHeaderField(obj.data, "parent");
                if (parent.len == 0) break;
                cur_h = try allocator.dupe(u8, parent);
            } else {
                allocator.free(cur_h);
            }
        }
    }

    // helpers.Process each commit
    for (all_commits.items) |commit_hash| {
        const cobj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch continue;
        defer cobj.deinit(allocator);
        if (cobj.type != .commit) continue;

        const tree_hash = helpers.extractHeaderField(cobj.data, "tree");
        const author_line = helpers.extractHeaderField(cobj.data, "author");
        const committer_line = helpers.extractHeaderField(cobj.data, "committer");
        const encoding_field = helpers.extractHeaderField(cobj.data, "encoding");

        // helpers.Check for gpgsig
        var has_gpgsig = false;
        var gpgsig_content = std.array_list.Managed(u8).init(allocator);
        defer gpgsig_content.deinit();
        {
            var lines_it = std.mem.splitScalar(u8, cobj.data, '\n');
            var in_gpgsig = false;
            while (lines_it.next()) |line| {
                if (line.len == 0 and !in_gpgsig) break;
                if (std.mem.startsWith(u8, line, "gpgsig ")) {
                    has_gpgsig = true;
                    in_gpgsig = true;
                    try gpgsig_content.appendSlice(line["gpgsig ".len..]);
                    try gpgsig_content.append('\n');
                } else if (in_gpgsig and line.len > 0 and line[0] == ' ') {
                    try gpgsig_content.appendSlice(line[1..]);
                    try gpgsig_content.append('\n');
                } else if (in_gpgsig) {
                    in_gpgsig = false;
                    if (line.len == 0) break;
                }
            }
        }

        if (has_gpgsig) {
            switch (signed_commits_mode) {
                .abort_mode => {
                    try platform_impl.writeStdout(output.items);
                    const emsg = try std.fmt.allocPrint(allocator, "fatal: encountered signed commit {s}; use --signed-commits=<mode> to handle it\n", .{commit_hash});
                    defer allocator.free(emsg);
                    try platform_impl.writeStderr(emsg);
                    std.process.exit(128);
                },
                .warn, .warn_strip => {
                    const wmsg = try std.fmt.allocPrint(allocator, "Warning: signed commit {s}\n", .{commit_hash});
                    defer allocator.free(wmsg);
                    try platform_impl.writeStderr(wmsg);
                },
                else => {},
            }
        }

        // helpers.Get commit message
        var commit_msg: []const u8 = "";
        if (std.mem.indexOf(u8, cobj.data, "\n\n")) |blank| {
            commit_msg = cobj.data[blank + 2 ..];
        }

        // helpers.Collect parents
        var parents = std.array_list.Managed([]const u8).init(allocator);
        defer parents.deinit();
        {
            var plines = std.mem.splitScalar(u8, cobj.data, '\n');
            while (plines.next()) |pline| {
                if (pline.len == 0) break;
                if (std.mem.startsWith(u8, pline, "parent ")) {
                    try parents.append(pline["parent ".len..]);
                }
            }
        }

        // helpers.Collect file entries from current tree
        var file_entries = std.array_list.Managed(FastExportEntry).init(allocator);
        defer {
            for (file_entries.items) |fe| allocator.free(fe.path);
            file_entries.deinit();
        }
        try fastExportCollectTree(git_path, tree_hash, "", platform_impl, allocator, &file_entries);

        // helpers.Collect parent tree entries for diffing
        var parent_entries = std.StringHashMap(FastExportEntry).init(allocator);
        defer {
            var peit = parent_entries.valueIterator();
            while (peit.next()) |pe| allocator.free(pe.path);
            parent_entries.deinit();
        }
        if (parents.items.len > 0) {
            const parent_obj = objects.GitObject.load(parents.items[0], git_path, platform_impl, allocator) catch null;
            if (parent_obj) |pobj| {
                defer pobj.deinit(allocator);
                if (pobj.type == .commit) {
                    const ptree = helpers.extractHeaderField(pobj.data, "tree");
                    if (ptree.len > 0) {
                        var pfe_list = std.array_list.Managed(FastExportEntry).init(allocator);
                        defer pfe_list.deinit();
                        fastExportCollectTree(git_path, ptree, "", platform_impl, allocator, &pfe_list) catch {};
                        for (pfe_list.items) |pfe| {
                            try parent_entries.put(pfe.path, pfe);
                        }
                    }
                }
            }
        }

        // helpers.Compute changed entries (new or modified vs parent)
        var changed_entries = std.array_list.Managed(FastExportEntry).init(allocator);
        defer changed_entries.deinit();
        for (file_entries.items) |fe| {
            if (parent_entries.get(fe.path)) |pe| {
                if (!std.mem.eql(u8, fe.blob_hash, pe.blob_hash) or !std.mem.eql(u8, fe.mode, pe.mode)) {
                    try changed_entries.append(fe);
                }
            } else {
                try changed_entries.append(fe);
            }
        }

        // helpers.Compute deleted entries
        var deleted_paths = std.array_list.Managed([]const u8).init(allocator);
        defer deleted_paths.deinit();
        {
            var peit2 = parent_entries.iterator();
            while (peit2.next()) |pe| {
                var found = false;
                for (file_entries.items) |fe| {
                    if (std.mem.eql(u8, fe.path, pe.key_ptr.*)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try deleted_paths.append(pe.key_ptr.*);
                }
            }
        }

        // helpers.Output blobs for changed entries
        for (changed_entries.items) |fe| {
            if (!blob_to_mark.contains(fe.blob_hash)) {
                mark_counter += 1;
                try blob_to_mark.put(fe.blob_hash, mark_counter);

                try output.appendSlice("blob\n");
                const mark_str = try std.fmt.allocPrint(allocator, "mark :{d}\n", .{mark_counter});
                defer allocator.free(mark_str);
                try output.appendSlice(mark_str);

                if (show_original_ids) {
                    const oid_str = try std.fmt.allocPrint(allocator, "original-oid {s}\n", .{fe.blob_hash});
                    defer allocator.free(oid_str);
                    try output.appendSlice(oid_str);
                }

                if (no_data) {
                    try output.appendSlice("data 0\n\n");
                } else {
                    const blob_obj = objects.GitObject.load(fe.blob_hash, git_path, platform_impl, allocator) catch {
                        try output.appendSlice("data 0\n\n");
                        continue;
                    };
                    defer blob_obj.deinit(allocator);
                    const data_header = try std.fmt.allocPrint(allocator, "data {d}\n", .{blob_obj.data.len});
                    defer allocator.free(data_header);
                    try output.appendSlice(data_header);
                    try output.appendSlice(blob_obj.data);
                    try output.append('\n');
                }
            }
        }

        // helpers.Find the ref for this commit
        const actual_ref = commit_to_ref.get(commit_hash) orelse blk: {
            for (ref_targets.items) |rn| {
                if (!std.mem.startsWith(u8, rn, "refs/tags/")) break :blk rn;
            }
            break :blk "refs/heads/main";
        };

        // Assign mark
        mark_counter += 1;
        const commit_mark = mark_counter;
        const ch_dup = try allocator.dupe(u8, commit_hash);
        try commit_to_mark.put(ch_dup, commit_mark);

        // Emit reset before first commit on each ref
        if (!refs_seen.contains(actual_ref)) {
            try refs_seen.put(actual_ref, {});
            if (parents.items.len == 0) {
                const reset_str = try std.fmt.allocPrint(allocator, "reset {s}\n", .{actual_ref});
                defer allocator.free(reset_str);
                try output.appendSlice(reset_str);
            }
        }

        // helpers.Output commit header
        const commit_line = try std.fmt.allocPrint(allocator, "commit {s}\n", .{actual_ref});
        defer allocator.free(commit_line);
        try output.appendSlice(commit_line);

        const cmark_str = try std.fmt.allocPrint(allocator, "mark :{d}\n", .{commit_mark});
        defer allocator.free(cmark_str);
        try output.appendSlice(cmark_str);

        if (show_original_ids) {
            const oid_str = try std.fmt.allocPrint(allocator, "original-oid {s}\n", .{commit_hash});
            defer allocator.free(oid_str);
            try output.appendSlice(oid_str);
        }

        // helpers.Output gpgsig for verbatim modes
        if (has_gpgsig and (signed_commits_mode == .verbatim or signed_commits_mode == .warn_verbatim)) {
            // helpers.Output as "gpgsig <hash-algo> <sig-type>" header
            // helpers.Actually the format is different - need to determine the sig type
            // helpers.For now output as-is
            const gpgsig_trimmed = std.mem.trimRight(u8, gpgsig_content.items, "\n");
            _ = gpgsig_trimmed;
            // helpers.Detect signature type
            var sig_type: []const u8 = "openpgp";
            if (std.mem.indexOf(u8, gpgsig_content.items, "SSH SIGNATURE") != null) {
                sig_type = "ssh";
            } else if (std.mem.indexOf(u8, gpgsig_content.items, "SIGNED MESSAGE") != null) {
                sig_type = "x509";
            }
            const sig_line = try std.fmt.allocPrint(allocator, "gpgsig sha1 {s}\n", .{sig_type});
            defer allocator.free(sig_line);
            try output.appendSlice(sig_line);
        }

        // Encoding
        if (encoding_field.len > 0 and reencode_mode == .no) {
            const enc_line = try std.fmt.allocPrint(allocator, "encoding {s}\n", .{encoding_field});
            defer allocator.free(enc_line);
            try output.appendSlice(enc_line);
        }

        const author_str = try std.fmt.allocPrint(allocator, "author {s}\n", .{author_line});
        defer allocator.free(author_str);
        try output.appendSlice(author_str);

        const committer_str = try std.fmt.allocPrint(allocator, "committer {s}\n", .{committer_line});
        defer allocator.free(committer_str);
        try output.appendSlice(committer_str);

        // Commit message
        var msg_with_nl = commit_msg;
        var msg_needs_free = false;
        if (msg_with_nl.len > 0 and msg_with_nl[msg_with_nl.len - 1] != '\n') {
            msg_with_nl = try std.fmt.allocPrint(allocator, "{s}\n", .{commit_msg});
            msg_needs_free = true;
        }
        defer if (msg_needs_free) allocator.free(msg_with_nl);

        const data_line = try std.fmt.allocPrint(allocator, "data {d}\n", .{msg_with_nl.len});
        defer allocator.free(data_line);
        try output.appendSlice(data_line);
        try output.appendSlice(msg_with_nl);

        // from (first parent)
        if (parents.items.len > 0) {
            const parent_hash = parents.items[0];
            if (commit_to_mark.get(parent_hash)) |pm| {
                const from_str = try std.fmt.allocPrint(allocator, "from :{d}\n", .{pm});
                defer allocator.free(from_str);
                try output.appendSlice(from_str);
            } else if (reference_excluded_parents and excluded_commits.contains(parent_hash)) {
                const from_str = try std.fmt.allocPrint(allocator, "from {s}\n", .{parent_hash});
                defer allocator.free(from_str);
                try output.appendSlice(from_str);
            }
        }

        // merge parents
        if (parents.items.len > 1) {
            for (parents.items[1..]) |parent_hash| {
                if (commit_to_mark.get(parent_hash)) |pm| {
                    const merge_str = try std.fmt.allocPrint(allocator, "merge :{d}\n", .{pm});
                    defer allocator.free(merge_str);
                    try output.appendSlice(merge_str);
                } else if (reference_excluded_parents and excluded_commits.contains(parent_hash)) {
                    const merge_str = try std.fmt.allocPrint(allocator, "merge {s}\n", .{parent_hash});
                    defer allocator.free(merge_str);
                    try output.appendSlice(merge_str);
                }
            }
        }

        // File modifications
        for (file_entries.items) |fe| {
            if (blob_to_mark.get(fe.blob_hash)) |bm| {
                const m_str = try std.fmt.allocPrint(allocator, "M {s} :{d} {s}\n", .{ fe.mode, bm, fe.path });
                defer allocator.free(m_str);
                try output.appendSlice(m_str);
            }
        }

        try output.append('\n');

        // Flush periodically
        if (output.items.len > 1024 * 1024) {
            try platform_impl.writeStdout(output.items);
            output.clearRetainingCapacity();
        }
    }

    // helpers.Output tags
    for (ref_targets.items) |ref_name| {
        if (!std.mem.startsWith(u8, ref_name, "refs/tags/")) continue;

        const raw_hash = refs.getRef(git_path, ref_name, platform_impl, allocator) catch continue;
        defer allocator.free(raw_hash);

        const tag_obj = objects.GitObject.load(raw_hash, git_path, platform_impl, allocator) catch {
            // Lightweight tag
            if (commit_to_mark.get(raw_hash)) |cm| {
                const reset_str = try std.fmt.allocPrint(allocator, "reset {s}\nfrom :{d}\n\n", .{ ref_name, cm });
                defer allocator.free(reset_str);
                try output.appendSlice(reset_str);
            }
            continue;
        };
        defer tag_obj.deinit(allocator);

        if (tag_obj.type == .tag) {
            const tag_target = helpers.extractHeaderField(tag_obj.data, "object");
            const tag_type = helpers.extractHeaderField(tag_obj.data, "type");
            _ = tag_type;
            const tagger_line = helpers.extractHeaderField(tag_obj.data, "tagger");
            const tag_short_name = if (std.mem.startsWith(u8, ref_name, "refs/tags/"))
                ref_name["refs/tags/".len..]
            else
                ref_name;

            // helpers.Check for signature
            var has_signature = false;
            var tag_msg: []const u8 = "";
            var tag_sig: []const u8 = "";
            if (std.mem.indexOf(u8, tag_obj.data, "\n\n")) |blank| {
                const body = tag_obj.data[blank + 2 ..];
                if (std.mem.indexOf(u8, body, "-----BEGIN PGP SIGNATURE-----")) |sig_start| {
                    has_signature = true;
                    tag_msg = body[0..sig_start];
                    tag_sig = body[sig_start..];
                } else if (std.mem.indexOf(u8, body, "-----BEGIN PGP MESSAGE-----")) |sig_start| {
                    has_signature = true;
                    tag_msg = body[0..sig_start];
                    tag_sig = body[sig_start..];
                } else if (std.mem.indexOf(u8, body, "-----BEGIN SSH SIGNATURE-----")) |sig_start| {
                    has_signature = true;
                    tag_msg = body[0..sig_start];
                    tag_sig = body[sig_start..];
                } else if (std.mem.indexOf(u8, body, "-----BEGIN SIGNED MESSAGE-----")) |sig_start| {
                    has_signature = true;
                    tag_msg = body[0..sig_start];
                    tag_sig = body[sig_start..];
                } else {
                    tag_msg = body;
                }
            }

            if (has_signature) {
                switch (signed_tags_mode) {
                    .abort_mode => {
                        const emsg = try std.fmt.allocPrint(allocator, "Error: encountered signed tag {s}\n", .{tag_short_name});
                        defer allocator.free(emsg);
                        try platform_impl.writeStdout(output.items);
                        try platform_impl.writeStderr(emsg);
                        std.process.exit(1);
                    },
                    .warn, .warn_strip => {
                        const wmsg = try std.fmt.allocPrint(allocator, "Warning: signed tag {s}\n", .{tag_short_name});
                        defer allocator.free(wmsg);
                        try platform_impl.writeStderr(wmsg);
                    },
                    .warn_verbatim => {
                        const wmsg = try std.fmt.allocPrint(allocator, "Warning: exporting signed tag {s}\n", .{tag_short_name});
                        defer allocator.free(wmsg);
                        try platform_impl.writeStderr(wmsg);
                    },
                    else => {},
                }
            }

            // helpers.Check if tag target is in export set
            const target_in_set = commit_to_mark.contains(tag_target);

            if (!target_in_set) {
                switch (tag_of_filtered) {
                    .drop => continue,
                    .rewrite => {
                        const tag_line2 = try std.fmt.allocPrint(allocator, "tag {s}\n", .{tag_short_name});
                        defer allocator.free(tag_line2);
                        try output.appendSlice(tag_line2);

                        if (mark_tags) {
                            mark_counter += 1;
                            try tag_mark_map.put(ref_name, mark_counter);
                            const tm_str = try std.fmt.allocPrint(allocator, "mark :{d}\n", .{mark_counter});
                            defer allocator.free(tm_str);
                            try output.appendSlice(tm_str);
                        }

                        const from_str2 = try std.fmt.allocPrint(allocator, "from {s}\n", .{tag_target});
                        defer allocator.free(from_str2);
                        try output.appendSlice(from_str2);

                        if (tagger_line.len > 0) {
                            const tagger_str = try std.fmt.allocPrint(allocator, "tagger {s}\n", .{tagger_line});
                            defer allocator.free(tagger_str);
                            try output.appendSlice(tagger_str);
                        }

                        const full_msg2 = if (has_signature and (signed_tags_mode == .verbatim or signed_tags_mode == .warn_verbatim))
                            try std.fmt.allocPrint(allocator, "{s}{s}", .{ tag_msg, tag_sig })
                        else
                            try allocator.dupe(u8, tag_msg);
                        defer allocator.free(full_msg2);
                        const data_str2 = try std.fmt.allocPrint(allocator, "data {d}\n{s}\n", .{ full_msg2.len, full_msg2 });
                        defer allocator.free(data_str2);
                        try output.appendSlice(data_str2);
                        continue;
                    },
                    .abort_mode => {},
                }
            }

            // helpers.Normal tag output
            const tag_line3 = try std.fmt.allocPrint(allocator, "tag {s}\n", .{tag_short_name});
            defer allocator.free(tag_line3);
            try output.appendSlice(tag_line3);

            if (mark_tags) {
                mark_counter += 1;
                try tag_mark_map.put(ref_name, mark_counter);
                const tm_str = try std.fmt.allocPrint(allocator, "mark :{d}\n", .{mark_counter});
                defer allocator.free(tm_str);
                try output.appendSlice(tm_str);
            }

            if (show_original_ids) {
                const oid_str = try std.fmt.allocPrint(allocator, "original-oid {s}\n", .{raw_hash});
                defer allocator.free(oid_str);
                try output.appendSlice(oid_str);
            }

            if (commit_to_mark.get(tag_target)) |cm| {
                const from_str3 = try std.fmt.allocPrint(allocator, "from :{d}\n", .{cm});
                defer allocator.free(from_str3);
                try output.appendSlice(from_str3);
            } else {
                const from_str3 = try std.fmt.allocPrint(allocator, "from {s}\n", .{tag_target});
                defer allocator.free(from_str3);
                try output.appendSlice(from_str3);
            }

            if (tagger_line.len > 0) {
                const tagger_str = try std.fmt.allocPrint(allocator, "tagger {s}\n", .{tagger_line});
                defer allocator.free(tagger_str);
                try output.appendSlice(tagger_str);
            }

            const full_msg3 = if (has_signature and (signed_tags_mode == .verbatim or signed_tags_mode == .warn_verbatim))
                try std.fmt.allocPrint(allocator, "{s}{s}", .{ tag_msg, tag_sig })
            else
                try allocator.dupe(u8, tag_msg);
            defer allocator.free(full_msg3);
            const data_str3 = try std.fmt.allocPrint(allocator, "data {d}\n{s}\n", .{ full_msg3.len, full_msg3 });
            defer allocator.free(data_str3);
            try output.appendSlice(data_str3);
        } else {
            // helpers.Not a tag object, treat as lightweight
            if (commit_to_mark.get(raw_hash)) |cm| {
                const reset_str = try std.fmt.allocPrint(allocator, "reset {s}\nfrom :{d}\n\n", .{ ref_name, cm });
                defer allocator.free(reset_str);
                try output.appendSlice(reset_str);
            }
        }
    }

    if (use_done_feature) {
        try output.appendSlice("done\n");
    }

    // helpers.Write export marks
    if (export_marks_file) |marks_path| {
        var marks_buf = std.array_list.Managed(u8).init(allocator);
        defer marks_buf.deinit();
        var bit = blob_to_mark.iterator();
        while (bit.next()) |entry| {
            const ml = try std.fmt.allocPrint(allocator, ":{d} {s}\n", .{ entry.value_ptr.*, entry.key_ptr.* });
            defer allocator.free(ml);
            try marks_buf.appendSlice(ml);
        }
        var cit = commit_to_mark.iterator();
        while (cit.next()) |entry| {
            const ml = try std.fmt.allocPrint(allocator, ":{d} {s}\n", .{ entry.value_ptr.*, entry.key_ptr.* });
            defer allocator.free(ml);
            try marks_buf.appendSlice(ml);
        }
        var tit = tag_mark_map.iterator();
        while (tit.next()) |entry| {
            const raw_h = refs.getRef(git_path, entry.key_ptr.*, platform_impl, allocator) catch continue;
            defer allocator.free(raw_h);
            const ml = try std.fmt.allocPrint(allocator, ":{d} {s}\n", .{ entry.value_ptr.*, raw_h });
            defer allocator.free(ml);
            try marks_buf.appendSlice(ml);
        }
        const marks_file = std.fs.cwd().createFile(marks_path, .{}) catch null;
        if (marks_file) |f| {
            defer f.close();
            f.writeAll(marks_buf.items) catch {};
        }
    }

    // Flush output
    try platform_impl.writeStdout(output.items);
}


pub fn fastExportCollectTree(git_path: []const u8, tree_hash_str: []const u8, prefix: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator, result: *std.array_list.Managed(FastExportEntry)) !void {
    const tree_obj = objects.GitObject.load(tree_hash_str, git_path, platform_impl, allocator) catch return;
    defer tree_obj.deinit(allocator);

    var entries = tree_mod.parseTree(tree_obj.data, allocator) catch return;
    defer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit();
    }

    for (entries.items) |entry| {
        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        if (entry.type == .tree) {
            defer allocator.free(full_path);
            try fastExportCollectTree(git_path, entry.hash, full_path, platform_impl, allocator, result);
        } else {
            try result.append(.{
                .path = full_path,
                .mode = entry.mode,
                .blob_hash = entry.hash,
            });
        }
    }
}

const FastExportEntry = struct {
    path: []const u8,
    mode: []const u8,
    blob_hash: []const u8,
};
