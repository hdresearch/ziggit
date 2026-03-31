// credential.zig - Git credential helper protocol implementation
// Implements the `git credential` subcommand with fill/approve/reject operations.
// Used by git-lfs and other tools for authentication.

const std = @import("std");
const platform_mod = @import("../platform/platform.zig");
const config_mod = @import("config.zig");

pub const Credential = struct {
    protocol: ?[]const u8 = null,
    host: ?[]const u8 = null,
    path: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    url: ?[]const u8 = null,
    quit: bool = false,

    pub fn deinit(self: *Credential, allocator: std.mem.Allocator) void {
        if (self.protocol) |v| allocator.free(v);
        if (self.host) |v| allocator.free(v);
        if (self.path) |v| allocator.free(v);
        if (self.username) |v| allocator.free(v);
        if (self.password) |v| allocator.free(v);
        if (self.url) |v| allocator.free(v);
        self.* = .{};
    }

    /// Parse credential from key=value lines
    pub fn parseFromData(allocator: std.mem.Allocator, data: []const u8) !Credential {
        var cred = Credential{};
        errdefer cred.deinit(allocator);

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw_line| {
            const l = std.mem.trimRight(u8, raw_line, "\r");
            if (l.len == 0) break;

            if (std.mem.indexOfScalar(u8, l, '=')) |eq| {
                const key = l[0..eq];
                const value = l[eq + 1 ..];
                if (std.mem.eql(u8, key, "protocol")) {
                    if (cred.protocol) |old| allocator.free(old);
                    cred.protocol = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "host")) {
                    if (cred.host) |old| allocator.free(old);
                    cred.host = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "path")) {
                    if (cred.path) |old| allocator.free(old);
                    cred.path = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "username")) {
                    if (cred.username) |old| allocator.free(old);
                    cred.username = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "password")) {
                    if (cred.password) |old| allocator.free(old);
                    cred.password = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "url")) {
                    if (cred.url) |old| allocator.free(old);
                    cred.url = try allocator.dupe(u8, value);
                    try cred.parseUrl(allocator, value);
                } else if (std.mem.eql(u8, key, "quit")) {
                    cred.quit = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
                }
            }
        }
        return cred;
    }

    /// Write credential fields to a writer
    pub fn writeTo(self: *const Credential, writer: anytype) !void {
        if (self.protocol) |v| try writer.print("protocol={s}\n", .{v});
        if (self.host) |v| try writer.print("host={s}\n", .{v});
        if (self.path) |v| try writer.print("path={s}\n", .{v});
        if (self.username) |v| try writer.print("username={s}\n", .{v});
        if (self.password) |v| try writer.print("password={s}\n", .{v});
        try writer.writeAll("\n");
    }

    fn parseUrl(self: *Credential, allocator: std.mem.Allocator, url_str: []const u8) !void {
        if (std.mem.indexOf(u8, url_str, "://")) |proto_end| {
            if (self.protocol) |old| allocator.free(old);
            self.protocol = try allocator.dupe(u8, url_str[0..proto_end]);

            var rest = url_str[proto_end + 3 ..];

            // Check for username@host
            if (std.mem.indexOfScalar(u8, rest, '@')) |at_pos| {
                const slash_pos = std.mem.indexOfScalar(u8, rest, '/');
                if (slash_pos == null or at_pos < slash_pos.?) {
                    const userinfo = rest[0..at_pos];
                    // Check for password in userinfo
                    if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
                        if (self.username) |old| allocator.free(old);
                        self.username = try allocator.dupe(u8, userinfo[0..colon]);
                        if (self.password) |old| allocator.free(old);
                        self.password = try allocator.dupe(u8, userinfo[colon + 1 ..]);
                    } else {
                        if (self.username) |old| allocator.free(old);
                        self.username = try allocator.dupe(u8, userinfo);
                    }
                    rest = rest[at_pos + 1 ..];
                }
            }

            if (std.mem.indexOfScalar(u8, rest, '/')) |slash_pos| {
                if (self.host) |old| allocator.free(old);
                self.host = try allocator.dupe(u8, rest[0..slash_pos]);
                if (slash_pos + 1 < rest.len) {
                    if (self.path) |old| allocator.free(old);
                    self.path = try allocator.dupe(u8, rest[slash_pos + 1 ..]);
                }
            } else {
                if (self.host) |old| allocator.free(old);
                self.host = try allocator.dupe(u8, rest);
            }
        }
    }
};

