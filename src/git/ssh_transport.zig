const std = @import("std");
const smart_http = @import("smart_http.zig");

// Re-export shared types and functions for use by callers
pub const Oid = smart_http.Oid;
pub const Ref = smart_http.Ref;
pub const CloneResult = smart_http.CloneResult;
pub const FetchResult = smart_http.FetchResult;
pub const LocalRef = smart_http.LocalRef;
pub const parsePktLine = smart_http.parsePktLine;
pub const PktLine = smart_http.PktLine;

pub const SshUrl = struct {
    user: []const u8,
    host: []const u8,
    port: ?u16,
    path: []const u8,
    /// Whether path is absolute (from ssh:// URL) or relative (from SCP-style)
    absolute_path: bool,
};

pub const SshError = error{
    InvalidSshUrl,
    SshProcessFailed,
    SshAuthFailed,
    InvalidPktLine,
    NoPackData,
    SideBandError,
    OutOfMemory,
    Overflow,
    EndOfStream,
};

/// Parse SSH URLs in various formats:
/// - SCP-style: `git@github.com:user/repo.git`
/// - Standard:  `ssh://git@github.com/user/repo.git`
/// - With port: `ssh://user@host:22/path/to/repo`
pub fn parseSshUrl(url: []const u8) !SshUrl {
    // ssh:// scheme
    if (std.mem.startsWith(u8, url, "ssh://")) {
        return parseSshSchemeUrl(url[6..]);
    }

    // SCP-style: user@host:path
    if (std.mem.indexOfScalar(u8, url, '@')) |at_pos| {
        const after_at = url[at_pos + 1 ..];
        if (std.mem.indexOfScalar(u8, after_at, ':')) |colon_pos| {
            // Make sure this isn't ssh:// that we missed
            const host = after_at[0..colon_pos];
            const path = after_at[colon_pos + 1 ..];
            if (path.len == 0) return error.InvalidSshUrl;
            // SCP-style colon separator — path must not start with //
            // and host must not contain /
            if (std.mem.indexOfScalar(u8, host, '/') != null) return error.InvalidSshUrl;
            return SshUrl{
                .user = url[0..at_pos],
                .host = host,
                .port = null,
                .path = path,
                .absolute_path = false, // SCP-style paths are relative
            };
        }
    }

    return error.InvalidSshUrl;
}

/// Parse the part after "ssh://" — user@host[:port]/path
fn parseSshSchemeUrl(authority_and_path: []const u8) !SshUrl {
    // Find user@
    const at_pos = std.mem.indexOfScalar(u8, authority_and_path, '@') orelse
        return error.InvalidSshUrl;
    const user = authority_and_path[0..at_pos];
    const host_and_path = authority_and_path[at_pos + 1 ..];

    // Find first / to split host[:port] from path
    const slash_pos = std.mem.indexOfScalar(u8, host_and_path, '/') orelse
        return error.InvalidSshUrl;

    const host_part = host_and_path[0..slash_pos];
    const path = host_and_path[slash_pos + 1 ..];

    // Check for port in host_part (host:port)
    if (std.mem.indexOfScalar(u8, host_part, ':')) |colon_pos| {
        const host = host_part[0..colon_pos];
        const port_str = host_part[colon_pos + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidSshUrl;
        return SshUrl{
            .user = user,
            .host = host,
            .port = port,
            .path = path,
            .absolute_path = true, // ssh:// paths are absolute
        };
    }

    return SshUrl{
        .user = user,
        .host = host_part,
        .port = null,
        .path = path,
        .absolute_path = true, // ssh:// paths are absolute
    };
}

/// Check if a URL looks like an SSH URL (SCP-style or ssh:// scheme)
pub fn isSshUrl(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "ssh://")) return true;
    // SCP-style: contains @ before first : and no :// scheme prefix
    if (std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "git://") or
        std.mem.startsWith(u8, url, "file://"))
        return false;
    if (std.mem.indexOfScalar(u8, url, '@')) |at_pos| {
        const after_at = url[at_pos + 1 ..];
        return std.mem.indexOfScalar(u8, after_at, ':') != null;
    }
    return false;
}

