const std = @import("std");
const helpers = @import("../git_helpers.zig");
const check_attr = @import("../cmd_check_attr.zig");
const platform_mod = @import("../platform/platform.zig");

/// Get the filter name assigned to a file path from .gitattributes.
/// Returns the filter name (e.g., "upper") or null if no filter is set.
pub fn getFilterName(
    allocator: std.mem.Allocator,
    relative_path: []const u8,
    git_path: []const u8,
    platform_impl: *const platform_mod.Platform,
) ?[]u8 {
    const repo_root = std.fs.path.dirname(git_path) orelse ".";

    // Load root .gitattributes
    var attr_rules = std.array_list.Managed(check_attr.AttrRule).init(allocator);
    defer {
        for (attr_rules.items) |*rule| rule.deinit(allocator);
        attr_rules.deinit();
    }

    check_attr.loadAttrFile(allocator, repo_root, "", platform_impl, &attr_rules) catch return null;

    // Also load directory-specific .gitattributes
    var remaining: []const u8 = relative_path;
    while (std.mem.indexOf(u8, remaining, "/")) |slash_pos| {
        const subdir = relative_path[0 .. @intFromPtr(remaining.ptr) - @intFromPtr(relative_path.ptr) + slash_pos];
        if (subdir.len > 0) {
            check_attr.loadAttrFile(allocator, repo_root, subdir, platform_impl, &attr_rules) catch {};
        }
        remaining = remaining[slash_pos + 1 ..];
    }

    // Search for filter attribute (last match wins)
    var filter_value: ?[]const u8 = null;
    for (attr_rules.items) |rule| {
        if (check_attr.attrPatternMatches(rule.pattern, relative_path, false)) {
            for (rule.attrs.items) |attr| {
                if (std.mem.eql(u8, attr.name, "filter")) {
                    if (std.mem.eql(u8, attr.value, "unset") or std.mem.eql(u8, attr.value, "unspecified")) {
                        filter_value = null;
                    } else {
                        filter_value = attr.value;
                    }
                }
            }
        }
    }

    if (filter_value) |v| {
        return allocator.dupe(u8, v) catch null;
    }
    return null;
}

/// Get a filter command from git config.
fn getFilterCommand(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    filter_name: []const u8,
    operation: []const u8,
) ?[]const u8 {
    const key = std.fmt.allocPrint(allocator, "filter.{s}.{s}", .{ filter_name, operation }) catch return null;
    defer allocator.free(key);

    return helpers.getConfigValueByKey(git_path, key, allocator);
}

/// Get the clean filter command for a given filter name.
pub fn getCleanCommand(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    filter_name: []const u8,
) ?[]const u8 {
    return getFilterCommand(allocator, git_path, filter_name, "clean");
}

/// Get the smudge filter command for a given filter name.
pub fn getSmudgeCommand(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    filter_name: []const u8,
) ?[]const u8 {
    return getFilterCommand(allocator, git_path, filter_name, "smudge");
}

/// Get the long-running process command for a given filter name.
pub fn getProcessCommand(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    filter_name: []const u8,
) ?[]const u8 {
    return getFilterCommand(allocator, git_path, filter_name, "process");
}

/// Pipe content through an external filter command.
/// The command is executed via /bin/sh -c, with content piped to stdin.
/// Returns the filtered output, or null on failure.
pub fn runFilter(
    allocator: std.mem.Allocator,
    command: []const u8,
    input: []const u8,
) ?[]u8 {
    if (@import("builtin").target.os.tag == .freestanding) {
        return null;
    }

    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    var child = std.process.Child.init(&argv, allocator);

    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    child.spawn() catch return null;

    // Write input to stdin
    if (child.stdin) |*stdin_pipe| {
        stdin_pipe.writeAll(input) catch {};
        stdin_pipe.close();
        child.stdin = null;
    }

    // Read all stdout
    var stdout_list = std.array_list.Managed(u8).init(allocator);
    defer stdout_list.deinit();

    if (child.stdout) |*stdout_pipe| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = stdout_pipe.read(&buf) catch break;
            if (n == 0) break;
            stdout_list.appendSlice(buf[0..n]) catch break;
        }
    }

    const result = child.wait() catch return null;

    return switch (result) {
        .Exited => |code| {
            if (code == 0) {
                return stdout_list.toOwnedSlice() catch null;
            }
            return null;
        },
        else => null,
    };
}

