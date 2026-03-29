const git_helpers_mod = @import("../git_helpers.zig");
const std = @import("std");
const pm = @import("../platform/platform.zig");
const refs = @import("refs.zig");
const B = @import("blame.zig");
const mc = @import("../main_common.zig");

pub fn cmdBlame(a: std.mem.Allocator, args: *pm.ArgIterator, pi: *const pm.Platform, is_annotate: bool) !void {
    var col = is_annotate;
    var se = false;
    var se_explicit = false;
    var sp = false;
    var slp = false;
    var srt = false;
    var suppress = false;
    var blank_boundary = false;
    var incremental = false;
    var fp: ?[]const u8 = null;
    var rv: ?[]const u8 = null;
    var rev_is_boundary = false;
    var cf: ?[]const u8 = null;
    var abl: usize = 7;
    var show_progress = false;
    var first_parent = false;
    var lr = std.array_list.Managed([]const u8).init(a);
    defer lr.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-c")) { col = true; }
        else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--show-email")) { se = true; se_explicit = true; }
        else if (std.mem.eql(u8, arg, "--no-show-email")) { se = false; se_explicit = true; }
        else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--porcelain")) { sp = true; }
        else if (std.mem.eql(u8, arg, "--incremental")) { incremental = true; }
        else if (std.mem.eql(u8, arg, "--line-porcelain")) { slp = true; }
        else if (std.mem.eql(u8, arg, "-t")) { srt = true; }
        else if (std.mem.eql(u8, arg, "-s")) { suppress = true; }
        else if (std.mem.eql(u8, arg, "-b")) { blank_boundary = true; }
        else if (std.mem.startsWith(u8, arg, "--contents=")) { cf = arg["--contents=".len..]; }
        else if (std.mem.eql(u8, arg, "--contents")) { cf = args.next(); }
        else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
            abl = std.fmt.parseInt(usize, arg["--abbrev=".len..], 10) catch 7;
            if (abl < 4) abl = 4;
            // Don't cap at 40 - let display logic handle it
        }
        else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--no-abbrev")) { abl = 40; }
        else if (std.mem.startsWith(u8, arg, "-L")) {
            try lr.append(if (arg.len > 2) arg[2..] else (args.next() orelse ""));
        }
        else if (std.mem.eql(u8, arg, "--")) { fp = args.next(); break; }
        else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try pi.writeStdout("usage: git blame [<options>] [<rev>] [--] <file>\n");
            std.process.exit(129);
        }
        else if (std.mem.eql(u8, arg, "--progress")) { show_progress = true; }
        else if (std.mem.eql(u8, arg, "--no-progress")) { show_progress = false; }
        else if (std.mem.eql(u8, arg, "--first-parent")) { first_parent = true; }
        else if (std.mem.eql(u8, arg, "--exclude-promisor-objects")) {
            try pi.writeStderr("fatal: --exclude-promisor-objects not supported for blame\n");
            std.process.exit(1);
        }
        else if (arg.len > 0 and arg[0] == '-') {}
        else {
            if (fp == null) {
                if (std.fs.cwd().access(arg, .{})) |_| { fp = arg; } else |_| {
                    if (rv == null) rv = arg else fp = arg;
                }
            } else {
                // fp already set; this must be a revision
                if (rv == null) rv = arg;
            }
        }
    }
    // If no file path found but we have a revision, treat it as the file path
    // (common in bare repos where the file doesn't exist on disk)
    if (fp == null and rv != null) {
        fp = rv;
        rv = null;
    }
    if (fp == null) { try pi.writeStderr("usage: git blame [<options>] [<rev>] [--] <file>\n"); std.process.exit(128); }

    const gp = git_helpers_mod.findGitDirectory(a, pi) catch {
        try pi.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer a.free(gp);

    // Config check for blame.showEmail
    if (!se_explicit) {
        const cp = std.fmt.allocPrint(a, "{s}/config", .{gp}) catch null;
        if (cp) |cfp| {
            defer a.free(cfp);
            if (std.fs.cwd().readFileAlloc(a, cfp, 1024 * 1024)) |cc| {
                defer a.free(cc);
                var cls = std.mem.splitScalar(u8, cc, '\n');
                var inb = false;
                while (cls.next()) |cl| {
                    const t = std.mem.trim(u8, cl, " \t\r");
                    if (t.len > 0 and t[0] == '[') inb = std.ascii.startsWithIgnoreCase(t, "[blame");
                    if (inb and std.ascii.startsWithIgnoreCase(t, "showemail")) {
                        const eq = std.mem.indexOf(u8, t, "=") orelse continue;
                        if (std.mem.eql(u8, std.mem.trim(u8, t[eq + 1 ..], " \t"), "true")) se = true;
                    }
                }
            } else |_| {}
        }
    }

    var hh: ?[]const u8 = null;
    defer if (hh) |h| a.free(h);
    if (rv) |r| {
        // Handle ^REV syntax (boundary commit)
        if (r.len > 0 and r[0] == '^') rev_is_boundary = true;
        const actual_rev = if (r.len > 0 and r[0] == '^') r[1..] else r;
        hh = git_helpers_mod.resolveRevision(gp, actual_rev, pi, a) catch (refs.resolveRef(gp, actual_rev, pi, a) catch null);
        // Dereference tag objects to commits (follow chain)
        if (hh) |h| {
            var cur_h = h;
            var depth: u32 = 0;
            while (depth < 10) : (depth += 1) {
                const data = git_helpers_mod.readGitObjectContent(gp, cur_h, a) catch break;
                defer a.free(data);
                if (std.mem.startsWith(u8, data, "object ") and data.len > 47) {
                    if (std.mem.indexOf(u8, data, "\n")) |nl| {
                        const target = data["object ".len..nl];
                        if (target.len >= 40) {
                            const new_h = a.dupe(u8, target[0..40]) catch break;
                            if (cur_h.ptr != h.ptr) a.free(cur_h);
                            cur_h = new_h;
                            continue;
                        }
                    }
                }
                break;
            }
            if (cur_h.ptr != h.ptr) {
                a.free(h);
                hh = cur_h;
            }
        }
    } else { hh = refs.resolveRef(gp, "HEAD", pi, a) catch null; }

    var fc: []const u8 = "";
    var fca = false;
    defer if (fca) a.free(fc);
    var bu = false;

    if (cf) |c| {
        fc = std.fs.cwd().readFileAlloc(a, c, 10 * 1024 * 1024) catch { try pi.writeStderr("fatal: cannot open file\n"); std.process.exit(128); unreachable; };
        fca = true;
    } else if (rv != null) {
        if (hh) |h| {
            fc = gf(gp, h, fp.?, a) catch { try pi.writeStderr("fatal: no such ref\n"); std.process.exit(128); unreachable; };
            fca = true;
        } else { try pi.writeStderr("fatal: no such ref\n"); std.process.exit(128); }
    } else {
        if (std.fs.cwd().readFileAlloc(a, fp.?, 10 * 1024 * 1024)) |c| {
            // Check if file is tracked - must exist in HEAD commit or be in an empty repo
            if (hh) |h| {
                // File exists on disk but check if it's tracked
                _ = gf(gp, h, fp.?, a) catch {
                    // File not in HEAD - check if it's in the index (conflicted merge)
                    const idx_mod = @import("index.zig");
                    const idx = idx_mod.Index.load(gp, pi, a) catch null;
                    var in_index = false;
                    if (idx) |ix| {
                        var ix_mut = ix;
                        defer ix_mut.deinit();
                        for (ix_mut.entries.items) |*entry| {
                            if (std.mem.eql(u8, entry.path, fp.?)) {
                                in_index = true;
                                break;
                            }
                        }
                    }
                    if (!in_index) {
                        a.free(c);
                        const emsg = std.fmt.allocPrint(a, "fatal: no such path '{s}' in HEAD\n", .{fp.?}) catch unreachable;
                        defer a.free(emsg);
                        pi.writeStderr(emsg) catch {};
                        std.process.exit(128);
                    }
                };
            } else {
                // No HEAD - empty repo
                a.free(c);
                const emsg = try std.fmt.allocPrint(a, "fatal: no such path '{s}' in HEAD\n", .{fp.?});
                defer a.free(emsg);
                try pi.writeStderr(emsg);
                std.process.exit(128);
            }
            fc = c; fca = true; bu = true;
        } else |_| {
            if (hh) |h| {
                fc = gf(gp, h, fp.?, a) catch { try pi.writeStderr("fatal: no such path\n"); std.process.exit(128); unreachable; };
                fca = true;
            } else { try pi.writeStderr("fatal: no such path\n"); std.process.exit(128); }
        }
    }

    var lines = try B.splitLines(a, fc);
    defer lines.deinit();
    if (lines.items.len == 0) {
        // Even for empty files, -L ranges need validation
        if (lr.items.len > 0) {
            for (lr.items) |rs| {
                if (rs.len == 0) continue;
                // -L0 is always invalid
                if (std.mem.eql(u8, rs, "0") or std.mem.startsWith(u8, rs, "0,")) {
                    try pi.writeStderr("fatal: -L invalid line range\n");
                    std.process.exit(128);
                }
                // Any -L on empty file: "has only 0 lines"
                try pi.writeStderr("fatal: file ");
                try pi.writeStderr(fp.?);
                try pi.writeStderr(" has only 0 lines\n");
                std.process.exit(128);
            }
        }
        return;
    }

    const es = try a.alloc(B.BlameEntry, lines.items.len);
    defer a.free(es);
    const da: []const u8 = if (cf != null) "External file (--contents)" else "Not Committed Yet";
    const de: []const u8 = if (cf != null) "external.file" else "not.committed.yet";
    for (es) |*e| {
        @memset(&e.commit_hash, '0');
        e.author_name = da; e.author_email = de; e.author_time = std.time.timestamp(); e.author_tz = "+0000";
        e.committer_name = da; e.committer_email = de; e.committer_time = std.time.timestamp(); e.committer_tz = "+0000";
        e.summary = ""; e.is_default = true; e.is_boundary = false;
    }

    if (hh) |sh| {
        const cfc = gf(gp, sh, fp.?, a) catch null;
        var cl2 = std.array_list.Managed([]const u8).init(a);
        defer cl2.deinit();
        if (cfc) |cc| {
            defer a.free(cc);
            var li = std.mem.splitScalar(u8, cc, '\n');
            while (li.next()) |l| try cl2.append(l);
            if (cl2.items.len > 0 and cl2.items[cl2.items.len - 1].len == 0) _ = cl2.pop();
        }
        const uwd = bu and cfc != null and !std.mem.eql(u8, fc, cfc.?);
        const wcl: ?[]const []const u8 = if (uwd and cf == null and rv == null) cl2.items else null;
        try trav(a, gp, sh, fp.?, lines.items, es, wcl, first_parent);
    }

    // Mark all entries as boundary if ^rev was used
    if (rev_is_boundary) {
        for (es) |*e| {
            e.is_boundary = true;
        }
    }

    // -L ranges
    var oi = std.array_list.Managed(usize).init(a);
    defer oi.deinit();
    if (lr.items.len == 0) {
        for (0..lines.items.len) |i| try oi.append(i);
    } else {
        const inc = try a.alloc(bool, lines.items.len);
        defer a.free(inc);
        @memset(inc, false);
        var prev_end: usize = 0; // track end of previous -L range for relative /RE/
        for (lr.items) |rs| {
            var s: usize = 1;
            var e: usize = lines.items.len;

            // Handle :funcname syntax
            if (rs.len > 0 and (rs[0] == ':' or (rs.len > 1 and rs[0] == '^' and rs[1] == ':'))) {
                const is_absolute = rs[0] == '^';
                const pattern = if (is_absolute) rs[2..] else rs[1..];
                const search_from = if (is_absolute) @as(usize, 0) else prev_end;
                if (resolveFuncname(pattern, lines.items, search_from)) |result| {
                    s = result.start;
                    e = result.end;
                    if (s <= e) {
                        for (s - 1..e) |idx| inc[idx] = true;
                        prev_end = e;
                    }
                } else {
                    try pi.writeStderr("fatal: -L: no match\n");
                    std.process.exit(128);
                }
                continue;
            }

            // Find comma separator, but skip commas inside /regex/
            const comma = findLComma(rs);
            if (comma) |ci| {
                const ss = rs[0..ci];
                const ess = rs[ci + 1 ..];
                if (ss.len > 0) {
                    if (ss.len > 1 and ss[0] == '^' and ss[1] == '/') {
                        s = resolveRegex(ss[1..], lines.items, 0) orelse {
                            try pi.writeStderr("fatal: -L: no match\n");
                            std.process.exit(128);
                            unreachable;
                        };
                    } else if (ss[0] == '/') {
                        s = resolveRegex(ss, lines.items, prev_end) orelse {
                            try pi.writeStderr("fatal: -L: no match\n");
                            std.process.exit(128);
                            unreachable;
                        };
                    } else {
                        if (ss[0] == '-') { try pi.writeStderr("fatal: -L invalid line range\n"); std.process.exit(128); }
                        s = std.fmt.parseInt(usize, ss, 10) catch {
                            try pi.writeStderr("fatal: -L: invalid line number: ");
                            try pi.writeStderr(ss);
                            try pi.writeStderr("\n");
                            std.process.exit(128);
                            unreachable;
                        };
                    }
                }
                if (ess.len > 0) {
                    if (ess[0] == '+') {
                        const o = std.fmt.parseInt(usize, ess[1..], 10) catch 0;
                        if (o == 0) { try pi.writeStderr("fatal: -L invalid line range\n"); std.process.exit(128); }
                        e = s + o - 1;
                    } else if (ess[0] == '-') {
                        const o = std.fmt.parseInt(usize, ess[1..], 10) catch 0;
                        if (o == 0) { try pi.writeStderr("fatal: -L invalid line range\n"); std.process.exit(128); }
                        if (o >= s) { e = 1; } else { e = s - o + 1; }
                        if (e < s) { const t = s; s = e; e = t; }
                    } else if (ess.len > 1 and ess[0] == '^' and ess[1] == '/') {
                        // ^/RE/ is not valid as end specifier in -L range
                        try pi.writeStderr("fatal: -L invalid line range\n");
                        std.process.exit(128);
                    } else if (ess[0] == '/') {
                        e = resolveRegex(ess, lines.items, if (s > 0) s - 1 else 0) orelse {
                            try pi.writeStderr("fatal: -L: no match\n");
                            std.process.exit(128);
                            unreachable;
                        };
                    } else {
                        e = std.fmt.parseInt(usize, ess, 10) catch {
                            try pi.writeStderr("fatal: -L: invalid line number: ");
                            try pi.writeStderr(ess);
                            try pi.writeStderr("\n");
                            std.process.exit(128);
                            unreachable;
                        };
                        if (e == 0) { try pi.writeStderr("fatal: -L invalid line range\n"); std.process.exit(128); }
                    }
                }
            } else if (rs.len > 0) {
                if (rs.len > 1 and rs[0] == '^' and rs[1] == '/') {
                    s = resolveRegex(rs[1..], lines.items, 0) orelse {
                        try pi.writeStderr("fatal: -L: no match\n");
                        std.process.exit(128);
                        unreachable;
                    };
                    e = lines.items.len;
                } else if (rs[0] == '/') {
                    s = resolveRegex(rs, lines.items, prev_end) orelse {
                        try pi.writeStderr("fatal: -L: no match\n");
                        std.process.exit(128);
                        unreachable;
                    };
                    e = lines.items.len;
                } else {
                    if (rs[0] == '-') { try pi.writeStderr("fatal: -L invalid line range\n"); std.process.exit(128); }
                    s = std.fmt.parseInt(usize, rs, 10) catch {
                        try pi.writeStderr("fatal: -L: invalid line number: ");
                        try pi.writeStderr(rs);
                        try pi.writeStderr("\n");
                        std.process.exit(128);
                        unreachable;
                    };
                    // Single line number without comma: s must be <= nlines
                    if (s > lines.items.len) {
                        try pi.writeStderr("fatal: file ");
                        try pi.writeStderr(fp.?);
                        try pi.writeStderr(" has only ");
                        const nbuf = try std.fmt.allocPrint(a, "{d}", .{lines.items.len});
                        defer a.free(nbuf);
                        try pi.writeStderr(nbuf);
                        try pi.writeStderr(" lines\n");
                        std.process.exit(128);
                    }
                }
            }
            if (s == 0) { try pi.writeStderr("fatal: -L invalid line range\n"); std.process.exit(128); }
            if (s > lines.items.len) {
                try pi.writeStderr("fatal: file ");
                try pi.writeStderr(fp.?);
                try pi.writeStderr(" has only ");
                const nbuf = try std.fmt.allocPrint(a, "{d}", .{lines.items.len});
                defer a.free(nbuf);
                try pi.writeStderr(nbuf);
                try pi.writeStderr(" lines\n");
                std.process.exit(128);
            }
            if (s > e) { const t = s; s = e; e = t; }
            if (s < 1) s = 1;
            if (e > lines.items.len) e = lines.items.len;
            if (s <= e) {
                for (s - 1..e) |i| inc[i] = true;
                prev_end = e;
            }
        }
        for (0..lines.items.len) |i| { if (inc[i]) try oi.append(i); }
    }

    var mal: usize = 0;
    for (oi.items) |i| {
        const dn = if (se) es[i].author_email.len + 2 else es[i].author_name.len;
        if (dn > mal) mal = dn;
    }
    var lnw: usize = 1;
    { var nn = lines.items.len; while (nn >= 10) : (nn /= 10) lnw += 1; }

    // Output progress if requested
    if (show_progress and oi.items.len > 0) {
        const progress_msg = try std.fmt.allocPrint(a, "Blaming lines: 100% ({d}/{d}), done.\n", .{oi.items.len, oi.items.len});
        defer a.free(progress_msg);
        try pi.writeStderr(progress_msg);
    }

    var seen_hashes = std.StringHashMap(void).init(a);
    defer seen_hashes.deinit();

    // Compute group sizes for porcelain output
    // A "group" is a maximal run of consecutive output lines with the same commit hash
    var group_sizes = try a.alloc(usize, oi.items.len);
    defer a.free(group_sizes);
    @memset(group_sizes, 0);
    if (oi.items.len > 0) {
        var gi: usize = 0;
        var gs: usize = 1;
        var j: usize = 1;
        while (j < oi.items.len) : (j += 1) {
            if (std.mem.eql(u8, &es[oi.items[j]].commit_hash, &es[oi.items[j - 1]].commit_hash) and oi.items[j] == oi.items[j - 1] + 1) {
                gs += 1;
            } else {
                group_sizes[gi] = gs;
                gi = j;
                gs = 1;
            }
        }
        group_sizes[gi] = gs;
    }

    if (incremental) {
        // Incremental output: group consecutive lines from same commit, output header per group
        var idx: usize = 0;
        while (idx < oi.items.len) {
            const start_idx = idx;
            const e = es[oi.items[idx]];
            const start_ln = oi.items[idx] + 1;
            idx += 1;
            while (idx < oi.items.len and
                std.mem.eql(u8, &es[oi.items[idx]].commit_hash, &e.commit_hash) and
                oi.items[idx] == oi.items[idx - 1] + 1) : (idx += 1) {}
            const count = idx - start_idx;
            const orig_ln = if (e.orig_line > 0) e.orig_line else start_ln;
            // Output header
            const hdr = try std.fmt.allocPrint(a, "{s} {d} {d} {d}\n", .{ &e.commit_hash, orig_ln, start_ln, count });
            defer a.free(hdr);
            try pi.writeStdout(hdr);
            // Author info
            const ab = try std.fmt.allocPrint(a, "author {s}\nauthor-mail <{s}>\nauthor-time {d}\nauthor-tz {s}\ncommitter {s}\ncommitter-mail <{s}>\ncommitter-time {d}\ncommitter-tz {s}\nsummary {s}\n", .{
                e.author_name, e.author_email, e.author_time, e.author_tz,
                e.committer_name, e.committer_email, e.committer_time, e.committer_tz, e.summary,
            });
            defer a.free(ab);
            try pi.writeStdout(ab);
            if (e.has_previous) {
                const pv = try std.fmt.allocPrint(a, "previous {s} {s}\n", .{ &e.previous_hash, fp.? });
                defer a.free(pv);
                try pi.writeStdout(pv);
            }
            if (e.is_boundary) try pi.writeStdout("boundary\n");
            const fl = try std.fmt.allocPrint(a, "filename {s}\n", .{fp.?});
            defer a.free(fl);
            try pi.writeStdout(fl);
        }
    } else {
        for (oi.items, 0..) |i, oi_idx| {
            const e = es[i]; const line = lines.items[i]; const ln = i + 1;
            if (sp or slp) {
                const first_time = !seen_hashes.contains(&e.commit_hash);
                if (first_time) seen_hashes.put(&e.commit_hash, {}) catch {};
                const is_group_start = group_sizes[oi_idx] > 0;
                try oP(pi, a, e, line, ln, first_time or slp, fp.?, is_group_start, if (is_group_start) group_sizes[oi_idx] else 0);
            }
            else if (col) { try oC(pi, a, e, line, ln, se, srt, mal, lnw, abl, suppress, blank_boundary); }
            else { try oD(pi, a, e, line, ln, se, srt, mal, lnw, abl, suppress, blank_boundary); }
        }
    }
}