/// Get credential helpers from config
fn getCredentialHelpers(allocator: std.mem.Allocator, git_dir: []const u8) ![][]const u8 {
    var helpers_list = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (helpers_list.items) |h| allocator.free(h);
        helpers_list.deinit();
    }

    var cfg = config_mod.GitConfig.init(allocator);
    defer cfg.deinit();

    // Load repo config
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
    defer allocator.free(config_path);
    cfg.parseFromFile(config_path) catch {};

    // Load global config
    if (std.posix.getenv("HOME")) |home| {
        const global_path = try std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{home});
        defer allocator.free(global_path);
        cfg.parseFromFile(global_path) catch {};
    }

    // Load XDG config
    const xdg_home = std.posix.getenv("XDG_CONFIG_HOME");
    if (xdg_home) |xdg| {
        const xdg_path = try std.fmt.allocPrint(allocator, "{s}/git/config", .{xdg});
        defer allocator.free(xdg_path);
        cfg.parseFromFile(xdg_path) catch {};
    } else if (std.posix.getenv("HOME")) |home| {
        const xdg_path = try std.fmt.allocPrint(allocator, "{s}/.config/git/config", .{home});
        defer allocator.free(xdg_path);
        cfg.parseFromFile(xdg_path) catch {};
    }

    // Load system config
    cfg.parseFromFile("/etc/gitconfig") catch {};

    // Get all credential.helper values
    const all = try cfg.getAll("credential", null, "helper", allocator);
    defer allocator.free(all);
    for (all) |helper_val| {
        if (helper_val.len > 0) {
            try helpers_list.append(try allocator.dupe(u8, helper_val));
        }
    }

    return try helpers_list.toOwnedSlice();
}

/// Build command line for a credential helper
fn buildHelperArgv(allocator: std.mem.Allocator, helper: []const u8, operation: []const u8) ![]const []const u8 {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (argv.items) |a| allocator.free(a);
        argv.deinit();
    }

    if (helper.len > 0 and helper[0] == '!') {
        // Shell command
        const shell_cmd = try std.fmt.allocPrint(allocator, "{s} {s}", .{ helper[1..], operation });
        try argv.append(try allocator.dupe(u8, "/bin/sh"));
        try argv.append(try allocator.dupe(u8, "-c"));
        try argv.append(shell_cmd);
    } else if (helper[0] == '/' or std.mem.startsWith(u8, helper, "./") or std.mem.startsWith(u8, helper, "../")) {
        try argv.append(try allocator.dupe(u8, helper));
        try argv.append(try allocator.dupe(u8, operation));
    } else {
        const binary = try std.fmt.allocPrint(allocator, "git-credential-{s}", .{helper});
        try argv.append(binary);
        try argv.append(try allocator.dupe(u8, operation));
    }

    return try argv.toOwnedSlice();
}

/// Run a credential helper
fn runHelper(allocator: std.mem.Allocator, helper: []const u8, operation: []const u8, cred: *const Credential) !?Credential {
    const argv_owned = try buildHelperArgv(allocator, helper, operation);
    defer {
        for (argv_owned) |a| allocator.free(a);
        allocator.free(argv_owned);
    }

    if (argv_owned.len == 0) return null;

    var child = std.process.Child.init(argv_owned, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    child.spawn() catch return null;

    // Write credential to stdin
    if (child.stdin) |stdin_pipe| {
        var buf = std.array_list.Managed(u8).init(allocator);
        defer buf.deinit();
        cred.writeTo(buf.writer()) catch {};
        stdin_pipe.writeAll(buf.items) catch {};
        stdin_pipe.close();
        child.stdin = null;
    }

    // Read stdout
    var result_cred: ?Credential = null;
    if (child.stdout) |stdout_pipe| {
        var resp_buf = std.array_list.Managed(u8).init(allocator);
        defer resp_buf.deinit();
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = stdout_pipe.read(&read_buf) catch break;
            if (n == 0) break;
            resp_buf.appendSlice(read_buf[0..n]) catch break;
        }
        if (resp_buf.items.len > 0) {
            result_cred = Credential.parseFromData(allocator, resp_buf.items) catch null;
        }
    }

    const term = child.wait() catch return result_cred;
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                if (result_cred) |*rc| rc.deinit(allocator);
                return null;
            }
        },
        else => {
            if (result_cred) |*rc| rc.deinit(allocator);
            return null;
        },
    }

    return result_cred;
}

