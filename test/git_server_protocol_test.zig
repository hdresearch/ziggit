const std = @import("std");
const git_serve = @import("../src/git/git_serve.zig");
const git_storage = @import("../src/git/git_storage.zig");
const smart_http = @import("../src/git/smart_http.zig");

// ============================================================================
// PktLine Protocol Tests
// ============================================================================

test "PktLine format basic payload" {
    const allocator = std.testing.allocator;
    const result = try git_serve.PktLine.format(allocator, "hello\n");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("000ahello\n", result);
}

test "PktLine format empty payload" {
    const allocator = std.testing.allocator;
    const result = try git_serve.PktLine.format(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("0004", result);
}

test "PktLine flush returns 0000" {
    try std.testing.expectEqualStrings("0000", git_serve.PktLine.flush());
}

test "PktLine appendTo and readFrom round-trip" {
    const allocator = std.testing.allocator;

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try git_serve.PktLine.appendTo(&buf, "want abc123\n");
    try git_serve.PktLine.appendTo(&buf, "have def456\n");
    try git_serve.PktLine.appendFlush(&buf);

    var offset: usize = 0;
    const r1 = git_serve.PktLine.readFrom(buf.items, offset).?;
    try std.testing.expectEqualStrings("want abc123\n", r1.payload);
    offset = r1.next;

    const r2 = git_serve.PktLine.readFrom(buf.items, offset).?;
    try std.testing.expectEqualStrings("have def456\n", r2.payload);
    offset = r2.next;

    const r3 = git_serve.PktLine.readFrom(buf.items, offset).?;
    try std.testing.expectEqualStrings("", r3.payload);
}

test "PktLine readFrom with invalid data" {
    // Too short
    try std.testing.expect(git_serve.PktLine.readFrom("ab", 0) == null);

    // Invalid hex
    try std.testing.expect(git_serve.PktLine.readFrom("zzzz", 0) == null);

    // Length too short (< 4)
    try std.testing.expect(git_serve.PktLine.readFrom("0002xx", 0) == null);
}

// ============================================================================
// SideBand Tests
// ============================================================================

test "SideBand appendTo with PACK_DATA channel" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try git_serve.SideBand.appendTo(&buf, git_serve.SideBand.PACK_DATA, "PACK data here");

    // Verify: length = 4 + 1 + 14 = 19 = 0x0013
    try std.testing.expectEqualStrings("0013", buf.items[0..4]);
    try std.testing.expectEqual(@as(u8, 1), buf.items[4]);
    try std.testing.expectEqualStrings("PACK data here", buf.items[5..]);
}

test "SideBand appendTo with PROGRESS channel" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try git_serve.SideBand.appendTo(&buf, git_serve.SideBand.PROGRESS, "counting...\n");
    try std.testing.expectEqual(@as(u8, 2), buf.items[4]);
}

test "SideBand appendTo with ERROR channel" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try git_serve.SideBand.appendTo(&buf, git_serve.SideBand.ERROR, "fatal error\n");
    try std.testing.expectEqual(@as(u8, 3), buf.items[4]);
}

// ============================================================================
// Ref Advertisement Tests
// ============================================================================