/// Resolve a :funcname pattern to a line range (start, end) 1-based
fn resolveFuncname(pattern: []const u8, file_lines: []const []const u8, search_from: usize) ?struct { start: usize, end: usize } {
    if (pattern.len == 0) return null;
    
    // Find the first line matching the function pattern starting from search_from
    // No wrapping - relative search only goes forward
    var found_line: ?usize = null;
    var i: usize = search_from;
    while (i < file_lines.len) : (i += 1) {
        if (isFuncDefMatch(file_lines[i], pattern)) {
            found_line = i;
            break;
        }
    }
    
    if (found_line == null) return null;
    const start = found_line.? + 1; // 1-based
    
    // Find the end: next function definition or end of file
    var end: usize = file_lines.len;
    var j: usize = found_line.? + 1;
    while (j < file_lines.len) : (j += 1) {
        // Check if this line starts a new function (heuristic: line starts with non-space, non-# and contains '(')
        if (isNewFuncStart(file_lines[j])) {
            end = j; // exclusive
            break;
        }
    }
    
    return .{ .start = start, .end = end };
}

/// Check if a line matches a function definition pattern
fn isFuncDefMatch(line: []const u8, pattern: []const u8) bool {
    // Simple heuristic: the line contains the pattern followed by '(' 
    // or the pattern is a regex that matches the line
    const trimmed = std.mem.trim(u8, line, " \t");
    
    // Try simple pattern matching (like simpleMatch)
    if (simpleMatch(trimmed, pattern)) return true;
    
    // Also check if line contains "pattern(" for function definitions
    if (std.mem.indexOf(u8, trimmed, pattern)) |pos| {
        // Check if followed by '(' somewhere after
        const after = trimmed[pos + pattern.len ..];
        if (std.mem.indexOf(u8, after, "(") != null) return true;
    }
    
    return false;
}