/// Fill a credential by trying each configured helper in order
pub fn credentialFill(allocator: std.mem.Allocator, git_dir: []const u8, cred: *Credential) !void {
    const helpers_list = try getCredentialHelpers(allocator, git_dir);
    defer {
        for (helpers_list) |h| allocator.free(h);
        allocator.free(helpers_list);
    }

    for (helpers_list) |helper| {
        if (helper.len == 0) continue;

        const result = try runHelper(allocator, helper, "get", cred);
        if (result) |resp| {
            // Merge response into cred
            if (resp.username) |u| {
                if (cred.username) |old| allocator.free(old);
                cred.username = allocator.dupe(u8, u) catch null;
            }
            if (resp.password) |p| {
                if (cred.password) |old| allocator.free(old);
                cred.password = allocator.dupe(u8, p) catch null;
            }
            if (resp.protocol) |v| {
                if (cred.protocol == null) cred.protocol = allocator.dupe(u8, v) catch null;
            }
            if (resp.host) |v| {
                if (cred.host == null) cred.host = allocator.dupe(u8, v) catch null;
            }
            if (resp.path) |v| {
                if (cred.path == null) cred.path = allocator.dupe(u8, v) catch null;
            }
            var resp_mut = resp;
            resp_mut.deinit(allocator);

            if (cred.username != null and cred.password != null) return;
        }
        if (cred.quit) return;
    }
}

/// Notify helpers of successful credential use
pub fn credentialApprove(allocator: std.mem.Allocator, git_dir: []const u8, cred: *const Credential) !void {
    if (cred.username == null or cred.password == null) return;

    const helpers_list = try getCredentialHelpers(allocator, git_dir);
    defer {
        for (helpers_list) |h| allocator.free(h);
        allocator.free(helpers_list);
    }

    for (helpers_list) |helper| {
        if (helper.len == 0) continue;
        const result = runHelper(allocator, helper, "store", cred) catch null;
        if (result) |r| {
            var r_mut = r;
            r_mut.deinit(allocator);
        }
    }
}

/// Notify helpers of rejected credential
pub fn credentialReject(allocator: std.mem.Allocator, git_dir: []const u8, cred: *const Credential) !void {
    const helpers_list = try getCredentialHelpers(allocator, git_dir);
    defer {
        for (helpers_list) |h| allocator.free(h);
        allocator.free(helpers_list);
    }

    for (helpers_list) |helper| {
        if (helper.len == 0) continue;
        const result = runHelper(allocator, helper, "erase", cred) catch null;
        if (result) |r| {
            var r_mut = r;
            r_mut.deinit(allocator);
        }
    }
}

/// Command handler for `git credential <fill|approve|reject>`
pub fn cmdCredential(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const operation = args.next() orelse {
        try platform_impl.writeStderr("usage: git credential <fill|approve|reject>\n");
        std.process.exit(128);
    };

    const git_helpers = @import("../git_helpers.zig");
    const git_dir = git_helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_dir);

    // Read credential data from stdin
    const stdin_data = git_helpers.readStdin(allocator, 10 * 1024 * 1024) catch &[_]u8{};
    defer if (stdin_data.len > 0) allocator.free(stdin_data);

    if (std.mem.eql(u8, operation, "fill")) {
        var cred = try Credential.parseFromData(allocator, stdin_data);
        defer cred.deinit(allocator);

        try credentialFill(allocator, git_dir, &cred);

        // Output the filled credential
        var out_buf = std.array_list.Managed(u8).init(allocator);
        defer out_buf.deinit();
        try cred.writeTo(out_buf.writer());
        try platform_impl.writeStdout(out_buf.items);
    } else if (std.mem.eql(u8, operation, "approve")) {
        var cred = try Credential.parseFromData(allocator, stdin_data);
        defer cred.deinit(allocator);
        try credentialApprove(allocator, git_dir, &cred);
    } else if (std.mem.eql(u8, operation, "reject")) {
        var cred = try Credential.parseFromData(allocator, stdin_data);
        defer cred.deinit(allocator);
        try credentialReject(allocator, git_dir, &cred);
    } else {
        const msg = std.fmt.allocPrint(allocator, "fatal: unknown credential operation: {s}\n", .{operation}) catch "fatal: unknown credential operation\n";
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    }
}