test "PktLine ref advertisement format" {
    const allocator = std.testing.allocator;

    const hash = "0123456789abcdef0123456789abcdef01234567";
    const ref_name = "HEAD";
    const caps = "multi_ack side-band-64k";
    const line = try std.fmt.allocPrint(allocator, "{s} {s}\x00{s}\n", .{ hash, ref_name, caps });
    defer allocator.free(line);

    const pkt = try git_serve.PktLine.format(allocator, line);
    defer allocator.free(pkt);

    // Verify contains hash, ref, null byte, caps
    try std.testing.expect(std.mem.indexOf(u8, pkt, hash) != null);
    try std.testing.expect(std.mem.indexOf(u8, pkt, "HEAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkt, "multi_ack") != null);
}

test "Empty repo ref advertisement" {
    const allocator = std.testing.allocator;
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    const caps = "report-status side-band-64k";
    const line = try std.fmt.allocPrint(allocator, "0000000000000000000000000000000000000000 capabilities^{{}}\x00{s}\n", .{caps});
    defer allocator.free(line);
    try git_serve.PktLine.appendTo(&out, line);
    try git_serve.PktLine.appendFlush(&out);

    const r = git_serve.PktLine.readFrom(out.items, 0).?;
    try std.testing.expect(std.mem.startsWith(u8, r.payload, "0000000000000000000000000000000000000000"));
    try std.testing.expect(std.mem.indexOf(u8, r.payload, "capabilities^{}") != null);
}

// ============================================================================
// GitServer Init Tests
// ============================================================================

test "GitServer init and deinit" {
    const allocator = std.testing.allocator;
    var server = git_serve.GitServer.init(allocator, "/tmp/test-repo");
    defer server.deinit();
    try std.testing.expectEqualStrings("/tmp/test-repo", server.repo_path);
}

// ============================================================================
// Upload-Pack Protocol Message Tests
// ============================================================================

test "Upload-pack want line format" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    const hash = "0123456789abcdef0123456789abcdef01234567";
    const caps = "multi_ack thin-pack side-band-64k";
    const want_line = try std.fmt.allocPrint(allocator, "want {s} {s}\n", .{ hash, caps });
    defer allocator.free(want_line);

    try git_serve.PktLine.appendTo(&buf, want_line);

    const r = git_serve.PktLine.readFrom(buf.items, 0).?;
    try std.testing.expect(std.mem.startsWith(u8, r.payload, "want "));
    try std.testing.expect(std.mem.indexOf(u8, r.payload, hash) != null);
}

test "Upload-pack have line format" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    const hash = "abcdef0123456789abcdef0123456789abcdef01";
    const have_line = try std.fmt.allocPrint(allocator, "have {s}\n", .{hash});
    defer allocator.free(have_line);

    try git_serve.PktLine.appendTo(&buf, have_line);

    const r = git_serve.PktLine.readFrom(buf.items, 0).?;
    try std.testing.expect(std.mem.startsWith(u8, r.payload, "have "));
}

test "Upload-pack NAK response format" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try git_serve.PktLine.appendTo(&buf, "NAK\n");

    const r = git_serve.PktLine.readFrom(buf.items, 0).?;
    try std.testing.expectEqualStrings("NAK\n", r.payload);
}

// ============================================================================
// Receive-Pack Protocol Message Tests
// ============================================================================

test "Receive-pack ref update command format" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    const old_hash = "0000000000000000000000000000000000000000";
    const new_hash = "abcdef0123456789abcdef0123456789abcdef01";
    const ref_name = "refs/heads/main";
    const caps = "report-status side-band-64k";
    const update_line = try std.fmt.allocPrint(allocator, "{s} {s} {s}\x00{s}\n", .{ old_hash, new_hash, ref_name, caps });
    defer allocator.free(update_line);

    try git_serve.PktLine.appendTo(&buf, update_line);

    const r = git_serve.PktLine.readFrom(buf.items, 0).?;
    try std.testing.expect(std.mem.startsWith(u8, r.payload, old_hash));
    try std.testing.expect(std.mem.indexOf(u8, r.payload, new_hash) != null);
    try std.testing.expect(std.mem.indexOf(u8, r.payload, ref_name) != null);
}

test "Receive-pack unpack status format" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try git_serve.PktLine.appendTo(&buf, "unpack ok\n");
    try git_serve.PktLine.appendTo(&buf, "ok refs/heads/main\n");
    try git_serve.PktLine.appendFlush(&buf);

    var offset: usize = 0;
    const r1 = git_serve.PktLine.readFrom(buf.items, offset).?;
    try std.testing.expectEqualStrings("unpack ok\n", r1.payload);
    offset = r1.next;

    const r2 = git_serve.PktLine.readFrom(buf.items, offset).?;
    try std.testing.expectEqualStrings("ok refs/heads/main\n", r2.payload);
}