/// Check if a line starts a new function (heuristic)
fn isNewFuncStart(line: []const u8) bool {
    if (line.len == 0) return false;
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    // Skip preprocessor lines, comments, and lines starting with whitespace
    if (line[0] == ' ' or line[0] == '\t' or line[0] == '#' or line[0] == '/' or line[0] == '*') return false;
    if (line[0] == '}') return false;
    if (line[0] == '{') return false;
    // A function definition typically has a '(' or starts a block
    if (std.mem.indexOf(u8, trimmed, "(") != null) return true;
    return false;
}

/// Find the comma separator in an -L range spec, skipping commas inside /regex/
fn findLComma(rs: []const u8) ?usize {
    var i: usize = 0;
    while (i < rs.len) {
        if (rs[i] == '/') {
            // Skip regex
            i += 1;
            while (i < rs.len and rs[i] != '/') : (i += 1) {
                if (rs[i] == '\\' and i + 1 < rs.len) i += 1;
            }
            if (i < rs.len) i += 1; // skip closing /
        } else if (rs[i] == ',') {
            return i;
        } else {
            i += 1;
        }
    }
    return null;
}

/// Resolve a /regex/ pattern to a 1-based line number, searching from start_line (0-based)
fn resolveRegex(spec: []const u8, file_lines: []const []const u8, start_from: usize) ?usize {
    // Extract pattern from /pattern/
    if (spec.len < 2 or spec[0] != '/') return null;
    var end: usize = spec.len;
    if (spec[spec.len - 1] == '/') end = spec.len - 1;
    const pattern = spec[1..end];
    if (pattern.len == 0) return null;

    // Search forward from start_from without wrapping (relative search)
    var i: usize = start_from;
    while (i < file_lines.len) : (i += 1) {
        if (simpleMatch(file_lines[i], pattern)) return i + 1;
    }
    return null;
}