/// Check if a ref name is relevant for cloning (HEAD, branches, tags).
/// Skips pull request refs, GitHub internal refs, etc.
fn isCloneRelevantRef(name: []const u8) bool {
    if (std.mem.eql(u8, name, "HEAD")) return true;
    if (std.mem.startsWith(u8, name, "refs/heads/")) return true;
    if (std.mem.startsWith(u8, name, "refs/tags/")) return true;
    return false;
}

/// Clone via SSH — returns pack data + refs just like smart_http.clonePack
pub fn clonePack(allocator: std.mem.Allocator, url: []const u8) !CloneResult {
    const parsed = try parseSshUrl(url);

    // Spawn ssh git-upload-pack
    var process = try spawnSshUploadPack(allocator, parsed);
    defer destroyProcess(&process);

    // Read ref advertisement from stdout (pkt-lines until flush)
    var discovery = try readRefAdvertisementFromPipe(allocator, &process);
    errdefer discovery.deinit();

    // Collect unique want hashes
    var want_set = std.StringHashMap(void).init(allocator);
    defer {
        var it = want_set.keyIterator();
        while (it.next()) |key| allocator.free(@constCast(key.*));
        want_set.deinit();
    }

    var wants = std.array_list.Managed(Oid).init(allocator);
    defer wants.deinit();

    for (discovery.refs) |ref| {
        if (!isCloneRelevantRef(ref.name)) continue;
        const hash_str = ref.hash;
        if (!want_set.contains(&hash_str)) {
            try want_set.put(try allocator.dupe(u8, &hash_str), {});
            try wants.append(hash_str);
        }
    }

    if (wants.items.len == 0) {
        return .{
            .refs = discovery.refs,
            .capabilities = discovery.capabilities,
            .pack_data = try allocator.alloc(u8, 0),
            .shallow_commits = try allocator.alloc(smart_http.Oid, 0),
            .allocator = allocator,
        };
    }

    // Build and send upload-pack request
    const request_body = try smart_http.buildUploadPackRequest(allocator, wants.items, &.{});
    defer allocator.free(request_body);

    try writeToStdin(&process, request_body);
    try closeStdin(&process);

    // Read pack response (everything remaining on stdout)
    const response = try readAllFromPipe(allocator, &process);
    defer allocator.free(response);

    const pack_data = try smart_http.parseFetchPackResponse(allocator, response);

    return .{
        .refs = discovery.refs,
        .capabilities = discovery.capabilities,
        .pack_data = pack_data,
        .shallow_commits = try allocator.alloc(smart_http.Oid, 0),
            .allocator = allocator,
    };
}

