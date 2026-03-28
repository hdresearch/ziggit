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
    var fp: ?[]const u8 = null;
    var rv: ?[]const u8 = null;
    var cf: ?[]const u8 = null;
    var abl: usize = 7;
    var show_progress = false;
    var lr = std.array_list.Managed([]const u8).init(a);
    defer lr.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-c")) { col = true; }
        else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--show-email")) { se = true; se_explicit = true; }
        else if (std.mem.eql(u8, arg, "--no-show-email")) { se = false; se_explicit = true; }
        else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--porcelain")) { sp = true; }
        else if (std.mem.eql(u8, arg, "--line-porcelain")) { slp = true; }
        else if (std.mem.eql(u8, arg, "-t")) { srt = true; }
        else if (std.mem.eql(u8, arg, "-s")) { suppress = true; }
        else if (std.mem.eql(u8, arg, "-b")) { blank_boundary = true; }
        else if (std.mem.startsWith(u8, arg, "--contents=")) { cf = arg["--contents=".len..]; }
        else if (std.mem.eql(u8, arg, "--contents")) { cf = args.next(); }
        else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
            abl = std.fmt.parseInt(usize, arg["--abbrev=".len..], 10) catch 7;
            if (abl < 4) abl = 4;
            if (abl > 40) abl = 40;
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
    if (fp == null) { try pi.writeStderr("usage: git blame [<options>] [<rev>] [--] <file>\n"); std.process.exit(128); }

    const gp = mc.findGitDirectory(a, pi) catch {
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
        const actual_rev = if (r.len > 0 and r[0] == '^') r[1..] else r;
        hh = mc.resolveRevision(gp, actual_rev, pi, a) catch (refs.resolveRef(gp, actual_rev, pi, a) catch null);
        // Dereference tag objects to commits (follow chain)
        if (hh) |h| {
            var cur_h = h;
            var depth: u32 = 0;
            while (depth < 10) : (depth += 1) {
                const data = mc.readGitObjectContent(gp, cur_h, a) catch break;
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
        try trav(a, gp, sh, fp.?, lines.items, es, wcl);
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
                        e = resolveRegex(ess[1..], lines.items, 0) orelse {
                            try pi.writeStderr("fatal: -L: no match\n");
                            std.process.exit(128);
                            unreachable;
                        };
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

/// Resolve a :funcname pattern to a line range (start, end) 1-based
fn resolveFuncname(pattern: []const u8, file_lines: []const []const u8, search_from: usize) ?struct { start: usize, end: usize } {
    if (pattern.len == 0) return null;
    
    // Find the first line matching the function pattern starting from search_from
    var found_line: ?usize = null;
    var i: usize = search_from;
    while (i < file_lines.len) : (i += 1) {
        if (isFuncDefMatch(file_lines[i], pattern)) {
            found_line = i;
            break;
        }
    }
    // Wrap around if not found
    if (found_line == null and search_from > 0) {
        i = 0;
        while (i < search_from) : (i += 1) {
            if (isFuncDefMatch(file_lines[i], pattern)) {
                found_line = i;
                break;
            }
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

    // Search from start_from forward (wrapping if needed)
    var i: usize = start_from;
    var checked: usize = 0;
    while (checked < file_lines.len) : (checked += 1) {
        if (i >= file_lines.len) i = 0;
        if (simpleMatch(file_lines[i], pattern)) return i + 1;
        i += 1;
    }
    return null;
}

/// Simple regex-like matching: supports basic substring matching with some regex features
fn simpleMatch(line: []const u8, pattern: []const u8) bool {
    // For basic patterns, do substring search
    // Handle common regex escapes and anchors
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
    // Remove escapes for literal matching
    var cleaned: [1024]u8 = undefined;
    var ci: usize = 0;
    var pi2: usize = 0;
    while (pi2 < pat.len and ci < cleaned.len) {
        if (pat[pi2] == '\\' and pi2 + 1 < pat.len) {
            pi2 += 1;
            cleaned[ci] = pat[pi2];
            ci += 1;
            pi2 += 1;
        } else if (pat[pi2] == '.') {
            // . matches any character - use as wildcard marker
            cleaned[ci] = 0; // sentinel for wildcard
            ci += 1;
            pi2 += 1;
        } else {
            cleaned[ci] = pat[pi2];
            ci += 1;
            pi2 += 1;
        }
    }
    const clean = cleaned[0..ci];

    if (anchored_start and anchored_end) {
        return matchWithWildcard(line, clean);
    } else if (anchored_start) {
        if (line.len < clean.len) return false;
        return matchWithWildcard(line[0..clean.len], clean);
    } else if (anchored_end) {
        if (line.len < clean.len) return false;
        return matchWithWildcard(line[line.len - clean.len ..], clean);
    } else {
        // Substring match
        if (clean.len == 0) return true;
        if (line.len < clean.len) return false;
        var si: usize = 0;
        while (si <= line.len - clean.len) : (si += 1) {
            if (matchWithWildcard(line[si .. si + clean.len], clean)) return true;
        }
        return false;
    }
}

fn matchWithWildcard(text: []const u8, pattern: []const u8) bool {
    if (text.len != pattern.len) return false;
    for (0..text.len) |i| {
        if (pattern[i] == 0) continue; // wildcard matches anything
        if (text[i] != pattern[i]) return false;
    }
    return true;
}

fn gf(gp: []const u8, ch: []const u8, fp2: []const u8, a2: std.mem.Allocator) ![]const u8 {
    const bh = try mc.getTreeEntryHashFromCommit(gp, ch, fp2, a2);
    defer a2.free(bh);
    return try mc.readGitObjectContent(gp, bh, a2);
}

fn trav(a: std.mem.Allocator, gp: []const u8, sh: []const u8, fp2: []const u8, tl: []const []const u8, es: []B.BlameEntry, wl: ?[]const []const u8) !void {
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
        const cc = mc.readGitObjectContent(gp, cur.hash, a) catch continue;
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
        for (pars.items) |ph| {
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
                    const ph = pars.items[0];
                    const cl2 = @min(40, ph.len);
                    @memcpy(es[idx].previous_hash[0..cl2], ph[0..cl2]);
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
        const pn = try B.padR(a, dn, mal2);
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
    const total_width = @min(abl2 + 1, 40);
    const hash_str = blk: {
        if (bb2 and e.is_boundary) {
            // -b: blank boundary - spaces for the entire hash width
            const spaces = try a.alloc(u8, total_width);
            @memset(spaces, ' ');
            break :blk spaces;
        } else if (e.is_boundary) {
            // ^hash format: ^ + (total_width - 1) hex chars
            break :blk try std.fmt.allocPrint(a, "^{s}", .{e.commit_hash[0..total_width - 1]});
        } else {
            // non-boundary: total_width hex chars
            break :blk try std.fmt.allocPrint(a, "{s}", .{e.commit_hash[0..total_width]});
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

fn oP(so: *const pm.Platform, a: std.mem.Allocator, e: B.BlameEntry, line: []const u8, ln: usize, sh2: bool, fp2: []const u8) !void {
    if (sh2) {
        const boundary_line = if (e.is_boundary) "boundary\n" else "";
        const h = try std.fmt.allocPrint(a, "{s} {d} {d} 1\nauthor {s}\nauthor-mail <{s}>\nauthor-time {d}\nauthor-tz {s}\ncommitter {s}\ncommitter-mail <{s}>\ncommitter-time {d}\ncommitter-tz {s}\nsummary {s}\n{s}filename {s}\n", .{
            &e.commit_hash, ln, ln, e.author_name, e.author_email, e.author_time, e.author_tz,
            e.committer_name, e.committer_email, e.committer_time, e.committer_tz, e.summary, boundary_line, fp2,
        });
        defer a.free(h);
        try so.writeStdout(h);
    } else {
        const h = try std.fmt.allocPrint(a, "{s} {d} {d}\n", .{ &e.commit_hash, ln, ln });
        defer a.free(h);
        try so.writeStdout(h);
    }
    const cl = try std.fmt.allocPrint(a, "\t{s}\n", .{line});
    defer a.free(cl);
    try so.writeStdout(cl);
}
