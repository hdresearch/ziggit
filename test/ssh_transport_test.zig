const std = @import("std");

// We test the SSH transport module by importing it directly
const ssh_transport = @import("ssh_transport");

test "parseSshUrl - SCP-style git@github.com:user/repo.git" {
    const result = try ssh_transport.parseSshUrl("git@github.com:user/repo.git");
    try std.testing.expectEqualStrings("git", result.user);
    try std.testing.expectEqualStrings("github.com", result.host);
    try std.testing.expect(result.port == null);
    try std.testing.expectEqualStrings("user/repo.git", result.path);
}

test "parseSshUrl - SCP-style with nested path" {
    const result = try ssh_transport.parseSshUrl("deploy@gitlab.com:org/group/repo.git");
    try std.testing.expectEqualStrings("deploy", result.user);
    try std.testing.expectEqualStrings("gitlab.com", result.host);
    try std.testing.expect(result.port == null);
    try std.testing.expectEqualStrings("org/group/repo.git", result.path);
}

test "parseSshUrl - ssh:// standard URL" {
    const result = try ssh_transport.parseSshUrl("ssh://git@github.com/user/repo.git");
    try std.testing.expectEqualStrings("git", result.user);
    try std.testing.expectEqualStrings("github.com", result.host);
    try std.testing.expect(result.port == null);
    try std.testing.expectEqualStrings("user/repo.git", result.path);
}

test "parseSshUrl - ssh:// with port" {
    const result = try ssh_transport.parseSshUrl("ssh://deploy@myserver.com:2222/repos/project.git");
    try std.testing.expectEqualStrings("deploy", result.user);
    try std.testing.expectEqualStrings("myserver.com", result.host);
    try std.testing.expectEqual(@as(u16, 2222), result.port.?);
    try std.testing.expectEqualStrings("repos/project.git", result.path);
}

test "parseSshUrl - ssh:// with standard port 22" {
    const result = try ssh_transport.parseSshUrl("ssh://user@host:22/path/to/repo");
    try std.testing.expectEqualStrings("user", result.user);
    try std.testing.expectEqualStrings("host", result.host);
    try std.testing.expectEqual(@as(u16, 22), result.port.?);
    try std.testing.expectEqualStrings("path/to/repo", result.path);
}

test "parseSshUrl - invalid URLs" {
    // HTTPS URL
    try std.testing.expectError(error.InvalidSshUrl, ssh_transport.parseSshUrl("https://github.com/user/repo"));
    // Local path
    try std.testing.expectError(error.InvalidSshUrl, ssh_transport.parseSshUrl("/local/path"));
    // No user@host
    try std.testing.expectError(error.InvalidSshUrl, ssh_transport.parseSshUrl("ssh://noatsign/path"));
    // Empty path after colon in SCP-style
    try std.testing.expectError(error.InvalidSshUrl, ssh_transport.parseSshUrl("git@host:"));
}

test "isSshUrl - detects SSH URLs" {
    try std.testing.expect(ssh_transport.isSshUrl("git@github.com:user/repo.git"));
    try std.testing.expect(ssh_transport.isSshUrl("ssh://git@github.com/repo.git"));
    try std.testing.expect(ssh_transport.isSshUrl("deploy@gitlab.com:group/repo.git"));
}

test "isSshUrl - rejects non-SSH URLs" {
    try std.testing.expect(!ssh_transport.isSshUrl("https://github.com/repo.git"));
    try std.testing.expect(!ssh_transport.isSshUrl("http://github.com/repo.git"));
    try std.testing.expect(!ssh_transport.isSshUrl("/local/path"));
    try std.testing.expect(!ssh_transport.isSshUrl("git://github.com/repo.git"));
    try std.testing.expect(!ssh_transport.isSshUrl("file:///path/to/repo"));
    try std.testing.expect(!ssh_transport.isSshUrl("relative/path"));
}

test "parseRefAdvertisement via parseSshUrl integration" {
    // This validates that the pkt-line parser works with SSH-style ref advertisement
    // (no HTTP service announcement prefix)
    const allocator = std.testing.allocator;

    // Build fake pkt-line ref advertisement (SSH format — no # service line)
    const line1 = "0040abcdef0123456789abcdef0123456789abcdef01 HEAD\x00side-band-64k\n";
    const line2 = "003d1234567890abcdef1234567890abcdef12345678 refs/heads/main\n";
    const flush = "0000";

    const data = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ line1, line2, flush });
    defer allocator.free(data);

    // We can't call parseRefAdvertisement directly since it's not pub,
    // but we tested it via the inline tests in ssh_transport.zig.
    // Here just validate the data parses as valid pkt-lines using re-exported parsePktLine.
    var offset: usize = 0;
    var count: usize = 0;
    while (offset < data.len) {
        const result = ssh_transport.parsePktLine(data[offset..]) catch break;
        offset += result.consumed;
        if (result.pkt.line_type == .flush) break;
        if (result.pkt.line_type == .data) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
