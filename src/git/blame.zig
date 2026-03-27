const std = @import("std");

pub const BlameEntry = struct {
    commit_hash: [40]u8,
    author_name: []const u8,
    author_email: []const u8,
    author_time: i64,
    author_tz: []const u8,
    committer_name: []const u8,
    committer_email: []const u8,
    committer_time: i64,
    committer_tz: []const u8,
    summary: []const u8,
    is_default: bool,
};

pub const Info = struct {
    author_name: []const u8,
    author_email: []const u8,
    author_time: i64,
    author_tz: []const u8,
    committer_name: []const u8,
    committer_email: []const u8,
    committer_time: i64,
    committer_tz: []const u8,
    summary: []const u8,
};

pub fn parseInfo(cc: []const u8, alloc: std.mem.Allocator) !Info {
    var an: []const u8 = "Unknown";
    var ae: []const u8 = "unknown";
    var at: i64 = 0;
    var az: []const u8 = "+0000";
    var cn: []const u8 = "Unknown";
    var ce: []const u8 = "unknown";
    var ct: i64 = 0;
    var cz: []const u8 = "+0000";
    var sum: []const u8 = "";
    var body = false;
    var it = std.mem.splitScalar(u8, cc, '\n');
    while (it.next()) |line| {
        if (body) {
            if (line.len > 0 and sum.len == 0) sum = line;
            continue;
        }
        if (line.len == 0) {
            body = true;
            continue;
        }
        const ia = std.mem.startsWith(u8, line, "author ");
        const ic = std.mem.startsWith(u8, line, "committer ");
        if (ia or ic) {
            const pl: usize = if (ia) 7 else 10;
            const r = line[pl..];
            if (std.mem.lastIndexOf(u8, r, ">")) |gt| {
                if (std.mem.lastIndexOf(u8, r[0..gt], "<")) |lt| {
                    const nm = std.mem.trim(u8, r[0..lt], " ");
                    const em = r[lt + 1 .. gt];
                    const af = std.mem.trim(u8, r[gt + 1 ..], " ");
                    var tv: i64 = 0;
                    var tz2: []const u8 = "+0000";
                    if (std.mem.indexOf(u8, af, " ")) |sp| {
                        tv = std.fmt.parseInt(i64, af[0..sp], 10) catch 0;
                        tz2 = af[sp + 1 ..];
                    } else {
                        tv = std.fmt.parseInt(i64, af, 10) catch 0;
                    }
                    if (ia) {
                        an = nm;
                        ae = em;
                        at = tv;
                        az = tz2;
                    } else {
                        cn = nm;
                        ce = em;
                        ct = tv;
                        cz = tz2;
                    }
                }
            }
        }
    }
    return .{
        .author_name = try alloc.dupe(u8, an), .author_email = try alloc.dupe(u8, ae),
        .author_time = at, .author_tz = try alloc.dupe(u8, az),
        .committer_name = try alloc.dupe(u8, cn), .committer_email = try alloc.dupe(u8, ce),
        .committer_time = ct, .committer_tz = try alloc.dupe(u8, cz),
        .summary = try alloc.dupe(u8, sum),
    };
}

pub fn setEntry(e: *BlameEntry, h: []const u8, i: Info, alloc: std.mem.Allocator) !void {
    @memset(&e.commit_hash, '0');
    const cl = @min(40, h.len);
    @memcpy(e.commit_hash[0..cl], h[0..cl]);
    e.author_name = try alloc.dupe(u8, i.author_name);
    e.author_email = try alloc.dupe(u8, i.author_email);
    e.author_time = i.author_time;
    e.author_tz = try alloc.dupe(u8, i.author_tz);
    e.committer_name = try alloc.dupe(u8, i.committer_name);
    e.committer_email = try alloc.dupe(u8, i.committer_email);
    e.committer_time = i.committer_time;
    e.committer_tz = try alloc.dupe(u8, i.committer_tz);
    e.summary = try alloc.dupe(u8, i.summary);
    e.is_default = false;
}

pub fn freeInfo(i: Info, alloc: std.mem.Allocator) void {
    alloc.free(i.author_name);
    alloc.free(i.author_email);
    alloc.free(i.author_tz);
    alloc.free(i.committer_name);
    alloc.free(i.committer_email);
    alloc.free(i.committer_tz);
    alloc.free(i.summary);
}