/// Regex-like matching: supports anchors, `.`, `[...]`, `[^...]`, `\` escapes, `*`, `+`, `?`
fn simpleMatch(line: []const u8, pattern: []const u8) bool {
    var anchored_start = false;
    var anchored_end = false;
    var pat = pattern;
    if (pat.len > 0 and pat[0] == '^') {
        anchored_start = true;
        pat = pat[1..];
    }
    if (pat.len > 0 and pat[pat.len - 1] == '$' and (pat.len < 2 or pat[pat.len - 2] != '\\')) {
        anchored_end = true;
        pat = pat[0 .. pat.len - 1];
    }

    if (anchored_start) {
        return regexMatchAt(line, 0, pat, anchored_end);
    } else if (anchored_end) {
        // Try matching at every position, require consuming to end
        var si: usize = 0;
        while (si <= line.len) : (si += 1) {
            if (regexMatchAt(line, si, pat, true)) return true;
        }
        return false;
    } else {
        // Substring match at any position
        if (pat.len == 0) return true;
        var si: usize = 0;
        while (si <= line.len) : (si += 1) {
            if (regexMatchAt(line, si, pat, false)) return true;
        }
        return false;
    }
}

/// Try to match pattern starting at line[pos..], return true if matched
fn regexMatchAt(line: []const u8, start: usize, pat: []const u8, must_reach_end: bool) bool {
    return regexMatchImpl(line, start, pat, 0, must_reach_end);
}

