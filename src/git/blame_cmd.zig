const std = @import("std");
const pm = @import("../platform/platform.zig");
const refs = @import("refs.zig");
const B = @import("blame.zig");
const mc = @import("../main_common.zig");

pub fn cmdBlame(a: std.mem.Allocator, args: *pm.ArgIterator, pi: *const pm.Platform) !void {
    var col = false;
    var se = false;
    var sp = false;
    var slp = false;
    var srt = false;
    var fp: ?[]const u8 = null;
    var rv: ?[]const u8 = null;
    var cf: ?[]const u8 = null;
    var abl: usize = 8;
    var lr = std.ArrayList([]const u8).init(a);
    defer lr.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-c")) { col = true; }
        else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--show-email")) { se = true; }
        else if (std.mem.eql(u8, arg, "--no-show-email")) { se = false; }
        else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--porcelain")) { sp = true; }
        else if (std.mem.eql(u8, arg, "--line-porcelain")) { slp = true; }
        else if (std.mem.eql(u8, arg, "-t")) { srt = true; }
        else if (std.mem.startsWith(u8, arg, "--contents=")) { cf = arg["--contents=".len..]; }
        else if (std.mem.eql(u8, arg, "--contents")) { cf = args.next(); }
        else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
            abl = std.fmt.parseInt(usize, arg["--abbrev=".len..], 10) catch 8;
            if (abl < 4) abl = 4;
            if (abl > 40) abl = 40;
        }
        else if (std.mem.eql(u8, arg, "-l")) { abl = 40; }
        else if (std.mem.startsWith(u8, arg, "-L")) {
            try lr.append(if (arg.len > 2) arg[2..] else (args.next() orelse ""));
        }
        else if (std.mem.eql(u8, arg, "--")) { fp = args.next(); break; }
        else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try pi.writeStdout("usage: git blame [<options>] [<rev>] [--] <file>\n");
            std.process.exit(129);
        }
        else if (arg.len > 0 and arg[0] == '-') {}
        else {
            if (fp == null) {
                if (std.fs.cwd().access(arg, .{})) |_| { fp = arg; } else |_| {
                    if (rv == null) rv = arg else fp = arg;
                }
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
    if (!se) {
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
    if (rv) |r| { hh = refs.resolveRef(gp, r, pi, a) catch null; }
    else { hh = refs.resolveRef(gp, "HEAD", pi, a) catch null; }

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
    if (lines.items.len == 0) return;

    const es = try a.alloc(B.BlameEntry, lines.items.len);
    defer a.free(es);
    const da: []const u8 = if (cf != null) "External file (--contents)" else "Not Committed Yet";
    const de: []const u8 = if (cf != null) "external.file" else "not.committed.yet";
    for (es) |*e| {
        @memset(&e.commit_hash, '0');
        e.author_name = da; e.author_email = de; e.author_time = std.time.timestamp(); e.author_tz = "+0000";
        e.committer_name = da; e.committer_email = de; e.committer_time = std.time.timestamp(); e.committer_tz = "+0000";
        e.summary = ""; e.is_default = true;
    }

    if (hh) |sh| {
        const cfc = gf(gp, sh, fp.?, a) catch null;
        var cl2 = std.ArrayList([]const u8).init(a);
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
    var oi = std.ArrayList(usize).init(a);
    defer oi.deinit();
    if (lr.items.len == 0) {
        for (0..lines.items.len) |i| try oi.append(i);
    } else {
        const inc = try a.alloc(bool, lines.items.len);
        defer a.free(inc);
        @memset(inc, false);
        for (lr.items) |rs| {
            var s: usize = 1;
            var e: usize = lines.items.len;
            if (std.mem.indexOf(u8, rs, ",")) |comma| {
                const ss = rs[0..comma];
                const ess = rs[comma + 1 ..];
                if (ss.len > 0) {
                    if (ss[0] == '-') { try pi.writeStderr("fatal: -L invalid line range\n"); std.process.exit(128); }
                    s = std.fmt.parseInt(usize, ss, 10) catch 1;
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
                    } else {
                        e = std.fmt.parseInt(usize, ess, 10) catch lines.items.len;
                        if (e == 0) { try pi.writeStderr("fatal: -L invalid line range\n"); std.process.exit(128); }
                    }
                }
            } else if (rs.len > 0) {
                if (rs[0] == '-') { try pi.writeStderr("fatal: -L invalid line range\n"); std.process.exit(128); }
                s = std.fmt.parseInt(usize, rs, 10) catch 1;
            }
            if (s == 0) { try pi.writeStderr("fatal: -L invalid line range\n"); std.process.exit(128); }
            if (s > e) { const t = s; s = e; e = t; }
            if (s < 1) s = 1;
            if (e > lines.items.len) e = lines.items.len;
            if (s <= e) { for (s - 1..e) |i| inc[i] = true; }
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

    for (oi.items) |i| {
        const e = es[i]; const line = lines.items[i]; const ln = i + 1;
        if (sp or slp) { try oP(pi, a, e, line, ln, i == 0 or slp, fp.?); }
        else if (col) { try oC(pi, a, e, line, ln, se, srt, mal, lnw, abl); }
        else { try oD(pi, a, e, line, ln, se, srt, mal, lnw, abl); }
    }
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
    var q = std.ArrayList(QE).init(a);
    defer { for (q.items) |qe| { a.free(qe.hash); a.free(qe.idx); } q.deinit(); }
    {
        var ii = std.ArrayList(usize).init(a);
        defer ii.deinit();
        for (0..tl.len) |i| { if (ub[i]) try ii.append(i); }
        if (ii.items.len > 0) try q.append(.{ .hash = try a.dupe(u8, sh), .idx = try a.dupe(usize, ii.items) });
    }
    var its: usize = 0;
    while (q.items.len > 0 and its < 10000) : (its += 1) {
        const cur = q.orderedRemove(0);
        defer a.free(cur.hash);
        defer a.free(cur.idx);
        var act = std.ArrayList(usize).init(a);
        defer act.deinit();
        for (cur.idx) |idx| { if (ub[idx]) try act.append(idx); }
        if (act.items.len == 0) continue;
        const cc = mc.readGitObjectContent(gp, cur.hash, a) catch continue;
        defer a.free(cc);
        const info = B.parseInfo(cc, a) catch continue;
        defer B.freeInfo(info, a);
        var pars = std.ArrayList([]const u8).init(a);
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
            var pp = std.ArrayList(usize).init(a);
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
                ub[idx] = false;
            }
        }
    }
}

fn oC(so: *const pm.Platform, a: std.mem.Allocator, e: B.BlameEntry, line: []const u8, ln: usize, se2: bool, srt2: bool, mal2: usize, lnw2: usize, abl2: usize) !void {
    const dn = if (se2) try std.fmt.allocPrint(a, "<{s}>", .{e.author_email}) else try a.dupe(u8, e.author_name);
    defer a.free(dn);
    const pn = try B.padR(a, dn, mal2);
    defer a.free(pn);
    const ds = if (srt2) try std.fmt.allocPrint(a, "{d} {s}", .{ e.author_time, e.author_tz }) else try B.fmtTs(a, e.author_time, e.author_tz);
    defer a.free(ds);
    const pnum = try B.padN(a, ln, lnw2);
    defer a.free(pnum);
    const out = try std.fmt.allocPrint(a, "{s}\t({s}\t{s}\t{s}){s}\n", .{ e.commit_hash[0..abl2], pn, ds, pnum, line });
    defer a.free(out);
    try so.writeStdout(out);
}

fn oD(so: *const pm.Platform, a: std.mem.Allocator, e: B.BlameEntry, line: []const u8, ln: usize, se2: bool, _: bool, mal2: usize, lnw2: usize, abl2: usize) !void {
    const dn = if (se2) try std.fmt.allocPrint(a, "<{s}>", .{e.author_email}) else try a.dupe(u8, e.author_name);
    defer a.free(dn);
    const pn = try B.padR(a, dn, mal2);
    defer a.free(pn);
    const ds = try B.fmtTs(a, e.author_time, e.author_tz);
    defer a.free(ds);
    const pnum = try B.padN(a, ln, lnw2);
    defer a.free(pnum);
    const out = try std.fmt.allocPrint(a, "{s} ({s} {s} {s}) {s}\n", .{ e.commit_hash[0..abl2], pn, ds, pnum, line });
    defer a.free(out);
    try so.writeStdout(out);
}

fn oP(so: *const pm.Platform, a: std.mem.Allocator, e: B.BlameEntry, line: []const u8, ln: usize, sh2: bool, fp2: []const u8) !void {
    if (sh2) {
        const h = try std.fmt.allocPrint(a, "{s} {d} {d} 1\nauthor {s}\nauthor-mail <{s}>\nauthor-time {d}\nauthor-tz {s}\ncommitter {s}\ncommitter-mail <{s}>\ncommitter-time {d}\ncommitter-tz {s}\nsummary {s}\nfilename {s}\n", .{
            &e.commit_hash, ln, ln, e.author_name, e.author_email, e.author_time, e.author_tz,
            e.committer_name, e.committer_email, e.committer_time, e.committer_tz, e.summary, fp2,
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