/// Fetch new objects via SSH with have/want negotiation
pub fn fetchNewPack(allocator: std.mem.Allocator, url: []const u8, local_refs: []const LocalRef) !?FetchResult {
    const parsed = try parseSshUrl(url);

    var process = try spawnSshUploadPack(allocator, parsed);
    defer destroyProcess(&process);

    // Read ref advertisement from stdout (pkt-lines until flush)
    var discovery = try readRefAdvertisementFromPipe(allocator, &process);

    // Build local ref map
    var local_map = std.StringHashMap(Oid).init(allocator);
    defer local_map.deinit();
    for (local_refs) |lr| {
        try local_map.put(lr.name, lr.hash);
    }

    // Determine wants and haves
    var wants = std.array_list.Managed(Oid).init(allocator);
    defer wants.deinit();
    var haves = std.array_list.Managed(Oid).init(allocator);
    defer haves.deinit();

    var have_set = std.StringHashMap(void).init(allocator);
    defer {
        var it = have_set.keyIterator();
        while (it.next()) |key| allocator.free(@constCast(key.*));
        have_set.deinit();
    }

    var want_set = std.StringHashMap(void).init(allocator);
    defer {
        var wit = want_set.keyIterator();
        while (wit.next()) |key| allocator.free(@constCast(key.*));
        want_set.deinit();
    }

    for (discovery.refs) |ref| {
        if (!isCloneRelevantRef(ref.name)) continue;
        if (local_map.get(ref.name)) |local_hash| {
            if (!std.mem.eql(u8, &local_hash, &ref.hash)) {
                if (!want_set.contains(&ref.hash)) {
                    try want_set.put(try allocator.dupe(u8, &ref.hash), {});
                    try wants.append(ref.hash);
                }
                if (!have_set.contains(&local_hash)) {
                    try have_set.put(try allocator.dupe(u8, &local_hash), {});
                    try haves.append(local_hash);
                }
            }
        } else {
            if (!want_set.contains(&ref.hash)) {
                try want_set.put(try allocator.dupe(u8, &ref.hash), {});
                try wants.append(ref.hash);
            }
        }
    }

    if (wants.items.len == 0) {
        discovery.deinit();
        return null;
    }

    // Build and send request
    const request_body = try smart_http.buildUploadPackRequest(allocator, wants.items, haves.items);
    defer allocator.free(request_body);

    try writeToStdin(&process, request_body);
    try closeStdin(&process);

    // Read pack response (everything remaining on stdout)
    const response = try readAllFromPipe(allocator, &process);
    defer allocator.free(response);

    const pack_data = try smart_http.parseFetchPackResponse(allocator, response);

    return .{
        .refs = discovery.refs,
        .capabilities = discovery.capabilities,
        .pack_data = pack_data,
        .allocator = allocator,
    };
}

/// Push result from SSH push: contains the remote's response for status parsing
pub const PushResult = struct {
    refs: []Ref,
    capabilities: []const u8,
    response: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PushResult) void {
        for (self.refs) |ref| self.allocator.free(ref.name);
        self.allocator.free(self.refs);
        self.allocator.free(self.capabilities);
        self.allocator.free(self.response);
    }
};

/// Discover refs from a remote via SSH git-receive-pack (for push)
pub fn discoverRefsReceivePackSsh(allocator: std.mem.Allocator, url: []const u8) !struct { discovery: smart_http.RefDiscovery, process: std.process.Child } {
    const parsed = try parseSshUrl(url);

    var process = try spawnSshReceivePack(allocator, parsed);
    errdefer destroyProcess(&process);

    // Read ref advertisement (same format as upload-pack)
    var discovery = try readRefAdvertisementFromPipe(allocator, &process);
    errdefer discovery.deinit();

    return .{ .discovery = discovery, .process = process };
}

/// Push objects to a remote via SSH git-receive-pack.
/// Sends ref update + pack data, returns the server response.
pub fn sendReceivePackSsh(
    allocator: std.mem.Allocator,
    process: *std.process.Child,
    old_hash: []const u8,
    new_hash: []const u8,
    ref_name: []const u8,
    pack_data: []const u8,
) ![]u8 {
    // Build pkt-line request body
    var body = std.array_list.Managed(u8).init(allocator);
    defer body.deinit();

    // ref update line: "<old> <new> <refname>\0 report-status\n"
    const ref_line = try std.fmt.allocPrint(allocator, "{s} {s} {s}\x00 report-status\n", .{ old_hash, new_hash, ref_name });
    defer allocator.free(ref_line);

    const pkt = try smart_http.writePktLine(allocator, ref_line);
    defer allocator.free(pkt);
    try body.appendSlice(pkt);

    // flush
    try body.appendSlice(smart_http.writeFlushPkt());

    // pack data
    try body.appendSlice(pack_data);

    // Send everything to stdin
    try writeToStdin(process, body.items);
    try closeStdin(process);

    // Read response from stdout
    const response = readAllFromPipe(allocator, process) catch |err| {
        // If pipe is closed, check stderr for error messages
        if (process.stderr) |*stderr| {
            const err_msg = stderr.readToEndAlloc(allocator, 4096) catch return err;
            defer allocator.free(err_msg);
        }
        return err;
    };

    return response;
}