fn regexMatchImpl(line: []const u8, li: usize, pat: []const u8, pi: usize, must_reach_end: bool) bool {
    var lpos = li;
    var ppos = pi;

    while (ppos < pat.len) {
        // Parse current element
        const elem_start = ppos;
        var elem_end = ppos;

        if (pat[ppos] == '\\' and ppos + 1 < pat.len) {
            elem_end = ppos + 2;
        } else if (pat[ppos] == '[') {
            // Find closing ]
            var bi = ppos + 1;
            if (bi < pat.len and pat[bi] == '^') bi += 1;
            if (bi < pat.len and pat[bi] == ']') bi += 1;
            while (bi < pat.len and pat[bi] != ']') : (bi += 1) {}
            if (bi < pat.len) elem_end = bi + 1 else elem_end = pat.len;
        } else if (pat[ppos] == '.') {
            elem_end = ppos + 1;
        } else {
            elem_end = ppos + 1;
        }

        // Check for quantifier
        const has_star = elem_end < pat.len and pat[elem_end] == '*';
        const has_plus = elem_end < pat.len and pat[elem_end] == '+';
        const has_question = elem_end < pat.len and pat[elem_end] == '?';
        const next_ppos = if (has_star or has_plus or has_question) elem_end + 1 else elem_end;

        if (has_star or has_question) {
            // Try 0 matches first (non-greedy for correctness via backtracking)
            if (regexMatchImpl(line, lpos, pat, next_ppos, must_reach_end)) return true;
            if (has_star) {
                // Try 1+ matches
                var count: usize = 0;
                while (lpos + count < line.len and matchOneElement(line[lpos + count], pat[elem_start..elem_end])) {
                    count += 1;
                    if (regexMatchImpl(line, lpos + count, pat, next_ppos, must_reach_end)) return true;
                }
            } else {
                // ? - try 1 match
                if (lpos < line.len and matchOneElement(line[lpos], pat[elem_start..elem_end])) {
                    if (regexMatchImpl(line, lpos + 1, pat, next_ppos, must_reach_end)) return true;
                }
            }
            return false;
        } else if (has_plus) {
            // Must match at least 1
            var count: usize = 0;
            while (lpos + count < line.len and matchOneElement(line[lpos + count], pat[elem_start..elem_end])) {
                count += 1;
            }
            // Try from max down to 1 (greedy)
            while (count > 0) : (count -= 1) {
                if (regexMatchImpl(line, lpos + count, pat, next_ppos, must_reach_end)) return true;
            }
            return false;
        } else {
            // Exactly 1 match required
            if (lpos >= line.len) return false;
            if (!matchOneElement(line[lpos], pat[elem_start..elem_end])) return false;
            lpos += 1;
            ppos = elem_end;
        }
    }

    // Pattern consumed
    if (must_reach_end) return lpos == line.len;
    return true;
}

