const std = @import("std");
const tree_mod = @import("tree.zig");
const objects = @import("objects.zig");
const platform_mod = @import("../platform/platform.zig");

pub fn countLines(ct: []const u8) usize {
    if (ct.len == 0) return 0;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, ct, '\n');
    while (it.next()) |_| count += 1;
    if (ct[ct.len - 1] == '\n') count -= 1;
    return count;
}

pub fn isBinContent(content: []const u8) bool {
    const check_len = @min(content.len, 8000);
    for (content[0..check_len]) |c| {
        if (c == 0) return true;
    }
    return false;
}

fn computeLCSLen(a: []const []const u8, b: []const []const u8) usize {
    if (a.len == 0 or b.len == 0) return 0;
    const short = if (a.len <= b.len) a else b;
    const long = if (a.len <= b.len) b else a;
    const row = std.heap.page_allocator.alloc(usize, short.len + 1) catch return 0;
    defer std.heap.page_allocator.free(row);
    @memset(row, 0);
    for (long) |long_line| {
        var prev: usize = 0;
        for (short, 0..) |short_line, j| {
            const temp = row[j + 1];
            if (std.mem.eql(u8, long_line, short_line)) { row[j + 1] = prev + 1; } else { row[j + 1] = @max(row[j + 1], row[j]); }
            prev = temp;
        }
    }
    return row[short.len];
}

pub fn countInsDels(old_content: []const u8, new_content: []const u8) struct { ins: usize, dels: usize } {
    var old_lines = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
    defer old_lines.deinit();
    var new_lines = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
    defer new_lines.deinit();
    var oit = std.mem.splitScalar(u8, old_content, '\n');
    while (oit.next()) |line| old_lines.append(line) catch {};
    var nit = std.mem.splitScalar(u8, new_content, '\n');
    while (nit.next()) |line| new_lines.append(line) catch {};
    if (old_lines.items.len > 0 and old_content.len > 0 and old_content[old_content.len - 1] == '\n') _ = old_lines.pop();
    if (new_lines.items.len > 0 and new_content.len > 0 and new_content[new_content.len - 1] == '\n') _ = new_lines.pop();
    if (old_lines.items.len == 0) return .{ .ins = new_lines.items.len, .dels = 0 };
    if (new_lines.items.len == 0) return .{ .ins = 0, .dels = old_lines.items.len };
    const lcs_len = computeLCSLen(old_lines.items, new_lines.items);
    return .{ .ins = new_lines.items.len - lcs_len, .dels = old_lines.items.len - lcs_len };
}

pub const StatEntry = struct { path: []const u8, insertions: usize, deletions: usize, is_binary: bool, is_new: bool, is_deleted: bool };

fn loadBlob(allocator: std.mem.Allocator, hash: []const u8, git_path: []const u8, platform_impl: *const platform_mod.Platform) ![]u8 {
    const obj = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch return error.ObjectNotFound;
    defer obj.deinit(allocator);
    if (obj.type != .blob) return error.NotABlob;
    return allocator.dupe(u8, obj.data);
}

fn isTreeMd(mode: []const u8) bool { return std.mem.eql(u8, mode, "40000") or std.mem.eql(u8, mode, "040000"); }

fn matchPs(path: []const u8, pathspecs: []const []const u8) bool {
    if (pathspecs.len == 0) return true;
    for (pathspecs) |ps| {
        if (std.mem.eql(u8, path, ps)) return true;
        if (std.mem.startsWith(u8, path, ps) and path.len > ps.len and path[ps.len] == '/') return true;
        if (std.mem.startsWith(u8, ps, path) and ps.len > path.len and ps[path.len] == '/') return true;
    }
    return false;
}

