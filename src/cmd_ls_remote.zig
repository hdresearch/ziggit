// Auto-generated from main_common.zig - cmd_ls_remote
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_remote = @import("cmd_remote.zig");
const cmd_show_ref = @import("cmd_show_ref.zig");

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

pub fn nativeCmdLsRemote(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var show_tags = false; var show_heads = false; var symref_flag = false;
    var quiet = false; var ecf = false; var get_url = false;
    var patterns = std.ArrayList([]const u8).init(allocator); defer patterns.deinit();
    var remote_arg: ?[]const u8 = null; var saw_dd = false;
    var ii = command_index + 1;
    while (ii < args.len) : (ii += 1) { const arg = args[ii];
        if (saw_dd) { try patterns.append(arg); continue; }
        if (std.mem.eql(u8, arg, "--")) { saw_dd = true; }
        else if (std.mem.eql(u8, arg, "--tags") or std.mem.eql(u8, arg, "-t")) { show_tags = true; }
        else if (std.mem.eql(u8, arg, "--heads") or std.mem.eql(u8, arg, "--branches") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "-b")) { show_heads = true; }
        else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) { quiet = true; }
        else if (std.mem.eql(u8, arg, "--exit-code")) { ecf = true; }
        else if (std.mem.eql(u8, arg, "--get-url")) { get_url = true; }
        else if (std.mem.eql(u8, arg, "--symref")) { symref_flag = true; }
        else if (std.mem.eql(u8, arg, "--sort") or std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--upload-pack") or std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--server-option")) { ii += 1; }
        else if (std.mem.startsWith(u8, arg, "--sort=") or std.mem.startsWith(u8, arg, "--upload-pack=") or std.mem.eql(u8, arg, "--refs")) {}
        else if (!std.mem.startsWith(u8, arg, "-")) { if (remote_arg == null) remote_arg = arg else try patterns.append(arg); } }
    var drb: ?[]u8 = null; defer if (drb) |b| allocator.free(b);
    const rn: []const u8 = remote_arg orelse blk: {
        const gd = helpers.findGitDir() catch { try platform_impl.writeStderr("fatal: helpers.No remote configured to list helpers.refs from.\n"); std.process.exit(2); };
        if (helpers.getRemoteUrl(gd, "origin", platform_impl, allocator)) |u| { allocator.free(u); break :blk "origin"; } else |_| {
            const f = helpers.t5FindSingle(allocator, gd); if (f) |n| { drb = n; break :blk n; }
            try platform_impl.writeStderr("fatal: helpers.No remote configured to list helpers.refs from.\n"); std.process.exit(2); } };
    const tgd = helpers.t5ResolveRemote(allocator, rn, platform_impl) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' does not appear to be a git repository\nfatal: helpers.Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n", .{rn});
        defer allocator.free(msg); try platform_impl.writeStderr(msg); std.process.exit(128); };
    defer allocator.free(tgd);
    if (get_url) { var du: []const u8 = rn; var duo: ?[]u8 = null; defer if (duo) |u| allocator.free(u);
        if (helpers.findGitDir() catch null) |gd| { if (helpers.getRemoteUrl(gd, rn, platform_impl, allocator)) |u| { duo = u; du = u; } else |_| {} }
        const o = try std.fmt.allocPrint(allocator, "{s}\n", .{du}); defer allocator.free(o); try platform_impl.writeStdout(o); return; }
    if (quiet) return;
    { var du: []const u8 = rn; var duo: ?[]u8 = null; defer if (duo) |u| allocator.free(u);
      if (helpers.findGitDir() catch null) |gd| { if (helpers.getRemoteUrl(gd, rn, platform_impl, allocator)) |u| { duo = u; du = u; } else |_| {} }
      const fm = try std.fmt.allocPrint(allocator, "From {s}\n", .{du}); defer allocator.free(fm); try platform_impl.writeStderr(fm); }
    var rl = std.ArrayList(helpers.RefEntry).init(allocator);
    defer { for (rl.items) |e| { allocator.free(e.name); allocator.free(e.hash); } rl.deinit(); }
    var pm = std.StringHashMap([]const u8).init(allocator);
    defer { var pit = pm.iterator(); while (pit.next()) |e| { allocator.free(e.key_ptr.*); allocator.free(e.value_ptr.*); } pm.deinit(); }
    var hs: ?[]const u8 = null; defer if (hs) |t| allocator.free(t);
    const hp = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{tgd}); defer allocator.free(hp);
    if (std.fs.cwd().readFileAlloc(allocator, hp, 4096)) |hc| { defer allocator.free(hc); const tr = std.mem.trim(u8, hc, " \t\r\n");
        if (std.mem.startsWith(u8, tr, "ref: ")) { hs = try allocator.dupe(u8, tr["ref: ".len..]);
            if (refs.resolveRef(tgd, tr["ref: ".len..], platform_impl, allocator) catch null) |h2| { defer allocator.free(h2); try rl.append(.{ .name = try allocator.dupe(u8, "HEAD"), .hash = try allocator.dupe(u8, h2) }); }
        } else if (tr.len >= 40) { try rl.append(.{ .name = try allocator.dupe(u8, "HEAD"), .hash = try allocator.dupe(u8, tr[0..40]) }); } } else |_| {}
    const pp = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{tgd}); defer allocator.free(pp);
    if (std.fs.cwd().readFileAlloc(allocator, pp, 10*1024*1024)) |pc| { defer allocator.free(pc); var lines = std.mem.splitScalar(u8, pc, '\n'); var lrn3: ?[]const u8 = null;
        while (lines.next()) |line| { if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '^') { if (lrn3) |l| { const ph = std.mem.trim(u8, line[1..], " \t\r\n"); if (ph.len >= 40) try pm.put(try allocator.dupe(u8, l), try allocator.dupe(u8, ph[0..40])); } continue; }
            if (std.mem.indexOfScalar(u8, line, ' ')) |si| { const h = line[0..si]; const n = line[si+1..]; if (h.len >= 40) { var d = false; for (rl.items) |e| { if (std.mem.eql(u8, e.name, n)) { d = true; break; } } if (!d) { try rl.append(.{ .name = try allocator.dupe(u8, n), .hash = try allocator.dupe(u8, h[0..40]) }); lrn3 = rl.items[rl.items.len-1].name; } } } } } else |_| {}
    try helpers.collectLooseRefs(allocator, tgd, "refs", &rl, platform_impl);
    std.mem.sort(helpers.RefEntry, rl.items, {}, struct { fn lt(_: void, a: helpers.RefEntry, b: helpers.RefEntry) bool { if (std.mem.eql(u8, a.name, "HEAD")) return true; if (std.mem.eql(u8, b.name, "HEAD")) return false; return std.mem.order(u8, a.name, b.name).compare(.lt); } }.lt);
    var fa = false;
    for (rl.items) |entry| { if (entry.broken) continue;
        if (show_tags and !show_heads and !std.mem.startsWith(u8, entry.name, "refs/tags/")) continue;
        if (show_heads and !show_tags and !std.mem.startsWith(u8, entry.name, "refs/heads/")) continue;
        if (show_heads and show_tags and !std.mem.startsWith(u8, entry.name, "refs/heads/") and !std.mem.startsWith(u8, entry.name, "refs/tags/")) continue;
        if (patterns.items.len > 0) { var m = false; for (patterns.items) |p| { if (helpers.t5LsMatch(entry.name, p)) { m = true; break; } } if (!m) continue; }
        fa = true;
        if (symref_flag and std.mem.eql(u8, entry.name, "HEAD")) { if (hs) |t| { const so = try std.fmt.allocPrint(allocator, "ref: {s}\tHEAD\n", .{t}); defer allocator.free(so); try platform_impl.writeStdout(so); } }
        const o = try std.fmt.allocPrint(allocator, "{s}\t{s}\n", .{entry.hash, entry.name}); defer allocator.free(o); try platform_impl.writeStdout(o);
        if (std.mem.startsWith(u8, entry.name, "refs/tags/")) { if (pm.get(entry.name)) |ph| { const po = try std.fmt.allocPrint(allocator, "{s}\t{s}^{{}}\n", .{ph, entry.name}); defer allocator.free(po); try platform_impl.writeStdout(po); } } }
    if (ecf and !fa) std.process.exit(2);
}