/// Match a single character against a pattern element
fn matchOneElement(ch: u8, elem: []const u8) bool {
    if (elem.len == 0) return false;
    if (elem[0] == '.') return true; // . matches any
    if (elem[0] == '\\' and elem.len >= 2) return ch == elem[1];
    if (elem[0] == '[') return matchCharClass(ch, elem);
    return ch == elem[0];
}

/// Match character against a character class [...]
fn matchCharClass(ch: u8, elem: []const u8) bool {
    if (elem.len < 2) return false;
    var i: usize = 1;
    var negated = false;
    if (i < elem.len and elem[i] == '^') { negated = true; i += 1; }
    const end = if (elem[elem.len - 1] == ']') elem.len - 1 else elem.len;
    var matched = false;
    // Handle ] as first char in class
    if (i < end and elem[i] == ']') {
        if (ch == ']') matched = true;
        i += 1;
    }
    while (i < end) {
        if (i + 2 < end and elem[i + 1] == '-') {
            // Range a-z
            if (ch >= elem[i] and ch <= elem[i + 2]) matched = true;
            i += 3;
        } else {
            if (ch == elem[i]) matched = true;
            i += 1;
        }
    }
    return if (negated) !matched else matched;
}

fn gf(gp: []const u8, ch: []const u8, fp2: []const u8, a2: std.mem.Allocator) ![]const u8 {
    const bh = try git_helpers_mod.getTreeEntryHashFromCommit(gp, ch, fp2, a2);
    defer a2.free(bh);
    return try git_helpers_mod.readGitObjectContent(gp, bh, a2);
}