test "Receive-pack ng status format" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try git_serve.PktLine.appendTo(&buf, "unpack ok\n");
    try git_serve.PktLine.appendTo(&buf, "ng refs/heads/main non-fast-forward\n");
    try git_serve.PktLine.appendFlush(&buf);

    var offset: usize = 0;
    _ = git_serve.PktLine.readFrom(buf.items, offset).?;
    offset = git_serve.PktLine.readFrom(buf.items, 0).?.next;

    const r2 = git_serve.PktLine.readFrom(buf.items, offset).?;
    try std.testing.expect(std.mem.startsWith(u8, r2.payload, "ng refs/heads/main"));
}

// ============================================================================
// Deepen Protocol Tests
// ============================================================================

test "Deepen command line format" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try git_serve.PktLine.appendTo(&buf, "deepen 3\n");

    const r = git_serve.PktLine.readFrom(buf.items, 0).?;
    try std.testing.expectEqualStrings("deepen 3\n", r.payload);
}

test "Deepen-since command line format" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try git_serve.PktLine.appendTo(&buf, "deepen-since 1609459200\n");

    const r = git_serve.PktLine.readFrom(buf.items, 0).?;
    try std.testing.expectEqualStrings("deepen-since 1609459200\n", r.payload);
}

test "Deepen-relative command line format" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try git_serve.PktLine.appendTo(&buf, "deepen-relative\n");

    const r = git_serve.PktLine.readFrom(buf.items, 0).?;
    try std.testing.expectEqualStrings("deepen-relative\n", r.payload);
}

test "Deepen-not command line format" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try git_serve.PktLine.appendTo(&buf, "deepen-not refs/tags/v1.0\n");

    const r = git_serve.PktLine.readFrom(buf.items, 0).?;
    try std.testing.expectEqualStrings("deepen-not refs/tags/v1.0\n", r.payload);
}

test "Shallow response line format" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    const hash = "abcdef0123456789abcdef0123456789abcdef01";
    const line = try std.fmt.allocPrint(allocator, "shallow {s}\n", .{hash});
    defer allocator.free(line);
    try git_serve.PktLine.appendTo(&buf, line);

    const r = git_serve.PktLine.readFrom(buf.items, 0).?;
    try std.testing.expect(std.mem.startsWith(u8, r.payload, "shallow "));
    try std.testing.expect(std.mem.indexOf(u8, r.payload, hash) != null);
}

test "Unshallow response line format" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    const hash = "abcdef0123456789abcdef0123456789abcdef01";
    const line = try std.fmt.allocPrint(allocator, "unshallow {s}\n", .{hash});
    defer allocator.free(line);
    try git_serve.PktLine.appendTo(&buf, line);

    const r = git_serve.PktLine.readFrom(buf.items, 0).?;
    try std.testing.expect(std.mem.startsWith(u8, r.payload, "unshallow "));
}

// ============================================================================
// GitStorage Tests
// ============================================================================

test "GitStorage init and deinit" {
    const allocator = std.testing.allocator;
    var storage = git_storage.GitStorage.init(allocator, "/tmp/nonexistent");
    defer storage.deinit();
    try std.testing.expectEqualStrings("/tmp/nonexistent", storage.git_dir);
}

test "GitStorage isValidRepo false for nonexistent" {
    const allocator = std.testing.allocator;
    var storage = git_storage.GitStorage.init(allocator, "/tmp/nonexistent-repo-xyz-test");
    defer storage.deinit();
    try std.testing.expect(!storage.isValidRepo());
}

test "GitStorage HeadValue types" {
    const allocator = std.testing.allocator;

    var head = git_storage.HeadValue{ .symbolic = try allocator.dupe(u8, "refs/heads/main") };
    defer head.deinit(allocator);
    switch (head) {
        .symbolic => |s| try std.testing.expectEqualStrings("refs/heads/main", s),
        .direct => unreachable,
    }
}

// ============================================================================
// Client-side DeepenOptions Tests
// ============================================================================

test "DeepenOptions default values" {
    const opts = smart_http.DeepenOptions{};
    try std.testing.expectEqual(@as(u32, 0), opts.depth);
    try std.testing.expectEqual(@as(i64, 0), opts.deepen_since);
    try std.testing.expect(!opts.deepen_relative);
    try std.testing.expectEqual(@as(usize, 0), opts.deepen_not.len);
}

test "DeepenOptions with depth" {
    const opts = smart_http.DeepenOptions{ .depth = 5 };
    try std.testing.expectEqual(@as(u32, 5), opts.depth);
}