pub fn doLcs(alloc: std.mem.Allocator, al: []const []const u8, bl: []const []const u8) ![]usize {
    const m = al.len;
    const n = bl.len;
    var r = try alloc.alloc(usize, m);
    @memset(r, std.math.maxInt(usize));
    if (m == 0 or n == 0) return r;
    if (m * n > 10_000_000) {
        var u = try alloc.alloc(bool, n);
        defer alloc.free(u);
        @memset(u, false);
        for (0..m) |i| {
            for (0..n) |j| {
                if (!u[j] and std.mem.eql(u8, al[i], bl[j])) {
                    r[i] = j;
                    u[j] = true;
                    break;
                }
            }
        }
        return r;
    }
    const dp = try alloc.alloc(usize, (m + 1) * (n + 1));
    defer alloc.free(dp);
    const ds = try alloc.alloc(u8, (m + 1) * (n + 1));
    defer alloc.free(ds);
    @memset(dp, 0);
    @memset(ds, 0);
    for (1..m + 1) |i| {
        for (1..n + 1) |j| {
            if (std.mem.eql(u8, al[i - 1], bl[j - 1])) {
                dp[i * (n + 1) + j] = dp[(i - 1) * (n + 1) + (j - 1)] + 1;
                ds[i * (n + 1) + j] = 1;
            } else if (dp[(i - 1) * (n + 1) + j] >= dp[i * (n + 1) + (j - 1)]) {
                dp[i * (n + 1) + j] = dp[(i - 1) * (n + 1) + j];
                ds[i * (n + 1) + j] = 2;
            } else {
                dp[i * (n + 1) + j] = dp[i * (n + 1) + (j - 1)];
                ds[i * (n + 1) + j] = 3;
            }
        }
    }
    var i = m;
    var j = n;
    while (i > 0 and j > 0) {
        if (ds[i * (n + 1) + j] == 1) {
            r[i - 1] = j - 1;
            i -= 1;
            j -= 1;
        } else if (ds[i * (n + 1) + j] == 2) {
            i -= 1;
        } else {
            j -= 1;
        }
    }
    return r;
}

pub fn splitLines(alloc: std.mem.Allocator, c: []const u8) !std.array_list.Managed([]const u8) {
    var l = std.array_list.Managed([]const u8).init(alloc);
    var it = std.mem.splitScalar(u8, c, '\n');
    while (it.next()) |ln| try l.append(ln);
    if (l.items.len > 0 and l.items[l.items.len - 1].len == 0) _ = l.pop();
    return l;
}

pub fn fmtTs(alloc: std.mem.Allocator, ts_in: i64, tz: []const u8) ![]const u8 {
    var ts = ts_in;
    if (tz.len >= 5) {
        const sg: i64 = if (tz[0] == '-') -1 else 1;
        ts += sg * ((std.fmt.parseInt(i64, tz[1..3], 10) catch 0) * 60 + (std.fmt.parseInt(i64, tz[3..5], 10) catch 0)) * 60;
    }
    var days = @divFloor(ts, 86400);
    var rem = @mod(ts, 86400);
    if (rem < 0) {
        rem += 86400;
        days -= 1;
    }
    const h: u32 = @intCast(@divFloor(rem, 3600));
    rem = @mod(rem, 3600);
    const mi: u32 = @intCast(@divFloor(rem, 60));
    const s: u32 = @intCast(@mod(rem, 60));
    var y: i64 = 1970;
    var d = days;
    while (true) {
        const dy: i64 = if (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0)) 366 else 365;
        if (d < dy) break;
        d -= dy;
        y += 1;
    }
    const lp = @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
    const md = [_]u32{ 31, if (lp) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var mo: u32 = 0;
    var dm: u32 = @intCast(d);
    for (md) |m| {
        if (dm < m) break;
        dm -= m;
        mo += 1;
    }
    return try std.fmt.allocPrint(alloc, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s}", .{ y, mo + 1, dm + 1, h, mi, s, tz });
}

pub fn padR(alloc: std.mem.Allocator, str: []const u8, w: usize) ![]const u8 {
    if (str.len >= w) return try alloc.dupe(u8, str);
    var b = std.array_list.Managed(u8).init(alloc);
    var pi: usize = 0;
    while (pi < w - str.len) : (pi += 1) try b.append(' ');
    try b.appendSlice(str);
    return b.toOwnedSlice();
}

pub fn padN(alloc: std.mem.Allocator, num: usize, w: usize) ![]const u8 {
    var nb: [20]u8 = undefined;
    const ns = std.fmt.bufPrint(&nb, "{d}", .{num}) catch "0";
    if (ns.len >= w) return try alloc.dupe(u8, ns);
    var b = std.array_list.Managed(u8).init(alloc);
    var pi: usize = 0;
    while (pi < w - ns.len) : (pi += 1) try b.append(' ');
    try b.appendSlice(ns);
    return b.toOwnedSlice();
}