/// Apply the clean filter for a file being added to the index.
/// Returns filtered content if a clean filter was applied, null otherwise.
pub fn applyCleanFilter(
    allocator: std.mem.Allocator,
    relative_path: []const u8,
    content: []const u8,
    git_path: []const u8,
    platform_impl: *const platform_mod.Platform,
) ?[]u8 {
    const filter_name = getFilterName(allocator, relative_path, git_path, platform_impl) orelse return null;
    defer allocator.free(filter_name);

    const clean_cmd = getCleanCommand(allocator, git_path, filter_name) orelse return null;
    defer allocator.free(clean_cmd);

    return runFilter(allocator, clean_cmd, content);
}

/// Apply the smudge filter for a file being checked out.
/// Returns filtered content if a smudge filter was applied, null otherwise.
pub fn applySmudgeFilter(
    allocator: std.mem.Allocator,
    relative_path: []const u8,
    content: []const u8,
    git_path: []const u8,
    platform_impl: *const platform_mod.Platform,
) ?[]u8 {
    const filter_name = getFilterName(allocator, relative_path, git_path, platform_impl) orelse return null;
    defer allocator.free(filter_name);

    const smudge_cmd = getSmudgeCommand(allocator, git_path, filter_name) orelse return null;
    defer allocator.free(smudge_cmd);

    return runFilter(allocator, smudge_cmd, content);
}

// =============================================================================
// Long-running filter process protocol (filter.<name>.process)
// =============================================================================

/// Pkt-line helpers
const PktLine = struct {
    /// Write a pkt-line data packet. Format: 4-hex-digit length + data.
    /// Length includes the 4 bytes of the length field itself.
    fn writePacket(writer: anytype, data: []const u8) !void {
        const len = data.len + 4;
        var buf: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{x:0>4}", .{len}) catch unreachable;
        try writer.writeAll(&buf);
        try writer.writeAll(data);
    }

    /// Write a flush packet (0000).
    fn writeFlush(writer: anytype) !void {
        try writer.writeAll("0000");
    }

    /// Read a pkt-line packet. Returns null for flush packet (0000).
    /// Returns the data portion (without the 4-byte length prefix).
    fn readPacket(allocator_: std.mem.Allocator, reader: anytype) !?[]u8 {
        var len_buf: [4]u8 = undefined;
        const n = reader.readAll(&len_buf) catch return error.PktLineReadError;
        if (n < 4) return error.PktLineReadError;

        // Parse hex length
        const pkt_len = std.fmt.parseInt(u16, &len_buf, 16) catch return error.PktLineParseError;
        if (pkt_len == 0) return null; // flush packet
        if (pkt_len < 4) return error.PktLineParseError;

        const data_len = pkt_len - 4;
        if (data_len == 0) return try allocator_.dupe(u8, "");

        const data = try allocator_.alloc(u8, data_len);
        errdefer allocator_.free(data);
        const read_n = reader.readAll(data) catch {
            allocator_.free(data);
            return error.PktLineReadError;
        };
        if (read_n < data_len) {
            allocator_.free(data);
            return error.PktLineReadError;
        }
        return data;
    }

    /// Write content in pkt-line frames (max 65516 bytes data per packet).
    fn writeContent(writer: anytype, content: []const u8) !void {
        const max_data = 65516; // 65520 - 4
        var offset: usize = 0;
        while (offset < content.len) {
            const chunk_len = @min(content.len - offset, max_data);
            try writePacket(writer, content[offset .. offset + chunk_len]);
            offset += chunk_len;
        }
        try writeFlush(writer);
    }

    /// Read content from pkt-line frames until flush packet.
    fn readContent(allocator_: std.mem.Allocator, reader: anytype) ![]u8 {
        var result = std.array_list.Managed(u8).init(allocator_);
        errdefer result.deinit();
        while (true) {
            const packet = try readPacket(allocator_, reader);
            if (packet == null) break; // flush
            const pkt = packet.?;
            defer allocator_.free(pkt);
            try result.appendSlice(pkt);
        }
        return try result.toOwnedSlice();
    }
};