fn trav(a: std.mem.Allocator, gp: []const u8, sh: []const u8, fp2: []const u8, tl: []const []const u8, es: []B.BlameEntry, wl: ?[]const []const u8, first_parent_only: bool) !void {
    var ub = try a.alloc(bool, tl.len);
    defer a.free(ub);
    @memset(ub, true);
    if (wl) |cl| {
        const m = try B.doLcs(a, tl, cl);
        defer a.free(m);
        for (0..tl.len) |i| { if (m[i] == std.math.maxInt(usize)) ub[i] = false; }
    }
    const QE = struct { hash: []const u8, idx: []usize };
    var q = std.array_list.Managed(QE).init(a);
    defer { for (q.items) |qe| { a.free(qe.hash); a.free(qe.idx); } q.deinit(); }
    {
        var ii = std.array_list.Managed(usize).init(a);
        defer ii.deinit();
        for (0..tl.len) |i| { if (ub[i]) try ii.append(i); }
        if (ii.items.len > 0) try q.append(.{ .hash = try a.dupe(u8, sh), .idx = try a.dupe(usize, ii.items) });
    }
    var its: usize = 0;
    while (q.items.len > 0 and its < 10000) : (its += 1) {
        const cur = q.orderedRemove(0);
        defer a.free(cur.hash);
        defer a.free(cur.idx);
        var act = std.array_list.Managed(usize).init(a);
        defer act.deinit();
        for (cur.idx) |idx| { if (ub[idx]) try act.append(idx); }
        if (act.items.len == 0) continue;
        const cc = git_helpers_mod.readGitObjectContent(gp, cur.hash, a) catch continue;
        defer a.free(cc);
        const info = B.parseInfo(cc, a) catch continue;
        defer B.freeInfo(info, a);
        var pars = std.array_list.Managed([]const u8).init(a);
        defer { for (pars.items) |p| a.free(p); pars.deinit(); }
        {
            var li = std.mem.splitScalar(u8, cc, '\n');
            while (li.next()) |l| {
                if (std.mem.startsWith(u8, l, "parent ")) try pars.append(try a.dupe(u8, l[7..]));
                if (l.len == 0) break;
            }
        }
        const tf = gf(gp, cur.hash, fp2, a) catch {
            for (act.items) |idx| {
                if (ub[idx]) { B.setEntry(&es[idx], cur.hash, info, a) catch {}; ub[idx] = false; }
            }
            continue;
        };
        defer a.free(tf);
        var tls = B.splitLines(a, tf) catch continue;
        defer tls.deinit();
        const t2t = try B.doLcs(a, tl, tls.items);
        defer a.free(t2t);
        if (pars.items.len == 0) {
            for (act.items) |idx| {
                if (ub[idx] and t2t[idx] != std.math.maxInt(usize)) {
                    B.setEntry(&es[idx], cur.hash, info, a) catch {};
                    es[idx].is_boundary = true;
                    es[idx].orig_line = t2t[idx] + 1;
                    ub[idx] = false;
                }
            }
            continue;
        }
        const fap = try a.alloc(bool, tl.len);
        defer a.free(fap);
        @memset(fap, false);
        const pars_to_check = if (first_parent_only and pars.items.len > 1) pars.items[0..1] else pars.items;
        for (pars_to_check) |ph| {
            const pf = gf(gp, ph, fp2, a) catch continue;
            defer a.free(pf);
            var pl = B.splitLines(a, pf) catch continue;
            defer pl.deinit();
            const t2p = try B.doLcs(a, tls.items, pl.items);
            defer a.free(t2p);
            var pp = std.array_list.Managed(usize).init(a);
            defer pp.deinit();
            for (act.items) |idx| {
                if (ub[idx] and t2t[idx] != std.math.maxInt(usize) and t2p[t2t[idx]] != std.math.maxInt(usize) and !fap[idx]) {
                    fap[idx] = true;
                    try pp.append(idx);
                }
            }
            if (pp.items.len > 0) try q.append(.{ .hash = try a.dupe(u8, ph), .idx = try a.dupe(usize, pp.items) });
        }
        for (act.items) |idx| {
            if (ub[idx] and !fap[idx] and t2t[idx] != std.math.maxInt(usize)) {
                B.setEntry(&es[idx], cur.hash, info, a) catch {};
                es[idx].orig_line = t2t[idx] + 1;
                // Set previous to first parent
                if (pars.items.len > 0) {
                    const prev_h = pars.items[0];
                    const pcl = @min(40, prev_h.len);
                    @memset(&es[idx].previous_hash, 0);
                    @memcpy(es[idx].previous_hash[0..pcl], prev_h[0..pcl]);
                    es[idx].has_previous = true;
                }
                ub[idx] = false;
            }
        }
    }
}

fn oC(so: *const pm.Platform, a: std.mem.Allocator, e: B.BlameEntry, line: []const u8, ln: usize, se2: bool, srt2: bool, mal2: usize, lnw2: usize, abl2: usize, suppress2: bool, bb2: bool) !void {
    const effective_abl = @min(abl2 + 1, 40);
    const hash_str = blk: {
        if (bb2 and e.is_boundary) {
            // blank boundary: spaces instead of hash
            const spaces = try a.alloc(u8, effective_abl);
            @memset(spaces, ' ');
            break :blk spaces;
        } else {
            break :blk try a.dupe(u8, e.commit_hash[0..effective_abl]);
        }
    };
    defer a.free(hash_str);
    if (suppress2) {
        const pnum = try B.padN(a, ln, lnw2);
        defer a.free(pnum);
        const out = try std.fmt.allocPrint(a, "{s}\t{s}){s}\n", .{ hash_str, pnum, line });
        defer a.free(out);
        try so.writeStdout(out);
    } else {
        const dn = if (se2) try std.fmt.allocPrint(a, "<{s}>", .{e.author_email}) else try a.dupe(u8, e.author_name);
        defer a.free(dn);
        // Use at least dn.len + 1 to ensure a space before the author name (for awk parsing)
        const pn = try B.padR(a, dn, @max(mal2, dn.len + 1));
        defer a.free(pn);
        const ds = if (srt2) try std.fmt.allocPrint(a, "{d} {s}", .{ e.author_time, e.author_tz }) else try B.fmtTs(a, e.author_time, e.author_tz);
        defer a.free(ds);
        const pnum = try B.padN(a, ln, lnw2);
        defer a.free(pnum);
        const out = try std.fmt.allocPrint(a, "{s}\t({s}\t{s}\t{s}){s}\n", .{ hash_str, pn, ds, pnum, line });
        defer a.free(out);
        try so.writeStdout(out);
    }
}