// ============================================================================
// Internal helpers
// ============================================================================

fn spawnSshReceivePack(allocator: std.mem.Allocator, parsed: SshUrl) !std.process.Child {
    // Build the ssh command
    // ssh [-p port] user@host "git-receive-pack '/path'"
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("ssh");

    // Disable strict host key checking for non-interactive use
    try argv.append("-o");
    try argv.append("BatchMode=yes");
    try argv.append("-o");
    try argv.append("StrictHostKeyChecking=accept-new");

    if (parsed.port) |port| {
        try argv.append("-p");
        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;
        try argv.append(try allocator.dupe(u8, port_str));
    }

    // user@host
    const user_host = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ parsed.user, parsed.host });
    try argv.append(user_host);

    // git-receive-pack command with quoted path
    const cmd = if (parsed.absolute_path)
        try std.fmt.allocPrint(allocator, "git-receive-pack '/{s}'", .{parsed.path})
    else
        try std.fmt.allocPrint(allocator, "git-receive-pack '{s}'", .{parsed.path});
    try argv.append(cmd);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    return child;
}

fn spawnSshUploadPack(allocator: std.mem.Allocator, parsed: SshUrl) !std.process.Child {
    // Build the ssh command
    // ssh [-p port] user@host "git-upload-pack '/path'"
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("ssh");

    // Disable strict host key checking for non-interactive use
    try argv.append("-o");
    try argv.append("BatchMode=yes");
    try argv.append("-o");
    try argv.append("StrictHostKeyChecking=accept-new");

    if (parsed.port) |port| {
        try argv.append("-p");
        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;
        try argv.append(try allocator.dupe(u8, port_str));
    }

    // user@host
    const user_host = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ parsed.user, parsed.host });
    try argv.append(user_host);

    // git-upload-pack command with quoted path
    // SCP-style paths are relative, ssh:// paths are absolute (need leading /)
    const cmd = if (parsed.absolute_path)
        try std.fmt.allocPrint(allocator, "git-upload-pack '/{s}'", .{parsed.path})
    else
        try std.fmt.allocPrint(allocator, "git-upload-pack '{s}'", .{parsed.path});
    try argv.append(cmd);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    return child;
}

fn destroyProcess(process: *std.process.Child) void {
    if (process.stdin) |*stdin| stdin.close();
    if (process.stdout) |*stdout| stdout.close();
    if (process.stderr) |*stderr| stderr.close();
    _ = process.kill() catch {};
}

pub fn destroyProcessPublic(process: *std.process.Child) void {
    destroyProcess(process);
}

fn writeToStdin(process: *std.process.Child, data: []const u8) !void {
    if (process.stdin) |*stdin| {
        stdin.writeAll(data) catch return error.SshProcessFailed;
    } else return error.SshProcessFailed;
}

fn closeStdin(process: *std.process.Child) !void {
    if (process.stdin) |*stdin| {
        stdin.close();
        process.stdin = null;
    }
}

const max_ssh_response = 256 * 1024 * 1024; // 256MB

fn readAllFromPipe(allocator: std.mem.Allocator, process: *std.process.Child) ![]u8 {
    if (process.stdout) |*stdout| {
        return stdout.readToEndAlloc(allocator, max_ssh_response) catch return error.SshProcessFailed;
    }
    return error.SshProcessFailed;
}

/// Read exactly `n` bytes from the process stdout
fn readExact(process: *std.process.Child, buf: []u8) !void {
    const stdout = &(process.stdout orelse return error.SshProcessFailed);
    var total: usize = 0;
    while (total < buf.len) {
        const n = stdout.read(buf[total..]) catch return error.SshProcessFailed;
        if (n == 0) return error.EndOfStream;
        total += n;
    }
}