/// A long-running filter process connection.
pub const FilterProcess = struct {
    child: std.process.Child,
    allocator: std.mem.Allocator,
    capabilities: struct {
        clean: bool = false,
        smudge: bool = false,
    } = .{},

    /// Spawn and handshake with a long-running filter process.
    pub fn init(allocator_: std.mem.Allocator, command: []const u8) !FilterProcess {
        if (@import("builtin").target.os.tag == .freestanding) {
            return error.NotSupported;
        }

        const argv = [_][]const u8{ "/bin/sh", "-c", command };
        var child = std.process.Child.init(&argv, allocator_);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();

        var self = FilterProcess{
            .child = child,
            .allocator = allocator_,
        };

        // Perform version handshake
        self.handshake() catch |err| {
            self.deinit();
            return err;
        };

        return self;
    }

    fn handshake(self: *FilterProcess) !void {
        const writer = &self.child.stdin.?;
        const reader = &self.child.stdout.?;

        // Send client hello
        try PktLine.writePacket(writer, "git-filter-client\n");
        try PktLine.writePacket(writer, "version=2\n");
        try PktLine.writeFlush(writer);

        // Read server hello
        const server_hello = try PktLine.readPacket(self.allocator, reader);
        if (server_hello) |h| {
            defer self.allocator.free(h);
            if (!std.mem.eql(u8, std.mem.trimRight(u8, h, "\n"), "git-filter-server")) {
                return error.ProtocolError;
            }
        } else return error.ProtocolError;

        const version_pkt = try PktLine.readPacket(self.allocator, reader);
        if (version_pkt) |v| {
            defer self.allocator.free(v);
            if (!std.mem.startsWith(u8, std.mem.trimRight(u8, v, "\n"), "version=2")) {
                return error.ProtocolError;
            }
        } else return error.ProtocolError;

        // Read flush
        const flush = try PktLine.readPacket(self.allocator, reader);
        if (flush != null) {
            self.allocator.free(flush.?);
            return error.ProtocolError;
        }

        // Send capabilities
        try PktLine.writePacket(writer, "capability=clean\n");
        try PktLine.writePacket(writer, "capability=smudge\n");
        try PktLine.writeFlush(writer);

        // Read server capabilities
        while (true) {
            const cap_pkt = try PktLine.readPacket(self.allocator, reader);
            if (cap_pkt == null) break; // flush
            const cap = cap_pkt.?;
            defer self.allocator.free(cap);
            const trimmed = std.mem.trimRight(u8, cap, "\n");
            if (std.mem.eql(u8, trimmed, "capability=clean")) {
                self.capabilities.clean = true;
            } else if (std.mem.eql(u8, trimmed, "capability=smudge")) {
                self.capabilities.smudge = true;
            }
        }
    }

    /// Send a filter request (clean or smudge) and get the result.
    pub fn filterBlob(
        self: *FilterProcess,
        operation: []const u8,
        pathname: []const u8,
        content: []const u8,
    ) ![]u8 {
        const writer = &self.child.stdin.?;
        const reader = &self.child.stdout.?;

        // Send command and pathname
        const cmd_line = try std.fmt.allocPrint(self.allocator, "command={s}\n", .{operation});
        defer self.allocator.free(cmd_line);
        try PktLine.writePacket(writer, cmd_line);

        const path_line = try std.fmt.allocPrint(self.allocator, "pathname={s}\n", .{pathname});
        defer self.allocator.free(path_line);
        try PktLine.writePacket(writer, path_line);

        try PktLine.writeFlush(writer);

        // Send content
        try PktLine.writeContent(writer, content);

        // Read response status
        while (true) {
            const status_pkt = try PktLine.readPacket(self.allocator, reader);
            if (status_pkt == null) break; // flush after status lines
            const spkt = status_pkt.?;
            defer self.allocator.free(spkt);
            const trimmed = std.mem.trimRight(u8, spkt, "\n");
            if (std.mem.startsWith(u8, trimmed, "status=")) {
                const status_val = trimmed["status=".len..];
                if (!std.mem.eql(u8, status_val, "success")) {
                    // Read remaining packets until double flush
                    _ = PktLine.readContent(self.allocator, reader) catch {};
                    _ = PktLine.readPacket(self.allocator, reader) catch {};
                    return error.FilterFailed;
                }
            }
        }

        // Read filtered content
        const result = try PktLine.readContent(self.allocator, reader);

        // Read trailing flush (end of response)
        const trailing = PktLine.readPacket(self.allocator, reader) catch null;
        if (trailing) |t| self.allocator.free(t);

        return result;
    }

    pub fn deinit(self: *FilterProcess) void {
        if (self.child.stdin) |*pipe| {
            pipe.close();
            self.child.stdin = null;
        }
        if (self.child.stdout) |*pipe| {
            pipe.close();
            self.child.stdout = null;
        }
        _ = self.child.wait() catch {};
    }
};