fn oD(so: *const pm.Platform, a: std.mem.Allocator, e: B.BlameEntry, line: []const u8, ln: usize, se2: bool, _: bool, mal2: usize, lnw2: usize, abl2: usize, suppress2: bool, bb2: bool) !void {
    // Total visual width for hash field is min(abl2+1, 40) chars
    // Hash display rules:
    // Non-boundary: min(abbrev+1, 40) hex chars
    // Boundary: ^HASH where HASH = min(abbrev+1, 40) - 1 hex chars
    // Exception: when abbrev > 40, show full 40 hex (non-boundary) or ^+40 hex (boundary)
    const field_width: usize = if (abl2 > 40) 40 else @min(abl2 + 1, 40);
    const boundary_total: usize = if (abl2 > 40) 41 else field_width;
    const hash_str = blk: {
        if (bb2 and e.is_boundary) {
            // -b: blank boundary - spaces matching boundary display width
            const spaces = try a.alloc(u8, field_width);
            @memset(spaces, ' ');
            break :blk spaces;
        } else if (e.is_boundary) {
            // ^hash format
            const hex_count = boundary_total - 1;
            break :blk try std.fmt.allocPrint(a, "^{s}", .{e.commit_hash[0..hex_count]});
        } else {
            // non-boundary: field_width hex chars
            break :blk try std.fmt.allocPrint(a, "{s}", .{e.commit_hash[0..field_width]});
        }
    };
    defer a.free(hash_str);
    if (suppress2) {
        const pnum = try B.padN(a, ln, lnw2);
        defer a.free(pnum);
        const out = try std.fmt.allocPrint(a, "{s} {s}) {s}\n", .{ hash_str, pnum, line });
        defer a.free(out);
        try so.writeStdout(out);
    } else {
        const dn = if (se2) try std.fmt.allocPrint(a, "<{s}>", .{e.author_email}) else try a.dupe(u8, e.author_name);
        defer a.free(dn);
        const pn = try B.padR(a, dn, mal2);
        defer a.free(pn);
        const ds = try B.fmtTs(a, e.author_time, e.author_tz);
        defer a.free(ds);
        const pnum = try B.padN(a, ln, lnw2);
        defer a.free(pnum);
        const out = try std.fmt.allocPrint(a, "{s} ({s} {s} {s}) {s}\n", .{ hash_str, pn, ds, pnum, line });
        defer a.free(out);
        try so.writeStdout(out);
    }
}

fn oP(so: *const pm.Platform, a: std.mem.Allocator, e: B.BlameEntry, line: []const u8, ln: usize, sh2: bool, fp2: []const u8, is_group_start2: bool, group_size2: usize) !void {
    const orig_ln = if (e.orig_line > 0) e.orig_line else ln;
    if (sh2) {
        // Full header (first time hash seen or --line-porcelain)
        if (is_group_start2) {
            const h1 = try std.fmt.allocPrint(a, "{s} {d} {d} {d}\n", .{ &e.commit_hash, orig_ln, ln, group_size2 });
            defer a.free(h1);
            try so.writeStdout(h1);
        } else {
            const h1 = try std.fmt.allocPrint(a, "{s} {d} {d}\n", .{ &e.commit_hash, orig_ln, ln });
            defer a.free(h1);
            try so.writeStdout(h1);
        }
        const ab = try std.fmt.allocPrint(a, "author {s}\nauthor-mail <{s}>\nauthor-time {d}\nauthor-tz {s}\ncommitter {s}\ncommitter-mail <{s}>\ncommitter-time {d}\ncommitter-tz {s}\nsummary {s}\n", .{
            e.author_name, e.author_email, e.author_time, e.author_tz,
            e.committer_name, e.committer_email, e.committer_time, e.committer_tz, e.summary,
        });
        defer a.free(ab);
        try so.writeStdout(ab);
        if (e.has_previous) {
            const pv = try std.fmt.allocPrint(a, "previous {s} {s}\n", .{ &e.previous_hash, fp2 });
            defer a.free(pv);
            try so.writeStdout(pv);
        }
        if (e.is_boundary) try so.writeStdout("boundary\n");
        const fl = try std.fmt.allocPrint(a, "filename {s}\n", .{fp2});
        defer a.free(fl);
        try so.writeStdout(fl);
    } else {
        // Continuation (--porcelain, hash already seen)
        if (is_group_start2) {
            const h1 = try std.fmt.allocPrint(a, "{s} {d} {d} {d}\n", .{ &e.commit_hash, orig_ln, ln, group_size2 });
            defer a.free(h1);
            try so.writeStdout(h1);
        } else {
            const h1 = try std.fmt.allocPrint(a, "{s} {d} {d}\n", .{ &e.commit_hash, orig_ln, ln });
            defer a.free(h1);
            try so.writeStdout(h1);
        }
    }
    const cl = try std.fmt.allocPrint(a, "\t{s}\n", .{line});
    defer a.free(cl);
    try so.writeStdout(cl);
}