/// Read ref advertisement from SSH pipe incrementally (pkt-line by pkt-line).
/// This avoids the deadlock of trying to read all stdout before sending the request,
/// since git-upload-pack sends refs then waits for input.
fn readRefAdvertisementFromPipe(allocator: std.mem.Allocator, process: *std.process.Child) !smart_http.RefDiscovery {
    var refs = std.array_list.Managed(Ref).init(allocator);
    errdefer {
        for (refs.items) |ref| allocator.free(ref.name);
        refs.deinit();
    }
    var capabilities: []const u8 = "";
    var caps_allocated = false;
    var first_ref = true;

    while (true) {
        // Read 4-byte pkt-line header
        var hdr: [4]u8 = undefined;
        try readExact(process, &hdr);

        // Check for flush
        if (std.mem.eql(u8, &hdr, "0000")) break;
        if (std.mem.eql(u8, &hdr, "0001")) continue; // delim

        const pkt_len = std.fmt.parseInt(u16, &hdr, 16) catch return error.InvalidPktLine;
        if (pkt_len < 4) return error.InvalidPktLine;
        const payload_len: usize = @as(usize, pkt_len) - 4;

        // Read payload
        const payload = try allocator.alloc(u8, payload_len);
        defer allocator.free(payload);
        try readExact(process, payload);

        var line = payload;
        // Skip service announcement line
        if (line.len > 0 and line[0] == '#') continue;

        // Strip trailing newline
        if (line.len > 0 and line[line.len - 1] == '\n') {
            line = line[0 .. line.len - 1];
        }
        if (line.len < 41) continue;

        const hash = line[0..40];
        const rest = line[41..];

        var ref_name: []const u8 = rest;
        if (first_ref) {
            if (std.mem.indexOfScalar(u8, rest, 0)) |nul_pos| {
                ref_name = rest[0..nul_pos];
                const caps_str = rest[nul_pos + 1 ..];
                capabilities = try allocator.dupe(u8, caps_str);
                caps_allocated = true;
            }
            first_ref = false;
        }

        try refs.append(.{
            .hash = hash[0..40].*,
            .name = try allocator.dupe(u8, ref_name),
        });
    }

    if (!caps_allocated) {
        capabilities = try allocator.dupe(u8, "");
    }

    return .{
        .refs = try refs.toOwnedSlice(),
        .capabilities = capabilities,
        .allocator = allocator,
    };
}