/// Try to use a long-running filter process, falling back to single-shot filter.
/// For smudge operations during checkout.
pub fn applySmudgeFilterWithProcess(
    allocator: std.mem.Allocator,
    relative_path: []const u8,
    content: []const u8,
    git_path: []const u8,
    platform_impl: *const platform_mod.Platform,
    process_cache: *std.StringHashMap(FilterProcess),
) ?[]u8 {
    const filter_name = getFilterName(allocator, relative_path, git_path, platform_impl) orelse return null;
    defer allocator.free(filter_name);

    // Try long-running process first
    if (process_cache.getPtr(filter_name)) |proc| {
        return proc.filterBlob("smudge", relative_path, content) catch null;
    }

    // Try to start a new long-running process
    if (getProcessCommand(allocator, git_path, filter_name)) |process_cmd| {
        defer allocator.free(process_cmd);
        if (FilterProcess.init(allocator, process_cmd)) |proc| {
            var p = proc;
            if (p.capabilities.smudge) {
                const result = p.filterBlob("smudge", relative_path, content) catch {
                    p.deinit();
                    return applySmudgeFilter(allocator, relative_path, content, git_path, platform_impl);
                };
                // Cache the process (need to dupe the key)
                const key = allocator.dupe(u8, filter_name) catch {
                    p.deinit();
                    return result;
                };
                process_cache.put(key, p) catch {
                    allocator.free(key);
                    p.deinit();
                };
                return result;
            } else {
                p.deinit();
            }
        } else |_| {}
    }

    // Fallback to single-shot smudge
    return applySmudgeFilter(allocator, relative_path, content, git_path, platform_impl);
}

/// Apply clean filter, trying long-running process first.
pub fn applyCleanFilterWithProcess(
    allocator: std.mem.Allocator,
    relative_path: []const u8,
    content: []const u8,
    git_path: []const u8,
    platform_impl: *const platform_mod.Platform,
    process_cache: *std.StringHashMap(FilterProcess),
) ?[]u8 {
    const filter_name = getFilterName(allocator, relative_path, git_path, platform_impl) orelse return null;
    defer allocator.free(filter_name);

    // Try long-running process first
    if (process_cache.getPtr(filter_name)) |proc| {
        return proc.filterBlob("clean", relative_path, content) catch null;
    }

    // Try to start a new long-running process
    if (getProcessCommand(allocator, git_path, filter_name)) |process_cmd| {
        defer allocator.free(process_cmd);
        if (FilterProcess.init(allocator, process_cmd)) |proc| {
            var p = proc;
            if (p.capabilities.clean) {
                const result = p.filterBlob("clean", relative_path, content) catch {
                    p.deinit();
                    return applyCleanFilter(allocator, relative_path, content, git_path, platform_impl);
                };
                const key = allocator.dupe(u8, filter_name) catch {
                    p.deinit();
                    return result;
                };
                process_cache.put(key, p) catch {
                    allocator.free(key);
                    p.deinit();
                };
                return result;
            } else {
                p.deinit();
            }
        } else |_| {}
    }

    // Fallback to single-shot clean
    return applyCleanFilter(allocator, relative_path, content, git_path, platform_impl);
}