test "DeepenOptions with deepen-since" {
    const opts = smart_http.DeepenOptions{ .deepen_since = 1609459200 };
    try std.testing.expectEqual(@as(i64, 1609459200), opts.deepen_since);
}

test "DeepenOptions with deepen-relative" {
    const opts = smart_http.DeepenOptions{ .depth = 3, .deepen_relative = true };
    try std.testing.expectEqual(@as(u32, 3), opts.depth);
    try std.testing.expect(opts.deepen_relative);
}

// ============================================================================
// Full Protocol Sequence Tests
// ============================================================================

test "Upload-pack full negotiation sequence" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    // Simulate ref advertisement
    const hash = "abcdef0123456789abcdef0123456789abcdef01";
    const caps = "multi_ack thin-pack side-band-64k shallow deepen-since deepen-relative";
    const ref_line = try std.fmt.allocPrint(allocator, "{s} HEAD\x00{s}\n", .{ hash, caps });
    defer allocator.free(ref_line);
    try git_serve.PktLine.appendTo(&buf, ref_line);

    const branch_line = try std.fmt.allocPrint(allocator, "{s} refs/heads/main\n", .{hash});
    defer allocator.free(branch_line);
    try git_serve.PktLine.appendTo(&buf, branch_line);
    try git_serve.PktLine.appendFlush(&buf);

    // Verify ref lines
    var offset: usize = 0;
    const r1 = git_serve.PktLine.readFrom(buf.items, offset).?;
    try std.testing.expect(std.mem.indexOf(u8, r1.payload, "HEAD") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.payload, "deepen-since") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.payload, "deepen-relative") != null);
    offset = r1.next;

    const r2 = git_serve.PktLine.readFrom(buf.items, offset).?;
    try std.testing.expect(std.mem.indexOf(u8, r2.payload, "refs/heads/main") != null);
    offset = r2.next;

    // Flush
    const r3 = git_serve.PktLine.readFrom(buf.items, offset).?;
    try std.testing.expectEqualStrings("", r3.payload);
}

test "Receive-pack full ref update sequence" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    // Ref advertisement for receive-pack
    const hash = "abcdef0123456789abcdef0123456789abcdef01";
    const caps = "report-status report-status-v2 delete-refs side-band-64k";
    const ref_line = try std.fmt.allocPrint(allocator, "{s} refs/heads/main\x00{s}\n", .{ hash, caps });
    defer allocator.free(ref_line);
    try git_serve.PktLine.appendTo(&buf, ref_line);
    try git_serve.PktLine.appendFlush(&buf);

    // Simulate status response
    try git_serve.PktLine.appendTo(&buf, "unpack ok\n");
    try git_serve.PktLine.appendTo(&buf, "ok refs/heads/main\n");
    try git_serve.PktLine.appendFlush(&buf);

    // Verify advertisement
    var offset: usize = 0;
    const r1 = git_serve.PktLine.readFrom(buf.items, offset).?;
    try std.testing.expect(std.mem.indexOf(u8, r1.payload, "report-status") != null);
    offset = r1.next;

    // Skip flush
    offset = git_serve.PktLine.readFrom(buf.items, offset).?.next;

    // Check status
    const r3 = git_serve.PktLine.readFrom(buf.items, offset).?;
    try std.testing.expectEqualStrings("unpack ok\n", r3.payload);
    offset = r3.next;

    const r4 = git_serve.PktLine.readFrom(buf.items, offset).?;
    try std.testing.expectEqualStrings("ok refs/heads/main\n", r4.payload);
}

test "Multiple pkt-lines stress test" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    // Write 100 pkt-lines
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var line_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "line {d}\n", .{i}) catch unreachable;
        try git_serve.PktLine.appendTo(&buf, line);
    }
    try git_serve.PktLine.appendFlush(&buf);

    // Read them back
    var offset: usize = 0;
    var count: usize = 0;
    while (true) {
        const r = git_serve.PktLine.readFrom(buf.items, offset) orelse break;
        offset = r.next;
        if (r.payload.len == 0) break; // flush
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 100), count);
}
