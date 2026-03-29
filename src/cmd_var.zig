// Auto-generated from main_common.zig - cmd_var
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

pub fn nativeCmdVar(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    const allocator = std.heap.page_allocator;
    const rest = args[command_index + 1 ..];
    if (rest.len == 0) { try platform_impl.writeStderr("usage: git var (-l | <variable>)\n"); std.process.exit(1); }
    var list_mode = false; var var_name_arg: ?[]const u8 = null;
    for (rest) |a| { if (std.mem.eql(u8, a, "-l")) list_mode = true else if (!std.mem.startsWith(u8, a, "-")) var_name_arg = a; }
    if (list_mode and var_name_arg != null) { try platform_impl.writeStderr("error: helpers.The argument '-l' cannot be used with '<variable>'\n\nusage: git var (-l | <variable>)\n"); std.process.exit(129); }
    if (list_mode) {
        const var_names = [_][]const u8{ "GIT_COMMITTER_IDENT", "GIT_AUTHOR_IDENT", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR", "GIT_PAGER", "GIT_DEFAULT_BRANCH", "GIT_SHELL_PATH", "GIT_ATTR_SYSTEM", "GIT_ATTR_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_GLOBAL" };
        for (var_names) |vn| {
            if (std.mem.eql(u8, vn, "GIT_CONFIG_GLOBAL")) { const vals = getVarMulti(allocator, vn) catch continue; defer { for (vals) |v| allocator.free(v); allocator.free(vals); } for (vals) |val| { const line = std.fmt.allocPrint(allocator, "{s}={s}\n", .{ vn, val }) catch continue; defer allocator.free(line); platform_impl.writeStdout(line) catch {}; } continue; }
            if (getVarValueP(allocator, vn, platform_impl)) |val| { defer allocator.free(val); const line = std.fmt.allocPrint(allocator, "{s}={s}\n", .{ vn, val }) catch continue; defer allocator.free(line); platform_impl.writeStdout(line) catch {}; } else |_| {}
        }
        const gpo = helpers.findGitDirectory(allocator, platform_impl) catch null; defer if (gpo) |gp| allocator.free(gp);
        if (gpo) |gp| { const cp = std.fmt.allocPrint(allocator, "{s}/config", .{gp}) catch return; defer allocator.free(cp); if (platform_impl.fs.readFile(allocator, cp)) |cd| { defer allocator.free(cd); helpers.listConfigEntries(cd, platform_impl, allocator) catch {}; } else |_| {} }
        return;
    }
    const var_name = var_name_arg orelse { try platform_impl.writeStderr("usage: git var (-l | <variable>)\n"); std.process.exit(1); };
    const known = [_][]const u8{ "GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT", "GIT_EDITOR", "GIT_PAGER", "GIT_DEFAULT_BRANCH", "GIT_SEQUENCE_EDITOR", "GIT_SHELL_PATH", "GIT_ATTR_SYSTEM", "GIT_ATTR_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_GLOBAL" };
    var is_known = false; for (known) |k| { if (std.mem.eql(u8, var_name, k)) { is_known = true; break; } }
    if (!is_known) { const msg = std.fmt.allocPrint(allocator, "helpers.Unknown variable: '{s}'\n", .{var_name}) catch return; defer allocator.free(msg); try platform_impl.writeStderr(msg); std.process.exit(1); }
    if (std.mem.eql(u8, var_name, "GIT_CONFIG_GLOBAL")) { if (std.process.getEnvVarOwned(allocator, "GIT_CONFIG_GLOBAL")) |ev| { defer allocator.free(ev); const o = std.fmt.allocPrint(allocator, "{s}\n", .{ev}) catch return; defer allocator.free(o); try platform_impl.writeStdout(o); return; } else |_| {} const vals = getVarMulti(allocator, var_name) catch { try outputVar(allocator, var_name, platform_impl); return; }; defer { for (vals) |v| allocator.free(v); allocator.free(vals); } for (vals) |val| { const l = std.fmt.allocPrint(allocator, "{s}\n", .{val}) catch continue; defer allocator.free(l); platform_impl.writeStdout(l) catch {}; } return; }
    try outputVar(allocator, var_name, platform_impl);
}


pub fn getVarValue(allocator: std.mem.Allocator, var_name: []const u8) ![]u8 { return getVarValueP(allocator, var_name, null); }

pub fn getVarValueP(allocator: std.mem.Allocator, var_name: []const u8, pi: ?*const platform_mod.Platform) ![]u8 {
    if (std.mem.eql(u8, var_name, "GIT_AUTHOR_IDENT") or std.mem.eql(u8, var_name, "GIT_COMMITTER_IDENT")) return helpers.getGitIdent(allocator, if (std.mem.eql(u8, var_name, "GIT_AUTHOR_IDENT")) "GIT_AUTHOR" else "GIT_COMMITTER");
    if (std.mem.eql(u8, var_name, "GIT_EDITOR") or std.mem.eql(u8, var_name, "GIT_SEQUENCE_EDITOR")) {
        if (std.mem.eql(u8, var_name, "GIT_SEQUENCE_EDITOR")) { if (std.process.getEnvVarOwned(allocator, "GIT_SEQUENCE_EDITOR")) |v| return v else |_| {} if (pi) |p| { if (helpers.readCfg(allocator, "sequence.editor", p)) |v| return v; } return getVarValueP(allocator, "GIT_EDITOR", pi); }
        if (std.process.getEnvVarOwned(allocator, "GIT_EDITOR")) |v| return v else |_| {} if (pi) |p| { if (helpers.readCfg(allocator, "core.editor", p)) |v| return v; } if (std.process.getEnvVarOwned(allocator, "VISUAL")) |v| return v else |_| {} if (std.process.getEnvVarOwned(allocator, "EDITOR")) |v| return v else |_| {} return error.UnknownVariable;
    }
    if (std.mem.eql(u8, var_name, "GIT_PAGER")) { if (std.process.getEnvVarOwned(allocator, "GIT_PAGER")) |v| return v else |_| {} if (pi) |p| { if (helpers.readCfg(allocator, "core.pager", p)) |v| return v; } if (std.process.getEnvVarOwned(allocator, "PAGER")) |v| return v else |_| {} return allocator.dupe(u8, "less"); }
    if (std.mem.eql(u8, var_name, "GIT_DEFAULT_BRANCH")) { if (std.process.getEnvVarOwned(allocator, "GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME") catch null) |ev| { if (ev.len > 0) return ev; allocator.free(ev); } if (pi) |p| { if (helpers.readCfg(allocator, "init.defaultbranch", p)) |v| return v; } return allocator.dupe(u8, "master"); }
    if (std.mem.eql(u8, var_name, "GIT_SHELL_PATH")) return allocator.dupe(u8, "/bin/sh");
    if (std.mem.eql(u8, var_name, "GIT_ATTR_SYSTEM")) { if (std.process.getEnvVarOwned(allocator, "GIT_ATTR_NOSYSTEM") catch null) |v| { defer allocator.free(v); if (v.len > 0 and !std.mem.eql(u8, v, "0")) return error.UnknownVariable; } return allocator.dupe(u8, "/etc/gitattributes"); }
    if (std.mem.eql(u8, var_name, "GIT_ATTR_GLOBAL")) { const xdg = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null; if (xdg) |xh| { defer allocator.free(xh); if (xh.len > 0) return std.fmt.allocPrint(allocator, "{s}/git/attributes", .{xh}); } const h = std.process.getEnvVarOwned(allocator, "HOME") catch return error.UnknownVariable; defer allocator.free(h); return std.fmt.allocPrint(allocator, "{s}/.config/git/attributes", .{h}); }
    if (std.mem.eql(u8, var_name, "GIT_CONFIG_SYSTEM")) { if (std.process.getEnvVarOwned(allocator, "GIT_CONFIG_NOSYSTEM") catch null) |v| { defer allocator.free(v); if (v.len > 0 and !std.mem.eql(u8, v, "0")) return error.UnknownVariable; } if (std.process.getEnvVarOwned(allocator, "GIT_CONFIG_SYSTEM")) |v| return v else |_| {} return allocator.dupe(u8, "/etc/gitconfig"); }
    if (std.mem.eql(u8, var_name, "GIT_CONFIG_GLOBAL")) { const xdg = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null; if (xdg) |xh| { defer allocator.free(xh); if (xh.len > 0) return std.fmt.allocPrint(allocator, "{s}/git/config", .{xh}); } const h = std.process.getEnvVarOwned(allocator, "HOME") catch return error.UnknownVariable; defer allocator.free(h); return std.fmt.allocPrint(allocator, "{s}/.config/git/config", .{h}); }
    return error.UnknownVariable;
}

pub fn getVarMulti(allocator: std.mem.Allocator, var_name: []const u8) ![][]u8 {
    if (std.mem.eql(u8, var_name, "GIT_CONFIG_GLOBAL")) {
        var results = std.ArrayList([]u8).init(allocator);
        const xdg = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null;
        if (xdg) |xh| { defer allocator.free(xh); if (xh.len > 0) { if (std.fmt.allocPrint(allocator, "{s}/git/config", .{xh})) |pp| try results.append(@constCast(pp)) else |_| {} } } else { const h = std.process.getEnvVarOwned(allocator, "HOME") catch null; if (h) |hh| { defer allocator.free(hh); if (std.fmt.allocPrint(allocator, "{s}/.config/git/config", .{hh})) |pp| try results.append(@constCast(pp)) else |_| {} } }
        const h2 = std.process.getEnvVarOwned(allocator, "HOME") catch null;
        if (h2) |hh| { defer allocator.free(hh); if (std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{hh})) |pp| try results.append(@constCast(pp)) else |_| {} }
        return try results.toOwnedSlice();
    }
    return error.NotMultiValue;
}


pub fn outputVar(allocator: std.mem.Allocator, var_name: []const u8, platform_impl: *const platform_mod.Platform) !void {
    const val = getVarValueP(allocator, var_name, platform_impl) catch { const msg = std.fmt.allocPrint(allocator, "fatal: unable to determine {s}\n", .{var_name}) catch return; defer allocator.free(msg); try platform_impl.writeStderr(msg); std.process.exit(1); };
    defer allocator.free(val);
    const out = try std.fmt.allocPrint(allocator, "{s}\n", .{val});
    defer allocator.free(out);
    try platform_impl.writeStdout(out);
}