/// Parse the ref advertisement from git-upload-pack's initial output.
/// SSH transport doesn't have the HTTP service announcement line, but the
/// format is otherwise identical: pkt-lines with hash + refname, capabilities
/// on first line after NUL byte, terminated by flush.
fn parseRefAdvertisement(allocator: std.mem.Allocator, data: []const u8, ref_end: *usize) !smart_http.RefDiscovery {
    var refs = std.array_list.Managed(Ref).init(allocator);
    errdefer {
        for (refs.items) |ref| allocator.free(ref.name);
        refs.deinit();
    }
    var capabilities: []const u8 = "";
    var caps_allocated = false;

    var offset: usize = 0;
    var first_ref = true;

    while (offset < data.len) {
        const result = smart_http.parsePktLine(data[offset..]) catch break;
        offset += result.consumed;

        if (result.pkt.line_type == .flush) {
            // End of ref advertisement
            break;
        }
        if (result.pkt.line_type != .data) continue;

        var line = result.pkt.data;
        // Skip service announcement line (starts with #) — shouldn't be in SSH but handle it
        if (line.len > 0 and line[0] == '#') continue;

        // Strip trailing newline
        if (line.len > 0 and line[line.len - 1] == '\n') {
            line = line[0 .. line.len - 1];
        }
        if (line.len < 41) continue;

        const hash = line[0..40];
        const rest = line[41..];

        var ref_name: []const u8 = rest;
        if (first_ref) {
            if (std.mem.indexOfScalar(u8, rest, 0)) |nul_pos| {
                ref_name = rest[0..nul_pos];
                const caps_str = rest[nul_pos + 1 ..];
                capabilities = try allocator.dupe(u8, caps_str);
                caps_allocated = true;
            }
            first_ref = false;
        }

        try refs.append(.{
            .hash = hash[0..40].*,
            .name = try allocator.dupe(u8, ref_name),
        });
    }

    ref_end.* = offset;

    if (!caps_allocated) {
        capabilities = try allocator.dupe(u8, "");
    }

    return .{
        .refs = try refs.toOwnedSlice(),
        .capabilities = capabilities,
        .allocator = allocator,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "parseSshUrl - SCP-style" {
    const result = try parseSshUrl("git@github.com:user/repo.git");
    try std.testing.expectEqualStrings("git", result.user);
    try std.testing.expectEqualStrings("github.com", result.host);
    try std.testing.expect(result.port == null);
    try std.testing.expectEqualStrings("user/repo.git", result.path);
}

test "parseSshUrl - ssh:// standard" {
    const result = try parseSshUrl("ssh://git@github.com/user/repo.git");
    try std.testing.expectEqualStrings("git", result.user);
    try std.testing.expectEqualStrings("github.com", result.host);
    try std.testing.expect(result.port == null);
    try std.testing.expectEqualStrings("user/repo.git", result.path);
}

test "parseSshUrl - ssh:// with port" {
    const result = try parseSshUrl("ssh://deploy@myserver.com:2222/repos/project.git");
    try std.testing.expectEqualStrings("deploy", result.user);
    try std.testing.expectEqualStrings("myserver.com", result.host);
    try std.testing.expectEqual(@as(u16, 2222), result.port.?);
    try std.testing.expectEqualStrings("repos/project.git", result.path);
}

test "parseSshUrl - invalid URLs" {
    try std.testing.expectError(error.InvalidSshUrl, parseSshUrl("https://github.com/user/repo"));
    try std.testing.expectError(error.InvalidSshUrl, parseSshUrl("/local/path"));
    try std.testing.expectError(error.InvalidSshUrl, parseSshUrl("ssh://noatsign/path"));
}

test "isSshUrl" {
    try std.testing.expect(isSshUrl("git@github.com:user/repo.git"));
    try std.testing.expect(isSshUrl("ssh://git@github.com/repo.git"));
    try std.testing.expect(!isSshUrl("https://github.com/repo.git"));
    try std.testing.expect(!isSshUrl("http://github.com/repo.git"));
    try std.testing.expect(!isSshUrl("/local/path"));
    try std.testing.expect(!isSshUrl("git://github.com/repo.git"));
    try std.testing.expect(!isSshUrl("file:///path/to/repo"));
}

test "parseRefAdvertisement" {
    // Simulate a git-upload-pack ref advertisement
    const allocator = std.testing.allocator;

    // Build a fake pkt-line ref advertisement
    // First line: hash SP refname NUL capabilities NL
    // Subsequent: hash SP refname NL
    // Then flush
    // hash must be 40 hex chars, pkt-line length includes the 4-byte header
    // line1 payload: 40(hash) + 1(space) + 4(HEAD) + 1(NUL) + 14(caps) + 1(NL) = 61; but NUL is 0 byte
    // Actually: 60 bytes content + 4 header = 64 = 0x0040
    const line1 = "0040abcdef0123456789abcdef0123456789abcdef01 HEAD\x00side-band-64k\n";
    // line2 payload: 40(hash) + 1(space) + 15(refs/heads/main) + 1(NL) = 57 → total 61 = 0x003d
    const line2 = "003d1234567890abcdef1234567890abcdef12345678 refs/heads/main\n";
    const flush = "0000";

    const data = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ line1, line2, flush });
    defer allocator.free(data);

    var ref_end: usize = 0;
    var discovery = try parseRefAdvertisement(allocator, data, &ref_end);
    defer discovery.deinit();

    try std.testing.expectEqual(@as(usize, 2), discovery.refs.len);
    try std.testing.expectEqualStrings("HEAD", discovery.refs[0].name);
    try std.testing.expectEqualStrings("refs/heads/main", discovery.refs[1].name);
    try std.testing.expectEqualStrings("side-band-64k", discovery.capabilities);
}