pub fn collectAccurate(allocator: std.mem.Allocator, t1h: []const u8, t2h: []const u8, prefix: []const u8, git_path: []const u8, pathspecs: []const []const u8, pi: *const platform_mod.Platform, out: *std.array_list.Managed(StatEntry)) !void {
    const t1o = objects.GitObject.load(t1h, git_path, pi, allocator) catch return;
    defer t1o.deinit(allocator);
    const t2o = objects.GitObject.load(t2h, git_path, pi, allocator) catch return;
    defer t2o.deinit(allocator);
    var p1 = tree_mod.parseTree(t1o.data, allocator) catch return;
    defer p1.deinit();
    var p2 = tree_mod.parseTree(t2o.data, allocator) catch return;
    defer p2.deinit();
    var m1 = std.StringHashMap(tree_mod.TreeEntry).init(allocator);
    defer m1.deinit();
    var m2 = std.StringHashMap(tree_mod.TreeEntry).init(allocator);
    defer m2.deinit();
    for (p1.items) |e| m1.put(e.name, e) catch {};
    for (p2.items) |e| m2.put(e.name, e) catch {};
    var an = std.StringHashMap(void).init(allocator);
    defer an.deinit();
    for (p1.items) |e| an.put(e.name, {}) catch {};
    for (p2.items) |e| an.put(e.name, {}) catch {};
    var nl = std.array_list.Managed([]const u8).init(allocator);
    defer nl.deinit();
    var ki = an.keyIterator();
    while (ki.next()) |k| try nl.append(k.*);
    std.mem.sort([]const u8, nl.items, {}, struct { fn c(_: void, a: []const u8, b: []const u8) bool { return std.mem.order(u8, a, b) == .lt; } }.c);
    for (nl.items) |name| {
        const e1 = m1.get(name);
        const e2 = m2.get(name);
        const fn2 = if (prefix.len > 0) try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name }) else try allocator.dupe(u8, name);
        if (e1 != null and e2 != null) {
            if (std.mem.eql(u8, e1.?.hash, e2.?.hash) and std.mem.eql(u8, e1.?.mode, e2.?.mode)) { allocator.free(fn2); continue; }
            if (std.mem.eql(u8, e1.?.hash, e2.?.hash)) { if (!matchPs(fn2, pathspecs)) { allocator.free(fn2); continue; } try out.append(.{ .path = fn2, .insertions = 0, .deletions = 0, .is_binary = false, .is_new = false, .is_deleted = false }); continue; }
            if (isTreeMd(e1.?.mode) and isTreeMd(e2.?.mode)) { try collectAccurate(allocator, e1.?.hash, e2.?.hash, fn2, git_path, pathspecs, pi, out); allocator.free(fn2); continue; }
            if (!matchPs(fn2, pathspecs)) { allocator.free(fn2); continue; }
            const oc = loadBlob(allocator, e1.?.hash, git_path, pi) catch "";
            defer if (oc.len > 0) allocator.free(oc);
            const nc = loadBlob(allocator, e2.?.hash, git_path, pi) catch "";
            defer if (nc.len > 0) allocator.free(nc);
            const r = countInsDels(oc, nc);
            try out.append(.{ .path = fn2, .insertions = r.ins, .deletions = r.dels, .is_binary = isBinContent(oc) or isBinContent(nc), .is_new = false, .is_deleted = false });
        } else if (e1 != null and e2 == null) {
            if (isTreeMd(e1.?.mode)) { try collectAccurate(allocator, e1.?.hash, "4b825dc642cb6eb9a060e54bf899d69f82cf0101", fn2, git_path, pathspecs, pi, out); allocator.free(fn2); continue; }
            if (!matchPs(fn2, pathspecs)) { allocator.free(fn2); continue; }
            const dc = loadBlob(allocator, e1.?.hash, git_path, pi) catch "";
            defer if (dc.len > 0) allocator.free(dc);
            try out.append(.{ .path = fn2, .insertions = 0, .deletions = countLines(dc), .is_binary = isBinContent(dc), .is_new = false, .is_deleted = true });
        } else if (e2 != null) {
            if (isTreeMd(e2.?.mode)) { try collectAccurate(allocator, "4b825dc642cb6eb9a060e54bf899d69f82cf0101", e2.?.hash, fn2, git_path, pathspecs, pi, out); allocator.free(fn2); continue; }
            if (!matchPs(fn2, pathspecs)) { allocator.free(fn2); continue; }
            const ac = loadBlob(allocator, e2.?.hash, git_path, pi) catch "";
            defer if (ac.len > 0) allocator.free(ac);
            try out.append(.{ .path = fn2, .insertions = countLines(ac), .deletions = 0, .is_binary = isBinContent(ac), .is_new = true, .is_deleted = false });
        } else { allocator.free(fn2); }
    }
}

pub fn formatStat(entries: []const StatEntry, pi: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    if (entries.len == 0) return;
    var mpl: usize = 0;
    for (entries) |e| { if (e.path.len > mpl) mpl = e.path.len; }
    var ti: usize = 0;
    var td: usize = 0;
    for (entries) |e| {
        ti += e.insertions; td += e.deletions;
        const t = e.insertions + e.deletions;
        const p = mpl - e.path.len;
        const pb = try allocator.alloc(u8, p);
        defer allocator.free(pb);
        @memset(pb, ' ');
        if (e.is_binary) {
            const l = try std.fmt.allocPrint(allocator, " {s}{s} | Bin\n", .{ e.path, pb }); defer allocator.free(l); try pi.writeStdout(l);
        } else if (t == 0) {
            const l = try std.fmt.allocPrint(allocator, " {s}{s} | 0\n", .{ e.path, pb }); defer allocator.free(l); try pi.writeStdout(l);
        } else {
            const plb = try allocator.alloc(u8, e.insertions); defer allocator.free(plb); @memset(plb, '+');
            const mb = try allocator.alloc(u8, e.deletions); defer allocator.free(mb); @memset(mb, '-');
            const l = try std.fmt.allocPrint(allocator, " {s}{s} | {d} {s}{s}\n", .{ e.path, pb, t, plb, mb }); defer allocator.free(l); try pi.writeStdout(l);
        }
    }
    var s = std.array_list.Managed(u8).init(allocator); defer s.deinit();
    const w = s.writer();
    try w.print(" {d} file{s} changed", .{ entries.len, if (entries.len != 1) "s" else "" });
    if (ti > 0 or (ti == 0 and td == 0)) try w.print(", {d} insertion{s}(+)", .{ ti, if (ti != 1) "s" else "" });
    if (td > 0 or (ti == 0 and td == 0)) try w.print(", {d} deletion{s}(-)", .{ td, if (td != 1) "s" else "" });
    try w.writeAll("\n");
    try pi.writeStdout(s.items);
}
